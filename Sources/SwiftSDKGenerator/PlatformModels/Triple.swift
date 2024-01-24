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
    case wasm32

    public init?(rawValue: String) {
      switch rawValue {
      case "x86_64":
        self = .x86_64
      case "aarch64", "arm64":
        self = .arm64
      case "wasm32":
        self = .wasm32
      default:
        return nil
      }
    }

    /// Returns the value of `cpu` converted to a convention used by Swift on Linux, i.e. `arm64` becomes `aarch64`.
    var linuxConventionName: String {
      switch self {
      case .arm64: "aarch64"
      case .x86_64: "x86_64"
      case .wasm32: "wasm32"
      }
    }

    /// Returns the value of `cpu` converted to a convention used by `LLVM_TARGETS_TO_BUILD` CMake setting.
    var llvmTargetConventionName: String {
      switch self {
      case .x86_64: "X86"
      case .arm64: "AArch64"
      case .wasm32: "WebAssembly"
      }
    }
  }

  public enum Vendor: String, Sendable {
    case apple
    case unknown
  }

  public enum OS: Hashable, CustomStringConvertible, Sendable {
    case linux
    case darwin(version: String)
    case macosx(version: String)
    case wasi
    case win32

    public var description: String {
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

  public enum Environment: Sendable {
    case gnu
  }

  public var cpu: CPU
  public var vendor: Vendor
  public var os: OS
  public var environment: Environment?

  public init(cpu: CPU, vendor: Vendor, os: OS, environment: Environment? = nil) {
    self.cpu = cpu
    self.vendor = vendor
    self.os = os
    self.environment = environment
  }

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
