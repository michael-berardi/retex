// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Retex",
    platforms: [
        .macOS(.v14),
        // RetexCore and the CLI also compile for iOS 17; the vault reader UI
        // is a future product and will consume this package.
        .iOS(.v17),
    ],
    products: [
        .executable(name: "retex", targets: ["RetexCLI"]),
        .library(name: "RetexCore", targets: ["RetexCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .target(name: "RetexCore", dependencies: [.product(name: "Crypto", package: "swift-crypto")]),
        .executableTarget(
            name: "RetexCLI",
            dependencies: ["RetexCore"]
        ),
        .testTarget(
            name: "RetexCoreTests",
            dependencies: ["RetexCore"]
        ),
        .testTarget(
            name: "RetexCLITests",
            dependencies: ["RetexCLI"]
        ),
    ]
)
