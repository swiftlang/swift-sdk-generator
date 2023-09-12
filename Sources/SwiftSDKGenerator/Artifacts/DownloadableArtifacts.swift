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

private let knownLinuxSwiftVersions = [
  LinuxDistribution.ubuntu(.jammy): [
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

#if os(macOS)
private let knownLLVMVersions: [String: (Triple.OS, [Triple.CPU: String])] = [
  "15.0.7": (
    .darwin(version: "22.0"),
    [
      Triple.CPU.arm64: "867c6afd41158c132ef05a8f1ddaecf476a26b91c85def8e124414f9a9ba188d",
    ]
  ),
  "16.0.0": (
    .darwin(version: "22.0"),
    [
      Triple.CPU.arm64: "2041587b90626a4a87f0de14a5842c14c6c3374f42c8ed12726ef017416409d9",
    ]
  ),
  "16.0.1": (
    .darwin(version: "22.0"),
    [
      Triple.CPU.arm64: "cb487fa991f047dc79ae36430cbb9ef14621c1262075373955b1d97215c75879",
    ]
  ),
  "16.0.4": (
    .darwin(version: "22.0"),
    [
      Triple.CPU.arm64: "429b8061d620108fee636313df55a0602ea0d14458c6d3873989e6b130a074bd",
    ]
  ),
  "16.0.5": (
    .darwin(version: "22.0"),
    [
      Triple.CPU.arm64: "1aed0787417dd915f0101503ce1d2719c8820a2c92d4a517bfc4044f72035bcc",
    ]
  ),
]
#else
private let knownLLVMVersions: [String: (Triple.OS, [Triple.CPU: String])] = [:]
#endif

public struct DownloadableArtifacts: Sendable {
  public struct Item: Sendable {
    let remoteURL: URL
    var localPath: FilePath
    let checksum: String?
    let isPrebuilt: Bool
  }

  let hostSwift: Item
  let hostLLVM: Item
  let targetSwift: Item

  let allItems: [Item]

  init(
    hostTriple: Triple,
    targetTriple: Triple,
    shouldUseDocker: Bool,
    _ versions: VersionsConfiguration,
    _ paths: PathsConfiguration
  ) throws {
    self.hostSwift = .init(
      remoteURL: versions.swiftDownloadURL(
        subdirectory: "xcode",
        platform: "osx",
        fileExtension: "pkg"
      ),
      localPath: paths.artifactsCachePath
        .appending("host_swift_\(versions.swiftVersion)_\(hostTriple).pkg"),
      checksum: knownMacOSSwiftVersions[versions.swiftVersion]?[hostTriple.cpu],
      isPrebuilt: true
    )

    var llvmTriple = hostTriple
    if let llvmOS = knownLLVMVersions[versions.lldVersion]?.0 {
      llvmTriple.os = llvmOS

      self.hostLLVM = .init(
        remoteURL: URL(
          string: """
          https://github.com/llvm/llvm-project/releases/download/llvmorg-\(
            versions.lldVersion
          )/clang+llvm-\(
            versions.lldVersion
          )-\(llvmTriple).tar.xz
          """
        )!,
        localPath: paths.artifactsCachePath
          .appending("host_llvm_\(versions.lldVersion)_\(llvmTriple).tar.xz"),
        checksum: knownLLVMVersions[versions.lldVersion]?.1[hostTriple.cpu],
        isPrebuilt: true
      )
    } else {
      self.hostLLVM = .init(
        remoteURL: URL(
          string: """
          https://github.com/llvm/llvm-project/releases/download/llvmorg-\(
            versions.lldVersion
          )/clang+llvm-\(
            versions.lldVersion
          )-\(llvmTriple).tar.xz
          """
        )!,
        localPath: paths.artifactsCachePath
          .appending("host_llvm_\(versions.lldVersion)_\(llvmTriple).tar.xz"),
        checksum: knownLLVMVersions[versions.lldVersion]?.1[hostTriple.cpu],
        isPrebuilt: false
      )
    }

    self.targetSwift = .init(
      remoteURL: versions.swiftDownloadURL(),
      localPath: paths.artifactsCachePath
        .appending("target_swift_\(versions.swiftVersion)_\(targetTriple).tar.gz"),
      checksum: knownLinuxSwiftVersions[versions.linuxDistribution]?[versions.swiftVersion]?[targetTriple.cpu],
      isPrebuilt: true
    )

    self.allItems = if shouldUseDocker {
      [self.hostSwift, self.hostLLVM]
    } else {
      [self.hostSwift, self.hostLLVM, self.targetSwift]
    }
  }
}
