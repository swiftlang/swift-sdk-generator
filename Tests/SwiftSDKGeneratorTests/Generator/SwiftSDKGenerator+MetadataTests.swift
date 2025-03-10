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

import Logging
import SystemPackage
import XCTest

@testable import SwiftSDKGenerator

final class SwiftSDKGeneratorMetadataTests: XCTestCase {
  let logger = Logger(label: "SwiftSDKGeneratorMetadataTests")

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
      let fileExists = await sdk.doesFileExist(at: sdkSettingsFile)
      XCTAssertTrue(fileExists)

      // Read back file, make sure it contains the expected data
      let data = String(data: try await sdk.readFile(at: sdkSettingsFile), encoding: .utf8)
      XCTAssertNotNil(data)
      XCTAssertTrue(data!.contains(testCase.bundleVersion))
      XCTAssertTrue(data!.contains("(\(testCase.targetTriple.archName))"))
      XCTAssertTrue(data!.contains(linuxDistribution.description))
      XCTAssertTrue(data!.contains(testCase.expectedCanonicalName))

      // Cleanup
      try await sdk.removeFile(at: sdkSettingsFile)
    }
  }
}
