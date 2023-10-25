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

public enum ProcessExitReason: Hashable & Sendable {
  case exit(CInt)
  case signal(CInt)

  public func throwIfNonZero() throws {
    switch self {
    case .exit(0):
      return
    default:
      throw ProcessExecutionError(self)
    }
  }
}

public struct ProcessExecutionError: Error & Hashable & Sendable {
  public var exitReason: ProcessExitReason

  public init(_ exitResult: ProcessExitReason) {
    self.exitReason = exitResult
  }
}

extension ProcessExecutionError: CustomStringConvertible {
  public var description: String {
    "process exited non-zero: \(self.exitReason)"
  }
}
