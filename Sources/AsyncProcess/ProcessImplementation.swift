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

import Foundation
import ProcessSpawnSync

#if os(iOS) || os(tvOS) || os(watchOS)
  #error("Process and fork() unavailable")
#endif

internal protocol ProcessImplementation: AnyObject & Sendable {
  var executableURL: URL? { get set }
  var currentDirectoryURL: URL? { get set }
  var launchPath: String? { get set }
  var processIdentifier: pid_t { get }
  var terminationReason: Process.TerminationReason { get }
  var terminationStatus: CInt { get }
  var isRunning: Bool { get }

  func run() throws
  func setArguments(_ arguments: [String])
  func setEnvironment(_ environment: [String: String])
  func setStandardInput(_ standardInput: Pipe?)
  func setStandardOutput(_ standardOutput: FileHandle?)
  func setStandardError(_ standardError: FileHandle?)
  func setTerminationHandler(_ handler: @Sendable @escaping (any ProcessImplementation) -> Void)
}

extension ProcessImplementation {
  static func initialiseProcessImpl(spawnOptions: ProcessExecutor.SpawnOptions) -> any ProcessImplementation {
    if spawnOptions.requiresPSProcess {
      return PSProcess()
    } else {
      return Process()
    }
  }
}

extension Process: ProcessImplementation {
  func setArguments(_ arguments: [String]) {
    self.arguments = arguments
  }

  func setEnvironment(_ environment: [String: String]) {
    self.environment = environment
  }

  func setStandardInput(_ standardInput: Pipe?) {
    self.standardInput = standardInput
  }

  func setStandardOutput(_ standardOutput: FileHandle?) {
    self.standardOutput = standardOutput
  }

  func setStandardError(_ standardError: FileHandle?) {
    self.standardError = standardError
  }

  func setTerminationHandler(_ handler: @Sendable @escaping (any ProcessImplementation) -> Void) {
    self.terminationHandler = { process in
      handler(process)
    }
  }
}

extension PSProcess: ProcessImplementation {
  func setArguments(_ arguments: [String]) {
    self.arguments = arguments
  }

  func setEnvironment(_ environment: [String: String]) {
    self.environment = environment
  }

  func setStandardInput(_ standardInput: Pipe?) {
    self.standardInput = standardInput
  }

  func setStandardOutput(_ standardOutput: FileHandle?) {
    self.standardOutput = standardOutput
  }

  func setStandardError(_ standardError: FileHandle?) {
    self.standardError = standardError
  }

  func setTerminationHandler(_ handler: @Sendable @escaping (any ProcessImplementation) -> Void) {
    self.terminationHandler = { process in
      handler(process)
    }
  }
}
