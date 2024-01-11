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
import GeneratorEngine

public struct LinuxRecipe: SwiftSDKRecipe {
  public init() {}

  public func makeSwiftSDK(generator: SwiftSDKGenerator, engine: Engine, httpClient client: HTTPClient) async throws {
    try await generator.downloadArtifacts(client, engine)

    if !generator.shouldUseDocker {
      guard case let .ubuntu(version) = generator.versionsConfiguration.linuxDistribution else {
        throw GeneratorError
          .distributionSupportsOnlyDockerGenerator(generator.versionsConfiguration.linuxDistribution)
      }

      try await generator.downloadUbuntuPackages(client, engine, requiredPackages: version.requiredPackages)
    }

    try await generator.unpackHostSwift()

    if generator.shouldUseDocker {
      try await generator.copyTargetSwiftFromDocker()
    } else {
      try await generator.unpackTargetSwiftPackage()
    }

    try await generator.prepareLLDLinker(engine)

    try await generator.fixAbsoluteSymlinks()

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
  }
}
