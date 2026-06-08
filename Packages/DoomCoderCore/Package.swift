// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DoomCoderCore",
    platforms: [
        // Audit 2026-06: raised the macOS floor from .v14 to .v26 to
        // match the actual deployment targets of both apps (DoomCoder.app
        // and DoomCoderCompanion both target macOS 26 / iOS 26). The
        // old .v14 floor was a holdover from a transitional period and
        // hid the fact that several types (CKSyncEngine wrappers,
        // TimelineView, .glassEffect, FoundationModels) require newer
        // SDKs at runtime.
        .macOS(.v26),
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
