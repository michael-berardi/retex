// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Retex",
    platforms: [
        // The current app and CLI run on macOS; iOS is the shared UI/model baseline.
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .executable(name: "RetexApp", targets: ["Retex"]),
        .executable(name: "retex", targets: ["RetexCLI"]),
    ],
    targets: [
        .target(name: "RetexCore"),
        .executableTarget(
            name: "Retex",
            dependencies: ["RetexCore"],
            resources: [.copy("Resources/SampleVaults")]
        ),
        .executableTarget(
            name: "RetexCLI",
            dependencies: ["RetexCore"]
        ),
    ]
)
