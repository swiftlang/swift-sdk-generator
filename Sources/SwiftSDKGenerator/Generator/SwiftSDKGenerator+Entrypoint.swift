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
import AsyncHTTPClient
import Foundation
import GeneratorEngine
import RegexBuilder
import SystemPackage
import Helpers

public extension Triple.CPU {
  /// Returns the value of `cpu` converted to a convention used in Debian package names
  var debianConventionName: String {
    switch self {
    case .arm64: "arm64"
    case .x86_64: "amd64"
    case .wasm32: "wasm32"
    }
  }
}

private func withHTTPClient(
  _ configuration: HTTPClient.Configuration,
  _ body: @Sendable (HTTPClient) async throws -> ()
) async throws {
  let client = HTTPClient(eventLoopGroupProvider: .singleton, configuration: configuration)
  try await withAsyncThrowing {
    try await body(client)
  } defer: {
    try await client.shutdown()
  }
}

extension SwiftSDKGenerator {
  public func run(recipe: SwiftSDKRecipe) async throws {
    try await withEngine(LocalFileSystem(), self.logger, cacheLocation: self.engineCachePath) { engine in
      var configuration = HTTPClient.Configuration(redirectConfiguration: .follow(max: 5, allowCycles: false))
      // Workaround an issue with github.com returning 400 instead of 404 status to HEAD requests from AHC.
      configuration.httpVersion = .http1Only
      try await withHTTPClient(configuration) { client in
        if !self.isIncremental {
          try await self.removeRecursively(at: pathsConfiguration.toolchainDirPath)
        }

        try await self.createDirectoryIfNeeded(at: pathsConfiguration.artifactsCachePath)
        try await self.createDirectoryIfNeeded(at: pathsConfiguration.toolchainDirPath)

        let swiftSDKProduct = try await recipe.makeSwiftSDK(generator: self, engine: engine, httpClient: client)

        let toolsetJSONPath = try await generateToolsetJSON(recipe: recipe)

        try await generateDestinationJSON(toolsetPath: toolsetJSONPath, sdkDirPath: swiftSDKProduct.sdkDirPath)

        try await generateArtifactBundleManifest()

        logGenerationStep(
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

func logGenerationStep(_ message: String) {
  print("\n\(message)")
}
