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

/// A raw decoding of toolset configuration stored on disk.
public struct Toolset: Encodable {
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

  // MARK: Tools currently known and used by SwiftPM.

  var swiftCompiler: ToolProperties?
  var cCompiler: ToolProperties?
  var cxxCompiler: ToolProperties?
  var linker: ToolProperties?
  var librarian: ToolProperties?
  var debugger: ToolProperties?
  var testRunner: ToolProperties?
  var xcbuild: ToolProperties?
}
