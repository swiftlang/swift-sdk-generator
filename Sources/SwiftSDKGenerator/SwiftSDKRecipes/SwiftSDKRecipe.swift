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

import Helpers
import Logging

import struct SystemPackage.FilePath

package struct SwiftSDKProduct {
  let sdkDirPath: FilePath
  /// Array of supported host triples. `nil` indicates the SDK can be universally used.
  let hostTriples: [Triple]?
}

/// A protocol describing a set of platform specific instructions to make a Swift SDK
package protocol SwiftSDKRecipe: Sendable {
  /// Update the given toolset with platform specific options
  func applyPlatformOptions(
    toolset: inout Toolset,
    targetTriple: Triple,
    isForEmbeddedSwift: Bool
  )
  func applyPlatformOptions(
    metadata: inout SwiftSDKMetadataV4,
    paths: PathsConfiguration,
    targetTriple: Triple,
    isForEmbeddedSwift: Bool
  )

  /// The default identifier of the Swift SDK
  var defaultArtifactID: String { get }

  /// The logger to use for recipe generators.
  var logger: Logger { get }

  /// The main entrypoint of the recipe to make a Swift SDK
  func makeSwiftSDK(
    generator: SwiftSDKGenerator,
    engine: QueryEngine,
    httpClient: some HTTPClientProtocol
  ) async throws -> SwiftSDKProduct

  var shouldSupportEmbeddedSwift: Bool { get }
}

extension SwiftSDKRecipe {
  package func applyPlatformOptions(
    toolset: inout Toolset,
    targetTriple: Triple,
    isForEmbeddedSwift: Bool
  ) {}
  package func applyPlatformOptions(
    metadata: inout SwiftSDKMetadataV4.TripleProperties,
    paths: PathsConfiguration,
    targetTriple: Triple,
    isForEmbeddedSwift: Bool
  ) {}

  package var shouldSupportEmbeddedSwift: Bool { false }
}
