//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2022-2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

public struct Triple: CustomStringConvertible {
  public let cpu: String
  let vendor: String
  let os: String
  var abi: String?

  public var description: String { "\(self.cpu)-\(self.vendor)-\(self.os)\(self.abi != nil ? "-\(self.abi!)" : "")" }

  public static let availableTriples = (
    linux: Triple(
      cpu: "aarch64",
      vendor: "unknown",
      os: "linux",
      abi: "gnu"
    ),
    // Used to download LLVM distribution.
    darwin: Triple(
      cpu: "arm64",
      vendor: "apple",
      os: "darwin22.0"
    ),
    // Used to download Swift distribution.
    macOS: Triple(
      cpu: "arm64",
      vendor: "apple",
      os: "macosx13.0"
    )
  )
}
