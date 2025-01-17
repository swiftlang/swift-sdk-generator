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
#if canImport(AsyncHTTPClient)
import AsyncHTTPClient
#endif
import Foundation
import Helpers
import RegexBuilder
import SystemPackage

public extension Triple.Arch {
  /// Returns the value of `cpu` converted to a convention used in Debian package names
  var debianConventionName: String {
    switch self {
    case .aarch64: return "arm64"
    case .x86_64: return "amd64"
    case .wasm32: return "wasm32"
    default: fatalError("\(self) is not supported yet")
    }
  }
}

public extension SwiftSDKGenerator {
  func run(recipe: SwiftSDKRecipe) async throws {
    try await withQueryEngine(OSFileSystem(), self.logger, cacheLocation: self.engineCachePath) { engine in
      let httpClientType: HTTPClientProtocol.Type
      #if canImport(AsyncHTTPClient)
      httpClientType = HTTPClient.self
      #else
      httpClientType = OfflineHTTPClient.self
      #endif
      try await httpClientType.with { client in
        if !self.isIncremental {
          try await self.removeRecursively(at: pathsConfiguration.toolchainDirPath)
        }

        try await self.createDirectoryIfNeeded(at: pathsConfiguration.artifactsCachePath)

        let swiftSDKProduct = try await recipe.makeSwiftSDK(generator: self, engine: engine, httpClient: client)

        let toolsetJSONPath = try await self.generateToolsetJSON(recipe: recipe)

        try await generateDestinationJSON(
          toolsetPath: toolsetJSONPath,
          sdkDirPath: swiftSDKProduct.sdkDirPath,
          recipe: recipe
        )

        try await generateArtifactBundleManifest(hostTriples: swiftSDKProduct.hostTriples)

        logger.logGenerationStep(
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
