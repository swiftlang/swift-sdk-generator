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

public protocol FileSystem {

    // MARK: shell commands

    func untar(file: FilePath, into directoryPath: FilePath, stripComponents: Int?) async throws
    func unpack(file: FilePath, into directoryPath: FilePath) async throws
    func rsync(from source: FilePath, to destination: FilePath) async throws

    // MARK: common operations on files

    func doesFileExist(at path: FilePath) -> Bool
    func copy(from source: FilePath, to destination: FilePath) throws

    // MARK: common operations on directories

    func createDirectoryIfNeeded(at directoryPath: FilePath) throws
    func removeRecursively(at path: FilePath) throws
    func inTemporaryDirectory<T>(_ closure: @Sendable (Self, FilePath) async throws -> T) async throws -> T

    // MARK: file I/O

    func readFile(at path: FilePath) throws -> Data
    func writeFile(at path: FilePath, _ data: Data) throws

    // MARK: symbolic links

    func findSymlinks(at directory: FilePath) throws -> [(FilePath, FilePath)]
    func createSymlink(at source: FilePath, pointingTo destination: FilePath) throws

    // MARK: Docker operations

    func launchDockerContainer(swiftVersion: String, ubuntuRelease: String) async throws -> String
    func copyFromDockerContainer(id: String, from containerPath: FilePath, to localPath: FilePath) async throws
    func stopDockerContainer(id: String) async throws
}

// FIXME: make an actor?
public final class LocalFileSystem: FileSystem {
    public init() {}

    private let fileManager = FileManager.default

    public func launchDockerContainer(swiftVersion: String, ubuntuRelease: String) async throws -> String {
        try await Shell.readStdout("PATH='/bin:/usr/bin:/usr/local/bin' docker create swift:\(swiftVersion)-\(ubuntuRelease)")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func copyFromDockerContainer(id: String, from containerPath: FilePath, to localPath: FilePath) async throws {
        try await Shell.run("PATH='/bin:/usr/bin:/usr/local/bin' docker cp \(id):\(containerPath) \(localPath)")
    }

    public func stopDockerContainer(id: String) async throws {
        try await Shell.run("PATH='/bin:/usr/bin:/usr/local/bin' docker rm -v \(id)")
    }

    public func doesFileExist(at path: FilePath) -> Bool {
        fileManager.fileExists(atPath: path.string)
    }

    public func writeFile(at path: FilePath, _ data: Data) throws {
        try data.write(to: URL(fileURLWithPath: path.string), options: .atomic)
    }

    public func readFile(at path: FilePath) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: path.string))
    }

    public func rsync(from source: FilePath, to destination: FilePath) async throws {
        try await Shell.run("rsync -a \(source) \(destination)")
    }

    public func createSymlink(at source: FilePath, pointingTo destination: FilePath) throws {
        try fileManager.createSymbolicLink(atPath: source.string, withDestinationPath: destination.string)
    }

    public func findSymlinks(at directory: FilePath) throws -> [(FilePath, FilePath)] {
        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: directory.string),
            includingPropertiesForKeys: [.isSymbolicLinkKey]
        ) else { return [] }

        var result = [(FilePath, FilePath)]()
        for case let url as URL in enumerator {
            guard let isSymlink = try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink else { continue }

            if isSymlink {
                let path = url.path
                try result.append((FilePath(path), FilePath(fileManager.destinationOfSymbolicLink(atPath: url.path))))
            }
        }

        return result
    }

    public func copy(from source: FilePath, to destination: FilePath) throws {
        try removeRecursively(at: destination)
        try fileManager.copyItem(atPath: source.string, toPath: destination.string)
    }

    public func createDirectoryIfNeeded(at directoryPath: FilePath) throws {
        var isDirectory: ObjCBool = false

        if fileManager.fileExists(atPath: directoryPath.string, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw FileOperationError.directoryCreationFailed(directoryPath) }
        } else {
            try fileManager.createDirectory(atPath: directoryPath.string, withIntermediateDirectories: true)
        }
    }

    public func removeRecursively(at path: FilePath) throws {
        // Can't use `FileManager.fileExists` here, because it isn't good enough for symlinks. It always tries to
        // resolve a symlink before checking.
        if (try? fileManager.attributesOfItem(atPath: path.string)) != nil {
            try fileManager.removeItem(atPath: path.string)
        }
    }

    func gunzip(file: FilePath, into directoryPath: FilePath) async throws {
        try await Shell.run("gzip -d \(file)", currentDirectory: directoryPath)
    }

    public func untar(file: FilePath, into directoryPath: FilePath, stripComponents: Int? = nil) async throws {
        let stripComponentsOption: String
        if let stripComponents {
            stripComponentsOption = "--strip-components=\(stripComponents)"
        } else {
            stripComponentsOption = ""
        }
        try await Shell.run("tar \(stripComponentsOption) -xzf \(file)", currentDirectory: directoryPath)
    }

    func unpack(debFile: FilePath, into directoryPath: FilePath) async throws {
        try await inTemporaryDirectory { _, tmp in
            try await Shell.run("ar -x \(debFile)", currentDirectory: tmp)
            // FIXME: don't hardcode homebrew path
            try await Shell.run(
                "PATH='/bin:/usr/bin:/opt/homebrew/bin' tar -xf \(tmp)/data.tar.*",
                currentDirectory: directoryPath
            )
        }
    }

    func unpack(pkgFile: FilePath, into directoryPath: FilePath) async throws {
        try await inTemporaryDirectory { _, tmp in
            try await Shell.run("xar -xf \(pkgFile)", currentDirectory: tmp)
            try await Shell.run("cat \(tmp)/*.pkg/Payload | gunzip -cd | cpio -i", currentDirectory: directoryPath)
        }
    }

    public func unpack(file: FilePath, into directoryPath: FilePath) async throws {
        switch file.extension {
        case "gz":
            if let stem = file.stem, FilePath(stem).extension == "tar" {
                try await untar(file: file, into: directoryPath)
            } else {
                try await gunzip(file: file, into: directoryPath)
            }
        case "deb":
            try await unpack(debFile: file, into: directoryPath)
        case "pkg":
            try await unpack(pkgFile: file, into: directoryPath)
        default:
            throw FileOperationError.unknownArchiveFormat(file.extension)
        }
    }

    public func inTemporaryDirectory<T>(_ closure: @Sendable (LocalFileSystem, FilePath) async throws -> T) async throws -> T {
        let tmp = FilePath(NSTemporaryDirectory()).appending("cc-sdk-\(UUID().uuidString.prefix(6))")

        try createDirectoryIfNeeded(at: tmp)

        let result = try await closure(self, tmp)

        try removeRecursively(at: tmp)

        return result
    }
}


@available(*, unavailable)
extension LocalFileSystem: Sendable {}
