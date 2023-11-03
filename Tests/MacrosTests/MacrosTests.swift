//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Macros
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

final class MacrosTests: XCTestCase {
  private let macros: [String: Macro.Type] = ["CacheKey": CacheKeyMacro.self, "Query": QueryMacro.self]

  func testCacheKeyDerived() {
    assertMacroExpansion(
      """
      @CacheKey
      struct Message {
        let text: String
        let sender: String
      }

      @Query
      struct Q {
        let number: Int
        let text: String
      }
      """,
      expandedSource: """
      struct Message {
        let text: String
        let sender: String
      }
      struct Q {
        let number: Int
        let text: String
      }

      extension Message: CacheKeyProtocol {
        func hash(with hashFunction: inout some HashFunction) {
          String(reflecting: Self.self).hash(with: &hashFunction)
          text.hash(with: &hashFunction)
          sender.hash(with: &hashFunction)
        }
      }

      extension Q: QueryProtocol {
      }

      extension Q: CacheKeyProtocol {
        func hash(with hashFunction: inout some HashFunction) {
          String(reflecting: Self.self).hash(with: &hashFunction)
          number.hash(with: &hashFunction)
          text.hash(with: &hashFunction)
        }
      }
      """,
      macros: self.macros,
      indentationWidth: .spaces(2)
    )
  }
}
