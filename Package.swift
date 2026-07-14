// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ClaudeNotch",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/MrKai77/DynamicNotchKit", exact: "1.1.0")
    ],
    targets: [
        .executableTarget(
            name: "ClaudeNotch",
            dependencies: [
                .product(name: "DynamicNotchKit", package: "DynamicNotchKit")
            ],
            path: "Sources/ClaudeNotch"
        ),
        .testTarget(
            name: "ClaudeNotchTests",
            dependencies: ["ClaudeNotch"],
            path: "Tests/ClaudeNotchTests"
        )
    ]
)
