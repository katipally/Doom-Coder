// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DoomCoderCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v26),
    ],
    products: [
        .library(name: "DoomCoderCore", targets: ["DoomCoderCore"]),
    ],
    targets: [
        .target(
            name: "DoomCoderCore"
        ),
        .testTarget(name: "DoomCoderCoreTests", dependencies: ["DoomCoderCore"]),
    ]
)
