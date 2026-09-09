// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "TokenTick",
  platforms: [.macOS("26.0")],
  products: [
    .library(
      name: "TokenTickCore",
      targets: ["TokenTickCore"]
    )
  ],
  dependencies: [
    .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
    .package(url: "https://github.com/facebook/zstd.git", exact: "1.5.7"),
  ],
  targets: [
    .target(
      name: "TokenTickCore",
      dependencies: [
        .product(name: "GRDB", package: "GRDB.swift"),
        .product(name: "libzstd", package: "zstd"),
      ], path: "TokenTick/Core"),
    .testTarget(
      name: "TokenTickCoreTests",
      dependencies: ["TokenTickCore",.product(name: "GRDB", package: "GRDB.swift"),.product(name: "libzstd", package: "zstd"),]
    ),
  ]
)
