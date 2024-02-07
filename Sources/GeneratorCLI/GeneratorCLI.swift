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
import struct SystemPackage.FilePath
import FoundationInternationalization

@main
struct GeneratorCLI: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "swift-sdk-generator",
    subcommands: [MakeLinuxSDK.self, MakeWasmSDK.self],
    defaultSubcommand: MakeLinuxSDK.self
  )

  static func run<Recipe: SwiftSDKRecipe>(
    recipe: Recipe,
    hostTriple: Triple,
    targetTriple: Triple,
    options: GeneratorOptions
  ) async throws {
    let elapsed = try await ContinuousClock().measure {
      let logger = Logger(label: "org.swift.swift-sdk-generator")
      let generator = try await SwiftSDKGenerator(
        bundleVersion: options.bundleVersion,
        hostTriple: hostTriple,
        targetTriple: targetTriple,
        artifactID: options.sdkName ?? recipe.defaultArtifactID,
        isIncremental: options.incremental,
        isVerbose: options.verbose,
        logger: logger
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

    print("\nTime taken for this generator run: \(elapsed.formatted()).")
  }
}

extension Triple.Arch: ExpressibleByArgument {}
extension Triple: ExpressibleByArgument {
  public init?(argument: String) {
    self.init(argument, normalizing: true)
  }
}

extension GeneratorCLI {
  struct GeneratorOptions: ParsableArguments {
    @Option(help: "An arbitrary version number for informational purposes.")
    var bundleVersion = "0.0.1"

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

    @Option(
      help: """
      Path to the Swift toolchain package containing the Swift compiler that runs on the host platform.
      """
    )
    var hostSwiftPackagePath: String? = nil

    @Option(
      help: """
      Path to the Swift toolchain package containing the Swift standard library that runs on the target platform.
      """
    )
    var targetSwiftPackagePath: String? = nil

    @Option(
      help: """
      The host triple of the bundle. Defaults to a triple of the machine this generator is \
      running on if unspecified.
      """
    )
    var host: Triple? = nil

    @Option(
      help: """
      The target triple of the bundle. The default depends on a recipe used for SDK generation. Pass `--help` to a specific recipe subcommand for more details.
      """
    )
    var target: Triple? = nil

    @Option(help: "Deprecated. Use `--host` instead")
    var hostArch: Triple.Arch? = nil
    @Option(help: "Deprecated. Use `--target` instead")
    var targetArch: Triple.Arch? = nil

    func deriveHostTriple() throws -> Triple {
      if let host {
        return host
      }
      let current = try SwiftSDKGenerator.getCurrentTriple(isVerbose: verbose)
      if let arch = hostArch {
        let target = Triple(arch: arch, vendor: current.vendor!, os: current.os!)
        print("deprecated: Please use `--host \(target.triple)` instead of `--host-arch \(arch)`")
        return target
      }
      return current
    }
  }

  struct MakeLinuxSDK: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "make-linux-sdk",
      abstract: "Generate a Swift SDK bundle for Linux.",
      discussion: """
      The default `--target` triple is Linux with the same CPU architecture with host triple
      """
    )

    @OptionGroup
    var generatorOptions: GeneratorOptions

    @Flag(help: "Delegate to Docker for copying files for the target triple.")
    var withDocker: Bool = false

    @Option(help: "Container image from which to copy the target triple.")
    var fromContainerImage: String? = nil

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

    func deriveTargetTriple(hostTriple: Triple) -> Triple {
      if let target = generatorOptions.target {
        return target
      }
      if let arch = generatorOptions.targetArch {
        let target = Triple(arch: arch, vendor: nil, os: .linux, environment: .gnu)
        print("deprecated: Please use `--target \(target.triple)` instead of `--target-arch \(arch)`")
      }
      return Triple(arch: hostTriple.arch!, vendor: nil, os: .linux, environment: .gnu)
    }

    func run() async throws {
      if isInvokedAsDefaultSubcommand() {
        print("deprecated: Please explicity specify the subcommand to run. For example: $ swift-sdk-generator make-linux-sdk")
      }
      let linuxDistributionDefaultVersion = switch self.linuxDistributionName {
      case .rhel:
        "ubi9"
      case .ubuntu:
        "22.04"
      }
      let linuxDistributionVersion = self.linuxDistributionVersion ?? linuxDistributionDefaultVersion
      let linuxDistribution = try LinuxDistribution(name: linuxDistributionName, version: linuxDistributionVersion)
      let hostTriple = try self.generatorOptions.deriveHostTriple()
      let targetTriple = self.deriveTargetTriple(hostTriple: hostTriple)

      let recipe = try LinuxRecipe(
        targetTriple: targetTriple,
        linuxDistribution: linuxDistribution,
        swiftVersion: generatorOptions.swiftVersion,
        swiftBranch: generatorOptions.swiftBranch,
        lldVersion: lldVersion,
        withDocker: withDocker,
        fromContainerImage: fromContainerImage,
        hostSwiftPackagePath: generatorOptions.hostSwiftPackagePath,
        targetSwiftPackagePath: generatorOptions.targetSwiftPackagePath
      )
      try await GeneratorCLI.run(recipe: recipe, hostTriple: hostTriple, targetTriple: targetTriple, options: generatorOptions)
    }

    func isInvokedAsDefaultSubcommand() -> Bool {
      let arguments = CommandLine.arguments
      guard arguments.count >= 2 else {
        // No subcommand nor option: $ swift-sdk-generator
        return true
      }
      let maybeSubcommand = arguments[1]
      guard maybeSubcommand == Self.configuration.commandName else {
        // No subcommand but with option: $ swift-sdk-generator --with-docker
        return true
      }
      return false
    }
  }

  struct MakeWasmSDK: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "make-wasm-sdk",
      abstract: "Experimental: Generate a Swift SDK bundle for WebAssembly.",
      discussion: """
      The default `--target` triple is wasm32-unknown-wasi
      """
    )

    @OptionGroup
    var generatorOptions: GeneratorOptions

    @Option(
      help: """
      Path to the WASI sysroot directory containing the WASI libc headers and libraries.
      """
    )
    var wasiSysroot: String

    func deriveTargetTriple(hostTriple: Triple) -> Triple {
      self.generatorOptions.target ?? Triple("wasm32-unknown-wasi")
    }

    func run() async throws {
      guard let targetSwiftPackagePath = generatorOptions.targetSwiftPackagePath else {
        throw StringError("Missing expected argument '--target-swift-package-path'")
      }
      let recipe = WebAssemblyRecipe(
        hostSwiftPackagePath: generatorOptions.hostSwiftPackagePath.map { FilePath($0) },
        targetSwiftPackagePath: FilePath(targetSwiftPackagePath),
        wasiSysroot: FilePath(wasiSysroot),
        swiftVersion: generatorOptions.swiftVersion
      )
      let hostTriple = try self.generatorOptions.deriveHostTriple()
      let targetTriple = self.deriveTargetTriple(hostTriple: hostTriple)
      try await GeneratorCLI.run(recipe: recipe, hostTriple: hostTriple, targetTriple: targetTriple, options: generatorOptions)
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

struct StringError: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) {
    self.description = description
  }
}
