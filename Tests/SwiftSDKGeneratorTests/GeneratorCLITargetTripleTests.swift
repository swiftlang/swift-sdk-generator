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

@testable import GeneratorCLI

struct GeneratorCLITargetTripleTests {
  /// Drives the existing CLI options → Triple path (`MakeLinuxSDK.parse` / `--target`).
  /// Incomplete triples must be rejected; this compiles against unmodified main, where parse
  /// currently succeeds and this assertion fails.
  @Test(arguments: [
    "x86_64-unknown-linux",
    "aarch64-linux",
  ])
  func incompleteTargetTriplesAreRejectedByCLIOptions(tripleString: String) {
    #expect(throws: (any Error).self) {
      try GeneratorCLI.MakeLinuxSDK.parse(["--target", tripleString])
    }
  }
}
