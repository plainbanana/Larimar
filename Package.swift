// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Larimar",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "LarimarDaemon", targets: ["LarimarDaemon"]),
        .executable(name: "larimar", targets: ["LarimarCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "LarimarShared",
            dependencies: [],
            path: "Sources/LarimarShared"
        ),
        .executableTarget(
            name: "LarimarDaemon",
            dependencies: ["LarimarShared"],
            path: "Sources/LarimarDaemon"
        ),
        .executableTarget(
            name: "LarimarCLI",
            dependencies: [
                "LarimarShared",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/LarimarCLI"
        ),
        .executableTarget(
            name: "larimar-test",
            dependencies: ["LarimarShared"],
            path: "Tests/LarimarSharedTests"
        ),
    ]
)
