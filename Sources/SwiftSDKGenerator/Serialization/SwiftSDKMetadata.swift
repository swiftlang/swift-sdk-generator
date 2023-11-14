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

struct DestinationV1: Encodable {
  enum CodingKeys: String, CodingKey {
    case version
    case sdk
    case toolchainBinDir = "toolchain-bin-dir"
    case target
    case extraCCFlags = "extra-cc-flags"
    case extraSwiftCFlags = "extra-swiftc-flags"
    case extraCPPFlags = "extra-cpp-flags"
  }

  let version = 1
  let sdk: String
  let toolchainBinDir: String
  let target: String
  let extraCCFlags: [String]
  let extraSwiftCFlags: [String]
  let extraCPPFlags: [String]
}

struct DestinationV2: Encodable {
  let version = 2

  let sdkRootDir: String
  let toolchainBinDir: String
  let hostTriples: [String]
  let targetTriples: [String]
  let extraCCFlags: [String]
  let extraSwiftCFlags: [String]
  let extraCXXFlags: [String]
  let extraLinkerFlags: [String]
}

/// Represents v3 schema of `destination.json` files used for cross-compilation.
struct DestinationV3: Encodable {
  struct TripleProperties: Encodable {
    /// Path relative to `destination.json` containing SDK root.
    let sdkRootPath: String

    /// Path relative to `destination.json` containing Swift resources for dynamic linking.
    var swiftResourcesPath: String?

    /// Path relative to `destination.json` containing Swift resources for static linking.
    var swiftStaticResourcesPath: String?

    /// Array of paths relative to `destination.json` containing headers.
    var includeSearchPaths: [String]?

    /// Array of paths relative to `destination.json` containing libraries.
    var librarySearchPaths: [String]?

    /// Array of paths relative to `destination.json` containing toolset files.
    let toolsetPaths: [String]?
  }

  /// Version of the schema used when serializing the destination file.
  let schemaVersion = "3.0"

  /// Mapping of triple strings to corresponding properties of such target triple.
  let runTimeTriples: [String: TripleProperties]
}

/// Represents v4 schema of `swift-sdk.json` (previously `destination.json`) files used for cross-compilation.
struct SwiftSDKMetadataV4: Encodable {
  struct TripleProperties: Encodable {
    /// Path relative to `swift-sdk.json` containing SDK root.
    var sdkRootPath: String

    /// Path relative to `swift-sdk.json` containing Swift resources for dynamic linking.
    var swiftResourcesPath: String?

    /// Path relative to `swift-sdk.json` containing Swift resources for static linking.
    var swiftStaticResourcesPath: String?

    /// Array of paths relative to `swift-sdk.json` containing headers.
    var includeSearchPaths: [String]?

    /// Array of paths relative to `swift-sdk.json` containing libraries.
    var librarySearchPaths: [String]?

    /// Array of paths relative to `swift-sdk.json` containing toolset files.
    var toolsetPaths: [String]?
  }

  /// Version of the schema used when serializing the destination file.
  let schemaVersion = "4.0"

  /// Mapping of triple strings to corresponding properties of such target triple.
  let targetTriples: [String: TripleProperties]
}
