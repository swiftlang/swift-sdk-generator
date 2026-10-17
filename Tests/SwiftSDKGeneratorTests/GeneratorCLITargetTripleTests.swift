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

@testable import GeneratorCLI

final class GeneratorCLITargetTripleTests: XCTestCase {
  /// Drives the existing CLI options → Triple path (`MakeLinuxSDK.parse` / `--target`).
  /// Incomplete triples must be rejected; this compiles against unmodified main, where parse
  /// currently succeeds and this assertion fails.
  func testIncompleteTargetTriplesAreRejectedByCLIOptions() {
    let incompleteTriples = [
      "x86_64-unknown-linux",
      "aarch64-linux",
    ]

    for tripleString in incompleteTriples {
      XCTAssertThrowsError(
        try GeneratorCLI.MakeLinuxSDK.parse(["--target", tripleString]),
        "Incomplete triple \(tripleString) should be rejected"
      )
    }
  }
}
