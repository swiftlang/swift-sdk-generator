//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation

/// A raw decoding of toolset configuration stored on disk.
struct Toolset: Encodable {
  /// Tools currently known and used by SwiftPM.
  enum KnownTool: String, Encodable {
    case swiftCompiler
    case cCompiler
    case cxxCompiler
    case linker
    case librarian
    case debugger
    case testRunner
    case xcbuild
  }

  /// Properties of a tool in a ``DecodedToolset``.
  struct ToolProperties: Encodable {
    /// Either a relative or an absolute path to the tool on the filesystem.
    var path: String?

    /// Command-line options to be passed to the tool when it's invoked.
    var extraCLIOptions: [String]?
  }

  /// Version of a toolset schema used for decoding a toolset file.
  let schemaVersion = "1.0"

  /// Root path of the toolset, if present. When filling in ``Toolset.ToolProperties/path``, if a raw path string in
  /// ``DecodedToolset`` is inferred to be relative, it's resolved as absolute path relatively to `rootPath`.
  let rootPath: String?

  /// Dictionary of known tools mapped to their properties.
  let tools: [KnownTool: ToolProperties]
}
