// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "swift-sdk-generator",
  platforms: [.macOS(.v13)],
  products: [
    // Products define the executables and libraries a package produces, and make them visible to other packages.
    .executable(
      name: "swift-sdk-generator",
      targets: ["GeneratorCLI"]
    )
  ],
  targets: [
    // Targets are the basic building blocks of a package. A target can define a module or a test suite.
    // Targets can depend on other targets in this package, and on products in packages this package depends on.
    .executableTarget(
      name: "GeneratorCLI",
      dependencies: [
        "SwiftSDKGenerator",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ],
      swiftSettings: [
        .enableExperimentalFeature("StrictConcurrency=complete")
      ]
    ),
    .target(
      name: "SwiftSDKGenerator",
      dependencies: [
        .target(name: "AsyncProcess"),
        .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
        .product(name: "NIOHTTP1", package: "swift-nio"),
        .product(name: "Logging", package: "swift-log"),
        .product(name: "SystemPackage", package: "swift-system"),
        "Helpers",
      ],
      exclude: ["Dockerfiles"],
      swiftSettings: [
        .enableExperimentalFeature("StrictConcurrency=complete")
      ]
    ),
    .testTarget(
      name: "SwiftSDKGeneratorTests",
      dependencies: [
        "SwiftSDKGenerator"
      ],
      swiftSettings: [
        .enableExperimentalFeature("StrictConcurrency=complete")
      ]
    ),
    .testTarget(
      name: "GeneratorEngineTests",
      dependencies: [
        "Helpers"
      ]
    ),
    .target(
      name: "Helpers",
      dependencies: [
        .product(name: "SwiftToolchainCSQLite", package: "swift-toolchain-sqlite"),
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "Logging", package: "swift-log"),
        .product(name: "SystemPackage", package: "swift-system"),
      ],
      exclude: ["Vendor/README.md"],
      swiftSettings: [
        .enableExperimentalFeature("StrictConcurrency=complete")
      ]
    ),
    .testTarget(
      name: "HelpersTests",
      dependencies: [
        "Helpers"
      ]
    ),
    .target(
      name: "AsyncProcess",
      dependencies: [
        .product(name: "Atomics", package: "swift-atomics"),
        .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
        .product(name: "Logging", package: "swift-log"),
        .product(name: "NIO", package: "swift-nio"),
        .product(name: "DequeModule", package: "swift-collections"),
        .product(name: "SystemPackage", package: "swift-system"),
      ]
    ),
    .testTarget(
      name: "AsyncProcessTests",
      dependencies: [
        "AsyncProcess",
        .product(name: "Atomics", package: "swift-atomics"),
        .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
        .product(name: "NIO", package: "swift-nio"),
        .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
        .product(name: "Logging", package: "swift-log"),
      ]
    ),
  ],
  swiftLanguageVersions: [.v5, .version("6")]
)

struct Configuration {
  let useAsyncHttpClient: Bool
  let useLocalDependencies: Bool
  init(SWIFT_SDK_GENERATOR_DISABLE_AHC: Bool, SWIFTCI_USE_LOCAL_DEPS: Bool) {
    self.useAsyncHttpClient = !SWIFT_SDK_GENERATOR_DISABLE_AHC && !SWIFTCI_USE_LOCAL_DEPS
    self.useLocalDependencies = SWIFTCI_USE_LOCAL_DEPS
  }
}

let configuration = Configuration(
  SWIFT_SDK_GENERATOR_DISABLE_AHC: Context.environment["SWIFT_SDK_GENERATOR_DISABLE_AHC"] != nil,
  SWIFTCI_USE_LOCAL_DEPS: Context.environment["SWIFTCI_USE_LOCAL_DEPS"] != nil
)

if configuration.useAsyncHttpClient {
  package.dependencies.append(
    .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.19.0")
  )
  let targetsToAppend: Set<String> = ["SwiftSDKGenerator", "Helpers"]
  for target in package.targets.filter({ targetsToAppend.contains($0.name) }) {
    target.dependencies.append(
      .product(name: "AsyncHTTPClient", package: "async-http-client")
    )
  }
}

if configuration.useLocalDependencies {
  package.dependencies += [
    .package(path: "../swift-system"),
    .package(path: "../swift-argument-parser"),
    .package(path: "../swift-async-algorithms"),
    .package(path: "../swift-atomics"),
    .package(path: "../swift-collections"),
    .package(path: "../swift-crypto"),
    .package(path: "../swift-nio"),
    .package(path: "../swift-log"),
    .package(path: "../swift-toolchain-sqlite"),
  ]
} else {
  package.dependencies += [
    .package(url: "https://github.com/apple/swift-system", from: "1.3.0"),
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.4.0"),
    .package(url: "https://github.com/apple/swift-async-algorithms.git", exact: "1.0.1"),
    .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0"),
    .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.2"),
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.1.0"),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.5.4"),
    .package(url: "https://github.com/swiftlang/swift-toolchain-sqlite.git", from: "1.0.0"),
  ]
}
