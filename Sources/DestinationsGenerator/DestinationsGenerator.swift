//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import AsyncAlgorithms
import AsyncHTTPClient
import FileUtils
import Foundation
import RegexBuilder
import SystemPackage
import FileUtils

private let ubuntuMirror = "http://gb.archive.ubuntu.com/ubuntu"
private let ubuntuRelease = "jammy"
private let ubuntuVersion = "22.04"
private let packagesFile = "\(ubuntuMirror)/dists/\(ubuntuRelease)/main/binary-amd64/Packages.gz"

private struct Triple: CustomStringConvertible {
    let cpu: String
    let vendor: String
    let os: String
    var abi: String?

    var description: String { "\(cpu)-\(vendor)-\(os)\(abi != nil ? "-\(abi!)" : "")" }
}

private let availablePlatforms = (
    linux: Triple(
        cpu: "aarch64",
        vendor: "unknown",
        os: "linux",
        abi: "gnu"
    ),
    // Used to download LLVM distribution.
    darwin: Triple(
        cpu: "arm64",
        vendor: "apple",
        os: "darwin22.0"
    ),
    // Used to download Swift distribution.
    macOS: Triple(
        cpu: "arm64",
        vendor: "apple",
        os: "macosx13.0"
    )
)

private let llvmVersion = "15.0.7"
private let llvmDarwin =
    """
    https://github.com/llvm/llvm-project/releases/download/llvmorg-\(
        llvmVersion
    )/clang+llvm-\(
        llvmVersion
    )-\(availablePlatforms.darwin.cpu)-apple-\(availablePlatforms.darwin.os).tar.xz
    """
private let swiftBranch = "swift-5.7.2-release"
private let swiftVersion = "5.7.2-RELEASE"

private let byteCountFormatter = ByteCountFormatter()

private let sourceRoot = FilePath(#file)
    .removingLastComponent()
    .removingLastComponent()
    .removingLastComponent()

private let artifactBundlePath = sourceRoot
    .appending("cc-destination.artifactbundle")

private let artifactID = "5.7.2_ubuntu_jammy"

private let destinationRootPath = artifactBundlePath
    .appending(artifactID)
    .appending(availablePlatforms.linux.description)

private let sdkDirPath = destinationRootPath.appending("ubuntu-\(ubuntuRelease).sdk")
private let toolchainDirPath = destinationRootPath.appending("swift.xctoolchain")
private let toolchainBinDirPath = toolchainDirPath.appending("usr/bin")
private let artifactsCachePath = sourceRoot.appending("artifacts-cache")

private let toolchainPackages = [hostPath, destPath, llvmArchivePath]

private let hostURL = URL(string: "https://download.swift.org/\(swiftBranch)/xcode/swift-\(swiftVersion)/swift-\(swiftVersion)-osx.pkg")!
private let destURL = URL(string: """
    https://download.swift.org/\(swiftBranch)/ubuntu\(
        ubuntuVersion.replacingOccurrences(of: ".", with: "")
    )/swift-\(swiftVersion)/swift-\(swiftVersion)-ubuntu\(ubuntuVersion).tar.gz
    """)!
private let llvmURL = URL(string: llvmDarwin)!

private let destPath = artifactsCachePath.appending("\(availablePlatforms.linux).tar.gz")
private let hostPath = artifactsCachePath.appending("\(availablePlatforms.macOS).pkg")
private let llvmArchivePath = artifactsCachePath.appending("llvm-\(availablePlatforms.macOS).tar.xz")

extension FileSystem {
    public func generateDestinationBundle(shouldUseDocker: Bool, shouldGenerateFromScratch: Bool) async throws {
        let client = HTTPClient(
            eventLoopGroupProvider: .createNew,
            configuration: .init(
                redirectConfiguration: .follow(max: 5, allowCycles: false)
            )
        )

        defer {
            try! client.syncShutdown()
        }

        if shouldGenerateFromScratch {
            try removeRecursively(at: sdkDirPath)
            try removeRecursively(at: toolchainDirPath)
        }

        try createDirectoryIfNeeded(at: artifactsCachePath)
        try createDirectoryIfNeeded(at: sdkDirPath)
        try createDirectoryIfNeeded(at: toolchainDirPath)

        if try await !checkArtifactsCache() {
            try await downloadToolchainPackages(client, shouldUseDocker: shouldUseDocker)
        }

        if !shouldUseDocker {
            try await downloadUbuntuPackages(client)
        }

        try await unpackHostToolchain()

        if shouldUseDocker {
            try await copyDestinationSDKFromDocker()
        } else {
            try await unpackDestinationSDKPackage()
        }

        try await unpackLLDLinker()

        try fixAbsoluteSymlinks()

        try fixGlibcModuleMap(at: toolchainDirPath.appending("/usr/lib/swift/linux/\(availablePlatforms.linux.cpu)/glibc.modulemap"))

        let autolinkExtractPath = toolchainBinDirPath.appending("swift-autolink-extract")

        if !doesFileExist(at: autolinkExtractPath) {
            logGenerationStep("Fixing `swift-autolink-extract` symlink...")
            try createSymlink(at: autolinkExtractPath, pointingTo: "swift")
        }

        let destinationJSONPath = try generateDestinationJSON()

        try generateArtifactBundleManifest()

        logGenerationStep(
            """
            All done! Use the sdk as:
            swift build --destination \(destinationJSONPath)
            """
        )
    }

    private func unpackDestinationSDKPackage() async throws {
        logGenerationStep("Unpacking destination Swift SDK package...")

        try await inTemporaryDirectory { fs, tmpDir in
            try await fs.unpack(file: destPath, into: tmpDir)
            try await fs.copyDestinationSDK(from: tmpDir.appending("swift-\(swiftVersion)-ubuntu\(ubuntuVersion)/usr/lib"))
        }
    }

    private func copyDestinationSDKFromDocker() async throws {

        let imageName = "swiftlang/swift-cc-destination:\(swiftVersion.components(separatedBy: "-")[0])-\(ubuntuRelease)"

        logGenerationStep("Building a Docker image with the destination environment...")
        try await buildDockerImage(name: imageName, dockerfileDirectory: sourceRoot.appending("Dockerfiles"))

        logGenerationStep("Launching a Docker container to copy destination Swift SDK from it...")
        let containerID = try await launchDockerContainer(imageName: imageName)

        try await inTemporaryDirectory { fs, tmpDir in
            let sdkUsrPath = sdkDirPath.appending("usr")
            let sdkUsrLibPath = sdkUsrPath.appending("lib")
            try fs.createDirectoryIfNeeded(at: sdkUsrPath)
            try await fs.copyFromDockerContainer(id: containerID, from: "/usr/include", to: sdkUsrPath.appending("include"))
            try await fs.copyFromDockerContainer(id: containerID, from: "/usr/lib", to: sdkUsrLibPath)
            try fs.createSymlink(at: sdkDirPath.appending("lib"), pointingTo: "usr/lib")
            try fs.removeRecursively(at: sdkUsrLibPath.appending("ssl"))
            try await fs.copyDestinationSDK(from: sdkUsrLibPath)
        }
    }

    private func copyDestinationSDK(from destinationPackagePath: FilePath) async throws {
        logGenerationStep("Copying Swift core libraries into destination SDK bundle...")

        for (pathWithinPackage, destinationBundlePath) in [
            ("swift/linux", toolchainDirPath.appending("usr/lib/swift")),
            ("swift_static/linux", toolchainDirPath.appending("usr/lib/swift_static")),
            ("swift/dispatch", sdkDirPath.appending("usr/include")),
            ("swift/os", sdkDirPath.appending("usr/include")),
            ("swift/CoreFoundation", sdkDirPath.appending("usr/include")),
        ] {
            try await rsync(
                from: destinationPackagePath.appending(pathWithinPackage),
                to: destinationBundlePath
            )
        }
    }

    private func unpackHostToolchain() async throws {
        logGenerationStep("Unpacking and copying host toolchain...")

        try await inTemporaryDirectory { fs, tmpDir in
            try await fs.unpack(file: hostPath, into: tmpDir)
            try await fs.rsync(from: tmpDir.appending("usr"), to: toolchainDirPath)
        }
    }

    private func unpackLLDLinker() async throws {
        logGenerationStep("Unpacking and copying `lld` linker...")

        try await inTemporaryDirectory { fs, tmpDir in
            try await fs.untar(file: llvmArchivePath, into: tmpDir, stripComponents: 1)
            try fs.copy(from: tmpDir.appending("bin/lld"), to: toolchainBinDirPath.appending("ld.lld"))
        }
    }

    /// Check whether files in `artifactsCachePath` can be reused instead of downloading them.
    /// - Returns: `true` if artifacts are valid, `false` otherwise.
    private func checkArtifactsCache() async throws -> Bool {
        logGenerationStep("Checking packages cache...")

        guard toolchainPackages.contains(where: doesFileExist(at:)) else {
            return false
        }

        async let hostChecksum = Self.computeChecksum(file: hostPath)
        async let destChecksum = Self.computeChecksum(file: destPath)
        async let llvmChecksum = Self.computeChecksum(file: llvmArchivePath)

        return try await [hostChecksum, destChecksum, llvmChecksum] == [
            "fa9a18aa2e63d9a8532e640a86900dca0fb6d1361b7af22c77423b5cdef3ed2b",
            "e729912846b0cff98bf8e0e5ede2e17bc2d1098de3cdb6fa13b3ff52c36ee5d6",
            "867c6afd41158c132ef05a8f1ddaecf476a26b91c85def8e124414f9a9ba188d"
        ]
    }

    private func downloadToolchainPackages(_ client: HTTPClient, shouldUseDocker: Bool) async throws {
        logGenerationStep("Downloading required toolchain packages...")

        let hostProgressStream = client.streamDownloadProgress(from: hostURL, to: hostPath)
            .removeDuplicates(by: didProgressChangeSignificantly)
        let destProgressStream = client.streamDownloadProgress(from: destURL, to: destPath)
            .removeDuplicates(by: didProgressChangeSignificantly)
        let llvmProgress = client.streamDownloadProgress(from: llvmURL, to: llvmArchivePath)
            .removeDuplicates(by: didProgressChangeSignificantly)

        if shouldUseDocker {
            let progressStream = combineLatest(hostProgressStream, llvmProgress)
                .throttle(for: .seconds(1))

            for try await (hostProgress, llvmProgress) in progressStream {
                report(progress: hostProgress, for: destURL)
                report(progress: llvmProgress, for: llvmURL)
            }
        } else {
            let progressStream = combineLatest(hostProgressStream, destProgressStream, llvmProgress)
                .throttle(for: .seconds(1))

            for try await (hostProgress, destProgress, llvmProgress) in progressStream {
                report(progress: hostProgress, for: hostURL)
                report(progress: destProgress, for: destURL)
                report(progress: llvmProgress, for: llvmURL)
            }
        }
    }

    private func downloadUbuntuPackages(_ client: HTTPClient) async throws {
        logGenerationStep("Parsing Ubuntu packages list...")

        let allPackages = try await parse(ubuntuPackagesList: client.downloadUbuntuPackagesList())

        let requiredPackages = ["libc6-dev", "linux-libc-dev", "libicu70", "libgcc-12-dev", "libicu-dev", "libc6", "libgcc-s1", "libstdc++-12-dev", "libstdc++6", "zlib1g", "zlib1g-dev"]
        let urls = requiredPackages.compactMap { allPackages[$0] }

        print("Downloading \(urls.count) Ubuntu packages...")
        try await inTemporaryDirectory { fs, tmpDir in
            let progress = try await client.downloadFiles(from: urls, to: tmpDir)
            report(downloadedFiles: Array(zip(urls, progress.map(\.receivedBytes))))

            for fileName in urls.map(\.lastPathComponent) {
                try await fs.unpack(file: tmpDir.appending(fileName), into: sdkDirPath)
            }
        }

        try createDirectoryIfNeeded(at: toolchainBinDirPath)
    }

    private func fixAbsoluteSymlinks() throws {
        logGenerationStep("Fixing up absolute symlinks...")

        for (source, absoluteDestination) in try findSymlinks(at: sdkDirPath).filter({ $1.string.hasPrefix("/") }) {
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

            guard FileManager.default.fileExists(atPath: source.string) else {
                throw FileOperationError.symlinkFixupFailed(source: source, destination: absoluteDestination)
            }
        }
    }

    private func generateDestinationJSON() throws -> FilePath {
        logGenerationStep("Generating destination JSON file...")

        let destinationJSONPath = destinationRootPath.appending("destination.json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted

        var relativeToolchainBinDir = toolchainBinDirPath
        var relativeSDKDir = sdkDirPath

        guard
            relativeToolchainBinDir.removePrefix(destinationRootPath),
            relativeSDKDir.removePrefix(destinationRootPath)
        else {
            fatalError(
                "`toolchainBinDirPath` and `sdkDirPath` are at unexpected locations that prevent computing relative paths"
            )
        }

        try writeFile(
            at: destinationJSONPath,
            encoder.encode(
                DestinationV2(
                    sdkRootDir: relativeSDKDir.string,
                    toolchainBinDir: relativeToolchainBinDir.string,
                    hostTriples: [availablePlatforms.macOS.description],
                    targetTriples: [availablePlatforms.linux.description],
                    extraCCFlags: [
                        "-fPIC"
                    ],
                    extraSwiftCFlags: [
                        "-use-ld=lld",
                        "-Xlinker", "-R/usr/lib/swift/linux/"
                    ],
                    extraCXXFlags: [
                        "-lstdc++"
                    ],
                    extraLinkerFlags: []
                )
            )
        )

        return destinationJSONPath
    }

    private func generateArtifactBundleManifest() throws {
        logGenerationStep("Generating .artifactbundle manifest file...")

        let artifactBundleManifestPath = artifactBundlePath.appending("info.json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted

        try writeFile(
            at: artifactBundleManifestPath,
            encoder.encode(
                ArtifactsArchiveMetadata(
                    schemaVersion: "1.0",
                    artifacts: [
                        "ubuntu22.04_aarch64": .init(
                            type: .crossCompilationDestination,
                            version: "0.0.1",
                            variants: [
                                .init(
                                    path: FilePath(artifactID).appending(availablePlatforms.linux.description).string,
                                    supportedTriples: [availablePlatforms.macOS.description]
                                )
                            ]
                        )
                    ]
                )
            )
        )
    }

    private func fixGlibcModuleMap(at path: FilePath) throws {
        logGenerationStep("Fixing absolute paths in `glibc.modulemap`...")

        let privateIncludesPath = path.removingLastComponent().appending("private_includes")
        try removeRecursively(at: privateIncludesPath)
        try createDirectoryIfNeeded(at: privateIncludesPath)

        let regex = Regex {
            #/\n( *header )"\/+usr\/include\//#
            Capture {
                Optionally {
                    availablePlatforms.linux.cpu
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
}

private struct DestinationV1: Encodable {
    enum CodingKeys: String, CodingKey {
        case version
        case sdk
        case toolchainBinDir = "toolchain-bin-dir"
        case target
        case extraCCFlags = "extra-cc-flags"
        case extraSwiftCFlags = "extra-swiftc-flags"
        case extraCPPFlags = "extra-cpp-flags"
    }

    let version = 1
    let sdk: String
    let toolchainBinDir: String
    let target: String
    let extraCCFlags: [String]
    let extraSwiftCFlags: [String]
    let extraCPPFlags: [String]
}

private struct DestinationV2: Encodable {
    let version = 2

    let sdkRootDir: String
    let toolchainBinDir: String
    let hostTriples: [String]
    let targetTriples: [String]
    let extraCCFlags: [String]
    let extraSwiftCFlags: [String]
    let extraCXXFlags: [String]
    let extraLinkerFlags: [String]
}

/// Checks whether two given progress value are different enough from each other. Used for filtering out progress values
/// in async streams with `removeDuplicates` operator.
/// - Parameters:
///   - previous: Preceding progress value in the stream.
///   - current: Currently processed progress value in the stream.
/// - Returns: `true` if `totalBytes` value is different by any amount or if `receivedBytes` is different by amount
/// larger than 1MiB. Returns `false` otherwise.
@Sendable
private func didProgressChangeSignificantly(
    previous: FileDownloadDelegate.Progress,
    current: FileDownloadDelegate.Progress
) -> Bool {
    guard previous.totalBytes == current.totalBytes else {
        return true
    }

    return current.receivedBytes - previous.receivedBytes > 1024 * 1024 * 1024
}

private func report(progress: FileDownloadDelegate.Progress, for url: URL) {
    if let total = progress.totalBytes {
        print("""
        \(url.lastPathComponent) \(byteCountFormatter.string(fromByteCount: Int64(progress.receivedBytes)))/\(byteCountFormatter.string(fromByteCount: Int64(total)))
        """)
    } else {
        print("\(url.lastPathComponent) \(byteCountFormatter.string(fromByteCount: Int64(progress.receivedBytes)))")
    }
}

private func report(downloadedFiles: [(URL, Int)]) {
    for (url, bytes) in downloadedFiles {
        print("\(url) – \(byteCountFormatter.string(fromByteCount: Int64(bytes)))")
    }
}

extension HTTPClient {
    func downloadUbuntuPackagesList() async throws -> String {
        guard let packages = try await get(url: packagesFile).get().body else {
            throw FileOperationError.downloadFailed(URL(string: packagesFile)!)
        }

        var result = ""
        for try await chunk in try packages.unzip() {
            result.append(String(data: chunk, encoding: .utf8)!)
        }

        return result
    }
}

private func parse(ubuntuPackagesList packages: String) -> [String: URL] {
    let packageRef = Reference(Substring.self)
    let pathRef = Reference(Substring.self)

    let regex = Regex {
        "Package: "

        Capture(as: packageRef) {
            OneOrMore(.anyNonNewline)
        }

        OneOrMore(.any, .reluctant)

        "Filename: "

        Capture(as: pathRef) {
            OneOrMore(.anyNonNewline)
        }

        Anchor.endOfLine

        OneOrMore(.any, .reluctant)

        "Description-md5: "

        OneOrMore(.hexDigit)
    }

    var result = [String: URL]()
    for match in packages.matches(of: regex) {
        guard let url = URL(string: "\(ubuntuMirror)/\(match[pathRef])") else { continue }

        result[String(match[packageRef])] = url
    }

    return result
}

private func logGenerationStep(_ message: String) {
    print("\n\(message)")
}