//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2022-2026 Apple Inc. and the Swift project authors
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
      targetTriple: Triple("wasm32-unknown-wasip1"),
      logger: logger
    )
  }

  func testToolOptions() {
    let recipe = self.createRecipe()
    var toolset = Toolset(rootPath: nil)
    recipe.applyPlatformOptions(
      toolset: &toolset,
      targetTriple: Triple("wasm32-unknown-wasi"),
      isForEmbeddedSwift: false
    )
    XCTAssertEqual(toolset.swiftCompiler?.extraCLIOptions, ["-static-stdlib"])
    XCTAssertNil(toolset.cCompiler)
    XCTAssertNil(toolset.cxxCompiler)
    XCTAssertNil(toolset.linker)
  }

  func testEmbeddedToolOptions() {
    let recipe = self.createRecipe()
    var toolset = Toolset(rootPath: nil)
    recipe.applyPlatformOptions(
      toolset: &toolset,
      targetTriple: Triple("wasm32-unknown-wasi"),
      isForEmbeddedSwift: true
    )
    XCTAssertEqual(
      toolset.swiftCompiler?.extraCLIOptions,
      [
        "-static-stdlib",
        "-enable-experimental-feature", "Embedded", "-wmo",
      ]
        + ["-lc++", "-lswift_Concurrency"].flatMap {
          ["-Xlinker", $0]
        }
    )
    XCTAssertEqual(toolset.cCompiler?.extraCLIOptions, ["-D__EMBEDDED_SWIFT__"])
    XCTAssertEqual(toolset.cxxCompiler?.extraCLIOptions, ["-D__EMBEDDED_SWIFT__"])
    XCTAssertNil(toolset.linker)
  }

  func testToolOptionsWithThreads() {
    let recipe = self.createRecipe()
    var toolset = Toolset(rootPath: nil)
    recipe.applyPlatformOptions(
      toolset: &toolset,
      targetTriple: Triple("wasm32-unknown-wasip1-threads"),
      isForEmbeddedSwift: false
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

  func testMetadataWithEmbedded() {
    testMetadataWithEmbedded(targetTriple: Triple("wasm32-unknown-wasip1"))
    testMetadataWithEmbedded(targetTriple: Triple("wasm32-unknown-wasip1-threads"))
  }

  func testMetadataWithEmbedded(targetTriple: Triple) {
    let recipe = self.createRecipe()
    var metadata = SwiftSDKMetadataV4(
      targetTriples: [
        targetTriple.triple: .init(sdkRootPath: "./WASI.sdk")
      ]
    )
    let paths = PathsConfiguration(
      sourceRoot: "./",
      artifactID: "any-sdk-id",
      targetTriple: targetTriple
    )
    recipe.applyPlatformOptions(
      metadata: &metadata,
      paths: paths,
      targetTriple: targetTriple,
      isForEmbeddedSwift: true
    )
    // Should include the target we started with.
    XCTAssertNotNil(metadata.targetTriples[targetTriple.triple])
  }
}

#if compiler(>=6.0)
import Foundation
import Testing

@Suite
struct WasmSDKRecipeFileTests {
  let logger = Logger(label: "WasmSDKRecipeFileTests")

  @Test
  func recipeFileDeserialization() throws {
    let json = """
    {
      "schemaVersion": "0.1",
      "recipeType": "wasm",
      "swiftVersion": "6.2.1-RELEASE",
      "hostSwiftPackagePath": "/path/to/host",
      "targets": [
        {
          "triple": "wasm32-unknown-wasip1",
          "wasiSysroot": "/path/to/wasip1-sysroot",
          "swiftPackagePath": "/path/to/wasip1-package"
        },
        {
          "triple": "wasm32-unknown-wasip1-threads",
          "wasiSysroot": "/path/to/threads-sysroot",
          "swiftPackagePath": "/path/to/threads-package"
        }
      ]
    }
    """.data(using: .utf8)!

    let recipe = try JSONDecoder().decode(WasmSDKRecipeFile.self, from: json)
    #expect(recipe.schemaVersion == "0.1")
    #expect(recipe.recipeType == .wasm)
    #expect(recipe.swiftVersion == "6.2.1-RELEASE")
    #expect(recipe.hostSwiftPackagePath == "/path/to/host")
    #expect(recipe.targets.count == 2)
    #expect(recipe.targets[0].triple == "wasm32-unknown-wasip1")
    #expect(recipe.targets[0].wasiSysroot == "/path/to/wasip1-sysroot")
    #expect(recipe.targets[0].swiftPackagePath == "/path/to/wasip1-package")
    #expect(recipe.targets[1].triple == "wasm32-unknown-wasip1-threads")
    #expect(recipe.targets[1].wasiSysroot == "/path/to/threads-sysroot")
    #expect(recipe.targets[1].swiftPackagePath == "/path/to/threads-package")
  }

  @Test
  func recipeFileWithoutOptionalFields() throws {
    let json = """
    {
      "schemaVersion": "0.1",
      "recipeType": "wasm",
      "swiftVersion": "6.2.1-RELEASE",
      "targets": [
        {
          "triple": "wasm32-unknown-wasip1",
          "wasiSysroot": "/path/to/sysroot"
        }
      ]
    }
    """.data(using: .utf8)!

    let recipe = try JSONDecoder().decode(WasmSDKRecipeFile.self, from: json)
    #expect(recipe.hostSwiftPackagePath == nil)
    #expect(recipe.targets.count == 1)
    #expect(recipe.targets[0].swiftPackagePath == nil)
  }

  @Test
  func recipeBasedConstruction() throws {
    let json = """
    {
      "schemaVersion": "0.1",
      "recipeType": "wasm",
      "swiftVersion": "6.2.1-RELEASE",
      "targets": [
        {
          "triple": "wasm32-unknown-wasip1",
          "wasiSysroot": "/sysroot/wasip1",
          "swiftPackagePath": "/package/wasip1"
        },
        {
          "triple": "wasm32-unknown-wasip1-threads",
          "wasiSysroot": "/sysroot/threads",
          "swiftPackagePath": "/package/threads"
        }
      ]
    }
    """.data(using: .utf8)!

    let recipeFile = try JSONDecoder().decode(WasmSDKRecipeFile.self, from: json)
    let recipe = WebAssemblyRecipe(
      recipeFile: recipeFile,
      hostTriples: [],
      logger: logger
    )

    #expect(recipe.targetTriples.count == 2)
    #expect(recipe.targetTriples[0].triple == "wasm32-unknown-wasip1")
    #expect(recipe.targetTriples[1].triple == "wasm32-unknown-wasip1-threads")
    #expect(recipe.swiftVersion == "6.2.1-RELEASE")

    // Verify per-triple config has distinct entries
    let perTripleConfig = try #require(recipe.perTripleConfig)
    let wasip1Config = try #require(perTripleConfig[Triple("wasm32-unknown-wasip1")])
    let threadsConfig = try #require(perTripleConfig[Triple("wasm32-unknown-wasip1-threads")])
    #expect(wasip1Config.wasiSysroot == "/sysroot/wasip1")
    #expect(threadsConfig.wasiSysroot == "/sysroot/threads")
    #expect(wasip1Config.swiftPackagePath == "/package/wasip1")
    #expect(threadsConfig.swiftPackagePath == "/package/threads")
  }
}
#endif
