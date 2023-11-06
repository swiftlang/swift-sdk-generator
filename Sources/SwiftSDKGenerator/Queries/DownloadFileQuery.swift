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
import GeneratorEngine
import struct SystemPackage.FilePath

@Query
struct DownloadFileQuery {
    let remoteURL: URL
    let localDirectory: FilePath

    func run(engine: Engine) async throws -> FilePath {
        let downloadedFilePath = self.localDirectory.appending(self.remoteURL.lastPathComponent)
        _ = try await engine.httpClient.downloadFile(from: self.remoteURL, to: downloadedFilePath)
        return downloadedFilePath
    }
}
