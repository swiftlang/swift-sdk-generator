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

import Atomics
import Foundation
import Logging
import NIO

@_exported import struct SystemPackage.FileDescriptor

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
      "stdout"
    case .standardError:
      "stderr"
    }
  }
}

/// What to do with a given stream (`stdout`/`stderr`) in the spawned child process.
public struct ProcessOutput {
  enum Backing {
    case discard
    case inherit
    case fileDescriptor(FileDescriptor)
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
  /// - warning: After passing a `FileDescriptor` to this method you _must not_ perform _any_ other operations on it.
  public static func fileDescriptor(takingOwnershipOf fd: FileDescriptor) -> Self {
    .init(backing: .fileDescriptor(fd))
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

/// Execute a sub-process.
///
/// - warning: Currently, the default for `standardOutput` & `standardError` is ``ProcessOutput.stream`` which means
///            you _must_ consume ``ProcessExecutor.standardOutput`` & ``ProcessExecutor.standardError``. If you prefer
///            to not consume it, please set them to ``ProcessOutput.discard`` explicitly.
public actor ProcessExecutor<StandardInput: AsyncSequence & Sendable> where StandardInput.Element == ByteBuffer {
  private let logger: Logger
  private let group: EventLoopGroup
  private let executable: String
  private let arguments: [String]
  private let environment: [String: String]?
  private let standardInput: StandardInput
  private let standardInputPipe: Pipe?
  private let standardOutputWriteHandle: FileHandle?
  private let standardErrorWriteHandle: FileHandle?
  private let _standardOutput: ChunkSequence
  private let _standardError: ChunkSequence
  private let processIsRunningApproximation = ManagedAtomic(RunningStateApproximation.neverStarted.rawValue)
  private let processOutputConsumptionApproximation = ManagedAtomic(UInt8(0))

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

  public init(
    group: EventLoopGroup,
    executable: String,
    _ arguments: [String],
    environment: [String: String]? = nil,
    standardInput: StandardInput,
    standardOutput: ProcessOutput = .stream,
    standardError: ProcessOutput = .stream,
    logger: Logger
  ) {
    self.group = group
    self.executable = executable
    self.environment = environment
    self.arguments = arguments
    self.standardInput = standardInput
    self.logger = logger

    self.standardInputPipe = StandardInput.self == EOFSequence<ByteBuffer>.self ? nil : Pipe()

    switch standardOutput.backing {
    case .discard:
      _ = self.processOutputConsumptionApproximation.bitwiseXorThenLoad(
        with: OutputConsumptionState.stdoutNotStreamed.rawValue,
        ordering: .relaxed
      )
      self.standardOutputWriteHandle = FileHandle(forWritingAtPath: "/dev/null")
      self._standardOutput = ChunkSequence(takingOwnershipOfFileHandle: nil, group: group)
    case let .fileDescriptor(fd):
      _ = self.processOutputConsumptionApproximation.bitwiseXorThenLoad(
        with: OutputConsumptionState.stdoutNotStreamed.rawValue,
        ordering: .relaxed
      )
      self.standardOutputWriteHandle = FileHandle(fileDescriptor: fd.rawValue)
      self._standardOutput = ChunkSequence(takingOwnershipOfFileHandle: nil, group: group)
    case .inherit:
      _ = self.processOutputConsumptionApproximation.bitwiseXorThenLoad(
        with: OutputConsumptionState.stdoutNotStreamed.rawValue,
        ordering: .relaxed
      )
      self.standardOutputWriteHandle = nil
      self._standardOutput = ChunkSequence(takingOwnershipOfFileHandle: nil, group: group)
    case .stream:
      let (stdoutSequence, stdoutWriteHandle) = Self.makeWriteStream(group: group)
      self._standardOutput = stdoutSequence
      self.standardOutputWriteHandle = stdoutWriteHandle
    }

    switch standardError.backing {
    case .discard:
      _ = self.processOutputConsumptionApproximation.bitwiseXorThenLoad(
        with: OutputConsumptionState.stderrNotStreamed.rawValue,
        ordering: .relaxed
      )
      self.standardErrorWriteHandle = FileHandle(forWritingAtPath: "/dev/null")
      self._standardError = ChunkSequence(takingOwnershipOfFileHandle: nil, group: group)
    case let .fileDescriptor(fd):
      _ = self.processOutputConsumptionApproximation.bitwiseXorThenLoad(
        with: OutputConsumptionState.stderrNotStreamed.rawValue,
        ordering: .relaxed
      )
      self.standardErrorWriteHandle = FileHandle(fileDescriptor: fd.rawValue)
      self._standardError = ChunkSequence(takingOwnershipOfFileHandle: nil, group: group)
    case .inherit:
      _ = self.processOutputConsumptionApproximation.bitwiseXorThenLoad(
        with: OutputConsumptionState.stderrNotStreamed.rawValue,
        ordering: .relaxed
      )
      self.standardErrorWriteHandle = nil
      self._standardError = ChunkSequence(takingOwnershipOfFileHandle: nil, group: group)
    case .stream:
      let (stdoutSequence, stdoutWriteHandle) = Self.makeWriteStream(group: group)
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
    p.environment = self.environment ?? [:]
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

    @Sendable
    func go() async throws -> ProcessExitReason {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<ProcessExitReason, Error>) in
        p.terminationHandler = { p in
          self.logger.debug(
            "finished running command",
            metadata: [
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

          if p.terminationReason == .uncaughtSignal {
            continuation.resume(returning: .signal(p.terminationStatus))
          } else {
            continuation.resume(returning: .exit(p.terminationStatus))
          }
        }
        do {
          let (worked, original) = self.processIsRunningApproximation.compareExchange(
            expected: RunningStateApproximation.neverStarted.rawValue,
            desired: RunningStateApproximation.running.rawValue,
            ordering: .relaxed
          )
          precondition(worked, "illegal running state \(original)")
          try p.run()
          self.logger.debug(
            "running command",
            metadata: [
              "executable": "\(self.executable)",
              "arguments": "\(self.arguments)",
              "pid": "\(p.processIdentifier)",
            ]
          )
        } catch {
          continuation.resume(throwing: error)
        }

        try! self.standardInputPipe?.fileHandleForReading.close() // Must work.
        try! self.standardOutputWriteHandle?.close() // Must work.
        try! self.standardErrorWriteHandle?.close() // Must work.
      }
    }

    @Sendable
    func cancel() {
      guard p.processIdentifier != 0 else {
        self.logger.warning("leaking Process \(p) because it hasn't been started yet")
        return
      }
      self.logger.info("terminating process", metadata: ["pid": "\(p.processIdentifier)"])
      #if os(Linux)
      // workaround: https://github.com/apple/swift-corelibs-foundation/issues/4772
      if p.isRunning {
        kill(p.processIdentifier, SIGKILL)
      }
      #else
      p.terminate()
      #endif
    }

    return try await withThrowingTaskGroup(of: ProcessExitReason?.self, returning: ProcessExitReason.self) {
      group in
      group.addTask {
        try await withTaskCancellationHandler(operation: go, onCancel: cancel)
      }
      group.addTask {
        if let stdinPipe = self.standardInputPipe {
          try await NIOAsyncPipeWriter<StandardInput>.sinkSequenceInto(
            self.standardInput,
            fileDescriptor: stdinPipe.fileHandleForWriting.fileDescriptor,
            eventLoop: self.group.any()
          )
        }
        return nil
      }

      var exitReason: ProcessExitReason?
      while let result = try await group.next() {
        if let result {
          exitReason = result
        }
      }
      return exitReason! // must work because the real task will return a reason (or throw)
    }
  }
}
