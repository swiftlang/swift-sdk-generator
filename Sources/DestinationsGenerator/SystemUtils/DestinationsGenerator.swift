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

private let ubuntuReleases = [
  "22.04": "jammy",
]

public struct VersionsConfiguration {
  init(swiftVersion: String, llvmVersion: String, ubuntuVersion: String) throws {
    guard let ubuntuRelease = ubuntuReleases[ubuntuVersion]
    else { throw GeneratorError.unsupportedUbuntuVersion(ubuntuVersion) }

    self.swiftVersion = swiftVersion
    swiftBranch = "swift-\(swiftVersion.lowercased())"
    self.llvmVersion = llvmVersion
    self.ubuntuVersion = ubuntuVersion
    self.ubuntuRelease = ubuntuRelease
  }

  let swiftVersion: String
  let swiftBranch: String
  let llvmVersion: String
  let ubuntuVersion: String
  let ubuntuRelease: String
}

public struct PathsConfiguration {
  init(sourceRoot: FilePath, artifactID: String, ubuntuRelease: String) {
    self.sourceRoot = sourceRoot
    artifactBundlePath = sourceRoot
      .appending("cc-destination.artifactbundle")
    artifactsCachePath = sourceRoot.appending("artifacts-cache")
    destinationRootPath = artifactBundlePath
      .appending(artifactID)
      .appending(Triple.availableTriples.linux.description)
    sdkDirPath = destinationRootPath.appending("ubuntu-\(ubuntuRelease).sdk")
    toolchainDirPath = destinationRootPath.appending("swift.xctoolchain")
    toolchainBinDirPath = toolchainDirPath.appending("usr/bin")
  }

  let sourceRoot: FilePath
  let artifactBundlePath: FilePath
  let artifactsCachePath: FilePath
  let destinationRootPath: FilePath
  let sdkDirPath: FilePath
  let toolchainDirPath: FilePath
  let toolchainBinDirPath: FilePath
}

public protocol DestinationsGenerator {
  // MARK: configuration

  var artifactID: String { get }
  var versionsConfiguration: VersionsConfiguration { get }
  var pathsConfiguration: PathsConfiguration { get }
  var downloadableArtifacts: DownloadableArtifacts { get }

  // MARK: shell commands

  func untar(file: FilePath, into directoryPath: FilePath, stripComponents: Int?) async throws
  func unpack(file: FilePath, into directoryPath: FilePath) async throws
  func rsync(from source: FilePath, to destination: FilePath) async throws

  static func isChecksumValid(artifact: DownloadableArtifacts.Item) async throws -> Bool

  // MARK: common operations on files

  func doesFileExist(at path: FilePath) -> Bool
  func copy(from source: FilePath, to destination: FilePath) throws

  // MARK: common operations on directories

  func createDirectoryIfNeeded(at directoryPath: FilePath) throws
  func removeRecursively(at path: FilePath) throws
  func inTemporaryDirectory<T>(
    _ closure: @Sendable (Self, FilePath) async throws -> T
  ) async throws -> T

  // MARK: file I/O

  func readFile(at path: FilePath) throws -> Data
  func writeFile(at path: FilePath, _ data: Data) throws

  // MARK: symbolic links

  func findSymlinks(at directory: FilePath) throws -> [(FilePath, FilePath)]
  func createSymlink(at source: FilePath, pointingTo destination: FilePath) throws

  // MARK: Docker operations

  func buildDockerImage(name: String, dockerfileDirectory: FilePath) async throws
  func launchDockerContainer(imageName: String) async throws -> String
  func copyFromDockerContainer(id: String, from containerPath: FilePath, to localPath: FilePath) async throws
  func stopDockerContainer(id: String) async throws
}
