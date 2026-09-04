// swift-tools-version:5.9
import PackageDescription

// Single logical app. `NotchlingKit` holds all source modules (as directories);
// `Notchling` is a thin executable shim so the pure logic stays unit-testable.
let package = Package(
    name: "Notchling",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Notchling", targets: ["Notchling"]),
        .executable(name: "NotchlingTests", targets: ["NotchlingTests"]),
    ],
    targets: [
        .target(name: "NotchlingKit"),
        .executableTarget(
            name: "Notchling",
            dependencies: ["NotchlingKit"]
        ),
        // XCTest is unavailable with Command Line Tools only, and the project
        // forbids third-party deps, so pure-logic tests run as a tiny
        // self-contained executable (`swift run NotchlingTests`).
        .executableTarget(
            name: "NotchlingTests",
            dependencies: ["NotchlingKit"],
            path: "Tests/NotchlingTests"
        ),
    ]
)
