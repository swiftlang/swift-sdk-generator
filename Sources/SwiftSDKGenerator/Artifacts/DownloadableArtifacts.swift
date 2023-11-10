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

import struct Foundation.URL
import GeneratorEngine
import struct SystemPackage.FilePath

/// Information about the OS for which the artifact is built, if it's downloaded as prebuilt.
enum ArtifactOS: Hashable {
  init(_ tripleOS: Triple.OS, _ versions: VersionsConfiguration) {
    switch tripleOS {
    case .linux:
      self = .linux(versions.linuxDistribution)
    case .macosx, .darwin:
      self = .macOS
    case .wasi:
      self = .wasi
    case .win32:
      self = .windows
    }
  }

  case linux(LinuxDistribution)
  case macOS
  case wasi
  case windows

  var llvmBinaryURLSuffix: String {
    switch self {
    case .linux: "linux-gnu"
    case .macOS: "apple-darwin22.0"
    case .wasi: fatalError()
    case .windows: fatalError()
    }
  }
}

typealias CPUMapping = [Triple.CPU: String]

struct DownloadableArtifacts: Sendable {
  @CacheKey
  struct Item: Sendable {
    let remoteURL: URL
    var localPath: FilePath
    let isPrebuilt: Bool
  }

  let hostSwift: Item
  private(set) var hostLLVM: Item
  let targetSwift: Item

  private let shouldUseDocker: Bool
  var allItems: [Item] {
    if self.shouldUseDocker {
      [self.hostSwift, self.hostLLVM]
    } else {
      [self.hostSwift, self.hostLLVM, self.targetSwift]
    }
  }

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
      isPrebuilt: true
    )

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
      isPrebuilt: true
    )

    self.targetSwift = .init(
      remoteURL: versions.swiftDownloadURL(),
      localPath: paths.artifactsCachePath
        .appending("target_swift_\(versions.swiftVersion)_\(targetTriple).tar.gz"),
      isPrebuilt: true
    )

    self.shouldUseDocker = shouldUseDocker
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
