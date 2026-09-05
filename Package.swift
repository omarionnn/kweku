// swift-tools-version:5.9
import PackageDescription

// Single logical app. `KwekuKit` holds all source modules (as directories);
// `Kweku` is a thin executable shim so the pure logic stays unit-testable.
let package = Package(
    name: "Kweku",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Kweku", targets: ["Kweku"]),
        .executable(name: "KwekuTests", targets: ["KwekuTests"]),
    ],
    targets: [
        .target(name: "KwekuKit"),
        .executableTarget(
            name: "Kweku",
            dependencies: ["KwekuKit"]
        ),
        // XCTest is unavailable with Command Line Tools only, and the project
        // forbids third-party deps, so pure-logic tests run as a tiny
        // self-contained executable (`swift run KwekuTests`).
        .executableTarget(
            name: "KwekuTests",
            dependencies: ["KwekuKit"],
            path: "Tests/KwekuTests"
        ),
    ]
)
