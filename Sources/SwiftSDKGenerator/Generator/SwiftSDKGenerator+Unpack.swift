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

import struct SystemPackage.FilePath

let unusedTargetPlatforms = [
  "appletvos",
  "appletvsimulator",
  "embedded",
  "iphoneos",
  "iphonesimulator",
  "watchos",
  "watchsimulator",
  "xros",
  "xrsimulator",
]

let unusedHostBinaries = [
  "clangd",
  "docc",
  "dsymutil",
  "sourcekit-lsp",
  "swift-format",
  "swift-package",
  "swift-package-collection",
  "lldb*",
]

let unusedHostLibraries = [
  "sourcekitd.framework",
  "libsourcekitdInProc.so",
  "liblldb.so*",
]

extension SwiftSDKGenerator {
  func unpackHostSwift(hostSwiftPackagePath: FilePath) async throws {
    logger.logGenerationStep("Unpacking and copying Swift binaries for the host triple...")
    let pathsConfiguration = self.pathsConfiguration

    try self.createDirectoryIfNeeded(at: pathsConfiguration.toolchainDirPath)

    let excludes =
      unusedTargetPlatforms.map { "--exclude usr/lib/swift/\($0)" } +
      unusedTargetPlatforms.map { "--exclude usr/lib/swift_static/\($0)" } +
      unusedHostBinaries.map { "--exclude usr/bin/\($0)" } +
      unusedHostLibraries.map { "--exclude usr/lib/\($0)" }

    if hostSwiftPackagePath.string.contains("tar.gz") {
      try await Shell.run(
        #"""
        tar -xzf \#(hostSwiftPackagePath) -C "\#(pathsConfiguration.toolchainDirPath)" -x \#(excludes.joined(separator: " ")) --strip-components=1
        """#,
        shouldLogCommands: isVerbose
      )
    } else {
      try await Shell.run(
        #"""
        tar -x --to-stdout -f \#(hostSwiftPackagePath) \*.pkg/Payload |
        tar -C "\#(pathsConfiguration.toolchainDirPath)" -x \#(excludes.joined(separator: " ")) --include usr
        """#,
        shouldLogCommands: isVerbose
      )
    }
  }

  func removeToolchainComponents(
    _ packagePath: FilePath,
    platforms: [String] = unusedTargetPlatforms,
    libraries: [String] = unusedHostLibraries,
    binaries: [String] = unusedHostBinaries
  ) async throws {
    // Remove libraries for platforms we don't intend cross-compiling to
    for platform in platforms {
      try self.removeRecursively(at: packagePath.appending("usr/lib/swift/\(platform)"))
      try self.removeRecursively(at: packagePath.appending("usr/lib/swift_static/\(platform)"))
    }
    for binary in binaries {
      try self.removeRecursively(at: packagePath.appending("usr/bin/\(binary)"))
    }
    for library in libraries {
      try self.removeRecursively(at: packagePath.appending("usr/lib/\(library)"))
    }
  }

  func unpackTargetSwiftPackage(
    targetSwiftPackagePath: FilePath,
    relativePathToRoot: [FilePath.Component],
    sdkDirPath: FilePath
  ) async throws {
    logger.logGenerationStep("Unpacking Swift distribution for the target triple...")

    try await inTemporaryDirectory { fs, tmpDir in
      try await fs.unpack(file: targetSwiftPackagePath, into: tmpDir)
      try await fs.copyTargetSwift(
        from: tmpDir.appending(relativePathToRoot).appending("usr"), sdkDirPath: sdkDirPath
      )
    }
  }

  func prepareLLDLinker(_ engine: QueryEngine, llvmArtifact: DownloadableArtifacts.Item) async throws {
    logger.logGenerationStep("Unpacking and copying `lld` linker...")
    let pathsConfiguration = self.pathsConfiguration
    let targetOS = self.targetTriple.os

    let untarDestination = pathsConfiguration.artifactsCachePath.appending(
      FilePath.Component(llvmArtifact.localPath.stem!)!.stem
    )
    try self.createDirectoryIfNeeded(at: untarDestination)

    let unpackedLLDPath: FilePath
    if llvmArtifact.isPrebuilt {
      unpackedLLDPath = try await engine[TarExtractQuery(
        file: llvmArtifact.localPath,
        into: untarDestination,
        outputBinarySubpath: ["bin", "lld"],
        stripComponents: 1
      )].path
    } else {
      try await self.untar(
        file: llvmArtifact.localPath,
        into: untarDestination,
        stripComponents: 1
      )
      unpackedLLDPath = try await engine[CMakeBuildQuery(
        sourcesDirectory: untarDestination,
        outputBinarySubpath: ["bin", "lld"],
        options: "-DLLVM_ENABLE_PROJECTS=lld -DLLVM_TARGETS_TO_BUILD=''"
      )].path
    }

    let toolchainLLDPath: FilePath
    switch targetOS {
    case .linux:
      toolchainLLDPath = pathsConfiguration.toolchainBinDirPath.appending("ld.lld")
    case .wasi:
      toolchainLLDPath = pathsConfiguration.toolchainBinDirPath.appending("wasm-ld")
    default:
      fatalError("Unknown target OS to prepare lld \"\(targetOS?.rawValue ?? "nil")\"")
    }

    try self.copy(from: unpackedLLDPath, to: toolchainLLDPath)
  }
}
