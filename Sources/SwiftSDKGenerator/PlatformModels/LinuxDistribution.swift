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
    case focal
    case jammy

    init(version: String) throws {
      self = switch version {
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
      case .focal: "20.04"
      case .jammy: "22.04"
      }
    }

    public var requiredPackages: [String] {
      switch self {
      case .focal: [
          "libc6",
          "libc6-dev",
          "libgcc-s1",
          "libgcc-10-dev",
          "libicu66",
          "libicu-dev",
          "libstdc++-10-dev",
          "libstdc++6",
          "linux-libc-dev",
          "zlib1g",
          "zlib1g-dev",
          "libc6",
        ]
      case .jammy: [
          "libc6",
          "libc6-dev",
          "libgcc-s1",
          "libgcc-12-dev",
          "libicu70",
          "libicu-dev",
          "libstdc++-12-dev",
          "libstdc++6",
          "linux-libc-dev",
          "zlib1g",
          "zlib1g-dev",
        ]
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

  var name: Name {
    switch self {
    case .rhel: .rhel
    case .ubuntu: .ubuntu
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

extension LinuxDistribution: CustomStringConvertible {
  public var description: String {
    let versionComponent = switch self {
    case .rhel:
      self.release.uppercased()
    case .ubuntu:
      self.release.capitalized
    }

    return "\(self.name) \(versionComponent)"
  }
}

extension LinuxDistribution.Name: CustomStringConvertible {
  public var description: String {
    switch self {
    case .rhel: "RHEL"
    case .ubuntu: "Ubuntu"
    }
  }
}
