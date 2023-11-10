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

import Foundation
import NIOCore
import NIOFoundationCompat

public extension ByteBuffer {
  func unzip(isVerbose: Bool) throws -> AsyncThrowingStream<Data, any Error> {
    let gzip = try Shell("gzip -cd", shouldLogCommands: isVerbose)
    gzip.stdin.write(Data(buffer: self))
    try gzip.stdin.close()

    return gzip.stdout
  }
}
