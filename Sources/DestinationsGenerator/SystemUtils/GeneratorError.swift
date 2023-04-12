//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import struct SystemPackage.FilePath

enum GeneratorError: Error {
  case unknownUbuntuVersion(String)
  case unknownMacOSVersion(String)
  case unknownCPUArchitecture(String)
  case fileDoesNotExist(FilePath)
  case ubuntuPackagesParsingFailure(expectedPackages: Int, actual: Int)
}

extension GeneratorError: CustomStringConvertible {
  var description: String {
    switch self {
    case let .unknownUbuntuVersion(version):
      return "Ubuntu Linux version `\(version)` is not supported by this generator."
    case let .unknownMacOSVersion(version):
      return "macOS version `\(version)` is not supported by this generator."
    case let .unknownCPUArchitecture(cpu):
      return "CPU architecture `\(cpu)` is not supported by this generator."
    case let .fileDoesNotExist(filePath):
      return "Expected to find a file at path `\(filePath)`"
    case let .ubuntuPackagesParsingFailure(expected, actual):
      return "Failed to parse Ubuntu packages manifest, expected \(expected), found \(actual) packages"
    }
  }
}
