//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2021-2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
import Logging
import SystemPackage

/// SQLite backed persistent cache.
final class SQLiteBackedCache {
  typealias Key = String

  let tableName: String
  let location: SQLite.Location
  let configuration: Configuration
  private let logger: Logger

  private var state = State.idle

  private let jsonEncoder: JSONEncoder
  private let jsonDecoder: JSONDecoder

  /// Creates a SQLite-backed cache.
  ///
  /// - Parameters:
  ///   - tableName: The SQLite table name. Must follow SQLite naming rules (e.g., no spaces).
  ///   - location: SQLite.Location
  ///   - configuration: Optional. Configuration for the cache.
  init(
    tableName: String,
    location: SQLite.Location,
    configuration: Configuration = .init(),
    _ logger: Logger
  ) {
    self.tableName = tableName
    self.location = location
    self.logger = logger
    self.configuration = configuration
    self.jsonEncoder = JSONEncoder()
    self.jsonDecoder = JSONDecoder()
  }

  deinit {
    try? self.withStateLock {
      if case let .connected(db) = self.state {
        // TODO: we could wrap the failure here with diagnostics if it was available
        assertionFailure("db should be closed")
        try db.close()
      }
    }
  }

  public func close() throws {
    try self.withStateLock {
      if case let .connected(db) = self.state {
        try db.close()
      }
      self.state = .disconnected
    }
  }

  private func put(
    key: some Sequence<UInt8>,
    value: some Codable,
    replace: Bool = false
  ) throws {
    do {
      let query = "INSERT OR \(replace ? "REPLACE" : "IGNORE") INTO \(self.tableName) VALUES (?, ?);"
      try self.executeStatement(query) { statement in
        let data = try self.jsonEncoder.encode(value)
        let bindings: [SQLite.SQLiteValue] = [
          .blob(Data(key)),
          .blob(data),
        ]
        try statement.bind(bindings)
        try statement.step()
      }
    } catch let error as SQLite.Error where error == .databaseFull {
      if !self.configuration.truncateWhenFull {
        throw error
      }
      self.logger.warning(
        "truncating \(self.tableName) cache database since it reached max size of \(self.configuration.maxSizeInBytes ?? 0) bytes"
      )
      try self.executeStatement("DELETE FROM \(self.tableName);") { statement in
        try statement.step()
      }
      try self.put(key: key, value: value, replace: replace)
    } catch {
      throw error
    }
  }

  func get<Value: Codable>(_ key: some Sequence<UInt8>, as: Value.Type) throws -> Value? {
    let query = "SELECT value FROM \(self.tableName) WHERE key = ? LIMIT 1;"
    return try self.executeStatement(query) { statement -> Value? in
      try statement.bind([.blob(Data(key))])
      let data = try statement.step()?.blob(at: 0)
      return try data.flatMap {
        try self.jsonDecoder.decode(Value.self, from: $0)
      }
    }
  }

  func set(_ key: some Sequence<UInt8>, to value: some Codable) throws {
    try self.put(key: key, value: value, replace: true)
  }

  func remove(key: Key) throws {
    let query = "DELETE FROM \(self.tableName) WHERE key = ?;"
    try self.executeStatement(query) { statement in
      try statement.bind([.string(key)])
      try statement.step()
    }
  }

  @discardableResult
  private func executeStatement<T>(_ query: String, _ body: (SQLite.PreparedStatement) throws -> T) throws -> T {
    try self.withDB { db in
      let result: Result<T, Error>
      let statement = try db.prepare(query: query)
      do {
        result = try .success(body(statement))
      } catch {
        result = .failure(error)
      }
      try statement.finalize()
      switch result {
      case let .failure(error):
        throw error
      case let .success(value):
        return value
      }
    }
  }

  private func withDB<T>(_ body: (SQLite) throws -> T) throws -> T {
    let createDB = { () throws -> SQLite in
      let db = try SQLite(location: self.location, configuration: self.configuration.underlying)
      try self.createSchemaIfNecessary(db: db)
      return db
    }

    let db: SQLite
    let fm = FileManager.default
    switch (self.location, self.state) {
    case let (.path(path), .connected(database)):
      if fm.fileExists(atPath: path.string) {
        db = database
      } else {
        try database.close()
        try fm.createDirectory(atPath: path.removingLastComponent().string, withIntermediateDirectories: true)
        db = try createDB()
      }
    case let (.path(path), _):
      if !fm.fileExists(atPath: path.string) {
        try fm.createDirectory(atPath: path.removingLastComponent().string, withIntermediateDirectories: true)
      }
      db = try createDB()
    case let (_, .connected(database)):
      db = database
    case (_, _):
      db = try createDB()
    }
    self.state = .connected(db)
    return try body(db)
  }

  private func createSchemaIfNecessary(db: SQLite) throws {
    let table = """
        CREATE TABLE IF NOT EXISTS \(self.tableName) (
            key STRING PRIMARY KEY NOT NULL,
            value BLOB NOT NULL
        );
    """

    try db.exec(query: table)
    try db.exec(query: "PRAGMA journal_mode=WAL;")
  }

  private func withStateLock<T>(_ body: () throws -> T) throws -> T {
    switch self.location {
    case let .path(path):
      let fm = FileManager.default
      if !fm.fileExists(atPath: path.string) {
        try fm.createDirectory(atPath: path.removingLastComponent().string, withIntermediateDirectories: true)
      }

      return try FileLock.withLock(fileToLock: path, body: body)
    case .memory, .temporary:
      return try body()
    }
  }

  private enum State {
    case idle
    case connected(SQLite)
    case disconnected
  }

  public struct Configuration {
    var truncateWhenFull: Bool

    fileprivate var underlying: SQLite.Configuration

    init() {
      self.underlying = .init()
      self.truncateWhenFull = true
      self.maxSizeInMegabytes = 100
      // see https://www.sqlite.org/c3ref/busy_timeout.html
      self.busyTimeoutMilliseconds = 1000
    }

    var maxSizeInMegabytes: Int? {
      get {
        self.underlying.maxSizeInMegabytes
      }
      set {
        self.underlying.maxSizeInMegabytes = newValue
      }
    }

    var maxSizeInBytes: Int? {
      get {
        self.underlying.maxSizeInBytes
      }
      set {
        self.underlying.maxSizeInBytes = newValue
      }
    }

    var busyTimeoutMilliseconds: Int32 {
      get {
        self.underlying.busyTimeoutMilliseconds
      }
      set {
        self.underlying.busyTimeoutMilliseconds = newValue
      }
    }
  }
}

// Explicitly mark this class as non-Sendable
@available(*, unavailable)
extension SQLiteBackedCache: Sendable {}
