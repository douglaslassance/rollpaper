// swift-tools-version: 5.9
import PackageDescription
import Foundation

// Sparkle is omitted for App Store builds (Apple forbids auto-update mechanisms).
let isAppStore = ProcessInfo.processInfo.environment["APPSTORE_BUILD"] == "1"

let dependencies: [Package.Dependency] = isAppStore ? [] : [
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.0.0")
]

let appTargetDeps: [Target.Dependency] = isAppStore ? [] : [
    .product(name: "Sparkle", package: "Sparkle")
]

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
    dependencies: dependencies,
    targets: [
        .executableTarget(
            name: "App",
            dependencies: appTargetDeps,
            resources: [
                .copy("Resources/RealESRGANx4v3.mlmodelc")
            ]
        ),
        .testTarget(
            name: "RollpaperTests",
            dependencies: ["App"],
            path: "Tests/RollpaperTests"
        )
    ]
)
