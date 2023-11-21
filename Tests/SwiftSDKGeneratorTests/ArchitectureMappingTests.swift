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

import Logging
@testable import SwiftSDKGenerator
import XCTest

final class ArchitectureMappingTests: XCTestCase {
  /// Swift on macOS, Swift on Linux and Debian packages all use
  /// different names for the x86 and Arm architectures:
  ///
  ///                     |  x86_64    arm64
  ///    ------------------------------------
  ///    Swift macOS      |  x86_64    arm64
  ///    Swift Linux      |  x86_64  aarch64
  ///    Debian packages  |   amd64    arm64
  ///
  /// The right names must be used in the right places, such as
  /// in download URLs and paths within the SDK bundle.   These
  /// tests check several paths and URLs for each combination
  /// of host and target architecture.
  ///
  /// At present macOS is the only supported build environment
  /// and Linux is the only supported target environment.

  public func verifySDKSpec(
    hostCPUArchitecture: Triple.CPU, // CPU architecture of the build system
    targetCPUArchitecture: Triple.CPU, // CPU architecture of the target

    artifactID: String, // Base name of the generated bundle
    hostLLVMDownloadURL: String, // URL of the host LLVM package
    targetSwiftDownloadURL: String, // URL of the target Swift SDK

    artifactBundlePathSuffix: String, // Path to the generated bundle
    sdkDirPathSuffix: String // Path of the SDK within the bundle
  ) async throws {
    // LocalSwiftSDKGenerator constructs URLs and paths which depend on architectures
    let sdk = try await SwiftSDKGenerator(
      // macOS is currently the only supported build environment
      hostCPUArchitecture: hostCPUArchitecture,

      // Linux is currently the only supported runtime environment
      targetCPUArchitecture: targetCPUArchitecture,

      // Remaining fields are placeholders which are the same for all
      // combinations of build and runtime architecture
      swiftVersion: "5.8-RELEASE",
      swiftBranch: nil,
      lldVersion: "16.0.4",
      linuxDistribution: .ubuntu(.jammy),
      shouldUseDocker: false,
      baseDockerImage: nil,
      artifactID: nil,
      isIncremental: false,
      isVerbose: false,
      logger: Logger(label: "org.swift.swift-sdk-generator")
    )

    let sdkArtifactID = await sdk.artifactID
    XCTAssertEqual(sdkArtifactID, artifactID, "Unexpected artifactID")

    // Verify download URLs
    let artifacts = await sdk.downloadableArtifacts

    // The build-time Swift SDK is a multiarch package and so is always the same
    XCTAssertEqual(
      artifacts.hostSwift.remoteURL.absoluteString,
      "https://download.swift.org/swift-5.8-release/xcode/swift-5.8-RELEASE/swift-5.8-RELEASE-osx.pkg",
      "Unexpected build-time Swift SDK URL"
    )

    // LLVM provides ld.lld
    XCTAssertEqual(
      artifacts.hostLLVM.remoteURL.absoluteString,
      hostLLVMDownloadURL,
      "Unexpected llvmDownloadURL"
    )

    // The Swift runtime must match the target architecture
    XCTAssertEqual(
      artifacts.targetSwift.remoteURL.absoluteString,
      targetSwiftDownloadURL,
      "Unexpected runtimeSwiftDownloadURL"
    )

    // Verify paths within the bundle
    let paths = await sdk.pathsConfiguration

    // The bundle path is not critical - it uses Swift's name
    // for the target architecture
    XCTAssertEqual(
      paths.artifactBundlePath.string,
      paths.sourceRoot.string + artifactBundlePathSuffix,
      "Unexpected artifactBundlePathSuffix"
    )

    // The SDK path must use Swift's name for the architecture
    XCTAssertEqual(
      paths.sdkDirPath.string,
      paths.artifactBundlePath.string + sdkDirPathSuffix,
      "Unexpected sdkDirPathSuffix"
    )
  }

  func testX86ToX86SDKGenerator() async throws {
    try await self.verifySDKSpec(
      hostCPUArchitecture: .x86_64,
      targetCPUArchitecture: .x86_64,
      artifactID: "5.8-RELEASE_ubuntu_jammy_x86_64",
      hostLLVMDownloadURL: "https://github.com/llvm/llvm-project/releases/download/llvmorg-16.0.4/clang+llvm-16.0.4-x86_64-apple-darwin22.0.tar.xz",
      targetSwiftDownloadURL: "https://download.swift.org/swift-5.8-release/ubuntu2204/swift-5.8-RELEASE/swift-5.8-RELEASE-ubuntu22.04.tar.gz",
      artifactBundlePathSuffix: "/Bundles/5.8-RELEASE_ubuntu_jammy_x86_64.artifactbundle",
      sdkDirPathSuffix: "/5.8-RELEASE_ubuntu_jammy_x86_64/x86_64-unknown-linux-gnu/ubuntu-jammy.sdk"
    )
  }

  func testX86ToArmSDKGenerator() async throws {
    try await self.verifySDKSpec(
      hostCPUArchitecture: .x86_64,
      targetCPUArchitecture: .arm64,
      artifactID: "5.8-RELEASE_ubuntu_jammy_aarch64",
      hostLLVMDownloadURL: "https://github.com/llvm/llvm-project/releases/download/llvmorg-16.0.4/clang+llvm-16.0.4-x86_64-apple-darwin22.0.tar.xz",
      targetSwiftDownloadURL: "https://download.swift.org/swift-5.8-release/ubuntu2204-aarch64/swift-5.8-RELEASE/swift-5.8-RELEASE-ubuntu22.04-aarch64.tar.gz",
      artifactBundlePathSuffix: "/Bundles/5.8-RELEASE_ubuntu_jammy_aarch64.artifactbundle",
      sdkDirPathSuffix: "/5.8-RELEASE_ubuntu_jammy_aarch64/aarch64-unknown-linux-gnu/ubuntu-jammy.sdk"
    )
  }

  func testArmToArmSDKGenerator() async throws {
    try await self.verifySDKSpec(
      hostCPUArchitecture: .arm64,
      targetCPUArchitecture: .arm64,
      artifactID: "5.8-RELEASE_ubuntu_jammy_aarch64",
      hostLLVMDownloadURL: "https://github.com/llvm/llvm-project/releases/download/llvmorg-16.0.4/clang+llvm-16.0.4-arm64-apple-darwin22.0.tar.xz",
      targetSwiftDownloadURL: "https://download.swift.org/swift-5.8-release/ubuntu2204-aarch64/swift-5.8-RELEASE/swift-5.8-RELEASE-ubuntu22.04-aarch64.tar.gz",
      artifactBundlePathSuffix: "/Bundles/5.8-RELEASE_ubuntu_jammy_aarch64.artifactbundle",
      sdkDirPathSuffix: "/5.8-RELEASE_ubuntu_jammy_aarch64/aarch64-unknown-linux-gnu/ubuntu-jammy.sdk"
    )
  }

  func testArmToX86SDKGenerator() async throws {
    try await self.verifySDKSpec(
      hostCPUArchitecture: .arm64,
      targetCPUArchitecture: .x86_64,
      artifactID: "5.8-RELEASE_ubuntu_jammy_x86_64",
      hostLLVMDownloadURL: "https://github.com/llvm/llvm-project/releases/download/llvmorg-16.0.4/clang+llvm-16.0.4-arm64-apple-darwin22.0.tar.xz",
      targetSwiftDownloadURL: "https://download.swift.org/swift-5.8-release/ubuntu2204/swift-5.8-RELEASE/swift-5.8-RELEASE-ubuntu22.04.tar.gz",
      artifactBundlePathSuffix: "/Bundles/5.8-RELEASE_ubuntu_jammy_x86_64.artifactbundle",
      sdkDirPathSuffix: "/5.8-RELEASE_ubuntu_jammy_x86_64/x86_64-unknown-linux-gnu/ubuntu-jammy.sdk"
    )
  }
}
