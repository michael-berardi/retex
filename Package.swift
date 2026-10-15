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
        // System SQLite backs the disposable query index. macOS ships it in the
        // SDK; Linux builds need libsqlite3-dev (static: libsqlite3.a).
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite", providers: [.apt(["libsqlite3-dev"])]),
        .target(name: "RetexCore", dependencies: ["CSQLite", .product(name: "Crypto", package: "swift-crypto")]),
        .executableTarget(name: "RetexCLI", dependencies: ["RetexCore"]),
        .testTarget(name: "RetexCoreTests", dependencies: ["RetexCore"]),
        .testTarget(name: "RetexCLITests", dependencies: ["RetexCLI"]),
    ]
)
