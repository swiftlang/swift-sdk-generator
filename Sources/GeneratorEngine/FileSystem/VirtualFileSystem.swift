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

import struct SystemPackage.FilePath

actor VirtualFileSystem: FileSystem {
  private var content: [FilePath: [UInt8]]

  init(content: [FilePath: [UInt8]] = [:]) {
    self.content = content
  }

  func read(_ path: FilePath) throws -> ReadableFileStream {
    guard let bytes = self.content[path] else {
      throw FileSystemError.fileDoesNotExist(path)
    }

    return .virtual(VirtualReadableFileStream(bytes: bytes))
  }

  func write(_ path: FilePath, _ bytes: [UInt8]) throws {
    self.content[path] = bytes
  }

  func hash(_ path: FilePath, with hashFunction: inout some HashFunction) throws {
    guard let bytes = self.content[path] else {
      throw FileSystemError.fileDoesNotExist(path)
    }

    hashFunction.update(data: bytes)
  }
}
