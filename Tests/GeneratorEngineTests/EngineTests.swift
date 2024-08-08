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

import struct Foundation.Data
@testable import GeneratorEngine
import struct Logging.Logger
import struct SystemPackage.FilePath
import XCTest

private let encoder = JSONEncoder()
private let decoder = JSONDecoder()

private extension FileSystem {
  func read<V: Decodable>(_ path: FilePath, bufferLimit: Int = 10 * 1024 * 1024, as: V.Type) async throws -> V {
    let data = try await self.withOpenReadableFile(path) {
      var data = Data()
      for try await chunk in try await $0.read() {
        data.append(contentsOf: chunk)

        guard data.count < bufferLimit else {
          throw FileSystemError.bufferLimitExceeded(path)
        }
      }
      return data
    }

    return try decoder.decode(V.self, from: data)
  }

  func write(_ path: FilePath, _ value: some Encodable) async throws {
    let data = try encoder.encode(value)
    try await self.withOpenWritableFile(path) { fileHandle in
      try await fileHandle.write(data)
    }
  }
}

struct Const: CachingQuery {
  let x: Int

  func run(engine: Engine) async throws -> FilePath {
    let resultPath = FilePath("/Const-\(x)")
    try await engine.fileSystem.write(resultPath, self.x)
    return resultPath
  }
}

struct MultiplyByTwo: CachingQuery {
  let x: Int

  func run(engine: Engine) async throws -> FilePath {
    let constPath = try await engine[Const(x: self.x)].path
    let constResult = try await engine.fileSystem.read(constPath, as: Int.self)

    let resultPath = FilePath("/MultiplyByTwo-\(constResult)")
    try await engine.fileSystem.write(resultPath, constResult * 2)
    return resultPath
  }
}

struct AddThirty: CachingQuery {
  let x: Int

  func run(engine: Engine) async throws -> FilePath {
    let constPath = try await engine[Const(x: self.x)].path
    let constResult = try await engine.fileSystem.read(constPath, as: Int.self)

    let resultPath = FilePath("/AddThirty-\(constResult)")
    try await engine.fileSystem.write(resultPath, constResult + 30)
    return resultPath
  }
}

struct Expression: CachingQuery {
  let x: Int
  let y: Int

  func run(engine: Engine) async throws -> FilePath {
    let multiplyPath = try await engine[MultiplyByTwo(x: self.x)].path
    let addThirtyPath = try await engine[AddThirty(x: self.y)].path

    let multiplyResult = try await engine.fileSystem.read(multiplyPath, as: Int.self)
    let addThirtyResult = try await engine.fileSystem.read(addThirtyPath, as: Int.self)

    let resultPath = FilePath("/Expression-\(multiplyResult)-\(addThirtyResult)")
    try await engine.fileSystem.write(resultPath, multiplyResult + addThirtyResult)
    return resultPath
  }
}

final class EngineTests: XCTestCase {
  func testSimpleCaching() async throws {
    let engine = Engine(
      VirtualFileSystem(),
      Logger(label: "engine-tests"),
      cacheLocation: .memory
    )

    var resultPath = try await engine[Expression(x: 1, y: 2)].path
    var result = try await engine.fileSystem.read(resultPath, as: Int.self)

    XCTAssertEqual(result, 34)

    var cacheMisses = await engine.cacheMisses
    XCTAssertEqual(cacheMisses, 5)

    var cacheHits = await engine.cacheHits
    XCTAssertEqual(cacheHits, 0)

    resultPath = try await engine[Expression(x: 1, y: 2)].path
    result = try await engine.fileSystem.read(resultPath, as: Int.self)
    XCTAssertEqual(result, 34)

    cacheMisses = await engine.cacheMisses
    XCTAssertEqual(cacheMisses, 5)

    cacheHits = await engine.cacheHits
    XCTAssertEqual(cacheHits, 1)

    resultPath = try await engine[Expression(x: 2, y: 1)].path
    result = try await engine.fileSystem.read(resultPath, as: Int.self)
    XCTAssertEqual(result, 35)

    cacheMisses = await engine.cacheMisses
    XCTAssertEqual(cacheMisses, 8)

    cacheHits = await engine.cacheHits
    XCTAssertEqual(cacheHits, 3)

    resultPath = try await engine[Expression(x: 2, y: 1)].path
    result = try await engine.fileSystem.read(resultPath, as: Int.self)
    XCTAssertEqual(result, 35)

    cacheMisses = await engine.cacheMisses
    XCTAssertEqual(cacheMisses, 8)

    cacheHits = await engine.cacheHits
    XCTAssertEqual(cacheHits, 4)

    try await engine.shutDown()
  }

  struct MyItem: Sendable, CacheKey {
    let remoteURL: URL
    var localPath: FilePath
    let isPrebuilt: Bool
  }

  func testQueryEncoding() throws {
    let item = MyItem(
      remoteURL: URL(string: "https://download.swift.org/swift-5.9.2-release/ubuntu2204-aarch64/swift-5.9.2-RELEASE/swift-5.9.2-RELEASE-ubuntu22.04-aarch64.tar.gz")!,
      localPath: "/Users/katei/ghq/github.com/apple/swift-sdk-generator/Artifacts/target_swift_5.9.2-RELEASE_aarch64-unknown-linux-gnu.tar.gz",
      isPrebuilt: true
    )
    func hashValue(of key: some CacheKey) throws -> SHA256Digest {
      let hasher = HashEncoder<SHA256>()
      try hasher.encode(key)
      return hasher.finalize()
    }
    // Ensure that hash key is stable across runs
    XCTAssertEqual(
      try hashValue(of: item).description,
      "SHA256 digest: 5178ba619e00da962d505954d33d0bceceeff29831bf5ee0c878dd1f2568b118"
    )
  }
}
