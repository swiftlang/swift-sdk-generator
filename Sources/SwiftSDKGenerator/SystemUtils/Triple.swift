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
  /// CPU architecture supported by the generator.
  public enum CPU: String, Decodable, CaseIterable {
    case x86_64
    case arm64

    /// Returns the value of `cpu` converted to a convention used by Linux, i.e. `arm64` becomes `aarch64`.
    var linuxConventionName: String {
      switch self {
      case .arm64: "aarch64"
      case .x86_64: "amd64"
      }
    }
  }

  enum Vendor: String {
    case apple
    case unknown
  }

  enum OS: CustomStringConvertible {
    case linux
    case darwin(version: String)
    case macosx(version: String)

    var description: String {
      switch self {
      case .linux:
        "linux"
      case let .darwin(version):
        "darwin\(version)"
      case let .macosx(version):
        "macosx\(version)"
      }
    }
  }

  enum Environment {
    case gnu
  }

  var cpu: CPU
  var vendor: Vendor
  var os: OS
  var environment: Environment?

  public var linuxConventionDescription: String {
    "\(self.cpu.linuxConventionName)-\(self.vendor)-\(self.os)\(self.environment != nil ? "-\(self.environment!)" : "")"
  }

  public var description: String {
    "\(self.cpu)-\(self.vendor)-\(self.os)\(self.environment != nil ? "-\(self.environment!)" : "")"
  }

  var darwinFormat: Triple {
    get throws {
      let os: OS
      switch self.os {
      case let .macosx(macOSVersion):
        guard let darwinVersion = macOSDarwinVersions[macOSVersion] else {
          throw GeneratorError.unknownMacOSVersion(macOSVersion)
        }

        os = .darwin(version: darwinVersion)
      default:
        fatalError("\(#function) should not be called on non-Darwin triples")
      }

      return Triple(cpu: self.cpu, vendor: self.vendor, os: os)
    }
  }
}

/// Mapping from a macOS version to a Darwin version.
private let macOSDarwinVersions = [
  "13.0": "22.0",
]
