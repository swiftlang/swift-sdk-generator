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

public enum LinuxDistribution: Hashable, Sendable {
  public enum Name: String {
    case rhel
    case ubuntu
    case debian
  }

  public enum RHEL: String, Sendable {
    case ubi9
  }

  public enum Ubuntu: String, Sendable {
    case focal
    case jammy
    case noble

    init(version: String) throws {
      switch version {
      case "20.04":
        self = .focal
      case "22.04":
        self = .jammy
      case "24.04":
        self = .noble
      default:
        throw GeneratorError.unknownLinuxDistribution(
          name: LinuxDistribution.Name.ubuntu.rawValue, version: version)
      }
    }

    var version: String {
      switch self {
      case .focal: return "20.04"
      case .jammy: return "22.04"
      case .noble: return "24.04"
      }
    }

    public var requiredPackages: [String] {
      switch self {
      case .focal:
        return [
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
        ]
      case .jammy:
        return [
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
      case .noble:
        return [
          "libc6",
          "libc6-dev",
          "libgcc-s1",
          "libgcc-13-dev",
          "libicu74",
          "libicu-dev",
          "libstdc++-13-dev",
          "libstdc++6",
          "linux-libc-dev",
          "zlib1g",
          "zlib1g-dev",
        ]
      }
    }
  }

  public enum Debian: String, Sendable {
    case bullseye
    case bookworm

    init(version: String) throws {
      switch version {
      case "11": self = .bullseye
      case "12": self = .bookworm
      default:
        throw GeneratorError.unknownLinuxDistribution(
          name: LinuxDistribution.Name.debian.rawValue, version: version)
      }
    }

    var version: String {
      switch self {
      case .bullseye: return "11"
      case .bookworm: return "12"
      }
    }

    public var requiredPackages: [String] {
      switch self {
      case .bullseye:
        return [
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
        ]
      case .bookworm:
        return [
          "libc6",
          "libc6-dev",
          "libgcc-s1",
          "libgcc-12-dev",
          "libicu72",
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
  case debian(Debian)

  public init(name: Name, version: String) throws {
    switch name {
    case .rhel:
      guard let version = RHEL(rawValue: version) else {
        throw GeneratorError.unknownLinuxDistribution(name: name.rawValue, version: version)
      }
      self = .rhel(version)

    case .ubuntu:
      self = try .ubuntu(Ubuntu(version: version))

    case .debian:
      self = try .debian(Debian(version: version))
    }
  }

  var name: Name {
    switch self {
    case .rhel: return .rhel
    case .ubuntu: return .ubuntu
    case .debian: return .debian
    }
  }

  var release: String {
    switch self {
    case let .rhel(rhel): return rhel.rawValue
    case let .ubuntu(ubuntu): return ubuntu.rawValue
    case let .debian(debian): return debian.rawValue
    }
  }

  var swiftDockerImageSuffix: String {
    switch self {
    case let .rhel(rhel): return "rhel-\(rhel.rawValue)"
    case let .ubuntu(ubuntu): return ubuntu.rawValue
    case let .debian(debian): return debian.rawValue
    }
  }
}

extension LinuxDistribution.Name {
  public init(nameString: String) throws {
    guard let name = LinuxDistribution.Name(rawValue: nameString) else {
      throw GeneratorError.unknownLinuxDistribution(name: nameString, version: nil)
    }
    self = name
  }
}

extension LinuxDistribution: CustomStringConvertible {
  public var description: String {
    let versionComponent: String
    switch self {
    case .rhel:
      versionComponent = self.release.uppercased()
    case .ubuntu, .debian:
      versionComponent = self.release.capitalized
    }

    return "\(self.name) \(versionComponent)"
  }
}

extension LinuxDistribution.Name: CustomStringConvertible {
  public var description: String {
    switch self {
    case .rhel: return "RHEL"
    case .ubuntu: return "Ubuntu"
    case .debian: return "Debian"
    }
  }
}
