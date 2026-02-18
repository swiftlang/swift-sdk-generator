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
import Foundation
import Logging
import SwiftSDKGenerator

import struct SystemPackage.FilePath

@main
struct GeneratorCLI: AsyncParsableCommand {
  static let appLogger = Logger(label: "org.swift.swift-sdk-generator")

  static let configuration = CommandConfiguration(
    commandName: "swift-sdk-generator",
    subcommands: [MakeLinuxSDK.self, MakeFreeBSDSDK.self, MakeWasmSDK.self],
    defaultSubcommand: MakeLinuxSDK.self
  )

  static func loggerWithLevel(from options: GeneratorOptions) -> Logger {
    var logger = self.appLogger
    if options.verbose {
      logger.logLevel = .debug
    }
    return logger
  }

  static func run(
    recipe: some SwiftSDKRecipe,
    targetTriples: [Triple],
    options: GeneratorOptions
  ) async throws {
    let logger = loggerWithLevel(from: options)
    let elapsed = try await ContinuousClock().measure {
      let generator = try await SwiftSDKGenerator(
        bundleVersion: options.bundleVersion,
        targetTriples: targetTriples,
        artifactID: options.sdkName ?? recipe.defaultArtifactID,
        isIncremental: options.incremental,
        isVerbose: options.verbose,
        logger: logger
      )

      let generatorTask = Task {
        try await generator.run(recipe: recipe)
      }

      #if canImport(Darwin)
        // On Darwin platforms Dispatch's signal source uses kqueue and EVFILT_SIGNAL for
        // delivering signals. This exists alongside but with lower precedence than signal and
        // sigaction: ignore signal handling here to kqueue can deliver signals.
        signal(SIGINT, SIG_IGN)
      #endif
      let signalSource = DispatchSource.makeSignalSource(signal: SIGINT)
      signalSource.setEventHandler {
        generatorTask.cancel()
      }
      signalSource.resume()
      try await generatorTask.value
    }

    logger.info(
      "Generator run finished successfully.",
      metadata: ["elapsedTime": .string(elapsed.intervalString)]
    )
  }
}

extension Triple.Arch: ArgumentParser.ExpressibleByArgument {}
extension Triple: ArgumentParser.ExpressibleByArgument {
  public init?(argument: String) {
    self.init(argument, normalizing: false)
  }
}

extension GeneratorCLI {
  struct GeneratorOptions: ParsableArguments {
    @Option(help: "An arbitrary version number for informational purposes.")
    var bundleVersion = "0.0.1"

    @Option(
      help: """
        Name of the Swift SDK bundle. Defaults to a string composed of Swift version, target OS release/version \
        and target CPU architecture.
        """
    )
    var sdkName: String? = nil

    @Flag(
      help:
        "Experimental: avoid cleaning up toolchain and SDK directories and regenerate the Swift SDK bundle incrementally."
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
    var swiftVersion = "6.2.1-RELEASE"

    @Option(
      help: """
        Path to the Swift toolchain package containing the Swift compiler that runs on the host platform.
        """
    )
    var hostSwiftPackagePath: String? = nil

    @Flag(
      inversion: .prefixedNo,
      help: """
        Whether or not to include the host toolchain in the Swift SDK.
        If the host toolchain is not included, this makes the Swift SDK compatible with any host, \
        but requires exactly the same version of the swift.org toolchain to be installed for it to work.
        """
    )
    var hostToolchain: Bool = hostToolchainDefault

    @Option(
      help: """
        Path to the Swift toolchain package containing the Swift standard library that runs on the target platform.
        """
    )
    var targetSwiftPackagePath: String? = nil

    @Option(
      name: .customLong("host"),
      help: """
        The host triples of the bundle. Defaults to a triple or triples of the machine this generator is \
        running on if unspecified. Multiple host triples are only supported for macOS hosts.
        """
    )
    var hosts: [Triple] = []

    @Option(
      help:
        """
        The target triple(s) of the bundle. Can be specified multiple times for multiple targets. \
        The default depends on a recipe used for SDK generation.
        """
    )
    var target: [Triple] = []

    @Option(help: "Deprecated. Use `--host` instead")
    var hostArch: Triple.Arch? = nil
    @Option(
      help: """
        The target arch of the bundle. The default depends on a recipe used for SDK generation. \
        If this is passed, the target triple will default to an appropriate value for the target \
        platform, with its arch component set to this value. \
        Use the `--target` param to pass the full target triple if needed.
        """
    )
    var targetArch: Triple.Arch? = nil

    /// Default to adding host toolchain when building on macOS
    static var hostToolchainDefault: Bool {
      #if os(macOS)
        true
      #else
        false
      #endif
    }

    func deriveHostTriples() throws -> [Triple] {
      if !hosts.isEmpty {
        return hosts
      }
      let current = try SwiftSDKGenerator.getCurrentTriple(isVerbose: self.verbose)
      if let arch = hostArch {
        let target = Triple(arch: arch, vendor: current.vendor!, os: current.os!)
        appLogger.warning(
          "deprecated: Please use `--host \(target.triple)` instead of `--host-arch \(arch)`"
        )
        return [target]
      }
      // macOS toolchains are built as universal binaries
      if current.isMacOSX {
        return [
          Triple("arm64-apple-macos"),
          Triple("x86_64-apple-macos"),
        ]
      }
      return [current]
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
        Linux distribution to use if the target platform is Linux.
        - Available options: `ubuntu`, `debian`, `rhel`. Default is `ubuntu`.
        """,
      transform: LinuxDistribution.Name.init(nameString:)
    )
    var distributionName = LinuxDistribution.Name.ubuntu

    @Option(
      help: """
        Version of the Linux distribution used as a target platform.
        - Available options for Ubuntu: `20.04`, `22.04` (default when `--distribution-name` is `ubuntu`), `24.04`.
        - Available options for Debian: `11`, `12` (default when `--distribution-name` is `debian`).
        - Available options for RHEL: `ubi9` (default when `--distribution-name` is `rhel`).
        """
    )
    var distributionVersion: String?

    func deriveTargetTriples(hostTriples: [Triple]) -> [Triple] {
      if !generatorOptions.target.isEmpty {
        return generatorOptions.target
      }
      if let arch = generatorOptions.targetArch {
        let target = Triple(arch: arch, vendor: nil, os: .linux, environment: .gnu)
        appLogger.warning(
          "Using `--target-arch \(arch)` defaults to `\(target.triple)`. Use `--target` if you want to pass the full target triple."
        )
        return [target]
      }
      let arch: Triple.Arch
      if hostTriples.count == 1, let hostTriple = hostTriples.first {
        arch = hostTriple.arch!
      } else {
        arch = try! SwiftSDKGenerator.getCurrentTriple(isVerbose: false).arch!
      }
      return [Triple(arch: arch, vendor: nil, os: .linux, environment: .gnu)]
    }

    func run() async throws {
      if self.isInvokedAsDefaultSubcommand() {
        appLogger.warning(
          "deprecated: Please explicitly specify the subcommand to run. For example: $ swift-sdk-generator make-linux-sdk"
        )
      }
      let distributionDefaultVersion: String
      switch self.distributionName {
      case .rhel:
        distributionDefaultVersion = "ubi9"
      case .ubuntu:
        distributionDefaultVersion = "22.04"
      case .debian:
        distributionDefaultVersion = "12"
      }
      let distributionVersion =
        self.distributionVersion ?? distributionDefaultVersion
      let linuxDistribution = try LinuxDistribution(
        name: distributionName,
        version: distributionVersion
      )
      let hostTriples = try self.generatorOptions.deriveHostTriples()
      let targetTriples = self.deriveTargetTriples(hostTriples: hostTriples)

      let recipe = try LinuxRecipe(
        targetTriple: targetTriples[0],
        hostTriples: hostTriples,
        linuxDistribution: linuxDistribution,
        swiftVersion: generatorOptions.swiftVersion,
        swiftBranch: self.generatorOptions.swiftBranch,
        lldVersion: self.lldVersion,
        withDocker: self.withDocker,
        fromContainerImage: self.fromContainerImage,
        hostSwiftPackagePath: self.generatorOptions.hostSwiftPackagePath,
        targetSwiftPackagePath: self.generatorOptions.targetSwiftPackagePath,
        includeHostToolchain: self.generatorOptions.hostToolchain,
        logger: loggerWithLevel(from: self.generatorOptions)
      )
      try await GeneratorCLI.run(
        recipe: recipe,
        targetTriples: targetTriples,
        options: self.generatorOptions
      )
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

  struct MakeFreeBSDSDK: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "make-freebsd-sdk",
      abstract: "Generate a Swift SDK bundle for FreeBSD.",
      discussion: """
        The default `--target` triple is FreeBSD with the same CPU architecture with host triple
        """
    )

    @OptionGroup
    var generatorOptions: GeneratorOptions

    @Option(
      name: .customLong("freebsd-version"),
      help: """
        Version of FreeBSD to use as a target platform. Example: 14.3
        """
    )
    var freeBSDVersion: String

    func deriveTargetTriples(hostTriples: [Triple], freeBSDVersion: String) throws -> [Triple] {
      if !generatorOptions.target.isEmpty {
        return generatorOptions.target
      }
      if let arch = generatorOptions.targetArch {
        let target = Triple(arch: arch, vendor: nil, os: .freeBSD, version: freeBSDVersion)
        appLogger.warning(
          """
            Using `--target-arch \(arch)` defaults to `\(target.triple)`. \
            Use `--target` if you want to pass the full target triple.
          """
        )
        return [target]
      }
      let arch: Triple.Arch
      if hostTriples.count == 1, let hostTriple = hostTriples.first {
        arch = hostTriple.arch!
      } else {
        arch = try! SwiftSDKGenerator.getCurrentTriple(isVerbose: false).arch!
      }
      return [Triple(arch: arch, vendor: nil, os: .freeBSD)]
    }

    func run() async throws {
      let freebsdVersion = try FreeBSD(self.freeBSDVersion)
      guard freebsdVersion.isSupportedVersion() else {
        throw StringError("Only FreeBSD versions 14.3 or higher are supported.")
      }

      let hostTriples = try self.generatorOptions.deriveHostTriples()
      let targetTriples = try self.deriveTargetTriples(hostTriples: hostTriples, freeBSDVersion: self.freeBSDVersion)

      if self.generatorOptions.hostSwiftPackagePath != nil {
        throw StringError("This tool does not support embedding host-specific toolchains into FreeBSD SDKs")
      }

      let sourceSwiftToolchain: FilePath?
      if let fromSwiftToolchain = self.generatorOptions.targetSwiftPackagePath {
        sourceSwiftToolchain = .init(fromSwiftToolchain)
      } else {
        sourceSwiftToolchain = nil
      }

      let recipe = FreeBSDRecipe(
        freeBSDVersion: freebsdVersion,
        mainTargetTriple: targetTriples[0],
        sourceSwiftToolchain: sourceSwiftToolchain,
        logger: loggerWithLevel(from: self.generatorOptions)
      )
      try await GeneratorCLI.run(
        recipe: recipe,
        targetTriples: targetTriples,
        options: self.generatorOptions
      )
    }
  }

  struct MakeWasmSDK: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "make-wasm-sdk",
      abstract: "Experimental: Generate a Swift SDK bundle for WebAssembly.",
      discussion: """
        The default `--target` triple is wasm32-unknown-wasip1. \
        Use `--target wasm32-unknown-wasip1 --target wasm32-unknown-wasip1-threads` to generate \
        a Swift SDK bundle supporting both threaded and non-threaded WebAssembly targets.
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

    func deriveTargetTriples() -> [Triple] {
      if !generatorOptions.target.isEmpty {
        return generatorOptions.target
      }
      // Default: single wasm triple
      return [Triple("wasm32-unknown-wasip1")]
    }

    func run() async throws {
      let targetTriples = self.deriveTargetTriples()
      let recipe = try WebAssemblyRecipe(
        hostSwiftPackage: generatorOptions.hostSwiftPackagePath.map {
          let hostTriples = try self.generatorOptions.deriveHostTriples()
          return WebAssemblyRecipe.HostToolchainPackage(path: FilePath($0), triples: hostTriples)
        },
        targetSwiftPackagePath: generatorOptions.targetSwiftPackagePath.map { FilePath($0) },
        wasiSysroot: FilePath(self.wasiSysroot),
        swiftVersion: self.generatorOptions.swiftVersion,
        targetTriples: targetTriples,
        logger: loggerWithLevel(from: self.generatorOptions)
      )
      try await GeneratorCLI.run(
        recipe: recipe,
        targetTriples: targetTriples,
        options: self.generatorOptions
      )
    }
  }
}

extension Duration {
  var intervalString: String {
    let reference = Date()
    let date = Date(timeInterval: TimeInterval(self.components.seconds), since: reference)

    let components = Calendar.current.dateComponents(
      [.hour, .minute, .second],
      from: reference,
      to: date
    )

    if let hours = components.hour, hours > 0 {
      #if !canImport(Darwin) && compiler(<6.0)
        return String(
          format: "%02d:%02d:%02d",
          hours,
          components.minute ?? 0,
          components.second ?? 0
        )
      #else
        return self.formatted()
      #endif
    } else if let minutes = components.minute, minutes > 0 {
      #if !canImport(Darwin) && compiler(<6.0)
        let seconds = components.second ?? 0
        return
          "\(minutes) minute\(minutes != 1 ? "s" : "") \(seconds) second\(seconds != 1 ? "s" : "")"
      #else
        return "\(self.formatted(.time(pattern: .minuteSecond))) seconds"
      #endif
    } else {
      return "\(components.second ?? 0) seconds"
    }
  }
}

struct StringError: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) {
    self.description = description
  }
}
