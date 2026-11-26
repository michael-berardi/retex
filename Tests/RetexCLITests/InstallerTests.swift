import Foundation
import XCTest

/// End-to-end tests for scripts/install.sh against a local release directory.
/// By default the release directory is generated with a tiny stub `retex`
/// binary; set RETEX_INSTALLER_TEST_ASSETS to a directory of real release
/// assets (for example dist/release) to exercise the same flow with them.
final class InstallerTests: XCTestCase {
    private static var repoRoot: URL {
        let file = URL(fileURLWithPath: #filePath)
        return file.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    // Arbitrary stub version; assertions below read the version reported by
    // the installed binary instead of hardcoding this value.
    private static let stubVersion = "3.2.1"

    private var root: URL!
    private var stubBin: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-installer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        stubBin = root.appendingPathComponent("stub-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: stubBin, withIntermediateDirectories: true)
    }

    /// Only the generated fixture (a shell script, not a Developer ID binary)
    /// gets a codesign stub; real release assets keep the real signature check.
    private var usesFixture = false

    private func stubCodesign() throws {
        let codeSign = stubBin.appendingPathComponent("codesign")
        try "#!/bin/sh\nexit 0\n".write(to: codeSign, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codeSign.path)
        usesFixture = true
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, stdout, stderr)
    }

    private func writeExecutable(_ contents: String, at url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func releaseDirectory() throws -> URL {
        let release = root.appendingPathComponent("release", isDirectory: true)
        if let assets = ProcessInfo.processInfo.environment["RETEX_INSTALLER_TEST_ASSETS"], !assets.isEmpty {
            try FileManager.default.copyItem(
                at: URL(fileURLWithPath: assets),
                to: release
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: release.appendingPathComponent("SHA256SUMS").path))
            return release
        }
        try stubCodesign()
        try FileManager.default.createDirectory(at: release, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("fixture-source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try writeExecutable(
            "#!/bin/sh\n[ \"$1\" = version ] && echo \(Self.stubVersion) || echo 'stub retex'\nexit 0\n",
            at: source.appendingPathComponent("retex")
        )

        let asset = Self.assetName()
#if os(macOS)
        let zip = try run(
            executable: URL(fileURLWithPath: "/usr/bin/zip"),
            arguments: ["-q", "-j", release.appendingPathComponent(asset).path, source.appendingPathComponent("retex").path]
        )
        XCTAssertEqual(zip.status, 0, zip.stderr)
#else
        // Linux uses the static xz archive.
        let tar = try run(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-cJf", release.appendingPathComponent(asset).path, "-C", source.path, "retex"]
        )
        XCTAssertEqual(tar.status, 0, tar.stderr)
#endif
        let sums = try run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c", "cd \"$1\" && if command -v sha256sum >/dev/null 2>&1; then sha256sum \"$2\"; else shasum -a 256 \"$2\"; fi > SHA256SUMS",
                "sh", release.path, asset,
            ]
        )
        XCTAssertEqual(sums.status, 0, sums.stderr)
        return release
    }

    private static func assetName() -> String {
#if os(macOS)
        "retex-universal.zip"
#else
        "retex-linux-\(isARM() ? "aarch64" : "x86_64").tar.xz"
#endif
    }

    private static func isARM() -> Bool {
#if arch(arm64)
        true
#else
        false
#endif
    }

    private func version(of executable: URL) throws -> String {
        let result = try run(executable: executable, arguments: ["version"])
        XCTAssertEqual(result.status, 0, result.stderr)
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func installedVersionDirectories(in home: URL) throws -> [URL] {
        let installed = home.appendingPathComponent(".local/share/retex", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: installed.path) else { return [] }
        return names.filter { $0 != "current" }
            .map { installed.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("retex").path) }
    }

    private func install(
        home: URL,
        release: URL,
        binDirectory: URL? = nil
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let bin = binDirectory ?? home.appendingPathComponent(".local/bin", isDirectory: true)
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "RETEX_VERSION")
        environment["HOME"] = home.path
        environment["RETEX_HOME"] = home.appendingPathComponent(".local/share/retex", isDirectory: true).path
        environment["RETEX_BIN_DIR"] = bin.path
        environment["RETEX_RELEASE_BASE"] = release.path
        environment["PATH"] = "\(stubBin.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        return try run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [Self.repoRoot.appendingPathComponent("scripts/install.sh").path],
            environment: environment
        )
    }

    func testInstallsIntoVersionFolderWithUpdaterCompatibleShim() throws {
        let release = try releaseDirectory()
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let result = try install(home: home, release: release)
        XCTAssertEqual(result.status, 0, result.stderr)

        let bin = home.appendingPathComponent(".local/bin/retex")
        let installedHome = home.appendingPathComponent(".local/share/retex")
        let current = installedHome.appendingPathComponent("current/retex")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: bin.path), current.path)

        let real = current.resolvingSymlinksInPath()
        XCTAssertTrue(FileManager.default.fileExists(atPath: real.path))
        let expectedVersion = try version(of: real)
        XCTAssertFalse(expectedVersion.isEmpty)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: current.deletingLastPathComponent().path),
                       installedHome.appendingPathComponent(expectedVersion).path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: real.deletingLastPathComponent()
            .appendingPathComponent(".retex-installed").path))
        XCTAssertEqual(try version(of: bin), expectedVersion)

        // The self-updater replaces the resolved binary in the version folder;
        // the shim must still point at that exact file afterwards.
        try writeExecutable("#!/bin/sh\necho 9.9.9\n", at: real)
        let afterUpdate = try run(executable: bin, arguments: ["version"])
        XCTAssertEqual(afterUpdate.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "9.9.9")
    }

    func testRefusesToReplaceUnownedShim() throws {
        let release = try releaseDirectory()
        let home = root.appendingPathComponent("clobber-home", isDirectory: true)
        let bin = home.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let unowned = bin.appendingPathComponent("retex")
        try "unowned".write(to: unowned, atomically: true, encoding: .utf8)

        let result = try install(home: home, release: release, binDirectory: bin)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("was not installed by this installer"), result.stderr)
        XCTAssertEqual(try String(contentsOf: unowned, encoding: .utf8), "unowned")
        XCTAssertTrue(try installedVersionDirectories(in: home).isEmpty)
    }

    func testRejectsChecksumMismatchBeforeInstalling() throws {
        let release = try releaseDirectory()
        let bad = root.appendingPathComponent("bad-release", isDirectory: true)
        try FileManager.default.copyItem(at: release, to: bad)
        try (String(repeating: "0", count: 64) + "  \(Self.assetName())\n")
            .write(to: bad.appendingPathComponent("SHA256SUMS"), atomically: true, encoding: .utf8)
        let home = root.appendingPathComponent("bad-home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let result = try install(home: home, release: bad)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("checksum mismatch"), result.stderr)
        XCTAssertTrue(try installedVersionDirectories(in: home).isEmpty)
    }

    func testInstallerPinsSameTeamIDAsUpdater() throws {
        let installer = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("scripts/install.sh"),
            encoding: .utf8
        )
        // The in-app updater's validation requirement lives in the CLI entry
        // point; UpdateChecker.swift performs the symlink-resolving swap.
        let updater = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("Sources/RetexCLI/Entrypoint.swift"),
            encoding: .utf8
        )
        let releaseScript = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("scripts/release.sh"),
            encoding: .utf8
        )
        let regex = try NSRegularExpression(
            pattern: #"certificate leaf\[subject\.OU\] = "([A-Z0-9]+)""#
        )
        func teamID(in text: String) -> String? {
            guard let match = regex.firstMatch(
                in: text, range: NSRange(text.startIndex..., in: text)
            ), let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
        let installerID = try XCTUnwrap(teamID(in: installer), "installer must pin a Team ID")
        let updaterID = try XCTUnwrap(teamID(in: updater), "updater must pin a Team ID")
        let releaseID = try XCTUnwrap(teamID(in: releaseScript), "release script must pin a Team ID")
        XCTAssertEqual(installerID, updaterID)
        XCTAssertEqual(installerID, releaseID)
    }

    func testBuildReleaseRefusesUnsafeOutDirectories() throws {
        // Run against a disposable checkout: if the guard ever regresses,
        // rm -rf can only damage this temporary fixture.
        let checkout = root.appendingPathComponent("release-checkout", isDirectory: true)
        let scripts = checkout.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        for name in ["build-release.sh", "install.sh"] {
            try FileManager.default.copyItem(
                at: Self.repoRoot.appendingPathComponent("scripts/\(name)"),
                to: scripts.appendingPathComponent(name)
            )
        }
        let marker = checkout.appendingPathComponent("Package.swift")
        try "marker".write(to: marker, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: checkout.appendingPathComponent("dist/release"),
            withIntermediateDirectories: true
        )
        let assets = root.appendingPathComponent("release-assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try "asset".write(
            to: assets.appendingPathComponent("retex-universal.zip"),
            atomically: true, encoding: .utf8
        )
        let outside = root.appendingPathComponent("outside-dist", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("sentinel")
        try "sentinel".write(to: sentinel, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: checkout.appendingPathComponent("dist/link"),
            withDestinationURL: outside
        )

        var environment = ProcessInfo.processInfo.environment
        environment["RETEX_ASSET_SOURCE"] = assets.path
        let script = scripts.appendingPathComponent("build-release.sh")
        for out in ["dist/..", "dist/x/..", "dist/./x", ".", "..", checkout.path, "/", "dist/link/escape"] {
            let result = try run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: [script.path, out],
                environment: environment,
                currentDirectory: checkout
            )
            XCTAssertNotEqual(result.status, 0, "\(out): \(result.stdout) \(result.stderr)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), out)
            XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path), out)
        }

        let accepted = try run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [script.path, "dist/release"],
            environment: environment,
            currentDirectory: checkout
        )
        XCTAssertEqual(accepted.status, 0, accepted.stderr)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: checkout.appendingPathComponent("dist/release/SHA256SUMS").path
        ))
    }
}
