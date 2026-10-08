// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CullerKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CullerKit", targets: ["CullerKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "CullerKit",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "CullerKitTests",
            dependencies: ["CullerKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
