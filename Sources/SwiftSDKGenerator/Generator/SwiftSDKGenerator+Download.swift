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

private let ubuntuAMD64Mirror = "http://gb.archive.ubuntu.com/ubuntu"
private let ubuntuARM64Mirror = "http://ports.ubuntu.com/ubuntu-ports"

extension FilePath {
  var metadataValue: Logger.MetadataValue {
    .string(self.string)
  }
}

extension SwiftSDKGenerator {
  func downloadArtifacts(
    _ client: some HTTPClientProtocol,
    _ engine: QueryEngine,
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
            DownloadArtifactQuery(artifact: item, httpClient: client, logger: self.logger)
          ]
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
      ]
    )
  }

  func downloadUbuntuPackages(
    _ client: some HTTPClientProtocol,
    _ engine: QueryEngine,
    requiredPackages: [String],
    versionsConfiguration: VersionsConfiguration,
    sdkDirPath: FilePath
  ) async throws {
    logger.debug("Parsing Ubuntu packages list...")

    // Find xz path
    let xzPath = try await which("xz")
    if xzPath == nil {
      logger.warning(
        """
        The `xz` utility was not found in `PATH`. \
        Consider installing it for more efficient downloading of package lists.
        """
      )
    }

    async let mainPackages = try await client.parseUbuntuPackagesList(
      ubuntuRelease: versionsConfiguration.linuxDistribution.release,
      repository: "main",
      targetTriple: self.targetTriple,
      isVerbose: self.isVerbose,
      xzPath: xzPath
    )

    async let updatesPackages = try await client.parseUbuntuPackagesList(
      ubuntuRelease: versionsConfiguration.linuxDistribution.release,
      releaseSuffix: "-updates",
      repository: "main",
      targetTriple: self.targetTriple,
      isVerbose: self.isVerbose,
      xzPath: xzPath
    )

    async let universePackages = try await client.parseUbuntuPackagesList(
      ubuntuRelease: versionsConfiguration.linuxDistribution.release,
      releaseSuffix: "-updates",
      repository: "universe",
      targetTriple: self.targetTriple,
      isVerbose: self.isVerbose,
      xzPath: xzPath
    )

    let allPackages =
      try await mainPackages
      .merging(updatesPackages, uniquingKeysWith: { $1 })
      .merging(universePackages, uniquingKeysWith: { $1 })

    let urls = requiredPackages.compactMap { allPackages[$0] }

    guard urls.count == requiredPackages.count else {
      throw GeneratorError.ubuntuPackagesParsingFailure(
        expectedPackages: requiredPackages.count,
        actual: urls.count
      )
    }

    logger.info(
      "Downloading Ubuntu packages...",
      metadata: ["packageCount": .stringConvertible(urls.count)]
    )
    try await inTemporaryDirectory { fs, tmpDir in
      let downloadedFiles = try await self.downloadFiles(from: urls, to: tmpDir, client, engine)
      await report(downloadedFiles: downloadedFiles)

      for fileName in urls.map(\.lastPathComponent) {
        logger.debug("Extracting deb package...", metadata: ["fileName": .string(fileName)])
        try await fs.unpack(file: tmpDir.appending(fileName), into: sdkDirPath)
      }
    }

    // Make sure we have /lib and /lib64, and if not symlink from /usr
    // This makes building from packages more consistent with copying from the Docker container
    let libDirectories = ["lib", "lib64"]
    for dir in libDirectories {
      let sdkLibPath = sdkDirPath.appending(dir)
      let sdkUsrLibPath = sdkDirPath.appending("usr/\(dir)")
      if !doesFileExist(at: sdkLibPath) && doesFileExist(at: sdkUsrLibPath) {
        try createSymlink(at: sdkLibPath, pointingTo: FilePath("./usr/\(dir)"))
      }
    }
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
              remoteURL: url,
              localDirectory: directory,
              httpClient: client
            )
          ]
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
        ]
      )
    }
  }
}

extension HTTPClientProtocol {
  private func downloadUbuntuPackagesList(
    from url: String,
    unzipWith zipPath: String,
    isVerbose: Bool
  ) async throws -> String? {
    guard let packages = try await get(url: url).body?.unzip(zipPath: zipPath, isVerbose: isVerbose)
    else {
      throw FileOperationError.downloadFailed(url)
    }

    return String(buffer: packages)
  }

  func packagesFileName(isXzAvailable: Bool) -> String {
    if isXzAvailable {
      return "Packages.xz"
    }
    // Use .gz if xz is not available
    return "Packages.gz"
  }

  func parseUbuntuPackagesList(
    ubuntuRelease: String,
    releaseSuffix: String = "",
    repository: String,
    targetTriple: Triple,
    isVerbose: Bool,
    xzPath: String?
  ) async throws -> [String: URL] {
    let mirrorURL: String
    if targetTriple.arch == .x86_64 {
      mirrorURL = ubuntuAMD64Mirror
    } else {
      mirrorURL = ubuntuARM64Mirror
    }

    let packagesListURL = """
      \(mirrorURL)/dists/\(ubuntuRelease)\(releaseSuffix)/\(repository)/binary-\(
        targetTriple.arch!.debianConventionName
      )/\(packagesFileName(isXzAvailable: xzPath != nil))
      """

    guard
      let packages = try await downloadUbuntuPackagesList(
        from: packagesListURL,
        unzipWith: xzPath ?? "/usr/bin/gzip",  // fallback on gzip if xz not available
        isVerbose: isVerbose
      )
    else {
      throw GeneratorError.ubuntuPackagesDecompressionFailure
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
