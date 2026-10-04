// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NightCrew",
    platforms: [.macOS("13.5")],
    products: [
        .executable(name: "nightcrew", targets: ["NightCrew"]),
    ],
    targets: [
        // Pure logic, no side effects (SPEC §4).
        .target(name: "NightCrewCore"),
        // App + side effects. For now only the `probe` command.
        .executableTarget(name: "NightCrew", dependencies: ["NightCrewCore"]),
        // swift-testing: the Command Line Tools ship Testing.framework but not XCTest.
        .testTarget(name: "NightCrewCoreTests", dependencies: ["NightCrewCore"]),
    ]
)
