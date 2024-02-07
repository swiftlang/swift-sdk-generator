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

import AsyncHTTPClient
import GeneratorEngine
import struct SystemPackage.FilePath

public struct WebAssemblyRecipe: SwiftSDKRecipe {
  let hostSwiftPackagePath: FilePath?
  let targetSwiftPackagePath: FilePath
  let wasiSysroot: FilePath
  let swiftVersion: String

  public init(
    hostSwiftPackagePath: FilePath?,
    targetSwiftPackagePath: FilePath,
    wasiSysroot: FilePath,
    swiftVersion: String
  ) {
    self.hostSwiftPackagePath = hostSwiftPackagePath
    self.targetSwiftPackagePath = targetSwiftPackagePath
    self.wasiSysroot = wasiSysroot
    self.swiftVersion = swiftVersion
  }

  public var defaultArtifactID: String {
    "\(self.swiftVersion)_wasm"
  }

  public func applyPlatformOptions(toolset: inout Toolset) {
    // We only support static linking for WebAssembly for now, so make it the default.
    toolset.swiftCompiler = Toolset.ToolProperties(extraCLIOptions: ["-static-stdlib"])
  }

  public func applyPlatformOptions(
    metadata: inout SwiftSDKMetadataV4.TripleProperties,
    paths: PathsConfiguration,
    targetTriple: Triple
  ) {
    var relativeToolchainDir = paths.toolchainDirPath
    guard relativeToolchainDir.removePrefix(paths.swiftSDKRootPath) else {
      fatalError("The toolchain bin directory path must be a subdirectory of the Swift SDK root path.")
    }
    metadata.swiftStaticResourcesPath = relativeToolchainDir.appending("usr/lib/swift_static").string
    metadata.swiftResourcesPath = metadata.swiftStaticResourcesPath
  }

  public func makeSwiftSDK(
    generator: SwiftSDKGenerator,
    engine: Engine,
    httpClient: HTTPClient
  ) async throws -> SwiftSDKProduct {
    let pathsConfiguration = generator.pathsConfiguration
    logGenerationStep("Copying Swift binaries for the host triple...")
    if let hostSwiftPackagePath {
      try await generator.rsync(from: hostSwiftPackagePath.appending("usr"), to: pathsConfiguration.toolchainDirPath)

      logGenerationStep("Removing unused toolchain components...")
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
        platforms: unusedDarwinPlatforms + ["embedded"],
        libraries: unusedHostLibraries + liblldbNames,
        binaries: unusedHostBinaries + ["lldb", "lldb-argdumper", "lldb-server"]
      )
    }

    try await self.copyTargetSwift(from: self.targetSwiftPackagePath.appending("usr/lib"), generator: generator)

    let autolinkExtractPath = generator.pathsConfiguration.toolchainBinDirPath.appending("swift-autolink-extract")

    // WebAssembly object file requires `swift-autolink-extract`
    if await !generator.doesFileExist(at: autolinkExtractPath) {
      logGenerationStep("Fixing `swift-autolink-extract` symlink...")
      try await generator.createSymlink(at: autolinkExtractPath, pointingTo: "swift")
    }

    // Copy the WASI sysroot into the SDK bundle.
    let sdkDirPath = pathsConfiguration.swiftSDKRootPath.appending("WASI.sdk")
    try await generator.rsyncContents(from: self.wasiSysroot, to: sdkDirPath)

    return SwiftSDKProduct(sdkDirPath: sdkDirPath)
  }

  func copyTargetSwift(from distributionPath: FilePath, generator: SwiftSDKGenerator) async throws {
    let pathsConfiguration = generator.pathsConfiguration
    logGenerationStep("Copying Swift core libraries for the target triple into Swift SDK bundle...")
    for (pathWithinPackage, pathWithinSwiftSDK) in [
      ("clang", pathsConfiguration.toolchainDirPath.appending("usr/lib")),
      ("swift/wasi", pathsConfiguration.toolchainDirPath.appending("usr/lib/swift")),
      ("swift_static/wasi", pathsConfiguration.toolchainDirPath.appending("usr/lib/swift_static")),
      ("swift_static/shims", pathsConfiguration.toolchainDirPath.appending("usr/lib/swift_static")),
      ("swift_static/CoreFoundation", pathsConfiguration.toolchainDirPath.appending("usr/lib/swift_static")),
    ] {
      try await generator.rsync(from: distributionPath.appending(pathWithinPackage), to: pathWithinSwiftSDK)
    }
  }
}
