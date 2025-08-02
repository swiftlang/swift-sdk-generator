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

import Helpers

import struct Foundation.URL
import struct SystemPackage.FilePath

extension Triple {
  fileprivate var llvmBinaryURLSuffix: String {
    switch (self.os, self.arch) {
    case (.linux, .aarch64): return "aarch64-linux-gnu"
    case (.linux, .x86_64): return "x86_64-linux-gnu-ubuntu-22.04"
    case (.macosx, .aarch64): return "arm64-apple-darwin22.0"
    case (.macosx, .x86_64): return "x86_64-apple-darwin22.0"
    default: fatalError("\(self) is not supported as LLVM host platform yet")
    }
  }
}

typealias CPUMapping = [Triple.Arch: String]

struct DownloadableArtifacts: Sendable {
  struct Item: Sendable, CacheKey {
    let remoteURL: URL
    var localPath: FilePath
    let isPrebuilt: Bool
  }

  let hostSwift: Item
  private(set) var hostLLVM: Item
  let targetSwift: Item

  private let versions: VersionsConfiguration
  private let paths: PathsConfiguration

  init(
    hostTriples: [Triple],
    targetTriple: Triple,
    _ versions: VersionsConfiguration,
    _ paths: PathsConfiguration
  ) throws {
    self.versions = versions
    self.paths = paths

    guard let hostTriple = hostTriples.first else {
      throw StringError("no host triples")
    }

    if hostTriples.allSatisfy({ $0.os == .macosx }) {
      self.hostSwift = .init(
        remoteURL: versions.swiftDownloadURL(
          subdirectory: "xcode",
          platform: "osx",
          fileExtension: "pkg"
        ),
        localPath: paths.artifactsCachePath
          .appending("host_swift_\(versions.swiftVersion)_apple-macos.pkg"),
        isPrebuilt: true
      )
    } else if hostTriple.os == .linux {
      // Amazon Linux 2 is chosen for its best compatibility with all Swift-supported Linux hosts
      let hostArchSuffix =
        hostTriple.arch == .aarch64 ? "-\(Triple.Arch.aarch64.linuxConventionName)" : ""
      self.hostSwift = .init(
        remoteURL: versions.swiftDownloadURL(
          subdirectory: "amazonlinux2\(hostArchSuffix)",
          platform: "amazonlinux2\(hostArchSuffix)",
          fileExtension: "tar.gz"
        ),
        localPath: paths.artifactsCachePath
          .appending("host_swift_\(versions.swiftVersion)_\(hostTriple.triple).tar.gz"),
        isPrebuilt: true
      )
    } else {
      if hostTriples.count > 1 {
        throw StringError(
          "unsupported host triples \(hostTriples.map { "\($0)" }.joined(separator: ", ")) (only macOS supports multiple host triples)"
        )
      } else {
        throw StringError("unsupported host triple \(hostTriple)")
      }
    }

    self.hostLLVM = .init(
      remoteURL: URL(
        string: """
          https://github.com/llvm/llvm-project/releases/download/llvmorg-\(
            versions.lldVersion
          )/clang+llvm-\(
            versions.lldVersion
          )-\(hostTriple.llvmBinaryURLSuffix).tar.xz
          """
      )!,
      localPath: paths.artifactsCachePath
        .appending("host_llvm_\(versions.lldVersion)_\(hostTriple.triple).tar.xz"),
      isPrebuilt: true
    )

    self.targetSwift = .init(
      remoteURL: versions.swiftDownloadURL(),
      localPath: paths.artifactsCachePath
        .appending(
          "target_swift_\(versions.swiftVersion)_\(versions.swiftPlatform)_\(targetTriple.archName).tar.gz"
        ),
      isPrebuilt: true
    )
  }

  mutating func useLLVMSources() {
    self.hostLLVM = .init(
      remoteURL: URL(
        string: """
          https://github.com/llvm/llvm-project/releases/download/llvmorg-\(
            self.versions.lldVersion
          )/llvm-project-\(
            self.versions.lldVersion
          ).src.tar.xz
          """
      )!,
      localPath: self.paths.artifactsCachePath
        .appending("llvm_\(self.versions.lldVersion).src.tar.xz"),
      isPrebuilt: false
    )
  }
}

struct StringError: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) {
    self.description = description
  }
}
