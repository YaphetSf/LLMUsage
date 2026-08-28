// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LLMUsage",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "LLMUsage_Tracker", targets: ["LLMUsage_Tracker"]),
        .executable(name: "LLMUsage", targets: ["LLMUsage"])
    ],
    targets: [
        .target(name: "LLMUsagePreferences", path: "Sources/LLMUsagePreferences"),
        /// Local usage history: reads what the agent CLIs already wrote to disk. Shared because
        /// both executables need it — the control center renders the Usage page from it, and the
        /// tracker can price a menu-bar spend figure from the same scan.
        .target(name: "LLMUsageHistory", path: "Sources/LLMUsageHistory"),
        .target(
            name: "LLMUsageUI",
            dependencies: ["LLMUsagePreferences"],
            path: "Sources/LLMUsageUI",
            resources: [.copy("Resources")],
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .executableTarget(
            name: "LLMUsage_Tracker",
            dependencies: ["LLMUsagePreferences", "LLMUsageUI", "LLMUsageHistory"],
            path: "Sources/LLMUsage_Tracker",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "LLMUsage",
            dependencies: ["LLMUsagePreferences", "LLMUsageUI", "LLMUsageHistory"],
            path: "Sources/LLMUsage",
            linkerSettings: [
                .linkedFramework("AppKit")
            ]
        ),
        .testTarget(
            name: "LLMUsageHistoryTests",
            dependencies: ["LLMUsageHistory"],
            path: "Tests/LLMUsageHistoryTests"
        ),
        .testTarget(
            name: "LLMUsageTests",
            dependencies: ["LLMUsage", "LLMUsageHistory"],
            path: "Tests/LLMUsageTests"
        ),
        .testTarget(
            name: "LLMUsage_TrackerTests",
            dependencies: ["LLMUsage_Tracker", "LLMUsageUI", "LLMUsageHistory"],
            path: "Tests/LLMUsage_TrackerTests"
        )
    ]
)
