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
            Set(["VaultSync.swift", "UpdateChecker.swift"]),
            "a new network client appeared outside user-invoked sync/update"
        )
    }

    func testSchedulerLogsArePrivateAndBounded() throws {
        let logs = root.appendingPathComponent("config/retex/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let log = logs.appendingPathComponent("fleet-update.log")
        let original = String(
            repeating: "x", count: AutoUpdateScheduler.maximumLogBytes + 512
        )
        try original.write(to: log, atomically: true, encoding: .utf8)

        XCTAssertTrue(AutoUpdateScheduler.boundLogs(in: logs).contains(log))
        let attributes = try FileManager.default.attributesOfItem(atPath: log.path)
        XCTAssertEqual((attributes[.size] as? NSNumber)?.intValue, AutoUpdateScheduler.maximumLogBytes)
        XCTAssertEqual(
            String(data: try Data(contentsOf: log), encoding: .utf8),
            String(original.suffix(AutoUpdateScheduler.maximumLogBytes))
        )
#if !os(Windows)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: logs.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
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
