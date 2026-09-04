// swift-tools-version:5.9
import PackageDescription

// Single logical app. `CharlieKit` holds all source modules (as directories);
// `Charlie` is a thin executable shim so the pure logic stays unit-testable.
let package = Package(
    name: "Charlie",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Charlie", targets: ["Charlie"]),
        .executable(name: "CharlieTests", targets: ["CharlieTests"]),
    ],
    targets: [
        .target(name: "CharlieKit"),
        .executableTarget(
            name: "Charlie",
            dependencies: ["CharlieKit"]
        ),
        // XCTest is unavailable with Command Line Tools only, and the project
        // forbids third-party deps, so pure-logic tests run as a tiny
        // self-contained executable (`swift run CharlieTests`).
        .executableTarget(
            name: "CharlieTests",
            dependencies: ["CharlieKit"],
            path: "Tests/CharlieTests"
        ),
    ]
)
