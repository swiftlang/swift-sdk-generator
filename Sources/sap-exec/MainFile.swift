//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2022-2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

// swift-format-ignore-file

#if canImport(Darwin)
  import Darwin
#elseif canImport(Musl)
  @preconcurrency import Musl
#elseif canImport(Glibc)
  @preconcurrency import Glibc
#elseif canImport(WASILibc)
  @preconcurrency import WASILibc
#elseif canImport(Bionic)
  @preconcurrency import Bionic
#elseif canImport(Android)
  @preconcurrency import Android
#else
  #error("unknown libc, please fix")
#endif

import AsyncProcess
import Foundation

@main
struct SAPExec {
  static func main() async throws {
    let args = CommandLine.arguments.dropFirst()

    guard let executable = args.first else {
      fputs("Usage: sap-exec <executable> [arguments...]\n", stderr)
      exit(1)
    }

    let executableArguments = Array(args.dropFirst())

    do {
      try await ProcessExecutor._runReplacingCurrentProcess(
        executable: executable,
        executableArguments,
        environment: ProcessInfo.processInfo.environment
      )
    } catch {
      fputs("ERROR: \(error)\n", stderr)
      exit(254)
    }
  }
}
