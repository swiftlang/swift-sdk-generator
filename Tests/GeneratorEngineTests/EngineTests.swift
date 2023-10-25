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
@testable import GeneratorEngine
import struct SystemPackage.FilePath
import XCTest

private let encoder = JSONEncoder()
private let decoder = JSONDecoder()

private extension FileSystem {
  func read<V: Decodable>(_ path: FilePath, as: V.Type) async throws -> V {
    let fileStream = try await self.read(path)
    var bytes = [UInt8]()
    for try await chunk in fileStream {
      bytes += chunk
    }

    return try decoder.decode(V.self, from: .init(bytes))
  }

  func write(_ path: FilePath, _ value: some Encodable) async throws {
    let data = try encoder.encode(value)
    try await self.write(path, .init(data))
  }
}

@Query
struct Const {
  let x: Int

  func run(engine: Engine) async throws -> FilePath {
    let resultPath = FilePath("/Const-\(x)")
    try await engine.fileSystem.write(resultPath, self.x)
    return resultPath
  }
}

@Query
struct MultiplyByTwo {
  let x: Int

  func run(engine: Engine) async throws -> FilePath {
    let constPath = try await engine[Const(x: self.x)]

    let constResult = try await engine.fileSystem.read(constPath, as: Int.self)

    let resultPath = FilePath("/MultiplyByTwo-\(constResult)")
    try await engine.fileSystem.write(resultPath, constResult * 2)
    return resultPath
  }
}

@Query
struct AddThirty {
  let x: Int

  func run(engine: Engine) async throws -> FilePath {
    let constPath = try await engine[Const(x: self.x)]
    let constResult = try await engine.fileSystem.read(constPath, as: Int.self)

    let resultPath = FilePath("/AddThirty-\(constResult)")
    try await engine.fileSystem.write(resultPath, constResult + 30)
    return resultPath
  }
}

@Query
struct Expression {
  let x: Int
  let y: Int

  func run(engine: Engine) async throws -> FilePath {
    let multiplyPath = try await engine[MultiplyByTwo(x: self.x)]
    let addThirtyPath = try await engine[AddThirty(x: self.y)]

    let multiplyResult = try await engine.fileSystem.read(multiplyPath, as: Int.self)
    let addThirtyResult = try await engine.fileSystem.read(addThirtyPath, as: Int.self)

    let resultPath = FilePath("/Expression-\(multiplyResult)-\(addThirtyResult)")
    try await engine.fileSystem.write(resultPath, multiplyResult + addThirtyResult)
    return resultPath
  }
}

final class EngineTests: XCTestCase {
  func testSimpleCaching() async throws {
    let engine = Engine(VirtualFileSystem(), cacheLocation: .memory)

    var resultPath = try await engine[Expression(x: 1, y: 2)]
    var result = try await engine.fileSystem.read(resultPath, as: Int.self)

    XCTAssertEqual(result, 34)

    var cacheMisses = await engine.cacheMisses
    XCTAssertEqual(cacheMisses, 5)

    var cacheHits = await engine.cacheHits
    XCTAssertEqual(cacheHits, 0)

    resultPath = try await engine[Expression(x: 1, y: 2)]
    result = try await engine.fileSystem.read(resultPath, as: Int.self)
    XCTAssertEqual(result, 34)

    cacheMisses = await engine.cacheMisses
    XCTAssertEqual(cacheMisses, 5)

    cacheHits = await engine.cacheHits
    XCTAssertEqual(cacheHits, 1)

    resultPath = try await engine[Expression(x: 2, y: 1)]
    result = try await engine.fileSystem.read(resultPath, as: Int.self)
    XCTAssertEqual(result, 35)

    cacheMisses = await engine.cacheMisses
    XCTAssertEqual(cacheMisses, 8)

    cacheHits = await engine.cacheHits
    XCTAssertEqual(cacheHits, 3)

    resultPath = try await engine[Expression(x: 2, y: 1)]
    result = try await engine.fileSystem.read(resultPath, as: Int.self)
    XCTAssertEqual(result, 35)

    cacheMisses = await engine.cacheMisses
    XCTAssertEqual(cacheMisses, 8)

    cacheHits = await engine.cacheHits
    XCTAssertEqual(cacheHits, 4)
  }
}
