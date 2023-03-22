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

import struct SystemPackage.FilePath

public struct PathsConfiguration: Sendable {
  init(sourceRoot: FilePath, artifactID: String, ubuntuRelease: String) {
    self.sourceRoot = sourceRoot
    self.artifactBundlePath = sourceRoot
      .appending("Bundles")
      .appending("\(artifactID).artifactbundle")
    self.artifactsCachePath = sourceRoot.appending("Artifacts")
    self.destinationRootPath = self.artifactBundlePath
      .appending(artifactID)
      .appending(Triple.availableTriples.linux.description)
    self.sdkDirPath = self.destinationRootPath.appending("ubuntu-\(ubuntuRelease).sdk")
    self.toolchainDirPath = self.destinationRootPath.appending("swift.xctoolchain")
    self.toolchainBinDirPath = self.toolchainDirPath.appending("usr/bin")
  }

  let sourceRoot: FilePath
  let artifactBundlePath: FilePath
  let artifactsCachePath: FilePath
  let destinationRootPath: FilePath
  let sdkDirPath: FilePath
  let toolchainDirPath: FilePath
  let toolchainBinDirPath: FilePath
}
