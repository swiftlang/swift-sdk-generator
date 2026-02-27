//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

/// A JSON recipe file for configuring WebAssembly SDK generation.
///
/// This allows specifying per-triple WASI sysroot and target Swift package paths,
/// which is necessary when building SDK bundles with multiple targets
/// (e.g., `wasip1` and `wasip1-threads`) that have different sysroots.
///
/// Example JSON:
/// ```json
/// {
///   "schemaVersion": "0.1",
///   "recipeType": "wasm",
///   "swiftVersion": "swift-DEVELOPMENT-SNAPSHOT",
///   "targets": [
///     {
///       "triple": "wasm32-unknown-wasip1",
///       "wasiSysroot": "/path/to/wasip1/sysroot",
///       "swiftPackagePath": "/path/to/wasip1/package"
///     }
///   ]
/// }
/// ```
package struct WasmSDKRecipeFile: Decodable, Sendable {
  /// Schema version for forward compatibility.
  package let schemaVersion: String

  /// Discriminator identifying this as a WebAssembly recipe.
  package let recipeType: RecipeType

  /// Known recipe types.
  package enum RecipeType: String, Decodable, Sendable {
    case wasm
  }

  /// Swift version string (e.g., "swift-DEVELOPMENT-SNAPSHOT").
  package let swiftVersion: String

  /// Path to the host Swift toolchain package (optional, shared across all targets).
  package let hostSwiftPackagePath: String?

  /// Per-triple target configurations.
  package let targets: [TargetConfig]

  /// Per-target-triple configuration.
  package struct TargetConfig: Decodable, Sendable {
    /// The target triple string (e.g., "wasm32-unknown-wasip1").
    package let triple: String

    /// Path to the WASI sysroot directory for this triple.
    package let wasiSysroot: String

    /// Path to the Swift toolchain package for this triple.
    package let swiftPackagePath: String?
  }
}
