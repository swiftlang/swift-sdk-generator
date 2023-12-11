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
  func copyTargetSwiftFromDocker() async throws {
    logGenerationStep("Launching a Docker container to copy Swift SDK for the target triple from it...")
    try await withDockerContainer(fromImage: baseDockerImage!) { containerID in
      let pathsConfiguration = self.pathsConfiguration

      try await inTemporaryDirectory { generator, _ in
        let sdkUsrPath = pathsConfiguration.sdkDirPath.appending("usr")
        let sdkUsrLibPath = sdkUsrPath.appending("lib")
        try await generator.createDirectoryIfNeeded(at: sdkUsrPath)
        try await generator.copyFromDockerContainer(
          id: containerID,
          from: "/usr/include",
          to: sdkUsrPath.appending("include")
        )

        if case .rhel = self.versionsConfiguration.linuxDistribution {
          try await generator.runOnDockerContainer(
            id: containerID,
            command: #"""
            sh -c '
                chmod +w /usr/lib64
                cd /usr/lib64
                for n in *; do
                    destination=$(readlink $n)
                    echo $destination | grep "\.\." && \
                        rm -f $n && \
                        ln -s $(basename $destination) $n
                done
                rm -rf pm-utils
            '
            """#
          )
        }

        if case let containerLib64 = FilePath("/usr/lib64"),
           try await generator.doesPathExist(containerLib64, inContainer: containerID) {
          let sdkUsrLib64Path = sdkUsrPath.appending("lib64")
          // we already checked that the path exists above, so we don't pass `failIfNotExists: false` here.
          try await generator.copyFromDockerContainer(
            id: containerID,
            from: containerLib64,
            to: sdkUsrLib64Path
          )
          try await createSymlink(at: pathsConfiguration.sdkDirPath.appending("lib64"), pointingTo: "./usr/lib64")
        }

        try await generator.createDirectoryIfNeeded(at: sdkUsrLibPath)
        var subpaths: [(subpath: String, failIfNotExists: Bool)] = [
          ("clang", true), ("gcc", true), ("swift", true), ("swift_static", true)
        ]

        // Ubuntu's multiarch directory scheme puts some libraries in
        // architecture-specific directories:
        //   https://wiki.ubuntu.com/MultiarchSpec
        // But not in all containers, so don't fail if it does not exist.
        if case .ubuntu = self.versionsConfiguration.linuxDistribution {
          subpaths += [("\(targetTriple.cpu)-linux-gnu", false)]
        }

        for (subpath, failIfNotExists) in subpaths {
          try await generator.copyFromDockerContainer(
            id: containerID,
            from: FilePath("/usr/lib").appending(subpath),
            to: sdkUsrLibPath.appending(subpath),
            failIfNotExists: failIfNotExists
          )
        }
        try await generator.createSymlink(at: pathsConfiguration.sdkDirPath.appending("lib"), pointingTo: "usr/lib")

        // Python artifacts are redundant.
        try await generator.removeRecursively(at: sdkUsrLibPath.appending("python3.10"))

        try await generator.removeRecursively(at: sdkUsrLibPath.appending("ssl"))
        try await generator.copyTargetSwift(from: sdkUsrLibPath)
      }
    }
  }

  func copyTargetSwift(from distributionPath: FilePath) async throws {
    logGenerationStep("Copying Swift core libraries for the target triple into Swift SDK bundle...")

    for (pathWithinPackage, pathWithinSwiftSDK) in [
      ("swift/linux", pathsConfiguration.toolchainDirPath.appending("usr/lib/swift")),
      ("swift_static/linux", pathsConfiguration.toolchainDirPath.appending("usr/lib/swift_static")),
      ("swift_static/shims", pathsConfiguration.toolchainDirPath.appending("usr/lib/swift_static")),
      ("swift/dispatch", pathsConfiguration.sdkDirPath.appending("usr/include")),
      ("swift/os", pathsConfiguration.sdkDirPath.appending("usr/include")),
      ("swift/CoreFoundation", pathsConfiguration.sdkDirPath.appending("usr/include")),
    ] {
      try await rsync(from: distributionPath.appending(pathWithinPackage), to: pathWithinSwiftSDK)
    }
  }
}
