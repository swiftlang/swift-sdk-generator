//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
import Logging
import SystemPackage
import XCTest

@testable import SwiftSDKGenerator

final class EndToEndTests: XCTestCase {
  private let logger = Logger(label: "swift-sdk-generator")

  #if !os(macOS)
  func testPackageInitExecutable() async throws {
    let fm = FileManager.default

    var packageDirectory = FilePath(#file)
    packageDirectory.removeLastComponent()
    packageDirectory.removeLastComponent()

    // Do multiple runs with different sets of arguments.
    // Test with no arguments by default:
    var possibleArguments = [""]
    do {
      try await Shell.run("docker ps")
      possibleArguments.append("--with-docker --linux-distribution-name rhel --linux-distribution-version ubi9")
    } catch {
      self.logger.warning("Docker CLI does not seem to be working, skipping tests that involve Docker.")
    }

    for runArguments in possibleArguments {
      let generatorOutput = try await Shell.readStdout(
        "swift run swift-sdk-generator \(runArguments)",
        currentDirectory: packageDirectory
      )

      let installCommand = try XCTUnwrap(generatorOutput.split(separator: "\n").first {
        $0.contains("swift experimental-sdk install")
      })

      let bundleName = try XCTUnwrap(
        FilePath(String(XCTUnwrap(installCommand.split(separator: " ").last))).components.last
      ).stem

      let installedSDKs = try await Shell.readStdout("swift experimental-sdk list").components(separatedBy: "\n")

      // Make sure this bundle hasn't been installed already.
      if installedSDKs.contains(bundleName) {
        try await Shell.run("swift experimental-sdk remove \(bundleName)")
      }

      let installOutput = try await Shell.readStdout(String(installCommand))
      XCTAssertTrue(installOutput.contains("successfully installed"))

      let testPackageURL = FileManager.default.temporaryDirectory.appending(path: "swift-sdk-generator-test").path
      let testPackageDir = FilePath(testPackageURL)
      try? fm.removeItem(atPath: testPackageDir.string)
      try fm.createDirectory(atPath: testPackageDir.string, withIntermediateDirectories: true)

      try await Shell.run("swift package init --type executable", currentDirectory: testPackageDir)

      var buildOutput = try await Shell.readStdout(
        "swift build --experimental-swift-sdk \(bundleName)",
        currentDirectory: testPackageDir
      )
      XCTAssertTrue(buildOutput.contains("Build complete!"))

      try await Shell.run("rm -rf .build", currentDirectory: testPackageDir)

      buildOutput = try await Shell.readStdout(
        "swift build --experimental-swift-sdk \(bundleName) --static-swift-stdlib",
        currentDirectory: testPackageDir
      )
      XCTAssertTrue(buildOutput.contains("Build complete!"))
    }
  }
  #endif
}
