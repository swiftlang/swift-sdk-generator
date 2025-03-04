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

import struct Foundation.URL
import struct SystemPackage.FilePath

enum GeneratorError: Error {
  case noProcessOutput(String)
  case unhandledChildProcessSignal(CInt, CommandInfo)
  case nonZeroExitCode(CInt, CommandInfo)
  case unknownLinuxDistribution(name: String, version: String?)
  case unknownMacOSVersion(String)
  case unknownCPUArchitecture(String)
  case unknownLLDVersion(String)
  case distributionSupportsOnlyDockerGenerator(LinuxDistribution)
  case distributionDoesNotSupportArchitecture(LinuxDistribution, targetArchName: String)
  case fileDoesNotExist(FilePath)
  case fileDownloadFailed(URL, String)
  case debianPackagesListDownloadRequiresXz
  case packagesListDecompressionFailure
  case packagesListParsingFailure(expectedPackages: Int, actual: Int)
}

extension GeneratorError: CustomStringConvertible {
  var description: String {
    switch self {
    case let .noProcessOutput(process):
      return "Failed to read standard output of a launched process: \(process)"
    case let .unhandledChildProcessSignal(signal, commandInfo):
      return "Process launched with \(commandInfo) finished due to signal \(signal)"
    case let .nonZeroExitCode(exitCode, commandInfo):
      return "Process launched with \(commandInfo) failed with exit code \(exitCode)"
    case let .unknownLinuxDistribution(name, version):
      return "Linux distribution `\(name)`\(version.map { " with version \($0)" } ?? "")` is not supported by this generator."
    case let .unknownMacOSVersion(version):
      return "macOS version `\(version)` is not supported by this generator."
    case let .unknownCPUArchitecture(cpu):
      return "CPU architecture `\(cpu)` is not supported by this generator."
    case let .unknownLLDVersion(version):
      return "LLD version `\(version)` is not supported by this generator."
    case let .distributionSupportsOnlyDockerGenerator(linuxDistribution):
      return """
      Target Linux distribution \(linuxDistribution) supports Swift SDK generation only when `--with-docker` flag is \
      passed.
      """
    case let .distributionDoesNotSupportArchitecture(linuxDistribution, targetArchName):
      return """
      Target Linux distribution \(linuxDistribution) does not support the target architecture: \(targetArchName)
      """
    case let .fileDoesNotExist(filePath):
      return "Expected to find a file at path `\(filePath)`."
    case let .fileDownloadFailed(url, status):
      return "File could not be downloaded from a URL `\(url)`, the server returned status `\(status)`."
    case .debianPackagesListDownloadRequiresXz:
      return "Downloading the Debian packages list requires xz, and it is not installed."
    case .packagesListDecompressionFailure:
      return "Failed to decompress the list of packages."
    case let .packagesListParsingFailure(expected, actual):
      return "Failed to parse packages manifest, expected \(expected), found \(actual) packages."
    }
  }
}
