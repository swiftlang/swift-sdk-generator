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

import AsyncAlgorithms
import DequeModule
import Foundation
import NIO

// ⚠️ IMPLEMENTATION WARNING
// - Known issues:
//   - no tests
//   - most configurations have never run
struct FileContentStream: AsyncSequence {
  public typealias Element = ByteBuffer
  typealias Underlying = AsyncThrowingChannel<Element, Error>

  public func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(underlying: self.asyncChannel.makeAsyncIterator())
  }

  public struct AsyncIterator: AsyncIteratorProtocol {
    public typealias Element = ByteBuffer

    var underlying: Underlying.AsyncIterator

    public mutating func next() async throws -> ByteBuffer? {
      try await self.underlying.next()
    }
  }

  public struct IOError: Error {
    public var errnoValue: CInt

    public static func makeFromErrnoGlobal() -> IOError {
      IOError(errnoValue: errno)
    }
  }

  private let asyncChannel: AsyncThrowingChannel<ByteBuffer, Error>

  public init(
    fileDescriptor: CInt,
    eventLoop: EventLoop,
    blockingPool: NIOThreadPool? = nil
  ) throws {
    var statInfo: stat = .init()
    let statError = fstat(fileDescriptor, &statInfo)
    if statError != 0 {
      throw IOError.makeFromErrnoGlobal()
    }

    let dupedFD = dup(fileDescriptor)
    let asyncChannel = AsyncThrowingChannel<ByteBuffer, Error>()
    self.asyncChannel = asyncChannel

    switch statInfo.st_mode & S_IFMT {
    case S_IFREG:
      guard let blockingPool else {
        throw IOError(errnoValue: EINVAL)
      }
      let fileHandle = NIOFileHandle(descriptor: dupedFD)
      NonBlockingFileIO(threadPool: blockingPool)
        .readChunked(
          fileHandle: fileHandle,
          byteCount: .max,
          allocator: ByteBufferAllocator(),
          eventLoop: eventLoop,
          chunkHandler: { chunk in
            eventLoop.makeFutureWithTask {
              await asyncChannel.send(chunk)
            }
          }
        )
        .whenComplete { result in
          try! fileHandle.close()
          switch result {
          case let .failure(error):
            asyncChannel.fail(error)
          case .success:
            asyncChannel.finish()
          }
        }
    case S_IFSOCK:
      _ = ClientBootstrap(group: eventLoop)
        .channelInitializer { channel in
          channel.pipeline.addHandler(ReadIntoAsyncChannelHandler(sink: asyncChannel))
        }
        .withConnectedSocket(dupedFD)
    case S_IFIFO:
      let deadPipe = Pipe()
      NIOPipeBootstrap(group: eventLoop)
        .channelInitializer { channel in
          channel.pipeline.addHandler(ReadIntoAsyncChannelHandler(sink: asyncChannel))
        }
        .takingOwnershipOfDescriptors(
          input: dupedFD,
          output: dup(deadPipe.fileHandleForWriting.fileDescriptor)
        )
        .whenSuccess { channel in
          channel.close(mode: .output, promise: nil)
        }
      try! deadPipe.fileHandleForReading.close()
      try! deadPipe.fileHandleForWriting.close()
    case S_IFDIR:
      throw IOError(errnoValue: EISDIR)
    case S_IFBLK, S_IFCHR, S_IFLNK:
      throw IOError(errnoValue: EINVAL)
    default:
      // odd, but okay
      throw IOError(errnoValue: EINVAL)
    }
  }
}

private final class ReadIntoAsyncChannelHandler: ChannelDuplexHandler {
  typealias InboundIn = ByteBuffer
  typealias OutboundIn = Never

  private var heldUpRead = false
  private let sink: AsyncThrowingChannel<ByteBuffer, Error>
  private var state: State = .idle

  enum State {
    case idle
    case error(Error)
    case sending(Deque<ReceivedEvent>)

    mutating func enqueue(_ data: ReceivedEvent) -> ReceivedEvent? {
      switch self {
      case .idle:
        self = .sending([])
        return data
      case .error:
        return nil
      case var .sending(queue):
        queue.append(data)
        self = .sending(queue)
        return nil
      }
    }

    mutating func didSendOne() -> ReceivedEvent? {
      switch self {
      case .idle:
        preconditionFailure("didSendOne during .idle")
      case .error:
        return nil
      case var .sending(queue):
        if queue.isEmpty {
          self = .idle
          return nil
        } else {
          let value = queue.removeFirst()
          self = .sending(queue)
          return value
        }
      }
    }

    mutating func fail(_ error: Error) {
      switch self {
      case .idle, .sending:
        self = .error(error)
      case .error:
        return
      }
    }
  }

  enum ReceivedEvent {
    case chunk(ByteBuffer)
    case finish
  }

  private var shouldRead: Bool {
    switch self.state {
    case .idle:
      true
    case .error:
      false
    case .sending:
      false
    }
  }

  init(sink: AsyncThrowingChannel<ByteBuffer, Error>) {
    self.sink = sink
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let data = self.unwrapInboundIn(data)
    if let itemToSend = self.state.enqueue(.chunk(data)) {
      self.sendOneItem(itemToSend, context: context)
    }
  }

  private func sendOneItem(_ data: ReceivedEvent, context: ChannelHandlerContext) {
    context.eventLoop.assertInEventLoop()
    assert(self.shouldRead == false, "sendOneItem in unexpected state \(self.state)")
    context.eventLoop.makeFutureWithTask {
      switch data {
      case let .chunk(data):
        await self.sink.send(data)
      case .finish:
        self.sink.finish()
      }
    }.map {
      if let moreToSend = self.state.didSendOne() {
        self.sendOneItem(moreToSend, context: context)
      } else {
        if self.heldUpRead {
          context.eventLoop.execute {
            context.read()
          }
        }
      }
    }.whenFailure { error in
      self.state.fail(error)
    }
  }

  func errorCaught(context: ChannelHandlerContext, error: Error) {
    self.state.fail(error)
    self.sink.fail(error)
    context.close(promise: nil)
  }

  func channelInactive(context: ChannelHandlerContext) {
    if let itemToSend = self.state.enqueue(.finish) {
      self.sendOneItem(itemToSend, context: context)
    }
  }

  func read(context: ChannelHandlerContext) {
    if self.shouldRead {
      context.read()
    } else {
      self.heldUpRead = true
    }
  }
}

extension FileHandle {
  func fileContentStream(eventLoop: EventLoop) throws -> FileContentStream {
    let asyncBytes = try FileContentStream(fileDescriptor: self.fileDescriptor, eventLoop: eventLoop)
    try self.close()
    return asyncBytes
  }
}

extension FileContentStream {
  var lines: AsyncByteBufferLineSequence<FileContentStream> {
    AsyncByteBufferLineSequence(
      self,
      dropTerminator: true,
      maximumAllowableBufferSize: 1024 * 1024,
      dropLastChunkIfNoNewline: false
    )
  }
}

public extension AsyncSequence where Element == ByteBuffer {
  func splitIntoLines(
    dropTerminator: Bool = true,
    maximumAllowableBufferSize: Int = 1024 * 1024,
    dropLastChunkIfNoNewline: Bool = false
  ) -> AsyncByteBufferLineSequence<Self> {
    AsyncByteBufferLineSequence(
      self,
      dropTerminator: dropTerminator,
      maximumAllowableBufferSize: maximumAllowableBufferSize,
      dropLastChunkIfNoNewline: dropLastChunkIfNoNewline
    )
  }

  var strings: AsyncMapSequence<Self, String> {
    self.map { String(buffer: $0) }
  }
}

public struct AsyncByteBufferLineSequence<Base: Sendable>: AsyncSequence & Sendable
  where Base: AsyncSequence, Base.Element == ByteBuffer
{
  public typealias Element = ByteBuffer
  private let underlying: Base
  private let dropTerminator: Bool
  private let maximumAllowableBufferSize: Int
  private let dropLastChunkIfNoNewline: Bool

  public struct AsyncIterator: AsyncIteratorProtocol {
    public typealias Element = ByteBuffer
    private var underlying: Base.AsyncIterator
    private let dropTerminator: Bool
    private let maximumAllowableBufferSize: Int
    private let dropLastChunkIfNoNewline: Bool
    private var buffer = Buffer()

    struct Buffer {
      private var buffer: [ByteBuffer] = []
      private(set) var byteCount: Int = 0

      mutating func append(_ buffer: ByteBuffer) {
        self.buffer.append(buffer)
        self.byteCount += buffer.readableBytes
      }

      func allButLast() -> ArraySlice<ByteBuffer> {
        self.buffer.dropLast()
      }

      var byteCountButLast: Int {
        self.byteCount - (self.buffer.last?.readableBytes ?? 0)
      }

      var lastChunkView: ByteBufferView? {
        self.buffer.last?.readableBytesView
      }

      mutating func concatenateEverything(upToLastChunkLengthToConsume lastLength: Int) -> ByteBuffer {
        var output = ByteBuffer()
        output.reserveCapacity(lastLength + self.byteCountButLast)

        var writtenBytes = 0
        for buffer in self.buffer.dropLast() {
          writtenBytes += output.writeImmutableBuffer(buffer)
        }
        writtenBytes += output.writeImmutableBuffer(
          self.buffer[self.buffer.endIndex - 1].readSlice(length: lastLength)!
        )
        if self.buffer.last!.readableBytes > 0 {
          if self.buffer.count > 1 {
            self.buffer.swapAt(0, self.buffer.endIndex - 1)
          }
          self.buffer.removeLast(self.buffer.count - 1)
        } else {
          self.buffer = []
        }

        self.byteCount -= writtenBytes
        assert(self.byteCount >= 0)
        return output
      }
    }

    init(
      underlying: Base.AsyncIterator,
      dropTerminator: Bool,
      maximumAllowableBufferSize: Int,
      dropLastChunkIfNoNewline: Bool
    ) {
      self.underlying = underlying
      self.dropTerminator = dropTerminator
      self.maximumAllowableBufferSize = maximumAllowableBufferSize
      self.dropLastChunkIfNoNewline = dropLastChunkIfNoNewline
    }

    private mutating func deliverUpTo(
      view: ByteBufferView,
      index: ByteBufferView.Index,
      expectNewline: Bool
    ) -> ByteBuffer {
      let howMany = view.startIndex.distance(to: index) + (expectNewline ? 1 : 0)

      var output = self.buffer.concatenateEverything(upToLastChunkLengthToConsume: howMany)
      if expectNewline {
        assert(output.readableBytesView.last == UInt8(ascii: "\n"))
        assert(
          output.readableBytesView.firstIndex(of: UInt8(ascii: "\n"))
            == output.readableBytesView.index(before: output.readableBytesView.endIndex)
        )
      } else {
        assert(output.readableBytesView.last != UInt8(ascii: "\n"))
        assert(!output.readableBytesView.contains(UInt8(ascii: "\n")))
      }
      if self.dropTerminator && expectNewline {
        output.moveWriterIndex(to: output.writerIndex - 1)
      }

      return output
    }

    public mutating func next() async throws -> Element? {
      while true {
        if let view = self.buffer.lastChunkView {
          if let newlineIndex = view.firstIndex(of: UInt8(ascii: "\n")) {
            return self.deliverUpTo(
              view: view,
              index: newlineIndex,
              expectNewline: true
            )
          }

          if self.buffer.byteCount > self.maximumAllowableBufferSize {
            return self.deliverUpTo(
              view: view,
              index: view.endIndex,
              expectNewline: false
            )
          }
        }

        if let nextBuffer = try await self.underlying.next() {
          self.buffer.append(nextBuffer)
        } else {
          if !self.dropLastChunkIfNoNewline, let view = self.buffer.lastChunkView, !view.isEmpty {
            return self.deliverUpTo(
              view: view,
              index: view.endIndex,
              expectNewline: false
            )
          } else {
            return nil
          }
        }
      }
    }
  }

  public init(
    _ underlying: Base, dropTerminator: Bool,
    maximumAllowableBufferSize: Int,
    dropLastChunkIfNoNewline: Bool
  ) {
    self.underlying = underlying
    self.dropTerminator = dropTerminator
    self.maximumAllowableBufferSize = maximumAllowableBufferSize
    self.dropLastChunkIfNoNewline = dropLastChunkIfNoNewline
  }

  public func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(
      underlying: self.underlying.makeAsyncIterator(),
      dropTerminator: self.dropTerminator,
      maximumAllowableBufferSize: self.maximumAllowableBufferSize,
      dropLastChunkIfNoNewline: self.dropLastChunkIfNoNewline
    )
  }
}
