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

import AsyncAlgorithms
import Foundation
import Helpers
import RegexBuilder
import SystemPackage

#if canImport(AsyncHTTPClient)
  import AsyncHTTPClient
#endif

extension Triple.Arch {
  /// Returns the value of `cpu` converted to a convention used in Debian package names
  public var debianConventionName: String {
    switch self {
    case .aarch64: return "arm64"
    case .x86_64: return "amd64"
    case .wasm32: return "wasm32"
    case .arm: return "armhf"
    default: fatalError("\(self) is not supported yet")
    }
  }
}

extension SwiftSDKGenerator {
  package func run(recipe: some SwiftSDKRecipe) async throws {
    try await withQueryEngine(OSFileSystem(), self.logger, cacheLocation: self.engineCachePath) {
      engine in
      let httpClientType: HTTPClientProtocol.Type
      #if canImport(AsyncHTTPClient)
        httpClientType = HTTPClient.self
      #else
        httpClientType = OfflineHTTPClient.self
      #endif
      try await httpClientType.with { client in
        if !self.isIncremental {
          // Clean up directories for all target triples
          for triple in targetTriples {
            let paths = pathsConfiguration(for: triple)
            try await self.removeRecursively(at: paths.toolchainDirPath)
          }
        }

        try await self.createDirectoryIfNeeded(at: pathsConfiguration.artifactsCachePath)

        let swiftSDKProduct = try await recipe.makeSwiftSDK(
          generator: self,
          engine: engine,
          httpClient: client
        )

        // Generate toolsets for each target triple
        var toolsetPaths: [Triple: FilePath] = [:]
        for triple in targetTriples {
          let toolsetPath = try await self.generateToolsetJSON(recipe: recipe, targetTriple: triple)
          toolsetPaths[triple] = toolsetPath
        }

        var artifacts = try await [
          self.artifactID: generateSwiftSDKMetadata(
            toolsetPaths: toolsetPaths,
            sdkDirPaths: swiftSDKProduct.sdkDirPaths,
            recipe: recipe
          )
        ]

        if recipe.shouldSupportEmbeddedSwift {
          // Generate embedded toolsets for each target triple
          var embeddedToolsetPaths: [Triple: FilePath] = [:]
          for triple in targetTriples {
            let toolsetPath = try await self.generateToolsetJSON(
              recipe: recipe,
              targetTriple: triple,
              isForEmbeddedSwift: true
            )
            embeddedToolsetPaths[triple] = toolsetPath
          }

          artifacts["\(self.artifactID)-embedded"] = try await generateSwiftSDKMetadata(
            toolsetPaths: embeddedToolsetPaths,
            sdkDirPaths: swiftSDKProduct.sdkDirPaths,
            recipe: recipe,
            isForEmbeddedSwift: true
          )
        }

        try await generateArtifactBundleManifest(
          hostTriples: swiftSDKProduct.hostTriples,
          artifacts: artifacts,
          shouldUseFullPaths: recipe.shouldSupportEmbeddedSwift
        )

        // Extra spaces added for readability for the user
        print(
          """

          All done! Install the newly generated SDK with this command:
          swift experimental-sdk install \(pathsConfiguration.artifactBundlePath)

          After that, use the newly installed SDK when building with this command:
          swift build --experimental-swift-sdk \(artifactID)

          """
        )
      }
    }
  }
}
