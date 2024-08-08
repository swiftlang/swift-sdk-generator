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
import GeneratorEngine
import Logging
import SystemPackage
import Helpers

/// Top-level actor that sequences all of the required SDK generation steps.
public actor SwiftSDKGenerator {
  let bundleVersion: String
  let targetTriple: Triple
  let artifactID: String
  let pathsConfiguration: PathsConfiguration
  let isIncremental: Bool
  let isVerbose: Bool
  let engineCachePath: SQLite.Location
  let logger: Logger

  public init(
    bundleVersion: String,
    targetTriple: Triple,
    artifactID: String,
    isIncremental: Bool,
    isVerbose: Bool,
    logger: Logger
  ) async throws {
    logGenerationStep("Looking up configuration values...")

    let sourceRoot = FilePath(#file)
      .removingLastComponent()
      .removingLastComponent()
      .removingLastComponent()
      .removingLastComponent()

    self.bundleVersion = bundleVersion

    self.targetTriple = targetTriple
    self.artifactID = artifactID

    self.pathsConfiguration = .init(
      sourceRoot: sourceRoot,
      artifactID: self.artifactID,
      targetTriple: self.targetTriple
    )
    self.isIncremental = isIncremental
    self.isVerbose = isVerbose

    self.engineCachePath = .path(self.pathsConfiguration.artifactsCachePath.appending("cache.db"))
    self.logger = logger
  }

  private let fileManager = FileManager.default
  private static let dockerCommand = "docker"

  public static func getCurrentTriple(isVerbose: Bool) throws -> Triple {
    let current = UnixName.current!
    let cpu = current.machine
    #if os(macOS)
    let darwinVersion = current.release
    let darwinTriple = Triple("\(cpu)-apple-darwin\(darwinVersion)")
    return Triple("\(cpu)-apple-macos\(darwinTriple._macOSVersion?.description ?? "")")
    #elseif os(Linux)
    return Triple("\(cpu)-unknown-linux")
    #else
    fatalError("Triple detection not implemented for the platform that this generator was built on.")
    #endif
  }

  func launchDockerContainer(imageName: String) async throws -> String {
    try await Shell.readStdout(
      """
      \(Self.dockerCommand) run --rm --platform=linux/\(
        self.targetTriple.arch!.debianConventionName
      ) -d \(imageName) tail -f /dev/null
      """,
      shouldLogCommands: self.isVerbose
    )
    .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func runOnDockerContainer(id: String, command: String) async throws {
    try await Shell.run(
      "\(Self.dockerCommand) exec \(id) \(command)",
      shouldLogCommands: self.isVerbose
    )
  }

  func doesPathExist(
    _ containerPath: FilePath,
    inContainer id: String
  ) async throws -> Bool {
    let result = try await Shell.readStdout(
      #"\#(Self.dockerCommand) exec \#(id) sh -c 'test -e "\#(containerPath)" && echo "y" || echo "n"'"#,
      shouldLogCommands: self.isVerbose
    )
    .trimmingCharacters(in: .whitespacesAndNewlines)
    return result == "y"
  }

  func copyFromDockerContainer(
    id: String,
    from containerPath: FilePath,
    to localPath: FilePath,
    failIfNotExists: Bool = true
  ) async throws {
    if !failIfNotExists {
      guard try await doesPathExist(containerPath, inContainer: id)
      else { return }
    }
    try await Shell.run(
      "\(Self.dockerCommand) cp \(id):\(containerPath) - | tar x -C \(localPath.removingLastComponent())",
      shouldLogCommands: self.isVerbose
    )
  }

  func stopDockerContainer(id: String) async throws {
    try await Shell.run(
      """
      \(Self.dockerCommand) stop \(id)
      """,
      shouldLogCommands: self.isVerbose
    )
  }

  func withDockerContainer(fromImage imageName: String,
                           _ body: @Sendable (String) async throws -> ()) async throws {
    let containerID = try await launchDockerContainer(imageName: imageName)
    try await withAsyncThrowing {
      try await body(containerID)
    } defer: {
      try await stopDockerContainer(id: containerID)
    }
  }

  func doesFileExist(at path: FilePath) -> Bool {
    self.fileManager.fileExists(atPath: path.string)
  }

  func removeFile(at path: FilePath) throws {
    try self.fileManager.removeItem(atPath: path.string)
  }

  func writeFile(at path: FilePath, _ data: Data) throws {
    try data.write(to: URL(fileURLWithPath: path.string), options: .atomic)
  }

  func readFile(at path: FilePath) throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: path.string))
  }

  func rsync(from source: FilePath, to destination: FilePath) async throws {
    try self.createDirectoryIfNeeded(at: destination)
    try await Shell.run("rsync -a \(source) \(destination)", shouldLogCommands: self.isVerbose)
  }

  func rsyncContents(from source: FilePath, to destination: FilePath) async throws {
    try self.createDirectoryIfNeeded(at: destination)
    try await Shell.run("rsync -a \(source)/ \(destination)", shouldLogCommands: self.isVerbose)
  }

  func createSymlink(at source: FilePath, pointingTo destination: FilePath) throws {
    try self.fileManager.createSymbolicLink(
      atPath: source.string,
      withDestinationPath: destination.string
    )
  }

  func findSymlinks(at directory: FilePath) throws -> [(FilePath, FilePath)] {
    guard let enumerator = fileManager.enumerator(
      at: URL(fileURLWithPath: directory.string),
      includingPropertiesForKeys: [.isSymbolicLinkKey]
    ) else { return [] }

    var result = [(FilePath, FilePath)]()
    for case let url as URL in enumerator {
      guard let isSymlink = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        .isSymbolicLink else { continue }

      if isSymlink {
        let path = url.path
        try result.append((FilePath(path), FilePath(self.fileManager.destinationOfSymbolicLink(atPath: url.path))))
      }
    }

    return result
  }

  func contentsOfDirectory(at path: FilePath) throws -> [String] {
    try self.fileManager.contentsOfDirectory(atPath: path.string)
  }

  func copy(from source: FilePath, to destination: FilePath) throws {
    try self.removeRecursively(at: destination)
    try self.fileManager.copyItem(atPath: source.string, toPath: destination.string)
  }

  func createDirectoryIfNeeded(at directoryPath: FilePath) throws {
    var isDirectory: ObjCBool = false

    if self.fileManager.fileExists(atPath: directoryPath.string, isDirectory: &isDirectory) {
      guard isDirectory.boolValue
      else { throw FileOperationError.directoryCreationFailed(directoryPath) }
    } else {
      try self.fileManager.createDirectory(
        atPath: directoryPath.string,
        withIntermediateDirectories: true
      )
    }
  }

  func removeRecursively(at path: FilePath) throws {
    // Can't use `FileManager.fileExists` here, because it isn't good enough for symlinks. It always
    // tries to resolve a symlink before checking.
    if (try? self.fileManager.attributesOfItem(atPath: path.string)) != nil {
      try self.fileManager.removeItem(atPath: path.string)
    }
  }

  func gunzip(file: FilePath, into directoryPath: FilePath) async throws {
    try await Shell.run(#"cd "\#(directoryPath)" && gzip -d "\#(file)""#, shouldLogCommands: self.isVerbose)
  }

  func untar(
    file: FilePath,
    into directoryPath: FilePath,
    stripComponents: Int? = nil
  ) async throws {
    let stripComponentsOption: String
    if let stripComponents {
      stripComponentsOption = "--strip-components=\(stripComponents)"
    } else {
      stripComponentsOption = ""
    }
    try await Shell.run(
      #"tar -C "\#(directoryPath)" \#(stripComponentsOption) -xf \#(file)"#,
      shouldLogCommands: self.isVerbose
    )
  }

  func unpack(debFile: FilePath, into directoryPath: FilePath) async throws {
    let isVerbose = self.isVerbose
    try await self.inTemporaryDirectory { _, tmp in
      try await Shell.run(#"cd "\#(tmp)" && ar -x "\#(debFile)""#, shouldLogCommands: isVerbose)
      try await print(Shell.readStdout("ls \(tmp)"))

      try await Shell.run(
        #"tar -C "\#(directoryPath)" -xf "\#(tmp)"/data.tar.*"#,
        shouldLogCommands: isVerbose
      )
    }
  }

  func unpack(pkgFile: FilePath, into directoryPath: FilePath) async throws {
    let isVerbose = self.isVerbose
    try await self.inTemporaryDirectory { _, tmp in
      try await Shell.run(#"xar -C "\#(tmp)" -xf "\#(pkgFile)""#, shouldLogCommands: isVerbose)
      try await Shell.run(
        #"cat "\#(tmp)"/*.pkg/Payload | gunzip -cd | (cd "\#(directoryPath)" && cpio -i)"#,
        shouldLogCommands: isVerbose
      )
    }
  }

  func unpack(file: FilePath, into directoryPath: FilePath) async throws {
    switch file.extension {
    case "gz":
      if let stem = file.stem, FilePath(stem).extension == "tar" {
        try await self.untar(file: file, into: directoryPath)
      } else {
        try await self.gunzip(file: file, into: directoryPath)
      }
    case "deb":
      try await self.unpack(debFile: file, into: directoryPath)
    case "pkg":
      try await self.unpack(pkgFile: file, into: directoryPath)
    default:
      throw FileOperationError.unknownArchiveFormat(file.extension)
    }
  }

  func inTemporaryDirectory<T: Sendable>(
    _ closure: @Sendable (SwiftSDKGenerator, FilePath) async throws -> T
  ) async throws -> T {
    let tmp = FilePath(NSTemporaryDirectory())
      .appending("swift-sdk-generator-\(UUID().uuidString.prefix(6))")

    try self.createDirectoryIfNeeded(at: tmp)

    let result = try await closure(self, tmp)

    try removeRecursively(at: tmp)

    return result
  }
}
