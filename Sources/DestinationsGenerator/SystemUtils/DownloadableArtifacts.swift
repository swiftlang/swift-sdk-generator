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

import struct Foundation.URL
import struct SystemPackage.FilePath

private let knownUbuntuSwiftVersions = [
    "22.04": [
        "5.7.3-RELEASE": "312a18d0d2f207620349e3a373200f369fc1a6aad1b7f2365d55aa8a10881a59"
    ]
]

private let knownMacOSSwiftVersions = [
    "5.7.3-RELEASE": "ba3516845eb8f4469a8bb06a273687f05791187324a3843996af32a73a2a687d"
]

private let knownMacOSLLVMVersions = [
    "15.0.7": "867c6afd41158c132ef05a8f1ddaecf476a26b91c85def8e124414f9a9ba188d",
    "16.0.0": "2041587b90626a4a87f0de14a5842c14c6c3374f42c8ed12726ef017416409d9"
]

public struct DownloadableArtifacts: Sendable {
  public struct Item: Sendable {
    let remoteURL: URL
    let localPath: FilePath
    let checksum: String?
  }

  let buildTimeTripleSwift: Item
  let buildTimeTripleLLVM: Item
  let runTimeTripleSwift: Item

  init(_ versions: VersionsConfiguration, _ paths: PathsConfiguration) {
    self.buildTimeTripleSwift = .init(
      remoteURL: URL(
        string: """
        https://download.swift.org/\(
          versions.swiftBranch
        )/xcode/swift-\(versions.swiftVersion)/swift-\(versions.swiftVersion)-osx.pkg
        """
      )!,
      localPath: paths.artifactsCachePath
        .appending("buildtime_swift_\(versions.swiftVersion)_\(Triple.availableTriples.macOS).pkg"),
      checksum: knownMacOSSwiftVersions[versions.swiftVersion]
    )

    self.buildTimeTripleLLVM = .init(
      remoteURL: URL(
        string: """
        https://github.com/llvm/llvm-project/releases/download/llvmorg-\(
          versions.lldVersion
        )/clang+llvm-\(
          versions.lldVersion
        )-\(Triple.availableTriples.darwin.cpu)-apple-\(Triple.availableTriples.darwin.os).tar.xz
        """
      )!,
      localPath: paths.artifactsCachePath
        .appending("buildtime_llvm_\(versions.lldVersion)_\(Triple.availableTriples.macOS).tar.xz"),
      checksum: knownMacOSLLVMVersions[versions.lldVersion]
    )

    self.runTimeTripleSwift = .init(
      remoteURL: URL(
        string: """
        https://download.swift.org/\(versions.swiftBranch)/ubuntu\(
          versions.ubuntuVersion.replacingOccurrences(of: ".", with: "")
        )/swift-\(versions.swiftVersion)/swift-\(versions.swiftVersion)-ubuntu\(versions.ubuntuVersion).tar.gz
        """
      )!,
      localPath: paths.artifactsCachePath
        .appending("runtime_swift_\(versions.swiftVersion)_\(Triple.availableTriples.linux).tar.gz"),
      checksum: knownUbuntuSwiftVersions[versions.ubuntuVersion]?[versions.swiftVersion]
    )
  }

  var allItems: [Item] { [buildTimeTripleSwift, buildTimeTripleLLVM, runTimeTripleSwift] }
}
