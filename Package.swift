// swift-tools-version: 6.0

import PackageDescription

// The shipping app, Finder extension and runner are built by FinderActions.xcodeproj.
// This manifest exists so `swift test` gives a fast inner loop on the shared core.
let package = Package(
    name: "FinderActions",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "FinderActionsCore", targets: ["FinderActionsCore"]),
    ],
    targets: [
        .target(name: "FinderActionsCore"),
        .testTarget(name: "FinderActionsCoreTests", dependencies: ["FinderActionsCore"]),
    ]
)
