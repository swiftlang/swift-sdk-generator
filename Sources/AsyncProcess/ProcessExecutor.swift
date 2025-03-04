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

import AsyncAlgorithms
import Atomics
import Logging
import NIO
import ProcessSpawnSync

@_exported import struct SystemPackage.FileDescriptor

#if os(Linux) || ASYNC_PROCESS_FORCE_PS_PROCESS
// Foundation.Process is too buggy on Linux
//
// - Foundation.Process on Linux throws error Error Domain=NSCocoaErrorDomain Code=256 "(null)" if executable not found
//   https://github.com/swiftlang/swift-corelibs-foundation/issues/4810
// - Foundation.Process on Linux doesn't correctly detect when child process dies (creating zombie processes)
//   https://github.com/swiftlang/swift-corelibs-foundation/issues/4795
// - Foundation.Process on Linux seems to inherit the Process.run()-calling thread's signal mask, even SIGTERM blocked
//   https://github.com/swiftlang/swift-corelibs-foundation/issues/4772
typealias Process = PSProcess
#endif

#if os(iOS) || os(tvOS) || os(watchOS)
// Note: Process() in iOS/tvOS/watchOS is available in internal builds only under Foundation Private/headers
import Foundation_Private.NSTask
#else
import Foundation
#endif

public struct ProcessOutputStream: Sendable & Hashable & CustomStringConvertible {
  enum Backing {
    case standardOutput
    case standardError
  }

  var backing: Backing

  public static let standardOutput: Self = .init(backing: .standardOutput)

  public static let standardError: Self = .init(backing: .standardError)

  public var description: String {
    switch self.backing {
    case .standardOutput:
      return "stdout"
    case .standardError:
      return "stderr"
    }
  }
}

/// What to do with a given stream (`stdout`/`stderr`) in the spawned child process.
public struct ProcessOutput: Sendable {
  enum Backing {
    case discard
    case inherit
    case fileDescriptorOwned(FileDescriptor)
    case fileDescriptorShared(FileDescriptor)
    case stream
  }

  var backing: Backing

  /// Discard the child process' output.
  ///
  /// This will set the process' stream to `/dev/null`.
  public static let discard: Self = .init(backing: .discard)

  /// Inherit the same file description from the parent process (i.e. this process).
  public static let inherit: Self = .init(backing: .inherit)

  /// Take ownership of `fd` and install that as the child process' file descriptor.
  ///
  /// You may use the same `fd` with `.fileDescriptor(takingOwnershipOf: fd)` and `.fileDescriptor(sharing: fd)` at
  /// the same time. For example to redirect standard output and standard error into the same file.
  ///
  /// - warning: After passing a `FileDescriptor` to this method you _must not_ perform _any_ other operations on it.
  public static func fileDescriptor(takingOwnershipOf fd: FileDescriptor) -> Self {
    .init(backing: .fileDescriptorOwned(fd))
  }

  /// Install `fd` as the child process' file descriptor, leaving the fd ownership with the user.
  ///
  /// You may use the same `fd` with `.fileDescriptor(takingOwnershipOf: fd)` and `.fileDescriptor(sharing: fd)` at
  /// the same time. For example to redirect standard output and standard error into the same file.
  ///
  /// - note: `fd` is required to be closed by the user after the process has started running (and _not_ before).
  public static func fileDescriptor(sharing fd: FileDescriptor) -> Self {
    .init(backing: .fileDescriptorShared(fd))
  }

  /// Stream this using the ``ProcessExecutor.standardOutput`` / ``ProcessExecutor.standardError`` ``AsyncStream``s.
  ///
  /// If you select `.stream`, you _must_ consume the stream. This is back-pressured into the child which means that
  /// if you fail to consume the child might get blocked producing its output.
  public static let stream: Self = .init(backing: .stream)
}

private struct OutputConsumptionState: OptionSet {
  typealias RawValue = UInt8

  var rawValue: UInt8

  init(rawValue: UInt8) {
    self.rawValue = rawValue
  }

  static let stdoutConsumed: Self = .init(rawValue: 0b0001)
  static let stderrConsumed: Self = .init(rawValue: 0b0010)
  static let stdoutNotStreamed: Self = .init(rawValue: 0b0100)
  static let stderrNotStreamed: Self = .init(rawValue: 0b1000)

  var hasStandardOutputBeenConsumed: Bool {
    self.contains([.stdoutConsumed])
  }

  var hasStandardErrorBeenConsumed: Bool {
    self.contains([.stderrConsumed])
  }

  var isStandardOutputStremed: Bool {
    !self.contains([.stdoutNotStreamed])
  }

  var isStandardErrorStremed: Bool {
    !self.contains([.stderrNotStreamed])
  }
}

/// Type-erasing type analogous to `AnySequence` from the Swift standard library.
private struct AnyAsyncSequence<Element>: AsyncSequence & Sendable where Element: Sendable {
  private let iteratorFactory: @Sendable () -> AsyncIterator

  init<S: AsyncSequence & Sendable>(_ asyncSequence: S) where S.Element == Element {
    self.iteratorFactory = {
      var iterator = asyncSequence.makeAsyncIterator()
      return AsyncIterator { try await iterator.next() }
    }
  }

  struct AsyncIterator: AsyncIteratorProtocol {
    let underlying: () async throws -> Element?

    func next() async throws -> Element? {
      try await self.underlying()
    }
  }

  func makeAsyncIterator() -> AsyncIterator {
    self.iteratorFactory()
  }
}

/// Execute a sub-process.
///
/// - warning: Currently, the default for `standardOutput` & `standardError` is ``ProcessOutput.stream`` which means
///            you _must_ consume ``ProcessExecutor.standardOutput`` & ``ProcessExecutor.standardError``. If you prefer
///            to not consume it, please set them to ``ProcessOutput.discard`` explicitly.
public final actor ProcessExecutor {
  private let logger: Logger
  private let group: EventLoopGroup
  private let executable: String
  private let arguments: [String]
  private let environment: [String: String]
  private let standardInput: AnyAsyncSequence<ByteBuffer>
  private let standardInputPipe: Pipe?
  private let standardOutputWriteHandle: FileHandle?
  private let standardErrorWriteHandle: FileHandle?
  private let _standardOutput: ChunkSequence
  private let _standardError: ChunkSequence
  private let processIsRunningApproximation = ManagedAtomic(RunningStateApproximation.neverStarted.rawValue)
  private let processOutputConsumptionApproximation = ManagedAtomic(UInt8(0))
  private let processPid = ManagedAtomic(pid_t(0))
  private let ownsStandardOutputWriteHandle: Bool
  private let ownsStandardErrorWriteHandle: Bool
  private let teardownSequence: TeardownSequence

  public struct OSError: Error & Sendable & Hashable {
    public var errnoNumber: CInt
    public var function: String
  }

  /// An ordered list of steps in order to tear down a process.
  ///
  /// Always ends in sending a `SIGKILL` whether that's specified or not.
  public struct TeardownSequence: Sendable, ExpressibleByArrayLiteral, CustomStringConvertible {
    public typealias ArrayLiteralElement = TeardownStep

    public init(arrayLiteral elements: TeardownStep...) {
      self.steps = (elements.map(\.backing)) + [.kill]
    }

    public struct TeardownStep: Sendable {
      var backing: Backing

      enum Backing {
        case sendSignal(CInt, allowedTimeNS: UInt64)
        case kill
      }

      /// Send `signal` to process and give it `allowedTimeToExitNS` nanoseconds to exit before progressing
      /// to the next teardown step. The final teardown step is always sending a `SIGKILL`.
      public static func sendSignal(_ signal: CInt, allowedTimeToExitNS: UInt64) -> Self {
        Self(backing: .sendSignal(signal, allowedTimeNS: allowedTimeToExitNS))
      }
    }

    var steps: [TeardownStep.Backing] = [.kill]

    public var description: String {
      self.steps.map { "\($0)" }.joined(separator: ", ")
    }
  }

  public var standardOutput: ChunkSequence {
    let afterValue = self.processOutputConsumptionApproximation.bitwiseXorThenLoad(
      with: OutputConsumptionState.stdoutConsumed.rawValue,
      ordering: .relaxed
    )
    precondition(
      OutputConsumptionState(rawValue: afterValue).contains([.stdoutConsumed]),
      "Double-consumption of stdandardOutput"
    )
    return self._standardOutput
  }

  public var standardError: ChunkSequence {
    let afterValue = self.processOutputConsumptionApproximation.bitwiseXorThenLoad(
      with: OutputConsumptionState.stderrConsumed.rawValue,
      ordering: .relaxed
    )
    precondition(
      OutputConsumptionState(rawValue: afterValue).contains([.stderrConsumed]),
      "Double-consumption of stdandardEror"
    )
    return self._standardError
  }

  private enum RunningStateApproximation: Int {
    case neverStarted = 1
    case running = 2
    case finishedExecuting = 3
  }

  /// Create a ``ProcessExecutor`` to spawn a single child process.
  ///
  /// - note: The `environment` defaults to the empty environment.
  ///
  /// - Parameters:
  ///   - group: The `EventLoopGroup` to run the I/O on
  ///   - executable: The full path to the executable to spawn
  ///   - arguments: The arguments to the executable (not including `argv[0]`)
  ///   - environment: The environment variables to pass to the child process.
  ///                  If you want to inherit the calling process' environment into the child, specify
  /// `ProcessInfo.processInfo.environment`
  ///   - standardInput: An `AsyncSequence` providing the standard input, pass `EOFSequence(of: ByteBuffer.self)` if you
  /// don't want to
  ///                    provide input.
  ///   - standardOutput: A description of what to do with the standard output of the child process (defaults to
  /// ``ProcessOutput/stream``
  ///                     which requires to consume it via ``ProcessExecutor/standardOutput``.
  ///   - standardError: A description of what to do with the standard output of the child process (defaults to
  /// ``ProcessOutput/stream``
  ///                    which requires to consume it via ``ProcessExecutor/standardError``.
  ///   - teardownSequence: What to do if ``ProcessExecutor`` needs to tear down the process abruptly
  ///                       (usually because of Swift Concurrency cancellation)
  ///   - logger: Where to log diagnostic messages to (default to no where)
  public init<StandardInput: AsyncSequence & Sendable>(
    group: EventLoopGroup = ProcessExecutor.defaultEventLoopGroup,
    executable: String,
    _ arguments: [String],
    environment: [String: String] = [:],
    standardInput: StandardInput,
    standardOutput: ProcessOutput = .stream,
    standardError: ProcessOutput = .stream,
    teardownSequence: TeardownSequence = TeardownSequence(),
    logger: Logger = ProcessExecutor.disableLogging
  ) where StandardInput.Element == ByteBuffer {
    self.group = group
    self.executable = executable
    self.environment = environment
    self.arguments = arguments
    self.standardInput = AnyAsyncSequence(standardInput)
    self.logger = logger
    self.teardownSequence = teardownSequence

    self.standardInputPipe = StandardInput.self == EOFSequence<ByteBuffer>.self ? nil : Pipe()

    switch standardOutput.backing {
    case .discard:
      _ = self.processOutputConsumptionApproximation.bitwiseXorThenLoad(
        with: OutputConsumptionState.stdoutNotStreamed.rawValue,
        ordering: .relaxed
      )
      self.ownsStandardOutputWriteHandle = true
      self.standardOutputWriteHandle = FileHandle(forWritingAtPath: "/dev/null")
      self._standardOutput = ChunkSequence(takingOwnershipOfFileHandle: nil, group: group)
    case let .fileDescriptorOwned(fd):
      _ = self.processOutputConsumptionApproximation.bitwiseXorThenLoad(
        with: OutputConsumptionState.stdoutNotStreamed.rawValue,
        ordering: .relaxed
      )
      self.ownsStandardOutputWriteHandle = true
      self.standardOutputWriteHandle = FileHandle(fileDescriptor: fd.rawValue)
      self._standardOutput = ChunkSequence(takingOwnershipOfFileHandle: nil, group: group)
    case let .fileDescriptorShared(fd):
      _ = self.processOutputConsumptionApproximation.bitwiseXorThenLoad(
        with: OutputConsumptionState.stdoutNotStreamed.rawValue,
        ordering: .relaxed
      )
      self.ownsStandardOutputWriteHandle = false
      self.standardOutputWriteHandle = FileHandle(fileDescriptor: fd.rawValue)
      self._standardOutput = ChunkSequence(takingOwnershipOfFileHandle: nil, group: group)
    case .inherit:
      _ = self.processOutputConsumptionApproximation.bitwiseXorThenLoad(
        with: OutputConsumptionState.stdoutNotStreamed.rawValue,
        ordering: .relaxed
      )
      self.ownsStandardOutputWriteHandle = true
      self.standardOutputWriteHandle = nil
      self._standardOutput = ChunkSequence(takingOwnershipOfFileHandle: nil, group: group)
    case .stream:
      let (stdoutSequence, stdoutWriteHandle) = Self.makeWriteStream(group: group)
      self.ownsStandardOutputWriteHandle = true
      self._standardOutput = stdoutSequence
      self.standardOutputWriteHandle = stdoutWriteHandle
    }

    switch standardError.backing {
    case .discard:
      _ = self.processOutputConsumptionApproximation.bitwiseXorThenLoad(
        with: OutputConsumptionState.stderrNotStreamed.rawValue,
        ordering: .relaxed
      )
      self.ownsStandardErrorWriteHandle = true
      self.standardErrorWriteHandle = FileHandle(forWritingAtPath: "/dev/null")
      self._standardError = ChunkSequence(takingOwnershipOfFileHandle: nil, group: group)
    case let .fileDescriptorOwned(fd):
      _ = self.processOutputConsumptionApproximation.bitwiseXorThenLoad(
        with: OutputConsumptionState.stderrNotStreamed.rawValue,
        ordering: .relaxed
      )
      self.ownsStandardErrorWriteHandle = true
      self.standardErrorWriteHandle = FileHandle(fileDescriptor: fd.rawValue)
      self._standardError = ChunkSequence(takingOwnershipOfFileHandle: nil, group: group)
    case let .fileDescriptorShared(fd):
      _ = self.processOutputConsumptionApproximation.bitwiseXorThenLoad(
        with: OutputConsumptionState.stderrNotStreamed.rawValue,
        ordering: .relaxed
      )
      self.ownsStandardErrorWriteHandle = false
      self.standardErrorWriteHandle = FileHandle(fileDescriptor: fd.rawValue)
      self._standardError = ChunkSequence(takingOwnershipOfFileHandle: nil, group: group)
    case .inherit:
      _ = self.processOutputConsumptionApproximation.bitwiseXorThenLoad(
        with: OutputConsumptionState.stderrNotStreamed.rawValue,
        ordering: .relaxed
      )
      self.ownsStandardErrorWriteHandle = true
      self.standardErrorWriteHandle = nil
      self._standardError = ChunkSequence(takingOwnershipOfFileHandle: nil, group: group)
    case .stream:
      let (stdoutSequence, stdoutWriteHandle) = Self.makeWriteStream(group: group)
      self.ownsStandardErrorWriteHandle = true
      self._standardError = stdoutSequence
      self.standardErrorWriteHandle = stdoutWriteHandle
    }
  }

  private static func makeWriteStream(group: EventLoopGroup) -> (ChunkSequence, FileHandle) {
    let pipe = Pipe()
    let chunkSequence = ChunkSequence(
      takingOwnershipOfFileHandle: pipe.fileHandleForReading,
      group: group
    )
    let writeHandle = pipe.fileHandleForWriting
    return (chunkSequence, writeHandle)
  }

  deinit {
    let storedPid = self.processPid.load(ordering: .relaxed)
    assert(storedPid == 0 || storedPid == -1)
    let runningState = self.processIsRunningApproximation.load(ordering: .relaxed)
    assert(
      runningState == RunningStateApproximation.finishedExecuting.rawValue,
      """
      Did you create a ProcessExecutor without run()ning it? \
      That's currently illegal: \
      illegal running state \(runningState) in deinit
      """
    )

    let outputConsumptionState = OutputConsumptionState(
      rawValue: self.processOutputConsumptionApproximation.load(ordering: .relaxed)
    )
    assert(
      { () -> Bool in
        guard
          outputConsumptionState.contains([.stdoutConsumed])
          || outputConsumptionState.contains([.stdoutNotStreamed])
        else {
          return false
        }

        guard
          outputConsumptionState.contains([.stderrConsumed])
          || outputConsumptionState.contains([.stderrNotStreamed])
        else {
          return false
        }
        return true
      }(),
      """
      Did you create a ProcessExecutor with standardOutput/standardError in `.stream.` mode without
      then consuming it? \
      That's currently illegal. If you do not want to consume the output, consider `.discard`int it: \
      illegal output consumption state \(outputConsumptionState) in deinit
      """
    )
  }

  private func teardown(process: Process) async {
    let childPid = self.processPid.load(ordering: .sequentiallyConsistent)
    guard childPid != 0 else {
      self.logger.warning(
        "leaking Process because it hasn't got a process identifier (likely a Foundation.Process bug)",
        metadata: ["process": "\(process)"]
      )
      return
    }

    var logger = self.logger
    logger[metadataKey: "pid"] = "\(childPid)"

    loop: for step in self.teardownSequence.steps {
      if process.isRunning {
        logger.trace("running teardown sequence", metadata: ["step": "\(step)"])
        enum TeardownStepCompletion {
          case processHasExited
          case processStillAlive
          case killedTheProcess
        }
        let stepCompletion: TeardownStepCompletion
        switch step {
        case let .sendSignal(signal, allowedTimeNS):
          stepCompletion = await withTaskGroup(of: TeardownStepCompletion.self) { group in
            group.addTask {
              do {
                try await Task.sleep(nanoseconds: allowedTimeNS)
                return .processStillAlive
              } catch {
                return .processHasExited
              }
            }
            try? await self.sendSignal(signal)
            return await group.next()!
          }
        case .kill:
          logger.info("sending SIGKILL to process")
          kill(childPid, SIGKILL)
          stepCompletion = .killedTheProcess
        }
        logger.debug(
          "teardown sequence step complete",
          metadata: ["step": "\(step)", "outcome": "\(stepCompletion)"]
        )
        switch stepCompletion {
        case .processHasExited, .killedTheProcess:
          break loop
        case .processStillAlive:
          () // gotta continue
        }
      } else {
        logger.debug("child process already dead")
        break
      }
    }
  }

  /// Run the process.
  ///
  /// Calling `run()` will run the (sub-)process and return its ``ProcessExitReason`` when the execution completes.
  /// Unless `standardOutput` and `standardError` were both set to ``ProcessOutput/discard``,
  /// ``ProcessOutput/fileDescriptor(takingOwnershipOf:)`` or ``ProcessOutput/inherit`` you must consume the
  /// `AsyncSequence`s
  /// ``ProcessExecutor/standardOutput`` and ``ProcessExecutor/standardError`` concurrently to ``run()``ing the process.
  ///
  /// If you prefer to get the standard output and error in one (non-stremed) piece upon exit, consider the `static`
  /// methods such as
  /// ``ProcessExecutor/runCollectingOutput(group:executable:_:standardInput:collectStandardOutput:collectStandardError:perStreamCollectionLimitBytes:environment:logger:)``.
  public func run() async throws -> ProcessExitReason {
    let p = Process()
    #if canImport(Darwin)
    if #available(macOS 13.0, *) {
      p.executableURL = URL(filePath: self.executable)
    } else {
      p.launchPath = self.executable
    }
    #else
    p.executableURL = URL(fileURLWithPath: self.executable)
    #endif
    p.arguments = self.arguments
    p.environment = self.environment
    p.standardInput = nil

    if let standardOutputWriteHandle = self.standardOutputWriteHandle {
      // NOTE: Do _NOT_ remove this if. Setting this to `nil` is different to not setting it at all!
      p.standardOutput = standardOutputWriteHandle
    }
    if let standardErrorWriteHandle = self.standardErrorWriteHandle {
      // NOTE: Do _NOT_ remove this if. Setting this to `nil` is different to not setting it at all!
      p.standardError = standardErrorWriteHandle
    }
    p.standardInput = self.standardInputPipe

    let (terminationStreamConsumer, terminationStreamProducer) = AsyncStream.justMakeIt(
      elementType: ProcessExitReason.self
    )

    p.terminationHandler = { p in
      let pProcessID = p.processIdentifier
      var terminationPidExchange: (exchanged: Bool, original: pid_t) = (false, -1)
      while !terminationPidExchange.exchanged {
        terminationPidExchange = self.processPid.compareExchange(
          expected: pProcessID,
          desired: -1,
          ordering: .sequentiallyConsistent
        )
        if !terminationPidExchange.exchanged {
          precondition(
            terminationPidExchange.original == 0,
            "termination pid exchange failed: \(terminationPidExchange)"
          )
          Thread.sleep(forTimeInterval: 0.01)
        }
      }
      self.logger.debug(
        "finished running command",
        metadata: [
          "executable": "\(self.executable)",
          "arguments": .array(self.arguments.map { .string($0) }),
          "termination-reason": p.terminationReason == .uncaughtSignal ? "signal" : "exit",
          "termination-status": "\(p.terminationStatus)",
          "pid": "\(p.processIdentifier)",
        ]
      )
      let (worked, original) = self.processIsRunningApproximation.compareExchange(
        expected: RunningStateApproximation.running.rawValue,
        desired: RunningStateApproximation.finishedExecuting.rawValue,
        ordering: .relaxed
      )
      precondition(worked, "illegal running state \(original)")

      for _ in 0..<2 {
        if p.terminationReason == .uncaughtSignal {
          terminationStreamProducer.yield(.signal(p.terminationStatus))
        } else {
          terminationStreamProducer.yield(.exit(p.terminationStatus))
        }
      }
      terminationStreamProducer.finish()
    }

    let (worked, original) = self.processIsRunningApproximation.compareExchange(
      expected: RunningStateApproximation.neverStarted.rawValue,
      desired: RunningStateApproximation.running.rawValue,
      ordering: .relaxed
    )
    precondition(
      worked,
      "Did you run() twice? That's currently not allowed: illegal running state \(original)"
    )
    do {
      try p.run()
    } catch {
      let (worked, original) = self.processIsRunningApproximation.compareExchange(
        expected: RunningStateApproximation.running.rawValue,
        desired: RunningStateApproximation.finishedExecuting.rawValue,
        ordering: .relaxed
      )
      terminationStreamProducer.finish() // The termination handler will never have fired.
      try! self.standardOutputWriteHandle?.close()
      try! self.standardErrorWriteHandle?.close()
      assert(worked) // We just set it to running above, shouldn't be able to race (no `await`).
      assert(original == RunningStateApproximation.running.rawValue) // We compare-and-exchange it.
      throw error
    }

    // At this point, the process is running, we should therefore have a process ID (unless we're already dead).
    let childPid = p.processIdentifier
    let runPidExchange = self.processPid.compareExchange(
      expected: 0,
      desired: childPid,
      ordering: .sequentiallyConsistent
    )
    precondition(runPidExchange.exchanged, "run pid exchange failed: \(runPidExchange)")
    assert(childPid != 0 || !p.isRunning)
    self.logger.debug(
      "running command",
      metadata: [
        "executable": "\(self.executable)",
        "arguments": "\(self.arguments)",
        "pid": "\(p.processIdentifier)",
      ]
    )

    try! self.standardInputPipe?.fileHandleForReading.close() // Must work.
    if self.ownsStandardOutputWriteHandle {
      try! self.standardOutputWriteHandle?.close() // Must work.
    }
    if self.ownsStandardErrorWriteHandle {
      try! self.standardErrorWriteHandle?.close() // Must work.
    }

    @Sendable
    func waitForChildToExit() async -> ProcessExitReason {
      // Please note, we're invoking this function multiple times concurrently, so we're relying on AsyncStream
      // supporting this.

      // We do need for the child to exit (and it will, we'll eventually SIGKILL it)
      await withUncancelledTask(returning: ProcessExitReason.self) {
        var iterator = terminationStreamConsumer.makeAsyncIterator()

        // Let's wait for the process to finish (it will)
        guard let terminationStatus = await iterator.next() else {
          fatalError("terminationStream finished without giving us a result")
        }
        return terminationStatus
      }
    }

    return try await withThrowingTaskGroup(
      of: ProcessExitReason?.self,
      returning: ProcessExitReason.self
    ) { runProcessGroup async throws -> ProcessExitReason in
      runProcessGroup.addTask {
        await withTaskGroup(of: Void.self) { triggerTeardownGroup in
          triggerTeardownGroup.addTask {
            // wait until cancelled
            do { while true {
              try await Task.sleep(nanoseconds: 1_000_000_000)
            } } catch {}

            let isRunning = self.processIsRunningApproximation.load(ordering: .relaxed)
            guard isRunning != RunningStateApproximation.finishedExecuting.rawValue else {
              self.logger.trace("skipping teardown, already finished executing")
              return
            }
            let pid = self.processPid.load(ordering: .relaxed)
            var logger = self.logger
            logger[metadataKey: "pid"] = "\(pid)"
            logger.debug("we got cancelled")
            await withUncancelledTask {
              await withTaskGroup(of: Void.self) { runTeardownStepsGroup in
                runTeardownStepsGroup.addTask {
                  await self.teardown(process: p)
                }
                runTeardownStepsGroup.addTask {
                  _ = await waitForChildToExit()
                }
                await runTeardownStepsGroup.next()!
                runTeardownStepsGroup.cancelAll()
              }
            }
          }

          let result = await waitForChildToExit()
          triggerTeardownGroup.cancelAll() // This triggers the teardown
          return result
        }
      }
      runProcessGroup.addTask {
        if let stdinPipe = self.standardInputPipe {
          let fdForNIO = dup(stdinPipe.fileHandleForWriting.fileDescriptor)
          try! stdinPipe.fileHandleForWriting.close()

          try await NIOAsyncPipeWriter<AnyAsyncSequence<ByteBuffer>>.sinkSequenceInto(
            self.standardInput,
            takingOwnershipOfFD: fdForNIO,
            eventLoop: self.group.any()
          )
        }
        return nil
      }

      var exitReason: ProcessExitReason? = nil
      // cannot fix this warning yet (rdar://113844171)
      while let result = try await runProcessGroup.next() {
        if let result {
          exitReason = result
        }
      }
      return exitReason! // must work because the real task will return a reason (or throw)
    }
  }

  public func sendSignal(_ signal: CInt) async throws {
    let pid = self.processPid.load(ordering: .sequentiallyConsistent)
    if pid == 0 || pid == -1 {
      throw OSError(errnoNumber: ESRCH, function: "sendSignal")
    }
    let ret = kill(pid, signal)
    if ret == -1 {
      throw OSError(errnoNumber: errno, function: "kill")
    }
  }
}

public extension ProcessExecutor {
  /// A globally shared, singleton `EventLoopGroup` that's suitable for ``ProcessExecutor``.
  ///
  /// At present this is always `MultiThreadedEventLoopGroup.singleton`.
  static var defaultEventLoopGroup: any EventLoopGroup {
    globalDefaultEventLoopGroup
  }

  /// The default `Logger` for ``ProcessExecutor`` that's used if you do not override it. It won't log anything.
  static var disableLogging: Logger {
    globalDisableLoggingLogger
  }
}

public extension ProcessExecutor {
  /// Create a ``ProcessExecutor`` to spawn a single child process.
  ///
  /// - note: The `environment` defaults to the empty environment.
  ///
  /// - Parameters:
  ///   - group: The `EventLoopGroup` to run the I/O on
  ///   - executable: The full path to the executable to spawn
  ///   - arguments: The arguments to the executable (not including `argv[0]`)
  ///   - environment: The environment variables to pass to the child process.
  ///                  If you want to inherit the calling process' environment into the child, specify
  /// `ProcessInfo.processInfo.environment`
  ///   - standardOutput: A description of what to do with the standard output of the child process (defaults to
  /// ``ProcessOutput/stream``
  ///                     which requires to consume it via ``ProcessExecutor/standardOutput``.
  ///   - standardError: A description of what to do with the standard output of the child process (defaults to
  /// ``ProcessOutput/stream``
  ///                    which requires to consume it via ``ProcessExecutor/standardError``.
  ///   - logger: Where to log diagnostic messages to (default to no where)
  init(
    group: EventLoopGroup = ProcessExecutor.defaultEventLoopGroup,
    executable: String,
    _ arguments: [String],
    environment: [String: String] = [:],
    standardOutput: ProcessOutput = .stream,
    standardError: ProcessOutput = .stream,
    teardownSequence: TeardownSequence = TeardownSequence(),
    logger: Logger = ProcessExecutor.disableLogging
  ) {
    self.init(
      group: group,
      executable: executable,
      arguments,
      environment: environment,
      standardInput: EOFSequence(),
      standardOutput: standardOutput,
      standardError: standardError,
      teardownSequence: teardownSequence,
      logger: logger
    )
  }
}

private let globalDefaultEventLoopGroup: MultiThreadedEventLoopGroup = .singleton
private let globalDisableLoggingLogger: Logger = .init(
  label: "swift-async-process -- never logs",
  factory: { _ in SwiftLogNoOpLogHandler() }
)

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

func withUncancelledTask<R: Sendable>(
  returning: R.Type = R.self,
  _ body: @Sendable @escaping () async -> R
) async -> R {
  // This looks unstructured but it isn't, please note that we `await` `.value` of this task.
  // The reason we need this separate `Task` is that in general, we cannot assume that code performs to our
  // expectations if the task we run it on is already cancelled. However, in some cases we need the code to
  // run regardless -- even if our task is already cancelled. Therefore, we create a new, uncancelled task here.
  await Task {
    await body()
  }.value
}
