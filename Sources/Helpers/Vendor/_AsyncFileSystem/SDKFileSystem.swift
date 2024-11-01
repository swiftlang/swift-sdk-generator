//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2023-2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

@preconcurrency import _NIOFileSystem

public actor SDKFileSystem: AsyncFileSystem {
    public init(readChunkSize: Int = defaultChunkSize) {
        self.readChunkSize = readChunkSize
    }
    public static let defaultChunkSize = 512 * 1024
    let readChunkSize: Int
    public func exists(_ path: SystemPackage.FilePath) async -> Bool {
        do {
            guard let _ = try await FileSystem.shared.info(forFileAt: path) else {
                return false
            }
            return true
        } catch {
            return false
        }
    }

    public func withOpenReadableFile<T: Sendable>(
        _ path: SystemPackage.FilePath, _ body: @Sendable (OpenReadableFile) async throws -> T
    ) async throws -> T {
        let fh = try await FileSystem.shared.openFile(forReadingAt: path)
        do {
            let result = try await body(OpenReadableFile(chunkSize: readChunkSize, fileHandle: .nio(fh)))
            try await fh.close()
            return result
        } catch {
            try await fh.close()
            throw error.attach(path)
        }
    }

    public func withOpenWritableFile<T: Sendable>(
        _ path: SystemPackage.FilePath, _ body: @Sendable (OpenWritableFile) async throws -> T
    ) async throws -> T {
        let fh = try await FileSystem.shared.openFile(forWritingAt: path, options: .newFile(replaceExisting: true))
        do {
            let result = try await body(OpenWritableFile(storage:.nio(fh),path:path))
            try await fh.close()
            return result
        } catch {
            try await fh.close()
            throw error.attach(path)
        }
    }
}
