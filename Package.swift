// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Specchio",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.8.1"),
    ],
    targets: [
        .executableTarget(
            name: "Specchio",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Specchio",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "SpecchioTests",
            dependencies: ["Specchio"],
            path: "SpecchioTests"
        )
    ]
)
