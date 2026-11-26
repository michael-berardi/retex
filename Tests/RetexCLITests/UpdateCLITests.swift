import XCTest

/// End-to-end coverage of the update contract's CLI surface. State is seeded
/// in a temporary file and the release API points at a closed loopback port,
/// so no test reaches a public endpoint.
final class UpdateCLITests: XCTestCase {
    private static let binPath: URL = {
        if let override = ProcessInfo.processInfo.environment["RETEX_TEST_BIN_DIR"] {
            return URL(fileURLWithPath: override)
        }
        return Bundle(for: BundleLocator.self).bundleURL.deletingLastPathComponent()
    }()

    private var root: URL!
    private var state: URL!
    private var jobRoot: URL!
    private var environment: [String: String] = [:]
    private var current = ""

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-update-cli-\(UUID().uuidString)", isDirectory: true)
        state = root.appendingPathComponent("state/update-state.json")
        jobRoot = root.appendingPathComponent("launcher")
        try FileManager.default.createDirectory(at: jobRoot, withIntermediateDirectories: true)
        environment = ProcessInfo.processInfo.environment
        for key in ["CI", "RETEX_NO_UPDATE_CHECK", "RETEX_UPDATE_VERIFYING"] { environment[key] = nil }
        environment["RETEX_UPDATE_STATE"] = state.path
        environment["RETEX_UPDATER_ROOT"] = jobRoot.path
        environment["RETEX_SCHEDULER_DRY_RUN"] = "1"
        environment["RETEX_UPDATE_REPO"] = "example/retex"
        // Port 9 is closed on loopback: any lookup fails fast and locally.
        environment["RETEX_UPDATE_API"] = "http://127.0.0.1:9/latest"
        current = try run(["version"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func run(
        _ arguments: [String],
        tty: Bool = false,
        env extra: [String: String?] = [:]
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        let stdout = Pipe(), stderr = Pipe()
        let binary = Self.binPath.appendingPathComponent("retex").path
        if tty {
            // `script` gives the command a terminal on stdout and stderr.
            process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
            process.arguments = ["-q", "/dev/null", binary] + arguments
        } else {
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = arguments
        }
        var childEnvironment = environment
        for (key, value) in extra { childEnvironment[key] = value }
        process.environment = childEnvironment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self))
    }

    private func seed(_ values: [String: Any]) throws {
        var document: [String: Any] = ["checkedAt": ISO8601DateFormatter().string(from: Date())]
        document.merge(values) { $1 }
        try FileManager.default.createDirectory(at: state.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: document).write(to: state, options: .atomic)
    }

    private func saved() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: state)) as? [String: Any])
    }

    private func payload(_ stdout: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any])
    }

    private func notice(_ new: String) -> String {
        "retex \(new) available (you have \(current)) · run: retex update"
    }

    func testCheckExitCodesZeroTenAndOne() throws {
        try seed(["latestVersion": current])
        let upToDate = try run(["update", "--check", "--lean"])
        XCTAssertEqual(upToDate.status, 0, upToDate.stderr)
        XCTAssertEqual(try payload(upToDate.stdout)["available"] as? Bool, false)

        try seed(["latestVersion": "9.9.9"])
        let newer = try run(["update", "--check", "--lean"])
        XCTAssertEqual(newer.status, 10)
        XCTAssertEqual(try payload(newer.stdout)["latestVersion"] as? String, "9.9.9")
        XCTAssertEqual(try run(["update", "--check"]).stdout, "Update available: \(current) → 9.9.9\n")

        // A recorded failure is retried by hand; this one fails again locally.
        try seed(["checkError": "fixture failure"])
        let failed = try run(["update", "--check"])
        XCTAssertEqual(failed.status, 1)
        XCTAssertTrue(failed.stdout.isEmpty, failed.stdout)
        XCTAssertTrue(failed.stderr.hasPrefix("retex: Update check failed: "), failed.stderr)
        let cause = try XCTUnwrap(try saved()["checkError"] as? String)
        XCTAssertNotEqual(cause, "fixture failure", "the new cause is recorded")
        XCTAssertTrue(failed.stderr.contains(cause))
    }

    func testMissingRepositoryIsAUsageErrorAndChecksNothing() throws {
        let check = try run(["update", "--check"], env: ["RETEX_UPDATE_REPO": nil])
        XCTAssertEqual(check.status, 64)
        XCTAssertTrue(check.stderr.contains("RETEX_UPDATE_REPO"))
        XCTAssertEqual(try run(["update", "--auto", "on"], env: ["RETEX_UPDATE_REPO": nil]).status, 64)
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.path))
    }

    func testNoticeAppearsAfterTheCommandOncePerDayAndHonoursSkip() throws {
#if os(macOS)
        try seed(["latestVersion": "9.9.9"])
        let first = try run(["version"], tty: true)
        XCTAssertEqual(first.status, 0)
        let noticeRange = try XCTUnwrap(first.stdout.range(of: notice("9.9.9")), first.stdout)
        let versionRange = try XCTUnwrap(first.stdout.range(of: "\(current)\r\n"))
        XCTAssertLessThan(versionRange.lowerBound, noticeRange.lowerBound, "notice follows the command output")
        XCTAssertTrue(first.stdout.contains(
            "\u{1B}[2mturn on automatic updates: retex update --auto on · skip: retex update --skip\u{1B}[0m"
        ))
        XCTAssertFalse(try run(["version"], tty: true).stdout.contains("available (you have"), "once per day per version")

        let skipped = try run(["update", "--skip", "--lean"])
        XCTAssertEqual(try payload(skipped.stdout)["skipped"] as? String, "9.9.9")
        var document = try saved()
        document["lastNotifiedAt"] = nil
        try seed(document)
        XCTAssertFalse(try run(["version"], tty: true).stdout.contains("available (you have"), "skipped version is silent")

        document["latestVersion"] = "9.10.0"
        try seed(document)
        XCTAssertTrue(try run(["version"], tty: true).stdout.contains(notice("9.10.0")), "a newer version notifies again")
#endif
    }

    func testNoticeIsSilentInMachineOutputCIOptOutAndPipes() throws {
        try seed(["latestVersion": "9.9.9"])
        let piped = try run(["list", "--vault", root.path, "--json"])
        XCTAssertEqual(piped.status, 0)
        XCTAssertTrue(piped.stderr.isEmpty, piped.stderr)
        XCTAssertTrue(try run(["version"]).stderr.isEmpty, "no notice without a terminal")
#if os(macOS)
        for (arguments, extra) in [
            (["list", "--vault", root.path, "--json"], [:]),
            (["version", "--lean"], [:]),
            (["version"], ["CI": "true"]),
            (["version"], ["RETEX_NO_UPDATE_CHECK": "1"]),
        ] as [([String], [String: String?])] {
            let result = try run(arguments, tty: true, env: extra)
            XCTAssertFalse(result.stdout.contains("available (you have"), "\(arguments) \(extra)")
        }
        XCTAssertEqual(try run(["update", "--checks", "off", "--lean"]).status, 0)
        XCTAssertEqual(try saved()["checkAutomatically"] as? Bool, false)
        XCTAssertFalse(try run(["version"], tty: true).stdout.contains("available (you have"), "checks off")
#endif
    }

    func testAutoOnOffAndStatusPersistAndKeepOtherChoices() throws {
        try seed(["latestVersion": "9.9.9", "skippedVersion": "9.9.9"])
        let initial = try payload(try run(["update", "--auto", "status", "--lean"]).stdout)
        XCTAssertEqual(initial["autoInstall"] as? Bool, false, "off by default")
        XCTAssertEqual(initial["checkAutomatically"] as? Bool, true)
        XCTAssertEqual(initial["schedulerInstalled"] as? Bool, false)

        let on = try run(["update", "--auto", "on", "--lean"])
        XCTAssertEqual(on.status, 0, on.stderr)
        XCTAssertEqual(try payload(on.stdout)["mode"] as? String, "selfUpdate")
        XCTAssertEqual(try saved()["repo"] as? String, "example/retex", "the scheduled job needs the channel")
        let statusOn = try payload(try run(["update", "--auto", "status", "--lean"], env: ["RETEX_UPDATE_REPO": nil]).stdout)
        XCTAssertEqual(statusOn["autoInstall"] as? Bool, true)
        XCTAssertEqual(statusOn["schedulerInstalled"] as? Bool, true)
        XCTAssertEqual(statusOn["repo"] as? String, "example/retex")

        let off = try run(["update", "--auto", "off", "--lean"])
        XCTAssertEqual(off.status, 0, off.stderr)
        let document = try saved()
        XCTAssertEqual(document["autoInstall"] as? Bool, false)
        XCTAssertEqual(document["autoChoiceRecorded"] as? Bool, true, "the [y/N] question is not asked again")
        XCTAssertEqual(document["skippedVersion"] as? String, "9.9.9", "turning auto off keeps other choices")
        XCTAssertEqual(try payload(try run(["update", "--auto", "status", "--lean"]).stdout)["schedulerInstalled"] as? Bool, false)
    }

    func testScheduledRunDoesNothingUntilOptedInAndRecordsAFailedInstall() throws {
        try seed(["latestVersion": "9.9.9"])
        let idle = try run(["update", "--auto-run", "--json"])
        XCTAssertEqual(idle.status, 0, idle.stderr)
        XCTAssertTrue(idle.stdout.isEmpty && idle.stderr.isEmpty)
        XCTAssertNil(try saved()["installError"])

        XCTAssertEqual(try run(["update", "--auto", "on", "--lean"]).status, 0)
        let failed = try run(["update", "--auto-run", "--json"])
        XCTAssertNotEqual(failed.status, 0, "the release download fails on the closed port")
        XCTAssertNotNil(try saved()["installError"] as? String, "the cause is recorded")
#if os(macOS)
        let fallback = try run(["version"], tty: true)
        XCTAssertTrue(fallback.stdout.contains(notice("9.9.9")), "a failed automatic install falls back to the notice")
#endif
    }

    func testUninstallRemovesStateJobAndLogs() throws {
        XCTAssertEqual(try run(["update", "--auto", "on", "--lean"]).status, 0)
        let log = jobRoot.appendingPathComponent(".config/retex/logs/retex-update.log")
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("job output\n".utf8).write(to: log)

        let result = try run(["update", "--uninstall", "--lean"])
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
        XCTAssertEqual(try payload(try run(["update", "--auto", "status", "--lean"]).stdout)["schedulerInstalled"] as? Bool, false)
    }

    func testRollbackCopyGoesOnlyAfterARealCommandOnTheNewBinary() throws {
        let installed = root.appendingPathComponent("bin/retex")
        try FileManager.default.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Self.binPath.appendingPathComponent("retex"), to: installed)
        let previous = URL(fileURLWithPath: installed.path + ".previous")
        try Data("old binary".utf8).write(to: previous)

        func runInstalled(_ arguments: [String], verifying: Bool) throws -> Int32 {
            let process = Process()
            process.executableURL = installed
            process.arguments = arguments
            var childEnvironment = environment
            childEnvironment["RETEX_UPDATE_VERIFYING"] = verifying ? "1" : nil
            process.environment = childEnvironment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        // The updater's own checks run the new binary; they must not drop
        // the copy a failed check would roll back to.
        XCTAssertEqual(try runInstalled(["version"], verifying: true), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: previous.path))
        XCTAssertEqual(try runInstalled(["update", "--auto", "status"], verifying: false), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: previous.path), "update commands keep it")
        XCTAssertNotEqual(try runInstalled(["list"], verifying: false), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: previous.path), "a failed command keeps it")
        XCTAssertEqual(try runInstalled(["version"], verifying: false), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: previous.path))
    }

    func testBadSettingValuesAreUsageErrors() throws {
        XCTAssertEqual(try run(["update", "--auto", "maybe"]).status, 64)
        let explicit = try run(["update", "--auto=maybe"])
        XCTAssertEqual(explicit.status, 64)
        XCTAssertTrue(explicit.stderr.contains("--auto must be on, off or status"), explicit.stderr)
        XCTAssertEqual(try run(["update", "--checks", "maybe"]).status, 64)
    }
}
