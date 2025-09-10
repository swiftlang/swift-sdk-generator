//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation

public struct FreeBSD: Sendable {
  public let version: String

  public let majorVersion: Int
  public let minorVersion: Int

  public func isSupportedVersion() -> Bool {
    if majorVersion >= 15 {
      return true
    } else if majorVersion == 14, minorVersion >= 3 {
      return true
    } else {
      return false
    }
  }

  public init(_ versionString: String) throws {
    guard !versionString.isEmpty else {
      throw GeneratorError.invalidVersionString(
        string: versionString,
        reason: "The version string cannot be empty."
      )
    }

    let versionComponents = versionString.split(separator: ".")
    guard let majorVersion = Int(versionComponents[0]) else {
      throw GeneratorError.unknownFreeBSDVersion(version: versionString)
    }

    self.version = versionString
    self.majorVersion = majorVersion
    if versionComponents.count > 1, let minorVersion = Int(versionComponents[1]) {
      self.minorVersion = minorVersion
    } else {
      minorVersion = 0
    }
  }
}
