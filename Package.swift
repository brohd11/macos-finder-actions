// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "FinderActions",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "FinderActionsCore", targets: ["FinderActionsCore"]),
        .executable(name: "finder-actions-selftest", targets: ["FinderActionsSelfTest"]),
        .executable(name: "finder-actions-runner-dev", targets: ["FinderActionsRunnerDev"]),
        .executable(name: "finder-actions-app-dev", targets: ["FinderActionsAppDev"]),
        .library(name: "FinderSyncExtensionDev", targets: ["FinderSyncExtensionDev"]),
    ],
    targets: [
        .target(name: "FinderActionsCore"),
        .executableTarget(name: "FinderActionsSelfTest", dependencies: ["FinderActionsCore"]),
        .executableTarget(
            name: "FinderActionsRunnerDev",
            dependencies: ["FinderActionsCore"],
            path: "Apps/FinderActionsRunner"
        ),
        .executableTarget(
            name: "FinderActionsAppDev",
            dependencies: ["FinderActionsCore"],
            path: "Apps/FinderActionsApp"
        ),
        .target(
            name: "FinderSyncExtensionDev",
            dependencies: ["FinderActionsCore"],
            path: "Apps/FinderSyncExtension"
        ),
    ]
)
