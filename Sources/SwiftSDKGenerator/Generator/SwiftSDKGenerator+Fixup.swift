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

import RegexBuilder
import SystemPackage

import struct Foundation.Data

extension SwiftSDKGenerator {
  func fixAbsoluteSymlinks(sdkDirPath: FilePath) throws {
    logGenerationStep("Fixing up absolute symlinks...")

    for (source, absoluteDestination) in try findSymlinks(at: sdkDirPath).filter({
      $1.string.hasPrefix("/")
    }) {
      guard !absoluteDestination.string.hasPrefix("/etc") else {
        try removeFile(at: source)
        continue
      }
      var relativeSource = source
      var relativeDestination = FilePath()

      let isPrefixRemoved = relativeSource.removePrefix(sdkDirPath)
      precondition(isPrefixRemoved)
      for _ in relativeSource.removingLastComponent().components {
        relativeDestination.append("..")
      }

      relativeDestination.push(absoluteDestination.removingRoot())
      try removeRecursively(at: source)
      try createSymlink(at: source, pointingTo: relativeDestination)

      guard doesFileExist(at: source) else {
        throw FileOperationError.symlinkFixupFailed(
          source: source,
          destination: absoluteDestination
        )
      }
    }
  }

  func fixGlibcModuleMap(at path: FilePath) throws {
    logGenerationStep("Fixing absolute paths in `glibc.modulemap`...")

    guard doesFileExist(at: path) else {
      throw GeneratorError.fileDoesNotExist(path)
    }

    let privateIncludesPath = path.removingLastComponent().appending("private_includes")
    try removeRecursively(at: privateIncludesPath)
    try createDirectoryIfNeeded(at: privateIncludesPath)

    let regex = Regex {
      #/\n( *header )"\/+usr\/include\//#
      Capture {
        Optionally {
          hostTriple.cpu.linuxConventionName
          "-linux-gnu"
        }
      }
      #/([^\"]+)\"/#
    }

    var moduleMap = try String(data: readFile(at: path), encoding: .utf8)!
    try moduleMap.replace(regex) {
      let (_, headerKeyword, _, headerPath) = $0.output

      let newHeaderRelativePath = headerPath.replacing("/", with: "_")
      try writeFile(
        at: privateIncludesPath.appending(String(newHeaderRelativePath)),
        Data("#include <linux/uuid.h>\n".utf8)
      )

      return #"\#n\#(headerKeyword) "private_includes/\#(newHeaderRelativePath)""#
    }

    try writeFile(at: path, Data(moduleMap.utf8))
  }

  func symlinkClangHeaders() throws {
    try self.createSymlink(
      at: self.pathsConfiguration.toolchainDirPath.appending("usr/lib/swift_static/clang"),
      pointingTo: "../swift/clang"
    )
  }
}
