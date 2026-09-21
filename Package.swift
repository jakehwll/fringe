// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Fringe",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Fringe"),
        .testTarget(name: "FringeTests", dependencies: ["Fringe"]),
    ]
)
