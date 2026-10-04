// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NightCrew",
    platforms: [.macOS("13.5")],
    targets: [
        // Pure logic, no side effects (SPEC §4).
        .target(name: "NightCrewCore"),
        // swift-testing: the Command Line Tools ship Testing.framework but not XCTest.
        .testTarget(name: "NightCrewCoreTests", dependencies: ["NightCrewCore"]),
    ]
)
