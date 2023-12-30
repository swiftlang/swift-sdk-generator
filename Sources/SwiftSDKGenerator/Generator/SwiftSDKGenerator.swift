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
  let hostTriple: Triple
  let targetTriple: Triple
  let artifactID: String
  let versionsConfiguration: VersionsConfiguration
  let pathsConfiguration: PathsConfiguration
  var downloadableArtifacts: DownloadableArtifacts
  let shouldUseDocker: Bool
  let baseDockerImage: String?
  let isIncremental: Bool
  let isVerbose: Bool
  let engineCachePath: SQLite.Location
  let logger: Logger

  public init(
    bundleVersion: String,
    hostCPUArchitecture: Triple.CPU?,
    targetCPUArchitecture: Triple.CPU?,
    swiftVersion: String,
    swiftBranch: String?,
    lldVersion: String,
    linuxDistribution: LinuxDistribution,
    shouldUseDocker: Bool,
    baseDockerImage: String?,
    artifactID: String?,
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

    var currentTriple = try await Self.getCurrentTriple(isVerbose: isVerbose)
    if let hostCPUArchitecture {
      currentTriple.cpu = hostCPUArchitecture
    }

    self.hostTriple = currentTriple

    self.targetTriple = Triple(
      cpu: targetCPUArchitecture ?? self.hostTriple.cpu,
      vendor: .unknown,
      os: .linux,
      environment: .gnu
    )
    self.artifactID = artifactID ?? """
    \(swiftVersion)_\(linuxDistribution.name.rawValue)_\(linuxDistribution.release)_\(
      self.targetTriple.cpu.linuxConventionName
    )
    """

    self.versionsConfiguration = try .init(
      swiftVersion: swiftVersion,
      swiftBranch: swiftBranch,
      lldVersion: lldVersion,
      linuxDistribution: linuxDistribution,
      targetTriple: self.targetTriple
    )
    self.pathsConfiguration = .init(
      sourceRoot: sourceRoot,
      artifactID: self.artifactID,
      linuxDistribution: self.versionsConfiguration.linuxDistribution,
      targetTriple: self.targetTriple
    )
    self.downloadableArtifacts = try .init(
      hostTriple: self.hostTriple,
      targetTriple: self.targetTriple,
      shouldUseDocker: shouldUseDocker,
      self.versionsConfiguration,
      self.pathsConfiguration
    )
    self.shouldUseDocker = shouldUseDocker
    self.baseDockerImage = if shouldUseDocker {
      baseDockerImage ?? self.versionsConfiguration.swiftBaseDockerImage
    } else {
      nil
    }
    self.isIncremental = isIncremental
    self.isVerbose = isVerbose

    self.engineCachePath = .path(self.pathsConfiguration.artifactsCachePath.appending("cache.db"))
    self.logger = logger
  }

  private let fileManager = FileManager.default
  private static let dockerCommand = "docker"

  static func getCurrentTriple(isVerbose: Bool) async throws -> Triple {
    let cpuString = try await Shell.readStdout("uname -m", shouldLogCommands: isVerbose)
      .trimmingCharacters(in: .whitespacesAndNewlines)

    guard let cpu = Triple.CPU(rawValue: cpuString) else {
      throw GeneratorError.unknownCPUArchitecture(cpuString)
    }
    #if os(macOS)
    let macOSVersion = try await Shell.readStdout("sw_vers -productVersion", shouldLogCommands: isVerbose)

    guard let majorMacOSVersion = macOSVersion.split(separator: ".").first else {
      throw GeneratorError.unknownMacOSVersion(macOSVersion)
    }
    return Triple(cpu: cpu, vendor: .apple, os: .macosx(version: "\(majorMacOSVersion).0"))
    #elseif os(Linux)
    return Triple(cpu: cpu, vendor: .unknown, os: .linux)
    #else
    fatalError("Triple detection not implemented for the platform that this generator was built on.")
    #endif
  }

  func launchDockerContainer(imageName: String) async throws -> String {
    try await Shell.readStdout(
      """
      \(Self.dockerCommand) run --rm --platform=linux/\(
        self.targetTriple.cpu.debianConventionName
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
      "\(Self.dockerCommand) cp \(id):\(containerPath) \(localPath)",
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
    try await Shell.run("gzip -d \(file)", currentDirectory: directoryPath, shouldLogCommands: self.isVerbose)
  }

  func untar(
    file: FilePath,
    into directoryPath: FilePath,
    stripComponents: Int? = nil
  ) async throws {
    let stripComponentsOption = if let stripComponents {
      "--strip-components=\(stripComponents)"
    } else {
      ""
    }
    try await Shell.run(
      "tar \(stripComponentsOption) -xzf \(file)",
      currentDirectory: directoryPath,
      shouldLogCommands: self.isVerbose
    )
  }

  func unpack(debFile: FilePath, into directoryPath: FilePath) async throws {
    let isVerbose = self.isVerbose
    try await self.inTemporaryDirectory { _, tmp in
      try await Shell.run("ar -x \(debFile)", currentDirectory: tmp, shouldLogCommands: isVerbose)

      try await Shell.run(
        "tar -xf \(tmp)/data.tar.*",
        currentDirectory: directoryPath,
        shouldLogCommands: isVerbose
      )
    }
  }

  func unpack(pkgFile: FilePath, into directoryPath: FilePath) async throws {
    let isVerbose = self.isVerbose
    try await self.inTemporaryDirectory { _, tmp in
      try await Shell.run("xar -xf \(pkgFile)", currentDirectory: tmp, shouldLogCommands: isVerbose)
      try await Shell.run(
        "cat \(tmp)/*.pkg/Payload | gunzip -cd | cpio -i",
        currentDirectory: directoryPath,
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
