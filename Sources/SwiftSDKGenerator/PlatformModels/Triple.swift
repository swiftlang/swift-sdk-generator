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

import Helpers

public typealias Triple = Helpers.Triple

extension Triple: @unchecked Sendable {}

public extension Triple {
  init(arch: Arch, vendor: Vendor?, os: OS, environment: Environment) {
    self.init("\(arch)-\(vendor?.rawValue ?? "unknown")-\(os)-\(environment)", normalizing: true)
  }

  init(arch: Arch, vendor: Vendor?, os: OS) {
    self.init("\(arch)-\(vendor?.rawValue ?? "unknown")-\(os)", normalizing: true)
  }
}

extension Triple.Arch {
  /// Returns the value of `cpu` converted to a convention used by Swift on Linux, i.e. `arm64` becomes `aarch64`.
  var linuxConventionName: String {
    switch self {
    case .aarch64: return "aarch64"
    case .x86_64: return "x86_64"
    case .wasm32: return "wasm32"
    case .arm: return "arm"
    default: fatalError("\(self) is not supported yet")
    }
  }

  /// Returns the value of `cpu` converted to a convention used by `LLVM_TARGETS_TO_BUILD` CMake setting.
  var llvmTargetConventionName: String {
    switch self {
    case .x86_64: return "X86"
    case .aarch64: return "AArch64"
    case .wasm32: return "WebAssembly"
    default: fatalError("\(self) is not supported yet")
    }
  }
}
