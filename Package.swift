// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SnowSweepCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SnowSweepCore", targets: ["SnowSweepCore"]),
        .executable(name: "SnowSweepApp", targets: ["SnowSweepApp"]),
        .executable(name: "CleanupE2E", targets: ["CleanupE2E"]),
        .executable(name: "ReleaseSim", targets: ["ReleaseSim"]),
        .executable(name: "SoakTest", targets: ["SoakTest"]),
        .executable(name: "FamilyScan", targets: ["FamilyScan"]),
        .executable(name: "ScannerService", targets: ["ScannerService"]),
        .executable(name: "ModelHost", targets: ["ModelHost"])
    ],
    targets: [
        .target(name: "SnowSweepCore", resources: [
            .copy("Resources/glossary.json"),
            .copy("Resources/software-families.json")
        ]),
        .executableTarget(name: "SnowSweepApp", dependencies: ["SnowSweepCore"]),
        .executableTarget(name: "CleanupE2E", dependencies: ["SnowSweepCore"]),
        .executableTarget(name: "ReleaseSim", dependencies: ["SnowSweepCore"]),
        .executableTarget(name: "SoakTest", dependencies: ["SnowSweepCore"]),
        .executableTarget(name: "FamilyScan", dependencies: ["SnowSweepCore"]),
        .executableTarget(name: "ScannerService", dependencies: ["SnowSweepCore"]),
        .executableTarget(name: "ModelHost", dependencies: ["SnowSweepCore"]),
        .testTarget(name: "SnowSweepCoreTests", dependencies: ["SnowSweepCore"])
    ]
)
