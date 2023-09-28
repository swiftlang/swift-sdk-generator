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

/// This protocol abstracts over possible generators, which allows creating a mock generator for testing purposes.
public protocol SwiftSDKGenerator: AnyObject {
  // MARK: configuration

  var hostTriple: Triple { get }
  var targetTriple: Triple { get }
  var artifactID: String { get }
  var versionsConfiguration: VersionsConfiguration { get }
  var pathsConfiguration: PathsConfiguration { get }
  var downloadableArtifacts: DownloadableArtifacts { get set }
  var shouldUseDocker: Bool { get }
  var isVerbose: Bool { get }

  static func getCurrentTriple(isVerbose: Bool) async throws -> Triple

  // MARK: shell commands

  func untar(file: FilePath, into directoryPath: FilePath, stripComponents: Int?) async throws
  func unpack(file: FilePath, into directoryPath: FilePath) async throws
  func rsync(from source: FilePath, to destination: FilePath) async throws
  func buildCMakeProject(_ projectPath: FilePath) async throws -> FilePath

  static func isChecksumValid(artifact: DownloadableArtifacts.Item, isVerbose: Bool) async throws -> Bool

  // MARK: common operations on files

  func doesFileExist(at path: FilePath) -> Bool
  func copy(from source: FilePath, to destination: FilePath) throws
  func removeFile(at path: FilePath) throws

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

  func buildDockerImage(baseImage: String) async throws -> String
  func launchDockerContainer(imageName: String) async throws -> String
  func runOnDockerContainer(id: String, command: String) async throws
  func copyFromDockerContainer(id: String, from containerPath: FilePath, to localPath: FilePath) async throws
  func stopDockerContainer(id: String) async throws
}
