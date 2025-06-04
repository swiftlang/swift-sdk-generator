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

/// Represents v4 schema of `swift-sdk.json` (previously `destination.json`) files used for cross-compilation.
package struct SwiftSDKMetadataV4: Encodable {
  package struct TripleProperties: Encodable {
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

  /// Version of the schema used when serializing the Swift SDK metadata file.
  let schemaVersion = "4.0"

  /// Mapping of triple strings to corresponding properties of such target triple.
  var targetTriples: [String: TripleProperties]
}
