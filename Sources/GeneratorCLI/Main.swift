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
import DestinationsGenerator

private let defaultSwiftVersion = "5.7.3-RELEASE"
private let defaultLLVMVersion = "16.0.0"
private let defaultUbuntuVersion = "22.04"

@main
struct Main: AsyncParsableCommand {
  @Flag(help: "Avoid delegating to Docker for copying files for the run-time triple.")
  var withoutDocker: Bool = false

  @Flag(
    help: "Avoid cleaning up toolchain and SDK directories and regenerate the SDK bundle incrementally."
  )
  var incremental: Bool = false

  @Flag(
    help: "Use latest nightly snapshot of Swift."
  )
  var nightlySwift = false

  @Option(help: "Version of Swift to supply in the bundle. Default is `\(defaultSwiftVersion)`.")
  var swiftVersion = defaultSwiftVersion

  @Option(help: "Version of LLVM to supply in the bundle. Default is `\(defaultLLVMVersion)`.")
  var llvmVersion = defaultLLVMVersion

  @Option(help: "Version of Ubuntu to use when assembling the bundle. Default is `\(defaultUbuntuVersion)`.")
  var ubuntuVersion = defaultUbuntuVersion

  mutating func run() async throws {
    let elapsed = try await ContinuousClock().measure {
      let artifactID = "\(swiftVersion)_ubuntu_\(ubuntuVersion)_\(Triple.availableTriples.linux.cpu)"

      try await LocalGeneratorOperations(
        artifactID: artifactID,
        swiftVersion: swiftVersion,
        llvmVersion: llvmVersion,
        ubuntuVersion: ubuntuVersion
      )
      .generateDestinationBundle(
        shouldUseDocker: !withoutDocker,
        shouldGenerateFromScratch: !incremental,
        shouldUseNightlySwift: nightlySwift
      )
    }

    print("\nTime taken for this generator run: \(elapsed.formatted())")
  }
}
