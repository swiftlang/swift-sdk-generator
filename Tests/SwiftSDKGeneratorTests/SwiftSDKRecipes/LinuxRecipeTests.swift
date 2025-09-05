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
    hostTriples: [Triple] = [Triple("x86_64-unknown-linux-gnu")],
    linuxDistribution: LinuxDistribution,
    swiftVersion: String = "6.0",
    withDocker: Bool = false,
    fromContainerImage: String? = nil,
    hostSwiftPackagePath: String? = nil,
    targetSwiftPackagePath: String? = nil,
    includeHostToolchain: Bool = true
  ) throws -> LinuxRecipe {
    try LinuxRecipe(
      targetTriple: Triple("aarch64-unknown-linux-gnu"),
      hostTriples: hostTriples,
      linuxDistribution: linuxDistribution,
      swiftVersion: swiftVersion,
      swiftBranch: nil,
      lldVersion: "",
      withDocker: withDocker,
      fromContainerImage: fromContainerImage,
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
          "-Xclang-linker", "--ld-path=ld.lld",
        ],
        expectedLinkerPath: nil
      ),
      (
        swiftVersion: "6.0.2",
        targetTriple: Triple("aarch64-unknown-linux-gnu"),
        expectedSwiftCompilerOptions: [
          "-Xlinker", "-R/usr/lib/swift/linux/",
          "-use-ld=lld",
        ],
        expectedLinkerPath: "ld.lld"
      ),
      (
        swiftVersion: "6.0.3",
        targetTriple: Triple("armv7-unknown-linux-gnueabihf"),
        expectedSwiftCompilerOptions: [
          "-Xlinker", "-R/usr/lib/swift/linux/",
          "-use-ld=lld",
          "-latomic",
        ],
        expectedLinkerPath: "ld.lld"
      ),
    ]

    let linuxDistribution = try LinuxDistribution(name: .ubuntu, version: "22.04")
    for testCase in testCases {
      let recipe = try self.createRecipe(
        linuxDistribution: linuxDistribution,
        swiftVersion: testCase.swiftVersion
      )
      var toolset = Toolset(rootPath: nil)
      recipe.applyPlatformOptions(
        toolset: &toolset,
        targetTriple: testCase.targetTriple,
        isForEmbeddedSwift: false
      )
      XCTAssertEqual(toolset.swiftCompiler?.extraCLIOptions, testCase.expectedSwiftCompilerOptions)
      XCTAssertEqual(toolset.linker?.path, testCase.expectedLinkerPath)
      XCTAssertEqual(toolset.cxxCompiler?.extraCLIOptions, ["-lstdc++"])
      XCTAssertEqual(toolset.librarian?.path, "llvm-ar")
    }
  }

  func testToolOptionsForPreinstalledSdk() throws {
    let linuxDistribution = try LinuxDistribution(name: .ubuntu, version: "22.04")
    let recipe = try self.createRecipe(
      linuxDistribution: linuxDistribution,
      includeHostToolchain: false
    )
    var toolset = Toolset(rootPath: "swift.xctoolchain")
    recipe.applyPlatformOptions(
      toolset: &toolset,
      targetTriple: Triple("x86_64-unknown-linux-gnu"),
      isForEmbeddedSwift: false
    )
    XCTAssertEqual(toolset.rootPath, nil)
    XCTAssertEqual(
      toolset.swiftCompiler?.extraCLIOptions,
      [
        "-Xlinker", "-R/usr/lib/swift/linux/",
        "-use-ld=lld",
      ]
    )
    XCTAssertEqual(toolset.cxxCompiler?.extraCLIOptions, ["-lstdc++"])
    XCTAssert(toolset.librarian == nil)
    XCTAssert(toolset.linker == nil)
  }

  func runItemsToDownloadTestCase(
    recipe: LinuxRecipe,
    includesHostLLVM: Bool,
    includesTargetSwift: Bool,
    includesHostSwift: Bool
  ) throws {
    let pathsConfiguration = PathsConfiguration(
      sourceRoot: ".",
      artifactID: "my-sdk",
      targetTriple: recipe.mainTargetTriple
    )
    let downloadableArtifacts = try DownloadableArtifacts(
      hostTriples: recipe.mainHostTriples,
      targetTriple: recipe.mainTargetTriple,
      recipe.versionsConfiguration,
      pathsConfiguration
    )
    let itemsToDownload = recipe.itemsToDownload(from: downloadableArtifacts)
    let foundHostLLVM = itemsToDownload.contains(where: {
      $0.remoteURL == downloadableArtifacts.hostLLVM.remoteURL
    })
    let foundTargetSwift = itemsToDownload.contains(where: {
      $0.remoteURL == downloadableArtifacts.targetSwift.remoteURL
    })
    let foundHostSwift = itemsToDownload.contains(where: {
      $0.remoteURL == downloadableArtifacts.hostSwift.remoteURL
    })

    // If this is a Linux host, we do not download LLVM
    XCTAssertEqual(foundHostLLVM, includesHostLLVM)
    XCTAssertEqual(foundTargetSwift, includesTargetSwift)
    XCTAssertEqual(foundHostSwift, includesHostSwift)
  }

  func testItemsToDownloadForMacOSHost_noArchs() throws {
    try testItemsToDownloadForMacOSHost(hostTriples: []) { result in
      XCTAssertThrowsError(
        try result.get(),
        "",
        { error in
          if case DownloadableArtifacts.Error.noHostTriples = error {
            return
          }
          XCTFail("unexpected error: \(error)")
        }
      )
    }
  }

  func testItemsToDownloadForMacOSHost_arm64() throws {
    try testItemsToDownloadForMacOSHost(hostTriples: [Triple("arm64-apple-macos")])
  }

  func testItemsToDownloadForMacOSHost_x86_64() throws {
    try testItemsToDownloadForMacOSHost(hostTriples: [Triple("x86_64-apple-macos")])
  }

  func testItemsToDownloadForMacOSHost_multiArch() throws {
    try testItemsToDownloadForMacOSHost(
      hostTriples: [Triple("arm64-apple-macos"), Triple("x86_64-apple-macos")]
    )
  }

  /// Runs a series of test cases with expectation for a macOS host.
  /// - parameter hostTriples: The list of host triples that the generated SDK should be compatible with.
  /// - parameter validate: A function to validate the result of each test case - this is a `Result`
  ///   in order to allow clients to either expect that the test case did not throw an error (succeeded),
  ///   or that it did throw an error (expected failure).
  private func testItemsToDownloadForMacOSHost(
    hostTriples: [Triple],
    validate: ((Result<Void, Error>) throws -> Void)? = nil
  ) throws {
    let linuxDistribution = try LinuxDistribution(name: .ubuntu, version: "22.04")
    let testCases:
      [(
        recipe: LinuxRecipe, includesHostLLVM: Bool, includesTargetSwift: Bool,
        includesHostSwift: Bool
      )] = [
        (
          // Remote tarballs on Swift < 6.0
          recipe: try createRecipe(
            hostTriples: hostTriples,
            linuxDistribution: linuxDistribution,
            swiftVersion: "5.10"
          ),
          includesHostLLVM: true,
          includesTargetSwift: true,
          includesHostSwift: true
        ),
        (
          // Remote tarballs on Swift >= 6.0
          recipe: try createRecipe(
            hostTriples: hostTriples,
            linuxDistribution: linuxDistribution,
            swiftVersion: "6.0"
          ),
          includesHostLLVM: false,
          includesTargetSwift: true,
          includesHostSwift: true
        ),
        (
          // Remote target tarball with preinstalled toolchain
          recipe: try createRecipe(
            hostTriples: hostTriples,
            linuxDistribution: linuxDistribution,
            swiftVersion: "5.9",
            includeHostToolchain: false
          ),
          includesHostLLVM: false,
          includesTargetSwift: true,
          includesHostSwift: false
        ),
        (
          // Local packages with Swift < 6.0
          recipe: try createRecipe(
            hostTriples: hostTriples,
            linuxDistribution: linuxDistribution,
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
            hostTriples: hostTriples,
            linuxDistribution: linuxDistribution,
            swiftVersion: "6.0",
            hostSwiftPackagePath: "/path/to/host/swift",
            targetSwiftPackagePath: "/path/to/target/swift"
          ),
          includesHostLLVM: false,
          includesTargetSwift: false,
          includesHostSwift: false
        ),
      ]

    for testCase in testCases {
      let result = Result {
        try runItemsToDownloadTestCase(
          recipe: testCase.recipe,
          includesHostLLVM: testCase.includesHostLLVM,
          includesTargetSwift: testCase.includesTargetSwift,
          includesHostSwift: testCase.includesHostSwift
        )
      }
      if let validate {
        try validate(result)
      } else {
        try result.get()
      }
    }
  }

  func testItemsToDownloadForLinuxHost() throws {
    let hostTriples = [Triple("x86_64-unknown-linux-gnu")]
    let linuxDistribution = try LinuxDistribution(name: .ubuntu, version: "22.04")
    let testCases = [
      (
        // Remote tarballs on Swift < 6.0
        recipe: try createRecipe(
          hostTriples: hostTriples,
          linuxDistribution: linuxDistribution,
          swiftVersion: "5.10"
        ),
        includesTargetSwift: true,
        includesHostSwift: true
      ),
      (
        // Remote tarballs on Swift >= 6.0
        recipe: try createRecipe(
          hostTriples: hostTriples,
          linuxDistribution: linuxDistribution,
          swiftVersion: "6.0"
        ),
        includesTargetSwift: true,
        includesHostSwift: true
      ),
      (
        // Remote target tarball with preinstalled toolchain
        recipe: try createRecipe(
          hostTriples: hostTriples,
          linuxDistribution: linuxDistribution,
          swiftVersion: "5.9",
          includeHostToolchain: false
        ),
        includesTargetSwift: true,
        includesHostSwift: false
      ),
      (
        // Local packages with Swift < 6.0
        recipe: try createRecipe(
          hostTriples: hostTriples,
          linuxDistribution: linuxDistribution,
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
          hostTriples: hostTriples,
          linuxDistribution: linuxDistribution,
          swiftVersion: "6.0",
          hostSwiftPackagePath: "/path/to/host/swift",
          targetSwiftPackagePath: "/path/to/target/swift"
        ),
        includesTargetSwift: false,
        includesHostSwift: false
      ),
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

  func testItemsToDownloadForLinuxMultiHost() throws {
    let hostTriples = [Triple("aarch64-unknown-linux-gnu"), Triple("x86_64-unknown-linux-gnu")]
    let linuxDistribution = try LinuxDistribution(name: .ubuntu, version: "22.04")
    XCTAssertThrowsError(
      try runItemsToDownloadTestCase(
        recipe: createRecipe(
          hostTriples: hostTriples,
          linuxDistribution: linuxDistribution,
          swiftVersion: "5.10"
        ),
        includesHostLLVM: false,  // when host is Linux we do not download LLVM
        includesTargetSwift: true,
        includesHostSwift: true
      ),
      ""
    ) { error in
      if case DownloadableArtifacts.Error.unsupportedHostTriples(hostTriples) = error {
        return
      }
      XCTFail("unexpected error: \(error)")
    }
  }

  func testItemsToDownloadForUnsupportedHost() throws {
    let linuxDistribution = try LinuxDistribution(name: .ubuntu, version: "22.04")

    let hostTriple = Triple("x86_64-pc-windows-msvc")
    XCTAssertThrowsError(
      try runItemsToDownloadTestCase(
        recipe: createRecipe(
          hostTriples: [hostTriple],
          linuxDistribution: linuxDistribution,
          swiftVersion: "5.10"
        ),
        includesHostLLVM: false,
        includesTargetSwift: true,
        includesHostSwift: true
      ),
      ""
    ) { error in
      if case DownloadableArtifacts.Error.unsupportedHostTriple(hostTriple) = error {
        return
      }
      XCTFail("unexpected error: \(error)")
    }

    let hostTriples = [Triple("aarch64-pc-windows-msvc"), Triple("x86_64-pc-windows-msvc")]
    XCTAssertThrowsError(
      try runItemsToDownloadTestCase(
        recipe: createRecipe(
          hostTriples: hostTriples,
          linuxDistribution: linuxDistribution,
          swiftVersion: "5.10"
        ),
        includesHostLLVM: false,
        includesTargetSwift: true,
        includesHostSwift: true
      ),
      ""
    ) { error in
      if case DownloadableArtifacts.Error.unsupportedHostTriples(hostTriples) = error {
        return
      }
      XCTFail("unexpected error: \(error)")
    }
  }

  // Ubuntu toolchains will be selected for Debian 11 and 12 depending on the Swift version
  func testItemsToDownloadForDebianTargets() throws {
    let hostTriples = [Triple("x86_64-unknown-linux-gnu")]
    let testCases = [
      (
        // Debian 11 -> ubuntu20.04
        recipe: try createRecipe(
          hostTriples: hostTriples,
          linuxDistribution: try LinuxDistribution(name: .debian, version: "11"),
          swiftVersion: "5.9"
        ),
        expectedTargetSwift: "ubuntu20.04"
      ),
      (
        // Debian 12 with Swift 5.9 -> ubuntu22.04
        recipe: try createRecipe(
          hostTriples: hostTriples,
          linuxDistribution: try LinuxDistribution(name: .debian, version: "12"),
          swiftVersion: "5.9"
        ),
        expectedTargetSwift: "ubuntu22.04"
      ),
      (
        // Debian 12 with Swift 5.10 -> ubuntu22.04
        recipe: try createRecipe(
          hostTriples: hostTriples,
          linuxDistribution: try LinuxDistribution(name: .debian, version: "12"),
          swiftVersion: "5.10"
        ),
        expectedTargetSwift: "ubuntu22.04"
      ),
      (
        // Debian 11 with Swift 6.0 -> ubuntu20.04
        recipe: try createRecipe(
          hostTriples: hostTriples,
          linuxDistribution: try LinuxDistribution(name: .debian, version: "11"),
          swiftVersion: "6.0"
        ),
        expectedTargetSwift: "ubuntu20.04"
      ),
      (
        // Debian 12 with Swift 5.10.1 -> debian12
        recipe: try createRecipe(
          hostTriples: hostTriples,
          linuxDistribution: try LinuxDistribution(name: .debian, version: "12"),
          swiftVersion: "5.10.1"
        ),
        expectedTargetSwift: "debian12"
      ),
      (
        // Debian 12 with Swift 6.0 -> debian12
        recipe: try createRecipe(
          hostTriples: hostTriples,
          linuxDistribution: try LinuxDistribution(name: .debian, version: "12"),
          swiftVersion: "6.0"
        ),
        expectedTargetSwift: "debian12"
      ),
    ]

    for testCase in testCases {

      let pathsConfiguration = PathsConfiguration(
        sourceRoot: ".",
        artifactID: "my-sdk",
        targetTriple: testCase.recipe.mainTargetTriple
      )
      let downloadableArtifacts = try DownloadableArtifacts(
        hostTriples: testCase.recipe.mainHostTriples,
        targetTriple: testCase.recipe.mainTargetTriple,
        testCase.recipe.versionsConfiguration,
        pathsConfiguration
      )
      let itemsToDownload = testCase.recipe.itemsToDownload(from: downloadableArtifacts)
      let targetSwiftRemoteURL = itemsToDownload.first(where: {
        $0.remoteURL == downloadableArtifacts.targetSwift.remoteURL
      })?.remoteURL.absoluteString

      // If this is a Linux host, we do not download LLVM
      XCTAssert(targetSwiftRemoteURL!.contains(testCase.expectedTargetSwift))
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
      (
        swiftVersion: "6.0", includeHostToolchain: true,
        expectedHostTriples: [Triple("x86_64-unknown-linux-gnu")]
      ),
    ]

    let linuxDistribution = try LinuxDistribution(name: .ubuntu, version: "22.04")
    for testCase in testCases {
      let recipe = try createRecipe(
        linuxDistribution: linuxDistribution,
        swiftVersion: testCase.swiftVersion,
        includeHostToolchain: testCase.includeHostToolchain
      )
      XCTAssertEqual(recipe.hostTriples, testCase.expectedHostTriples)
    }
  }
}
