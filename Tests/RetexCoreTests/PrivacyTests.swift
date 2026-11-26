import XCTest
@testable import RetexCore

/// Regression guards for the privacy contract: no analytics client may be
/// added, network clients stay in the two explicit opt-in paths, and local
/// state written by Retex stays private and bounded.
final class PrivacyTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-privacy-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testNoAnalyticsSDKsOrEndpoints() throws {
        // Distinctive package/product names and telemetry endpoint hosts.
        // Generic words such as "segment" are intentionally not matched.
        let forbidden = [
            "getsentry", "sentry.io", "posthog", "mixpanel", "amplitude.com",
            "api.segment.io", "google-analytics", "googletagmanager",
            "datadoghq", "bugsnag", "plausible.io", "hotjar", "newrelic",
        ]
        var scanned = 0
        for directory in ["Sources", "deploy", "scripts"] {
            let base = repositoryRoot.appendingPathComponent(directory, isDirectory: true)
            let paths = try FileManager.default.subpathsOfDirectory(atPath: base.path)
            for path in paths {
                let url = base.appendingPathComponent(path)
                let extensionOfFile = url.pathExtension.lowercased()
                guard ["swift", "py", "sh"].contains(extensionOfFile)
                        || url.lastPathComponent == "Dockerfile"
                else { continue }
                let text = try String(contentsOf: url, encoding: .utf8).lowercased()
                scanned += 1
                for token in forbidden where text.contains(token) {
                    XCTFail("analytics marker \(token) in \(directory)/\(path)")
                }
            }
        }
        let manifest = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        ).lowercased()
        scanned += 1
        for token in forbidden where manifest.contains(token) {
            XCTFail("analytics marker \(token) in Package.swift")
        }
        XCTAssertGreaterThan(scanned, 20)
    }

    func testNetworkClientsOnlyExistInExplicitSyncAndUpdatePaths() throws {
        let base = repositoryRoot.appendingPathComponent("Sources", isDirectory: true)
        let paths = try FileManager.default.subpathsOfDirectory(atPath: base.path)
        var networkFiles: Set<String> = []
        for path in paths where path.hasSuffix(".swift") {
            let url = base.appendingPathComponent(path)
            let text = try String(contentsOf: url, encoding: .utf8).lowercased()
            if text.contains("urlsession") || text.contains("api.github.com") {
                networkFiles.insert(url.lastPathComponent)
            }
        }
        XCTAssertEqual(
            networkFiles,
            // HTTPDeadline.swift only configures the deadlines of the sessions
            // those two files create; it opens no connection of its own.
            Set(["VaultSync.swift", "UpdateChecker.swift", "HTTPDeadline.swift"]),
            "a new network client appeared outside user-invoked sync/update"
        )
    }

    func testSchedulerLogsArePrivateAndBounded() throws {
        let log = UpdateLog.url(root: root)
        try UpdateLog.preparePrivate(url: log)
        let logs = log.deletingLastPathComponent()
#if !os(Windows)
        XCTAssertEqual(permissions(of: logs), 0o700)
        XCTAssertEqual(permissions(of: log), 0o600)
        // A log left world-readable by an older release is re-asserted private.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: log.path)
#endif
        let original = String(repeating: "x", count: UpdateLog.limitBytes + 512) + "newest"
        try Data(original.utf8).write(to: log)
#if !os(Windows)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: log.path)
#endif
        UpdateLog.trim(url: log)
        let trimmed = try String(contentsOf: log, encoding: .utf8)
        XCTAssertLessThanOrEqual(trimmed.utf8.count, UpdateLog.limitBytes)
        XCTAssertTrue(trimmed.hasSuffix("newest"))
#if !os(Windows)
        XCTAssertEqual(permissions(of: log), 0o600)
        XCTAssertEqual(permissions(of: logs), 0o700)
#endif
    }

    func testScheduledJobFilesArePrivate() throws {
        let executable = root.appendingPathComponent("retex")
        try "#!/bin/sh\n".write(to: executable, atomically: true, encoding: .utf8)
        let schedule = try AutoUpdateScheduler(mode: .selfUpdate, root: root, dryRun: true)
            .install(executable: executable)
#if !os(Windows)
        XCTAssertEqual(permissions(of: URL(fileURLWithPath: schedule.configurationPath)), 0o600)
        XCTAssertEqual(permissions(of: UpdateLog.url(root: root)), 0o600)
#endif
    }

    func testSyncStateAndFleetRegistryAreOwnerPrivate() throws {
        let vault = root.appendingPathComponent("Vault", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        try VaultSync.saveState(
            VaultSync.State(server: "https://sync.example.com", vaultID: "crm"),
            Vault(url: vault)
        )
        let stateDirectory = vault.appendingPathComponent(".retex", isDirectory: true)
        let stateFile = stateDirectory.appendingPathComponent("sync.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateFile.path))
#if !os(Windows)
        XCTAssertEqual(permissions(of: stateDirectory), 0o700)
        XCTAssertEqual(permissions(of: stateFile), 0o600)
#endif

        let registry = FleetRegistry(url: root.appendingPathComponent("config/fleet.json"))
        _ = try registry.register(path: vault.path, autoUpdate: false)
#if !os(Windows)
        XCTAssertEqual(permissions(of: registry.url.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(permissions(of: registry.url), 0o600)
#endif
    }

    func testReadmePrivacyIsShortAndDetailsLiveInPrivacyFile() throws {
        let readme = try String(contentsOf: repositoryRoot.appendingPathComponent("README.md"), encoding: .utf8)
        let sections = readme.components(separatedBy: "\n## Privacy\n")
        XCTAssertEqual(sections.count, 2, "README has exactly one Privacy section")
        let body = sections[1].components(separatedBy: "\n## ")[0]
        let lines = body.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        XCTAssertLessThanOrEqual(lines.count, 6, body)
        XCTAssertTrue(body.contains("PRIVACY.md"))
        XCTAssertFalse(body.lowercased().contains("no automatic update check"))
        let privacy = try String(contentsOf: repositoryRoot.appendingPathComponent("PRIVACY.md"), encoding: .utf8)
        for detail in ["RETEX_NO_UPDATE_CHECK", "retex-update-check", "IP address", "DO_NOT_TRACK", "0600", "--uninstall"] {
            XCTAssertTrue(privacy.contains(detail), detail)
        }
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // RetexCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
    }

#if !os(Windows)
    private func permissions(of url: URL) -> Int? {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber)?.intValue
    }
#endif
}
