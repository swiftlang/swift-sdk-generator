//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2022-2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Helpers
import Logging

import struct SystemPackage.FilePath

package struct WebAssemblyRecipe: SwiftSDKRecipe {
  let hostSwiftPackage: HostToolchainPackage?

  /// Optional to allow creating WebAssembly Swift SDKs that don't include Swift support and therefore can only target C/C++.
  let targetSwiftPackagePath: FilePath?
  let wasiSysroot: FilePath
  let swiftVersion: String
  let targetTriples: [Triple]
  package let logger: Logger

  package struct HostToolchainPackage: Sendable {
    let path: FilePath
    let triples: [Triple]

    package init(path: FilePath, triples: [Triple]) {
      self.path = path
      self.triples = triples
    }
  }

  package init(
    hostSwiftPackage: HostToolchainPackage?,
    targetSwiftPackagePath: FilePath?,
    wasiSysroot: FilePath,
    swiftVersion: String,
    targetTriples: [Triple],
    logger: Logger
  ) {
    self.hostSwiftPackage = hostSwiftPackage
    self.targetSwiftPackagePath = targetSwiftPackagePath
    self.wasiSysroot = wasiSysroot
    self.swiftVersion = swiftVersion
    self.targetTriples = targetTriples
    self.logger = logger
  }

  package var defaultArtifactID: String {
    if hostSwiftPackage == nil && targetSwiftPackagePath == nil {
      return "wasm"
    }
    return "\(self.swiftVersion)_wasm"
  }

  package let shouldSupportEmbeddedSwift = true

  package func applyPlatformOptions(toolset: inout Toolset, targetTriple: Triple, isForEmbeddedSwift: Bool) {
    // We only support static linking for WebAssembly for now, so make it the default.
    toolset.swiftCompiler = Toolset.ToolProperties(extraCLIOptions: ["-static-stdlib"])

    if isForEmbeddedSwift {
      let ccOptions = ["-D__EMBEDDED_SWIFT__"]
      toolset.cCompiler = Toolset.ToolProperties(extraCLIOptions: ccOptions)
      toolset.cxxCompiler = Toolset.ToolProperties(extraCLIOptions: ccOptions)

      toolset.swiftCompiler?.extraCLIOptions?.append(
        contentsOf: [
          "-enable-experimental-feature", "Embedded", "-wmo",
        ]
      )

      toolset.swiftCompiler?.extraCLIOptions?.append(
        // libraries required for concurrency
        contentsOf: ["-lc++", "-lswift_Concurrency"].flatMap {
          ["-Xlinker", $0]
        }
      )
    }

    if targetTriple.environmentName == "threads" {
      // Enable features required for threading support
      let ccOptions = [
        "-matomics", "-mbulk-memory", "-mthread-model", "posix",
        "-pthread", "-ftls-model=local-exec",
      ]
      // Tell LLVM codegen in swiftc to enable those features via clang options
      toolset.swiftCompiler?.extraCLIOptions?.append(
        contentsOf: ccOptions.flatMap {
          ["-Xcc", $0]
        }
      )
      // Tell the C and C++ compilers to enable those features
      toolset.cCompiler = Toolset.ToolProperties(extraCLIOptions: ccOptions)
      toolset.cxxCompiler = Toolset.ToolProperties(extraCLIOptions: ccOptions)

      let linkerOptions = [
        // Shared memory is required for WASI threads ABI
        // See https://github.com/WebAssembly/wasi-threads for more information.
        "--import-memory", "--export-memory", "--shared-memory",
        // Set the maximum memory size to 1GB because shared memory must specify
        // a maximum size. 1GB is chosen as a conservative default, but it can be
        // overridden by the user-provided --max-memory linker option.
        "--max-memory=1073741824",
      ]
      toolset.linker = Toolset.ToolProperties(extraCLIOptions: linkerOptions)
    }
  }

  package func applyPlatformOptions(
    metadata: inout SwiftSDKMetadataV4,
    paths: PathsConfiguration,
    targetTriple: Triple,
    isForEmbeddedSwift: Bool
  ) {
    var relativeToolchainDir = paths.toolchainDirPath
    guard relativeToolchainDir.removePrefix(paths.swiftSDKRootPath) else {
      fatalError(
        "The toolchain bin directory path must be a subdirectory of the Swift SDK root path."
      )
    }

    var tripleProperties = metadata.targetTriples[targetTriple.triple]!
    tripleProperties.swiftStaticResourcesPath =
      relativeToolchainDir.appending("usr/lib/swift_static").string
    tripleProperties.swiftResourcesPath =
      isForEmbeddedSwift
      ? relativeToolchainDir.appending("usr/lib/swift").string
      : tripleProperties.swiftStaticResourcesPath

    metadata.targetTriples[targetTriple.triple] = tripleProperties
  }

  package func makeSwiftSDK(
    generator: SwiftSDKGenerator,
    engine: QueryEngine,
    httpClient: some HTTPClientProtocol
  ) async throws -> SwiftSDKProduct {
    var hostTriples: [Triple]? = nil
    var sdkDirPaths: [Triple: FilePath] = [:]

    // Set up each target triple's directory
    for (index, targetTriple) in targetTriples.enumerated() {
      let pathsConfiguration = generator.pathsConfiguration(for: targetTriple)

      if index == 0 {
        // First triple: copy all files
        if let targetSwiftLibPath = self.targetSwiftPackagePath?.appending("usr/lib") {
          logger.info("Copying Swift binaries for the host triple...")
          if let hostSwiftPackage {
            hostTriples = hostSwiftPackage.triples
            try await generator.rsync(
              from: hostSwiftPackage.path.appending("usr"),
              to: pathsConfiguration.toolchainDirPath
            )

            logger.info("Removing unused toolchain components...")
            let liblldbNames: [String] = try await {
              let libDirPath = pathsConfiguration.toolchainDirPath.appending("usr/lib")
              guard await generator.doesFileExist(at: libDirPath) else {
                return []
              }
              return try await generator.contentsOfDirectory(at: libDirPath).filter { dirEntry in
                // liblldb is version suffixed: liblldb.so.17.0.0
                dirEntry.hasPrefix("liblldb")
              }
            }()
            try await generator.removeToolchainComponents(
              pathsConfiguration.toolchainDirPath,
              platforms: unusedTargetPlatforms,
              libraries: unusedHostLibraries + liblldbNames,
              binaries: unusedHostBinaries + ["lldb", "lldb-argdumper", "lldb-server"]
            )
            // Merge target Swift package with the host package.
            try await self.mergeTargetSwift(from: targetSwiftLibPath, pathsConfiguration: pathsConfiguration, generator: generator)
          } else {
            // Simply copy the target Swift package into the Swift SDK bundle when building host-agnostic Swift SDK.
            try await generator.createDirectoryIfNeeded(
              at: pathsConfiguration.toolchainDirPath.appending("usr")
            )
            try await generator.copy(
              from: targetSwiftLibPath,
              to: pathsConfiguration.toolchainDirPath.appending("usr/lib")
            )
          }

          let autolinkExtractPath = pathsConfiguration.toolchainBinDirPath.appending(
            "swift-autolink-extract"
          )

          // WebAssembly object file requires `swift-autolink-extract`
          if await !generator.doesFileExist(at: autolinkExtractPath),
            await generator.doesFileExist(
              at: pathsConfiguration.toolchainBinDirPath.appending("swift")
            )
          {
            logger.info("Fixing `swift-autolink-extract` symlink...")
            try await generator.createSymlink(at: autolinkExtractPath, pointingTo: "swift")
          }

          // TODO: Remove this once we drop support for Swift 6.2
          // Embedded Swift looks up clang compiler-rt in a different path.
          let embeddedCompilerRTPath = pathsConfiguration.toolchainDirPath.appending(
            "usr/lib/swift/clang/lib/wasip1"
          )
          if await !generator.doesFileExist(at: embeddedCompilerRTPath) {
            try await generator.createSymlink(
              at: embeddedCompilerRTPath,
              pointingTo: "../../../swift_static/clang/lib/wasi"
            )
          }
        }

        // Copy the WASI sysroot into the Swift SDK bundle.
        let sdkDirPath = pathsConfiguration.swiftSDKRootPath.appending("WASI.sdk")
        try await generator.rsyncContents(from: self.wasiSysroot, to: sdkDirPath)
        sdkDirPaths[targetTriple] = sdkDirPath
      } else {
        // Additional triples: copy from first triple's directory
        let firstTriplePaths = generator.pathsConfiguration(for: targetTriples[0])

        logger.info("Setting up directory for target triple \(targetTriple.triple)...")

        // Copy toolchain
        if self.targetSwiftPackagePath != nil {
          try await generator.rsync(
            from: firstTriplePaths.toolchainDirPath,
            to: pathsConfiguration.swiftSDKRootPath
          )
        }

        // Copy WASI sysroot
        let sdkDirPath = pathsConfiguration.swiftSDKRootPath.appending("WASI.sdk")
        let firstSdkDirPath = firstTriplePaths.swiftSDKRootPath.appending("WASI.sdk")
        try await generator.rsync(from: firstSdkDirPath, to: pathsConfiguration.swiftSDKRootPath)
        sdkDirPaths[targetTriple] = sdkDirPath
      }
    }

    return SwiftSDKProduct(sdkDirPaths: sdkDirPaths, hostTriples: hostTriples)
  }

  /// Merge the target Swift package into the Swift SDK bundle derived from the host Swift package.
  func mergeTargetSwift(from distributionPath: FilePath, pathsConfiguration: PathsConfiguration, generator: SwiftSDKGenerator) async throws {
    logger.info("Copying Swift core libraries for the target triple into Swift SDK bundle...")
    for (pathWithinPackage, pathWithinSwiftSDK, isOptional) in [
      ("clang", pathsConfiguration.toolchainDirPath.appending("usr/lib"), false),
      ("swift/clang", pathsConfiguration.toolchainDirPath.appending("usr/lib/swift"), false),
      ("swift/wasi", pathsConfiguration.toolchainDirPath.appending("usr/lib/swift"), false),
      (
        "swift_static/clang", pathsConfiguration.toolchainDirPath.appending("usr/lib/swift_static"),
        false
      ),
      (
        "swift_static/wasi", pathsConfiguration.toolchainDirPath.appending("usr/lib/swift_static"),
        false
      ),
      (
        "swift_static/shims", pathsConfiguration.toolchainDirPath.appending("usr/lib/swift_static"),
        false
      ),
      // Mark CoreFoundation as optional until we set up build system to build it for WebAssembly
      (
        "swift_static/CoreFoundation",
        pathsConfiguration.toolchainDirPath.appending("usr/lib/swift_static"), true
      ),
    ] {
      if isOptional,
        await !(generator.doesFileExist(at: distributionPath.appending(pathWithinPackage)))
      {
        logger.debug("Skipping optional path \(pathWithinPackage)")
        continue
      }
      try await generator.rsync(
        from: distributionPath.appending(pathWithinPackage),
        to: pathWithinSwiftSDK
      )
    }
  }
}
