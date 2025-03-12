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

import AsyncAlgorithms
import Helpers
import Logging
import RegexBuilder

import class Foundation.ByteCountFormatter
import class Foundation.FileManager
import struct Foundation.URL
import struct SystemPackage.FilePath

private let ubuntuMainMirror = "http://gb.archive.ubuntu.com/ubuntu"
private let ubuntuPortsMirror = "http://ports.ubuntu.com/ubuntu-ports"
private let debianMirror = "http://deb.debian.org/debian"

extension FilePath {
  var metadataValue: Logger.MetadataValue {
    .string(self.string)
  }
}

extension SwiftSDKGenerator {
  func downloadArtifacts(
    _ client: some HTTPClientProtocol, _ engine: QueryEngine,
    downloadableArtifacts: inout DownloadableArtifacts,
    itemsToDownload: @Sendable (DownloadableArtifacts) -> [DownloadableArtifacts.Item]
  ) async throws {
    logger.info("Downloading required toolchain packages...")
    let hostLLVMURL = downloadableArtifacts.hostLLVM.remoteURL
    // Workaround an issue with github.com returning 400 instead of 404 status to HEAD requests from AHC.

    if itemsToDownload(downloadableArtifacts).contains(where: {
      $0.remoteURL == downloadableArtifacts.hostLLVM.remoteURL
    }) {
      let isLLVMBinaryArtifactAvailable = try await type(of: client).with(http1Only: true) {
        try await $0.head(
          url: hostLLVMURL.absoluteString,
          headers: ["Accept": "*/*", "User-Agent": "Swift SDK Generator"]
        )
      }

      if !isLLVMBinaryArtifactAvailable {
        downloadableArtifacts.useLLVMSources()
      }
    }

    let results = try await withThrowingTaskGroup(of: FileCacheRecord.self) { group in
      for item in itemsToDownload(downloadableArtifacts) {
        group.addTask {
          try await engine[
            DownloadArtifactQuery(artifact: item, httpClient: client, logger: self.logger)]
        }
      }

      var result = [FileCacheRecord]()
      for try await file in group {
        result.append(file)
      }
      return result
    }

    logger.info("Using downloaded artifacts from cache")
    logger.debug(
      "Using downloaded artifacts in these locations.",
      metadata: [
        "paths": .array(results.map(\.path.metadataValue))
      ])
  }

  func getMirrorURL(for linuxDistribution: LinuxDistribution) throws -> String {
    if linuxDistribution.name == .ubuntu {
      if targetTriple.arch == .x86_64 {
        return ubuntuMainMirror
      } else {
        return ubuntuPortsMirror
      }
    } else if linuxDistribution.name == .debian {
      return debianMirror
    } else {
      throw GeneratorError.distributionSupportsOnlyDockerGenerator(linuxDistribution)
    }
  }

  func packagesFileName(isXzAvailable: Bool) -> String {
    if isXzAvailable {
      return "Packages.xz"
    }
    // Use .gz if xz is not available
    return "Packages.gz"
  }

  func downloadDebianPackages(
    _ client: some HTTPClientProtocol,
    _ engine: QueryEngine,
    requiredPackages: [String],
    versionsConfiguration: VersionsConfiguration,
    sdkDirPath: FilePath
  ) async throws {
    let mirrorURL = try getMirrorURL(for: versionsConfiguration.linuxDistribution)
    let distributionName = versionsConfiguration.linuxDistribution.name
    let distributionRelease = versionsConfiguration.linuxDistribution.release

    // Find xz path
    let xzPath = try await which("xz")
    if xzPath == nil {
      // If we don't have xz, it's required for Packages.xz for debian
      if distributionName == .debian {
        throw GeneratorError.debianPackagesListDownloadRequiresXz
      }

      logger.warning(
        """
        The `xz` utility was not found in `PATH`. \
        Consider installing it for more efficient downloading of package lists.
        """)
    }

    logger.info(
      "Downloading and parsing packages lists...",
      metadata: [
        "distributionName": .stringConvertible(distributionName),
        "distributionRelease": .string(distributionRelease),
      ])

    let allPackages = try await withThrowingTaskGroup(of: [String: URL].self) { group in
      group.addTask {
        return try await self.parseDebianPackageList(
          using: client,
          mirrorURL: mirrorURL,
          release: distributionRelease,
          releaseSuffix: "",
          repository: "main",
          targetTriple: self.targetTriple,
          xzPath: xzPath
        )
      }
      group.addTask {
        return try await self.parseDebianPackageList(
          using: client,
          mirrorURL: mirrorURL,
          release: distributionRelease,
          releaseSuffix: "-updates",
          repository: "main",
          targetTriple: self.targetTriple,
          xzPath: xzPath
        )
      }
      if distributionName == .ubuntu {
        group.addTask {
          return try await self.parseDebianPackageList(
            using: client,
            mirrorURL: mirrorURL,
            release: distributionRelease,
            releaseSuffix: "-updates",
            repository: "universe",
            targetTriple: self.targetTriple,
            xzPath: xzPath
          )
        }
      }

      var packages: [String: URL] = [String: URL]()
      for try await result in group {
        packages.merge(result, uniquingKeysWith: { $1 })
      }
      return packages
    }

    let urls = requiredPackages.compactMap { allPackages[$0] }

    guard urls.count == requiredPackages.count else {
      throw GeneratorError.packagesListParsingFailure(
        expectedPackages: requiredPackages.count,
        actual: urls.count
      )
    }

    logger.info(
      "Downloading packages...",
      metadata: [
        "distributionName": .stringConvertible(distributionName),
        "packageCount": .stringConvertible(urls.count),
      ])
    try await inTemporaryDirectory { fs, tmpDir in
      let downloadedFiles = try await self.downloadFiles(from: urls, to: tmpDir, client, engine)
      await report(downloadedFiles: downloadedFiles)

      for fileName in urls.map(\.lastPathComponent) {
        logger.debug("Extracting deb package...", metadata: ["fileName": .string(fileName)])
        try await fs.unpack(file: tmpDir.appending(fileName), into: sdkDirPath)
      }
    }
  }

  private func parseDebianPackageList(
    using client: HTTPClientProtocol,
    mirrorURL: String,
    release: String,
    releaseSuffix: String,
    repository: String,
    targetTriple: Triple,
    xzPath: String?
  ) async throws -> [String: URL] {
    var contextLogger = logger

    let packagesListURL = """
      \(mirrorURL)/dists/\(release)\(releaseSuffix)/\(repository)/binary-\(
      targetTriple.arch!.debianConventionName
      )/\(packagesFileName(isXzAvailable: xzPath != nil))
      """
    contextLogger[metadataKey: "packagesListURL"] = .string(packagesListURL)

    contextLogger.debug("Downloading packages list...")
    guard
      let packages = try await client.downloadDebianPackagesList(
        from: packagesListURL,
        unzipWith: xzPath ?? "/usr/bin/gzip",  // fallback on gzip if xz not available
        logger: logger
      )
    else {
      throw GeneratorError.packagesListDecompressionFailure
    }

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
    }

    contextLogger.debug("Processing packages list...")
    var result = [String: URL]()
    for match in packages.matches(of: regex) {
      guard let url = URL(string: "\(mirrorURL)/\(match[pathRef])") else { continue }

      result[String(match[packageRef])] = url
    }

    return result
  }

  func downloadFiles(
    from urls: [URL],
    to directory: FilePath,
    _ client: some HTTPClientProtocol,
    _ engine: QueryEngine
  ) async throws -> [(URL, UInt64)] {
    try await withThrowingTaskGroup(of: (URL, UInt64).self) {
      for url in urls {
        $0.addTask {
          let downloadedFilePath = try await engine[
            DownloadFileQuery(
              remoteURL: url, localDirectory: directory, httpClient: client
            )]
          let filePath = downloadedFilePath.path
          guard
            let fileSize = try FileManager.default.attributesOfItem(
              atPath: filePath.string
            )[.size] as? UInt64
          else {
            throw GeneratorError.fileDoesNotExist(filePath)
          }
          return (url, fileSize)
        }
      }

      var result = [(URL, UInt64)]()
      for try await progress in $0 {
        result.append(progress)
      }
      return result
    }
  }

  private func report(downloadedFiles: [(URL, UInt64)]) {
    let byteCountFormatter = ByteCountFormatter()

    for (url, bytes) in downloadedFiles {
      logger.debug(
        "Downloaded package",
        metadata: [
          "url": .string(url.absoluteString),
          "size": .string(byteCountFormatter.string(fromByteCount: Int64(bytes))),
        ])
    }
  }
}

extension HTTPClientProtocol {
  func downloadDebianPackagesList(
    from url: String,
    unzipWith zipPath: String,
    logger: Logger
  ) async throws -> String? {
    guard let packages = try await get(url: url).body?.unzip(zipPath: zipPath, logger: logger)
    else {
      throw FileOperationError.downloadFailed(url)
    }

    return String(buffer: packages)
  }
}
