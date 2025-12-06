#if canImport(Testing)
  import Testing
  @testable import SwiftSDKGenerator

  struct LinuxDistributionTests {
    struct UbuntuTests {
      @Test(arguments: [
        ("20.04", LinuxDistribution.Ubuntu.focal),
        ("focal", LinuxDistribution.Ubuntu.focal),

        ("22.04", LinuxDistribution.Ubuntu.jammy),
        ("jammy", LinuxDistribution.Ubuntu.jammy),

        ("24.04", LinuxDistribution.Ubuntu.noble),
        ("noble", LinuxDistribution.Ubuntu.noble),
      ])
      func validVersionStrings(versionString: String, expectedVersion: LinuxDistribution.Ubuntu) throws {
        let version = try LinuxDistribution.Ubuntu(version: versionString)
        #expect(version == expectedVersion)
      }

      @Test(arguments: [
        "18.04",
        "bionic",
        "unknown",
        "invalid",
      ]) func invalidVersionStrings(versionString: String) throws {
        #expect(throws: GeneratorError.self) {
          let _ = try LinuxDistribution.Ubuntu(version: versionString)
        }
      }

      @Test(arguments: [
        (LinuxDistribution.Ubuntu.focal, "20.04"),
        (LinuxDistribution.Ubuntu.jammy, "22.04"),
        (LinuxDistribution.Ubuntu.noble, "24.04"),
      ])
      func versionProperty(ubuntuVersion: LinuxDistribution.Ubuntu, expectedVersionString: String) {
        #expect(ubuntuVersion.version == expectedVersionString)
      }

      @Test(arguments: LinuxDistribution.Ubuntu.allCases)
      func requiredPackages(ubuntuVersion: LinuxDistribution.Ubuntu) {
        let commonPackages = [
          "libc6",
          "libc6-dev",
          "libgcc-s1",
          "libstdc++6",
          "linux-libc-dev",
          "zlib1g",
          "zlib1g-dev",
          "libicu-dev",
          "libcurl4-openssl-dev",
        ]

        let requiredPackages = ubuntuVersion.requiredPackages
        #expect(requiredPackages.starts(with: commonPackages))

        // Some required packages that change versions between Ubuntu versions
        #expect(requiredPackages.contains(where: { $0.matches(regex: "libgcc-\\d{2}-dev") }))
        #expect(requiredPackages.contains(where: { $0.matches(regex: "libicu\\d{2}") }))
        #expect(requiredPackages.contains(where: { $0.matches(regex: "libstdc\\+\\+-\\d{2}-dev") }))
      }
    }

    struct DebianTests {
      @Test(arguments: [
        ("11", LinuxDistribution.Debian.bullseye),
        ("bullseye", LinuxDistribution.Debian.bullseye),

        ("12", LinuxDistribution.Debian.bookworm),
        ("bookworm", LinuxDistribution.Debian.bookworm),

        ("13", LinuxDistribution.Debian.trixie),
        ("trixie", LinuxDistribution.Debian.trixie),
      ])
      func validVersionStrings(versionString: String, expectedVersion: LinuxDistribution.Debian) throws {
        let version = try LinuxDistribution.Debian(version: versionString)
        #expect(version == expectedVersion)
      }

      @Test(arguments: [
        "9",
        "sid",
        "unknown",
        "invalid",
      ]) func invalidVersionStrings(versionString: String) throws {
        #expect(throws: GeneratorError.self) {
          let _ = try LinuxDistribution.Debian(version: versionString)
        }
      }

      @Test(arguments: [
        (LinuxDistribution.Debian.bullseye, "11"),
        (LinuxDistribution.Debian.bookworm, "12"),
        (LinuxDistribution.Debian.trixie, "13"),
      ])
      func versionProperty(debianVersion: LinuxDistribution.Debian, expectedVersionString: String) {
        #expect(debianVersion.version == expectedVersionString)
      }

      @Test(arguments: LinuxDistribution.Debian.allCases)
      func requiredPackages(debianVersion: LinuxDistribution.Debian) {
        let commonPackages = [
          "libc6",
          "libc6-dev",
          "libgcc-s1",
          "libstdc++6",
          "linux-libc-dev",
          "zlib1g",
          "zlib1g-dev",
          "libicu-dev",
          "libcurl4-openssl-dev",
        ]

        let requiredPackages = debianVersion.requiredPackages
        #expect(requiredPackages.starts(with: commonPackages))

        // Some required packages that change versions between Debian versions
        #expect(requiredPackages.contains(where: { $0.matches(regex: "libgcc-\\d{2}-dev") }))
        #expect(requiredPackages.contains(where: { $0.matches(regex: "libicu\\d{2}") }))
        #expect(requiredPackages.contains(where: { $0.matches(regex: "libstdc\\+\\+-\\d{2}-dev") }))
      }
    }

    @Test(arguments: [
      (LinuxDistribution.Name.rhel, "ubi9", "ubi9", "rhel-ubi9"),
      (LinuxDistribution.Name.ubuntu, "22.04", "jammy", "jammy"),
      (LinuxDistribution.Name.debian, "12", "bookworm", "bookworm"),
    ])
    func distributionProperties(
      name: LinuxDistribution.Name,
      version: String,
      expectedRelease: String,
      expectedImageSuffix: String
    ) throws {
      let distribution = try LinuxDistribution(name: name, version: version)

      #expect(distribution.name == name)
      #expect(distribution.release == expectedRelease)
      #expect(distribution.swiftDockerImageSuffix == expectedImageSuffix)
      #expect(distribution.description.isEmpty == false)
    }

    @Test(arguments: [
      ("rhel", LinuxDistribution.Name.rhel),
      ("ubuntu", LinuxDistribution.Name.ubuntu),
      ("debian", LinuxDistribution.Name.debian),
    ]) func validDistributionNames(nameString: String, expectedName: LinuxDistribution.Name, ) throws {
      let name = try LinuxDistribution.Name(nameString: nameString)
      #expect(name == expectedName)
    }

    @Test(arguments: [
      "amazonlinux",
      "fedora",
      "opensuse",
    ]) func invalidDistributionNames(name: String) throws {
      #expect(throws: GeneratorError.self) {
        let _ = try LinuxDistribution.Name(nameString: name)
      }
    }

    @Test(arguments: [
      (LinuxDistribution.Name.rhel, "ubi8"),
      (LinuxDistribution.Name.ubuntu, "18.04"),
      (LinuxDistribution.Name.debian, "9"),
    ]) func invalidDistributionVersions(
      name: LinuxDistribution.Name,
      version: String
    ) throws {
      #expect(throws: GeneratorError.self) {
        let _ = try LinuxDistribution(name: name, version: version)
      }
    }
  }

  extension String {
    func matches(regex: String) -> Bool {
      return self.range(of: regex, options: .regularExpression) != nil
    }
  }
#endif
