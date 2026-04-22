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

import class Foundation.JSONDecoder
import class Foundation.JSONEncoder

private let encoder: JSONEncoder = {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
  return encoder
}()

extension SwiftSDKGenerator {
  func generateToolsetJSON(recipe: SwiftSDKRecipe, isForEmbeddedSwift: Bool = false) throws -> FilePath {
    logger.info("Generating toolset JSON file...")

    let toolsetJSONPath = pathsConfiguration.swiftSDKRootPath.appending(
      "\(isForEmbeddedSwift ? "embedded-" : "")toolset.json"
    )

    var relativeToolchainBinDir = pathsConfiguration.toolchainBinDirPath

    guard
      relativeToolchainBinDir.removePrefix(pathsConfiguration.swiftSDKRootPath)
    else {
      fatalError(
        "`toolchainBinDirPath` is at an unexpected location that prevents computing a relative path"
      )
    }

    var toolset = Toolset(rootPath: relativeToolchainBinDir.string)
    recipe.applyPlatformOptions(
      toolset: &toolset,
      targetTriple: self.targetTriple,
      isForEmbeddedSwift: isForEmbeddedSwift
    )
    try writeFile(at: toolsetJSONPath, encoder.encode(toolset))

    return toolsetJSONPath
  }

  /// Generates `swift-sdk.json` metadata file.
  func generateSwiftSDKMetadata(
    toolsetPath: FilePath,
    sdkDirPath: FilePath,
    recipe: SwiftSDKRecipe,
    isForEmbeddedSwift: Bool = false
  ) throws -> FilePath {
    logger.info("Generating Swift SDK metadata JSON file...")

    let swiftSDKMetadataPath = pathsConfiguration.swiftSDKRootPath.appending(
      "\(isForEmbeddedSwift ? "embedded-" : "")swift-sdk.json"
    )

    var relativeToolchainBinDir = pathsConfiguration.toolchainBinDirPath
    var relativeSDKDir = sdkDirPath
    var relativeToolsetPath = toolsetPath

    guard
      relativeToolchainBinDir.removePrefix(pathsConfiguration.swiftSDKRootPath),
      relativeSDKDir.removePrefix(pathsConfiguration.swiftSDKRootPath),
      relativeToolsetPath.removePrefix(pathsConfiguration.swiftSDKRootPath)
    else {
      fatalError(
        """
        `toolchainBinDirPath`, `sdkDirPath`, and `toolsetPath` are at unexpected locations that prevent computing \
        relative paths
        """
      )
    }

    var metadata = SwiftSDKMetadataV4(
      targetTriples: [
        self.targetTriple.triple: .init(
          sdkRootPath: relativeSDKDir.string,
          toolsetPaths: [relativeToolsetPath.string]
        )
      ]
    )

    recipe.applyPlatformOptions(
      metadata: &metadata,
      paths: pathsConfiguration,
      targetTriple: self.targetTriple,
      isForEmbeddedSwift: isForEmbeddedSwift
    )

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

    let newArtifacts: [String: ArtifactsArchiveMetadata.Artifact] = artifacts.mapValues {
      var relativePath = $0
      let prefixRemoved = relativePath.removePrefix(pathsConfiguration.artifactBundlePath)
      assert(prefixRemoved, "artifact path \($0) must be inside the bundle path \(pathsConfiguration.artifactBundlePath)")
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

    // In incremental mode, preserve any artifact entries already present in
    // the bundle's `info.json` so that running the generator multiple times
    // with different `--sdk-name` values (and a shared `--bundle-name`) yields
    // a single bundle containing all of them. Foreign keys are kept as-is;
    // current-run keys overwrite. Tolerate a missing file by writing fresh.
    let mergedArtifacts: [String: ArtifactsArchiveMetadata.Artifact]
    if isIncremental, doesFileExist(at: artifactBundleManifestPath) {
      let existingData = try readFile(at: artifactBundleManifestPath)
      let existing: ArtifactsArchiveMetadata
      do {
        existing = try JSONDecoder().decode(
          ArtifactsArchiveMetadata.self, from: existingData
        )
      } catch {
        throw GeneratorError.incrementalManifestDecodingFailed(
          artifactBundleManifestPath, error
        )
      }
      let expectedSchemaVersion = "1.0"
      guard existing.schemaVersion == expectedSchemaVersion else {
        throw GeneratorError.incrementalManifestSchemaMismatch(
          artifactBundleManifestPath,
          expected: expectedSchemaVersion,
          actual: existing.schemaVersion
        )
      }
      logger.info(
        "Merging \(newArtifacts.count) new artifact(s) into existing manifest at \(artifactBundleManifestPath) (\(existing.artifacts.count) existing entries)."
      )
      mergedArtifacts = existing.artifacts.merging(newArtifacts) { _, new in new }
    } else {
      mergedArtifacts = newArtifacts
    }

    try writeFile(
      at: artifactBundleManifestPath,
      encoder.encode(
        ArtifactsArchiveMetadata(
          schemaVersion: "1.0",
          artifacts: mergedArtifacts
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
  func generateSDKSettingsFile(sdkDirPath: FilePath, distribution: LinuxDistribution) throws {
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
