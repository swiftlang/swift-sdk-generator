//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2022-2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Logging
import XCTest

@testable import SwiftSDKGenerator

final class LinuxRecipeTests: XCTestCase {
  let logger = Logger(label: "LinuxRecipeTests")

  func createRecipe(
    hostTriple: Triple = Triple("x86_64-unknown-linux-gnu"),
    swiftVersion: String = "6.0",
    withDocker: Bool = false,
    fromContainerImage: String? = nil,
    hostSwiftPackagePath: String? = nil,
    targetSwiftPackagePath: String? = nil,
    includeHostToolchain: Bool = true
  ) throws -> LinuxRecipe {
   try LinuxRecipe(
      targetTriple: Triple("aarch64-unknown-linux-gnu"),
      hostTriple: hostTriple,
      linuxDistribution: .init(name: .ubuntu, version: "22.04"),
      swiftVersion: swiftVersion,
      swiftBranch: nil, lldVersion: "",
      withDocker: withDocker, fromContainerImage: fromContainerImage,
      hostSwiftPackagePath: hostSwiftPackagePath,
      targetSwiftPackagePath: targetSwiftPackagePath,
      includeHostToolchain: includeHostToolchain,
      logger: logger
    )
  }

  func testToolOptionsForSwiftVersions() throws {
    let testCases = [
      (
        swiftVersion: "5.9.2",
        targetTriple: Triple("x86_64-unknown-linux-gnu"),
        expectedSwiftCompilerOptions: [
          "-Xlinker", "-R/usr/lib/swift/linux/",
          "-Xclang-linker", "--ld-path=ld.lld"
        ],
        expectedLinkerPath: nil
      ),
      (
        swiftVersion: "6.0.2",
        targetTriple: Triple("aarch64-unknown-linux-gnu"),
        expectedSwiftCompilerOptions: [
          "-Xlinker", "-R/usr/lib/swift/linux/",
          "-use-ld=lld"
        ],
        expectedLinkerPath: "ld.lld"
      ),
      (
        swiftVersion: "6.0.3",
        targetTriple: Triple("armv7-unknown-linux-gnueabihf"),
        expectedSwiftCompilerOptions: [
          "-Xlinker", "-R/usr/lib/swift/linux/",
          "-use-ld=lld",
          "-latomic"
        ],
        expectedLinkerPath: "ld.lld"
      )
    ]

    for testCase in testCases {
      let recipe = try self.createRecipe(swiftVersion: testCase.swiftVersion)
      var toolset = Toolset(rootPath: nil)
      recipe.applyPlatformOptions(
        toolset: &toolset, targetTriple: testCase.targetTriple
      )
      XCTAssertEqual(toolset.swiftCompiler?.extraCLIOptions, testCase.expectedSwiftCompilerOptions)
      XCTAssertEqual(toolset.linker?.path, testCase.expectedLinkerPath)
      XCTAssertEqual(toolset.cxxCompiler?.extraCLIOptions, ["-lstdc++"])
      XCTAssertEqual(toolset.librarian?.path, "llvm-ar")
    }
  }

  func testToolOptionsForPreinstalledSdk() throws {
    let recipe = try self.createRecipe(includeHostToolchain: false)
    var toolset = Toolset(rootPath: "swift.xctoolchain")
    recipe.applyPlatformOptions(
      toolset: &toolset, targetTriple: Triple("x86_64-unknown-linux-gnu")
    )
    XCTAssertEqual(toolset.rootPath, nil)
    XCTAssertEqual(toolset.swiftCompiler?.extraCLIOptions, [
      "-Xlinker", "-R/usr/lib/swift/linux/",
      "-use-ld=lld"
    ])
    XCTAssertEqual(toolset.cxxCompiler?.extraCLIOptions, ["-lstdc++"])
    XCTAssertEqual(toolset.librarian?.path, "llvm-ar")
    XCTAssert(toolset.linker == nil)
  }

  func runItemsToDownloadTestCase(
    recipe: LinuxRecipe, includesHostLLVM: Bool, includesTargetSwift: Bool, includesHostSwift: Bool
  ) throws {
    let pathsConfiguration = PathsConfiguration(
      sourceRoot: ".",
      artifactID: "my-sdk",
      targetTriple: recipe.mainTargetTriple
    )
    let downloadableArtifacts = try DownloadableArtifacts(
      hostTriple: recipe.mainHostTriple,
      targetTriple: recipe.mainTargetTriple,
      recipe.versionsConfiguration,
      pathsConfiguration
    )
    let itemsToDownload = recipe.itemsToDownload(from: downloadableArtifacts)
    let foundHostLLVM = itemsToDownload.contains(where: { $0.remoteURL == downloadableArtifacts.hostLLVM.remoteURL })
    let foundTargetSwift = itemsToDownload.contains(where: { $0.remoteURL == downloadableArtifacts.targetSwift.remoteURL })
    let foundHostSwift = itemsToDownload.contains(where: { $0.remoteURL == downloadableArtifacts.hostSwift.remoteURL })

    // If this is a Linux host, we do not download LLVM
    XCTAssertEqual(foundHostLLVM, includesHostLLVM)
    XCTAssertEqual(foundTargetSwift, includesTargetSwift)
    XCTAssertEqual(foundHostSwift, includesHostSwift)
  }

  func testItemsToDownloadForMacOSHost() throws {
    let hostTriple = Triple("x86_64-apple-macos")
    let testCases: [(recipe: LinuxRecipe, includesHostLLVM: Bool, includesTargetSwift: Bool, includesHostSwift: Bool)] = [
      (
        // Remote tarballs on Swift < 6.0
        recipe: try createRecipe(hostTriple: hostTriple, swiftVersion: "5.10"),
        includesHostLLVM: true,
        includesTargetSwift: true,
        includesHostSwift: true
      ),
      (
        // Remote tarballs on Swift >= 6.0
        recipe: try createRecipe(hostTriple: hostTriple, swiftVersion: "6.0"),
        includesHostLLVM: false,
        includesTargetSwift: true,
        includesHostSwift: true
      ),
      (
        // Remote target tarball with preinstalled toolchain
        recipe: try createRecipe(hostTriple: hostTriple, swiftVersion: "5.9", includeHostToolchain: false),
        includesHostLLVM: false,
        includesTargetSwift: true,
        includesHostSwift: false
      ),
      (
        // Local packages with Swift < 6.0
        recipe: try createRecipe(
          hostTriple: hostTriple,
          swiftVersion: "5.10",
          hostSwiftPackagePath: "/path/to/host/swift",
          targetSwiftPackagePath: "/path/to/target/swift"
        ),
        includesHostLLVM: true,
        includesTargetSwift: false,
        includesHostSwift: false
      ),
      (
        // Local packages with Swift >= 6.0
        recipe: try createRecipe(
          hostTriple: hostTriple,
          swiftVersion: "6.0",
          hostSwiftPackagePath: "/path/to/host/swift",
          targetSwiftPackagePath: "/path/to/target/swift"
        ),
        includesHostLLVM: false,
        includesTargetSwift: false,
        includesHostSwift: false
      )
    ]

    for testCase in testCases {
      try runItemsToDownloadTestCase(
        recipe: testCase.recipe,
        includesHostLLVM: testCase.includesHostLLVM,
        includesTargetSwift: testCase.includesTargetSwift,
        includesHostSwift: testCase.includesHostSwift
      )
    }
  }

  func testItemsToDownloadForLinuxHost() throws {
    let hostTriple = Triple("x86_64-unknown-linux-gnu")
    let testCases = [
      (
        // Remote tarballs on Swift < 6.0
        recipe: try createRecipe(hostTriple: hostTriple, swiftVersion: "5.10"),
        includesTargetSwift: true,
        includesHostSwift: true
      ),
      (
        // Remote tarballs on Swift >= 6.0
        recipe: try createRecipe(hostTriple: hostTriple, swiftVersion: "6.0"),
        includesTargetSwift: true,
        includesHostSwift: true
      ),
      (
        // Remote target tarball with preinstalled toolchain
        recipe: try createRecipe(hostTriple: hostTriple, swiftVersion: "5.9", includeHostToolchain: false),
        includesTargetSwift: true,
        includesHostSwift: false
      ),
      (
        // Local packages with Swift < 6.0
        recipe: try createRecipe(
          hostTriple: hostTriple,
          swiftVersion: "5.10",
          hostSwiftPackagePath: "/path/to/host/swift",
          targetSwiftPackagePath: "/path/to/target/swift"
        ),
        includesTargetSwift: false,
        includesHostSwift: false
      ),
      (
        // Local packages with Swift >= 6.0
        recipe: try createRecipe(
          hostTriple: hostTriple,
          swiftVersion: "6.0",
          hostSwiftPackagePath: "/path/to/host/swift",
          targetSwiftPackagePath: "/path/to/target/swift"
        ),
        includesTargetSwift: false,
        includesHostSwift: false
      )
    ]

    for testCase in testCases {
      try runItemsToDownloadTestCase(
        recipe: testCase.recipe,
        includesHostLLVM: false,  // when host is Linux we do not download LLVM
        includesTargetSwift: testCase.includesTargetSwift,
        includesHostSwift: testCase.includesHostSwift
      )
    }
  }

  func testHostTriples() throws {
    let allHostTriples = [
      Triple("x86_64-unknown-linux-gnu"),
      Triple("aarch64-unknown-linux-gnu"),
      Triple("x86_64-apple-macos"),
      Triple("arm64-apple-macos"),
    ]
    let testCases = [
      (swiftVersion: "5.9", includeHostToolchain: false, expectedHostTriples: allHostTriples),
      (swiftVersion: "5.10", includeHostToolchain: false, expectedHostTriples: allHostTriples),
      (swiftVersion: "6.0", includeHostToolchain: false, expectedHostTriples: nil),
      (swiftVersion: "6.0", includeHostToolchain: true, expectedHostTriples: [Triple("x86_64-unknown-linux-gnu")])
    ]

    for testCase in testCases {
      let recipe = try createRecipe(
        swiftVersion: testCase.swiftVersion,
        includeHostToolchain: testCase.includeHostToolchain
      )
      XCTAssertEqual(recipe.hostTriples, testCase.expectedHostTriples)
    }
  }
}
