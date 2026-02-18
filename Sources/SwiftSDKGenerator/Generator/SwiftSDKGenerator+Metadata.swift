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
  encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
  return encoder
}()

extension SwiftSDKGenerator {
  /// Generates toolset JSON file for a specific target triple.
  func generateToolsetJSON(
    recipe: SwiftSDKRecipe,
    targetTriple: Triple,
    isForEmbeddedSwift: Bool = false
  ) throws -> FilePath {
    let paths = pathsConfiguration(for: targetTriple)
    logger.info("Generating toolset JSON file for \(targetTriple.triple)...")

    let toolsetJSONPath = paths.swiftSDKRootPath.appending(
      "\(isForEmbeddedSwift ? "embedded-" : "")toolset.json"
    )

    var relativeToolchainBinDir = paths.toolchainBinDirPath

    guard
      relativeToolchainBinDir.removePrefix(paths.swiftSDKRootPath)
    else {
      fatalError(
        "`toolchainBinDirPath` is at an unexpected location that prevents computing a relative path"
      )
    }

    var toolset = Toolset(rootPath: relativeToolchainBinDir.string)
    recipe.applyPlatformOptions(
      toolset: &toolset,
      targetTriple: targetTriple,
      isForEmbeddedSwift: isForEmbeddedSwift
    )
    try writeFile(at: toolsetJSONPath, encoder.encode(toolset))

    return toolsetJSONPath
  }

  /// Generates `swift-sdk.json` metadata file for multiple target triples.
  func generateSwiftSDKMetadata(
    toolsetPaths: [Triple: FilePath],
    sdkDirPaths: [Triple: FilePath],
    recipe: SwiftSDKRecipe,
    isForEmbeddedSwift: Bool = false
  ) throws -> FilePath {
    logger.info("Generating Swift SDK metadata JSON file...")

    // Use artifact bundle directory for metadata file (shared across all triples)
    let swiftSDKMetadataPath = pathsConfiguration.artifactBundlePath
      .appending(artifactID)
      .appending("\(isForEmbeddedSwift ? "embedded-" : "")swift-sdk.json")

    // Base path for computing relative paths
    let basePath = pathsConfiguration.artifactBundlePath.appending(artifactID)

    var targetTriplesMetadata: [String: SwiftSDKMetadataV4.TripleProperties] = [:]

    for targetTriple in targetTriples {
      guard let toolsetPath = toolsetPaths[targetTriple],
            let sdkDirPath = sdkDirPaths[targetTriple] else {
        fatalError("Missing toolset or SDK path for triple \(targetTriple.triple)")
      }

      var relativeSDKDir = sdkDirPath
      var relativeToolsetPath = toolsetPath

      guard
        relativeSDKDir.removePrefix(basePath),
        relativeToolsetPath.removePrefix(basePath)
      else {
        fatalError(
          """
          `sdkDirPath` and `toolsetPath` are at unexpected locations that prevent computing \
          relative paths
          """
        )
      }

      targetTriplesMetadata[targetTriple.triple] = .init(
        sdkRootPath: relativeSDKDir.string,
        toolsetPaths: [relativeToolsetPath.string]
      )
    }

    var metadata = SwiftSDKMetadataV4(targetTriples: targetTriplesMetadata)

    // Apply platform-specific options for each triple
    for targetTriple in targetTriples {
      let paths = pathsConfiguration(for: targetTriple)
      recipe.applyPlatformOptions(
        metadata: &metadata,
        paths: paths,
        targetTriple: targetTriple,
        isForEmbeddedSwift: isForEmbeddedSwift
      )
    }

    try createDirectoryIfNeeded(at: swiftSDKMetadataPath.removingLastComponent())
    try writeFile(
      at: swiftSDKMetadataPath,
      encoder.encode(metadata)
    )

    return swiftSDKMetadataPath
  }

  func generateArtifactBundleManifest(
    hostTriples: [Triple]?,
    artifacts: [String: FilePath],
    shouldUseFullPaths: Bool
  ) throws {
    logger.info("Generating .artifactbundle info JSON file...")

    let artifactBundleManifestPath = pathsConfiguration.artifactBundlePath.appending("info.json")

    try writeFile(
      at: artifactBundleManifestPath,
      encoder.encode(
        ArtifactsArchiveMetadata(
          schemaVersion: "1.0",
          artifacts: artifacts.mapValues {
            var relativePath = $0
            let prefixRemoved = relativePath.removePrefix(pathsConfiguration.artifactBundlePath)
            assert(prefixRemoved)
            if !shouldUseFullPaths {
              relativePath.removeLastComponent()
            }

            return .init(
              type: .swiftSDK,
              version: self.bundleVersion,
              variants: [
                .init(
                  path: relativePath.string,
                  supportedTriples: hostTriples.map { $0.map(\.triple) }
                )
              ]
            )
          }
        )
      )
    )
  }

  struct SDKSettings: Codable {
    var DisplayName: String
    var Version: String
    var VersionMap: [String: String] = [:]
    var CanonicalName: String
  }

  /// Generates an `SDKSettings.json` file that looks like this:
  ///
  /// ```json
  /// {
  ///   "CanonicalName" : "<arch>-swift-linux-[gnu|gnueabihf]",
  ///   "DisplayName" : "Swift SDK for <distribution> (<arch>)",
  ///   "Version" : "0.0.1",
  ///   "VersionMap" : {
  ///
  ///   }
  /// }
  /// ```
  func generateSDKSettingsFile(sdkDirPath: FilePath, distribution: LinuxDistribution, targetTriple: Triple) throws {
    logger.info("Generating SDKSettings.json file to silence cross-compilation warnings...")

    let sdkSettings = SDKSettings(
      DisplayName: "Swift SDK for \(distribution) (\(targetTriple.archName))",
      Version: bundleVersion,
      CanonicalName: targetTriple.triple.replacingOccurrences(of: "unknown", with: "swift")
    )

    let sdkSettingsFilePath = sdkDirPath.appending("SDKSettings.json")
    try writeFile(at: sdkSettingsFilePath, encoder.encode(sdkSettings))
  }
}
