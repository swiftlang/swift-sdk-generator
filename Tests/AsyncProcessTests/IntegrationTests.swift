//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2022-2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
@preconcurrency import Musl
#elseif canImport(Glibc)
@preconcurrency import Glibc
#elseif canImport(WASILibc)
@preconcurrency import WASILibc
#elseif canImport(Bionic)
@preconcurrency import Bionic
#elseif canImport(Android)
@preconcurrency import Android
#else
#error("unknown libc, please fix")
#endif

import AsyncAlgorithms
import AsyncProcess
import Atomics
import Logging
import NIO
import NIOConcurrencyHelpers
import XCTest

final class IntegrationTests: XCTestCase {
  private var group: EventLoopGroup!
  private var logger: Logger!
  private var highestFD: CInt?

  func testTheBasicsWork() async throws {
    let exe = ProcessExecutor(
      group: self.group,
      executable: "/bin/sh", ["-c", "exit 0"],
      standardInput: EOFSequence(),
      logger: self.logger
    )
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        for try await chunk in await merge(exe.standardOutput, exe.standardError) {
          XCTFail("unexpected output: \(chunk.debugDescription)")
        }
      }
      let result = try await exe.run()
      XCTAssertEqual(.exit(CInt(0)), result)
    }
  }

  func testExitCodesWork() async throws {
    for exitCode in UInt8.min...UInt8.max {
      let exe = ProcessExecutor(
        group: self.group,
        executable: "/bin/sh", ["-c", "exit \(exitCode)"],
        standardInput: EOFSequence(),
        logger: self.logger
      )
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
          for try await chunk in await merge(exe.standardOutput, exe.standardError) {
            XCTFail("unexpected output: \(chunk.debugDescription)")
          }
        }

        let result = try await exe.run()
        XCTAssertEqual(.exit(CInt(exitCode)), result)
      }
    }
  }

  func testSignalsWork() async throws {
    let signalsToTest: [CInt] = [SIGKILL, SIGTERM, SIGINT]
    for signal in signalsToTest {
      let exe = ProcessExecutor(
        group: self.group,
        executable: "/bin/sh", ["-c", "kill -\(signal) $$"],
        standardInput: EOFSequence(),
        logger: self.logger
      )

      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
          for try await chunk in await merge(exe.standardOutput, exe.standardError) {
            XCTFail("unexpected output: \(chunk.debugDescription)")
          }
        }

        let result = try await exe.run()
        XCTAssertEqual(.signal(CInt(signal)), result)
      }
    }
  }

  func testStreamingInputAndOutputWorks() async throws {
    let input = AsyncStream.justMakeIt(elementType: ByteBuffer.self)
    let exe = ProcessExecutor(
      group: self.group,
      executable: "/bin/cat", ["-nu"], // sh", ["-c", "while read -r line; do echo $line; done"],
      standardInput: input.consumer,
      logger: self.logger
    )
    try await withThrowingTaskGroup(of: ProcessExitReason?.self) { group in
      group.addTask {
        var lastLine: String? = nil
        for try await line in await exe.standardOutput.splitIntoLines(dropTerminator: false) {
          if line.readableBytes > 72 {
            lastLine = String(buffer: line)
            break
          }
          input.producer.yield(line)
        }
        XCTAssertEqual(
          "    10\t     9\t     8\t     7\t     6\t     5\t     4\t     3\t     2\t     1\tGO\n",
          lastLine
        )
        return nil
      }

      group.addTask {
        for try await chunk in await exe.standardError {
          XCTFail("unexpected stderr output: \(chunk.debugDescription)")
        }
        return nil
      }

      group.addTask {
        try await exe.run()
      }

      input.producer.yield(ByteBuffer(string: "GO\n"))

      // The stdout-reading task will exit first (the others will only return when we explicitly cancel because
      // the sub process would keep going forever).
      let stdoutReturn = try await group.next()
      var totalTasksReturned = 1
      XCTAssertEqual(.some(nil), stdoutReturn)
      group.cancelAll()

      while let furtherReturn = try await group.next() {
        totalTasksReturned += 1
        switch furtherReturn {
        case let .some(result):
          // the `exe.run()` task
          XCTAssert(.signal(SIGKILL) == result || .exit(0) == result)
        case .none:
          // stderr task
          ()
        }
      }
      XCTAssertEqual(3, totalTasksReturned)
    }
  }

  func testAbsorbing1MBOfDevZeroWorks() async throws {
    let totalAmountInBytes = 1024 * 1024
    let exe = ProcessExecutor(
      group: self.group,
      executable: "/bin/sh",
      [
        "-c",
        // spawn two `dd`s that output 1 MiB of zeros (but no diagnostics output). One bunch of zeroes will
        // go to stdout, the other one to stderr.
        "/bin/dd     2>/dev/null bs=\(totalAmountInBytes) count=1 if=/dev/zero; "
          + "/bin/dd >&2 2>/dev/null bs=\(totalAmountInBytes) count=1 if=/dev/zero; ",
      ],
      standardInput: EOFSequence(),
      logger: self.logger
    )
    try await withThrowingTaskGroup(of: ByteBuffer.self) { group in
      group.addTask {
        var accumulation = ByteBuffer()
        accumulation.reserveCapacity(totalAmountInBytes)

        for try await chunk in await exe.standardOutput {
          accumulation.writeImmutableBuffer(chunk)
        }

        return accumulation
      }

      group.addTask {
        var accumulation = ByteBuffer()
        accumulation.reserveCapacity(totalAmountInBytes)

        for try await chunk in await exe.standardError {
          accumulation.writeImmutableBuffer(chunk)
        }

        return accumulation
      }

      let result = try await exe.run()

      // once for stdout, once for stderr
      let stream1 = try await group.next()
      let stream2 = try await group.next()
      XCTAssertEqual(ByteBuffer(repeating: 0, count: totalAmountInBytes), stream1)
      XCTAssertEqual(ByteBuffer(repeating: 0, count: totalAmountInBytes), stream2)

      XCTAssertEqual(.exit(0), result)
    }
  }

  func testInteractiveShell() async throws {
    let input = AsyncStream.justMakeIt(elementType: ByteBuffer.self)
    let exe = ProcessExecutor(
      group: self.group,
      executable: "/bin/sh", [],
      standardInput: input.consumer,
      logger: self.logger
    )

    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        var allOutput: [String] = []
        for try await (stream, line) in await merge(
          exe.standardOutput.splitIntoLines(dropTerminator: true).map { ("stdout", $0) },
          exe.standardError.splitIntoLines(dropTerminator: true).map { ("stderr", $0) }
        ) {
          let formattedOutput = "\(String(buffer: line)) [\(stream)]"
          allOutput.append(formattedOutput)
        }

        XCTAssertEqual(
          [
            "hello stderr [stderr]",
            "hello stdout [stdout]",
          ],
          allOutput.sorted()
        )
      }

      group.addTask {
        let result = try await exe.run()
        XCTAssertEqual(.exit(0), result)
      }

      input.producer.yield(ByteBuffer(string: "echo hello stdout\n"))
      input.producer.yield(ByteBuffer(string: "echo >&2 hello stderr\n"))
      input.producer.yield(ByteBuffer(string: "exit 0\n"))
      input.producer.finish()

      try await group.waitForAll()
    }
  }

  func testEnvironmentVariables() async throws {
    let exe = ProcessExecutor(
      group: self.group,
      executable: "/bin/sh",
      ["-c", "echo $MY_VAR"],
      environment: ["MY_VAR": "value of my var"],
      standardInput: EOFSequence(),
      logger: self.logger
    )
    let all = try await exe.runGetAllOutput()
    XCTAssertEqual(.exit(0), all.exitReason)
    XCTAssertEqual("value of my var\n", String(buffer: all.standardOutput))
    XCTAssertEqual("", String(buffer: all.standardError))
  }

  func testSimplePipe() async throws {
    self.logger.logLevel = .debug
    let echo = ProcessExecutor(
      group: self.group,
      executable: "/bin/sh",
      ["-c", "echo foo;"],
      standardInput: EOFSequence(),
      standardError: .discard,
      logger: self.logger
    )

    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        try await echo.run().throwIfNonZero()
      }
      group.addTask { [elg = self.group!, logger = self.logger!] in
        let echoOutput = await echo.standardOutput

        let sed = ProcessExecutor(
          group: elg,
          executable: "/usr/bin/tr",
          ["[:lower:]", "[:upper:]"],
          standardInput: echoOutput,
          logger: logger
        )
        let output = try await sed.runGetAllOutput()
        XCTAssertEqual(String(buffer: output.standardOutput), "FOO\n")
      }
      try await group.waitForAll()
    }
  }

  func testStressTestVeryLittleOutput() async throws {
    for _ in 0..<128 {
      let exe = ProcessExecutor(
        group: self.group,
        executable: "/bin/sh",
        ["-c", "echo x; echo >&2 y;"],
        standardInput: EOFSequence(),
        logger: self.logger
      )
      let all = try await exe.runGetAllOutput()
      XCTAssertEqual(.exit(0), all.exitReason)
      XCTAssertEqual("x\n", String(buffer: all.standardOutput))
      XCTAssertEqual("y\n", String(buffer: all.standardError))
    }
  }

  func testOutputWithoutNewlinesThatIsSplitIntoLines() async throws {
    self.logger = Logger(label: "x")
    self.logger.logLevel = .trace
    let exe = ProcessExecutor(
      group: self.group,
      executable: "/bin/sh",
      ["-c", "/bin/echo -n x; /bin/echo >&2 -n y"],
      standardInput: EOFSequence(),
      logger: self.logger
    )
    try await withThrowingTaskGroup(of: (String, ByteBuffer)?.self) { group in
      group.addTask {
        try await exe.run().throwIfNonZero()
        return nil
      }
      group.addTask {
        var things: [ByteBuffer] = []
        for try await chunk in await exe.standardOutput.splitIntoLines() {
          things.append(chunk)
        }
        XCTAssertEqual(1, things.count)
        return ("stdout", things.first.flatMap { $0 } ?? ByteBuffer(string: "n/a"))
      }
      group.addTask {
        var things: [ByteBuffer?] = []
        for try await chunk in await exe.standardError.splitIntoLines() {
          things.append(chunk)
        }
        XCTAssertEqual(1, things.count)
        return ("stderr", things.first.flatMap { $0 } ?? ByteBuffer(string: "n/a"))
      }

      let everything = try await Array(group).sorted { l, r in
        guard let l else {
          return true
        }
        guard let r else {
          return false
        }
        return l.0 < r.0
      }
      XCTAssertEqual(
        [nil, "stderr", "stdout"],
        everything.map { $0?.0 }
      )

      XCTAssertEqual(
        [nil, ByteBuffer(string: "y"), ByteBuffer(string: "x")],
        everything.map { $0?.1 }
      )
    }
  }

  func testDiscardingStdoutWorks() async throws {
    let exe = ProcessExecutor(
      group: self.group,
      executable: "/bin/dd",
      ["if=/dev/zero", "bs=\(1024 * 1024)", "count=1024", "status=none"],
      standardInput: EOFSequence(),
      standardOutput: .discard,
      standardError: .stream,
      logger: self.logger
    )
    async let stderr = exe.standardError.pullAllOfIt()
    try await exe.run().throwIfNonZero()
    let stderrBytes = try await stderr
    XCTAssertEqual(ByteBuffer(), stderrBytes)
  }

  func testDiscardingStderrWorks() async throws {
    let exe = ProcessExecutor(
      group: self.group,
      executable: "/bin/sh",
      ["-c", "/bin/dd >&2 if=/dev/zero bs=\(1024 * 1024) count=1024 status=none; echo OK"],
      standardInput: EOFSequence(),
      standardOutput: .stream,
      standardError: .discard,
      logger: self.logger
    )
    async let stdout = exe.standardOutput.pullAllOfIt()
    try await exe.run().throwIfNonZero()
    let stdoutBytes = try await stdout
    XCTAssertEqual(ByteBuffer(string: "OK\n"), stdoutBytes)
  }

  func testStdoutToFileWorks() async throws {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("AsyncProcessTests-\(getpid())-\(UUID())")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: false)
    defer {
      XCTAssertNoThrow(try FileManager.default.removeItem(at: tempDir))
    }

    let file = tempDir.appendingPathComponent("file")

    let exe = try ProcessExecutor(
      group: self.group,
      executable: "/bin/dd",
      ["if=/dev/zero", "bs=\(1024 * 1024)", "count=3", "status=none"],
      standardInput: EOFSequence(),
      standardOutput: .fileDescriptor(
        takingOwnershipOf: .open(
          .init(file.path.removingPercentEncoding!),
          .writeOnly,
          options: .create,
          permissions: [.ownerRead, .ownerWrite]
        )
      ),
      standardError: .stream,
      logger: self.logger
    )
    async let stderr = exe.standardError.pullAllOfIt()
    try await exe.run().throwIfNonZero()
    let stderrBytes = try await stderr
    XCTAssertEqual(Data(repeating: 0, count: 3 * 1024 * 1024), try Data(contentsOf: file))
    XCTAssertEqual(ByteBuffer(), stderrBytes)
  }

  func testStderrToFileWorks() async throws {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("AsyncProcessTests-\(getpid())-\(UUID())")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: false)
    defer {
      XCTAssertNoThrow(try FileManager.default.removeItem(at: tempDir))
    }

    let file = tempDir.appendingPathComponent("file")

    let exe = ProcessExecutor(
      group: self.group,
      executable: "/bin/sh",
      ["-c", "/bin/dd >&2 if=/dev/zero bs=\(1024 * 1024) count=3 status=none; echo OK"],
      standardInput: EOFSequence(),
      standardOutput: .stream,
      standardError: .fileDescriptor(
        takingOwnershipOf: try! .open(
          .init(file.path.removingPercentEncoding!),
          .writeOnly,
          options: .create,
          permissions: [.ownerRead, .ownerWrite]
        )
      ),
      logger: self.logger
    )
    async let stdout = exe.standardOutput.pullAllOfIt()
    try await exe.run().throwIfNonZero()
    let stdoutBytes = try await stdout
    XCTAssertEqual(ByteBuffer(string: "OK\n"), stdoutBytes)
    XCTAssertEqual(Data(repeating: 0, count: 3 * 1024 * 1024), try Data(contentsOf: file))
  }

  func testInheritingStdoutAndStderrWork() async throws {
    let exe = ProcessExecutor(
      group: self.group,
      executable: "/bin/sh",
      ["-c", "echo this is stdout; echo >&2 this is stderr"],
      standardInput: EOFSequence(),
      standardOutput: .inherit,
      standardError: .inherit,
      logger: self.logger
    )
    try await exe.run().throwIfNonZero()
  }

  func testDiscardingAndConsumingOutputYieldsAnError() async throws {
    let exe = ProcessExecutor(
      group: self.group,
      executable: "/bin/sh",
      ["-c", "echo this is stdout; echo >&2 this is stderr"],
      standardInput: EOFSequence(),
      standardOutput: .discard,
      standardError: .discard,
      logger: self.logger
    )
    try await exe.run().throwIfNonZero()
    var stdoutIterator = await exe.standardOutput.makeAsyncIterator()
    var stderrIterator = await exe.standardError.makeAsyncIterator()
    do {
      _ = try await stdoutIterator.next()
      XCTFail("expected this to throw")
    } catch is IllegalStreamConsumptionError {
      // OK
    }
    do {
      _ = try await stderrIterator.next()
      XCTFail("expected this to throw")
    } catch is IllegalStreamConsumptionError {
      // OK
    }
  }

  func testStressTestDiscardingOutput() async throws {
    for _ in 0..<128 {
      let exe = ProcessExecutor(
        group: self.group,
        executable: "/bin/sh",
        [
          "-c",
          "/bin/dd if=/dev/zero bs=\(1024 * 1024) count=1; /bin/dd >&2 if=/dev/zero bs=\(1024 * 1024) count=1;",
        ],
        standardInput: EOFSequence(),
        standardOutput: .discard,
        standardError: .discard,
        logger: self.logger
      )
      try await exe.run().throwIfNonZero()
    }
  }

  func testLogOutputToMetadata() async throws {
    let sharedRecorder = LogRecorderHandler()
    var recordedLogger = Logger(label: "recorder", factory: { _ in sharedRecorder })
    recordedLogger.logLevel = .info // don't give us the normal messages
    recordedLogger[metadataKey: "yo"] = "hey"

    try await ProcessExecutor.runLogOutput(
      group: self.group,
      executable: "/bin/sh",
      ["-c", "echo 1; echo >&2 2; echo 3; echo >&2 4; echo 5; echo >&2 6; echo 7; echo >&2 8;"],
      standardInput: EOFSequence(),
      logger: recordedLogger,
      logConfiguration: OutputLoggingSettings(logLevel: .critical, to: .metadata(logMessage: "msg", key: "key"))
    ).throwIfNonZero()
    XCTAssert(sharedRecorder.recordedMessages.allSatisfy { $0.level == .critical })
    XCTAssert(sharedRecorder.recordedMessages.allSatisfy { $0.message == "msg" })
    XCTAssert(sharedRecorder.recordedMessages.allSatisfy { $0.metadata["key"] != nil })
    XCTAssert(sharedRecorder.recordedMessages.allSatisfy { $0.metadata["yo"] == "hey" })
    let loggedLines = sharedRecorder.recordedMessages.compactMap { $0.metadata["key"]?.description }.sorted()
    XCTAssertEqual(["1", "2", "3", "4", "5", "6", "7", "8"], loggedLines)
  }

  func testLogOutputToMessage() async throws {
    let sharedRecorder = LogRecorderHandler()
    var recordedLogger = Logger(label: "recorder", factory: { _ in sharedRecorder })
    recordedLogger.logLevel = .info // don't give us the normal messages
    recordedLogger[metadataKey: "yo"] = "hey"

    try await ProcessExecutor.runLogOutput(
      group: self.group,
      executable: "/bin/sh",
      ["-c", "echo 1; echo >&2 2; echo 3; echo >&2 4; echo 5; echo >&2 6; echo 7; echo >&2 8;"],
      standardInput: EOFSequence(),
      logger: recordedLogger,
      logConfiguration: OutputLoggingSettings(logLevel: .critical, to: .logMessage)
    ).throwIfNonZero()
    XCTAssert(sharedRecorder.recordedMessages.allSatisfy { $0.level == .critical })
    XCTAssert(sharedRecorder.recordedMessages.allSatisfy { $0.metadata["key"] == nil })
    XCTAssert(sharedRecorder.recordedMessages.allSatisfy { $0.metadata["yo"] == "hey" })
    let loggedLines = sharedRecorder.recordedMessages.map(\.message.description).sorted()
    XCTAssertEqual(["1", "2", "3", "4", "5", "6", "7", "8"], loggedLines)
  }

  func testProcessOutputByLine() async throws {
    let collectedLines: NIOLockedValueBox<[(String, String)]> = NIOLockedValueBox([])
    try await ProcessExecutor.runProcessingOutput(
      group: self.group,
      executable: "/bin/sh",
      [
        "-c",
        """
        ( echo 1; echo >&2 2; echo 3; echo >&2 4; echo 5; echo >&2 6; echo 7; echo >&2 8; ) | \
        /bin/dd bs=1000 status=none
        """,
      ],
      standardInput: EOFSequence(),
      outputProcessor: { stream, line in
        collectedLines.withLockedValue { collection in
          collection.append((stream.description, String(buffer: line)))
        }
      },
      splitOutputIntoLines: true,
      logger: self.logger
    ).throwIfNonZero()
    XCTAssertEqual(
      ["1", "2", "3", "4", "5", "6", "7", "8"],
      collectedLines.withLockedValue { $0.map(\.1) }.sorted()
    )
  }

  func testProcessOutputInChunks() async throws {
    let collectedBytes = ManagedAtomic<Int>(0)
    try await ProcessExecutor.runProcessingOutput(
      group: self.group,
      executable: "/bin/dd",
      ["if=/dev/zero", "bs=\(1024 * 1024)", "count=20", "status=none"],
      standardInput: EOFSequence(),
      outputProcessor: { stream, chunk in
        XCTAssertEqual(stream, .standardOutput)
        XCTAssert(chunk.withUnsafeReadableBytes { $0.allSatisfy { $0 == 0 } })
        collectedBytes.wrappingIncrement(by: chunk.readableBytes, ordering: .relaxed)
      },
      splitOutputIntoLines: true,
      logger: self.logger
    ).throwIfNonZero()
    XCTAssertEqual(20 * 1024 * 1024, collectedBytes.load(ordering: .relaxed))
  }

  func testBasicRunMethodWorks() async throws {
    try await ProcessExecutor.run(
      group: self.group,
      executable: "/bin/dd", ["if=/dev/zero", "bs=\(1024 * 1024)", "count=100"],
      standardInput: EOFSequence(),
      logger: self.logger
    ).throwIfNonZero()
  }

  func testCollectJustStandardOutput() async throws {
    let allInfo = try await ProcessExecutor.runCollectingOutput(
      group: self.group,
      executable: "/bin/dd", ["if=/dev/zero", "bs=\(1024 * 1024)", "count=1"],
      standardInput: EOFSequence(),
      collectStandardOutput: true,
      collectStandardError: false,
      perStreamCollectionLimitBytes: 1024 * 1024,
      logger: self.logger
    )
    XCTAssertNoThrow(try allInfo.exitReason.throwIfNonZero())
    XCTAssertNil(allInfo.standardError)
    XCTAssertEqual(ByteBuffer(repeating: 0, count: 1024 * 1024), allInfo.standardOutput)
  }

  func testCollectJustStandardError() async throws {
    let allInfo = try await ProcessExecutor.runCollectingOutput(
      group: self.group,
      executable: "/bin/sh", ["-c", "/bin/dd >&2 if=/dev/zero bs=\(1024 * 1024) count=1 status=none"],
      standardInput: EOFSequence(),
      collectStandardOutput: false,
      collectStandardError: true,
      perStreamCollectionLimitBytes: 1024 * 1024,
      logger: self.logger
    )
    XCTAssertNoThrow(try allInfo.exitReason.throwIfNonZero())
    XCTAssertNil(allInfo.standardOutput)
    XCTAssertEqual(ByteBuffer(repeating: 0, count: 1024 * 1024), allInfo.standardError)
  }

  func testCollectNothing() async throws {
    let allInfo = try await ProcessExecutor.runCollectingOutput(
      group: self.group,
      executable: "/bin/sh", ["-c", "/bin/dd >&2 if=/dev/zero bs=\(1024 * 1024) count=100 status=none"],
      standardInput: EOFSequence(),
      collectStandardOutput: false,
      collectStandardError: false,
      perStreamCollectionLimitBytes: 1024 * 1024,
      logger: self.logger
    )
    XCTAssertNoThrow(try allInfo.exitReason.throwIfNonZero())
    XCTAssertNil(allInfo.standardOutput)
    XCTAssertNil(allInfo.standardError)
  }

  func testCollectStdOutAndErr() async throws {
    let allInfo = try await ProcessExecutor.runCollectingOutput(
      group: self.group,
      executable: "/bin/sh",
      [
        "-c",
        """
        /bin/dd >&2 if=/dev/zero bs=\(1024 * 1024) count=1 status=none;
        /bin/dd if=/dev/zero bs=100 count=1 status=none;
        """,
      ],
      standardInput: EOFSequence(),
      collectStandardOutput: true,
      collectStandardError: true,
      perStreamCollectionLimitBytes: 1024 * 1024,
      logger: self.logger
    )
    XCTAssertNoThrow(try allInfo.exitReason.throwIfNonZero())
    XCTAssertEqual(ByteBuffer(repeating: 0, count: 1024 * 1024), allInfo.standardError)
    XCTAssertEqual(ByteBuffer(repeating: 0, count: 100), allInfo.standardOutput)
  }

  func testTooMuchToCollectStdout() async throws {
    do {
      let result = try await ProcessExecutor.runCollectingOutput(
        group: self.group,
        executable: "/bin/dd", ["if=/dev/zero", "bs=\(1024 * 1024)", "count=1"],
        standardInput: EOFSequence(),
        collectStandardOutput: true,
        collectStandardError: false,
        perStreamCollectionLimitBytes: 1024 * 1024 - 1,
        logger: self.logger
      )
      XCTFail("should've thrown but got result: \(result)")
    } catch {
      XCTAssertTrue(error is ProcessExecutor.TooMuchProcessOutputError)
      XCTAssertEqual(
        ProcessOutputStream.standardOutput,
        (error as? ProcessExecutor.TooMuchProcessOutputError)?.stream
      )
    }
  }

  func testTooMuchToCollectStderr() async throws {
    do {
      let result = try await ProcessExecutor.runCollectingOutput(
        group: self.group,
        executable: "/bin/dd",
        ["if=/dev/zero", "bs=\(1024 * 1024)", "of=/dev/stderr", "count=1", "status=none"],
        standardInput: EOFSequence(),
        collectStandardOutput: false,
        collectStandardError: true,
        perStreamCollectionLimitBytes: 1024 * 1024 - 1,
        logger: self.logger
      )
      XCTFail("should've thrown but got result: \(result)")
    } catch {
      XCTAssertTrue(error is ProcessExecutor.TooMuchProcessOutputError)
      XCTAssertEqual(
        ProcessOutputStream.standardError,
        (error as? ProcessExecutor.TooMuchProcessOutputError)?.stream
      )
    }
  }

  func testCollectEmptyStringFromStdoutAndErr() async throws {
    let allInfo = try await ProcessExecutor.runCollectingOutput(
      group: self.group,
      executable: "/bin/sh",
      ["-c", ""],
      standardInput: EOFSequence(),
      collectStandardOutput: true,
      collectStandardError: true,
      perStreamCollectionLimitBytes: 1024 * 1024,
      logger: self.logger
    )
    XCTAssertNoThrow(try allInfo.exitReason.throwIfNonZero())
    XCTAssertEqual(ByteBuffer(), allInfo.standardError)
    XCTAssertEqual(ByteBuffer(), allInfo.standardOutput)
  }

  func testExecutableDoesNotExist() async throws {
    let exe = ProcessExecutor(
      group: self.group,
      executable: "/dev/null/does/not/exist",
      [],
      standardInput: EOFSequence(),
      standardOutput: .discard,
      standardError: .discard,
      logger: self.logger
    )
    do {
      let result = try await exe.run()
      XCTFail("got result for bad executable: \(result)")
    } catch {
      XCTAssertEqual(NSCocoaErrorDomain, (error as NSError).domain, "\(error)")
      // https://github.com/apple/swift-corelibs-foundation/issues/4810
      XCTAssertEqual(NSFileNoSuchFileError, (error as NSError).code, "\(error)")
    }
  }

  func testAPIsWithoutELGOrLoggerArguments() async throws {
    let exe = ProcessExecutor(
      executable: "/bin/sh", ["-c", "true"],
      standardInput: EOFSequence(),
      standardOutput: .discard,
      standardError: .discard
    )
    try await exe.run().throwIfNonZero()

    try await ProcessExecutor.run(
      executable: "/bin/sh", ["-c", "true"],
      standardInput: EOFSequence()
    ).throwIfNonZero()

    try await ProcessExecutor.runCollectingOutput(
      executable: "/bin/sh",
      ["-c", "true"],
      standardInput: EOFSequence(),
      collectStandardOutput: false,
      collectStandardError: false
    ).exitReason.throwIfNonZero()

    try await ProcessExecutor.runProcessingOutput(
      executable: "/bin/sh",
      ["-c", "true"],
      standardInput: EOFSequence()
    ) { _, _ in
    }.throwIfNonZero()

    try await ProcessExecutor.runLogOutput(
      executable: "/bin/sh",
      ["-c", "true"],
      standardInput: EOFSequence(),
      logger: self.logger,
      logConfiguration: .init(logLevel: .critical, to: .logMessage)
    ).throwIfNonZero()
  }

  func testAPIsWithoutELGStandardInputOrLoggerArguments() async throws {
    let exe = ProcessExecutor(
      executable: "/bin/sh", ["-c", "true"],
      standardOutput: .discard,
      standardError: .discard
    )
    try await exe.run().throwIfNonZero()

    let exeStream = ProcessExecutor(executable: "/bin/sh", ["-c", "true"])
    #if compiler(>=5.8)
    async let stdout = Array(exeStream.standardOutput)
    async let stderr = Array(exeStream.standardError)
    #else
    async let stdout = {
      var chunks: [ByteBuffer] = []
      for try await chunk in await exeStream.standardOutput {
        chunks.append(chunk)
      }
      return chunks
    }()
    async let stderr = {
      var chunks: [ByteBuffer] = []
      for try await chunk in await exeStream.standardError {
        chunks.append(chunk)
      }
      return chunks
    }()
    #endif
    try await exeStream.run().throwIfNonZero()
    let out = try await stdout
    let err = try await stderr
    XCTAssertEqual([], out)
    XCTAssertEqual([], err)

    try await ProcessExecutor.run(executable: "/bin/sh", ["-c", "true"]).throwIfNonZero()

    try await ProcessExecutor.runCollectingOutput(
      executable: "/bin/sh",
      ["-c", "true"],
      collectStandardOutput: false,
      collectStandardError: false
    ).exitReason.throwIfNonZero()

    try await ProcessExecutor.runProcessingOutput(executable: "/bin/sh", ["-c", "true"]) { _, _ in
    }.throwIfNonZero()

    try await ProcessExecutor.runLogOutput(
      executable: "/bin/sh",
      ["-c", "true"],
      logger: self.logger,
      logConfiguration: .init(logLevel: .critical, to: .logMessage)
    ).throwIfNonZero()
  }

  func testStdoutAndStderrToSameFileWorks() async throws {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("AsyncProcessTests-\(getpid())-\(UUID())")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: false)
    defer {
      XCTAssertNoThrow(try FileManager.default.removeItem(at: tempDir))
    }

    for (stdoutMode, stderrMode) in [("shared", "shared"), ("shared", "owned"), ("owned", "shared")] {
      let filePath = tempDir.appendingPathComponent("file-\(stdoutMode)-\(stderrMode)")
      let fd = try FileDescriptor.open(
        .init(filePath.path.removingPercentEncoding!),
        .writeOnly,
        options: .create,
        permissions: [.ownerRead, .ownerWrite]
      )
      defer {
        if stdoutMode == "shared" && stderrMode == "shared" {
          XCTAssertNoThrow(try fd.close())
        }
      }

      let stdout: ProcessOutput
      let stderr: ProcessOutput

      if stdoutMode == "owned" {
        stdout = .fileDescriptor(takingOwnershipOf: fd)
      } else {
        stdout = .fileDescriptor(sharing: fd)
      }
      if stderrMode == "owned" {
        stderr = .fileDescriptor(takingOwnershipOf: fd)
      } else {
        stderr = .fileDescriptor(sharing: fd)
      }

      let command =
        "for o in 1 2; do i=1000; while [ $i -gt 0 ]; do echo $o >&$o; i=$(( $i - 1 )); done & done; wait"
      let exe = ProcessExecutor(
        group: self.group,
        executable: "/bin/sh",
        ["-c", command],
        standardInput: EOFSequence(),
        standardOutput: stdout,
        standardError: stderr,
        logger: self.logger
      )
      try await exe.run().throwIfNonZero()
      let actualOutput = try Data(contentsOf: filePath)
      XCTAssertEqual(4000, actualOutput.count, "\(stdoutMode)-\(stderrMode)")

      var expectedOutput = Data()
      expectedOutput.append(Data(repeating: UInt8(ascii: "\n"), count: 2000))
      expectedOutput.append(Data(repeating: UInt8(ascii: "1"), count: 1000))
      expectedOutput.append(Data(repeating: UInt8(ascii: "2"), count: 1000))
      XCTAssertEqual(expectedOutput, Data(actualOutput.sorted()), "\(stdoutMode)-\(stderrMode)")
    }
  }

  func testCanReliablyKillProcessesEvenWithSigmask() async throws {
    let exitReason = try await withThrowingTaskGroup(
      of: ProcessExitReason?.self,
      returning: ProcessExitReason.self
    ) { group in
      group.addTask {
        try await ProcessExecutor.run(
          executable: "/bin/sh",
          ["-c", "trap 'echo no' TERM; while true; do sleep 1; done"]
        )
      }
      group.addTask {
        try? await Task.sleep(nanoseconds: 10_000_000)
        return nil
      }

      while let result = try await group.next() {
        group.cancelAll()
        if let result {
          return result
        }
      }
      preconditionFailure("this should be impossible, task should've returned a result")
    }
    XCTAssertEqual(.signal(SIGKILL), exitReason)
  }

  func testCancelProcessVeryEarlyOnStressTest() async throws {
    for i in 0..<100 {
      self.logger.debug("iteration go", metadata: ["iteration-number": "\(i)"])
      let exitReason = try await withThrowingTaskGroup(
        of: ProcessExitReason?.self,
        returning: ProcessExitReason.self
      ) { group in
        group.addTask { [logger = self.logger!] in
          try await ProcessExecutor.run(
            executable: "/bin/sleep", ["100000"],
            logger: logger
          )
        }
        group.addTask { [logger = self.logger!] in
          let waitNS = UInt64.random(in: 0..<10_000_000)
          logger.info("waiting", metadata: ["wait-ns": "\(waitNS)"])
          try? await Task.sleep(nanoseconds: waitNS)
          return nil
        }

        while let result = try await group.next() {
          group.cancelAll()
          if let result {
            return result
          }
        }
        preconditionFailure("this should be impossible, task should've returned a result")
      }
      XCTAssertEqual(.signal(SIGKILL), exitReason, "iteration \(i)")
    }
  }

  func testShortestManuallyMergedOutput() async throws {
    let exe = ProcessExecutor(executable: "/bin/bash", ["-c", "echo hello world"])
    async let result = exe.run()
    let lines = try await Array(
      merge(exe.standardOutput.splitIntoLines(), exe.standardError.splitIntoLines()).strings
    )
    XCTAssertEqual(["hello world"], lines)
    try await result.throwIfNonZero()
  }

  func testShortestJustGiveMeTheOutput() async throws {
    let result = try await ProcessExecutor.runCollectingOutput(
      executable: "/bin/bash",
      ["-c", "echo hello world"],
      collectStandardOutput: true,
      collectStandardError: true
    )
    XCTAssertEqual("hello world\n", result.standardOutput.map { String(buffer: $0) })
    XCTAssertEqual("", result.standardError.map { String(buffer: $0) })
    XCTAssertEqual(.exit(0), result.exitReason)
  }

  func testKillProcess() async throws {
    let p = ProcessExecutor(
      executable: "/bin/bash",
      ["-c", "while true; do echo A; sleep 1; done"],
      standardError: .discard
    )
    async let result = p.run()
    var outputIterator = await p.standardOutput.makeAsyncIterator()
    let firstChunk = try await outputIterator.next()
    XCTAssertEqual(UInt8(ascii: "A"), firstChunk?.readableBytesView.first)
    try await p.sendSignal(SIGKILL)
    let finalResult = try await result
    XCTAssertEqual(.signal(SIGKILL), finalResult)
    while try await outputIterator.next() != nil {}
  }

  func testCanDealWithRunawayChildProcesses() async throws {
    self.logger = Logger(label: "x")
    self.logger.logLevel = .info
    let p = ProcessExecutor(
      executable: "/bin/bash",
      [
        "-c",
        """
        set -e
        /usr/bin/yes "Runaway process from \(#function), please file a swift-async-process bug." > /dev/null &
        child_pid=$!
        trap "echo >&2 killing $child_pid; kill -KILL $child_pid" INT
        echo "$child_pid" # communicate the child pid to our parent
        exec >&- # close stdout
        echo "waiting for $child_pid" >&2
        wait
        """,
      ],
      standardError: .discard,
      teardownSequence: [
        .sendSignal(SIGINT, allowedTimeToExitNS: 10_000_000_000),
      ],
      logger: self.logger
    )

    try await withThrowingTaskGroup(of: pid_t?.self) { group in
      group.addTask {
        let result = try await p.run()
        XCTAssertEqual(.exit(128 + SIGINT), result)
        return nil
      }

      group.addTask {
        let pidString = try await String(buffer: p.standardOutput.pullAllOfIt())
        guard let pid = pid_t(pidString.dropLast()) else {
          XCTFail("couldn't get pid from \(pidString)")
          return nil
        }
        return pid
      }

      let maybePid = try await group.next()!
      let pid = try XCTUnwrap(maybePid)
      group.cancelAll()
      try await group.waitForAll()

      // Let's check that the subprocess (/usr/bin/yes) of our subprocess (/bin/bash) is actually dead
      // This is a tiny bit racy because the pid isn't immediately invalidated, so let's allow a few failures
      for attempt in 0 ..< .max {
        let killRet = kill(pid, 0)
        let errnoCode = errno
        guard killRet == -1 || attempt > 5 else {
          self.logger.error("kill didn't fail on attempt \(attempt), trying again...")
          usleep(100_000)
          continue
        }
        XCTAssertEqual(-1, killRet)
        XCTAssertEqual(ESRCH, errnoCode)
        break
      }
    }
  }

  func testShutdownSequenceWorks() async throws {
    let p = ProcessExecutor(
      executable: "/bin/bash",
      [
        "-c",
        """
        set -e
        trap 'echo saw SIGQUIT; echo >&2 saw SIGQUIT' QUIT
        trap 'echo saw SIGTERM; echo >&2 saw SIGTERM' TERM
        trap 'echo saw SIGINT; echo >&2 saw SIGINT; exit 3;' INT
        echo OK
        while true; do sleep 0.1; done
        exit 2
        """,
      ],
      standardError: .discard,
      teardownSequence: [
        .sendSignal(SIGQUIT, allowedTimeToExitNS: 200_000_000),
        .sendSignal(SIGTERM, allowedTimeToExitNS: 200_000_000),
        .sendSignal(SIGINT, allowedTimeToExitNS: 1_000_000_000),
      ],
      logger: self.logger
    )

    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        let result = try await p.run()
        XCTAssertEqual(.exit(3), result)
      }
      var allLines: [String] = []
      for try await line in await p.standardOutput.splitIntoLines().strings {
        if line == "OK" {
          group.cancelAll()
        }
        allLines.append(line)
      }
      try await group.waitForAll()
      XCTAssertEqual(["OK", "saw SIGQUIT", "saw SIGTERM", "saw SIGINT"], allLines)
    }
  }

  // MARK: - Setup/teardown

  override func setUp() async throws {
    fflush(stdout)
    fflush(stderr)
    self.group = MultiThreadedEventLoopGroup(numberOfThreads: 3)
    self.logger = Logger(label: "test", factory: { _ in SwiftLogNoOpLogHandler() })

    // Make sure the singleton threads have booted (because they use file descriptors)
    try await MultiThreadedEventLoopGroup.singleton.next().submit {}.get()
    self.highestFD = highestOpenFD()
  }

  override func tearDown() {
    let highestFD = highestOpenFD()
    XCTAssertEqual(self.highestFD, highestFD, "\(blockingLSOFMyself())")
    self.highestFD = nil
    self.logger = nil

    XCTAssertNoThrow(try self.group.syncShutdownGracefully())
    self.group = nil
    fflush(stdout)
    fflush(stderr)
  }
}

extension AsyncStream {
  static func justMakeIt(elementType: Element.Type = Element.self) -> (
    consumer: AsyncStream<Element>, producer: AsyncStream<Element>.Continuation
  ) {
    var _producer: AsyncStream<Element>.Continuation?
    let stream = AsyncStream { producer in
      _producer = producer
    }

    return (stream, _producer!)
  }
}

extension AsyncSequence where Element == ByteBuffer {
  func pullAllOfIt() async throws -> ByteBuffer {
    var buffer: ByteBuffer? = nil
    for try await chunk in self {
      buffer.setOrWriteImmutableBuffer(chunk)
    }
    return buffer ?? ByteBuffer()
  }
}

extension ProcessExecutor {
  struct AllOfAProcess: Sendable {
    var exitReason: ProcessExitReason
    var standardOutput: ByteBuffer
    var standardError: ByteBuffer
  }

  private enum What {
    case exit(ProcessExitReason)
    case stdout(ByteBuffer)
    case stderr(ByteBuffer)
  }

  func runGetAllOutput() async throws -> AllOfAProcess {
    try await withThrowingTaskGroup(of: What.self, returning: AllOfAProcess.self) { group in
      group.addTask {
        try await .exit(self.run())
      }
      group.addTask {
        try await .stdout(self.standardOutput.pullAllOfIt())
      }
      group.addTask {
        try await .stderr(self.standardError.pullAllOfIt())
      }

      var exitReason: ProcessExitReason?
      var stdout: ByteBuffer?
      var stderr: ByteBuffer?

      while let next = try await group.next() {
        switch next {
        case let .exit(value):
          exitReason = value
        case let .stderr(value):
          stderr = value
        case let .stdout(value):
          stdout = value
        }
      }

      return AllOfAProcess(exitReason: exitReason!, standardOutput: stdout!, standardError: stderr!)
    }
  }
}

private func highestOpenFD() -> CInt? {
  #if os(macOS)
  guard let dirPtr = opendir("/dev/fd") else {
    return nil
  }
  #elseif os(Linux)
  guard let dirPtr = opendir("/proc/self/fd") else {
    return nil
  }
  #else
  return nil
  #endif
  defer {
    closedir(dirPtr)
  }
  var highestFDSoFar = CInt(0)

  while let dirEntPtr = readdir(dirPtr) {
    var entryName = dirEntPtr.pointee.d_name
    let thisFD = withUnsafeBytes(of: &entryName) { entryNamePtr -> CInt? in

      CInt(String(decoding: entryNamePtr.prefix(while: { $0 != 0 }), as: Unicode.UTF8.self))
    }
    highestFDSoFar = max(thisFD ?? -1, highestFDSoFar)
  }

  return highestFDSoFar
}

private func blockingLSOFMyself() -> String {
  let box = NIOLockedValueBox<String>("n/a")
  let sem = DispatchSemaphore(value: 0)
  Task {
    defer {
      sem.signal()
    }
    do {
      #if canImport(Darwin)
      let lsofPath = "/usr/sbin/lsof"
      #else
      let lsofPath = "/usr/bin/lsof"
      #endif
      let result = try await ProcessExecutor.runCollectingOutput(
        executable: lsofPath,
        ["-Pnp", "\(getpid())"],
        collectStandardOutput: true,
        collectStandardError: true
      )
      let outString = """
      exit code: \(result.exitReason)\n
      ## stdout
      \(String(buffer: result.standardOutput!))

      ## stderr
      \(String(buffer: result.standardError!))

      """
      box.withLockedValue { $0 = outString }
    } catch {
      box.withLockedValue { debugString in
        debugString = "ERROR: \(error)"
      }
    }
  }
  _ = sem.wait(timeout: .now() + 3)
  return box.withLockedValue { $0 }
}
