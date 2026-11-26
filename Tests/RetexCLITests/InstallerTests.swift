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

    private static let fixtureVersion = "1.9.1"

    private var root: URL!
    private var stubBin: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-installer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        stubBin = root.appendingPathComponent("stub-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: stubBin, withIntermediateDirectories: true)
        // The generated fixture is a shell script, not a Developer ID binary.
        let codeSign = stubBin.appendingPathComponent("codesign")
        try "#!/bin/sh\nexit 0\n".write(to: codeSign, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codeSign.path)
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
        try FileManager.default.createDirectory(at: release, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("fixture-source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try writeExecutable(
            "#!/bin/sh\n[ \"$1\" = version ] && echo \(Self.fixtureVersion) || echo 'stub retex'\nexit 0\n",
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

    private func install(
        home: URL,
        release: URL,
        binDirectory: URL? = nil
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let bin = binDirectory ?? home.appendingPathComponent(".local/bin", isDirectory: true)
        var environment = ProcessInfo.processInfo.environment
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
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: current.deletingLastPathComponent().path),
                       installedHome.appendingPathComponent(Self.fixtureVersion).path)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: bin.path), current.path)

        let real = current.resolvingSymlinksInPath()
        XCTAssertTrue(FileManager.default.fileExists(atPath: real.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: real.deletingLastPathComponent()
            .appendingPathComponent(".retex-installed").path))
        let version = try run(executable: bin, arguments: ["version"])
        XCTAssertEqual(version.status, 0, version.stderr)
        XCTAssertEqual(version.stdout.trimmingCharacters(in: .whitespacesAndNewlines), Self.fixtureVersion)

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
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: home.appendingPathComponent(".local/share/retex/\(Self.fixtureVersion)/retex").path
        ))
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
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: home.appendingPathComponent(".local/share/retex/\(Self.fixtureVersion)/retex").path
        ))
    }
}
