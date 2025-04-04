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
import Helpers
import Logging

import struct SystemPackage.FilePath

public struct LinuxRecipe: SwiftSDKRecipe {
  public enum TargetSwiftSource: Sendable {
    case docker(baseSwiftDockerImage: String)
    case localPackage(FilePath)
    case remoteTarball
  }

  public enum HostSwiftSource: Sendable, Equatable {
    case localPackage(FilePath)
    case remoteTarball
    case preinstalled
  }

  let mainTargetTriple: Triple
  let mainHostTriple: Triple
  let linuxDistribution: LinuxDistribution
  let targetSwiftSource: TargetSwiftSource
  let hostSwiftSource: HostSwiftSource
  let versionsConfiguration: VersionsConfiguration
  public let logger: Logger

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
    targetSwiftPackagePath: String?,
    includeHostToolchain: Bool = false,
    logger: Logger
  ) throws {
    let versionsConfiguration = try VersionsConfiguration(
      swiftVersion: swiftVersion,
      swiftBranch: swiftBranch,
      lldVersion: lldVersion,
      linuxDistribution: linuxDistribution,
      targetTriple: targetTriple,
      logger: logger
    )

    let targetSwiftSource: LinuxRecipe.TargetSwiftSource
    if let targetSwiftPackagePath {
      targetSwiftSource = .localPackage(FilePath(targetSwiftPackagePath))
    } else {
      if withDocker || fromContainerImage != nil {
        let imageName = fromContainerImage ?? versionsConfiguration.swiftBaseDockerImage
        targetSwiftSource = .docker(baseSwiftDockerImage: imageName)
      } else {
        targetSwiftSource = .remoteTarball
      }
    }
    let hostSwiftSource: HostSwiftSource
    if includeHostToolchain == false {
      hostSwiftSource = .preinstalled
    } else if let hostSwiftPackagePath {
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
      versionsConfiguration: versionsConfiguration,
      logger: logger
    )
  }

  public init(
    mainTargetTriple: Triple,
    mainHostTriple: Triple,
    linuxDistribution: LinuxDistribution,
    targetSwiftSource: TargetSwiftSource,
    hostSwiftSource: HostSwiftSource,
    versionsConfiguration: VersionsConfiguration,
    logger: Logger
  ) {
    self.mainTargetTriple = mainTargetTriple
    self.mainHostTriple = mainHostTriple
    self.linuxDistribution = linuxDistribution
    self.targetSwiftSource = targetSwiftSource
    self.hostSwiftSource = hostSwiftSource
    self.versionsConfiguration = versionsConfiguration
    self.logger = logger
  }

  public func applyPlatformOptions(toolset: inout Toolset, targetTriple: Triple) {
    if self.hostSwiftSource == .preinstalled {
      toolset.rootPath = nil
    }

    var swiftCompilerOptions = ["-Xlinker", "-R/usr/lib/swift/linux/"]

    // Swift 5.9 does not handle the `-use-ld` option properly:
    //   https://github.com/swiftlang/swift-package-manager/issues/7222
    if self.versionsConfiguration.swiftVersion.hasPrefix("5.9") {
      swiftCompilerOptions += ["-Xclang-linker", "--ld-path=ld.lld"]
    } else {
      swiftCompilerOptions.append("-use-ld=lld")

      // 32-bit architectures require libatomic
      if let arch = targetTriple.arch, arch.is32Bit {
        swiftCompilerOptions.append("-latomic")
      }

      if self.hostSwiftSource != .preinstalled {
        toolset.linker = Toolset.ToolProperties(path: "ld.lld")
      }
    }

    toolset.swiftCompiler = Toolset.ToolProperties(extraCLIOptions: swiftCompilerOptions)

    toolset.cxxCompiler = Toolset.ToolProperties(extraCLIOptions: ["-lstdc++"])
    toolset.librarian = Toolset.ToolProperties(path: "llvm-ar")
  }

  public func applyPlatformOptions(
    metadata: inout SwiftSDKMetadataV4.TripleProperties,
    paths: PathsConfiguration,
    targetTriple: Triple
  ) {
    var relativeSDKDir = self.sdkDirPath(paths: paths)
    guard relativeSDKDir.removePrefix(paths.swiftSDKRootPath) else {
      fatalError("The SDK directory path must be a subdirectory of the Swift SDK root path.")
    }
    metadata.swiftResourcesPath = relativeSDKDir.appending("usr/lib/swift").string
    metadata.swiftStaticResourcesPath = relativeSDKDir.appending("usr/lib/swift_static").string
  }

  public var defaultArtifactID: String {
    """
    \(self.versionsConfiguration.swiftVersion)_\(self.linuxDistribution.name.rawValue)_\(
      self.linuxDistribution
        .release
    )_\(
      self.mainTargetTriple.archName
    )
    """
  }

  func sdkDirPath(paths: PathsConfiguration) -> FilePath {
    paths.swiftSDKRootPath
      .appending("\(self.linuxDistribution.name.rawValue)-\(self.linuxDistribution.release).sdk")
  }

  func itemsToDownload(from artifacts: DownloadableArtifacts) -> [DownloadableArtifacts.Item] {
    var items: [DownloadableArtifacts.Item] = []
    if self.hostSwiftSource != .preinstalled
      && self.mainHostTriple.os != .linux
      && !self.versionsConfiguration.swiftVersion.hasPrefix("6.")
    {
      items.append(artifacts.hostLLVM)
    }

    switch self.targetSwiftSource {
    case .remoteTarball:
      items.append(artifacts.targetSwift)
    case .docker, .localPackage: break
    }

    switch self.hostSwiftSource {
    case .remoteTarball:
      items.append(artifacts.hostSwift)
    case .localPackage: break
    case .preinstalled: break
    }
    return items
  }

  var hostTriples: [Triple]? {
    if self.hostSwiftSource == .preinstalled {
      // Swift 5.9 and 5.10 require `supportedTriples` to be set in info.json.
      // FIXME: This can be removed once the SDK generator does not support 5.9/5.10 any more.
      if self.versionsConfiguration.swiftVersion.hasAnyPrefix(from: ["5.9", "5.10"]) {
        return [
          Triple("x86_64-unknown-linux-gnu"),
          Triple("aarch64-unknown-linux-gnu"),
          Triple("x86_64-apple-macos"),
          Triple("arm64-apple-macos"),
        ]
      }

      // Swift 6.0 and later can set `supportedTriples` to nil
      return nil
    }

    return [self.mainHostTriple]
  }

  public func makeSwiftSDK(
    generator: SwiftSDKGenerator,
    engine: QueryEngine,
    httpClient client: some HTTPClientProtocol
  ) async throws -> SwiftSDKProduct {
    if self.linuxDistribution.name == .rhel && self.mainTargetTriple.archName == "armv7" {
      throw GeneratorError.distributionDoesNotSupportArchitecture(
        self.linuxDistribution,
        targetArchName: self.mainTargetTriple.archName
      )
    }

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
      itemsToDownload: { artifacts in itemsToDownload(from: artifacts) }
    )

    if !self.shouldUseDocker {
      switch linuxDistribution {
      case .ubuntu(let version):
        try await generator.downloadDebianPackages(
          client,
          engine,
          requiredPackages: version.requiredPackages,
          versionsConfiguration: self.versionsConfiguration,
          sdkDirPath: sdkDirPath
        )
      case .debian(let version):
        try await generator.downloadDebianPackages(
          client,
          engine,
          requiredPackages: version.requiredPackages,
          versionsConfiguration: self.versionsConfiguration,
          sdkDirPath: sdkDirPath
        )
      default:
        throw
          GeneratorError
          .distributionSupportsOnlyDockerGenerator(self.linuxDistribution)
      }
    }

    switch self.hostSwiftSource {
    case let .localPackage(filePath):
      try await generator.rsync(
        from: filePath.appending("usr"),
        to: generator.pathsConfiguration.toolchainDirPath
      )
    case .remoteTarball:
      try await generator.unpackHostSwift(
        hostSwiftPackagePath: downloadableArtifacts.hostSwift.localPath
      )
    case .preinstalled:
      break
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
        from: filePath.appending("usr"),
        sdkDirPath: sdkDirPath
      )
    case .remoteTarball:
      try await generator.unpackTargetSwiftPackage(
        targetSwiftPackagePath: downloadableArtifacts.targetSwift.localPath,
        relativePathToRoot: [
          FilePath.Component(self.versionsConfiguration.swiftDistributionName())!
        ],
        sdkDirPath: sdkDirPath
      )
    }

    logger.info("Removing unused toolchain components from target SDK...")
    try await generator.removeToolchainComponents(
      sdkDirPath,
      platforms: unusedTargetPlatforms,
      libraries: unusedHostLibraries,
      binaries: unusedHostBinaries
    )

    try await generator.createLibSymlink(sdkDirPath: sdkDirPath)
    try await generator.fixAbsoluteSymlinks(sdkDirPath: sdkDirPath)

    // Swift 6.1 and later do not throw warnings about the SDKSettings.json file missing,
    // so they don't need this file.
    if self.versionsConfiguration.swiftVersion.hasAnyPrefix(from: ["5.9", "5.10", "6.0"]) {
      try await generator.generateSDKSettingsFile(
        sdkDirPath: sdkDirPath,
        distribution: linuxDistribution
      )
    }

    if self.hostSwiftSource != .preinstalled {
      if self.mainHostTriple.os != .linux
        && !self.versionsConfiguration.swiftVersion.hasPrefix("6.")
      {
        try await generator.prepareLLDLinker(engine, llvmArtifact: downloadableArtifacts.hostLLVM)
      }

      if self.versionsConfiguration.swiftVersion.hasAnyPrefix(from: ["5.9", "5.10"]) {
        try await generator.symlinkClangHeaders()
      }

      let autolinkExtractPath = generator.pathsConfiguration.toolchainBinDirPath.appending(
        "swift-autolink-extract"
      )

      if await !generator.doesFileExist(at: autolinkExtractPath) {
        logger.info("Fixing `swift-autolink-extract` symlink...")
        try await generator.createSymlink(at: autolinkExtractPath, pointingTo: "swift")
      }
    }

    return SwiftSDKProduct(sdkDirPath: sdkDirPath, hostTriples: self.hostTriples)
  }
}
