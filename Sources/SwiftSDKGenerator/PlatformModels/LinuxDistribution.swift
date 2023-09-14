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
  public enum Name: String {
    case rhel
    case ubuntu
  }

  public enum RHEL: String, Sendable {
    case ubi9
  }

  public enum Ubuntu: String, Sendable {
    case bionic
    case focal
    case jammy

    init(version: String) throws {
      self = switch version {
      case "18.04":
        .bionic
      case "20.04":
        .focal
      case "22.04":
        .jammy
      default:
        throw GeneratorError.unknownLinuxDistribution(name: LinuxDistribution.Name.ubuntu.rawValue, version: version)
      }
    }

    var version: String {
      switch self {
      case .bionic: "18.04"
      case .focal: "20.04"
      case .jammy: "22.04"
      }
    }
  }

  case rhel(RHEL)
  case ubuntu(Ubuntu)

  public init(name: Name, version: String) throws {
    switch name {
    case .rhel:
      guard let version = RHEL(rawValue: version) else {
        throw GeneratorError.unknownLinuxDistribution(name: name.rawValue, version: version)
      }
      self = .rhel(version)

    case .ubuntu:
      self = try .ubuntu(Ubuntu(version: version))
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

public extension LinuxDistribution.Name {
  init(nameString: String) throws {
    guard let name = LinuxDistribution.Name(rawValue: nameString) else {
      throw GeneratorError.unknownLinuxDistribution(name: nameString, version: nil)
    }
    self = name
  }
}
