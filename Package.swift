// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "TokenTick",
  defaultLocalization: "en",
  platforms: [.macOS("26.0")],
  products: [
    .library(
      name: "TokenTickCore",
      targets: ["TokenTickCore"]
    ),
    .library(
      name: "TokenTickUpdates",
      targets: ["TokenTickUpdates"]
    ),
    .library(
          name: "TokenTickTelemetry",
          targets: [ "TokenTickTelemetry" ]
      ),
  ],
  dependencies: [
    .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
    .package(url: "https://github.com/facebook/zstd.git", exact: "1.5.7"),
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
    .package(url: "https://github.com/getsentry/sentry-cocoa.git", exact: "9.26.0"),
  ],
  targets: [
    .target(
      name: "TokenTickCore",
      dependencies: [
        .product(name: "GRDB", package: "GRDB.swift"),
        .product(name: "libzstd", package: "zstd"),
      ], path: "TokenTick/Core", resources: [.copy("Pricing/openai-default-prices.json"), .process("Resources")]),
    .testTarget(
      name: "TokenTickCoreTests",
      dependencies: ["TokenTickCore",.product(name: "GRDB", package: "GRDB.swift"),.product(name: "libzstd", package: "zstd"),]
    ),
    .target(
      name: "TokenTickUpdates",
      dependencies: ["Sparkle"],
      path: "TokenTick/Updates"
    ),
    .target(name: "TokenTickTelemetry",dependencies: [
    .product(name: "Sentry", package: "sentry-cocoa"),]),
    .testTarget(
          name: "TokenTickTelemetryTests",
          dependencies: [ "TokenTickTelemetry", .target(name: "TokenTickUpdates"),]
      ),
  ]
)
