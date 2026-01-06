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

import struct Foundation.URL

public struct VersionsConfiguration: Sendable {
  init(
    swiftVersion: String,
    swiftBranch: String? = nil,
    lldVersion: String,
    linuxDistribution: LinuxDistribution,
    targetTriple: Triple,
    logger: Logger
  ) throws {
    self.swiftVersion = swiftVersion
    self.swiftBranch = swiftBranch ?? "swift-\(swiftVersion.lowercased())"
    self.lldVersion = lldVersion
    self.linuxDistribution = linuxDistribution
    self.linuxArchSuffix =
      targetTriple.arch == .aarch64 ? "-\(Triple.Arch.aarch64.linuxConventionName)" : ""
    self.logger = logger
  }

  let swiftVersion: String
  let swiftBranch: String
  let lldVersion: String
  let linuxDistribution: LinuxDistribution
  let linuxArchSuffix: String
  private let logger: Logger

  var swiftPlatform: String {
    switch self.linuxDistribution {
    case let .ubuntu(ubuntu):
      return "ubuntu\(ubuntu.version)"
    case let .debian(debian):
      if debian.version == "11" {
        // Ubuntu 20.04 toolchain is binary compatible with Debian 11
        return "ubuntu20.04"
      } else if self.swiftVersion.hasPrefix("5.9") || self.swiftVersion == "5.10" {
        // Ubuntu 22.04 toolchain is binary compatible with Debian 12
        return "ubuntu22.04"
      } else if debian.version == "13" {
        // Ubuntu 24.04 toolchain is binary compatible with Debian 13
        return "ubuntu24.04"
      }
      return "debian\(debian.version)"
    case let .rhel(rhel):
      return rhel.rawValue
    }
  }

  var swiftPlatformAndSuffix: String {
    return "\(self.swiftPlatform)\(self.linuxArchSuffix)"
  }

  func swiftDistributionName(platform: String? = nil) -> String {
    return
      "swift-\(self.swiftVersion)-\(platform ?? self.swiftPlatformAndSuffix)"
  }

  func swiftDownloadURL(
    subdirectory: String? = nil,
    platform: String? = nil,
    fileExtension: String = "tar.gz"
  ) -> URL {
    let computedPlatform = platform ?? self.swiftPlatformAndSuffix
    let computedSubdirectory =
      subdirectory
      ?? computedPlatform.replacingOccurrences(of: ".", with: "")

    return URL(
      string: """
        https://download.swift.org/\(
          self.swiftBranch
        )/\(computedSubdirectory)/\
        swift-\(self.swiftVersion)/\(self.swiftDistributionName(platform: computedPlatform)).\(fileExtension)
        """
    )!
  }

  var swiftBareSemVer: String {
    self.swiftVersion.components(separatedBy: "-")[0]
  }

  /// Name of a Docker image containing the Swift toolchain and SDK for this Linux distribution.
  var swiftBaseDockerImage: String {
    if self.swiftVersion.hasSuffix("-RELEASE") {
      return "swift:\(self.swiftBareSemVer)-\(self.linuxDistribution.swiftDockerImageSuffix)"
    } else {
      fatalError()
    }
  }
}
