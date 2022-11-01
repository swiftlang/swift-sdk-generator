//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
import SystemPackage

public struct CommandInfo {
    let command: String
    let currentDirectory: FilePath?
    let file: String
    let line: Int
}

final class Shell {
    private let process: Process
    private let commandInfo: CommandInfo

    /// Writable handle to the standard input of the command.
    let stdin: FileHandle

    /// Readable stream of data chunks that the running command writes to the standard output I/O handle.
    let stdout: AsyncThrowingStream<Data, any Error>

    /// Readable stream of data chunks that the running command writes to the standard error I/O handle.
    let stderr: AsyncThrowingStream<Data, any Error>
    
    init(
        _ command: String,
        currentDirectory: FilePath? = nil,
        disableIOStreams: Bool = false,
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
        stdin = stdinPipe.fileHandleForWriting
        process.standardInput = stdinPipe

        if disableIOStreams {
            stdout = .init { $0.finish() }
            stderr = .init { $0.finish() }
        } else {
            stdout = .init(process, pipeKeyPath: \.standardOutput, commandInfo: commandInfo)
            stderr = .init(process, pipeKeyPath: \.standardError, commandInfo: commandInfo)
        }
        
        self.process = process

        print(command)

        try process.run()
    }

    private func check(exitCode: Int32) throws {
        guard process.terminationStatus == 0 else {
            throw FileOperationError.nonZeroExitCode(process.terminationStatus, commandInfo)
        }
    }

    /// Wait for the process to exit in a non-blocking way.
    func waitUntilExit() async throws {
        guard process.isRunning else {
            return try check(exitCode: process.terminationStatus)
        }
        
        let exitCode = await withCheckedContinuation { continuation in
            process.terminationHandler = {
                continuation.resume(returning: $0.terminationStatus)
            }
        }

        try check(exitCode: exitCode)
    }

    /// Launch and wait until a shell command exists. Throws an error for non-zero exit codes.
    /// - Parameters:
    ///   - command: the shell command to launch.
    ///   - currentDirectory: current working directory for the command.
    static func run(
        _ command: String,
        currentDirectory: FilePath? = nil,
        file: String = #file,
        line: Int = #line
    ) async throws {
        try await Shell(command, currentDirectory: currentDirectory, disableIOStreams: true, file: file, line: line)
            .waitUntilExit()
    }

    static func readStdout(
        _ command: String,
        currentDirectory: FilePath? = nil,
        file: String = #file,
        line: Int = #line
    ) async throws -> String {
        let process = try Shell(
            command,
            currentDirectory: currentDirectory,
            disableIOStreams: false,
            file: file,
            line: line
        )

        var output = ""
        for try await chunk in process.stdout {
            output.append(String(data: chunk, encoding: .utf8)!)
        }
        return output
    }
}

@available(*, unavailable)
extension Shell: Sendable { }

private extension AsyncThrowingStream where Element == Data, Failure == any Error {
    init(
        _ process: Process,
        pipeKeyPath: ReferenceWritableKeyPath<Process, Any?>,
        commandInfo: CommandInfo
    ) {
        self.init { continuation in
            let pipe = Pipe()
            pipe.fileHandleForReading.readabilityHandler = { fileHandle in
                let data = fileHandle.availableData
                if !data.isEmpty {
                    continuation.yield(data)
                } else {
                    if !process.isRunning && process.terminationStatus != 0 {
                        continuation.finish(throwing: FileOperationError.nonZeroExitCode(process.terminationStatus, commandInfo))
                    } else {
                        continuation.finish()
                    }
                }
            }
            
            process[keyPath: pipeKeyPath] = pipe
        }
    }
}
