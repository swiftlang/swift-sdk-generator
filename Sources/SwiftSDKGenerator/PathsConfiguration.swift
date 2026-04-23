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

import struct SystemPackage.FilePath

public struct PathsConfiguration: Sendable {
  /// Errors thrown by ``PathsConfiguration/validateBundleName(_:)``.
  package enum BundleNameValidationError: Error, CustomStringConvertible {
    case empty
    case containsPathSeparator(String)
    case pathTraversal(String)

    package var description: String {
      switch self {
      case .empty:
        return "bundle name must not be empty"
      case .containsPathSeparator(let name):
        return "bundle name must be a single path component, got \"\(name)\""
      case .pathTraversal(let name):
        return "bundle name must not be a path-traversal segment, got \"\(name)\""
      }
    }
  }

  /// Validate that `name` is safe to use as the on-disk `.artifactbundle`
  /// directory name. The bundle name is appended to `<sourceRoot>/Bundles/`,
  /// so it must be a single path component that cannot escape that directory.
  ///
  /// Rejects: empty strings, names containing `/` or `\`, and the special
  /// names `.` and `..` (whether bare or as the first segment).
  package static func validateBundleName(_ name: String) throws {
    if name.isEmpty {
      throw BundleNameValidationError.empty
    }
    if name.contains("/") || name.contains("\\") {
      throw BundleNameValidationError.containsPathSeparator(name)
    }
    if name == "." || name == ".." || name.hasPrefix("../") || name.hasPrefix("..\\") {
      throw BundleNameValidationError.pathTraversal(name)
    }
  }

  init(sourceRoot: FilePath, artifactID: String, bundleName: String? = nil, targetTriple: Triple) {
    self.sourceRoot = sourceRoot
    self.artifactBundlePath =
      sourceRoot
      .appending("Bundles")
      .appending("\(bundleName ?? artifactID).artifactbundle")
    self.artifactsCachePath = sourceRoot.appending("Artifacts")
    self.swiftSDKRootPath = self.artifactBundlePath
      .appending(artifactID)
      .appending(targetTriple.triple)
    self.toolchainDirPath = self.swiftSDKRootPath.appending("swift.xctoolchain")
    self.toolchainBinDirPath = self.toolchainDirPath.appending("usr/bin")
  }

  let sourceRoot: FilePath
  let artifactBundlePath: FilePath
  let artifactsCachePath: FilePath
  let swiftSDKRootPath: FilePath
  let toolchainDirPath: FilePath
  let toolchainBinDirPath: FilePath
}
