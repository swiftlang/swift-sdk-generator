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

public struct Triple: Sendable, CustomStringConvertible {
  /// CPU architecture supported by the generator.
  public enum CPU: String, Sendable, Decodable, CaseIterable {
    case x86_64
    case arm64

    public init?(rawValue: String) {
      switch rawValue {
      case "x86_64":
        self = .x86_64
      case "aarch64", "arm64":
        self = .arm64
      default:
        return nil
      }
    }

    /// Returns the value of `cpu` converted to a convention used by Swift on Linux, i.e. `arm64` becomes `aarch64`.
    var linuxConventionName: String {
      switch self {
      case .arm64: "aarch64"
      case .x86_64: "x86_64"
      }
    }

    /// Returns the value of `cpu` converted to a convention used by `LLVM_TARGETS_TO_BUILD` CMake setting.
    var llvmTargetConventionName: String {
      switch self {
      case .x86_64: "X86"
      case .arm64: "AArch64"
      }
    }
  }

  enum Vendor: String {
    case apple
    case unknown
  }

  enum OS: Hashable, CustomStringConvertible {
    case linux
    case darwin(version: String)
    case macosx(version: String)
    case wasi
    case win32

    var description: String {
      switch self {
      case .linux:
        "linux"
      case let .darwin(version):
        "darwin\(version)"
      case let .macosx(version):
        "macosx\(version)"
      case .wasi:
        "wasi"
      case .win32:
        "win32"
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
      case .darwin:
        return self
      case let .macosx(macOSVersion):
        guard let darwinVersion = macOSDarwinVersions[macOSVersion] else {
          throw GeneratorError.unknownMacOSVersion(macOSVersion)
        }

        os = .darwin(version: darwinVersion)
      default:
        fatalError("\(#function) should not be called for non-Darwin triples")
      }

      return Triple(cpu: self.cpu, vendor: self.vendor, os: os)
    }
  }
}

/// Mapping from a macOS version to a Darwin version.
private let macOSDarwinVersions = [
  "13.0": "22.0",
  "14.0": "23.0",
]
