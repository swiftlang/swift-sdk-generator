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

import SystemPackage

public actor LocalFileSystem: FileSystem {
  public static let defaultChunkSize = 512 * 1024

  let readChunkSize: Int

  public init(readChunkSize: Int = defaultChunkSize) {
    self.readChunkSize = readChunkSize
  }

  public func withOpenReadableFile<T>(
    _ path: FilePath,
    _ body: (OpenReadableFile) async throws -> T
  ) async throws -> T {
    let fd = try FileDescriptor.open(path, .readOnly)
    // Can't use ``FileDescriptor//closeAfter` here, as that doesn't support async closures.
    do {
      let result = try await body(.init(readChunkSize: readChunkSize, fileHandle: .local(fd)))
      try fd.close()
      return result
    } catch {
      try fd.close()
      throw error.attach(path: path)
    }
  }

  public func withOpenWritableFile<T>(
    _ path: SystemPackage.FilePath,
    _ body: (OpenWritableFile) async throws -> T
  ) async throws -> T {
    let fd = try FileDescriptor.open(path, .writeOnly)
    do {
      let result = try await body(.init(fileHandle: .local(fd)))
      try fd.close()
      return result
    } catch {
      try fd.close()
      throw error.attach(path: path)
    }
  }
}
