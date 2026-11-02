// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "codex-travel-mode",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "CodexTravelModeSleepLease", targets: ["CodexTravelModeSleepLease"]),
        .library(
            name: "CodexTravelModeSleepLeaseXPC",
            targets: ["CodexTravelModeSleepLeaseXPC"]
        ),
        .library(name: "CodexTravelModeCore", targets: ["CodexTravelModeCore"]),
        .library(
            name: "CodexTravelModeReadiness",
            targets: ["CodexTravelModeReadiness"]
        ),
        .executable(name: "codex-travel-mode", targets: ["CodexTravelModeApp"]),
        .executable(
            name: "codex-travel-mode-readiness",
            targets: ["CodexTravelModeReadinessCLI"]
        ),
        .executable(
            name: "codex-travel-mode-readiness-oracle",
            targets: ["CodexTravelModeOracleCLI"]
        ),
        .executable(
            name: "codex-travel-mode-readiness-observer",
            targets: ["CodexTravelModeObserverCLI"]
        ),
        .executable(
            name: "codex-travel-mode-sleep-helper",
            targets: ["CodexTravelModeSleepHelper"]
        ),
        .executable(
            name: "sleep-override-lease-proof-helper",
            targets: ["SleepOverrideLeaseProofHelper"]
        ),
        .executable(
            name: "sleep-override-lease-proof-owner",
            targets: ["SleepOverrideLeaseProofOwner"]
        ),
        .executable(
            name: "sleep-override-lease-fake-power",
            targets: ["SleepOverrideLeaseFakePower"]
        ),
        .executable(name: "travel-session-proof-host", targets: ["TravelSessionProofHost"]),
        .executable(
            name: "hotspot-configuration-proof-worker",
            targets: ["HotspotConfigurationProofWorker"]
        ),
        .executable(
            name: "iphone-internet-handoff-proof-worker",
            targets: ["IPhoneInternetHandoffProofWorker"]
        )
    ],
    targets: [
        .target(
            name: "CodexTravelModeSleepLease",
            path: "Sources/CodexTravelModeSleepLease"
        ),
        .target(
            name: "CodexTravelModeSleepLeaseXPC",
            dependencies: ["CodexTravelModeSleepLease"],
            path: "Sources/CodexTravelModeSleepLeaseXPC"
        ),
        .target(
            name: "CodexTravelModeCore",
            dependencies: ["CodexTravelModeSleepLease"],
            path: "Sources/CodexTravelModeCore"
        ),
        .target(
            name: "CodexTravelModeReadiness",
            dependencies: ["CodexTravelModeCore", "CodexTravelModeSleepLeaseXPC"],
            path: "Sources/CodexTravelModeReadiness"
        ),
        .target(
            name: "SleepOverrideLeaseProofSupport",
            dependencies: ["CodexTravelModeSleepLease", "CodexTravelModeSleepLeaseXPC"],
            path: "Tests/SleepOverrideLeaseProofSupport"
        ),
        .target(
            name: "HotspotConfigurationProofSupport",
            dependencies: ["CodexTravelModeCore"],
            path: "Tests/HotspotConfigurationProofSupport"
        ),
        .executableTarget(
            name: "CodexTravelModeApp",
            dependencies: ["CodexTravelModeCore", "CodexTravelModeSleepLeaseXPC"],
            path: "Sources/CodexTravelModeApp"
        ),
        .executableTarget(
            name: "CodexTravelModeReadinessCLI",
            dependencies: ["CodexTravelModeReadiness"],
            path: "Sources/CodexTravelModeReadinessCLI"
        ),
        .executableTarget(
            name: "CodexTravelModeOracleCLI",
            dependencies: ["CodexTravelModeReadiness"],
            path: "Sources/CodexTravelModeOracleCLI"
        ),
        .executableTarget(
            name: "CodexTravelModeObserverCLI",
            dependencies: ["CodexTravelModeReadiness"],
            path: "Sources/CodexTravelModeObserverCLI"
        ),
        .executableTarget(
            name: "CodexTravelModeSleepHelper",
            dependencies: ["CodexTravelModeSleepLease", "CodexTravelModeSleepLeaseXPC"],
            path: "Sources/CodexTravelModeSleepHelper"
        ),
        .testTarget(
            name: "CodexTravelModeCoreTests",
            dependencies: [
                "CodexTravelModeCore",
                "CodexTravelModeReadiness",
                "CodexTravelModeSleepLease",
                "CodexTravelModeSleepLeaseXPC",
                "SleepOverrideLeaseProofSupport"
            ],
            path: "Tests/CodexTravelModeCoreTests"
        ),
        .executableTarget(
            name: "SleepOverrideLeaseProofHelper",
            dependencies: ["CodexTravelModeSleepLease", "SleepOverrideLeaseProofSupport"],
            path: "Tests/SleepOverrideLeaseProofHelper"
        ),
        .executableTarget(
            name: "SleepOverrideLeaseProofOwner",
            dependencies: [
                "CodexTravelModeCore",
                "CodexTravelModeSleepLease",
                "CodexTravelModeSleepLeaseXPC",
                "SleepOverrideLeaseProofSupport"
            ],
            path: "Tests/SleepOverrideLeaseProofOwner"
        ),
        .executableTarget(
            name: "SleepOverrideLeaseFakePower",
            dependencies: ["SleepOverrideLeaseProofSupport"],
            path: "Tests/SleepOverrideLeaseFakePower"
        ),
        .executableTarget(
            name: "TravelSessionProofHost",
            dependencies: ["CodexTravelModeCore"],
            path: "Tests/TravelSessionProofHost"
        ),
        .executableTarget(
            name: "HotspotConfigurationProofWorker",
            dependencies: ["CodexTravelModeCore", "HotspotConfigurationProofSupport"],
            path: "Tests/HotspotConfigurationProofWorker"
        ),
        .executableTarget(
            name: "IPhoneInternetHandoffProofWorker",
            dependencies: ["CodexTravelModeCore"],
            path: "Tests/IPhoneInternetHandoffProofWorker"
        )
    ]
)
