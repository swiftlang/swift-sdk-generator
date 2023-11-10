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
import Logging
import NIO

public struct OutputLoggingSettings {
  /// Where should the output line put to?
  public enum WhereTo {
    /// Put the output line into the logMessage itself.
    case logMessage

    /// Put the output line into the `metadata` of the ``Logger``.
    case metadata(logMessage: Logger.Message, key: Logger.Metadata.Key)
  }

  /// Which ``Logger.Level`` to log the output at.
  public var logLevel: Logger.Level

  public var to: WhereTo

  public init(logLevel: Logger.Level, to: OutputLoggingSettings.WhereTo) {
    self.logLevel = logLevel
    self.to = to
  }

  func logMessage(line: String) -> Logger.Message {
    switch self.to {
    case .logMessage:
      "\(line)"
    case .metadata(logMessage: let message, key: _):
      message
    }
  }

  func metadata(stream: ProcessOutputStream, line: String) -> Logger.Metadata {
    switch self.to {
    case .logMessage:
      return ["stream": "\(stream.description)"]
    case .metadata(logMessage: _, let key):
      return [key: "\(line)"]
    }
  }
}

public extension ProcessExecutor {
  /// Run child process, discarding all its output.
  static func run(
    group: EventLoopGroup,
    executable: String,
    _ arguments: [String],
    standardInput: StandardInput,
    environment: [String: String] = [:],
    logger: Logger
  ) async throws -> ProcessExitReason {
    let p = Self(
      group: group,
      executable: executable,
      arguments,
      environment: environment,
      standardInput: standardInput,
      standardOutput: .discard,
      standardError: .discard,
      logger: logger
    )
    return try await p.run()
  }

  /// Run child process, logging all its output line by line.
  static func runLogOutput(
    group: EventLoopGroup,
    executable: String,
    _ arguments: [String],
    standardInput: StandardInput,
    environment: [String: String] = [:],
    logger: Logger,
    logConfiguration: OutputLoggingSettings
  ) async throws -> ProcessExitReason {
    let exe = ProcessExecutor(
      group: group,
      executable: executable,
      arguments,
      environment: environment,
      standardInput: standardInput,
      standardOutput: .stream,
      standardError: .stream,
      logger: logger
    )
    return try await withThrowingTaskGroup(of: ProcessExitReason?.self) { group in
      group.addTask {
        for try await (stream, line) in await merge(
          exe.standardOutput.splitIntoLines().strings.map { (ProcessOutputStream.standardOutput, $0) },
          exe.standardError.splitIntoLines().strings.map { (ProcessOutputStream.standardError, $0) }
        ) {
          logger.log(
            level: logConfiguration.logLevel,
            logConfiguration.logMessage(line: line),
            metadata: logConfiguration.metadata(stream: stream, line: line)
          )
        }
        return nil
      }

      group.addTask {
        try await exe.run()
      }

      while let next = try await group.next() {
        if let result = next {
          return result
        }
      }
      fatalError("the impossible happened, second task didn't return.")
    }
  }

  /// Run child process, process all its output (`stdout` and `stderr`) using a closure.
  static func runProcessingOutput(
    group: EventLoopGroup,
    executable: String,
    _ arguments: [String],
    standardInput: StandardInput,
    outputProcessor: @escaping @Sendable (ProcessOutputStream, ByteBuffer) async throws -> (),
    splitOutputIntoLines: Bool = false,
    environment: [String: String] = [:],
    logger: Logger
  ) async throws -> ProcessExitReason {
    let exe = ProcessExecutor(
      group: group,
      executable: executable,
      arguments,
      environment: environment,
      standardInput: standardInput,
      standardOutput: .stream,
      standardError: .stream,
      logger: logger
    )
    return try await withThrowingTaskGroup(of: ProcessExitReason?.self) { group in
      group.addTask {
        if splitOutputIntoLines {
          for try await (stream, chunk) in await merge(
            exe.standardOutput.splitIntoLines().map { (ProcessOutputStream.standardOutput, $0) },
            exe.standardError.splitIntoLines().map { (ProcessOutputStream.standardError, $0) }
          ) {
            try await outputProcessor(stream, chunk)
          }
          return nil
        } else {
          for try await (stream, chunk) in await merge(
            exe.standardOutput.map { (ProcessOutputStream.standardOutput, $0) },
            exe.standardError.map { (ProcessOutputStream.standardError, $0) }
          ) {
            try await outputProcessor(stream, chunk)
          }
          return nil
        }
      }

      group.addTask {
        try await exe.run()
      }

      while let next = try await group.next() {
        if let result = next {
          return result
        }
      }
      fatalError("the impossible happened, second task didn't return.")
    }
  }

  struct TooMuchProcessOutputError: Error, Sendable & Hashable {
    public var stream: ProcessOutputStream
  }

  struct ProcessExitReasonAndOutput: Sendable & Hashable {
    public var exitReason: ProcessExitReason
    public var standardOutput: ByteBuffer?
    public var standardError: ByteBuffer?
  }

  internal enum ProcessExitInformationPiece {
    case exitReason(ProcessExitReason)
    case standardOutput(ByteBuffer?)
    case standardError(ByteBuffer?)
  }

  static func runCollectingOutput(
    group: EventLoopGroup,
    executable: String,
    _ arguments: [String],
    standardInput: StandardInput,
    collectStandardOutput: Bool,
    collectStandardError: Bool,
    perStreamCollectionLimitBytes: Int = 128 * 1024,
    environment: [String: String] = [:],
    logger: Logger
  ) async throws -> ProcessExitReasonAndOutput {
    let exe = ProcessExecutor(
      group: group,
      executable: executable,
      arguments,
      environment: environment,
      standardInput: standardInput,
      standardOutput: collectStandardOutput ? .stream : .discard,
      standardError: collectStandardError ? .stream : .discard,
      logger: logger
    )

    return try await withThrowingTaskGroup(of: ProcessExitInformationPiece.self) { group in
      group.addTask {
        if collectStandardOutput {
          var output: ByteBuffer?
          for try await chunk in await exe.standardOutput {
            guard (output?.readableBytes ?? 0) + chunk.readableBytes <= perStreamCollectionLimitBytes else {
              throw TooMuchProcessOutputError(stream: .standardOutput)
            }
            output.setOrWriteImmutableBuffer(chunk)
          }
          return .standardOutput(output ?? ByteBuffer())
        } else {
          return .standardOutput(nil)
        }
      }

      group.addTask {
        if collectStandardError {
          var output: ByteBuffer?
          for try await chunk in await exe.standardError {
            guard (output?.readableBytes ?? 0) + chunk.readableBytes <= perStreamCollectionLimitBytes else {
              throw TooMuchProcessOutputError(stream: .standardError)
            }
            output.setOrWriteImmutableBuffer(chunk)
          }
          return .standardError(output ?? ByteBuffer())
        } else {
          return .standardError(nil)
        }
      }

      group.addTask {
        try await .exitReason(exe.run())
      }

      var allInfo = ProcessExitReasonAndOutput(exitReason: .exit(-1), standardOutput: nil, standardError: nil)
      while let next = try await group.next() {
        switch next {
        case let .exitReason(exitReason):
          allInfo.exitReason = exitReason
        case let .standardOutput(output):
          allInfo.standardOutput = output
        case let .standardError(output):
          allInfo.standardError = output
        }
      }
      return allInfo
    }
  }
}
