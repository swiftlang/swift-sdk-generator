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

import AsyncProcess
import class Foundation.ProcessInfo
import struct SystemPackage.FilePath

public struct CommandInfo: Sendable {
  let command: String
  let file: String
  let line: Int
}

struct Shell {
  private let process: ProcessExecutor
  private let commandInfo: CommandInfo
  private let logStdout: Bool
  private let logStderr: Bool

  private init(
    _ command: String,
    shouldLogCommands: Bool,
    logStdout: Bool = false,
    logStderr: Bool = true,
    file: String = #file,
    line: Int = #line
  ) throws {
    self.process = ProcessExecutor(
      executable: "/bin/sh",
      ["-c", command],
      environment: ProcessInfo.processInfo.environment,
      standardOutput: logStdout ? .stream : .discard,
      standardError: logStderr ? .stream : .discard
    )
    self.commandInfo = CommandInfo(
      command: command,
      file: file,
      line: line
    )
    self.logStdout = logStdout
    self.logStderr = logStderr

    if shouldLogCommands {
      print(command)
    }
  }

  /// Wait for the process to exit in a non-blocking way.
  private func waitUntilExit() async throws {
    let result = try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        if self.logStdout {
          try await self.process.standardOutput.printChunksAsStrings()
        }
      }
      group.addTask {
        if self.logStderr {
          try await self.process.standardError.printChunksAsStrings()
        }
      }
      return try await self.process.run()
    }
    do {
      try result.throwIfNonZero()
    } catch {
      switch result {
      case let .exit(code):
        throw GeneratorError.nonZeroExitCode(code, self.commandInfo)
      case let .signal(signal):
        throw GeneratorError.unhandledChildProcessSignal(signal, self.commandInfo)
      }
    }
  }

  /// Launch and wait until a shell command exists. Throws an error for non-zero exit codes.
  /// - Parameters:
  ///   - command: the shell command to launch.
  ///   - currentDirectory: current working directory for the command.
  static func run(
    _ command: String,
    shouldLogCommands: Bool = false,
    logStdout: Bool = false,
    logStderr: Bool = true,
    file: String = #file,
    line: Int = #line
  ) async throws {
    try await Shell(
      command,
      shouldLogCommands: shouldLogCommands,
      logStdout: logStdout,
      logStderr: logStderr,
      file: file,
      line: line
    )
    .waitUntilExit()
  }

  static func readStdout(
    _ command: String,
    shouldLogCommands: Bool = false,
    file: String = #file,
    line: Int = #line
  ) async throws -> String {
    if shouldLogCommands {
      print(command)
    }

    let result = try await ProcessExecutor.runCollectingOutput(
      executable: "/bin/sh",
      ["-c", command],
      collectStandardOutput: true,
      collectStandardError: false,
      perStreamCollectionLimitBytes: 10 * 1024 * 1024,
      environment: ProcessInfo.processInfo.environment
    )

    try result.exitReason.throwIfNonZero()

    guard let stdOutBuffer = result.standardOutput else { throw GeneratorError.noProcessOutput(command) }

    return String(buffer: stdOutBuffer)
  }
}

extension ChunkSequence {
  func printChunksAsStrings() async throws {
      for try await line in self.splitIntoLines(dropTerminator: true) {
          print(line)
      }
  }
}
