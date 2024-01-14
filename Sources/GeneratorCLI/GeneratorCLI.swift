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

import ArgumentParser
import Logging
import ServiceLifecycle
import SwiftSDKGenerator

@main
struct GeneratorCLI: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "swift-sdk-generator")

  @Option(help: "An arbitrary version number for informational purposes.")
  var bundleVersion = "0.0.1"

  @Flag(help: "Delegate to Docker for copying files for the target triple.")
  var withDocker: Bool = false

  @Option(help: "Container image from which to copy the target triple.")
  var fromContainerImage: String? = nil

  @Option(
    help: """
    Name of the SDK bundle. Defaults to a string composed of Swift version, Linux distribution, Linux release \
    and target CPU architecture.
    """
  )
  var sdkName: String? = nil

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
  var swiftVersion = "5.9.2-RELEASE"

  @Option(help: "Version of LLD linker to supply in the bundle.")
  var lldVersion = "17.0.5"

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

  func run() async throws {
    let linuxDistributionDefaultVersion = switch self.linuxDistributionName {
    case .rhel:
      "ubi9"
    case .ubuntu:
      "22.04"
    }
    let linuxDistributionVersion = self.linuxDistributionVersion ?? linuxDistributionDefaultVersion
    let linuxDistribution = try LinuxDistribution(name: linuxDistributionName, version: linuxDistributionVersion)

    let elapsed = try await ContinuousClock().measure {
      let logger = Logger(label: "org.swift.swift-sdk-generator")
      let generator = try await SwiftSDKGenerator(
        bundleVersion: self.bundleVersion,
        hostCPUArchitecture: self.hostArch,
        targetCPUArchitecture: self.targetArch,
        swiftVersion: self.swiftVersion,
        linuxDistribution: linuxDistribution,
        artifactID: self.sdkName,
        isIncremental: self.incremental,
        isVerbose: self.verbose,
        logger: logger
      )
      let recipe = try await LinuxRecipe(
        targetTriple: generator.targetTriple,
        linuxDistribution: linuxDistribution,
        swiftVersion: swiftVersion,
        swiftBranch: swiftBranch,
        lldVersion: lldVersion,
        withDocker: withDocker,
        fromContainerImage: fromContainerImage
      )

      let serviceGroup = ServiceGroup(
        configuration: .init(
          services: [.init(
            service: SwiftSDKGeneratorService(recipe: recipe, generator: generator),
            successTerminationBehavior: .gracefullyShutdownGroup
          )],
          cancellationSignals: [.sigint],
          logger: logger
        )
      )

      try await serviceGroup.run()
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

struct SwiftSDKGeneratorService: Service {
    let recipe: SwiftSDKRecipe
    let generator: SwiftSDKGenerator

    func run() async throws {
        try await generator.run(recipe: recipe)
    }
}
