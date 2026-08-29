// swift-tools-version: 6.0

import PackageDescription
import Foundation

// UltraCompact engine (proprietary, Implose Cybernetics — see
// LICENSE-ULTRACOMPACT). Default public builds fetch the prebuilt universal
// macOS xcframework from the Implose release service and link it on macOS.
// Overrides:
//   ULTRACOMPACT_LIB=<dir>  link a local engine build (libultracompact.a)
//   ULTRACOMPACT_DIST=0     build without the engine; machine output is
//                           canonical JSON, no proprietary code fetched/linked
let ultraCompactLib = ProcessInfo.processInfo.environment["ULTRACOMPACT_LIB"] ?? ""
let ultraCompactLibExists = !ultraCompactLib.isEmpty
    && FileManager.default.fileExists(atPath: ultraCompactLib + "/libultracompact.a")
let ultraCompactDist = !ultraCompactLibExists
    && (ProcessInfo.processInfo.environment["ULTRACOMPACT_DIST"] ?? "1") != "0"
let ultraCompactLinked = ultraCompactLibExists || ultraCompactDist

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
            ] + (ultraCompactLinked ? ["CUltraCompact"] : [])
                + (ultraCompactDist
                    ? [.target(name: "UltraCompact", condition: .when(platforms: [.macOS]))]
                    : []),
            linkerSettings: ultraCompactLibExists
                ? [
                    // Local engine build link; macOS-only, never on iOS.
                    .unsafeFlags(["-L", ultraCompactLib, "-lultracompact"], .when(platforms: [.macOS])),
                ]
                : []
        ),
        .executableTarget(
            name: "RetexCLI",
            dependencies: [
                "RetexCore",
            ] + (ultraCompactLinked ? ["CUltraCompact"] : [])
                + (ultraCompactDist
                    ? [.target(name: "UltraCompact", condition: .when(platforms: [.macOS]))]
                    : []),
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
    ] + (ultraCompactLinked ? [
        // Umbrella for the engine's C ABI (uc.h + module map). Declared only
        // when the engine is linked, so engine-free builds never reference it.
        .target(name: "CUltraCompact"),
    ] : []) + (ultraCompactDist ? [
        // Prebuilt proprietary engine (universal macOS static library).
        // Version + checksum pin; update both on engine releases.
        .binaryTarget(
            name: "UltraCompact",
            url: "https://software.implosecybernetics.com/api/products/ultracompact/releases/0.1.0/artifacts/macos-universal/installer/UltraCompact.xcframework.zip",
            checksum: "988f6eee7e45429708d72c79e6dd0e22f26520220417075d0c705048ea458d93"
        ),
    ] : []),
)
