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

import Foundation
import GeneratorEngine
import struct SystemPackage.FilePath

public struct LinuxRecipe: SwiftSDKRecipe {
  public enum TargetSwiftSource: Sendable {
    case docker(baseSwiftDockerImage: String)
    case localPackage(FilePath)
    case remoteTarball
  }

  public enum HostSwiftSource: Sendable {
    case localPackage(FilePath)
    case remoteTarball
  }

  let mainTargetTriple: Triple
  let mainHostTriple: Triple
  let linuxDistribution: LinuxDistribution
  let targetSwiftSource: TargetSwiftSource
  let hostSwiftSource: HostSwiftSource
  let versionsConfiguration: VersionsConfiguration

  var shouldUseDocker: Bool {
    if case .docker = self.targetSwiftSource {
      return true
    }
    return false
  }

  public init(
    targetTriple: Triple,
    hostTriple: Triple,
    linuxDistribution: LinuxDistribution,
    swiftVersion: String,
    swiftBranch: String?,
    lldVersion: String,
    withDocker: Bool,
    fromContainerImage: String?,
    hostSwiftPackagePath: String?,
    targetSwiftPackagePath: String?
  ) throws {
    let versionsConfiguration = try VersionsConfiguration(
      swiftVersion: swiftVersion,
      swiftBranch: swiftBranch,
      lldVersion: lldVersion,
      linuxDistribution: linuxDistribution,
      targetTriple: targetTriple
    )

    let targetSwiftSource: LinuxRecipe.TargetSwiftSource
    if let targetSwiftPackagePath {
      targetSwiftSource = .localPackage(FilePath(targetSwiftPackagePath))
    } else {
      if withDocker {
        let imageName = fromContainerImage ?? versionsConfiguration.swiftBaseDockerImage
        targetSwiftSource = .docker(baseSwiftDockerImage: imageName)
      } else {
        targetSwiftSource = .remoteTarball
      }
    }
    let hostSwiftSource: HostSwiftSource
    if let hostSwiftPackagePath {
      hostSwiftSource = .localPackage(FilePath(hostSwiftPackagePath))
    } else {
      hostSwiftSource = .remoteTarball
    }

    self.init(
      mainTargetTriple: targetTriple,
      mainHostTriple: hostTriple,
      linuxDistribution: linuxDistribution,
      targetSwiftSource: targetSwiftSource,
      hostSwiftSource: hostSwiftSource,
      versionsConfiguration: versionsConfiguration
    )
  }

  public init(
    mainTargetTriple: Triple,
    mainHostTriple: Triple,
    linuxDistribution: LinuxDistribution,
    targetSwiftSource: TargetSwiftSource,
    hostSwiftSource: HostSwiftSource,
    versionsConfiguration: VersionsConfiguration
  ) {
    self.mainTargetTriple = mainTargetTriple
    self.mainHostTriple = mainHostTriple
    self.linuxDistribution = linuxDistribution
    self.targetSwiftSource = targetSwiftSource
    self.hostSwiftSource = hostSwiftSource
    self.versionsConfiguration = versionsConfiguration
  }

  public func applyPlatformOptions(toolset: inout Toolset, targetTriple: Triple) {
    toolset.swiftCompiler = Toolset.ToolProperties(extraCLIOptions: [
      "-use-ld=lld",
      "-Xlinker",
      "-R/usr/lib/swift/linux/",
    ])
    toolset.cxxCompiler = Toolset.ToolProperties(extraCLIOptions: ["-lstdc++"])
    toolset.linker = Toolset.ToolProperties(path: "ld.lld")
    toolset.librarian = Toolset.ToolProperties(path: "llvm-ar")
  }

  public var defaultArtifactID: String {
    """
    \(self.versionsConfiguration.swiftVersion)_\(self.linuxDistribution.name.rawValue)_\(
      self.linuxDistribution
        .release
    )_\(
      self.mainTargetTriple.arch!.linuxConventionName
    )
    """
  }

  func sdkDirPath(paths: PathsConfiguration) -> FilePath {
    paths.swiftSDKRootPath
      .appending("\(self.linuxDistribution.name.rawValue)-\(self.linuxDistribution.release).sdk")
  }

  public func makeSwiftSDK(
    generator: SwiftSDKGenerator,
    engine: Engine,
    httpClient client: some HTTPClientProtocol
  ) async throws -> SwiftSDKProduct {
    let sdkDirPath = self.sdkDirPath(paths: generator.pathsConfiguration)
    if !generator.isIncremental {
      try await generator.removeRecursively(at: sdkDirPath)
    }
    try await generator.createDirectoryIfNeeded(at: sdkDirPath)

    var downloadableArtifacts = try DownloadableArtifacts(
      hostTriple: mainHostTriple,
      targetTriple: generator.targetTriple,
      self.versionsConfiguration,
      generator.pathsConfiguration
    )

    try await generator.downloadArtifacts(
      client,
      engine,
      downloadableArtifacts: &downloadableArtifacts,
      itemsToDownload: { artifacts in
        var items = [artifacts.hostLLVM]
        switch self.targetSwiftSource {
        case .remoteTarball:
          items.append(artifacts.targetSwift)
        case .docker, .localPackage: break
        }
        switch self.hostSwiftSource {
        case .remoteTarball:
          items.append(artifacts.hostSwift)
        case .localPackage: break
        }
        return items
      }
    )

    if !self.shouldUseDocker {
      guard case let .ubuntu(version) = linuxDistribution else {
        throw GeneratorError
          .distributionSupportsOnlyDockerGenerator(self.linuxDistribution)
      }

      try await generator.downloadUbuntuPackages(
        client,
        engine,
        requiredPackages: version.requiredPackages,
        versionsConfiguration: self.versionsConfiguration,
        sdkDirPath: sdkDirPath
      )
    }

    switch self.hostSwiftSource {
    case let .localPackage(filePath):
      try await generator.rsync(
        from: filePath.appending("usr"), to: generator.pathsConfiguration.toolchainDirPath
      )
    case .remoteTarball:
      try await generator.unpackHostSwift(
        hostSwiftPackagePath: downloadableArtifacts.hostSwift.localPath
      )
    }

    switch self.targetSwiftSource {
    case let .docker(baseSwiftDockerImage):
      try await generator.copyTargetSwiftFromDocker(
        targetDistribution: self.linuxDistribution,
        baseDockerImage: baseSwiftDockerImage,
        sdkDirPath: sdkDirPath
      )
    case let .localPackage(filePath):
      try await generator.copyTargetSwift(
        from: filePath.appending("usr/lib"), sdkDirPath: sdkDirPath
      )
    case .remoteTarball:
      try await generator.unpackTargetSwiftPackage(
        targetSwiftPackagePath: downloadableArtifacts.targetSwift.localPath,
        relativePathToRoot: [FilePath.Component(self.versionsConfiguration.swiftDistributionName())!],
        sdkDirPath: sdkDirPath
      )
    }

    try await generator.prepareLLDLinker(engine, llvmArtifact: downloadableArtifacts.hostLLVM)

    try await generator.fixAbsoluteSymlinks(sdkDirPath: sdkDirPath)

    let targetCPU = generator.targetTriple.arch!
    try await generator.fixGlibcModuleMap(
      at: generator.pathsConfiguration.toolchainDirPath
        .appending("/usr/lib/swift/linux/\(targetCPU.linuxConventionName)/glibc.modulemap"),
      hostTriple: self.mainHostTriple
    )

    try await generator.symlinkClangHeaders()

    let autolinkExtractPath = generator.pathsConfiguration.toolchainBinDirPath.appending("swift-autolink-extract")

    if await !generator.doesFileExist(at: autolinkExtractPath) {
      logGenerationStep("Fixing `swift-autolink-extract` symlink...")
      try await generator.createSymlink(at: autolinkExtractPath, pointingTo: "swift")
    }

    return SwiftSDKProduct(sdkDirPath: sdkDirPath, hostTriples: [self.mainHostTriple])
  }
}
