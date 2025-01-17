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

import RegexBuilder
import SystemPackage

import struct Foundation.Data

extension SwiftSDKGenerator {
  func fixAbsoluteSymlinks(sdkDirPath: FilePath) throws {
    logger.logGenerationStep("Fixing up absolute symlinks...")

    for (source, absoluteDestination) in try findSymlinks(at: sdkDirPath).filter({
      $1.string.hasPrefix("/")
    }) {
      guard !absoluteDestination.string.hasPrefix("/etc") else {
        try removeFile(at: source)
        continue
      }
      var relativeSource = source
      var relativeDestination = FilePath()

      let isPrefixRemoved = relativeSource.removePrefix(sdkDirPath)
      precondition(isPrefixRemoved)
      for _ in relativeSource.removingLastComponent().components {
        relativeDestination.append("..")
      }

      relativeDestination.push(absoluteDestination.removingRoot())
      try removeRecursively(at: source)
      try createSymlink(at: source, pointingTo: relativeDestination)

      guard doesFileExist(at: source) else {
        throw FileOperationError.symlinkFixupFailed(
          source: source,
          destination: absoluteDestination
        )
      }
    }
  }

  func symlinkClangHeaders() throws {
    let swiftStaticClangPath = self.pathsConfiguration.toolchainDirPath.appending("usr/lib/swift_static/clang")
    if !doesFileExist(at: swiftStaticClangPath) {
      logger.logGenerationStep("Symlinking clang headers...")
      try self.createSymlink(
        at: self.pathsConfiguration.toolchainDirPath.appending("usr/lib/swift_static/clang"),
        pointingTo: "../swift/clang"
      )
    }
  }
}
