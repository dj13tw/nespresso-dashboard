// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WallPainterCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "WallPainterCore", targets: ["WallPainterCore"]),
    ],
    targets: [
        // Pure Swift (Foundation + Dispatch only) so it builds and tests on Linux too.
        .target(name: "WallPainterCore"),
        // Debug tool: runs refinement + recolor on raw RGBA dumps (see tools/swift_pipeline_check.py).
        .executableTarget(name: "wallpaint-cli", dependencies: ["WallPainterCore"]),
        .testTarget(name: "WallPainterCoreTests", dependencies: ["WallPainterCore"]),
    ]
)
