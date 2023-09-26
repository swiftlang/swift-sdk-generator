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

import ArgumentParser
import SwiftSDKGenerator

@main
struct GeneratorCLI: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "swift-sdk-generator")

  @Flag(help: "Delegate to Docker for copying files for the target triple.")
  var withDocker: Bool = false

  @Flag(
    help: "Experimental: avoid cleaning up toolchain and SDK directories and regenerate the SDK bundle incrementally."
  )
  var incremental: Bool = false

  @Flag(name: .shortAndLong, help: "Provide verbose logging output.")
  var verbose = false

  @Option(
    help: """
    Branch of Swift to use when downloading nightly snapshots. Specify `development` for snapshots off the `main` \
    branch of Swift open source project repositories.
    """
  )
  var swiftBranch: String? = nil

  @Option(help: "Version of Swift to supply in the bundle.")
  var swiftVersion = "5.9-RELEASE"

  @Option(help: "Version of LLD linker to supply in the bundle.")
  var lldVersion = "16.0.5"

  @Option(
    help: """
    Linux distribution to use if the target platform is Linux. Available options: `ubuntu`, `rhel`. Default is `ubuntu`.
    """,
    transform: LinuxDistribution.Name.init(nameString:)
  )
  var linuxDistributionName = LinuxDistribution.Name.ubuntu

  @Option(
    help: """
    Version of the Linux distribution used as a target platform. Available options for Ubuntu: `20.04`, \
    `22.04` (default when `--linux-distribution-name` is `ubuntu`). Available options for RHEL: `ubi9` (default when \
    `--linux-distribution-name` is `rhel`).
    """
  )
  var linuxDistributionVersion: String?

  @Option(
    help: """
    CPU architecture of the host triple of the bundle. Defaults to a triple of the machine this generator is \
    running on if unspecified. Available options: \(
      Triple.CPU.allCases.map { "`\($0.rawValue)`" }.joined(separator: ", ")
    ).
    """
  )
  var hostArch: Triple.CPU? = nil

  @Option(
    help: """
    CPU architecture of the target triple of the bundle. Same as the host triple CPU architecture if unspecified. \
    Available options: \(Triple.CPU.allCases.map { "`\($0.rawValue)`" }.joined(separator: ", ")).
    """
  )
  var targetArch: Triple.CPU? = nil

  mutating func run() async throws {
    let linuxDistributionVersion = switch self.linuxDistributionName {
    case .rhel:
      "ubi9"
    case .ubuntu:
      "22.04"
    }
    let linuxDistribution = try LinuxDistribution(name: linuxDistributionName, version: linuxDistributionVersion)

    let elapsed = try await ContinuousClock().measure {
      try await LocalSwiftSDKGenerator(
        hostCPUArchitecture: self.hostArch,
        targetCPUArchitecture: self.targetArch,
        swiftVersion: self.swiftVersion,
        swiftBranch: self.swiftBranch,
        lldVersion: self.lldVersion,
        linuxDistribution: linuxDistribution,
        shouldUseDocker: self.withDocker,
        isVerbose: self.verbose
      )
      .generateBundle(shouldGenerateFromScratch: !self.incremental)
    }

    print("\nTime taken for this generator run: \(elapsed.intervalString).")
  }
}

extension Triple.CPU: ExpressibleByArgument {}

// FIXME: replace this with a call on `.formatted()` on `Duration` when it's available in swift-foundation.
import Foundation

extension Duration {
  var intervalString: String {
    let reference = Date()
    let date = Date(timeInterval: TimeInterval(self.components.seconds), since: reference)

    let components = Calendar.current.dateComponents([.hour, .minute, .second], from: reference, to: date)

    if let hours = components.hour, hours > 0 {
      return String(format: "%02d:%02d:%02d", hours, components.minute ?? 0, components.second ?? 0)
    } else if let minutes = components.minute, minutes > 0 {
      let seconds = components.second ?? 0
      return "\(minutes) minute\(minutes != 1 ? "s" : "") \(seconds) second\(seconds != 1 ? "s" : "")"
    } else {
      return "\(components.second ?? 0) seconds"
    }
  }
}
