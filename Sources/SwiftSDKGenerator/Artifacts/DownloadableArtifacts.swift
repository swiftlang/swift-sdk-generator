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

enum ArtifactOS: Hashable {
  init(_ tripleOS: Triple.OS, _ versions: VersionsConfiguration) {
    switch tripleOS {
    case .linux:
      self = .linux(versions.linuxDistribution)
    case .macosx, .darwin:
      self = .macOS
    }
  }

  case linux(LinuxDistribution)
  case macOS
  case source

  var llvmBinaryURLSuffix: String {
    switch self {
    case .linux: "linux-gnu"
    case .macOS: "apple-darwin22.0"
    case .source: fatalError()
    }
  }
}

typealias CPUMapping = [Triple.CPU: String]

/// SHA256 hashes of binary LLVM artifacts known to the generator.
private let knownLLVMBinariesVersions: [ArtifactOS: [String: CPUMapping]] = [
  .macOS: [
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
    "16.0.5": [
      Triple.CPU.arm64: "1aed0787417dd915f0101503ce1d2719c8820a2c92d4a517bfc4044f72035bcc",
    ],
  ],
]

/// SHA256 hashes of binary Swift artifacts known to the generator.
private let knownSwiftBinariesVersions: [ArtifactOS: [String: CPUMapping]] = [
  .linux(.ubuntu(.jammy)): [
    "5.7.3-RELEASE": [
      .arm64: "75003d5a995292ae3f858b767fbb89bc3edee99488f4574468a0e44341aec55b",
    ],
    "5.8-RELEASE": [
      .arm64: "12ea2df36f9af0aefa74f0989009683600978f62223e7dd73b627c90c7fe9273",
    ],
    "5.9-RELEASE": [
      .arm64: "30b289e02f7e03c380744ea97fdf0e96985dff504b0f09de23e098fdaf6513f3",
      .x86_64: "bca015e9d727ca39385d7e5b5399f46302d54a02218d40d1c3063662ffc6b42f",
    ],
  ],
  .macOS: [
    "5.7.3-RELEASE": [
      .arm64: "ba3516845eb8f4469a8bb06a273687f05791187324a3843996af32a73a2a687d",
      .x86_64: "ba3516845eb8f4469a8bb06a273687f05791187324a3843996af32a73a2a687d",
    ],
    "5.8-RELEASE": [
      .arm64: "9b6cc56993652ca222c86a2d6b7b66abbd50bb92cc526efc2b23d47d40002097",
      .x86_64: "9b6cc56993652ca222c86a2d6b7b66abbd50bb92cc526efc2b23d47d40002097",
    ],
    "5.9-RELEASE": [
      .arm64: "3cf7a4b2f3efcfcb4fef42b6588a7b1c54f7b0f2d0a479f41c3e1620b045f48e",
      .x86_64: "3cf7a4b2f3efcfcb4fef42b6588a7b1c54f7b0f2d0a479f41c3e1620b045f48e",
    ],
  ],
]

private let knownLLVMSourcesVersions: [String: String] = [
  "16.0.5": "37f540124b9cfd4680666e649f557077f9937c9178489cea285a672e714b2863",
]

public struct DownloadableArtifacts: Sendable {
  public struct Item: Sendable {
    let remoteURL: URL
    var localPath: FilePath
    let checksum: String?
    let isPrebuilt: Bool
  }

  let hostSwift: Item
  private(set) var hostLLVM: Item
  let targetSwift: Item

  let allItems: [Item]

  private let versions: VersionsConfiguration
  private let paths: PathsConfiguration

  init(
    hostTriple: Triple,
    targetTriple: Triple,
    shouldUseDocker: Bool,
    _ versions: VersionsConfiguration,
    _ paths: PathsConfiguration
  ) throws {
    self.versions = versions
    self.paths = paths

    let hostArtifactsOS = ArtifactOS(hostTriple.os, versions)
    self.hostSwift = .init(
      remoteURL: versions.swiftDownloadURL(
        subdirectory: "xcode",
        platform: "osx",
        fileExtension: "pkg"
      ),
      localPath: paths.artifactsCachePath
        .appending("host_swift_\(versions.swiftVersion)_\(hostTriple).pkg"),
      checksum: knownSwiftBinariesVersions[hostArtifactsOS]?[versions.swiftVersion]?[hostTriple.cpu],
      isPrebuilt: true
    )

    if let llvmArtifact = knownLLVMBinariesVersions[hostArtifactsOS]?[versions.lldVersion]?[hostTriple.cpu] {
      self.hostLLVM = .init(
        remoteURL: URL(
          string: """
          https://github.com/llvm/llvm-project/releases/download/llvmorg-\(
            versions.lldVersion
          )/clang+llvm-\(
            versions.lldVersion
          )-\(hostTriple.cpu)-\(hostArtifactsOS.llvmBinaryURLSuffix).tar.xz
          """
        )!,
        localPath: paths.artifactsCachePath
          .appending("host_llvm_\(versions.lldVersion)_\(hostTriple).tar.xz"),
        checksum: llvmArtifact,
        isPrebuilt: true
      )
    } else {
      self.hostLLVM = Self.llvmSources(versions, paths)
    }

    let targetArtifactsOS = ArtifactOS(targetTriple.os, versions)
    self.targetSwift = .init(
      remoteURL: versions.swiftDownloadURL(),
      localPath: paths.artifactsCachePath
        .appending("target_swift_\(versions.swiftVersion)_\(targetTriple).tar.gz"),
      checksum: knownSwiftBinariesVersions[targetArtifactsOS]?[versions.swiftVersion]?[targetTriple.cpu],
      isPrebuilt: true
    )

    self.allItems = if shouldUseDocker {
      [self.hostSwift, self.hostLLVM]
    } else {
      [self.hostSwift, self.hostLLVM, self.targetSwift]
    }
  }

  mutating func useLLVMSources() {
    self.hostLLVM = Self.llvmSources(self.versions, self.paths)
  }

  static func llvmSources(_ versions: VersionsConfiguration, _ paths: PathsConfiguration) -> Item {
    .init(
      remoteURL: URL(
        string: """
        https://github.com/llvm/llvm-project/releases/download/llvmorg-\(
          versions.lldVersion
        )/llvm-project-\(
          versions.lldVersion
        ).src.tar.xz
        """
      )!,
      localPath: paths.artifactsCachePath
        .appending("llvm_\(versions.lldVersion).src.tar.xz"),
      checksum: knownLLVMSourcesVersions[versions.lldVersion],
      isPrebuilt: false
    )
  }
}
