//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation

public struct ArtifactsArchiveMetadata: Equatable, Codable {
  public let schemaVersion: String
  public let artifacts: [String: Artifact]

  public init(schemaVersion: String, artifacts: [String: Artifact]) {
    self.schemaVersion = schemaVersion
    self.artifacts = artifacts
  }

  public struct Artifact: Equatable, Codable {
    let type: ArtifactType
    let version: String
    let variants: [Variant]

    public init(
      type: ArtifactsArchiveMetadata.ArtifactType,
      version: String,
      variants: [Variant]
    ) {
      self.type = type
      self.version = version
      self.variants = variants
    }
  }

  public enum ArtifactType: String, RawRepresentable, Codable {
    case swiftSDK
  }

  public struct Variant: Equatable, Codable {
    let path: String
    let supportedTriples: [String]

    public init(path: String, supportedTriples: [String]) {
      self.path = path
      self.supportedTriples = supportedTriples
    }
  }
}
