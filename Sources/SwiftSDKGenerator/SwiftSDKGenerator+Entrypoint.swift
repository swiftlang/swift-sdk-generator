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

private let ubuntuAMD64Mirror = "http://gb.archive.ubuntu.com/ubuntu"
private let ubuntuARM64Mirror = "http://ports.ubuntu.com/ubuntu-ports"

private let byteCountFormatter = ByteCountFormatter()

private let unusedDarwinPlatforms = [
  "watchsimulator",
  "iphonesimulator",
  "appletvsimulator",
  "iphoneos",
  "watchos",
  "appletvos",
]

private let unusedHostBinaries = [
  "clangd",
  "docc",
  "dsymutil",
  "sourcekit-lsp",
  "swift-package",
  "swift-package-collection",
]

public extension Triple.CPU {
  /// Returns the value of `cpu` converted to a convention used in Debian package names
  var debianConventionName: String {
    switch self {
    case .arm64: "arm64"
    case .x86_64: "amd64"
    }
  }
}

extension SwiftSDKGenerator {
  public func generateBundle(shouldGenerateFromScratch: Bool) async throws {
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
      try await self.downloadArtifacts(client)
    }

    if !shouldUseDocker {
      guard case let .ubuntu(version) = versionsConfiguration.linuxDistribution else {
        throw GeneratorError.distributionSupportsOnlyDockerGenerator(versionsConfiguration.linuxDistribution)
      }

      try await self.downloadUbuntuPackages(client, requiredPackages: version.requiredPackages)
    }

    try await self.unpackHostSwift()

    if shouldUseDocker {
      try await self.copyTargetSwiftFromDocker()
    } else {
      try await self.unpackTargetSwiftPackage()
    }

    try await self.unpackLLDLinker()

    try self.fixAbsoluteSymlinks()

    let targetCPU = self.targetTriple.cpu
    try self.fixGlibcModuleMap(
      at: pathsConfiguration.toolchainDirPath
        .appending("/usr/lib/swift/linux/\(targetCPU.linuxConventionName)/glibc.modulemap")
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
      swift experimental-sdk install \(pathsConfiguration.artifactBundlePath)

      After that, use the newly installed SDK when building with this command:
      swift build --experimental-swift-sdk \(artifactID)
      """
    )
  }

  private func unpackTargetSwiftPackage() async throws {
    logGenerationStep("Unpacking Swift distribution for the target triple...")
    let packagePath = downloadableArtifacts.targetSwift.localPath

    try await inTemporaryDirectory { fs, tmpDir in
      try await fs.unpack(file: packagePath, into: tmpDir)
      try await fs.copyTargetSwift(
        from: tmpDir.appending(
          """
          \(self.versionsConfiguration.swiftDistributionName())/usr/lib
          """
        )
      )
    }
  }

  private func copyTargetSwiftFromDocker() async throws {
    logGenerationStep("Building a Docker image for the target environment...")
    // FIXME: launch Swift base image directly instead of building a new empty image
    let imageName = try await buildDockerImage(baseImage: self.versionsConfiguration.swiftBaseDockerImage)

    logGenerationStep("Launching a Docker container to copy Swift SDK for the target triple from it...")
    let containerID = try await launchDockerContainer(imageName: imageName)
    do {
      let pathsConfiguration = self.pathsConfiguration

      try await inTemporaryDirectory { generator, _ in
        let sdkUsrPath = pathsConfiguration.sdkDirPath.appending("usr")
        let sdkUsrLibPath = sdkUsrPath.appending("lib")
        try generator.createDirectoryIfNeeded(at: sdkUsrPath)
        try await generator.copyFromDockerContainer(
          id: containerID,
          from: "/usr/include",
          to: sdkUsrPath.appending("include")
        )

        if case .rhel = self.versionsConfiguration.linuxDistribution {
          try await generator.runOnDockerContainer(
            id: containerID,
            command: #"""
            sh -c '
                chmod +w /usr/lib64
                cd /usr/lib64
                for n in *; do
                    destination=$(readlink $n)
                    echo $destination | grep "\.\." && \
                        rm -f $n && \
                        ln -s $(basename $destination) $n
                done
                rm -rf pm-utils
            '
            """#
          )

          let sdkUsrLib64Path = sdkUsrPath.appending("lib64")
          try await generator.copyFromDockerContainer(
            id: containerID,
            from: FilePath("/usr/lib64"),
            to: sdkUsrLib64Path
          )

          try createSymlink(at: pathsConfiguration.sdkDirPath.appending("lib64"), pointingTo: "./usr/lib64")

          // `libc.so` is a linker script with absolute paths on RHEL, replace with a relative symlink
          let libcSO = sdkUsrLib64Path.appending("libc.so")
          try removeFile(at: libcSO)
          try createSymlink(at: libcSO, pointingTo: "libc.so.6")
        }

        try generator.createDirectoryIfNeeded(at: sdkUsrLibPath)
        for subpath in ["clang", "gcc", "swift", "swift_static"] {
          try await generator.copyFromDockerContainer(
            id: containerID,
            from: FilePath("/usr/lib").appending(subpath),
            to: sdkUsrLibPath.appending(subpath)
          )
        }

        // Python artifacts are redundant.
        try generator.removeRecursively(at: sdkUsrLibPath.appending("python3.10"))

        try generator.createSymlink(at: pathsConfiguration.sdkDirPath.appending("lib"), pointingTo: "usr/lib")
        try generator.removeRecursively(at: sdkUsrLibPath.appending("ssl"))
        try await generator.copyTargetSwift(from: sdkUsrLibPath)
        try await generator.stopDockerContainer(id: containerID)
      }
    } catch {
      try await stopDockerContainer(id: containerID)
    }
  }

  private func copyTargetSwift(from distributionPath: FilePath) async throws {
    logGenerationStep("Copying Swift core libraries for the target triple into Swift SDK bundle...")

    for (pathWithinPackage, pathWithinSwiftSDK) in [
      ("swift/linux", pathsConfiguration.toolchainDirPath.appending("usr/lib/swift")),
      ("swift_static/linux", pathsConfiguration.toolchainDirPath.appending("usr/lib/swift_static")),
      ("swift_static/shims", pathsConfiguration.toolchainDirPath.appending("usr/lib/swift_static")),
      ("swift/dispatch", pathsConfiguration.sdkDirPath.appending("usr/include")),
      ("swift/os", pathsConfiguration.sdkDirPath.appending("usr/include")),
      ("swift/CoreFoundation", pathsConfiguration.sdkDirPath.appending("usr/include")),
    ] {
      try await rsync(from: distributionPath.appending(pathWithinPackage), to: pathWithinSwiftSDK)
    }
  }

  private func unpackHostSwift() async throws {
    logGenerationStep("Unpacking and copying Swift binaries for the host triple...")
    let downloadableArtifacts = self.downloadableArtifacts
    let pathsConfiguration = self.pathsConfiguration

    try await inTemporaryDirectory { fileSystem, tmpDir in
      try await fileSystem.unpack(file: downloadableArtifacts.hostSwift.localPath, into: tmpDir)
      // Remove libraries for platforms we don't intend cross-compiling to
      for platform in unusedDarwinPlatforms {
        try fileSystem.removeRecursively(at: tmpDir.appending("usr/lib/swift/\(platform)"))
      }
      try fileSystem.removeRecursively(at: tmpDir.appending("usr/lib/sourcekitd.framework"))

      for binary in unusedHostBinaries {
        try fileSystem.removeRecursively(at: tmpDir.appending("usr/bin/\(binary)"))
      }

      try await fileSystem.rsync(from: tmpDir.appending("usr"), to: pathsConfiguration.toolchainDirPath)
    }
  }

  private func unpackLLDLinker() async throws {
    logGenerationStep("Unpacking and copying `lld` linker...")
    let downloadableArtifacts = self.downloadableArtifacts
    let pathsConfiguration = self.pathsConfiguration

    try await inTemporaryDirectory { fileSystem, tmpDir in
      try await fileSystem.untar(
        file: downloadableArtifacts.hostLLVM.localPath,
        into: tmpDir,
        stripComponents: 1
      )
      try fileSystem.copy(
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
          taskGroup.addTask { try await Self.isChecksumValid(artifact: artifact, isVerbose: self.isVerbose) }
        }

        for try await isValid in taskGroup {
          guard isValid else { return false }
        }

        return true
      }
    }
  }

  private func downloadArtifacts(_ client: HTTPClient) async throws {
    logGenerationStep("Downloading required toolchain packages...")

    let hostSwiftProgressStream = client.streamDownloadProgress(for: downloadableArtifacts.hostSwift)
      .removeDuplicates(by: didProgressChangeSignificantly)
    let hostLLVMProgressStream = client.streamDownloadProgress(for: downloadableArtifacts.hostLLVM)
      .removeDuplicates(by: didProgressChangeSignificantly)

    print("Using these URLs for downloads:")

    // FIXME: some code duplication is necessary due to https://github.com/apple/swift-async-algorithms/issues/226
    if shouldUseDocker {
      for artifact in [downloadableArtifacts.hostSwift, downloadableArtifacts.hostLLVM] {
        print(artifact.remoteURL)
      }

      let stream = combineLatest(hostSwiftProgressStream, hostLLVMProgressStream)
        .throttle(for: .seconds(1))

      for try await (swiftProgress, llvmProgress) in stream {
        report(progress: swiftProgress, for: downloadableArtifacts.hostSwift)
        report(progress: llvmProgress, for: downloadableArtifacts.hostLLVM)
      }
    } else {
      for artifact in [
        downloadableArtifacts.hostSwift,
        downloadableArtifacts.hostLLVM,
        downloadableArtifacts.targetSwift,
      ] {
        print(artifact.remoteURL)
      }
      let targetSwiftProgressStream = client.streamDownloadProgress(for: downloadableArtifacts.targetSwift)
        .removeDuplicates(by: didProgressChangeSignificantly)

      let stream = combineLatest(
        hostSwiftProgressStream,
        hostLLVMProgressStream,
        targetSwiftProgressStream
      )
      .throttle(for: .seconds(1))

      for try await (hostSwiftProgress, hostLLVMProgress, targetSwiftProgress) in stream {
        report(progress: hostSwiftProgress, for: downloadableArtifacts.hostSwift)
        report(progress: hostLLVMProgress, for: downloadableArtifacts.hostLLVM)
        report(progress: targetSwiftProgress, for: downloadableArtifacts.targetSwift)
      }
    }
  }

  private func downloadUbuntuPackages(_ client: HTTPClient, requiredPackages: [String]) async throws {
    logGenerationStep("Parsing Ubuntu packages list...")

    async let mainPackages = try await client.parseUbuntuPackagesList(
      ubuntuRelease: versionsConfiguration.linuxDistribution.release,
      repository: "main",
      targetTriple: self.targetTriple,
      isVerbose: self.isVerbose
    )

    async let updatesPackages = try await client.parseUbuntuPackagesList(
      ubuntuRelease: versionsConfiguration.linuxDistribution.release,
      releaseSuffix: "-updates",
      repository: "main",
      targetTriple: self.targetTriple,
      isVerbose: self.isVerbose
    )

    async let universePackages = try await client.parseUbuntuPackagesList(
      ubuntuRelease: versionsConfiguration.linuxDistribution.release,
      releaseSuffix: "-updates",
      repository: "universe",
      targetTriple: self.targetTriple,
      isVerbose: self.isVerbose
    )

    let allPackages = try await mainPackages
      .merging(updatesPackages, uniquingKeysWith: { $1 })
      .merging(universePackages, uniquingKeysWith: { $1 })

    let urls = requiredPackages.compactMap { allPackages[$0] }

    guard urls.count == requiredPackages.count else {
      throw GeneratorError.ubuntuPackagesParsingFailure(
        expectedPackages: requiredPackages.count,
        actual: urls.count
      )
    }

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

    for (source, absoluteDestination) in try findSymlinks(at: pathsConfiguration.sdkDirPath).filter({
      $1.string.hasPrefix("/")
    }) {
      guard !absoluteDestination.string.hasPrefix("/etc") else {
        try removeFile(at: source)
        continue
      }
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

      guard doesFileExist(at: source) else {
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

    let toolsetJSONPath = pathsConfiguration.swiftSDKRootPath.appending("toolset.json")

    var relativeToolchainBinDir = pathsConfiguration.toolchainBinDirPath

    guard
      relativeToolchainBinDir.removePrefix(pathsConfiguration.swiftSDKRootPath)
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
          ),
          librarian: .init(
            path: "llvm-ar"
          )
        )
      )
    )

    return toolsetJSONPath
  }

  private func generateDestinationJSON(toolsetPath: FilePath) throws {
    logGenerationStep("Generating destination JSON file...")

    let destinationJSONPath = pathsConfiguration.swiftSDKRootPath.appending("swift-sdk.json")

    var relativeToolchainBinDir = pathsConfiguration.toolchainBinDirPath
    var relativeSDKDir = pathsConfiguration.sdkDirPath
    var relativeToolsetPath = toolsetPath

    guard
      relativeToolchainBinDir.removePrefix(pathsConfiguration.swiftSDKRootPath),
      relativeSDKDir.removePrefix(pathsConfiguration.swiftSDKRootPath),
      relativeToolsetPath.removePrefix(pathsConfiguration.swiftSDKRootPath)
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
            self.targetTriple.linuxConventionDescription: .init(
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
              type: .swiftSDK,
              version: "0.0.1",
              variants: [
                .init(
                  path: FilePath(artifactID).appending(self.targetTriple.linuxConventionDescription).string,
                  supportedTriples: [self.hostTriple.description]
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

    guard doesFileExist(at: path) else {
      throw GeneratorError.fileDoesNotExist(path)
    }

    let privateIncludesPath = path.removingLastComponent().appending("private_includes")
    try removeRecursively(at: privateIncludesPath)
    try createDirectoryIfNeeded(at: privateIncludesPath)

    let regex = Regex {
      #/\n( *header )"\/+usr\/include\//#
      Capture {
        Optionally {
          hostTriple.cpu.linuxConventionName
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

/// Checks whether two given progress value are different enough from each other. Used for filtering out progress
/// values in async streams with `removeDuplicates` operator.
/// - Parameters:
///   - previous: Preceding progress value in the stream.
///   - current: Currently processed progress value in the stream.
/// - Returns: `true` if `totalBytes` value is different by any amount or if `receivedBytes` is different by amount
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
  private func downloadUbuntuPackagesList(
    from url: String,
    isVerbose: Bool
  ) async throws -> String {
    guard let packages = try await get(url: url).get().body else {
      throw FileOperationError.downloadFailed(URL(string: url)!)
    }

    var result = ""
    for try await chunk in try packages.unzip(isVerbose: isVerbose) {
      result.append(String(data: chunk, encoding: .utf8)!)
    }

    return result
  }

  func parseUbuntuPackagesList(
    ubuntuRelease: String,
    releaseSuffix: String = "",
    repository: String,
    targetTriple: Triple,
    isVerbose: Bool
  ) async throws -> [String: URL] {
    let mirrorURL: String = if targetTriple.cpu == .x86_64 {
      ubuntuAMD64Mirror
    } else {
      ubuntuARM64Mirror
    }

    let packagesListURL = """
    \(mirrorURL)/dists/\(ubuntuRelease)\(releaseSuffix)/\(repository)/binary-\(
      targetTriple.cpu
        .debianConventionName
    )/Packages.gz
    """

    let packages = try await downloadUbuntuPackagesList(
      from: packagesListURL,
      isVerbose: isVerbose
    )

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
      guard let url = URL(string: "\(mirrorURL)/\(match[pathRef])") else { continue }

      result[String(match[packageRef])] = url
    }

    return result
  }
}

func logGenerationStep(_ message: String) {
  print("\n\(message)")
}
