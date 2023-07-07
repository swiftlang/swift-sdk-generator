//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2022-2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

private let ubuntuReleases = [
  "22.04": "jammy",
]

public struct VersionsConfiguration: Sendable {
  init(
    swiftVersion: String,
    swiftBranch: String? = nil,
    lldVersion: String,
    ubuntuVersion: String,
    targetTriple: Triple
  ) throws {
    guard let ubuntuRelease = ubuntuReleases[ubuntuVersion]
    else { throw GeneratorError.unknownUbuntuVersion(ubuntuVersion) }

    self.swiftVersion = swiftVersion
    self.swiftBranch = swiftBranch ?? "swift-\(swiftVersion.lowercased())"
    self.lldVersion = lldVersion
    self.ubuntuVersion = ubuntuVersion
    self.ubuntuRelease = ubuntuRelease
    self.ubuntuArchSuffix = targetTriple.cpu == .arm64 ? "-\(Triple.CPU.arm64.linuxConventionName)" : ""
  }

  let swiftVersion: String
  let swiftBranch: String
  let lldVersion: String
  let ubuntuVersion: String
  let ubuntuRelease: String
  let ubuntuArchSuffix: String
}
