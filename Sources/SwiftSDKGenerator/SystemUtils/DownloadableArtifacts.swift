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
    "5.7.3-RELEASE": [
      Triple.CPU.arm64: "75003d5a995292ae3f858b767fbb89bc3edee99488f4574468a0e44341aec55b",
    ],
    "5.8-RELEASE": [
      Triple.CPU.arm64: "12ea2df36f9af0aefa74f0989009683600978f62223e7dd73b627c90c7fe9273",
    ],
  ],
]

private let knownMacOSSwiftVersions = [
  "5.7.3-RELEASE": [
    Triple.CPU.arm64: "ba3516845eb8f4469a8bb06a273687f05791187324a3843996af32a73a2a687d",
  ],
  "5.8-RELEASE": [
    Triple.CPU.arm64: "9b6cc56993652ca222c86a2d6b7b66abbd50bb92cc526efc2b23d47d40002097",
  ],
  "DEVELOPMENT-SNAPSHOT-2023-03-17-a": [
    Triple.CPU.arm64: "6d1664a84bd95161f65feebde32213c79f5cc9b9d3b12ef658c3216c9c2980d0",
  ],
]

private let knownMacOSLLVMVersions = [
  "15.0.7": [
    Triple.CPU.arm64: "867c6afd41158c132ef05a8f1ddaecf476a26b91c85def8e124414f9a9ba188d",
  ],
  "16.0.0": [
    Triple.CPU.arm64: "2041587b90626a4a87f0de14a5842c14c6c3374f42c8ed12726ef017416409d9",
  ],
  "16.0.1": [
    Triple.CPU.arm64: "cb487fa991f047dc79ae36430cbb9ef14621c1262075373955b1d97215c75879",
  ],
  "16.0.4": [
    Triple.CPU.arm64: "429b8061d620108fee636313df55a0602ea0d14458c6d3873989e6b130a074bd",
  ],
]

private func swiftDownloadURL(
  branch: String,
  version: String,
  subdirectory: String,
  platform: String,
  fileExtension: String
) -> URL {
  URL(
    string: """
    https://download.swift.org/\(
      branch
    )/\(subdirectory)/swift-\(version)/swift-\(version)-\(platform).\(fileExtension)
    """
  )!
}

public struct DownloadableArtifacts: Sendable {
  public struct Item: Sendable {
    let remoteURL: URL
    let localPath: FilePath
    let checksum: String?
  }

  let buildTimeTripleSwift: Item
  let buildTimeTripleLLVM: Item
  let runTimeTripleSwift: Item

  let allItems: [Item]

  init(
    buildTimeTriple: Triple,
    runTimeTriple: Triple,
    shouldUseDocker: Bool,
    _ versions: VersionsConfiguration,
    _ paths: PathsConfiguration
  ) throws {
    self.buildTimeTripleSwift = .init(
      remoteURL: swiftDownloadURL(
        branch: versions.swiftBranch,
        version: versions.swiftVersion,
        subdirectory: "xcode",
        platform: "osx",
        fileExtension: "pkg"
      ),
      localPath: paths.artifactsCachePath
        .appending("buildtime_swift_\(versions.swiftVersion)_\(buildTimeTriple).pkg"),
      checksum: knownMacOSSwiftVersions[versions.swiftVersion]?[buildTimeTriple.cpu]
    )

    self.buildTimeTripleLLVM = .init(
      remoteURL: URL(
        string: """
        https://github.com/llvm/llvm-project/releases/download/llvmorg-\(
          versions.lldVersion
        )/clang+llvm-\(
          versions.lldVersion
        )-\(try buildTimeTriple.darwinFormat).tar.xz
        """
      )!,
      localPath: paths.artifactsCachePath
        .appending("buildtime_llvm_\(versions.lldVersion)_\(buildTimeTriple).tar.xz"),
      checksum: knownMacOSLLVMVersions[versions.lldVersion]?[buildTimeTriple.cpu]
    )

    let subdirectory =
      "ubuntu\(versions.ubuntuVersion.replacingOccurrences(of: ".", with: ""))\(versions.ubuntuArchSuffix)"
    self.runTimeTripleSwift = .init(
      remoteURL: swiftDownloadURL(
        branch: versions.swiftBranch,
        version: versions.swiftVersion,
        subdirectory: subdirectory,
        platform: "ubuntu\(versions.ubuntuVersion)\(versions.ubuntuArchSuffix)",
        fileExtension: "tar.gz"
      ),
      localPath: paths.artifactsCachePath
        .appending("runtime_swift_\(versions.swiftVersion)_\(runTimeTriple).tar.gz"),
      checksum: knownUbuntuSwiftVersions[versions.ubuntuVersion]?[versions.swiftVersion]?[runTimeTriple.cpu]
    )

    if shouldUseDocker {
      allItems = [buildTimeTripleSwift, buildTimeTripleLLVM]
    } else {
      allItems = [buildTimeTripleSwift, buildTimeTripleLLVM, runTimeTripleSwift]
    }
  }
}
