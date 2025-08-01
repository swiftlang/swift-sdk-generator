//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
import Logging
import SystemPackage
import XCTest

@testable import SwiftSDKGenerator

extension FileManager {
  func withTemporaryDirectory<T>(
    logger: Logger,
    cleanup: Bool = true,
    body: (URL) async throws -> T
  ) async throws -> T {
    // Create a temporary directory using a UUID.  Throws if the directory already exists.
    // The docs suggest using FileManager.url(for: .itemReplacementDirectory, ...) to create a temporary directory,
    // but on Linux the directory name contains spaces, which means we need to be careful to quote it everywhere:
    //
    //     `(A Document Being Saved By \(name))`
    //
    // https://github.com/swiftlang/swift-corelibs-foundation/blob/21b3196b33a64d53a0989881fc9a486227b4a316/Sources/Foundation/FileManager.swift#L152
    var logger = logger

    let temporaryDirectory = self.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    logger[metadataKey: "temporaryDirectory"] = "\(temporaryDirectory.path)"

    try createDirectory(at: temporaryDirectory, withIntermediateDirectories: false)
    defer {
      // Best effort cleanup.
      if cleanup {
        try? removeItem(at: temporaryDirectory)
        logger.info("Removed temporary directory")
      } else {
        logger.info("Keeping temporary directory")
      }
    }

    logger.info("Created temporary directory")
    return try await body(temporaryDirectory)
  }
}

// Building an SDK requires running the sdk-generator with `swift run swift-sdk-generator`.
// This takes a lock on `.build`, but if the tests are being run by `swift test` the outer Swift Package Manager
// instance will already hold this lock, causing the test to deadlock.   We can work around this by giving
// the `swift run swift-sdk-generator` instance its own scratch directory.
func buildSDK(_ logger: Logger, scratchPath: String, withArguments runArguments: String)
  async throws -> String
{
  var logger = logger
  logger[metadataKey: "runArguments"] = "\"\(runArguments)\""
  logger[metadataKey: "scratchPath"] = "\(scratchPath)"

  logger.info("Building Swift SDK")

  var packageDirectory = FilePath(#filePath)
  packageDirectory.removeLastComponent()
  packageDirectory.removeLastComponent()

  let generatorOutput = try await Shell.readStdout(
    "cd \(packageDirectory) && swift run --scratch-path \"\(scratchPath)\" swift-sdk-generator make-linux-sdk \(runArguments)"
  )
  logger.info("Finished building Swift SDK")

  let installCommand = try XCTUnwrap(
    generatorOutput.split(separator: "\n").first {
      $0.contains("swift experimental-sdk install")
    }
  )

  let bundleName = try XCTUnwrap(
    FilePath(String(XCTUnwrap(installCommand.split(separator: " ").last))).components.last
  ).stem
  logger[metadataKey: "bundleName"] = "\(bundleName)"

  logger.info("Checking installed Swift SDKs")
  let installedSDKs = try await Shell.readStdout("swift experimental-sdk list").components(
    separatedBy: "\n"
  )

  // Make sure this bundle hasn't been installed already.
  if installedSDKs.contains(bundleName) {
    logger.info("Removing existing Swift SDK")
    try await Shell.run("swift experimental-sdk remove \(bundleName)")
  }

  logger.info("Installing new Swift SDK")
  let installOutput = try await Shell.readStdout(String(installCommand))
  XCTAssertTrue(installOutput.contains("successfully installed"))

  return bundleName
}

private let testcases = [
  #"""
    // Default program generated by swift package init
    print("Hello, world!")
  """#,
  #"""
    // Check that libc_nonshared.a is linked properly
    import Foundation

    func fin() -> Void {
      print("exiting")
    }

    atexit(fin)
  """#,
]

final class RepeatedBuildTests: XCTestCase {
  private let logger = Logger(label: "swift-sdk-generator")

  func testRepeatedSDKBuilds() async throws {
    if ProcessInfo.processInfo.environment.keys.contains("JENKINS_URL")
      || ProcessInfo.processInfo.environment.keys.contains("GITHUB_ACTIONS")
    {
      throw XCTSkip(
        "EndToEnd tests cannot currently run in CI: https://github.com/swiftlang/swift-sdk-generator/issues/145"
      )
    }

    var logger = logger
    logger[metadataKey: "testcase"] = "testRepeatedSDKBuilds"

    // Test that an existing SDK can be rebuilt without cleaning up.
    // Test with no arguments by default:
    var possibleArguments = ["--host-toolchain"]
    do {
      try await Shell.run("docker ps")
      possibleArguments.append(
        "--with-docker --distribution-name rhel --distribution-version ubi9"
      )
    } catch {
      self.logger.warning(
        "Docker CLI does not seem to be working, skipping tests that involve Docker."
      )
    }

    for runArguments in possibleArguments {
      if runArguments.contains("rhel") {
        // Temporarily skip the RHEL-based SDK.  XCTSkip() is not suitable as it would skipping the entire test case
        logger.warning(
          "RHEL-based SDKs currently do not work with Swift 6.0: https://github.com/swiftlang/swift-sdk-generator/issues/138"
        )
        continue
      }

      try await FileManager.default.withTemporaryDirectory(logger: logger) { tempDir in
        let _ = try await buildSDK(logger, scratchPath: tempDir.path, withArguments: runArguments)
        let _ = try await buildSDK(logger, scratchPath: tempDir.path, withArguments: runArguments)
      }
    }
  }
}

// SDKConfiguration represents an SDK build configuration and can construct the corresponding SDK generator arguments
struct SDKConfiguration {
  var swiftVersion: String
  var linuxDistributionName: String
  var linuxDistributionVersion: String
  var architecture: String
  var withDocker: Bool
  var containerImageSuffix: String?

  var bundleName: String {
    let sdkPrefix = containerImageSuffix ?? "\(linuxDistributionName)_\(linuxDistributionVersion)"
    return "\(sdkPrefix)_\(architecture)_\(swiftVersion)-RELEASE\(withDocker ? "_with-docker" : "")"
  }

  func withDocker(_ enabled: Bool = true) -> SDKConfiguration {
    var res = self
    res.withDocker = enabled
    return res
  }

  func withContainerImageSuffix(_ containerImageSuffix: String) -> SDKConfiguration {
    var res = self
    res.containerImageSuffix = containerImageSuffix
    return res
  }

  func withLinuxDistributionVersion(_ version: String) -> SDKConfiguration {
    var res = self
    res.linuxDistributionVersion = version
    return res
  }

  func withArchitecture(_ arch: String) -> SDKConfiguration {
    var res = self
    res.architecture = arch
    return res
  }

  var hostArch: String? {
    let triple = try? SwiftSDKGenerator.getCurrentTriple(isVerbose: false)
    return triple?.arch?.rawValue
  }

  var sdkGeneratorArguments: String {
    // Build the container image tag
    var containerImage: String? = nil
    if let containerImageSuffix {
      containerImage = "swift:\(swiftVersion)-\(containerImageSuffix)"
    }

    return [
      "--sdk-name \(bundleName)",
      "--host-toolchain",
      withDocker ? "--with-docker" : nil,
      containerImage != nil ? "--from-container-image" : nil, containerImage,
      "--swift-version \(swiftVersion)-RELEASE",
      testLinuxSwiftSDKs ? "--host \(hostArch!)-unknown-linux-gnu" : nil,
      "--target \(architecture)-unknown-linux-gnu",
      "--distribution-name \(linuxDistributionName)",
      "--distribution-version \(linuxDistributionVersion)",
    ].compactMap { $0 }.joined(separator: " ")
  }
}

// Skip slow tests unless an environment variable is set
func skipSlow() throws {
  try XCTSkipUnless(
    ProcessInfo.processInfo.environment.keys.contains("SWIFT_SDK_GENERATOR_RUN_SLOW_TESTS"),
    "Skipping slow test because SWIFT_SDK_GENERATOR_RUN_SLOW_TESTS is not set"
  )
}

var testLinuxSwiftSDKs: Bool {
  ProcessInfo.processInfo.environment.keys.contains("SWIFT_SDK_GENERATOR_TEST_LINUX_SWIFT_SDKS")
}

func buildTestcase(_ logger: Logger, testcase: String, bundleName: String, tempDir: URL)
  async throws
{
  let testPackageURL = tempDir.appendingPathComponent("swift-sdk-generator-test")
  let testPackageDir = FilePath(testPackageURL.path)
  try FileManager.default.createDirectory(
    atPath: testPackageDir.string,
    withIntermediateDirectories: true
  )

  logger.info("Creating test project \(testPackageDir)")
  try await Shell.run("swift package --package-path \(testPackageDir) init --type executable")
  let main_swift = testPackageURL.appendingPathComponent("Sources/main.swift")
  try testcase.write(to: main_swift, atomically: true, encoding: .utf8)

  // This is a workaround for if Swift 6.0 is used as the host toolchain to run the generator.
  // We manually set the swift-tools-version to 5.9 to support building our test cases.
  logger.info("Updating minimum swift-tools-version in test project...")
  let package_swift = testPackageURL.appendingPathComponent("Package.swift")
  let text = try String(contentsOf: package_swift, encoding: .utf8)
  var lines = text.components(separatedBy: .newlines)
  if lines.count > 0 {
    lines[0] = "// swift-tools-version: 5.9"
    let result = lines.joined(separator: "\r\n")
    try result.write(to: package_swift, atomically: true, encoding: .utf8)
  }

  var buildOutput = ""

  // If we are testing Linux Swift SDKs, we will run the test cases on a matrix of Docker containers
  // that contains each Swift-supported Linux distribution. This way we can validate that each
  // distribution is capable of building using the Linux Swift SDK.
  if testLinuxSwiftSDKs {
    let swiftContainerVersions = [
      "focal", "jammy", "noble", "fedora39", "rhel-ubi9", "amazonlinux2", "bookworm",
    ]
    for containerVersion in swiftContainerVersions {
      logger.info("Building test project in 6.0-\(containerVersion) container")
      buildOutput = try await Shell.readStdout(
        """
        docker run --rm -v \(testPackageDir):/src \
          -v $HOME/.swiftpm/swift-sdks:/root/.swiftpm/swift-sdks \
          --workdir /src swift:6.0-\(containerVersion) \
          /bin/bash -c "swift build --scratch-path /root/.build --experimental-swift-sdk \(bundleName)"
        """
      )
      XCTAssertTrue(buildOutput.contains("Build complete!"))
      logger.info("Test project built successfully")

      logger.info(
        "Building test project in 6.0-\(containerVersion) container with static-swift-stdlib"
      )
      buildOutput = try await Shell.readStdout(
        """
        docker run --rm -v \(testPackageDir):/src \
          -v $HOME/.swiftpm/swift-sdks:/root/.swiftpm/swift-sdks \
          --workdir /src swift:6.0-\(containerVersion) \
          /bin/bash -c "swift build --scratch-path /root/.build --experimental-swift-sdk \(bundleName) --static-swift-stdlib"
        """
      )
      XCTAssertTrue(buildOutput.contains("Build complete!"))
      logger.info("Test project built successfully")
    }
  } else {
    logger.info("Building test project")
    buildOutput = try await Shell.readStdout(
      "swift build --package-path \(testPackageDir) --experimental-swift-sdk \(bundleName)"
    )
    XCTAssertTrue(buildOutput.contains("Build complete!"))
    logger.info("Test project built successfully")

    try await Shell.run("rm -rf \(testPackageDir.appending(".build"))")

    logger.info("Building test project with static-swift-stdlib")
    buildOutput = try await Shell.readStdout(
      "swift build --package-path \(testPackageDir) --experimental-swift-sdk \(bundleName) --static-swift-stdlib"
    )
    XCTAssertTrue(buildOutput.contains("Build complete!"))
    logger.info("Test project built successfully")
  }
}

func buildTestcases(config: SDKConfiguration) async throws {
  var logger = Logger(label: "EndToEndTests")
  logger[metadataKey: "testcase"] = "testPackageInitExecutable"

  if ProcessInfo.processInfo.environment.keys.contains("JENKINS_URL")
    || ProcessInfo.processInfo.environment.keys.contains("GITHUB_ACTIONS")
  {
    throw XCTSkip(
      "EndToEnd tests cannot currently run in CI: https://github.com/swiftlang/swift-sdk-generator/issues/145"
    )
  }

  if config.withDocker {
    do {
      try await Shell.run("docker ps")
    } catch {
      throw XCTSkip("Container runtime is not available - skipping tests which require it")
    }
  }

  let bundleName = try await FileManager.default.withTemporaryDirectory(logger: logger) { tempDir in
    try await buildSDK(
      logger,
      scratchPath: tempDir.path,
      withArguments: config.sdkGeneratorArguments
    )
  }

  logger.info("Built Swift SDK")

  // Cleanup
  func cleanupSDK() async {
    logger.info("Removing Swift SDK to clean up...")
    try? await Shell.run("swift experimental-sdk remove \(bundleName)")
  }

  for testcase in testcases {
    do {
      try await FileManager.default.withTemporaryDirectory(logger: logger) { tempDir in
        try await buildTestcase(
          logger,
          testcase: testcase,
          bundleName: bundleName,
          tempDir: tempDir
        )
      }
    } catch {
      await cleanupSDK()
      throw error
    }
  }

  await cleanupSDK()
}

final class Swift59_UbuntuEndToEndTests: XCTestCase {
  let config = SDKConfiguration(
    swiftVersion: "5.9.2",
    linuxDistributionName: "ubuntu",
    linuxDistributionVersion: "22.04",
    architecture: "aarch64",
    withDocker: false
  )

  func testAarch64Direct() async throws {
    try skipSlow()
    try await buildTestcases(config: config.withArchitecture("aarch64"))
  }

  func testX86_64Direct() async throws {
    try skipSlow()
    try await buildTestcases(config: config.withArchitecture("x86_64"))
  }

  func testAarch64FromContainer() async throws {
    try skipSlow()
    try await buildTestcases(config: config.withArchitecture("aarch64").withDocker())
  }

  func testX86_64FromContainer() async throws {
    try skipSlow()
    try await buildTestcases(config: config.withArchitecture("x86_64").withDocker())
  }
}

final class Swift510_UbuntuEndToEndTests: XCTestCase {
  let config = SDKConfiguration(
    swiftVersion: "5.10.1",
    linuxDistributionName: "ubuntu",
    linuxDistributionVersion: "22.04",
    architecture: "aarch64",
    withDocker: false
  )

  func testAarch64Direct() async throws {
    try skipSlow()
    try await buildTestcases(config: config.withArchitecture("aarch64"))
  }

  func testX86_64Direct() async throws {
    try skipSlow()
    try await buildTestcases(config: config.withArchitecture("x86_64"))
  }

  func testAarch64FromContainer() async throws {
    try skipSlow()
    try await buildTestcases(config: config.withArchitecture("aarch64").withDocker())
  }

  func testX86_64FromContainer() async throws {
    try skipSlow()
    try await buildTestcases(config: config.withArchitecture("x86_64").withDocker())
  }
}

final class Swift60_UbuntuEndToEndTests: XCTestCase {
  let config = SDKConfiguration(
    swiftVersion: "6.0.3",
    linuxDistributionName: "ubuntu",
    linuxDistributionVersion: "24.04",
    architecture: "aarch64",
    withDocker: false
  )

  func testAarch64Direct() async throws {
    try skipSlow()
    try await buildTestcases(config: config.withArchitecture("aarch64"))
  }

  func testX86_64Direct() async throws {
    try skipSlow()
    try await buildTestcases(config: config.withArchitecture("x86_64"))
  }

  func testAarch64FromContainer() async throws {
    try skipSlow()
    try await buildTestcases(config: config.withArchitecture("aarch64").withDocker())
  }

  func testX86_64FromContainer() async throws {
    try skipSlow()
    try await buildTestcases(config: config.withArchitecture("x86_64").withDocker())
  }
}

final class Swift61_UbuntuEndToEndTests: XCTestCase {
  let config = SDKConfiguration(
    swiftVersion: "6.1",
    linuxDistributionName: "ubuntu",
    linuxDistributionVersion: "24.04",
    architecture: "aarch64",
    withDocker: false
  )

  func testAarch64Direct() async throws {
    try skipSlow()
    try await buildTestcases(config: config.withArchitecture("aarch64"))
  }

  func testX86_64Direct() async throws {
    try skipSlow()
    try await buildTestcases(config: config.withArchitecture("x86_64"))
  }

  func testAarch64FromContainer() async throws {
    try skipSlow()
    try await buildTestcases(config: config.withArchitecture("aarch64").withDocker())
  }

  func testX86_64FromContainer() async throws {
    try skipSlow()
    try await buildTestcases(config: config.withArchitecture("x86_64").withDocker())
  }

  func testJammyAarch64Direct() async throws {
    try skipSlow()
    try await buildTestcases(
      config: config.withArchitecture("aarch64").withLinuxDistributionVersion("22.04")
    )
  }

  func testJammyX86_64Direct() async throws {
    try skipSlow()
    try await buildTestcases(
      config: config.withArchitecture("x86_64").withLinuxDistributionVersion("22.04")
    )
  }

  func testJammyAarch64FromContainer() async throws {
    try skipSlow()
    try await buildTestcases(
      config: config.withArchitecture("aarch64").withLinuxDistributionVersion("22.04").withDocker()
    )
  }

  func testJammyX86_64FromContainer() async throws {
    try skipSlow()
    try await buildTestcases(
      config: config.withArchitecture("x86_64").withLinuxDistributionVersion("22.04").withDocker()
    )
  }
}

final class Swift59_DebianEndToEndTests: XCTestCase {
  let config = SDKConfiguration(
    swiftVersion: "5.9.2",
    linuxDistributionName: "debian",
    linuxDistributionVersion: "11",  // we use ubuntu2004 toolchain here
    architecture: "aarch64",
    withDocker: false
  )

  func testBullseyeAarch64Direct() async throws {
    try skipSlow()
    try await buildTestcases(config: config.withArchitecture("aarch64"))
  }

  func testBullseyeX86_64Direct() async throws {
    try skipSlow()
    try await buildTestcases(config: config.withArchitecture("x86_64"))
  }

  func testBookwormAarch64Direct() async throws {
    try skipSlow()
    try await buildTestcases(
      config: config.withLinuxDistributionVersion("12").withArchitecture("aarch64")
    )
  }

  func testBookwormX86_64Direct() async throws {
    try skipSlow()
    try await buildTestcases(
      config: config.withLinuxDistributionVersion("12").withArchitecture("x86_64")
    )
  }

  // NOTE: the generator does not support building a Debian 11/Debian 12 Swift SDK with Docker
  // for Swift 5.9.x and 5.10 without a pre-built container, so we do not test this here.
}

final class Swift510_DebianEndToEndTests: XCTestCase {
  let config = SDKConfiguration(
    swiftVersion: "5.10.1",
    linuxDistributionName: "debian",
    linuxDistributionVersion: "12",
    architecture: "aarch64",
    withDocker: false
  )

  func testBookwormAarch64Direct() async throws {
    try skipSlow()
    try await buildTestcases(config: config.withArchitecture("aarch64"))
  }

  func testBookwormX86_64Direct() async throws {
    try skipSlow()
    try await buildTestcases(config: config.withArchitecture("x86_64"))
  }

  func testBookwormAarch64FromContainer() async throws {
    try skipSlow()
    try await buildTestcases(config: config.withArchitecture("aarch64").withDocker())
  }

  func testBookwormX86_64FromContainer() async throws {
    try skipSlow()
    try await buildTestcases(config: config.withArchitecture("x86_64").withDocker())
  }

  func testBullseyeAarch64Direct() async throws {
    try skipSlow()
    try await buildTestcases(
      config: config.withLinuxDistributionVersion("11").withArchitecture("aarch64")
    )
  }

  func testBullseyeX86_64Direct() async throws {
    try skipSlow()
    try await buildTestcases(
      config: config.withLinuxDistributionVersion("11").withArchitecture("x86_64")
    )
  }

  // NOTE: Debian 11 containers do not exist for Swift, and the generator does not support
  // generating this container for you automatically, so we do not test this scenario.
}

final class Swift60_DebianEndToEndTests: XCTestCase {
  let config = SDKConfiguration(
    swiftVersion: "6.0.3",
    linuxDistributionName: "debian",
    linuxDistributionVersion: "12",
    architecture: "aarch64",
    withDocker: false
  )

  func testBookwormAarch64Direct() async throws {
    try skipSlow()
    try await buildTestcases(config: config.withArchitecture("aarch64"))
  }

  func testBookwormX86_64Direct() async throws {
    try skipSlow()
    try await buildTestcases(config: config.withArchitecture("x86_64"))
  }

  func testBookwormAarch64FromContainer() async throws {
    try skipSlow()
    try await buildTestcases(config: config.withArchitecture("aarch64").withDocker())
  }

  func testBookwormX86_64FromContainer() async throws {
    try skipSlow()
    try await buildTestcases(config: config.withArchitecture("x86_64").withDocker())
  }

  func testBullseyeAarch64Direct() async throws {
    try skipSlow()
    try await buildTestcases(
      config: config.withLinuxDistributionVersion("11").withArchitecture("aarch64")
    )
  }

  func testBullseyeX86_64Direct() async throws {
    try skipSlow()
    try await buildTestcases(
      config: config.withLinuxDistributionVersion("11").withArchitecture("x86_64")
    )
  }

  // NOTE: Debian 11 containers do not exist for Swift, and the generator does not support
  // generating this container for you automatically, so we do not test this scenario.
}

final class Swift61_DebianEndToEndTests: XCTestCase {
  let config = SDKConfiguration(
    swiftVersion: "6.1",
    linuxDistributionName: "debian",
    linuxDistributionVersion: "12",
    architecture: "aarch64",
    withDocker: false
  )

  func testBookwormAarch64Direct() async throws {
    try skipSlow()
    try await buildTestcases(config: config.withArchitecture("aarch64"))
  }

  func testBookwormX86_64Direct() async throws {
    try skipSlow()
    try await buildTestcases(config: config.withArchitecture("x86_64"))
  }

  func testBookwormAarch64FromContainer() async throws {
    try skipSlow()
    try await buildTestcases(config: config.withArchitecture("aarch64").withDocker())
  }

  func testBookwormX86_64FromContainer() async throws {
    try skipSlow()
    try await buildTestcases(config: config.withArchitecture("x86_64").withDocker())
  }

  func testBullseyeAarch64Direct() async throws {
    try skipSlow()
    try await buildTestcases(
      config: config.withLinuxDistributionVersion("11").withArchitecture("aarch64")
    )
  }

  func testBullseyeX86_64Direct() async throws {
    try skipSlow()
    try await buildTestcases(
      config: config.withLinuxDistributionVersion("11").withArchitecture("x86_64")
    )
  }

  // NOTE: Debian 11 containers do not exist for Swift, and the generator does not support
  // generating this container for you automatically, so we do not test this scenario.
}

final class Swift59_RHELEndToEndTests: XCTestCase {
  let config = SDKConfiguration(
    swiftVersion: "5.9.2",
    linuxDistributionName: "rhel",
    linuxDistributionVersion: "ubi9",
    architecture: "aarch64",
    withDocker: true  // RHEL-based SDKs can only be built from containers
  )

  func testAarch64FromContainer() async throws {
    try skipSlow()
    try await buildTestcases(config: config.withArchitecture("aarch64"))
  }

  func testX86_64FromContainer() async throws {
    try skipSlow()
    try await buildTestcases(config: config.withArchitecture("x86_64"))
  }

  func testAmazonLinux2Aarch64FromContainer() async throws {
    try skipSlow()
    try await buildTestcases(
      config: config.withArchitecture("aarch64").withContainerImageSuffix("amazonlinux2")
    )
  }

  func testAmazonLinux2X86_64FromContainer() async throws {
    try skipSlow()
    try await buildTestcases(
      config: config.withArchitecture("x86_64").withContainerImageSuffix("amazonlinux2")
    )
  }
}

final class Swift510_RHELEndToEndTests: XCTestCase {
  let config = SDKConfiguration(
    swiftVersion: "5.10.1",
    linuxDistributionName: "rhel",
    linuxDistributionVersion: "ubi9",
    architecture: "aarch64",
    withDocker: true  // RHEL-based SDKs can only be built from containers
  )

  func testAarch64FromContainer() async throws {
    try skipSlow()
    try await buildTestcases(config: config.withArchitecture("aarch64"))
  }

  func testX86_64FromContainer() async throws {
    try skipSlow()
    try await buildTestcases(config: config.withArchitecture("x86_64"))
  }

  func testAmazonLinux2Aarch64FromContainer() async throws {
    try skipSlow()
    try await buildTestcases(
      config: config.withArchitecture("aarch64").withContainerImageSuffix("amazonlinux2")
    )
  }

  func testAmazonLinux2X86_64FromContainer() async throws {
    try skipSlow()
    try await buildTestcases(
      config: config.withArchitecture("x86_64").withContainerImageSuffix("amazonlinux2")
    )
  }

  func testFedora39Aarch64FromContainer() async throws {
    try skipSlow()
    try await buildTestcases(
      config: config.withArchitecture("aarch64").withContainerImageSuffix("fedora39")
    )
  }

  func testFedora39X86_64FromContainer() async throws {
    try skipSlow()
    try await buildTestcases(
      config: config.withArchitecture("x86_64").withContainerImageSuffix("fedora39")
    )
  }
}

final class Swift60_RHELEndToEndTests: XCTestCase {
  let config = SDKConfiguration(
    swiftVersion: "6.0.3",
    linuxDistributionName: "rhel",
    linuxDistributionVersion: "ubi9",
    architecture: "aarch64",
    withDocker: true  // RHEL-based SDKs can only be built from containers
  )

  func testAarch64FromContainer() async throws {
    try skipSlow()
    try await buildTestcases(config: config.withArchitecture("aarch64"))
  }

  func testX86_64FromContainer() async throws {
    try skipSlow()
    try await buildTestcases(config: config.withArchitecture("x86_64"))
  }

  func testAmazonLinux2Aarch64FromContainer() async throws {
    try skipSlow()
    try await buildTestcases(
      config: config.withArchitecture("aarch64").withContainerImageSuffix("amazonlinux2")
    )
  }

  func testAmazonLinux2X86_64FromContainer() async throws {
    try skipSlow()
    try await buildTestcases(
      config: config.withArchitecture("x86_64").withContainerImageSuffix("amazonlinux2")
    )
  }

  func testFedora39Aarch64FromContainer() async throws {
    try skipSlow()
    try await buildTestcases(
      config: config.withArchitecture("aarch64").withContainerImageSuffix("fedora39")
    )
  }

  func testFedora39X86_64FromContainer() async throws {
    try skipSlow()
    try await buildTestcases(
      config: config.withArchitecture("x86_64").withContainerImageSuffix("fedora39")
    )
  }
}

final class Swift61_RHELEndToEndTests: XCTestCase {
  let config = SDKConfiguration(
    swiftVersion: "6.1",
    linuxDistributionName: "rhel",
    linuxDistributionVersion: "ubi9",
    architecture: "aarch64",
    withDocker: true  // RHEL-based SDKs can only be built from containers
  )

  func testAarch64FromContainer() async throws {
    try skipSlow()
    try await buildTestcases(config: config.withArchitecture("aarch64"))
  }

  func testX86_64FromContainer() async throws {
    try skipSlow()
    try await buildTestcases(config: config.withArchitecture("x86_64"))
  }

  func testAmazonLinux2Aarch64FromContainer() async throws {
    try skipSlow()
    try await buildTestcases(
      config: config.withArchitecture("aarch64").withContainerImageSuffix("amazonlinux2")
    )
  }

  func testAmazonLinux2X86_64FromContainer() async throws {
    try skipSlow()
    try await buildTestcases(
      config: config.withArchitecture("x86_64").withContainerImageSuffix("amazonlinux2")
    )
  }
}
