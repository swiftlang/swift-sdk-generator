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
    ),
  ],
  dependencies: [
    // Dependencies declare other packages that this package depends on.
    .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.17.0"),
    .package(url: "https://github.com/apple/swift-system", from: "1.2.1"),
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.2.2"),
    .package(url: "https://github.com/apple/swift-async-algorithms.git", from: "0.1.0"),
  ],
  targets: [
    // Targets are the basic building blocks of a package. A target can define a module or a test suite.
    // Targets can depend on other targets in this package, and on products in packages this package depends on.
    .executableTarget(
      name: "GeneratorCLI",
      dependencies: [
        "SwiftSDKGenerator",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]
    ),
    .target(
      name: "SwiftSDKGenerator",
      dependencies: [
        .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
        .product(name: "SystemPackage", package: "swift-system"),
      ]
    ),
  ]
)
