//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import XCTest

@testable import SwiftSDKGenerator

final class TargetTripleValidationTests: XCTestCase {
  func testIncompleteTargetTriplesAreRejected() {
    let incompleteTriples = [
      "aarch64",
      "x86_64-unknown-linux",
      "linux-gnu",
      "x86_64-unknown",
    ]

    for tripleString in incompleteTriples {
      XCTAssertThrowsError(
        try Triple(tripleString).validateSDKTargetTriple(),
        "Incomplete triple \(tripleString) should be rejected"
      ) { error in
        let description = String(describing: error)
        XCTAssertTrue(
          description.contains("aarch64-unknown-linux-gnu"),
          "Error for \(tripleString) should name the expected form `aarch64-unknown-linux-gnu`, got: \(description)"
        )
      }
    }
  }

  func testCompleteTargetTriplesAreAccepted() throws {
    let completeTriples = [
      "aarch64-unknown-linux-gnu",
      "x86_64-unknown-linux-gnu",
      "armv7-unknown-linux-gnueabihf",
      "aarch64-swift-linux-musl",
      "wasm32-unknown-wasi",
      "wasm32-unknown-wasip1",
      "wasm32-unknown-wasip1-threads",
      "wasm32-unknown-emscripten",
      "aarch64-unknown-freebsd",
      "aarch64-unknown-freebsd14.3",
      "x86_64-unknown-freebsd14.3",
    ]

    for tripleString in completeTriples {
      XCTAssertNoThrow(
        try Triple(tripleString).validateSDKTargetTriple(),
        "Complete triple \(tripleString) should be accepted"
      )
    }
  }
}
