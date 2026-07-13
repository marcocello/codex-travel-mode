// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "codex-travel-mode",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "CodexTravelModeCore", targets: ["CodexTravelModeCore"]),
        .executable(name: "codex-travel-mode", targets: ["CodexTravelModeApp"])
    ],
    targets: [
        .target(
            name: "CodexTravelModeCore",
            path: "Sources/CodexTravelModeCore"
        ),
        .executableTarget(
            name: "CodexTravelModeApp",
            dependencies: ["CodexTravelModeCore"],
            path: "Sources/CodexTravelModeApp"
        ),
        .testTarget(
            name: "CodexTravelModeCoreTests",
            dependencies: ["CodexTravelModeCore"],
            path: "Tests/CodexTravelModeCoreTests"
        )
    ]
)
