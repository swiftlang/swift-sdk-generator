//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
import Helpers
import Logging

import struct SystemPackage.FilePath

package struct FreeBSDRecipe: SwiftSDKRecipe {
  package func applyPlatformOptions(
    metadata: inout SwiftSDKMetadataV4,
    paths: PathsConfiguration,
    targetTriple: Triple,
    isForEmbeddedSwift: Bool
  ) {
    // Inside of the SDK, the sysroot directory has the same name as the
    // target triple.
    let targetTripleString = targetTriple.triple
    let properties = SwiftSDKMetadataV4.TripleProperties(
      sdkRootPath: targetTripleString,
      toolsetPaths: ["toolset.json"]
    )
    metadata.targetTriples = [
      targetTripleString: properties
    ]
  }

  package func applyPlatformOptions(
    toolset: inout Toolset,
    targetTriple: Triple,
    isForEmbeddedSwift: Bool
  ) {
    // The toolset data is always the same. It just instructs Swift and LLVM
    // to use the LLVM linker lld instead of whatever the system linker is.
    // It also instructs the linker to set the runtime paths so that the
    // dynamic linker can find the Swift runtime libraries.
    let swiftCompilerOptions = Toolset.ToolProperties(
      extraCLIOptions: [
        "-Xclang-linker", "-fuse-ld=lld", "-Xclang-linker", "-Wl,-rpath",
        "-Xclang-linker", "-Wl,/usr/local/swift/lib:/usr/local/swift/lib/swift/freebsd",
      ]
    )
    toolset.swiftCompiler = swiftCompilerOptions
  }

  /// The FreeBSD version that we are targeting.
  package let freeBSD: FreeBSD

  /// A toolchain compiled for FreeBSD whose contents we should use for the
  /// SDK.
  ///
  /// If this is nil, then the resulting SDK won't be able to compile Swift
  /// code and will only be able to build code for C and C++.
  private let sourceSwiftToolchain: FilePath?

  /// The triple of the target architecture that the SDK will support.
  private let mainTargetTriple: Triple

  /// The target architecture that the SDK will support (e.g., aarch64).
  private let architecture: String

  /// The default filename of the produced SDK.
  package var defaultArtifactID: String {
    """
    FreeBSD_\(self.freeBSD.version)_\(self.mainTargetTriple.archName)
    """
  }

  /// The logging object used by this class for debugging.
  package let logger: Logging.Logger

  /// Toolchain paths needed for cross-compilation. This is a dictionary that
  /// maps paths in the toolchain to the destination path in the SDK. We do
  /// this because our packaging script for FreeBSD installs Swift content
  /// in /usr/local/swift for ease of packaging, but there's no need to do so
  /// in the SDK.
  private let neededToolchainPaths = [
    "usr/local/swift/lib/swift": "usr/lib/swift",
    "usr/local/swift/lib/swift_static": "usr/lib/swift_static",
    "usr/local/swift/include/swift": "usr/include/swift",
    "usr/local/swift/include": "usr/include/swift",
  ]

  private func baseSysURL() -> String {
    // The FreeBSD package system uses arm64 instead of aarch64 in its URLs.
    let architectureString: String
    if mainTargetTriple.arch == .aarch64 {
      architectureString = "arm64"
    } else {
      architectureString = architecture
    }

    let majorVersion = freeBSD.majorVersion
    let minorVersion = freeBSD.minorVersion
    return
      "https://download.freebsd.org/ftp/releases/\(architectureString)/\(majorVersion).\(minorVersion)-RELEASE/base.txz"
  }

  package func makeSwiftSDK(
    generator: SwiftSDKGenerator,
    engine: Helpers.QueryEngine,
    httpClient: some HTTPClientProtocol
  ) async throws -> SwiftSDKProduct {
    let swiftSDKRootPath = generator.pathsConfiguration.swiftSDKRootPath
    try await generator.createDirectoryIfNeeded(at: swiftSDKRootPath)
    logger.debug("swiftSDKRootPath = \(swiftSDKRootPath)")

    // Create the sysroot directory. This is where all of the FreeBSD content
    // as well as the Swift toolchain will be copied to.
    let sysrootDir = swiftSDKRootPath.appending(mainTargetTriple.triple)
    try await generator.createDirectoryIfNeeded(at: sysrootDir)
    logger.debug("sysrootDir = \(sysrootDir)")

    let cachePath = generator.pathsConfiguration.artifactsCachePath
    logger.debug("cachePath = \(cachePath)")

    // Download the FreeBSD base system if we don't have it in the cache.
    let freeBSDBaseSystemTarballPath = cachePath.appending("FreeBSD-\(freeBSD.version)-base.txz")
    let freebsdBaseSystemUrl = URL(string: baseSysURL())!
    if await !generator.doesFileExist(at: freeBSDBaseSystemTarballPath) {
      try await httpClient.downloadFile(from: freebsdBaseSystemUrl, to: freeBSDBaseSystemTarballPath)
    }

    // Extract the FreeBSD base system into the sysroot.
    let neededPathsInSysroot = ["lib", "usr/include", "usr/lib"]
    try await generator.untar(
      file: freeBSDBaseSystemTarballPath,
      into: sysrootDir,
      paths: neededPathsInSysroot
    )

    // If the user provided a Swift toolchain, then also copy its contents
    // into the sysroot. We don't need the entire toolchain, only the libraries
    // and headers.
    if let sourceSwiftToolchain {
      // If the toolchain is a directory, then we need to expand it.
      let pathToCompleteToolchain: FilePath
      if await generator.doesDirectoryExist(at: sourceSwiftToolchain) {
        pathToCompleteToolchain = sourceSwiftToolchain
      } else {
        let expandedToolchainName = "ExpandedSwiftToolchain-FreeBSD-\(freeBSD.version)"
        pathToCompleteToolchain = cachePath.appending(expandedToolchainName)

        if await generator.doesFileExist(at: pathToCompleteToolchain) {
          try await generator.removeFile(at: pathToCompleteToolchain)
        }

        logger.debug("Expanding archived Swift toolchain at \(sourceSwiftToolchain) into \(pathToCompleteToolchain)")
        try await generator.createDirectoryIfNeeded(at: pathToCompleteToolchain)
        try await generator.untar(
          file: sourceSwiftToolchain,
          into: pathToCompleteToolchain
        )
      }

      logger.debug("Copying required items from toolchain into SDK")
      for (sourcePath, destinationPath) in neededToolchainPaths {
        let sourcePath = pathToCompleteToolchain.appending(sourcePath)
        let destinationPath = sysrootDir.appending(destinationPath)

        logger.debug("Copying item in toolchain at path \(sourcePath) into SDK at \(destinationPath)")
        try await generator.createDirectoryIfNeeded(at: destinationPath.removingLastComponent())
        try await generator.copy(from: sourcePath, to: destinationPath)
      }
    }

    // Return the path to the newly created SDK.
    return .init(sdkDirPath: swiftSDKRootPath, hostTriples: nil)
  }

  public init(
    freeBSDVersion: FreeBSD,
    mainTargetTriple: Triple,
    sourceSwiftToolchain: FilePath?,
    logger: Logging.Logger
  ) {
    self.freeBSD = freeBSDVersion
    self.mainTargetTriple = mainTargetTriple
    self.architecture = mainTargetTriple.archName
    self.logger = logger
    self.sourceSwiftToolchain = sourceSwiftToolchain
  }
}
