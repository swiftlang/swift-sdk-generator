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

import Testing

@testable import SwiftSDKGenerator

struct TargetTripleValidationTests {
  @Test(arguments: [
    "aarch64",
    "x86_64-unknown-linux",
    "linux-gnu",
    "x86_64-unknown",
  ])
  func incompleteTargetTriplesAreRejected(tripleString: String) {
    #expect(throws: GeneratorError.self) {
      try Triple(tripleString).validateSDKTargetTriple()
    }
  }

  @Test func incompleteTargetTripleErrorDescribesRequiredForm() {
    do {
      try Triple("x86_64-unknown-linux").validateSDKTargetTriple()
      Issue.record("Expected incompleteTargetTriple error")
    } catch let error as GeneratorError {
      let description = String(describing: error)
      #expect(description.contains("aarch64-unknown-linux-gnu"))
      #expect(description.contains("architecture-vendor-OS-environment"))
      #expect(!description.contains("[-environment]"))
    } catch {
      Issue.record("Expected GeneratorError, got \(error)")
    }
  }

  @Test(arguments: [
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
  ])
  func completeTargetTriplesAreAccepted(tripleString: String) throws {
    try Triple(tripleString).validateSDKTargetTriple()
  }
}
