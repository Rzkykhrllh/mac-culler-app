// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CullerKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CullerKit", targets: ["CullerKit"]),
        .executable(name: "culler-bench", targets: ["CullerBench"]),
        .executable(name: "culler-similar", targets: ["CullerSimilar"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "CullerKit",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        // Read-only performance benchmark against a real folder: `swift run -c release culler-bench <folder>`.
        .executableTarget(name: "CullerBench", dependencies: ["CullerKit"]),
        // Prototype for grouping similar photos with Vision feature prints: `swift run -c release culler-similar <folder>`.
        .executableTarget(name: "CullerSimilar", dependencies: ["CullerKit"]),
        .testTarget(
            name: "CullerKitTests",
            dependencies: ["CullerKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
