//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2022-2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import SystemPackage

extension SwiftSDKGenerator {
  func buildLLD(llvmSourcesDirectory: FilePath) async throws -> FilePath {
    let buildDirectory = try await self.buildCMakeProject(llvmSourcesDirectory)

    return buildDirectory.appending("bin").appending("lld")
  }
}
