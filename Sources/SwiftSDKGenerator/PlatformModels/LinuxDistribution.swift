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

private let ubuntuReleases = [
  "22.04": "jammy",
]

public enum LinuxDistribution: Hashable, Sendable {
  public enum RHEL: String, Sendable {
    case ubi9
  }

  public enum Ubuntu: String, Sendable {
    case jammy

    init(version: String) throws {
      switch version {
      case "22.04":
        self = .jammy
      default:
        throw GeneratorError.unknownLinuxDistribution(name: "Ubuntu", version: version)
      }
    }

    var version: String {
      switch self {
      case .jammy: "22.04"
      }
    }
  }

  case rhel(RHEL)
  case ubuntu(Ubuntu)

  public init(name: String, version: String) throws {
    switch name.lowercased() {
    case "rhel":
      guard let version = RHEL(rawValue: version) else {
        throw GeneratorError.unknownLinuxDistribution(name: name, version: version)
      }
      self = .rhel(version)

    case "ubuntu":
      self = .ubuntu(try Ubuntu(version: version))

    default:
      throw GeneratorError.unknownLinuxDistribution(name: name, version: version)
    }
  }

  var name: String {
    switch self {
    case .rhel: "rhel"
    case .ubuntu: "ubuntu"
    }
  }

  var release: String {
    switch self {
    case let .rhel(rhel): rhel.rawValue
    case let .ubuntu(ubuntu): ubuntu.rawValue
    }
  }

  var swiftDockerImageSuffix: String {
    switch self {
    case let .rhel(rhel): "rhel-\(rhel.rawValue)"
    case let .ubuntu(ubuntu): ubuntu.rawValue
    }
  }
}
