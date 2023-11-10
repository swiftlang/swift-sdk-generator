//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import struct Foundation.Data
import SystemPackage
import SystemSQLite

extension FilePath: @unchecked Sendable {}
extension FilePath.Component: @unchecked Sendable {}

/// A minimal SQLite wrapper.
public final class SQLite {
  enum Error: Swift.Error, Equatable {
    case databaseFull
    case message(String)
  }

  /// The location of the database.
  let location: Location

  /// The configuration for the database.
  let configuration: Configuration

  /// Pointer to the database.
  let db: OpaquePointer

  /// Create or open the database at the given path.
  ///
  /// The database is opened in serialized mode.
  init(location: Location, configuration: Configuration = Configuration()) throws {
    self.location = location
    self.configuration = configuration

    var handle: OpaquePointer?
    try Self.checkError(
      {
        sqlite3_open_v2(
          location.pathString,
          &handle,
          SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
          nil
        )
      },
      description: "Unable to open database at \(self.location)"
    )

    guard let db = handle else {
      throw Error.message("Unable to open database at \(self.location)")
    }
    self.db = db
    try Self.checkError({ sqlite3_extended_result_codes(db, 1) }, description: "Unable to configure database")
    try Self.checkError(
      { sqlite3_busy_timeout(db, self.configuration.busyTimeoutMilliseconds) },
      description: "Unable to configure database busy timeout"
    )
    if let maxPageCount = self.configuration.maxPageCount {
      try self.exec(query: "PRAGMA max_page_count=\(maxPageCount);")
    }
  }

  /// Prepare the given query.
  func prepare(query: String) throws -> PreparedStatement {
    try PreparedStatement(db: self.db, query: query)
  }

  /// Directly execute the given query.
  ///
  /// Note: Use withCString for string arguments.
  func exec(query queryString: String, args: [CVarArg] = [], _ callback: SQLiteExecCallback? = nil) throws {
    let query = withVaList(args) { ptr in
      sqlite3_vmprintf(queryString, ptr)
    }

    let wcb = callback.map { CallbackWrapper($0) }
    let callbackCtx = wcb.map { Unmanaged.passUnretained($0).toOpaque() }

    var err: UnsafeMutablePointer<Int8>?
    try Self.checkError { sqlite3_exec(self.db, query, sqlite_callback, callbackCtx, &err) }

    sqlite3_free(query)

    if let err {
      let errorString = String(cString: err)
      sqlite3_free(err)
      throw Error.message(errorString)
    }
  }

  func close() throws {
    try Self.checkError { sqlite3_close(self.db) }
  }

  typealias SQLiteExecCallback = ([Column]) -> ()

  struct Configuration {
    var busyTimeoutMilliseconds: Int32
    var maxSizeInBytes: Int?

    // https://www.sqlite.org/pgszchng2016.html
    private let defaultPageSizeInBytes = 1024

    init() {
      self.busyTimeoutMilliseconds = 5000
      self.maxSizeInBytes = .none
    }

    public var maxSizeInMegabytes: Int? {
      get {
        self.maxSizeInBytes.map { $0 / (1024 * 1024) }
      }
      set {
        self.maxSizeInBytes = newValue.map { $0 * 1024 * 1024 }
      }
    }

    public var maxPageCount: Int? {
      self.maxSizeInBytes.map { $0 / self.defaultPageSizeInBytes }
    }
  }

  public enum Location: Sendable {
    case path(FilePath)
    case memory
    case temporary

    var pathString: String {
      switch self {
      case let .path(path):
        path.string
      case .memory:
        ":memory:"
      case .temporary:
        ""
      }
    }
  }

  /// Represents an sqlite value.
  enum SQLiteValue {
    case null
    case string(String)
    case int(Int)
    case blob(Data)
  }

  /// Represents a row returned by called step() on a prepared statement.
  struct Row {
    /// The pointer to the prepared statement.
    let stmt: OpaquePointer

    /// Get integer at the given column index.
    func int(at index: Int32) -> Int {
      Int(sqlite3_column_int64(self.stmt, index))
    }

    /// Get blob data at the given column index.
    func blob(at index: Int32) -> Data {
      let bytes = sqlite3_column_blob(stmt, index)!
      let count = sqlite3_column_bytes(stmt, index)
      return Data(bytes: bytes, count: Int(count))
    }

    /// Get string at the given column index.
    func string(at index: Int32) -> String {
      String(cString: sqlite3_column_text(self.stmt, index))
    }
  }

  struct Column {
    var name: String
    var value: String
  }

  /// Represents a prepared statement.
  struct PreparedStatement {
    typealias sqlite3_destructor_type = @convention(c) (UnsafeMutableRawPointer?) -> ()
    static let SQLITE_STATIC = unsafeBitCast(0, to: sqlite3_destructor_type.self)
    static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// The pointer to the prepared statement.
    let stmt: OpaquePointer

    init(db: OpaquePointer, query: String) throws {
      var stmt: OpaquePointer?
      try SQLite.checkError { sqlite3_prepare_v2(db, query, -1, &stmt, nil) }
      self.stmt = stmt!
    }

    /// Evaluate the prepared statement.
    @discardableResult
    func step() throws -> Row? {
      let result = sqlite3_step(stmt)

      switch result {
      case SQLITE_DONE:
        return nil
      case SQLITE_ROW:
        return Row(stmt: self.stmt)
      default:
        throw Error.message(String(cString: sqlite3_errstr(result)))
      }
    }

    /// Bind the given arguments to the statement.
    func bind(_ arguments: [SQLiteValue]) throws {
      for (idx, argument) in arguments.enumerated() {
        let idx = Int32(idx) + 1
        switch argument {
        case .null:
          try checkError { sqlite3_bind_null(self.stmt, idx) }
        case let .int(int):
          try checkError { sqlite3_bind_int64(self.stmt, idx, Int64(int)) }
        case let .string(str):
          try checkError { sqlite3_bind_text(self.stmt, idx, str, -1, Self.SQLITE_TRANSIENT) }
        case let .blob(blob):
          try checkError {
            blob.withUnsafeBytes { ptr in
              sqlite3_bind_blob(
                self.stmt,
                idx,
                ptr.baseAddress,
                Int32(blob.count),
                Self.SQLITE_TRANSIENT
              )
            }
          }
        }
      }
    }

    /// Reset the prepared statement.
    func reset() throws {
      try SQLite.checkError { sqlite3_reset(self.stmt) }
    }

    /// Clear bindings from the prepared statement.
    func clearBindings() throws {
      try SQLite.checkError { sqlite3_clear_bindings(self.stmt) }
    }

    /// Finalize the statement and free up resources.
    func finalize() throws {
      try SQLite.checkError { sqlite3_finalize(self.stmt) }
    }
  }

  fileprivate class CallbackWrapper {
    var callback: SQLiteExecCallback
    init(_ callback: @escaping SQLiteExecCallback) {
      self.callback = callback
    }
  }

  private static func checkError(_ fn: () -> Int32, description prefix: String? = .none) throws {
    let result = fn()
    if result != SQLITE_OK {
      var description = String(cString: sqlite3_errstr(result))
      switch description.lowercased() {
      case "database or disk is full":
        throw Error.databaseFull
      default:
        if let prefix {
          description = "\(prefix): \(description)"
        }
        throw Error.message(description)
      }
    }
  }
}

// Explicitly mark this class as non-Sendable
@available(*, unavailable)
extension SQLite: Sendable {}

private func sqlite_callback(
  _ ctx: UnsafeMutableRawPointer?,
  _ numColumns: Int32,
  _ columns: UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>?,
  _ columnNames: UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>?
) -> Int32 {
  guard let ctx else { return 0 }
  guard let columnNames, let columns else { return 0 }
  let numColumns = Int(numColumns)
  var result: [SQLite.Column] = []

  for idx in 0..<numColumns {
    var name = ""
    if let ptr = columnNames.advanced(by: idx).pointee {
      name = String(cString: ptr)
    }
    var value = ""
    if let ptr = columns.advanced(by: idx).pointee {
      value = String(cString: ptr)
    }
    result.append(SQLite.Column(name: name, value: value))
  }

  let wcb = Unmanaged<SQLite.CallbackWrapper>.fromOpaque(ctx).takeUnretainedValue()
  wcb.callback(result)

  return 0
}
