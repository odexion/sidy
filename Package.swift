// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Sidy",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Sidy", targets: ["Sidy"]),
        // Loaded by /usr/bin/perl at runtime, never linked into the app.
        .library(name: "MediaBridge", type: .dynamic, targets: ["MediaBridge"]),
    ],
    targets: [
        .executableTarget(
            name: "Sidy",
            path: "Sources/Sidy",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "MediaBridge",
            path: "Sources/MediaBridge",
            cSettings: [.unsafeFlags(["-fobjc-arc"])]
        ),
    ]
)
