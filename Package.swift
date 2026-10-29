// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacAppUpdater",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AppUpdater", targets: ["AppUpdater"]),
        .executable(name: "PrivilegedHelper", targets: ["PrivilegedHelper"]),
        .library(name: "AppUpdaterCore", targets: ["AppUpdaterCore"]),
        .library(name: "MaintenanceCore", targets: ["MaintenanceCore"]),
        .library(name: "MonitorCore", targets: ["MonitorCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(name: "AppUpdaterCore", resources: [.process("Resources")]),
        /// Disk cleanup: caches, developer junk, old installers and large forgotten files.
        /// Depends on AppUpdaterCore only to reuse its leftover rules and app discovery.
        .target(name: "MaintenanceCore", dependencies: ["AppUpdaterCore"]),
        /// System monitor and task manager: CPU, memory, disk, network, battery, processes, ports.
        .target(name: "MonitorCore"),
        .executableTarget(
            name: "AppUpdater",
            dependencies: [
                "AppUpdaterCore",
                "MaintenanceCore",
                "MonitorCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            resources: [.process("Resources")],
            linkerSettings: [
                // Inside AppUpdater.app, Sparkle.framework lives in Contents/Frameworks.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .executableTarget(name: "PrivilegedHelper", dependencies: ["AppUpdaterCore"]),
        .testTarget(name: "AppUpdaterCoreTests", dependencies: ["AppUpdaterCore"]),
        .testTarget(name: "MaintenanceCoreTests", dependencies: ["MaintenanceCore", "AppUpdaterCore"]),
        .testTarget(name: "MonitorCoreTests", dependencies: ["MonitorCore"]),
        .testTarget(name: "AppUpdaterTests", dependencies: ["AppUpdater"]),
    ]
)
