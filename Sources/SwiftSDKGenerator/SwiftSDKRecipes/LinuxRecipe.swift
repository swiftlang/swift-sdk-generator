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
    includeHostToolchain: Bool = false
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
    var swiftCompilerOptions = ["-Xlinker", "-R/usr/lib/swift/linux/"]

    // Swift 5.9 does not handle the `-use-ld` option properly:
    //   https://github.com/swiftlang/swift-package-manager/issues/7222
    if self.versionsConfiguration.swiftVersion.hasPrefix("5.9") {
      swiftCompilerOptions += ["-Xclang-linker", "--ld-path=ld.lld"]
    } else {
      swiftCompilerOptions.append("-use-ld=lld")

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
    engine: QueryEngine,
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
        var items: [DownloadableArtifacts.Item] = []

        if self.hostSwiftSource != .preinstalled && !self.versionsConfiguration.swiftVersion.hasPrefix("6.0") {
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
        from: filePath.appending("usr"), sdkDirPath: sdkDirPath
      )
    case .remoteTarball:
      try await generator.unpackTargetSwiftPackage(
        targetSwiftPackagePath: downloadableArtifacts.targetSwift.localPath,
        relativePathToRoot: [FilePath.Component(self.versionsConfiguration.swiftDistributionName())!],
        sdkDirPath: sdkDirPath
      )
    }

    try await generator.fixAbsoluteSymlinks(sdkDirPath: sdkDirPath)

    var hostTriples: [Triple]? = [self.mainHostTriple]
    if self.hostSwiftSource != .preinstalled {
      if !self.versionsConfiguration.swiftVersion.hasPrefix("6.0") {
        try await generator.prepareLLDLinker(engine, llvmArtifact: downloadableArtifacts.hostLLVM)
      }

      if self.versionsConfiguration.swiftVersion.hasPrefix("5.9") ||
          self.versionsConfiguration.swiftVersion .hasPrefix("5.10") {
        try await generator.symlinkClangHeaders()
      }

      let autolinkExtractPath = generator.pathsConfiguration.toolchainBinDirPath.appending("swift-autolink-extract")

      if await !generator.doesFileExist(at: autolinkExtractPath) {
        logGenerationStep("Fixing `swift-autolink-extract` symlink...")
        try await generator.createSymlink(at: autolinkExtractPath, pointingTo: "swift")
      }
    } else if self.versionsConfiguration.swiftVersion.hasPrefix("5.9")
          || self.versionsConfiguration.swiftVersion.hasPrefix("5.10") {
      // Swift 5.9 and 5.10 require `supportedTriples` to be set in info.json.
      // FIXME: This can be removed once the SDK generator does not support 5.9/5.10 any more.
      hostTriples = [
        Triple("x86_64-unknown-linux-gnu"),
        Triple("aarch64-unknown-linux-gnu"),
        Triple("x86_64-apple-macos"),
        Triple("arm64-apple-macos"),
      ]
    } else {
      hostTriples = nil
    }

    return SwiftSDKProduct(sdkDirPath: sdkDirPath, hostTriples: hostTriples)
  }
}
