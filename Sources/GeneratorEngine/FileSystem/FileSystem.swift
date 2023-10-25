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

import protocol Crypto.HashFunction
import struct SystemPackage.FilePath

public protocol FileSystem: Actor {
  func read(_ path: FilePath) async throws -> ReadableFileStream
  func write(_ path: FilePath, _ bytes: [UInt8]) async throws
  func hash(_ path: FilePath, with hashFunction: inout some HashFunction) async throws
}

enum FileSystemError: Error {
  case fileDoesNotExist(FilePath)
}
