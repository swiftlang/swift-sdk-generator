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

import AsyncProcess
import Foundation
import NIOCore

extension ByteBuffer {
  public func unzip(zipPath: String, isVerbose: Bool) async throws -> ByteBuffer? {
    let result = try await ProcessExecutor.runCollectingOutput(
      executable: zipPath,
      ["-cd"],
      standardInput: [self].async,
      collectStandardOutput: true,
      collectStandardError: false,
      perStreamCollectionLimitBytes: 20 * 1024 * 1024
    )

    try result.exitReason.throwIfNonZero()

    return result.standardOutput
  }
}
