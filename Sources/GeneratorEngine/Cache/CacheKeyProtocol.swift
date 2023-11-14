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

import Macros

@_exported import protocol Crypto.HashFunction
import struct Foundation.URL
import struct SystemPackage.FilePath

/// Indicates that values of a conforming type can be hashed with an arbitrary hashing function. Unlike `Hashable`,
/// this protocol doesn't utilize random seed values and produces consistent hash values across process launches.
public protocol CacheKeyProtocol {
  func hash(with hashFunction: inout some HashFunction)
}

extension Bool: CacheKeyProtocol {
  public func hash(with hashFunction: inout some HashFunction) {
    String(reflecting: Self.self).hash(with: &hashFunction)
    hashFunction.update(data: self ? [1] : [0])
  }
}

extension Int: CacheKeyProtocol {
  public func hash(with hashFunction: inout some HashFunction) {
    String(reflecting: Self.self).hash(with: &hashFunction)
    withUnsafeBytes(of: self) {
      hashFunction.update(bufferPointer: $0)
    }
  }
}

extension String: CacheKeyProtocol {
  public func hash(with hashFunction: inout some HashFunction) {
    var t = String(reflecting: Self.self)
    t.withUTF8 {
      hashFunction.update(bufferPointer: .init($0))
    }
    var x = self
    x.withUTF8 {
      hashFunction.update(bufferPointer: .init($0))
    }
  }
}

extension FilePath: CacheKeyProtocol {
  public func hash(with hashFunction: inout some HashFunction) {
    String(reflecting: Self.self).hash(with: &hashFunction)
    self.string.hash(with: &hashFunction)
  }
}

extension FilePath.Component: CacheKeyProtocol {
  public func hash(with hashFunction: inout some HashFunction) {
    String(reflecting: Self.self).hash(with: &hashFunction)
    self.string.hash(with: &hashFunction)
  }
}

extension URL: CacheKeyProtocol {
  public func hash(with hashFunction: inout some HashFunction) {
    String(reflecting: Self.self).hash(with: &hashFunction)
    self.description.hash(with: &hashFunction)
  }
}

extension Optional: CacheKeyProtocol where Wrapped: CacheKeyProtocol {
  public func hash(with hashFunction: inout some HashFunction) {
    String(reflecting: Self.self).hash(with: &hashFunction)
    if let self {
      true.hash(with: &hashFunction)
      self.hash(with: &hashFunction)
    } else {
      false.hash(with: &hashFunction)
    }
  }
}

extension Array: CacheKeyProtocol where Element: CacheKeyProtocol {
  public func hash(with hashFunction: inout some HashFunction) {
    String(reflecting: Self.self).hash(with: &hashFunction)
    for element in self {
      element.hash(with: &hashFunction)
    }
  }
}

@attached(extension, conformances: CacheKeyProtocol, names: named(hash(with:)))
public macro CacheKey() = #externalMacro(module: "Macros", type: "CacheKeyMacro")
