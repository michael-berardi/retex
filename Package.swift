// swift-tools-version: 6.0

import PackageDescription
import Foundation

// Optional UltraCompact acceleration: point ULTRACOMPACT_LIB at a directory
// containing libultracompact.a (the proprietary Rust engine's build output).
// When absent — the default for public checkouts — Retex builds and runs with
// canonical JSON output; no proprietary code is required or linked.
let ultraCompactLib = ProcessInfo.processInfo.environment["ULTRACOMPACT_LIB"] ?? ""
let ultraCompactLibExists = !ultraCompactLib.isEmpty
    && FileManager.default.fileExists(atPath: ultraCompactLib + "/libultracompact.a")

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
            ] + (ultraCompactLibExists ? ["CUltraCompact"] : []),
            linkerSettings: ultraCompactLibExists
                ? [
                    // Proprietary UC engine link; macOS-only, never on iOS.
                    .unsafeFlags(["-L", ultraCompactLib, "-lultracompact"], .when(platforms: [.macOS])),
                ]
                : []
        ),
        .executableTarget(
            name: "RetexCLI",
            dependencies: [
                "RetexCore",
            ] + (ultraCompactLibExists ? ["CUltraCompact"] : []),
            linkerSettings: ultraCompactLibExists
                ? [.unsafeFlags(["-L", ultraCompactLib, "-lultracompact"])]
                : []
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
