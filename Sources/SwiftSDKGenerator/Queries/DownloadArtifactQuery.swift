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

import GeneratorEngine
import struct SystemPackage.FilePath

struct DownloadArtifactQuery: Query {
  var cacheKey: some CacheKey { artifact }
  let artifact: DownloadableArtifacts.Item
  let httpClient: any HTTPClientProtocol

  func run(engine: Engine) async throws -> FilePath {
    print("Downloading remote artifact not available in local cache: \(self.artifact.remoteURL)")
    let stream = httpClient.streamDownloadProgress(
      from: self.artifact.remoteURL, to: self.artifact.localPath
    )
      .removeDuplicates(by: didProgressChangeSignificantly)
      ._throttle(for: .seconds(1))

    for try await progress in stream {
      report(progress: progress, for: artifact)
    }
    return self.artifact.localPath
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
  previous: DownloadProgress,
  current: DownloadProgress
) -> Bool {
  guard previous.totalBytes == current.totalBytes else {
    return true
  }

  return current.receivedBytes - previous.receivedBytes > 1024 * 1024 * 1024
}

private func report(progress: DownloadProgress, for artifact: DownloadableArtifacts.Item) {
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
