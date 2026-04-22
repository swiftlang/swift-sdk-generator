//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2022-2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Helpers
import Logging
import SystemPackage
import XCTest

@testable import SwiftSDKGenerator

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

final class SwiftSDKGeneratorMetadataTests: XCTestCase {
  let logger = Logger(label: "SwiftSDKGeneratorMetadataTests")

  /// Construct a generator whose `Bundles/` output directory lives under
  /// the system temporary directory, so failing or crashing tests cannot
  /// pollute the package working tree with orphaned `.artifactbundle`
  /// directories.
  private func makeGenerator(
    artifactID: String,
    bundleName: String,
    isIncremental: Bool,
    file: StaticString = #file,
    line: UInt = #line
  ) async throws -> (sdk: SwiftSDKGenerator, sourceRoot: FilePath) {
    let tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("swift-sdk-generator-metadata-tests")
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: tempRoot, withIntermediateDirectories: true
    )
    let sourceRoot = FilePath(tempRoot.path)

    let sdk = try await SwiftSDKGenerator(
      bundleVersion: "0.0.1",
      targetTriple: Triple("wasm32-unknown-wasip1"),
      artifactID: artifactID,
      bundleName: bundleName,
      sourceRoot: sourceRoot,
      isIncremental: isIncremental,
      isVerbose: false,
      logger: logger
    )
    return (sdk, sourceRoot)
  }

  // MARK: - Incremental manifest merge

  /// When `isIncremental` is true and an `info.json` already exists at the
  /// bundle path, a subsequent call to `generateArtifactBundleManifest`
  /// must merge the new artifacts into the existing manifest (current run's
  /// keys overwrite, foreign keys preserved). This is what allows multiple
  /// Swift SDKs (wasip1, wasip1-threads, emscripten) to live inside the same
  /// `.artifactbundle`.
  func testIncrementalManifestMergesWithExisting() async throws {
    let (sdk, sourceRoot) = try await makeGenerator(
      artifactID: "first-sdk", bundleName: "merge-test-bundle", isIncremental: true
    )
    try await withAsyncThrowing {
      let bundlePath = await sdk.pathsConfiguration.artifactBundlePath
      let infoPath = bundlePath.appending("info.json")
      try await sdk.createDirectoryIfNeeded(at: bundlePath)

      // First write: only "first-sdk".
      try await sdk.generateArtifactBundleManifest(
        hostTriples: [sdk.targetTriple],
        artifacts: ["first-sdk": bundlePath.appending("first-sdk")],
        shouldUseFullPaths: false
      )

      let firstData = try await sdk.readFile(at: infoPath)
      let firstDecoded = try JSONDecoder().decode(ArtifactsArchiveMetadata.self, from: firstData)
      XCTAssertEqual(
        Set(firstDecoded.artifacts.keys),
        ["first-sdk"],
        "Sanity check: initial write should produce single-entry manifest"
      )

      // Second write (still isIncremental): adds "second-sdk".
      try await sdk.generateArtifactBundleManifest(
        hostTriples: [sdk.targetTriple],
        artifacts: ["second-sdk": bundlePath.appending("second-sdk")],
        shouldUseFullPaths: false
      )

      let mergedData = try await sdk.readFile(at: infoPath)
      let mergedDecoded = try JSONDecoder().decode(ArtifactsArchiveMetadata.self, from: mergedData)
      XCTAssertEqual(
        Set(mergedDecoded.artifacts.keys),
        ["first-sdk", "second-sdk"],
        "Incremental write must merge into existing manifest, preserving the previous artifact"
      )
    } defer: {
      try FileManager.default.removeItem(atPath: sourceRoot.string)
    }
  }

  /// When the same artifact key is written twice incrementally, the
  /// most-recent write wins — older variants must not stick around.
  func testIncrementalManifestOverwritesSameKey() async throws {
    let (sdk, sourceRoot) = try await makeGenerator(
      artifactID: "shared-id", bundleName: "merge-overwrite-bundle", isIncremental: true
    )
    try await withAsyncThrowing {
      let bundlePath = await sdk.pathsConfiguration.artifactBundlePath
      let infoPath = bundlePath.appending("info.json")
      try await sdk.createDirectoryIfNeeded(at: bundlePath)

      try await sdk.generateArtifactBundleManifest(
        hostTriples: [Triple("wasm32-unknown-wasip1")],
        artifacts: ["shared-id": bundlePath.appending("shared-id-old").appending("info.json")],
        shouldUseFullPaths: false
      )

      try await sdk.generateArtifactBundleManifest(
        hostTriples: [Triple("wasm32-unknown-wasip1-threads")],
        artifacts: ["shared-id": bundlePath.appending("shared-id-new").appending("info.json")],
        shouldUseFullPaths: false
      )

      let data = try await sdk.readFile(at: infoPath)
      let decoded = try JSONDecoder().decode(ArtifactsArchiveMetadata.self, from: data)
      XCTAssertEqual(decoded.artifacts.count, 1, "Same-key writes must collapse to one entry")
      let variant = try XCTUnwrap(decoded.artifacts["shared-id"]?.variants.first)
      XCTAssertEqual(
        variant.path, "shared-id-new",
        "Most recent write must win for the same artifact key"
      )
      XCTAssertEqual(
        variant.supportedTriples,
        ["wasm32-unknown-wasip1-threads"],
        "Most recent write's hostTriples must replace the old"
      )
    } defer: {
      try FileManager.default.removeItem(atPath: sourceRoot.string)
    }
  }

  /// When `isIncremental` is false, an existing `info.json` must be
  /// overwritten — preserving the legacy single-SDK-per-bundle behavior.
  func testNonIncrementalManifestOverwritesExisting() async throws {
    let (sdk, sourceRoot) = try await makeGenerator(
      artifactID: "first-sdk", bundleName: "overwrite-test-bundle", isIncremental: false
    )
    try await withAsyncThrowing {
      let bundlePath = await sdk.pathsConfiguration.artifactBundlePath
      let infoPath = bundlePath.appending("info.json")
      try await sdk.createDirectoryIfNeeded(at: bundlePath)

      try await sdk.generateArtifactBundleManifest(
        hostTriples: [sdk.targetTriple],
        artifacts: ["first-sdk": bundlePath.appending("first-sdk")],
        shouldUseFullPaths: false
      )
      try await sdk.generateArtifactBundleManifest(
        hostTriples: [sdk.targetTriple],
        artifacts: ["second-sdk": bundlePath.appending("second-sdk")],
        shouldUseFullPaths: false
      )

      let data = try await sdk.readFile(at: infoPath)
      let decoded = try JSONDecoder().decode(ArtifactsArchiveMetadata.self, from: data)
      XCTAssertEqual(
        Set(decoded.artifacts.keys),
        ["second-sdk"],
        "Non-incremental write must overwrite, never merge"
      )
    } defer: {
      try FileManager.default.removeItem(atPath: sourceRoot.string)
    }
  }

  /// Incremental mode with no pre-existing `info.json` writes a fresh
  /// manifest — there is no error or special-case behavior.
  func testIncrementalManifestToleratesMissingFile() async throws {
    let (sdk, sourceRoot) = try await makeGenerator(
      artifactID: "fresh-sdk", bundleName: "fresh-bundle", isIncremental: true
    )
    try await withAsyncThrowing {
      let bundlePath = await sdk.pathsConfiguration.artifactBundlePath
      let infoPath = bundlePath.appending("info.json")
      try await sdk.createDirectoryIfNeeded(at: bundlePath)

      try await sdk.generateArtifactBundleManifest(
        hostTriples: [sdk.targetTriple],
        artifacts: ["fresh-sdk": bundlePath.appending("fresh-sdk")],
        shouldUseFullPaths: false
      )

      let data = try await sdk.readFile(at: infoPath)
      let decoded = try JSONDecoder().decode(ArtifactsArchiveMetadata.self, from: data)
      XCTAssertEqual(Set(decoded.artifacts.keys), ["fresh-sdk"])
    } defer: {
      try FileManager.default.removeItem(atPath: sourceRoot.string)
    }
  }

  /// An existing `info.json` with a foreign `schemaVersion` must cause the
  /// merge to throw rather than silently downgrading the schema.
  func testIncrementalManifestRejectsSchemaMismatch() async throws {
    let (sdk, sourceRoot) = try await makeGenerator(
      artifactID: "x", bundleName: "schema-mismatch-bundle", isIncremental: true
    )
    try await withAsyncThrowing {
      let bundlePath = await sdk.pathsConfiguration.artifactBundlePath
      let infoPath = bundlePath.appending("info.json")
      try await sdk.createDirectoryIfNeeded(at: bundlePath)

      // Plant an info.json with a future schemaVersion.
      let foreignManifest = ArtifactsArchiveMetadata(
        schemaVersion: "2.0",
        artifacts: [:]
      )
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted]
      try encoder.encode(foreignManifest).write(
        to: URL(fileURLWithPath: infoPath.string)
      )

      do {
        try await sdk.generateArtifactBundleManifest(
          hostTriples: [sdk.targetTriple],
          artifacts: ["x": bundlePath.appending("x")],
          shouldUseFullPaths: false
        )
        XCTFail("Expected schemaVersion mismatch to throw")
      } catch let error as GeneratorError {
        guard case .incrementalManifestSchemaMismatch(_, expected: "1.0", actual: "2.0") = error else {
          XCTFail("Expected incrementalManifestSchemaMismatch error, got \(error)")
          return
        }
      }
    } defer: {
      try FileManager.default.removeItem(atPath: sourceRoot.string)
    }
  }

  // MARK: - Existing tests

  func testGenerateSDKSettingsFile() async throws {
    let testCases = [
      (
        bundleVersion: "0.0.1",
        targetTriple: Triple("x86_64-unknown-linux-gnu"),
        expectedCanonicalName: "x86_64-swift-linux-gnu"
      ),
      (
        bundleVersion: "0.0.2",
        targetTriple: Triple("aarch64-unknown-linux-gnu"),
        expectedCanonicalName: "aarch64-swift-linux-gnu"
      ),
      (
        bundleVersion: "0.0.3",
        targetTriple: Triple("armv7-unknown-linux-gnueabihf"),
        expectedCanonicalName: "armv7-swift-linux-gnueabihf"
      ),
    ]

    for testCase in testCases {
      let sdk = try await SwiftSDKGenerator(
        bundleVersion: testCase.bundleVersion,
        targetTriple: testCase.targetTriple,
        artifactID: "6.0.3-RELEASE_ubuntu_jammy_\(testCase.targetTriple.archName)",
        isIncremental: false,
        isVerbose: false,
        logger: logger
      )
      let linuxDistribution = try LinuxDistribution(name: .ubuntu, version: "22.04")

      let sdkDirPath = FilePath(".")
      try await sdk.generateSDKSettingsFile(sdkDirPath: sdkDirPath, distribution: linuxDistribution)

      // Make sure the file exists
      let sdkSettingsFile = sdkDirPath.appending("SDKSettings.json")
      var fileExists = await sdk.doesFileExist(at: sdkSettingsFile)
      XCTAssertTrue(fileExists)

      // Read back file, make sure it contains the expected data
      let maybeString = String(data: try await sdk.readFile(at: sdkSettingsFile), encoding: .utf8)
      let string = try XCTUnwrap(maybeString)
      XCTAssertTrue(string.contains(testCase.bundleVersion))
      XCTAssertTrue(string.contains("(\(testCase.targetTriple.archName))"))
      XCTAssertTrue(string.contains(linuxDistribution.description))
      XCTAssertTrue(string.contains(testCase.expectedCanonicalName))

      // Cleanup
      try await sdk.removeFile(at: sdkSettingsFile)

      try await sdk.createDirectoryIfNeeded(at: sdk.pathsConfiguration.artifactBundlePath)

      for shouldUseFullPaths in [true, false] {
        // Generate bundle metadata
        try await sdk.generateArtifactBundleManifest(
          hostTriples: [sdk.targetTriple],
          artifacts: ["foo": sdk.pathsConfiguration.artifactBundlePath.appending("foo").appending("bar.json")],
          shouldUseFullPaths: shouldUseFullPaths
        )

        // Make sure the file exists
        let archiveMetadataFile = await sdk.pathsConfiguration.artifactBundlePath.appending("info.json")
        fileExists = await sdk.doesFileExist(at: archiveMetadataFile)
        XCTAssertTrue(fileExists)

        // Read back file, make sure it contains the expected data
        let data = try await sdk.readFile(at: archiveMetadataFile)
        let decodedMetadata = try JSONDecoder().decode(ArtifactsArchiveMetadata.self, from: data)
        XCTAssertEqual(decodedMetadata.artifacts.count, 1)
        let variant: ArtifactsArchiveMetadata.Variant
        if shouldUseFullPaths {
          variant = .init(path: "foo/bar.json", supportedTriples: [testCase.targetTriple.triple])
        } else {
          variant = .init(path: "foo", supportedTriples: [testCase.targetTriple.triple])
        }

        for (id, artifact) in decodedMetadata.artifacts {
          XCTAssertEqual(id, "foo")
          XCTAssertEqual(artifact.variants, [variant])
        }

        // Cleanup
        try await sdk.removeFile(at: archiveMetadataFile)
      }
    }
  }
}
