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

public struct OutputLoggingSettings: Sendable {
  /// Where should the output line put to?
  public enum WhereTo: Sendable {
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
      return "\(line)"
    case .metadata(logMessage: let message, key: _):
      return message
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

extension ProcessExecutor {
  /// Run child process, discarding all its output.
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
  ///   - logger: Where to log diagnostic messages to (default to no where)
  public static func run<StandardInput: AsyncSequence & Sendable>(
    group: EventLoopGroup = ProcessExecutor.defaultEventLoopGroup,
    executable: String,
    _ arguments: [String],
    standardInput: StandardInput,
    environment: [String: String] = [:],
    logger: Logger = ProcessExecutor.disableLogging
  ) async throws -> ProcessExitReason where StandardInput.Element == ByteBuffer {
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

  /// Run child process, logging all its output.
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
  ///   - logger: Where to log diagnostic and output messages to
  ///   - logConfiguration: How to log the output lines
  public static func runLogOutput<StandardInput: AsyncSequence & Sendable>(
    group: EventLoopGroup = ProcessExecutor.defaultEventLoopGroup,
    executable: String,
    _ arguments: [String],
    standardInput: StandardInput,
    environment: [String: String] = [:],
    logger: Logger,
    logConfiguration: OutputLoggingSettings
  ) async throws -> ProcessExitReason where StandardInput.Element == ByteBuffer {
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
          exe.standardOutput.splitIntoLines().strings.map {
            (ProcessOutputStream.standardOutput, $0)
          },
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

  /// Run child process, processing all its output (`stdout` and `stderr`) using a closure.
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
  ///   - outputProcessor: The closure that'll be called for every chunk of output
  ///   - splitOutputIntoLines: Whether to call the closure with full lines (`true`) or arbitrary chunks of output
  /// (`false`)
  ///   - logger: Where to log diagnostic and output messages to
  public static func runProcessingOutput<StandardInput: AsyncSequence & Sendable>(
    group: EventLoopGroup = ProcessExecutor.defaultEventLoopGroup,
    executable: String,
    _ arguments: [String],
    standardInput: StandardInput,
    outputProcessor: @escaping @Sendable (ProcessOutputStream, ByteBuffer) async throws -> Void,
    splitOutputIntoLines: Bool = false,
    environment: [String: String] = [:],
    logger: Logger = ProcessExecutor.disableLogging
  ) async throws -> ProcessExitReason where StandardInput.Element == ByteBuffer {
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

  public struct TooMuchProcessOutputError: Error, Sendable & Hashable {
    public var stream: ProcessOutputStream
  }

  public struct ProcessExitReasonAndOutput: Sendable & Hashable {
    public var exitReason: ProcessExitReason
    public var standardOutput: ByteBuffer?
    public var standardError: ByteBuffer?
  }

  internal enum ProcessExitInformationPiece {
    case exitReason(ProcessExitReason)
    case standardOutput(ByteBuffer?)
    case standardError(ByteBuffer?)
  }

  /// Run child process, collecting its output (`stdout` and `stderr`) into memory.
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
  ///   - collectStandardOutput: If `true`, collect all of the child process' standard output into memory, discard if
  /// `false`
  ///   - collectStandardError: If `true`, collect all of the child process' standard error into memory, discard if
  /// `false`
  ///   - logger: Where to log diagnostic and output messages to
  public static func runCollectingOutput<StandardInput: AsyncSequence & Sendable>(
    group: EventLoopGroup = ProcessExecutor.defaultEventLoopGroup,
    executable: String,
    _ arguments: [String],
    standardInput: StandardInput,
    collectStandardOutput: Bool,
    collectStandardError: Bool,
    perStreamCollectionLimitBytes: Int = 128 * 1024,
    environment: [String: String] = [:],
    logger: Logger = ProcessExecutor.disableLogging
  ) async throws -> ProcessExitReasonAndOutput where StandardInput.Element == ByteBuffer {
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
          var output: ByteBuffer? = nil
          for try await chunk in await exe.standardOutput {
            guard
              (output?.readableBytes ?? 0) + chunk.readableBytes <= perStreamCollectionLimitBytes
            else {
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
          var output: ByteBuffer? = nil
          for try await chunk in await exe.standardError {
            guard
              (output?.readableBytes ?? 0) + chunk.readableBytes <= perStreamCollectionLimitBytes
            else {
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

      var allInfo = ProcessExitReasonAndOutput(
        exitReason: .exit(-1), standardOutput: nil, standardError: nil)
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

extension ProcessExecutor {
  /// Run child process, discarding all its output.
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
  ///   - logger: Where to log diagnostic messages to (default to no where)
  public static func run(
    group: EventLoopGroup = ProcessExecutor.defaultEventLoopGroup,
    executable: String,
    _ arguments: [String],
    environment: [String: String] = [:],
    logger: Logger = ProcessExecutor.disableLogging
  ) async throws -> ProcessExitReason {
    try await self.run(
      group: group,
      executable: executable,
      arguments,
      standardInput: EOFSequence(),
      environment: environment,
      logger: logger
    )
  }

  /// Run child process, logging all its output.
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
  ///   - logger: Where to log diagnostic and output messages to
  ///   - logConfiguration: How to log the output lines
  public static func runLogOutput(
    group: EventLoopGroup = ProcessExecutor.defaultEventLoopGroup,
    executable: String,
    _ arguments: [String],
    environment: [String: String] = [:],
    logger: Logger,
    logConfiguration: OutputLoggingSettings
  ) async throws -> ProcessExitReason {
    try await self.runLogOutput(
      group: group,
      executable: executable,
      arguments,
      standardInput: EOFSequence(),
      environment: environment,
      logger: logger,
      logConfiguration: logConfiguration
    )
  }

  /// Run child process, processing all its output (`stdout` and `stderr`) using a closure.
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
  ///   - outputProcessor: The closure that'll be called for every chunk of output
  ///   - splitOutputIntoLines: Whether to call the closure with full lines (`true`) or arbitrary chunks of output
  /// (`false`)
  ///   - logger: Where to log diagnostic and output messages to
  public static func runProcessingOutput(
    group: EventLoopGroup = ProcessExecutor.defaultEventLoopGroup,
    executable: String,
    _ arguments: [String],
    outputProcessor: @escaping @Sendable (ProcessOutputStream, ByteBuffer) async throws -> Void,
    splitOutputIntoLines: Bool = false,
    environment: [String: String] = [:],
    logger: Logger = ProcessExecutor.disableLogging
  ) async throws -> ProcessExitReason {
    try await self.runProcessingOutput(
      group: group,
      executable: executable,
      arguments,
      standardInput: EOFSequence(),
      outputProcessor: outputProcessor,
      splitOutputIntoLines: splitOutputIntoLines,
      environment: environment,
      logger: logger
    )
  }

  /// Run child process, collecting its output (`stdout` and `stderr`) into memory.
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
  ///   - collectStandardOutput: If `true`, collect all of the child process' standard output into memory, discard if
  /// `false`
  ///   - collectStandardError: If `true`, collect all of the child process' standard error into memory, discard if
  /// `false`
  ///   - logger: Where to log diagnostic and output messages to
  public static func runCollectingOutput(
    group: EventLoopGroup = ProcessExecutor.defaultEventLoopGroup,
    executable: String,
    _ arguments: [String],
    collectStandardOutput: Bool,
    collectStandardError: Bool,
    perStreamCollectionLimitBytes: Int = 128 * 1024,
    environment: [String: String] = [:],
    logger: Logger = ProcessExecutor.disableLogging
  ) async throws -> ProcessExitReasonAndOutput {
    try await self.runCollectingOutput(
      group: group,
      executable: executable,
      arguments, standardInput: EOFSequence(),
      collectStandardOutput: collectStandardOutput,
      collectStandardError: collectStandardError,
      perStreamCollectionLimitBytes: perStreamCollectionLimitBytes,
      environment: environment,
      logger: logger
    )
  }
}
