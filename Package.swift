// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import CompilerPluginSupport
import PackageDescription

let package = Package(
  name: "swift-sdk-generator",
  platforms: [.macOS("13.3")],
  products: [
    // Products define the executables and libraries a package produces, and make them visible to other packages.
    .executable(
      name: "swift-sdk-generator",
      targets: ["GeneratorCLI"]
    ),
  ],
  dependencies: [
    // Dependencies declare other packages that this package depends on.
    .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.19.0"),
    .package(url: "https://github.com/apple/swift-system", from: "1.2.1"),
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.2.2"),
    .package(url: "https://github.com/apple/swift-async-algorithms.git", exact: "1.0.0-beta.1"),
    .package(url: "https://github.com/apple/swift-atomics.git", from: "1.1.0"),
    .package(url: "https://github.com/apple/swift-collections.git", from: "1.0.5"),
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.1.0"),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.63.0"),
    .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.20.0"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.5.3"),
    .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.3.0"),
    .package(url: "https://github.com/apple/swift-syntax.git", from: "509.0.2"),
    .package(
        url: "https://github.com/apple/swift-foundation.git",
        revision: "74fefa176b26a49c9a461dda4bfca9b0a1e7cdcd"
    ),
  ],
  targets: [
    // Targets are the basic building blocks of a package. A target can define a module or a test suite.
    // Targets can depend on other targets in this package, and on products in packages this package depends on.
    .executableTarget(
      name: "GeneratorCLI",
      dependencies: [
        "SwiftSDKGenerator",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
        .product(name: "FoundationInternationalization", package: "swift-foundation")
      ],
      swiftSettings: [
        .enableExperimentalFeature("StrictConcurrency=complete"),
      ]
    ),
    .target(
      name: "SwiftSDKGenerator",
      dependencies: [
        .target(name: "AsyncProcess"),
        .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
        .product(name: "Logging", package: "swift-log"),
        .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
        .product(name: "SystemPackage", package: "swift-system"),
        "GeneratorEngine",
        "Helpers",
      ],
      exclude: ["Dockerfiles"],
      swiftSettings: [
        .enableExperimentalFeature("StrictConcurrency=complete"),
      ]
    ),
    .testTarget(
      name: "SwiftSDKGeneratorTests",
      dependencies: [
        "SwiftSDKGenerator",
      ],
      swiftSettings: [
        .enableExperimentalFeature("StrictConcurrency=complete"),
      ]
    ),
    .target(
      name: "GeneratorEngine",
      dependencies: [
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "Logging", package: "swift-log"),
        .product(name: "SystemPackage", package: "swift-system"),
        "Helpers",
        "Macros",
        "SystemSQLite",
      ]
    ),
    .testTarget(
      name: "GeneratorEngineTests",
      dependencies: [
        "GeneratorEngine",
      ]
    ),
    .target(
      name: "Helpers",
      exclude: ["Vendor/README.md"],
      swiftSettings: [
        .enableExperimentalFeature("StrictConcurrency=complete"),
      ]
    ),
    .testTarget(
      name: "HelpersTests",
      dependencies: [
        "Helpers",
      ]
    ),
    .macro(
      name: "Macros",
      dependencies: [
        .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
        .product(name: "SwiftSyntax", package: "swift-syntax"),
        .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
        .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
        .product(name: "SwiftDiagnostics", package: "swift-syntax"),
      ]
    ),
    .testTarget(
      name: "MacrosTests",
      dependencies: [
        "Macros",
        .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
        .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
      ]
    ),
    .systemLibrary(name: "SystemSQLite", pkgConfig: "sqlite3"),
    .target(
      name: "AsyncProcess",
      dependencies: [
        .product(name: "Atomics", package: "swift-atomics"),
        .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
        .product(name: "Logging", package: "swift-log"),
        .product(name: "NIO", package: "swift-nio"),
        .product(name: "NIOExtras", package: "swift-nio-extras"),
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
  ]
)
