// swift-tools-version: 6.0

import PackageDescription
import Foundation

// Path to the directory containing libultracompact.a (the ultracompact Rust
// crate's `cargo build --release` output). Override for other checkouts.
let ultraCompactLib = ProcessInfo.processInfo.environment["ULTRACOMPACT_LIB"]
    ?? NSString("~/dev/ultracompact/target/release").expandingTildeInPath

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
        .target(
            name: "RetexCore",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
                "CUltraCompact",
            ],
            linkerSettings: [
                // UC dense/readable encoding for MCP output; macOS-only link,
                // iOS keeps the plain-JSON fallback path.
                .unsafeFlags(["-L", ultraCompactLib, "-lultracompact"], .when(platforms: [.macOS])),
            ]
        ),
        .target(
            name: "CUltraCompact",
            path: "Sources/CUltraCompact"
        ),
        .executableTarget(
            name: "RetexCLI",
            dependencies: ["RetexCore"],
            linkerSettings: [
                .unsafeFlags(["-L", ultraCompactLib, "-lultracompact"]),
            ]
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
