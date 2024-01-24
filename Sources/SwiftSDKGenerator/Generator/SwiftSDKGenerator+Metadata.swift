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

import SystemPackage

import class Foundation.JSONEncoder

private let encoder: JSONEncoder = {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
  return encoder
}()

extension SwiftSDKGenerator {
  func generateToolsetJSON(recipe: SwiftSDKRecipe) throws -> FilePath {
    logGenerationStep("Generating toolset JSON file...")

    let toolsetJSONPath = pathsConfiguration.swiftSDKRootPath.appending("toolset.json")

    var relativeToolchainBinDir = pathsConfiguration.toolchainBinDirPath

    guard
      relativeToolchainBinDir.removePrefix(pathsConfiguration.swiftSDKRootPath)
    else {
      fatalError(
        "`toolchainBinDirPath` is at an unexpected location that prevents computing a relative path"
      )
    }

    var toolset = Toolset(rootPath: relativeToolchainBinDir.string)
    recipe.applyPlatformOptions(toolset: &toolset)
    try writeFile(at: toolsetJSONPath, encoder.encode(toolset))

    return toolsetJSONPath
  }

  func generateDestinationJSON(toolsetPath: FilePath, sdkDirPath: FilePath) throws {
    logGenerationStep("Generating destination JSON file...")

    let destinationJSONPath = pathsConfiguration.swiftSDKRootPath.appending("swift-sdk.json")

    var relativeToolchainBinDir = pathsConfiguration.toolchainBinDirPath
    var relativeSDKDir = sdkDirPath
    var relativeToolsetPath = toolsetPath

    guard
      relativeToolchainBinDir.removePrefix(pathsConfiguration.swiftSDKRootPath),
      relativeSDKDir.removePrefix(pathsConfiguration.swiftSDKRootPath),
      relativeToolsetPath.removePrefix(pathsConfiguration.swiftSDKRootPath)
    else {
      fatalError("""
      `toolchainBinDirPath`, `sdkDirPath`, and `toolsetPath` are at unexpected locations that prevent computing \
      relative paths
      """)
    }

    try writeFile(
      at: destinationJSONPath,
      encoder.encode(
        SwiftSDKMetadataV4(
          targetTriples: [
            self.targetTriple.linuxConventionDescription: .init(
              sdkRootPath: relativeSDKDir.string,
              toolsetPaths: [relativeToolsetPath.string]
            ),
          ]
        )
      )
    )
  }

  func generateArtifactBundleManifest() throws {
    logGenerationStep("Generating .artifactbundle manifest file...")

    let artifactBundleManifestPath = pathsConfiguration.artifactBundlePath.appending("info.json")

    try writeFile(
      at: artifactBundleManifestPath,
      encoder.encode(
        ArtifactsArchiveMetadata(
          schemaVersion: "1.0",
          artifacts: [
            artifactID: .init(
              type: .swiftSDK,
              version: self.bundleVersion,
              variants: [
                .init(
                  path: FilePath(artifactID).appending(self.targetTriple.linuxConventionDescription).string,
                  supportedTriples: [self.hostTriple.description]
                ),
              ]
            ),
          ]
        )
      )
    )
  }
}
