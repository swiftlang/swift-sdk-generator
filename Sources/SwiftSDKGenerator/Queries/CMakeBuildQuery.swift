//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2022-2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import GeneratorEngine
import struct SystemPackage.FilePath

@Query
struct CMakeBuildQuery {
  let sourcesDirectory: FilePath
  /// Path to the output binary relative to the CMake build directory.
  let outputBinarySubpath: [FilePath.Component]
  let options: String

  func run(engine: Engine) async throws -> FilePath {
    try await Shell.run(
      """
      cmake -B build -G Ninja -S llvm -DCMAKE_BUILD_TYPE=Release \(self.options)
      """,
      currentDirectory: self.sourcesDirectory
    )

    let buildDirectory = self.sourcesDirectory.appending("build")
    try await Shell.run("ninja \(FilePath(".").appending(self.outputBinarySubpath))", currentDirectory: buildDirectory)

    return self.outputBinarySubpath.reduce(into: buildDirectory) { $0.append($1) }
  }
}
