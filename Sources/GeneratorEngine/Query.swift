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

import struct SystemPackage.FilePath

@attached(extension, conformances: QueryProtocol, CacheKeyProtocol, names: named(hash(with:)))
public macro Query() = #externalMacro(module: "Macros", type: "QueryMacro")

public protocol QueryProtocol: CacheKeyProtocol {
  func run(engine: Engine) async throws -> FilePath
}
