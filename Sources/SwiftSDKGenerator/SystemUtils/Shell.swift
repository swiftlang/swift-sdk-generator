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

import Foundation
import struct SystemPackage.FilePath

public struct CommandInfo: Sendable {
  let command: String
  let currentDirectory: FilePath?
  let file: String
  let line: Int
}

final class Shell {
  // FIXME: using Foundation's `Process` under the hood might not work on Linux due to these bugs:
  // https://github.com/apple/swift-corelibs-foundation/issues/3275
  // https://github.com/apple/swift-corelibs-foundation/issues/3276
  private let process: Process
  private let commandInfo: CommandInfo

  /// Writable handle to the standard input of the command.
  let stdin: FileHandle

  /// Readable stream of data chunks that the running command writes to the standard output I/O
  /// handle.
  let stdout: AsyncThrowingStream<Data, any Error>

  /// Readable stream of data chunks that the running command writes to the standard error I/O
  /// handle.
  let stderr: AsyncThrowingStream<Data, any Error>

  init(
    _ command: String,
    currentDirectory: FilePath? = nil,
    shouldDisableIOStreams: Bool = false,
    shouldLogCommands: Bool,
    file: String = #file,
    line: Int = #line
  ) throws {
    self.commandInfo = CommandInfo(
      command: command,
      currentDirectory: currentDirectory,
      file: file,
      line: line
    )
    let process = Process()

    if let currentDirectory {
      process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory.string)
    }
    process.executableURL = URL(string: "file:///bin/sh")
    process.arguments = ["-c", command]

    let stdinPipe = Pipe()
    self.stdin = stdinPipe.fileHandleForWriting
    process.standardInput = stdinPipe

    if shouldDisableIOStreams {
      self.stdout = .init { $0.finish() }
      self.stderr = .init { $0.finish() }
    } else {
      self.stdout = .init(process, pipeKeyPath: \.standardOutput, commandInfo: self.commandInfo)
      self.stderr = .init(process, pipeKeyPath: \.standardError, commandInfo: self.commandInfo)
    }

    self.process = process

    if shouldLogCommands {
      print(command)
    }

    try process.run()
  }

  private func check(exitCode: Int32) throws {
    guard exitCode == 0 else {
      throw FileOperationError.nonZeroExitCode(exitCode, self.commandInfo)
    }
  }

  /// Wait for the process to exit in a non-blocking way.
  func waitUntilExit() async throws {
    guard self.process.isRunning else {
      return try self.check(exitCode: self.process.terminationStatus)
    }

    try await withTaskCancellationHandler {
      let exitCode = await withCheckedContinuation { continuation in
        self.process.terminationHandler = {
          continuation.resume(returning: $0.terminationStatus)
        }
      }

      try check(exitCode: exitCode)
    } onCancel: {
      self.process.interrupt()
    }
  }

  /// Launch and wait until a shell command exists. Throws an error for non-zero exit codes.
  /// - Parameters:
  ///   - command: the shell command to launch.
  ///   - currentDirectory: current working directory for the command.
  static func run(
    _ command: String,
    currentDirectory: FilePath? = nil,
    shouldLogCommands: Bool = false,
    file: String = #file,
    line: Int = #line
  ) async throws {
    try await Shell(
      command,
      currentDirectory: currentDirectory,
      shouldDisableIOStreams: true,
      shouldLogCommands: shouldLogCommands,
      file: file,
      line: line
    )
    .waitUntilExit()
  }

  static func readStdout(
    _ command: String,
    currentDirectory: FilePath? = nil,
    shouldLogCommands: Bool = false,
    file: String = #file,
    line: Int = #line
  ) async throws -> String {
    let process = try Shell(
      command,
      currentDirectory: currentDirectory,
      shouldDisableIOStreams: false,
      shouldLogCommands: shouldLogCommands,
      file: file,
      line: line
    )

    try await process.waitUntilExit()

    var output = ""
    for try await chunk in process.stdout {
      output.append(String(data: chunk, encoding: .utf8)!)
    }
    return output
  }
}

@available(*, unavailable)
extension Shell: Sendable {}

private extension AsyncThrowingStream where Element == Data, Failure == any Error {
  init(
    _ process: Process,
    pipeKeyPath: ReferenceWritableKeyPath<Process, Any?>,
    commandInfo: CommandInfo
  ) {
    self.init { continuation in
      let pipe = Pipe()
      pipe.fileHandleForReading.readabilityHandler = { [unowned pipe] fileHandle in
        let data = fileHandle.availableData
        if !data.isEmpty {
          continuation.yield(data)
        } else {
          if !process.isRunning && process.terminationStatus != 0 {
            continuation.finish(
              throwing: FileOperationError.nonZeroExitCode(process.terminationStatus, commandInfo)
            )
          } else {
            continuation.finish()
          }

          // Clean up the handler to prevent repeated calls and continuation finishes for the same
          // process.
          pipe.fileHandleForReading.readabilityHandler = nil
        }
      }

      process[keyPath: pipeKeyPath] = pipe
    }
  }
}
