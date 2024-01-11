//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2022-2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import AsyncHTTPClient
import GeneratorEngine

/// A protocol describing a set of platform specific instructions to make a Swift SDK
public protocol SwiftSDKRecipe: Sendable {
  /// The main entrypoint of the recipe to make a Swift SDK
  func makeSwiftSDK(generator: SwiftSDKGenerator, engine: Engine, httpClient: HTTPClient) async throws
}
