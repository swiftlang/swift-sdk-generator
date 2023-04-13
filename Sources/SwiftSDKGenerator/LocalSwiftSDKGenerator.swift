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
public final class LocalSwiftSDKGenerator: SwiftSDKGenerator {
  public let buildTimeTriple: Triple
  public let runTimeTriple: Triple
  public let artifactID: String
  public let versionsConfiguration: VersionsConfiguration
  public let pathsConfiguration: PathsConfiguration
  public let downloadableArtifacts: DownloadableArtifacts
  public let shouldUseDocker: Bool
  public let isVerbose: Bool

  public init(
    runTimeCPUArchitecture: Triple.CPU?,
    swiftVersion: String,
    swiftBranch: String?,
    lldVersion: String,
    ubuntuVersion: String,
    shouldUseDocker: Bool,
    isVerbose: Bool
  ) async throws {
    logGenerationStep("Looking up configuration values...")

    let sourceRoot = FilePath(#file)
      .removingLastComponent()
      .removingLastComponent()
      .removingLastComponent()
    self.buildTimeTriple = try await Self.getCurrentTriple(isVerbose: isVerbose)
    self.runTimeTriple = Triple(
      cpu: runTimeCPUArchitecture ?? self.buildTimeTriple.cpu,
      vendor: .unknown,
      os: .linux,
      environment: .gnu
    )
    self.artifactID = "\(swiftVersion)_ubuntu_\(ubuntuVersion)_\(self.runTimeTriple.cpu.linuxConventionName)"

    self.versionsConfiguration = try .init(
      swiftVersion: swiftVersion,
      swiftBranch: swiftBranch,
      lldVersion: lldVersion,
      ubuntuVersion: ubuntuVersion,
      runTimeTriple: self.runTimeTriple
    )
    self.pathsConfiguration = .init(
      sourceRoot: sourceRoot,
      artifactID: self.artifactID,
      ubuntuRelease: self.versionsConfiguration.ubuntuRelease,
      runTimeTriple: self.runTimeTriple
    )
    self.downloadableArtifacts = try .init(
      buildTimeTriple: self.buildTimeTriple,
      runTimeTriple: self.runTimeTriple,
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

  public func buildDockerImage(name: String, dockerfileDirectory: FilePath) async throws {
    try await Shell.run(
      "PATH='/bin:/usr/bin:\(Self.homebrewPrefix)/bin' docker build . -t \(name)",
      currentDirectory: dockerfileDirectory,
      shouldLogCommands: self.isVerbose
    )
  }

  public func launchDockerContainer(imageName: String) async throws -> String {
    try await Shell
      .readStdout(
        "PATH='/bin:/usr/bin:\(Self.homebrewPrefix)/bin' docker create \(imageName)",
        shouldLogCommands: self.isVerbose
      )
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public func copyFromDockerContainer(
    id: String,
    from containerPath: FilePath,
    to localPath: FilePath
  ) async throws {
    try await Shell.run(
      "PATH='/bin:/usr/bin:\(Self.homebrewPrefix)/bin' docker cp \(id):\(containerPath) \(localPath)",
      shouldLogCommands: self.isVerbose
    )
  }

  public func stopDockerContainer(id: String) async throws {
    try await Shell.run(
      "PATH='/bin:/usr/bin:\(Self.homebrewPrefix)/bin' docker rm -v \(id)",
      shouldLogCommands: self.isVerbose
    )
  }

  public func doesFileExist(at path: FilePath) -> Bool {
    self.fileManager.fileExists(atPath: path.string)
  }

  public func writeFile(at path: FilePath, _ data: Data) throws {
    try data.write(to: URL(fileURLWithPath: path.string), options: .atomic)
  }

  public func readFile(at path: FilePath) throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: path.string))
  }

  public func rsync(from source: FilePath, to destination: FilePath) async throws {
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
    // tries to
    // resolve a symlink before checking.
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
    let stripComponentsOption: String
    if let stripComponents {
      stripComponentsOption = "--strip-components=\(stripComponents)"
    } else {
      stripComponentsOption = ""
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

  public func inTemporaryDirectory<T>(
    _ closure: @Sendable (LocalSwiftSDKGenerator, FilePath) async throws -> T
  ) async throws -> T {
    let tmp = FilePath(NSTemporaryDirectory())
      .appending("swift-sdk-generator-\(UUID().uuidString.prefix(6))")

    try self.createDirectoryIfNeeded(at: tmp)

    let result = try await closure(self, tmp)

    try removeRecursively(at: tmp)

    return result
  }
}

// Explicitly marking `LocalSwiftSDKGenerator` as non-`Sendable` for safety.
@available(*, unavailable)
extension LocalSwiftSDKGenerator: Sendable {}
