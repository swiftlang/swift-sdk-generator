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

import GeneratorEngine
import struct SystemPackage.FilePath

private let unusedDarwinPlatforms = [
  "watchsimulator",
  "iphonesimulator",
  "appletvsimulator",
  "iphoneos",
  "watchos",
  "appletvos",
]

private let unusedHostBinaries = [
  "clangd",
  "docc",
  "dsymutil",
  "sourcekit-lsp",
  "swift-package",
  "swift-package-collection",
]

extension SwiftSDKGenerator {
  func unpackHostSwift(hostSwiftPackagePath: FilePath) async throws {
    logGenerationStep("Unpacking and copying Swift binaries for the host triple...")
    let pathsConfiguration = self.pathsConfiguration

    try await inTemporaryDirectory { fileSystem, tmpDir in
      try await fileSystem.unpack(file: hostSwiftPackagePath, into: tmpDir)
      // Remove libraries for platforms we don't intend cross-compiling to
      for platform in unusedDarwinPlatforms {
        try await fileSystem.removeRecursively(at: tmpDir.appending("usr/lib/swift/\(platform)"))
        try await fileSystem.removeRecursively(at: tmpDir.appending("usr/lib/swift_static/\(platform)"))
      }
      try await fileSystem.removeRecursively(at: tmpDir.appending("usr/lib/sourcekitd.framework"))

      for binary in unusedHostBinaries {
        try await fileSystem.removeRecursively(at: tmpDir.appending("usr/bin/\(binary)"))
      }

      try await fileSystem.rsync(from: tmpDir.appending("usr"), to: pathsConfiguration.toolchainDirPath)
    }
  }

  func unpackTargetSwiftPackage(targetSwiftPackagePath: FilePath, relativePathToRoot: [FilePath.Component], sdkDirPath: FilePath) async throws {
    logGenerationStep("Unpacking Swift distribution for the target triple...")

    try await inTemporaryDirectory { fs, tmpDir in
      try await fs.unpack(file: targetSwiftPackagePath, into: tmpDir)
      try await fs.copyTargetSwift(
        from: tmpDir.appending(relativePathToRoot).appending("usr/lib"), sdkDirPath: sdkDirPath
      )
    }
  }

  func prepareLLDLinker(_ engine: Engine, llvmArtifact: DownloadableArtifacts.Item) async throws {
    logGenerationStep("Unpacking and copying `lld` linker...")
    let pathsConfiguration = self.pathsConfiguration
    let targetOS = self.targetTriple.os

    let untarDestination = pathsConfiguration.artifactsCachePath.appending(
      FilePath.Component(llvmArtifact.localPath.stem!)!.stem
    )
    try self.createDirectoryIfNeeded(at: untarDestination)
    try await self.untar(
      file: llvmArtifact.localPath,
      into: untarDestination,
      stripComponents: 1
    )

    let unpackedLLDPath = if llvmArtifact.isPrebuilt {
      untarDestination.appending("bin/lld")
    } else {
      try await engine[CMakeBuildQuery(
        sourcesDirectory: untarDestination,
        outputBinarySubpath: ["bin", "lld"],
        options: "-DLLVM_ENABLE_PROJECTS=lld -DLLVM_TARGETS_TO_BUILD=''"
      )].path
    }

    let toolchainLLDPath = switch targetOS {
    case .linux:
      pathsConfiguration.toolchainBinDirPath.appending("ld.lld")
    case .wasi:
      pathsConfiguration.toolchainBinDirPath.appending("wasm-ld")
    default:
      fatalError("Unknown target OS to prepare lld \"\(targetOS)\"")
    }

    try self.copy(from: unpackedLLDPath, to: toolchainLLDPath)
  }
}
