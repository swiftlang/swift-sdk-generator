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

  @Option(help: "Version of Swift to supply in the bundle.")
  var swiftVersion = "5.7.3-RELEASE"

  @Option(help: "Version of LLVM to supply in the bundle.")
  var llvmVersion = "16.0.0"

  @Option(help: "Version of Ubuntu to use when assembling the bundle.")
  var ubuntuVersion = "22.04"

  mutating func run() async throws {
    let elapsed = try await ContinuousClock().measure {
      let artifactID = "\(swiftVersion)_ubuntu_\(ubuntuVersion)_\(Triple.availableTriples.linux.cpu)"

      try await LocalDestinationsGenerator(
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
