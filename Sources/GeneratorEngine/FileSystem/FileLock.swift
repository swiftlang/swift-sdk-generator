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

import Foundation
import SystemPackage

enum ProcessLockError: Error {
  case unableToAquireLock(errno: Int32)
}

extension ProcessLockError: CustomNSError {
  public var errorUserInfo: [String: Any] {
    [NSLocalizedDescriptionKey: "\(self)"]
  }
}

/// Provides functionality to acquire a lock on a file via POSIX's flock() method.
/// It can be used for things like serializing concurrent mutations on a shared resource
/// by multiple instances of a process. The `FileLock` is not thread-safe.
final class FileLock {
  enum LockType {
    case exclusive
    case shared
  }

  enum Error: Swift.Error {
    case noEntry(FilePath)
    case notDirectory(FilePath)
    case errno(Int32, FilePath)
  }

  /// File descriptor to the lock file.
  #if os(Windows)
  private var handle: HANDLE?
  #else
  private var fileDescriptor: CInt?
  #endif

  /// Path to the lock file.
  private let lockFile: FilePath

  /// Create an instance of FileLock at the path specified
  ///
  /// Note: The parent directory path should be a valid directory.
  init(at lockFile: FilePath) {
    self.lockFile = lockFile
  }

  /// Try to acquire a lock. This method will block until lock the already aquired by other process.
  ///
  /// Note: This method can throw if underlying POSIX methods fail.
  func lock(type: LockType = .exclusive) throws {
    #if os(Windows)
    if self.handle == nil {
      let h: HANDLE = self.lockFile.pathString.withCString(encodedAs: UTF16.self) {
        CreateFileW(
          $0,
          UInt32(GENERIC_READ) | UInt32(GENERIC_WRITE),
          UInt32(FILE_SHARE_READ) | UInt32(FILE_SHARE_WRITE),
          nil,
          DWORD(OPEN_ALWAYS),
          DWORD(FILE_ATTRIBUTE_NORMAL),
          nil
        )
      }
      if h == INVALID_HANDLE_VALUE {
        throw FileSystemError(errno: Int32(GetLastError()), self.lockFile)
      }
      self.handle = h
    }
    var overlapped = OVERLAPPED()
    overlapped.Offset = 0
    overlapped.OffsetHigh = 0
    overlapped.hEvent = nil
    switch type {
    case .exclusive:
      if !LockFileEx(
        self.handle,
        DWORD(LOCKFILE_EXCLUSIVE_LOCK),
        0,
        UInt32.max,
        UInt32.max,
        &overlapped
      ) {
        throw ProcessLockError.unableToAquireLock(errno: Int32(GetLastError()))
      }
    case .shared:
      if !LockFileEx(
        self.handle,
        0,
        0,
        UInt32.max,
        UInt32.max,
        &overlapped
      ) {
        throw ProcessLockError.unableToAquireLock(errno: Int32(GetLastError()))
      }
    }
    #else
    // Open the lock file.
    if self.fileDescriptor == nil {
      let fd = try FileDescriptor.open(
        self.lockFile,
        .writeOnly,
        options: [.create, .closeOnExec],
        permissions: [.groupReadWrite, .ownerReadWrite, .otherReadWrite]
      ).rawValue
      if fd == -1 {
        throw Error.errno(errno, self.lockFile)
      }
      self.fileDescriptor = fd
    }
    // Aquire lock on the file.
    while true {
      if type == .exclusive && flock(self.fileDescriptor!, LOCK_EX) == 0 {
        break
      } else if type == .shared && flock(self.fileDescriptor!, LOCK_SH) == 0 {
        break
      }
      // Retry if interrupted.
      if errno == EINTR { continue }
      throw ProcessLockError.unableToAquireLock(errno: errno)
    }
    #endif
  }

  /// Unlock the held lock.
  public func unlock() {
    #if os(Windows)
    var overlapped = OVERLAPPED()
    overlapped.Offset = 0
    overlapped.OffsetHigh = 0
    overlapped.hEvent = nil
    UnlockFileEx(self.handle, 0, UInt32.max, UInt32.max, &overlapped)
    #else
    guard let fd = fileDescriptor else { return }
    flock(fd, LOCK_UN)
    #endif
  }

  deinit {
    #if os(Windows)
    guard let handle else { return }
    CloseHandle(handle)
    #else
    guard let fd = fileDescriptor else { return }
    close(fd)
    #endif
  }

  /// Execute the given block while holding the lock.
  private func withLock<T>(type: LockType = .exclusive, _ body: () throws -> T) throws -> T {
    try self.lock(type: type)
    defer { unlock() }
    return try body()
  }

  /// Execute the given block while holding the lock.
  private func withLock<T>(type: LockType = .exclusive, _ body: () async throws -> T) async throws -> T {
    try self.lock(type: type)
    defer { unlock() }
    return try await body()
  }

  private static func prepareLock(
    fileToLock: FilePath,
    at lockFilesDirectory: FilePath? = nil,
    _ type: LockType = .exclusive
  ) throws -> FileLock {
    let fm = FileManager.default

    // unless specified, we use the tempDirectory to store lock files
    let lockFilesDirectory = lockFilesDirectory ?? FilePath(fm.temporaryDirectory.path)
    var isDirectory: ObjCBool = false
    if !fm.fileExists(atPath: lockFilesDirectory.string, isDirectory: &isDirectory) {
      throw Error.noEntry(lockFilesDirectory)
    }
    if !isDirectory.boolValue {
      throw Error.notDirectory(lockFilesDirectory)
    }
    // use the parent path to generate unique filename in temp
    var lockFileName =
      (
        FilePath(URL(string: fileToLock.removingLastComponent().string)!.resolvingSymlinksInPath().path)
          .appending(fileToLock.lastComponent!)
      )
      .components.map(\.string).joined(separator: "_")
      .replacingOccurrences(of: ":", with: "_") + ".lock"
    #if os(Windows)
    // NTFS has an ARC limit of 255 codepoints
    var lockFileUTF16 = lockFileName.utf16.suffix(255)
    while String(lockFileUTF16) == nil {
      lockFileUTF16 = lockFileUTF16.dropFirst()
    }
    lockFileName = String(lockFileUTF16) ?? lockFileName
    #else
    // back off until it occupies at most `NAME_MAX` UTF-8 bytes but without splitting scalars
    // (we might split clusters but it's not worth the effort to keep them together as long as we get a valid file name)
    var lockFileUTF8 = lockFileName.utf8.suffix(Int(NAME_MAX))
    while String(lockFileUTF8) == nil {
      // in practice this will only be a few iterations
      lockFileUTF8 = lockFileUTF8.dropFirst()
    }
    // we will never end up with nil since we have ASCII characters at the end
    lockFileName = String(lockFileUTF8) ?? lockFileName
    #endif
    let lockFilePath = lockFilesDirectory.appending(lockFileName)

    return FileLock(at: lockFilePath)
  }

  static func withLock<T>(
    fileToLock: FilePath,
    lockFilesDirectory: FilePath? = nil,
    type: LockType = .exclusive,
    body: () throws -> T
  ) throws -> T {
    let lock = try Self.prepareLock(fileToLock: fileToLock, at: lockFilesDirectory, type)
    return try lock.withLock(type: type, body)
  }

  static func withLock<T>(
    fileToLock: FilePath,
    lockFilesDirectory: FilePath? = nil,
    type: LockType = .exclusive,
    body: () async throws -> T
  ) async throws -> T {
    let lock = try Self.prepareLock(fileToLock: fileToLock, at: lockFilesDirectory, type)
    return try await lock.withLock(type: type, body)
  }
}
