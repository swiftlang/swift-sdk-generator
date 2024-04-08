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
import struct SystemPackage.FilePath

public enum FileOperationError: Error {
  case downloadFailed(URL, String)
  case directoryCreationFailed(FilePath)
  case downloadFailed(String)
  case unknownArchiveFormat(String?)
  case symlinkFixupFailed(source: FilePath, destination: FilePath)
}
