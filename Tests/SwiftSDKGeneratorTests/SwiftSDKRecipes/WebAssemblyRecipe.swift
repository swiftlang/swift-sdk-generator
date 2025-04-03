//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2022-2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Logging
import XCTest

@testable import SwiftSDKGenerator

final class WebAssemblyRecipeTests: XCTestCase {
  let logger = Logger(label: "WebAssemblyRecipeTests")

  func createRecipe() -> WebAssemblyRecipe {
    WebAssemblyRecipe(
      hostSwiftPackage: nil,
      targetSwiftPackagePath: "./target-toolchain",
      wasiSysroot: "./wasi-sysroot",
      swiftVersion: "5.10",
      logger: logger
    )
  }

  func testToolOptions() {
    let recipe = self.createRecipe()
    var toolset = Toolset(rootPath: nil)
    recipe.applyPlatformOptions(
      toolset: &toolset,
      targetTriple: Triple("wasm32-unknown-wasi")
    )
    XCTAssertEqual(toolset.swiftCompiler?.extraCLIOptions, ["-static-stdlib"])
    XCTAssertNil(toolset.cCompiler)
    XCTAssertNil(toolset.cxxCompiler)
    XCTAssertNil(toolset.linker)
  }

  func testToolOptionsWithThreads() {
    let recipe = self.createRecipe()
    var toolset = Toolset(rootPath: nil)
    recipe.applyPlatformOptions(
      toolset: &toolset,
      targetTriple: Triple("wasm32-unknown-wasip1-threads")
    )
    XCTAssertEqual(
      toolset.swiftCompiler?.extraCLIOptions,
      [
        "-static-stdlib",
        "-Xcc", "-matomics",
        "-Xcc", "-mbulk-memory",
        "-Xcc", "-mthread-model",
        "-Xcc", "posix",
        "-Xcc", "-pthread",
        "-Xcc", "-ftls-model=local-exec",
      ]
    )

    let ccOptions = [
      "-matomics", "-mbulk-memory", "-mthread-model", "posix",
      "-pthread", "-ftls-model=local-exec",
    ]
    XCTAssertEqual(toolset.cCompiler?.extraCLIOptions, ccOptions)
    XCTAssertEqual(toolset.cxxCompiler?.extraCLIOptions, ccOptions)
    XCTAssertEqual(
      toolset.linker?.extraCLIOptions,
      [
        "--import-memory", "--export-memory", "--shared-memory", "--max-memory=1073741824",
      ]
    )
  }
}
