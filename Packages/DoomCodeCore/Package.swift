// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DoomCodeCore",
    platforms: [
        // Audit 2026-06: raised the macOS floor from .v14 to .v26 to
        // match the actual deployment targets of both apps (DoomCode.app
        // and DoomCodeCompanion both target macOS 26 / iOS 26). The
        // old .v14 floor was a holdover from a transitional period and
        // hid the fact that several types (CKSyncEngine wrappers,
        // TimelineView, .glassEffect, FoundationModels) require newer
        // SDKs at runtime.
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(name: "DoomCodeCore", targets: ["DoomCodeCore"]),
    ],
    targets: [
        .target(
            name: "DoomCodeCore"
        ),
        .testTarget(name: "DoomCodeCoreTests", dependencies: ["DoomCodeCore"]),
    ]
)
