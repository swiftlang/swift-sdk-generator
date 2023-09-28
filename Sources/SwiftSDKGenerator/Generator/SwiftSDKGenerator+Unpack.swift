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
  func unpackHostSwift() async throws {
    logGenerationStep("Unpacking and copying Swift binaries for the host triple...")
    let downloadableArtifacts = self.downloadableArtifacts
    let pathsConfiguration = self.pathsConfiguration

    try await inTemporaryDirectory { fileSystem, tmpDir in
      try await fileSystem.unpack(file: downloadableArtifacts.hostSwift.localPath, into: tmpDir)
      // Remove libraries for platforms we don't intend cross-compiling to
      for platform in unusedDarwinPlatforms {
        try fileSystem.removeRecursively(at: tmpDir.appending("usr/lib/swift/\(platform)"))
      }
      try fileSystem.removeRecursively(at: tmpDir.appending("usr/lib/sourcekitd.framework"))

      for binary in unusedHostBinaries {
        try fileSystem.removeRecursively(at: tmpDir.appending("usr/bin/\(binary)"))
      }

      try await fileSystem.rsync(from: tmpDir.appending("usr"), to: pathsConfiguration.toolchainDirPath)
    }
  }

  func unpackTargetSwiftPackage() async throws {
    logGenerationStep("Unpacking Swift distribution for the target triple...")
    let packagePath = downloadableArtifacts.targetSwift.localPath

    try await inTemporaryDirectory { fs, tmpDir in
      try await fs.unpack(file: packagePath, into: tmpDir)
      try await fs.copyTargetSwift(
        from: tmpDir.appending(
          """
          \(self.versionsConfiguration.swiftDistributionName())/usr/lib
          """
        )
      )
    }
  }

  func unpackLLDLinker() async throws {
    logGenerationStep("Unpacking and copying `lld` linker...")
    let downloadableArtifacts = self.downloadableArtifacts
    let pathsConfiguration = self.pathsConfiguration
    let targetOS = self.targetTriple.os

    try await inTemporaryDirectory { fileSystem, tmpDir in
      let llvmArtifact = downloadableArtifacts.hostLLVM
      try await fileSystem.untar(
        file: llvmArtifact.localPath,
        into: tmpDir,
        stripComponents: 1
      )

      let unpackedLLDPath = if llvmArtifact.isPrebuilt {
        tmpDir.appending("bin/lld")
      } else {
        try await self.buildLLD(llvmSourcesDirectory: tmpDir)
      }

      let toolchainLLDPath = switch targetOS {
      case .linux:
        pathsConfiguration.toolchainBinDirPath.appending("ld.lld")
      case .wasi:
        pathsConfiguration.toolchainBinDirPath.appending("wasm-ld")
      default:
        fatalError()
      }

      try fileSystem.copy(
        from: unpackedLLDPath,
        to: toolchainLLDPath
      )
    }
  }
}
