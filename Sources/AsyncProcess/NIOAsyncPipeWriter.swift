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
import NIO
import NIOExtras

struct NIOAsyncPipeWriter<Chunks: AsyncSequence & Sendable> where Chunks.Element == ByteBuffer {
  static func sinkSequenceInto(
    _ chunks: Chunks,
    fileDescriptor fd: CInt,
    eventLoop: EventLoop
  ) async throws {
    // Just so we've got an input.
    // (workaround for https://github.com/apple/swift-nio/issues/2444)
    let deadPipe = Pipe()
    let channel = try await NIOPipeBootstrap(group: eventLoop)
      .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
      .channelOption(ChannelOptions.autoRead, value: false)
      .takingOwnershipOfDescriptors(
        input: dup(deadPipe.fileHandleForReading.fileDescriptor),
        output: dup(fd)
      ).get()
    channel.close(mode: .input, promise: nil)
    try! deadPipe.fileHandleForReading.close()
    try! deadPipe.fileHandleForWriting.close()
    defer {
      channel.close(promise: nil)
    }
    for try await chunk in chunks {
      try await channel.writeAndFlush(chunk).get()
    }
  }
}
