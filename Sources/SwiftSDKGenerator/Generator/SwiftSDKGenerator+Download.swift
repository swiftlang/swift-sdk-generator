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
import AsyncHTTPClient
import GeneratorEngine
import RegexBuilder

import class Foundation.ByteCountFormatter
import struct Foundation.URL

import struct SystemPackage.FilePath

private let ubuntuAMD64Mirror = "http://gb.archive.ubuntu.com/ubuntu"
private let ubuntuARM64Mirror = "http://ports.ubuntu.com/ubuntu-ports"

private let byteCountFormatter = ByteCountFormatter()

@Query
struct DownloadQuery {
  let artifact: DownloadableArtifacts.Item

  func run(engine: Engine) async throws -> FilePath {
    print("Downloading remote artifact not available in local cache: \(self.artifact.remoteURL)")
    let stream = await engine.httpClient.streamDownloadProgress(for: self.artifact)
      .removeDuplicates(by: didProgressChangeSignificantly)
      .throttle(for: .seconds(1))

    for try await item in stream {
      report(progress: item.progress, for: item.artifact)
    }
    return self.artifact.localPath
  }
}

extension SwiftSDKGenerator {
  func downloadArtifacts(_ client: HTTPClient) async throws {
    logGenerationStep("Downloading required toolchain packages...")
    var headRequest = HTTPClientRequest(url: downloadableArtifacts.hostLLVM.remoteURL.absoluteString)
    headRequest.method = .HEAD
    headRequest.headers = ["Accept": "*/*", "User-Agent": "Swift SDK Generator"]
    let isLLVMBinaryArtifactAvailable = try await client.execute(headRequest, deadline: .distantFuture)
      .status == .ok

    if !isLLVMBinaryArtifactAvailable {
      downloadableArtifacts.useLLVMSources()
    }

    let results = try await withThrowingTaskGroup(of: FileCacheRecord.self) { group in
      for item in self.downloadableArtifacts.allItems {
        print(item.remoteURL)
        group.addTask {
          try await self.engine[DownloadQuery(artifact: item)]
        }
      }

      var result = [FileCacheRecord]()
      for try await file in group {
        result.append(file)
      }
      return result
    }
  }

  func downloadUbuntuPackages(_ client: HTTPClient, requiredPackages: [String]) async throws {
    logGenerationStep("Parsing Ubuntu packages list...")

    async let mainPackages = try await client.parseUbuntuPackagesList(
      ubuntuRelease: self.versionsConfiguration.linuxDistribution.release,
      repository: "main",
      targetTriple: self.targetTriple,
      isVerbose: self.isVerbose
    )

    async let updatesPackages = try await client.parseUbuntuPackagesList(
      ubuntuRelease: self.versionsConfiguration.linuxDistribution.release,
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

/// Checks whether two given progress value are different enough from each other. Used for filtering out progress
/// values in async streams with `removeDuplicates` operator.
/// - Parameters:
///   - previous: Preceding progress value in the stream.
///   - current: Currently processed progress value in the stream.
/// - Returns: `true` if `totalBytes` value is different by any amount or if `receivedBytes` is different by amount
/// larger than 1MiB. Returns `false` otherwise.
@Sendable
private func didProgressChangeSignificantly(
  previous: ArtifactDownloadProgress,
  current: ArtifactDownloadProgress
) -> Bool {
  guard previous.progress.totalBytes == current.progress.totalBytes else {
    return true
  }

  return current.progress.receivedBytes - previous.progress.receivedBytes > 1024 * 1024 * 1024
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
