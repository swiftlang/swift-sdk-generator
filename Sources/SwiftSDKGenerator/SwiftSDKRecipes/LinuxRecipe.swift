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

import AsyncHTTPClient
import Foundation
import GeneratorEngine
import struct SystemPackage.FilePath

public struct LinuxRecipe: SwiftSDKRecipe {
  public enum TargetSwiftSource: Sendable {
    case docker(baseSwiftDockerImage: String)
    case tarball
  }

  let mainTargetTriple: Triple
  let linuxDistribution: LinuxDistribution
  let targetSwiftSource: TargetSwiftSource
  let versionsConfiguration: VersionsConfiguration

  var shouldUseDocker: Bool {
    if case .docker = self.targetSwiftSource {
      return true
    }
    return false
  }

  public init(
    targetTriple: Triple,
    linuxDistribution: LinuxDistribution,
    swiftVersion: String,
    swiftBranch: String?,
    lldVersion: String,
    withDocker: Bool,
    fromContainerImage: String?
  ) throws {
    let versionsConfiguration = try VersionsConfiguration(
      swiftVersion: swiftVersion,
      swiftBranch: swiftBranch,
      lldVersion: lldVersion,
      linuxDistribution: linuxDistribution,
      targetTriple: targetTriple
    )

    let targetSwiftSource: LinuxRecipe.TargetSwiftSource
    if withDocker {
      let imageName = fromContainerImage ?? versionsConfiguration.swiftBaseDockerImage
      targetSwiftSource = .docker(baseSwiftDockerImage: imageName)
    } else {
      targetSwiftSource = .tarball
    }

    self.init(
      mainTargetTriple: targetTriple,
      linuxDistribution: linuxDistribution,
      targetSwiftSource: targetSwiftSource,
      versionsConfiguration: versionsConfiguration
    )
  }

  public init(
    mainTargetTriple: Triple,
    linuxDistribution: LinuxDistribution,
    targetSwiftSource: TargetSwiftSource,
    versionsConfiguration: VersionsConfiguration
  ) {
    self.mainTargetTriple = mainTargetTriple
    self.linuxDistribution = linuxDistribution
    self.targetSwiftSource = targetSwiftSource
    self.versionsConfiguration = versionsConfiguration
  }

  public func applyPlatformOptions(toolset: inout Toolset) {
    toolset.swiftCompiler = Toolset.ToolProperties(extraCLIOptions: ["-use-ld=lld", "-Xlinker", "-R/usr/lib/swift/linux/"])
    toolset.cxxCompiler = Toolset.ToolProperties(extraCLIOptions: ["-lstdc++"])
    toolset.linker = Toolset.ToolProperties(path: "ld.lld")
    toolset.librarian = Toolset.ToolProperties(path: "llvm-ar")
  }

  public var defaultArtifactID: String {
    """
    \(versionsConfiguration.swiftVersion)_\(linuxDistribution.name.rawValue)_\(linuxDistribution.release)_\(
    mainTargetTriple.cpu.linuxConventionName
    )
    """
  }

  func sdkDirPath(paths: PathsConfiguration) -> FilePath {
    paths.swiftSDKRootPath
      .appending("\(linuxDistribution.name.rawValue)-\(linuxDistribution.release).sdk")
  }

  public func makeSwiftSDK(
    generator: SwiftSDKGenerator,
    engine: Engine,
    httpClient client: HTTPClient
  ) async throws -> SwiftSDKProduct {
    let sdkDirPath = self.sdkDirPath(paths: generator.pathsConfiguration)
    if generator.isIncremental {
      try await generator.removeRecursively(at: sdkDirPath)
    }
    try await generator.createDirectoryIfNeeded(at: sdkDirPath)

    var downloadableArtifacts = try DownloadableArtifacts(
      hostTriple: generator.hostTriple,
      targetTriple: generator.targetTriple,
      shouldUseDocker: shouldUseDocker,
      versionsConfiguration,
      generator.pathsConfiguration
    )

    try await generator.downloadArtifacts(client, engine, downloadableArtifacts: &downloadableArtifacts)

    if !self.shouldUseDocker {
      guard case let .ubuntu(version) = linuxDistribution else {
        throw GeneratorError
          .distributionSupportsOnlyDockerGenerator(self.linuxDistribution)
      }

      try await generator.downloadUbuntuPackages(
        client,
        engine,
        requiredPackages: version.requiredPackages,
        versionsConfiguration: versionsConfiguration,
        sdkDirPath: sdkDirPath
      )
    }

    try await generator.unpackHostSwift(
      hostSwiftPackagePath: downloadableArtifacts.hostSwift.localPath
    )

    switch self.targetSwiftSource {
    case let .docker(baseSwiftDockerImage):
      try await generator.copyTargetSwiftFromDocker(
        targetDistribution: self.linuxDistribution,
        baseDockerImage: baseSwiftDockerImage,
        sdkDirPath: sdkDirPath
      )
    case .tarball:
      try await generator.unpackTargetSwiftPackage(
        targetSwiftPackagePath: downloadableArtifacts.targetSwift.localPath,
        relativePathToRoot: [FilePath.Component(versionsConfiguration.swiftDistributionName())!],
        sdkDirPath: sdkDirPath
      )
    }

    try await generator.prepareLLDLinker(engine, llvmArtifact: downloadableArtifacts.hostLLVM)

    try await generator.fixAbsoluteSymlinks(sdkDirPath: sdkDirPath)

    let targetCPU = generator.targetTriple.cpu
    try await generator.fixGlibcModuleMap(
      at: generator.pathsConfiguration.toolchainDirPath
        .appending("/usr/lib/swift/linux/\(targetCPU.linuxConventionName)/glibc.modulemap")
    )

    try await generator.symlinkClangHeaders()

    let autolinkExtractPath = generator.pathsConfiguration.toolchainBinDirPath.appending("swift-autolink-extract")

    if await !generator.doesFileExist(at: autolinkExtractPath) {
      logGenerationStep("Fixing `swift-autolink-extract` symlink...")
      try await generator.createSymlink(at: autolinkExtractPath, pointingTo: "swift")
    }

    return SwiftSDKProduct(sdkDirPath: sdkDirPath)
  }
}
