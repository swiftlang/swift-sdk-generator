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

import SystemPackage

extension SwiftSDKGenerator {
  func buildLLD(llvmSourcesDirectory: FilePath) async throws -> FilePath {
    let buildDirectory = try await self.buildCMakeProject(
      llvmSourcesDirectory,
      options: "-DLLVM_ENABLE_PROJECTS=lld -DLLVM_TARGETS_TO_BUILD=\(self.targetTriple.cpu.llvmTargetConventionName)"
    )

    return buildDirectory.appending("bin").appending("lld")
  }
}
