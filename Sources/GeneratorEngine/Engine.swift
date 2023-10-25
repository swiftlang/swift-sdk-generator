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

import class AsyncHTTPClient.HTTPClient
@_exported import Crypto
import struct Logging.Logger
@_exported import struct SystemPackage.FilePath

/// Cacheable computations engine. Currently the engine makes an assumption that computations produce same results for
/// the same query values and write results to a single file path.
public actor Engine {
  private(set) var cacheHits = 0
  private(set) var cacheMisses = 0

  public let fileSystem: any FileSystem
  public let httpClient: HTTPClient
  public let logger: Logger
  private let resultsCache: SQLiteBackedCache

  /// Creates a new instance of the ``Engine`` actor.
  /// - Parameter fileSystem: Implementation of a file system this engine should use.
  /// - Parameter cacheLocation: Location of cache storage used by the engine.
  /// - Parameter httpClient: HTTP client to use in queries that need it.
  /// - Parameter logger: Logger to use during queries execution.
  public init(
    _ fileSystem: any FileSystem,
    _ httpClient: HTTPClient,
    _ logger: Logger,
    cacheLocation: SQLite.Location
  ) {
    self.fileSystem = fileSystem
    self.httpClient = httpClient
    self.logger = logger
    self.resultsCache = SQLiteBackedCache(tableName: "cache_table", location: cacheLocation, logger)
  }

  deinit {
    try! resultsCache.close()
  }

  /// Executes a given query if no cached result of it is available. Otherwise fetches the result from engine's cache.
  /// - Parameter query: A query value to execute.
  /// - Returns: A file path to query's result recorded in a file.
  public subscript(_ query: some QueryProtocol) -> FilePath {
    get async throws {
      var hashFunction = SHA512()
      query.hash(with: &hashFunction)
      let key = hashFunction.finalize().description

      if let fileRecord = try resultsCache.get(key, as: FileCacheRecord.self) {
        hashFunction = SHA512()
        try await self.fileSystem.hash(fileRecord.path, with: &hashFunction)
        let fileHash = hashFunction.finalize().description

        if fileHash == fileRecord.hash {
          self.cacheHits += 1
          return fileRecord.path
        }
      }

      self.cacheMisses += 1
      let resultPath = try await query.run(engine: self)
      hashFunction = SHA512()
      try await self.fileSystem.hash(resultPath, with: &hashFunction)
      let resultHash = hashFunction.finalize().description

      try self.resultsCache.set(key, to: FileCacheRecord(path: resultPath, hash: resultHash))

      return resultPath
    }
  }
}
