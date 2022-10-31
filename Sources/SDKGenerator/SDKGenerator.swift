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
private let destinationCPUArch = "x86_64"
private let clangDarwin =
    "https://github.com/llvm/llvm-project/releases/download/llvmorg-13.0.1/clang+llvm-13.0.1-\(destinationCPUArch)-apple-darwin.tar.xz"
private let swiftBranch = "swift-5.7-release"
private let swiftVersion = "5.7-RELEASE"
private let destinationTriple = "\(destinationCPUArch)-unknown-linux-gnu"

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

extension FileSystem {
    public func generateSDK() async throws {
        let client = HTTPClient(
            eventLoopGroupProvider: .createNew,
            configuration: .init(
                redirectConfiguration: .follow(max: 5, allowCycles: false)
            )
        )

        defer {
            try! client.syncShutdown()
        }

        let artifactsCachePath = sdkRootPath.appending("artifacts-cache")
        try createDirectoryIfNeeded(at: artifactsCachePath)

        try createDirectoryIfNeeded(at: sdkDirPath)
        try createDirectoryIfNeeded(at: toolchainDirPath)

        let hostURL = URL(string: "https://download.swift.org/\(swiftBranch)/xcode/swift-\(swiftVersion)/swift-\(swiftVersion)-osx.pkg")!
        let destURL = URL(string: """
        https://download.swift.org/\(swiftBranch)/ubuntu\(
            ubuntuVersion.replacingOccurrences(of: ".", with: "")
        )/swift-\(swiftVersion)/swift-\(swiftVersion)-ubuntu\(ubuntuVersion).tar.gz
        """)!
        let clangURL = URL(string: clangDarwin)!

        let destPath = artifactsCachePath.appending("dest.tar.gz")
        let hostPath = artifactsCachePath.appending("host.pkg")
        let clangArchive = artifactsCachePath.appending("clang.tar.xz")

        let hostProgressStream = client.streamDownloadProgress(from: hostURL, to: hostPath)
            .removeDuplicates(by: didProgressChangeSignificantly)
        let destProgressStream = client.streamDownloadProgress(from: destURL, to: destPath)
            .removeDuplicates(by: didProgressChangeSignificantly)
        let clangProgress = client.streamDownloadProgress(from: clangURL, to: clangArchive)
            .removeDuplicates(by: didProgressChangeSignificantly)

        let progressStream = combineLatest(hostProgressStream, destProgressStream, clangProgress)
            .throttle(for: .seconds(1))

        print("Downloading required packages...")
        for try await (hostProgress, destProgress, clangProgress) in progressStream {
            report(progress: hostProgress, for: hostURL)
            report(progress: destProgress, for: destURL)
            report(progress: clangProgress, for: clangURL)
        }

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

        print("Unpacking and copying `lld` linker...")
        try await inTemporaryDirectory { fs, tmpDir in
            try await fs.untar(file: clangArchive, into: tmpDir, stripComponents: 1)
            try fs.copy(from: tmpDir.appending("bin/lld"), to: toolchainBinDirPath.appending("ld.lld"))
        }

        print("Fixing up absolute symlinks...")
        try fixAbsoluteSymlinks()

        print("Unpacking and copying host toolchain...")
        try await inTemporaryDirectory { fs, tmpDir in
            try await fs.unpack(file: hostPath, into: tmpDir)
            try await fs.rsync(from: tmpDir.appending("usr"), to: toolchainDirPath)
        }

        print("Unpacking and copying destination Swift SDK...")
        try await inTemporaryDirectory { fs, tmpDir in
            try await fs.unpack(file: destPath, into: tmpDir)

            for (source, destination) in [
                ("swift/linux", toolchainDirPath.appending("usr/lib/swift")),
                ("swift_static/linux", toolchainDirPath.appending("usr/lib/swift_static")),
                ("swift/dispatch", sdkDirPath.appending("usr/include")),
                ("swift/os", sdkDirPath.appending("usr/include")),
                ("swift/CoreFoundation", sdkDirPath.appending("usr/include")),
            ] {
                try await fs.rsync(
                    from: tmpDir.appending("swift-\(swiftVersion)-ubuntu\(ubuntuVersion)/usr/lib/\(source)"),
                    to: destination
                )
            }
        }

        print("Fixing absolute paths in `glibc.modulemap`...")
        try fixGlibcModuleMap(at: toolchainDirPath.appending("/usr/lib/swift/linux/\(destinationCPUArch)/glibc.modulemap"))

        let autolinkExtractPath = toolchainBinDirPath.appending("swift-autolink-extract")

        if !doesFileExist(at: autolinkExtractPath) {
            print("Fixing `swift-autolink-extract` symlink...")
            try createSymlink(at: autolinkExtractPath, pointingTo: "swift")
        }

        print("Generating destination JSON file...")
        let destinationJSONPath = sdkRootPath.appending("ubuntu-\(ubuntuRelease)-destination.json")
        try generateDestinationJSON(at: destinationJSONPath)

        print(
            """
            
            All done! Use the sdk as:
            swift build --destination \(destinationJSONPath)
            """
        )
    }

    private func fixAbsoluteSymlinks() throws {
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

    private func generateDestinationJSON(at path: FilePath) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted

        try writeFile(
            at: path,
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
                    ],
                    extraCPPFlags: [
                        "-lstdc++"
                    ]
                )
            )
        )
    }

    private func fixGlibcModuleMap(at path: FilePath) throws {
        let privateIncludesPath = path.removingLastComponent().appending("private_includes")
        try removeRecursively(at: privateIncludesPath)
        try createDirectoryIfNeeded(at: privateIncludesPath)

        let regex = Regex {
            #/\n( *header )"\/+usr\/include\//#
            Capture {
                Optionally {
                    destinationCPUArch
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
