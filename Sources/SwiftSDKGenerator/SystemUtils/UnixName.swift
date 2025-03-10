//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2024-2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//


#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// libc's `uname` wrapper
struct UnixName {
  let release: String
  let machine: String

  init(info: utsname) {
    var info = info

    func cloneCString(_ value: inout some Any) -> String {
      withUnsafePointer(to: &value) {
        String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
      }
    }
    self.release = cloneCString(&info.release)
    self.machine = cloneCString(&info.machine)
  }

  static let current: UnixName! = {
    var info = utsname()
    guard uname(&info) == 0 else { return nil }
    return UnixName(info: info)
  }()
}
