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
  @Flag(help: "Delegate to Docker for copying files for the target triple.")
  var withDocker: Bool = false

  @Flag(
    help: "Avoid cleaning up toolchain and SDK directories and regenerate the SDK bundle incrementally."
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
  var swiftVersion = "5.8-RELEASE"

  @Option(help: "Version of LLD linker to supply in the bundle.")
  var lldVersion = "16.0.5"

  @Option(help: "Linux distribution to use if the target platform is Linux. Available options: `ubuntu`, `ubi`.")
  var linuxDistribution = "ubuntu"

  @Option(help: "Version of the Linux distribution used as a target platform.")
  var linuxDistributionVersion = "22.04"

  @Option(
    help: """
    CPU architecture of the host triple of the bundle. Defaults to a triple of the machine this generator is \
    running on if unspecified. Available options: \(
      Triple.CPU.allCases.map { "`\($0.rawValue)`" }.joined(separator: ", ")
    ).
    """
  )
  var hostCPUArchitecture: Triple.CPU? = nil

  @Option(
    help: """
    CPU architecture of the target triple of the bundle. Same as the host triple CPU architecture if unspecified. \
    Available options: \(Triple.CPU.allCases.map { "`\($0.rawValue)`" }.joined(separator: ", ")).
    """
  )
  var targetCPUArchitecture: Triple.CPU? = nil

  mutating func run() async throws {
    let linuxDistrubution = try LinuxDistribution(name: linuxDistribution, version: linuxDistributionVersion)

    let elapsed = try await ContinuousClock().measure {
      try await LocalSwiftSDKGenerator(
        hostCPUArchitecture: hostCPUArchitecture,
        targetCPUArchitecture: targetCPUArchitecture,
        swiftVersion: swiftVersion,
        swiftBranch: swiftBranch,
        lldVersion: lldVersion,
        linuxDistribution: linuxDistrubution,
        shouldUseDocker: withDocker,
        isVerbose: verbose
      )
      .generateBundle(shouldGenerateFromScratch: !incremental)
    }

    print("\nTime taken for this generator run: \(elapsed.intervalString)")
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

    return if let hours = components.hour, hours > 0 {
      "\(hours):\(components.minute ?? 0):\(components.second ?? 0)"
    } else if let minutes = components.minute, minutes > 0 {
      "\(minutes):\(components.second ?? 0)"
    } else {
      "\(components.second ?? 0) seconds"
    }
  }
}
