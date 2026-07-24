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

import Logging
import SystemPackage
import XCTest

@testable import SwiftSDKGenerator

/// Tests covering the on-disk layout of the generated `.artifactbundle`,
/// in particular the decoupling of the bundle directory name from the
/// per-SDK artifact ID. This decoupling is what allows multiple Swift SDKs
/// (e.g. wasip1, wasip1-threads, emscripten) to live inside the same
/// `.artifactbundle` while keeping their own subdirectories.
final class BundleLayoutTests: XCTestCase {
  let logger = Logger(label: "BundleLayoutTests")

  /// `bundleName` controls the `.artifactbundle` directory; `artifactID`
  /// continues to name the per-SDK subdirectory inside it.
  func testBundleNameDecouplesFromArtifactID() async throws {
    let sdk = try await SwiftSDKGenerator(
      bundleVersion: "0.0.1",
      targetTriple: Triple("wasm32-unknown-wasip1"),
      artifactID: "foo",
      bundleName: "shared",
      isIncremental: false,
      isVerbose: false,
      logger: logger
    )

    let bundleComponents = await sdk.pathsConfiguration.artifactBundlePath.components.suffix(2).map(\.string)
    XCTAssertEqual(
      bundleComponents,
      ["Bundles", "shared.artifactbundle"],
      "Expected artifactBundlePath to end with Bundles/shared.artifactbundle"
    )

    let sdkRootComponents = await sdk.pathsConfiguration.swiftSDKRootPath.components.suffix(4).map(\.string)
    XCTAssertEqual(
      sdkRootComponents,
      ["Bundles", "shared.artifactbundle", "foo", "wasm32-unknown-wasip1"],
      "Expected swiftSDKRootPath to nest artifactID under bundleName"
    )
  }

  /// When `bundleName` is omitted the bundle directory name falls back to
  /// the artifact ID, preserving the legacy single-SDK-per-bundle layout.
  func testBundleNameDefaultsToArtifactID() async throws {
    let sdk = try await SwiftSDKGenerator(
      bundleVersion: "0.0.1",
      targetTriple: Triple("wasm32-unknown-wasip1"),
      artifactID: "legacy-id",
      isIncremental: false,
      isVerbose: false,
      logger: logger
    )

    let bundleComponents = await sdk.pathsConfiguration.artifactBundlePath.components.suffix(2).map(\.string)
    XCTAssertEqual(
      bundleComponents,
      ["Bundles", "legacy-id.artifactbundle"],
      "Expected artifactBundlePath to default to artifactID when bundleName is omitted"
    )

    let sdkRootComponents = await sdk.pathsConfiguration.swiftSDKRootPath.components.suffix(4).map(\.string)
    XCTAssertEqual(
      sdkRootComponents,
      ["Bundles", "legacy-id.artifactbundle", "legacy-id", "wasm32-unknown-wasip1"],
      "Expected swiftSDKRootPath to nest artifactID under itself when bundleName is omitted"
    )
  }

  // MARK: - Bundle name validation

  /// Empty bundle names are rejected to avoid creating a hidden,
  /// nameless `.artifactbundle` directory.
  func testValidateBundleNameRejectsEmptyString() {
    XCTAssertThrowsError(try PathsConfiguration.validateBundleName(""))
  }

  /// Path separators must be rejected so users cannot escape the
  /// `Bundles/` directory or create nested bundle paths by accident.
  func testValidateBundleNameRejectsForwardSlash() {
    XCTAssertThrowsError(try PathsConfiguration.validateBundleName("foo/bar"))
  }

  func testValidateBundleNameRejectsBackslash() {
    XCTAssertThrowsError(try PathsConfiguration.validateBundleName("foo\\bar"))
  }

  /// `..` as a bundle name would walk out of the `Bundles/` directory.
  func testValidateBundleNameRejectsDotDot() {
    XCTAssertThrowsError(try PathsConfiguration.validateBundleName(".."))
  }

  /// `.` as a bundle name would create a hidden `..artifactbundle` directory
  /// (equivalent to writing into `Bundles/`) — almost certainly a mistake.
  func testValidateBundleNameRejectsSingleDot() {
    XCTAssertThrowsError(try PathsConfiguration.validateBundleName("."))
  }

  /// A bundle name that starts with `..` is a path-traversal attempt
  /// even when not strictly equal to `..`.
  func testValidateBundleNameRejectsTraversalSegment() {
    XCTAssertThrowsError(try PathsConfiguration.validateBundleName("../escape"))
  }

  /// Names that look reasonable should be accepted: dots, dashes, digits,
  /// version suffixes, etc.
  func testValidateBundleNameAcceptsReasonableNames() throws {
    try PathsConfiguration.validateBundleName("swift-wasm-sdk")
    try PathsConfiguration.validateBundleName("swift-wasm-sdk-6.3")
    try PathsConfiguration.validateBundleName("foo")
    try PathsConfiguration.validateBundleName("a.b.c")
  }
}
