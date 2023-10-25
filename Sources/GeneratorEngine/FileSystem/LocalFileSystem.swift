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
  public static let defaultChunkSize = 128 * 1024

  let readChunkSize: Int

  public init(readChunkSize: Int = defaultChunkSize) {
    self.readChunkSize = readChunkSize
  }

  public func read(_ path: FilePath) throws -> ReadableFileStream {
    try .local(
      LocalReadableFileStream(
        fileDescriptor: FileDescriptor.open(path, .readOnly),
        readChunkSize: self.readChunkSize
      )
    )
  }

  public func write(_ path: FilePath, _ bytes: [UInt8]) throws {
    let fd = try FileDescriptor.open(path, .writeOnly)

    try fd.closeAfter {
      _ = try fd.writeAll(bytes)
    }
  }

  public func hash(
    _ path: FilePath,
    with hashFunction: inout some HashFunction
  ) throws {
    let fd = try FileDescriptor.open(path, .readOnly)

    try fd.closeAfter {
      var buffer = [UInt8](repeating: 0, count: readChunkSize)
      var bytesRead = 0
      repeat {
        bytesRead = try buffer.withUnsafeMutableBytes {
          try fd.read(into: $0)
        }

        if bytesRead > 0 {
          hashFunction.update(data: buffer[0..<bytesRead])
        }

      } while bytesRead > 0
    }
  }
}
