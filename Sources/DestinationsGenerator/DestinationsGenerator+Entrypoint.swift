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

import AsyncAlgorithms
import AsyncHTTPClient
import Foundation
import RegexBuilder
import SystemPackage

private let ubuntuMirror = "http://gb.archive.ubuntu.com/ubuntu"

private let byteCountFormatter = ByteCountFormatter()

extension DestinationsGenerator {
  public func generateDestinationBundle(
    shouldUseDocker: Bool,
    shouldGenerateFromScratch: Bool
  ) async throws {
    let client = HTTPClient(
      eventLoopGroupProvider: .createNew,
      configuration: .init(redirectConfiguration: .follow(max: 5, allowCycles: false))
    )

    defer {
      try! client.syncShutdown()
    }

    if shouldGenerateFromScratch {
      try removeRecursively(at: pathsConfiguration.sdkDirPath)
      try removeRecursively(at: pathsConfiguration.toolchainDirPath)
    }

    try createDirectoryIfNeeded(at: pathsConfiguration.artifactsCachePath)
    try createDirectoryIfNeeded(at: pathsConfiguration.sdkDirPath)
    try createDirectoryIfNeeded(at: pathsConfiguration.toolchainDirPath)

    if try await !self.isCacheValid {
      try await self.downloadArtifacts(
        client,
        shouldUseDocker: shouldUseDocker
      )
    }

    if !shouldUseDocker {
      try await self.downloadUbuntuPackages(client)
    }

    try await self.unpackHostToolchain()

    if shouldUseDocker {
      try await self.copyDestinationSDKFromDocker()
    } else {
      try await self.unpackDestinationSDKPackage()
    }

    try await self.unpackLLDLinker()

    try self.fixAbsoluteSymlinks()

    try self.fixGlibcModuleMap(
      at: pathsConfiguration.toolchainDirPath
        .appending("/usr/lib/swift/linux/\(Triple.availableTriples.linux.cpu)/glibc.modulemap")
    )

    let autolinkExtractPath = pathsConfiguration.toolchainBinDirPath.appending("swift-autolink-extract")

    if !doesFileExist(at: autolinkExtractPath) {
      logGenerationStep("Fixing `swift-autolink-extract` symlink...")
      try createSymlink(at: autolinkExtractPath, pointingTo: "swift")
    }

    let toolsetJSONPath = try generateToolsetJSON()

    try generateDestinationJSON(toolsetPath: toolsetJSONPath)

    try generateArtifactBundleManifest()

    logGenerationStep(
      """
      All done! Install the newly generated SDK with this command:
      swift experimental-destination install \(pathsConfiguration.artifactBundlePath)

      Use the newly installed SDK when building with this command:
      swift build --experimental-destination-selector \(artifactID)
      """
    )
  }

  private func unpackDestinationSDKPackage() async throws {
    logGenerationStep("Unpacking destination Swift SDK package...")
    let packagePath = downloadableArtifacts.runTimeTripleSwift.localPath
    let versionsConfiguration = self.versionsConfiguration

    try await inTemporaryDirectory { fs, tmpDir in
      try await fs.unpack(file: packagePath, into: tmpDir)
      try await fs
        .copyDestinationSDK(
          from: tmpDir
            .appending(
              "swift-\(versionsConfiguration.swiftVersion)-ubuntu\(versionsConfiguration.ubuntuVersion)/usr/lib"
            )
        )
    }
  }

  private func copyDestinationSDKFromDocker() async throws {
    let imageName =
      "swiftlang/swift-cc-destination:\(versionsConfiguration.swiftVersion.components(separatedBy: "-")[0])-\(versionsConfiguration.ubuntuRelease)"

    logGenerationStep("Building a Docker image with the destination environment...")
    try await buildDockerImage(
      name: imageName,
      dockerfileDirectory: pathsConfiguration.sourceRoot
        .appending("Dockerfiles")
        .appending("Ubuntu")
        .appending(versionsConfiguration.ubuntuVersion)
    )

    logGenerationStep("Launching a Docker container to copy destination Swift SDK from it...")
    let containerID = try await launchDockerContainer(imageName: imageName)
    let pathsConfiguration = self.pathsConfiguration

    try await inTemporaryDirectory { fs, _ in
      let sdkUsrPath = pathsConfiguration.sdkDirPath.appending("usr")
      let sdkUsrLibPath = sdkUsrPath.appending("lib")
      try fs.createDirectoryIfNeeded(at: sdkUsrPath)
      try await fs.copyFromDockerContainer(
        id: containerID,
        from: "/usr/include",
        to: sdkUsrPath.appending("include")
      )
      try await fs.copyFromDockerContainer(
        id: containerID,
        from: "/usr/lib",
        to: sdkUsrLibPath
      )
      try fs.createSymlink(at: pathsConfiguration.sdkDirPath.appending("lib"), pointingTo: "usr/lib")
      try fs.removeRecursively(at: sdkUsrLibPath.appending("ssl"))
      try await fs.copyDestinationSDK(from: sdkUsrLibPath)
    }
  }

  private func copyDestinationSDK(from destinationPackagePath: FilePath) async throws {
    logGenerationStep("Copying Swift core libraries into destination SDK bundle...")

    for (pathWithinPackage, destinationBundlePath) in [
      ("swift/linux", pathsConfiguration.toolchainDirPath.appending("usr/lib/swift")),
      ("swift_static/linux", pathsConfiguration.toolchainDirPath.appending("usr/lib/swift_static")),
      ("swift/dispatch", pathsConfiguration.sdkDirPath.appending("usr/include")),
      ("swift/os", pathsConfiguration.sdkDirPath.appending("usr/include")),
      ("swift/CoreFoundation", pathsConfiguration.sdkDirPath.appending("usr/include")),
    ] {
      try await rsync(
        from: destinationPackagePath.appending(pathWithinPackage),
        to: destinationBundlePath
      )
    }
  }

  private func unpackHostToolchain() async throws {
    logGenerationStep("Unpacking and copying host toolchain...")
    let downloadableArtifacts = self.downloadableArtifacts
    let pathsConfiguration = self.pathsConfiguration

    try await inTemporaryDirectory { fs, tmpDir in
      try await fs.unpack(file: downloadableArtifacts.buildTimeTripleSwift.localPath, into: tmpDir)
      try await fs.rsync(from: tmpDir.appending("usr"), to: pathsConfiguration.toolchainDirPath)
    }
  }

  private func unpackLLDLinker() async throws {
    logGenerationStep("Unpacking and copying `lld` linker...")
    let downloadableArtifacts = self.downloadableArtifacts
    let pathsConfiguration = self.pathsConfiguration

    try await inTemporaryDirectory { fs, tmpDir in
      try await fs.untar(file: downloadableArtifacts.buildTimeTripleLLVM.localPath, into: tmpDir, stripComponents: 1)
      try fs.copy(
        from: tmpDir.appending("bin/lld"),
        to: pathsConfiguration.toolchainBinDirPath.appending("ld.lld")
      )
    }
  }

  /// Check whether cached downloads for required `DownloadArtifact` values can be reused instead of downloading them.
  /// - Returns: `true` if artifacts are valid, `false` otherwise.
  private var isCacheValid: Bool {
    get async throws {
      logGenerationStep("Checking packages cache...")

      guard downloadableArtifacts.allItems.map(\.localPath).allSatisfy(doesFileExist(at:)) else {
        return false
      }

      return try await withThrowingTaskGroup(of: Bool.self) { taskGroup in
        for artifact in downloadableArtifacts.allItems {
          taskGroup.addTask { try await Self.isChecksumValid(artifact: artifact) }
        }

        for try await isValid in taskGroup {
          guard isValid else { return false }
        }

        return true
      }
    }
  }

  private func downloadArtifacts(
    _ client: HTTPClient,
    shouldUseDocker: Bool
  ) async throws {
    logGenerationStep("Downloading required toolchain packages...")

    let buildTimeTripleSwiftStream = client.streamDownloadProgress(for: downloadableArtifacts.buildTimeTripleSwift)
      .removeDuplicates(by: didProgressChangeSignificantly)
    let buildTimeTripleLLVMStream = client.streamDownloadProgress(for: downloadableArtifacts.buildTimeTripleLLVM)
      .removeDuplicates(by: didProgressChangeSignificantly)

    print("Using these URLs for downloads:")

    // FIXME: some code duplication is necessary due to https://github.com/apple/swift-async-algorithms/issues/226
    if shouldUseDocker {
      for artifact in [downloadableArtifacts.buildTimeTripleSwift, downloadableArtifacts.buildTimeTripleLLVM] {
        print(artifact.remoteURL)
      }

      let stream = combineLatest(buildTimeTripleSwiftStream, buildTimeTripleLLVMStream)
        .throttle(for: .seconds(1))

      for try await (swiftProgress, llvmProgress) in stream {
        report(progress: swiftProgress, for: downloadableArtifacts.buildTimeTripleSwift)
        report(progress: llvmProgress, for: downloadableArtifacts.buildTimeTripleLLVM)
      }
    } else {
      for artifact in [
        downloadableArtifacts.buildTimeTripleSwift,
        downloadableArtifacts.buildTimeTripleLLVM,
        downloadableArtifacts.runTimeTripleSwift,
      ] {
        print(artifact.remoteURL)
      }
      let runTimeTripleSwiftStream = client.streamDownloadProgress(for: downloadableArtifacts.runTimeTripleSwift)
        .removeDuplicates(by: didProgressChangeSignificantly)

      let stream = combineLatest(
        buildTimeTripleSwiftStream,
        buildTimeTripleLLVMStream,
        runTimeTripleSwiftStream
      )
      .throttle(for: .seconds(1))

      for try await (buildTimeTripleSwiftProgress, buildTimeTripleLLVMProgress, runTimeTripleSwiftProgress) in stream {
        report(progress: buildTimeTripleSwiftProgress, for: downloadableArtifacts.buildTimeTripleSwift)
        report(progress: buildTimeTripleLLVMProgress, for: downloadableArtifacts.buildTimeTripleLLVM)
        report(progress: runTimeTripleSwiftProgress, for: downloadableArtifacts.runTimeTripleSwift)
      }
    }
  }

  private func downloadUbuntuPackages(_ client: HTTPClient) async throws {
    logGenerationStep("Parsing Ubuntu packages list...")

    let allPackages = try await parse(
      ubuntuPackagesList: client.downloadUbuntuPackagesList(ubuntuRelease: versionsConfiguration.ubuntuRelease)
    )

    let requiredPackages = [
      "libc6-dev",
      "linux-libc-dev",
      "libicu70",
      "libgcc-12-dev",
      "libicu-dev",
      "libc6",
      "libgcc-s1",
      "libstdc++-12-dev",
      "libstdc++6",
      "zlib1g",
      "zlib1g-dev",
    ]
    let urls = requiredPackages.compactMap { allPackages[$0] }

    print("Downloading \(urls.count) Ubuntu packages...")
    let pathsConfiguration = self.pathsConfiguration

    try await inTemporaryDirectory { fs, tmpDir in
      let progress = try await client.downloadFiles(from: urls, to: tmpDir)
      report(downloadedFiles: Array(zip(urls, progress.map(\.receivedBytes))))

      for fileName in urls.map(\.lastPathComponent) {
        try await fs.unpack(file: tmpDir.appending(fileName), into: pathsConfiguration.sdkDirPath)
      }
    }

    try createDirectoryIfNeeded(at: pathsConfiguration.toolchainBinDirPath)
  }

  private func fixAbsoluteSymlinks() throws {
    logGenerationStep("Fixing up absolute symlinks...")

    for (source, absoluteDestination) in try findSymlinks(at: pathsConfiguration.sdkDirPath)
      .filter({ $1.string.hasPrefix("/") })
    {
      var relativeSource = source
      var relativeDestination = FilePath()

      let isPrefixRemoved = relativeSource.removePrefix(pathsConfiguration.sdkDirPath)
      precondition(isPrefixRemoved)
      for _ in relativeSource.removingLastComponent().components {
        relativeDestination.append("..")
      }

      relativeDestination.push(absoluteDestination.removingRoot())
      try removeRecursively(at: source)
      try createSymlink(at: source, pointingTo: relativeDestination)

      guard FileManager.default.fileExists(atPath: source.string) else {
        throw FileOperationError.symlinkFixupFailed(
          source: source,
          destination: absoluteDestination
        )
      }
    }
  }

  private var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    return encoder
  }

  private func generateToolsetJSON() throws -> FilePath {
    logGenerationStep("Generating toolset JSON file...")

    let toolsetJSONPath = pathsConfiguration.destinationRootPath.appending("toolset.json")

    var relativeToolchainBinDir = pathsConfiguration.toolchainBinDirPath

    guard
      relativeToolchainBinDir.removePrefix(pathsConfiguration.destinationRootPath)
    else {
      fatalError(
        "`toolchainBinDirPath` is at an unexpected location that prevents computing a relative path"
      )
    }

    try writeFile(
      at: toolsetJSONPath,
      self.encoder.encode(
        Toolset(
          rootPath: relativeToolchainBinDir.string,
          swiftCompiler: .init(
            extraCLIOptions: ["-use-ld=lld", "-Xlinker", "-R/usr/lib/swift/linux/"]
          ),
          cxxCompiler: .init(
            extraCLIOptions: ["-lstdc++"]
          ),
          linker: .init(
            path: "ld.lld"
          )
        )
      )
    )

    return toolsetJSONPath
  }

  private func generateDestinationJSON(toolsetPath: FilePath) throws {
    logGenerationStep("Generating destination JSON file...")

    let destinationJSONPath = pathsConfiguration.destinationRootPath.appending("destination.json")

    var relativeToolchainBinDir = pathsConfiguration.toolchainBinDirPath
    var relativeSDKDir = pathsConfiguration.sdkDirPath
    var relativeToolsetPath = toolsetPath

    guard
      relativeToolchainBinDir.removePrefix(pathsConfiguration.destinationRootPath),
      relativeSDKDir.removePrefix(pathsConfiguration.destinationRootPath),
      relativeToolsetPath.removePrefix(pathsConfiguration.destinationRootPath)
    else {
      fatalError("""
      `toolchainBinDirPath`, `sdkDirPath`, and `toolsetPath` are at unexpected locations that prevent computing \
      relative paths
      """)
    }

    try writeFile(
      at: destinationJSONPath,
      self.encoder.encode(
        DestinationV3(
          runTimeTriples: [
            Triple.availableTriples.linux.description: .init(
              sdkRootPath: relativeSDKDir.string,
              toolsetPaths: [relativeToolsetPath.string]
            ),
          ]
        )
      )
    )
  }

  private func generateArtifactBundleManifest() throws {
    logGenerationStep("Generating .artifactbundle manifest file...")

    let artifactBundleManifestPath = pathsConfiguration.artifactBundlePath.appending("info.json")

    try writeFile(
      at: artifactBundleManifestPath,
      self.encoder.encode(
        ArtifactsArchiveMetadata(
          schemaVersion: "1.0",
          artifacts: [
            artifactID: .init(
              type: .crossCompilationDestination,
              version: "0.0.1",
              variants: [
                .init(
                  path: FilePath(artifactID).appending(Triple.availableTriples.linux.description).string,
                  supportedTriples: [Triple.availableTriples.macOS.description]
                ),
              ]
            ),
          ]
        )
      )
    )
  }

  private func fixGlibcModuleMap(at path: FilePath) throws {
    logGenerationStep("Fixing absolute paths in `glibc.modulemap`...")

    let privateIncludesPath = path.removingLastComponent().appending("private_includes")
    try removeRecursively(at: privateIncludesPath)
    try createDirectoryIfNeeded(at: privateIncludesPath)

    let regex = Regex {
      #/\n( *header )"\/+usr\/include\//#
      Capture {
        Optionally {
          Triple.availableTriples.linux.cpu
          "-linux-gnu"
        }
      }
      #/([^\"]+)\"/#
    }

    var moduleMap = try String(data: readFile(at: path), encoding: .utf8)!
    try moduleMap.replace(regex) {
      let (_, headerKeyword, _, headerPath) = $0.output

      let newHeaderRelativePath = headerPath.replacing("/", with: "_")
      try writeFile(
        at: privateIncludesPath.appending(String(newHeaderRelativePath)),
        Data("#include <linux/uuid.h>\n".utf8)
      )

      return #"\#n\#(headerKeyword) "private_includes/\#(newHeaderRelativePath)""#
    }

    try writeFile(at: path, Data(moduleMap.utf8))
  }
}

/// Checks whether two given progress value are different enough from each other. Used for filtering
/// out progress values
/// in async streams with `removeDuplicates` operator.
/// - Parameters:
///   - previous: Preceding progress value in the stream.
///   - current: Currently processed progress value in the stream.
/// - Returns: `true` if `totalBytes` value is different by any amount or if `receivedBytes` is
/// different by amount
/// larger than 1MiB. Returns `false` otherwise.
@Sendable
private func didProgressChangeSignificantly(
  previous: FileDownloadDelegate.Progress,
  current: FileDownloadDelegate.Progress
) -> Bool {
  guard previous.totalBytes == current.totalBytes else {
    return true
  }

  return current.receivedBytes - previous.receivedBytes > 1024 * 1024 * 1024
}

private func report(progress: FileDownloadDelegate.Progress, for artifact: DownloadableArtifacts.Item) {
  if let total = progress.totalBytes {
    print("""
    \(artifact.remoteURL.lastPathComponent) \(
      byteCountFormatter
        .string(fromByteCount: Int64(progress.receivedBytes))
    )/\(
      byteCountFormatter
        .string(fromByteCount: Int64(total))
    )
    """)
  } else {
    print(
      "\(artifact.remoteURL.lastPathComponent) \(byteCountFormatter.string(fromByteCount: Int64(progress.receivedBytes)))"
    )
  }
}

private func report(downloadedFiles: [(URL, Int)]) {
  for (url, bytes) in downloadedFiles {
    print("\(url) – \(byteCountFormatter.string(fromByteCount: Int64(bytes)))")
  }
}

extension HTTPClient {
  func downloadUbuntuPackagesList(ubuntuRelease: String) async throws -> String {
    let packagesFile = "\(ubuntuMirror)/dists/\(ubuntuRelease)/main/binary-amd64/Packages.gz"

    guard let packages = try await get(url: packagesFile).get().body else {
      throw FileOperationError.downloadFailed(URL(string: packagesFile)!)
    }

    var result = ""
    for try await chunk in try packages.unzip() {
      result.append(String(data: chunk, encoding: .utf8)!)
    }

    return result
  }
}

private func parse(ubuntuPackagesList packages: String) -> [String: URL] {
  let packageRef = Reference(Substring.self)
  let pathRef = Reference(Substring.self)

  let regex = Regex {
    "Package: "

    Capture(as: packageRef) {
      OneOrMore(.anyNonNewline)
    }

    OneOrMore(.any, .reluctant)

    "Filename: "

    Capture(as: pathRef) {
      OneOrMore(.anyNonNewline)
    }

    Anchor.endOfLine

    OneOrMore(.any, .reluctant)

    "Description-md5: "

    OneOrMore(.hexDigit)
  }

  var result = [String: URL]()
  for match in packages.matches(of: regex) {
    guard let url = URL(string: "\(ubuntuMirror)/\(match[pathRef])") else { continue }

    result[String(match[packageRef])] = url
  }

  return result
}

private func logGenerationStep(_ message: String) {
  print("\n\(message)")
}
