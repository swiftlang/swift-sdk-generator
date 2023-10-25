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

import NIO

#if os(Linux) || os(Android) || os(Windows)
@preconcurrency import Foundation
#else
import Foundation
#endif

public struct IllegalStreamConsumptionError: Error {
  var description: String
}

public struct ChunkSequence: AsyncSequence & Sendable {
  private let fileHandle: FileHandle?
  private let group: EventLoopGroup

  public init(takingOwnershipOfFileHandle fileHandle: FileHandle?, group: EventLoopGroup) {
    self.group = group
    self.fileHandle = fileHandle
  }

  public func makeAsyncIterator() -> AsyncIterator {
    // This will close the file handle.
    AsyncIterator(try! self.fileHandle?.fileContentStream(eventLoop: self.group.any()))
  }

  public typealias Element = ByteBuffer
  public struct AsyncIterator: AsyncIteratorProtocol {
    public typealias Element = ByteBuffer
    typealias UnderlyingSequence = FileContentStream

    private var underlyingIterator: UnderlyingSequence.AsyncIterator?

    init(_ underlyingSequence: UnderlyingSequence?) {
      self.underlyingIterator = underlyingSequence?.makeAsyncIterator()
    }

    public mutating func next() async throws -> Element? {
      if self.underlyingIterator != nil {
        try await self.underlyingIterator!.next()
      } else {
        throw IllegalStreamConsumptionError(
          description: """
          Either `.discard`ed, `.inherit`ed or redirected this stream to a `.fileHandle`,
          cannot also consume it. To consume, please `.stream` it.
          """
        )
      }
    }
  }
}
