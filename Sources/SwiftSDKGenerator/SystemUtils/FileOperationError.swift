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

import struct Foundation.URL
import enum NIOHTTP1.HTTPResponseStatus
import struct SystemPackage.FilePath

public enum FileOperationError: Error {
  case downloadFailed(URL, HTTPResponseStatus)
  case directoryCreationFailed(FilePath)
  case downloadFailed(URL)
  case unknownArchiveFormat(String?)
  case nonZeroExitCode(Int32, CommandInfo)
  case symlinkFixupFailed(source: FilePath, destination: FilePath)
}
