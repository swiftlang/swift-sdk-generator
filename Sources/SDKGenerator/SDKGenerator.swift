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

private struct Platform {
    let cpu: String
    let vendor: String
    let os: String
}

private let availablePlatforms = (
    linux: Platform(
        cpu: "aarch64",
        vendor: "unknown",
        os: "linux"
    ),
    darwin: Platform(
        cpu: "arm64",
        vendor: "apple",
        os: "darwin21.0"
    )
)

private let clangDarwin =
"https://github.com/llvm/llvm-project/releases/download/llvmorg-15.0.3/clang+llvm-15.0.3-\(availablePlatforms.darwin.cpu)-apple-\(availablePlatforms.darwin.os).tar.xz"
private let swiftBranch = "swift-5.7-release"
private let swiftVersion = "5.7-RELEASE"
private let destinationTriple = "\(availablePlatforms.linux.cpu)-unknown-linux-gnu"

private let byteCountFormatter = ByteCountFormatter()

private let generatorWorkspacePath = FilePath(#file)
    .removingLastComponent()
    .removingLastComponent()
    .removingLastComponent()
    .appending("cc-sdk")
    .appending(destinationTriple)

private let sdkRootPath = generatorWorkspacePath
private let sdkDirPath = sdkRootPath.appending("ubuntu-\(ubuntuRelease).sdk")
private let toolchainDirPath = generatorWorkspacePath.appending("swift.xctoolchain")
private let toolchainBinDirPath = toolchainDirPath.appending("usr/bin")
private let artifactsCachePath = sdkRootPath.appending("artifacts-cache")

private let hostURL = URL(string: "https://download.swift.org/\(swiftBranch)/xcode/swift-\(swiftVersion)/swift-\(swiftVersion)-osx.pkg")!
private let destURL = URL(string: """
    https://download.swift.org/\(swiftBranch)/ubuntu\(
        ubuntuVersion.replacingOccurrences(of: ".", with: "")
    )/swift-\(swiftVersion)/swift-\(swiftVersion)-ubuntu\(ubuntuVersion).tar.gz
    """)!
private let clangURL = URL(string: clangDarwin)!

private let destPath = artifactsCachePath.appending("dest.tar.gz")
private let hostPath = artifactsCachePath.appending("host.pkg")
private let clangArchive = artifactsCachePath.appending("clang.tar.xz")

extension FileSystem {
    public func generateSDK(shouldUseDocker: Bool = true) async throws {
        let client = HTTPClient(
            eventLoopGroupProvider: .createNew,
            configuration: .init(
                redirectConfiguration: .follow(max: 5, allowCycles: false)
            )
        )

        defer {
            try! client.syncShutdown()
        }

        try createDirectoryIfNeeded(at: artifactsCachePath)
        try createDirectoryIfNeeded(at: sdkDirPath)
        try createDirectoryIfNeeded(at: toolchainDirPath)

        try await downloadToolchainPackages(client, shouldUseDocker: shouldUseDocker)

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
            print("Fixing `swift-autolink-extract` symlink...")
            try createSymlink(at: autolinkExtractPath, pointingTo: "swift")
        }

        let destinationJSONPath = try generateDestinationJSON()

        print(
            """
            
            All done! Use the sdk as:
            swift build --destination \(destinationJSONPath)
            """
        )
    }

    private func unpackDestinationSDKPackage() async throws {
        print("Unpacking destination Swift SDK package...")

        try await inTemporaryDirectory { fs, tmpDir in
            try await fs.unpack(file: destPath, into: tmpDir)
            try await fs.copyDestinationSDK(from: tmpDir.appending("swift-\(swiftVersion)-ubuntu\(ubuntuVersion)/usr/lib"))
        }
    }

    private func copyDestinationSDKFromDocker() async throws {
        print("Launching a Docker container to copy destination Swift SDK from it...")

        let containerID = try await launchDockerContainer(
            swiftVersion: swiftVersion.components(separatedBy: "-")[0],
            ubuntuRelease: ubuntuRelease
        )

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
        print("Copying Swift core libraries into destination SDK bundle...")

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
        print("Unpacking and copying host toolchain...")

        try await inTemporaryDirectory { fs, tmpDir in
            try await fs.unpack(file: hostPath, into: tmpDir)
            try await fs.rsync(from: tmpDir.appending("usr"), to: toolchainDirPath)
        }
    }

    private func unpackLLDLinker() async throws {
        print("Unpacking and copying `lld` linker...")

        try await inTemporaryDirectory { fs, tmpDir in
            try await fs.untar(file: clangArchive, into: tmpDir, stripComponents: 1)
            try fs.copy(from: tmpDir.appending("bin/lld"), to: toolchainBinDirPath.appending("ld.lld"))
        }
    }

    private func downloadToolchainPackages(_ client: HTTPClient, shouldUseDocker: Bool) async throws {
        print("Downloading required toolchain packages...")

        let hostProgressStream = client.streamDownloadProgress(from: hostURL, to: hostPath)
            .removeDuplicates(by: didProgressChangeSignificantly)
        let destProgressStream = client.streamDownloadProgress(from: destURL, to: destPath)
            .removeDuplicates(by: didProgressChangeSignificantly)
        let clangProgress = client.streamDownloadProgress(from: clangURL, to: clangArchive)
            .removeDuplicates(by: didProgressChangeSignificantly)

        if shouldUseDocker {
            let progressStream = combineLatest(hostProgressStream, clangProgress)
                .throttle(for: .seconds(1))

            for try await (hostProgress, clangProgress) in progressStream {
                report(progress: hostProgress, for: destURL)
                report(progress: clangProgress, for: clangURL)
            }
        } else {
            let progressStream = combineLatest(hostProgressStream, destProgressStream, clangProgress)
                .throttle(for: .seconds(1))

            for try await (hostProgress, destProgress, clangProgress) in progressStream {
                report(progress: hostProgress, for: hostURL)
                report(progress: destProgress, for: destURL)
                report(progress: clangProgress, for: clangURL)
            }
        }
    }

    private func downloadUbuntuPackages(_ client: HTTPClient) async throws {
        print("Parsing Ubuntu packages list...")

        let allPackages = try await parse(packages: client.downloadPackagesList())

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
        print("Fixing up absolute symlinks...")

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
        print("Generating destination JSON file...")

        let destinationJSONPath = sdkRootPath.appending("ubuntu-\(ubuntuRelease)-destination.json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted

        try writeFile(
            at: destinationJSONPath,
            encoder.encode(
                DestinationV1(
                    sdk: sdkDirPath.string,
                    toolchainBinDir: toolchainBinDirPath.string,
                    target: destinationTriple,
                    extraCCFlags: [
                        "-fPIC"
                    ],
                    extraSwiftCFlags: [
                        "-use-ld=lld",
                        "-tools-directory", toolchainBinDirPath.string,
                        "-sdk", sdkDirPath.string,
                        "-Xlinker", "-R/usr/lib/swift/linux/"
                    ],
                    extraCPPFlags: [
                        "-lstdc++"
                    ]
                )
            )
        )

        return destinationJSONPath
    }

    private func fixGlibcModuleMap(at path: FilePath) throws {
        print("Fixing absolute paths in `glibc.modulemap`...")

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
    func downloadPackagesList() async throws -> String {
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

private func parse(packages: String) -> [String: URL] {
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
