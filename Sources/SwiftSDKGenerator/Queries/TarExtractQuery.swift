//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2022-2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Helpers

import struct SystemPackage.FilePath

struct TarExtractQuery: CachingQuery {
  var file: FilePath  // Archive to extract
  var into: FilePath  // Destination for unpacked archive
  var outputBinarySubpath: [FilePath.Component]
  var stripComponents: Int? = nil

  func run(engine: QueryEngine) async throws -> FilePath {
    let stripComponentsOption = stripComponents.map { " --strip-components \($0)" } ?? ""
    let archivePath = self.file
    let destinationPath = self.into

    try await Shell.run(
      #"tar -C "\#(destinationPath)" -x -f "\#(archivePath)" \#(stripComponentsOption) \#(FilePath("*").appending(outputBinarySubpath))"#,
      logStdout: true
    )

    // We must return a path to a single file which the cache will track
    return destinationPath.appending(outputBinarySubpath)
  }
}
