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

import struct Foundation.URL

public struct VersionsConfiguration: Sendable {
  init(
    swiftVersion: String,
    swiftBranch: String? = nil,
    lldVersion: String,
    linuxDistribution: LinuxDistribution,
    targetTriple: Triple
  ) throws {
    self.swiftVersion = swiftVersion
    self.swiftBranch = swiftBranch ?? "swift-\(swiftVersion.lowercased())"
    self.lldVersion = lldVersion
    self.linuxDistribution = linuxDistribution
    self.linuxArchSuffix = targetTriple.cpu == .arm64 ? "-\(Triple.CPU.arm64.linuxConventionName)" : ""
  }

  let swiftVersion: String
  let swiftBranch: String
  let lldVersion: String
  let linuxDistribution: LinuxDistribution
  let linuxArchSuffix: String

  var swiftPlatform: String {
    switch self.linuxDistribution {
    case let .ubuntu(ubuntu):
      "ubuntu\(ubuntu.version)\(self.linuxArchSuffix)"
    case let .rhel(rhel):
      "\(rhel.rawValue)\(self.linuxArchSuffix)"
    }
  }

  func swiftDistributionName(platform: String? = nil) -> String {
    "swift-\(self.swiftVersion)-\(platform ?? self.swiftPlatform)"
  }

  func swiftDownloadURL(
    subdirectory: String? = nil,
    platform: String? = nil,
    fileExtension: String = "tar.gz"
  ) -> URL {
    let computedSubdirectory = switch self.linuxDistribution {
    case let .ubuntu(ubuntu):
      "ubuntu\(ubuntu.version.replacingOccurrences(of: ".", with: ""))\(self.linuxArchSuffix)"
    case let .rhel(rhel):
      rhel.rawValue
    }

    return URL(
      string: """
      https://download.swift.org/\(
        self.swiftBranch
      )/\(
        subdirectory ?? computedSubdirectory
      )/swift-\(self.swiftVersion)/\(self.swiftDistributionName(platform: platform)).\(fileExtension)
      """
    )!
  }

  var swiftBareSemVer: String {
    self.swiftVersion.components(separatedBy: "-")[0]
  }

  /// Name of a Docker image containing the Swift toolchain and SDK for this Linux distribution.
  var swiftBaseDockerImage: String {
    if self.swiftVersion.hasSuffix("-RELEASE") {
      "swift:\(self.swiftBareSemVer)-\(self.linuxDistribution.swiftDockerImageSuffix)"
    } else {
      fatalError()
    }
  }
}
