//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2022-2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Logging
import Testing

@testable import SwiftSDKGenerator

struct DownloadableArtifactsTests {
  private let logger = Logger(label: "DownloadableArtifactsTests")
  private let target = Triple("aarch64-unknown-linux-gnu")

  private func makeArtifacts(
    hostTriples: [Triple],
    swiftVersion: String = "6.3-RELEASE"
  ) throws -> DownloadableArtifacts {
    let versions = try VersionsConfiguration(
      swiftVersion: swiftVersion,
      lldVersion: "19.1.7",
      linuxDistribution: .ubuntu(.jammy),
      targetTriple: self.target,
      logger: self.logger
    )
    let paths = PathsConfiguration(
      sourceRoot: "/tmp/sdk-generator-test",
      artifactID: "test-sdk",
      targetTriple: self.target
    )
    return try DownloadableArtifacts(hostTriples: hostTriples, targetTriple: self.target, versions, paths)
  }

  @Test func macOSHostUsesUniversalSwiftPackageAndLLVMArchive() throws {
    let artifacts = try self.makeArtifacts(hostTriples: [Triple("arm64-apple-macosx13")])

    let expectedHostRemoteURL =
      "https://download.swift.org/swift-6.3-release/xcode/swift-6.3-RELEASE/swift-6.3-RELEASE-osx.pkg"
    let expectedHostLocalPath = "/tmp/sdk-generator-test/Artifacts/host_swift_6.3-RELEASE_apple-macos.pkg"
    #expect(artifacts.hostSwift.remoteURL.absoluteString == expectedHostRemoteURL)
    #expect(artifacts.hostSwift.localPath.string == expectedHostLocalPath)
    #expect(artifacts.hostSwift.isPrebuilt)

    let expectedHostLLVMRemoteURL =
      "https://github.com/llvm/llvm-project/releases/download/llvmorg-19.1.7/clang+llvm-19.1.7-arm64-apple-darwin22.0.tar.xz"
    let expectedHostLLVMLocalPath = "/tmp/sdk-generator-test/Artifacts/host_llvm_19.1.7_arm64-apple-macosx13.tar.xz"
    #expect(artifacts.hostLLVM.remoteURL.absoluteString == expectedHostLLVMRemoteURL)
    #expect(artifacts.hostLLVM.localPath.string == expectedHostLLVMLocalPath)
  }

  @Test(arguments: [
    ("x86_64-unknown-linux-gnu", "x86_64", "6.0-RELEASE", "amazonlinux2", "amazonlinux2"),
    ("aarch64-unknown-linux-gnu", "aarch64", "6.0-RELEASE", "amazonlinux2-aarch64", "amazonlinux2-aarch64"),
    ("x86_64-unknown-linux-gnu", "x86_64", "6.3-RELEASE", "amazonlinux2", "amazonlinux2"),
    ("aarch64-unknown-linux-gnu", "aarch64", "6.3-RELEASE", "amazonlinux2-aarch64", "amazonlinux2-aarch64"),
    // Swift 6.4 no longer supports Amazon Linux 2
    ("x86_64-unknown-linux-gnu", "x86_64", "6.4.0-RELEASE", "ubi9", "ubi9"),
    ("aarch64-unknown-linux-gnu", "aarch64", "6.4.0-RELEASE", "ubi9-aarch64", "ubi9-aarch64"),
  ])
  func linuxHostUsesSwiftArchive(
    hostTripleString: String,
    hostArch: String,
    swiftVersion: String,
    swiftPlatform: String,
    swiftSubdirectory: String
  ) throws {
    let artifacts = try self.makeArtifacts(hostTriples: [Triple(hostTripleString)], swiftVersion: swiftVersion)

    let expectedHostRemoteUrl =
      "https://download.swift.org/swift-\(swiftVersion.lowercased())/\(swiftSubdirectory)/swift-\(swiftVersion)/swift-\(swiftVersion)-\(swiftPlatform).tar.gz"
    let expectedHostLocalPath =
      "/tmp/sdk-generator-test/Artifacts/host_swift_\(swiftVersion)_\(hostTripleString).tar.gz"

    #expect(artifacts.hostSwift.remoteURL.absoluteString == expectedHostRemoteUrl)
    #expect(artifacts.hostSwift.localPath.string == expectedHostLocalPath)
    #expect(artifacts.hostSwift.isPrebuilt)
  }

  @Test func targetSwiftUsesTargetArchitectureAndPlatform() throws {
    let artifacts = try self.makeArtifacts(hostTriples: [Triple("x86_64-apple-macosx13")])

    #expect(
      artifacts.targetSwift.remoteURL.absoluteString
        == "https://download.swift.org/swift-6.3-release/ubuntu2204-aarch64/swift-6.3-RELEASE/swift-6.3-RELEASE-ubuntu22.04-aarch64.tar.gz"
    )
    #expect(
      artifacts.targetSwift.localPath.string
        == "/tmp/sdk-generator-test/Artifacts/target_swift_6.3-RELEASE_ubuntu22.04_aarch64.tar.gz"
    )
    #expect(artifacts.targetSwift.isPrebuilt)
  }

  @Test func useLLVMSourcesSwitchesURLPathAndPrebuiltFlag() throws {
    var artifacts = try self.makeArtifacts(hostTriples: [Triple("x86_64-apple-macosx13")])

    artifacts.useLLVMSources()

    #expect(
      artifacts.hostLLVM.remoteURL.absoluteString
        == "https://github.com/llvm/llvm-project/releases/download/llvmorg-19.1.7/llvm-project-19.1.7.src.tar.xz"
    )
    #expect(artifacts.hostLLVM.localPath.string == "/tmp/sdk-generator-test/Artifacts/llvm_19.1.7.src.tar.xz")
    #expect(!artifacts.hostLLVM.isPrebuilt)
  }

  @Test func emptyHostListThrowsNoHostTriples() {
    do {
      _ = try self.makeArtifacts(hostTriples: [])
      Issue.record("Expected an empty host list to throw")
    } catch let error as DownloadableArtifacts.Error {
      #expect(error.description == "no host triples")
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test func unsupportedHostTripleThrowsSpecificError() {
    let host = Triple("x86_64-unknown-freebsd")

    do {
      _ = try self.makeArtifacts(hostTriples: [host])
      Issue.record("Expected an unsupported host triple to throw")
    } catch let error as DownloadableArtifacts.Error {
      #expect(error.description == "unsupported host triple \(host)")
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test func multipleNonMacHostsThrowUnsupportedHostTriples() {
    let hosts = [Triple("x86_64-unknown-linux-gnu"), Triple("aarch64-unknown-linux-gnu")]

    do {
      _ = try self.makeArtifacts(hostTriples: hosts)
      Issue.record("Expected multiple Linux hosts to throw")
    } catch let error as DownloadableArtifacts.Error {
      #expect(
        error.description
          == "unsupported host triples \(hosts.map { "\($0)" }.joined(separator: ", ")) (only macOS supports multiple host triples)"
      )
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }
}
