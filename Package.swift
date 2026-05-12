// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Rollpaper",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "Rollpaper",
            targets: ["App"]
        )
    ],
    targets: [
        .executableTarget(
            name: "App"
        ),
        .testTarget(
            name: "RollpaperTests",
            dependencies: ["App"],
            path: "Tests/RollpaperTests"
        )
    ]
)
