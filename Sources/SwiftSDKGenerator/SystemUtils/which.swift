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

import AsyncProcess
import Foundation

/// Look for an executable using the `which` utility.
///
/// - Parameter executableName: The name of the executable to search for.
/// - Throws: Any errors thrown by the ProcessExecutor.
/// - Returns: The path to the executable if found, otherwise nil.
func which(_ executableName: String) async throws -> String? {
  let result = try await ProcessExecutor.runCollectingOutput(
    executable: "/usr/bin/which", [executableName], collectStandardOutput: true,
    collectStandardError: false,
    environment: ProcessInfo.processInfo.environment
  )

  guard result.exitReason == .exit(0) else {
    return nil
  }

  if let output = result.standardOutput {
    let path = String(buffer: output).trimmingCharacters(in: .whitespacesAndNewlines)
    return path.isEmpty ? nil : path
  }

  return nil
}
