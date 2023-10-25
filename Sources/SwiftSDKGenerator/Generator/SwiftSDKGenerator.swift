//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2022-2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
import SystemPackage

/// Implementation of ``SwiftSDKGenerator`` for the local file system.
public actor SwiftSDKGenerator {
  public let hostTriple: Triple
  public let targetTriple: Triple
  public let artifactID: String
  public let versionsConfiguration: VersionsConfiguration
  public let pathsConfiguration: PathsConfiguration
  public var downloadableArtifacts: DownloadableArtifacts
  public let shouldUseDocker: Bool
  public let isVerbose: Bool

  public init(
    hostCPUArchitecture: Triple.CPU?,
    targetCPUArchitecture: Triple.CPU?,
    swiftVersion: String,
    swiftBranch: String?,
    lldVersion: String,
    linuxDistribution: LinuxDistribution,
    shouldUseDocker: Bool,
    isVerbose: Bool
  ) async throws {
    logGenerationStep("Looking up configuration values...")

    let sourceRoot = FilePath(#file)
      .removingLastComponent()
      .removingLastComponent()
      .removingLastComponent()
      .removingLastComponent()

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
    self.artifactID = """
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
    self.isVerbose = isVerbose
  }

  private let fileManager = FileManager.default

  #if arch(arm64)
  private static let homebrewPrefix = "/opt/homebrew"
  #elseif arch(x86_64)
  private static let homebrewPrefix = "/usr/local"
  #endif

  private static let homebrewPath = "PATH='/bin:/usr/bin:\(SwiftSDKGenerator.homebrewPrefix)/bin'"

  private static let dockerCommand = "\(SwiftSDKGenerator.homebrewPath) docker"

  public static func getCurrentTriple(isVerbose: Bool) async throws -> Triple {
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

  public static func isChecksumValid(artifact: DownloadableArtifacts.Item, isVerbose: Bool) async throws -> Bool {
    guard let expectedChecksum = artifact.checksum else { return false }

    let computedChecksum = try await String(
      Shell.readStdout("openssl dgst -sha256 \(artifact.localPath)", shouldLogCommands: isVerbose)
        .split(separator: "= ")[1]
        // drop the trailing newline
        .dropLast()
    )

    guard computedChecksum == expectedChecksum else {
      print("SHA256 digest of file at `\(artifact.localPath)` does not match expected value: \(expectedChecksum)")
      return false
    }

    return true
  }

  private func buildDockerImage(name: String, dockerfileDirectory: FilePath) async throws {
    try await Shell.run(
      "\(Self.dockerCommand) build . -t \(name)",
      currentDirectory: dockerfileDirectory,
      shouldLogCommands: self.isVerbose
    )
  }

  public func buildDockerImage(baseImage: String) async throws -> String {
    try await self.inTemporaryDirectory { generator, tmp in
      try await generator.writeFile(
        at: tmp.appending("Dockerfile"),
        Data(
          """
          FROM \(baseImage)
          """.utf8
        )
      )

      let versions = generator.versionsConfiguration
      let imageName =
        """
        swiftlang/swift-sdk:\(versions.swiftBareSemVer)-\(versions.linuxDistribution.name)-\(
          versions.linuxDistribution.release
        )
        """

      try await generator.buildDockerImage(name: imageName, dockerfileDirectory: tmp)

      return imageName
    }
  }

  public func launchDockerContainer(imageName: String) async throws -> String {
    try await Shell
      .readStdout(
        "\(Self.dockerCommand) run -d \(imageName) tail -f /dev/null",
        shouldLogCommands: self.isVerbose
      )
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public func runOnDockerContainer(id: String, command: String) async throws {
    try await Shell.run(
      "\(Self.dockerCommand) exec \(id) \(command)",
      shouldLogCommands: self.isVerbose
    )
  }

  public func copyFromDockerContainer(
    id: String,
    from containerPath: FilePath,
    to localPath: FilePath
  ) async throws {
    try await Shell.run(
      "\(Self.dockerCommand) cp \(id):\(containerPath) \(localPath)",
      shouldLogCommands: self.isVerbose
    )
  }

  public func stopDockerContainer(id: String) async throws {
    try await Shell.run(
      """
      \(Self.dockerCommand) stop \(id) && \
      \(Self.dockerCommand) rm -v \(id)
      """,
      shouldLogCommands: self.isVerbose
    )
  }

  public func doesFileExist(at path: FilePath) -> Bool {
    self.fileManager.fileExists(atPath: path.string)
  }

  public func removeFile(at path: FilePath) throws {
    try self.fileManager.removeItem(atPath: path.string)
  }

  public func writeFile(at path: FilePath, _ data: Data) throws {
    try data.write(to: URL(fileURLWithPath: path.string), options: .atomic)
  }

  public func readFile(at path: FilePath) throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: path.string))
  }

  public func rsync(from source: FilePath, to destination: FilePath) async throws {
    try self.createDirectoryIfNeeded(at: destination)
    try await Shell.run("rsync -a \(source) \(destination)", shouldLogCommands: self.isVerbose)
  }

  public func createSymlink(at source: FilePath, pointingTo destination: FilePath) throws {
    try self.fileManager.createSymbolicLink(
      atPath: source.string,
      withDestinationPath: destination.string
    )
  }

  public func findSymlinks(at directory: FilePath) throws -> [(FilePath, FilePath)] {
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

  public func copy(from source: FilePath, to destination: FilePath) throws {
    try self.removeRecursively(at: destination)
    try self.fileManager.copyItem(atPath: source.string, toPath: destination.string)
  }

  public func createDirectoryIfNeeded(at directoryPath: FilePath) throws {
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

  public func removeRecursively(at path: FilePath) throws {
    // Can't use `FileManager.fileExists` here, because it isn't good enough for symlinks. It always
    // tries to resolve a symlink before checking.
    if (try? self.fileManager.attributesOfItem(atPath: path.string)) != nil {
      try self.fileManager.removeItem(atPath: path.string)
    }
  }

  func gunzip(file: FilePath, into directoryPath: FilePath) async throws {
    try await Shell.run("gzip -d \(file)", currentDirectory: directoryPath, shouldLogCommands: self.isVerbose)
  }

  public func untar(
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
        "PATH='/bin:/usr/bin:\(Self.homebrewPrefix)/bin' tar -xf \(tmp)/data.tar.*",
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

  public func unpack(file: FilePath, into directoryPath: FilePath) async throws {
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

  public func buildCMakeProject(_ projectPath: FilePath, options: String) async throws -> FilePath {
    try await Shell.run(
      """
      PATH='/bin:/usr/bin:\(Self.homebrewPrefix)/bin' \
      cmake -B build -G Ninja -S llvm -DCMAKE_BUILD_TYPE=Release \(options)
      """,
      currentDirectory: projectPath
    )

    let buildDirectory = projectPath.appending("build")
    try await Shell.run("PATH='/bin:/usr/bin:\(Self.homebrewPrefix)/bin' ninja", currentDirectory: buildDirectory)

    return buildDirectory
  }

  public func inTemporaryDirectory<T: Sendable>(
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
