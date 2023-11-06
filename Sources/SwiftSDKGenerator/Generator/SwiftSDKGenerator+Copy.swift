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
    let containerID = try await launchDockerContainer(imageName: self.versionsConfiguration.swiftBaseDockerImage)
    do {
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

        let sdkUsrLib64Path = sdkUsrPath.appending("lib64")
        try await generator.copyFromDockerContainer(
          id: containerID,
          from: FilePath("/usr/lib64"),
          to: sdkUsrLib64Path
        )
        try await createSymlink(at: pathsConfiguration.sdkDirPath.appending("lib64"), pointingTo: "./usr/lib64")

        if case .rhel = self.versionsConfiguration.linuxDistribution {
          // `libc.so` is a linker script with absolute paths on RHEL, replace with a relative symlink
          let libcSO = sdkUsrLib64Path.appending("libc.so")
          try await removeFile(at: libcSO)
          try await createSymlink(at: libcSO, pointingTo: "libc.so.6")
        }

        try await generator.createDirectoryIfNeeded(at: sdkUsrLibPath)
        var subpaths =  ["clang", "gcc", "swift", "swift_static"]

        // Ubuntu's multiarch directory scheme puts some libraries in
        // architecture-specific directories:
        //   https://wiki.ubuntu.com/MultiarchSpec
        if case .ubuntu = self.versionsConfiguration.linuxDistribution {
          subpaths += ["\(targetTriple.cpu)-linux-gnu"]
        }

        for subpath in subpaths {
          try await generator.copyFromDockerContainer(
            id: containerID,
            from: FilePath("/usr/lib").appending(subpath),
            to: sdkUsrLibPath.appending(subpath)
          )
        }
        try await generator.createSymlink(at: pathsConfiguration.sdkDirPath.appending("lib"), pointingTo: "usr/lib")

        // Python artifacts are redundant.
        try await generator.removeRecursively(at: sdkUsrLibPath.appending("python3.10"))

        try await generator.removeRecursively(at: sdkUsrLibPath.appending("ssl"))
        try await generator.copyTargetSwift(from: sdkUsrLibPath)
        try await generator.stopDockerContainer(id: containerID)
      }
    } catch {
      try await stopDockerContainer(id: containerID)
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
