//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
import XCTest

@testable import Helpers

final class ThrowingDeferTests: XCTestCase {
  struct EquatableError: Error, Equatable {
    let identifier = UUID()
  }

  final actor Worker {
    let error: EquatableError?
    private(set) var didRun = false

    init(error: EquatableError? = nil) {
      self.error = error
    }

    func run() throws {
      didRun = true
      if let error {
        throw error
      }
    }
  }

  // MARK: - Non-Async
  func testThrowingDeferWithoutThrowing() throws {
    var didRunWork = false
    var didRunCleanup = false

    try withThrowing {
      didRunWork = true
    } defer: {
      didRunCleanup = true
    }

    XCTAssertTrue(didRunWork)
    XCTAssertTrue(didRunCleanup)
  }

  func testThrowingDeferWhenThrowingFromWork() throws {
    let workError = EquatableError()
    var didRunCleanup = false

    XCTAssertThrowsError(try withThrowing {
      throw workError
    } defer: {
      didRunCleanup = true
    }) {
      XCTAssertTrue($0 is EquatableError)
      XCTAssertEqual($0 as? EquatableError, workError)
    }
    XCTAssertTrue(didRunCleanup)
  }

  func testThrowingDeferWhenThrowingFromCleanup() throws {
    var didRunWork = false
    let cleanupError = EquatableError()

    XCTAssertThrowsError(try withThrowing {
      didRunWork = true
    } defer: {
      throw cleanupError
    }) {
      XCTAssertTrue($0 is EquatableError)
      XCTAssertEqual($0 as? EquatableError, cleanupError)
    }
    XCTAssertTrue(didRunWork)
  }

  func testThrowingDeferWhenThrowingFromBothClosures() throws {
    var didRunWork = false
    let workError = EquatableError()
    let cleanupError = EquatableError()

    XCTAssertThrowsError(try withThrowing {
      didRunWork = true
      throw workError
    } defer: {
      throw cleanupError
    }) {
      XCTAssertTrue($0 is EquatableError)
      XCTAssertEqual($0 as? EquatableError, cleanupError)
    }
    XCTAssertTrue(didRunWork)
  }

  // MARK: - Async
  func testAsyncThrowingDeferWithoutThrowing() async throws {
    let work = Worker()
    let cleanup = Worker()

    try await withAsyncThrowing {
      try await work.run()
    } defer: {
      try await cleanup.run()
    }

    let didRunWork = await work.didRun
    let didRunCleanup = await cleanup.didRun
    XCTAssertTrue(didRunWork)
    XCTAssertTrue(didRunCleanup)
  }

  func testAsyncThrowingDeferWhenThrowingFromWork() async throws {
    let workError = EquatableError()
    let work = Worker(error: workError)
    let cleanup = Worker()

    do {
      try await withAsyncThrowing {
        try await work.run()
      } defer: {
        try await cleanup.run()
      }
      XCTFail("No error was thrown!")
    } catch {
      XCTAssertTrue(error is EquatableError)
      XCTAssertEqual(error as? EquatableError, workError)
    }

    let didRunWork = await cleanup.didRun
    let didRunCleanup = await cleanup.didRun
    XCTAssertTrue(didRunWork)
    XCTAssertTrue(didRunCleanup)
  }

  func testAsyncThrowingDeferWhenThrowingFromCleanup() async throws {
    let cleanupError = EquatableError()
    let work = Worker()
    let cleanup = Worker(error: cleanupError)

    do {
      try await withAsyncThrowing {
        try await work.run()
      } defer: {
        try await cleanup.run()
      }
      XCTFail("No error was thrown!")
    } catch {
      XCTAssertTrue(error is EquatableError)
      XCTAssertEqual(error as? EquatableError, cleanupError)
    }

    let didRunWork = await work.didRun
    let didRunCleanup = await cleanup.didRun
    XCTAssertTrue(didRunWork)
    XCTAssertTrue(didRunCleanup)
  }

  func testAsyncThrowingDeferWhenThrowingFromBothClosures() async throws {
    let workError = EquatableError()
    let cleanupError = EquatableError()
    let work = Worker(error: workError)
    let cleanup = Worker(error: cleanupError)

    do {
      try await withAsyncThrowing {
        try await work.run()
        XCTFail("No error was thrown from work!")
      } defer: {
        try await cleanup.run()
      }
      XCTFail("No error was thrown!")
    } catch {
      XCTAssertTrue(error is EquatableError)
      XCTAssertEqual(error as? EquatableError, cleanupError)
    }

    let didRunWork = await work.didRun
    let didRunCleanup = await cleanup.didRun
    XCTAssertTrue(didRunWork)
    XCTAssertTrue(didRunCleanup)
  }
}
