// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Fringe",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/LaunchAtLogin-modern", from: "1.1.0")
    ],
    targets: [
        .executableTarget(
            name: "Fringe",
            dependencies: [
                .product(name: "LaunchAtLogin", package: "LaunchAtLogin-modern")
            ]
        ),
        .testTarget(name: "FringeTests", dependencies: ["Fringe"])
    ]
)
