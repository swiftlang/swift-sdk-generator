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

import Foundation
import Helpers
import NIOCore
import NIOHTTP1
import SystemPackage

public struct DownloadProgress: Sendable {
  public var totalBytes: Int?
  public var receivedBytes: Int
}

public protocol HTTPClientProtocol: Sendable {
  /// Perform an operation with a new HTTP client.
  /// NOTE: The client will be shutdown after the operation completes, so it
  /// should not be stored or used outside of the operation.
  static func with<Result: Sendable>(
    http1Only: Bool, _ body: @Sendable (any HTTPClientProtocol) async throws -> Result
  ) async throws -> Result

  /// Download a file from the given URL to the given path.
  func downloadFile(
    from url: URL,
    to path: FilePath
  ) async throws

  /// Download a file from the given URL to the given path and report download
  /// progress as a stream.
  func streamDownloadProgress(
    from url: URL,
    to path: FilePath
  ) -> AsyncThrowingStream<DownloadProgress, any Error>

  /// Perform GET request to the given URL.
  func get(url: String) async throws -> (
    status: NIOHTTP1.HTTPResponseStatus,
    body: ByteBuffer?
  )
  /// Perform HEAD request to the given URL.
  /// - Returns: `true` if the request returns a 200 status code, `false` otherwise.
  func head(url: String, headers: NIOHTTP1.HTTPHeaders) async throws -> Bool
}

extension HTTPClientProtocol {
  static func with<Result: Sendable>(
    _ body: @Sendable (any HTTPClientProtocol) async throws -> Result
  ) async throws
    -> Result
  {
    try await self.with(http1Only: false, body)
  }
}

extension FilePath: @unchecked Sendable {}

#if canImport(AsyncHTTPClient)
  import AsyncHTTPClient

  extension FileDownloadDelegate.Progress: @unchecked Sendable {}

  extension HTTPClient: HTTPClientProtocol {
    public static func with<Result: Sendable>(
      http1Only: Bool, _ body: @Sendable (any HTTPClientProtocol) async throws -> Result
    ) async throws -> Result {
      var configuration = HTTPClient.Configuration(
        redirectConfiguration: .follow(max: 5, allowCycles: false))
      if http1Only {
        configuration.httpVersion = .http1Only
      }
      let client = HTTPClient(eventLoopGroupProvider: .singleton, configuration: configuration)
      return try await withAsyncThrowing {
        try await body(client)
      } defer: {
        try await client.shutdown()
      }
    }

    public func get(url: String) async throws -> (
      status: NIOHTTP1.HTTPResponseStatus, body: NIOCore.ByteBuffer?
    ) {
      let response = try await self.get(url: url).get()
      return (status: response.status, body: response.body)
    }

    public func head(url: String, headers: NIOHTTP1.HTTPHeaders) async throws -> Bool {
      var headRequest = HTTPClientRequest(url: url)
      headRequest.method = .HEAD
      headRequest.headers = ["Accept": "*/*", "User-Agent": "Swift SDK Generator"]
      return try await self.execute(headRequest, deadline: .distantFuture).status == .ok
    }

    public func downloadFile(
      from url: URL,
      to path: FilePath
    ) async throws {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(), Error>) in
        do {
          let delegate = try FileDownloadDelegate(
            path: path.string,
            reportHead: { task, responseHead in
              if responseHead.status != .ok {
                task.fail(
                  reason: GeneratorError.fileDownloadFailed(url, responseHead.status.description))
              }
            }
          )
          let request = try HTTPClient.Request(url: url)

          execute(request: request, delegate: delegate).futureResult.whenComplete {
            switch $0 {
            case let .failure(error):
              continuation.resume(throwing: error)
            case .success:
              continuation.resume(returning: ())
            }
          }
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }

    public func streamDownloadProgress(
      from url: URL,
      to path: FilePath
    ) -> AsyncThrowingStream<DownloadProgress, any Error> {
      .init { continuation in
        do {
          let delegate = try FileDownloadDelegate(
            path: path.string,
            reportHead: {
              if $0.status != .ok {
                continuation
                  .finish(throwing: FileOperationError.downloadFailed(url, $0.status.description))
              }
            },
            reportProgress: {
              continuation.yield(
                DownloadProgress(totalBytes: $0.totalBytes, receivedBytes: $0.receivedBytes)
              )
            }
          )
          let request = try HTTPClient.Request(url: url)

          execute(request: request, delegate: delegate).futureResult.whenComplete {
            switch $0 {
            case let .failure(error):
              continuation.finish(throwing: error)
            case let .success(finalProgress):
              continuation.yield(
                DownloadProgress(
                  totalBytes: finalProgress.totalBytes, receivedBytes: finalProgress.receivedBytes)
              )
              continuation.finish()
            }
          }
        } catch {
          continuation.finish(throwing: error)
        }
      }
    }
  }
#endif

struct OfflineHTTPClient: HTTPClientProtocol {
  static func with<Result: Sendable>(
    http1Only: Bool, _ body: @Sendable (any HTTPClientProtocol) async throws -> Result
  ) async throws -> Result {
    let client = OfflineHTTPClient()
    return try await body(client)
  }

  public func downloadFile(from url: URL, to path: SystemPackage.FilePath) async throws {
    throw FileOperationError.downloadFailed(url, "Cannot fetch file with offline client")
  }

  public func streamDownloadProgress(
    from url: URL,
    to path: SystemPackage.FilePath
  ) -> AsyncThrowingStream<DownloadProgress, any Error> {
    AsyncThrowingStream { continuation in
      continuation.finish(
        throwing: FileOperationError.downloadFailed(url, "Cannot fetch file with offline client")
      )
    }
  }

  public func get(url: String) async throws -> (
    status: NIOHTTP1.HTTPResponseStatus, body: NIOCore.ByteBuffer?
  ) {
    throw FileOperationError.downloadFailed(
      URL(string: url)!, "Cannot fetch file with offline client")
  }

  public func head(url: String, headers: NIOHTTP1.HTTPHeaders) async throws -> Bool {
    throw FileOperationError.downloadFailed(
      URL(string: url)!, "Cannot fetch file with offline client")
  }
}
