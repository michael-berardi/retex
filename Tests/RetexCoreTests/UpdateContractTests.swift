import XCTest
@testable import RetexCore

/// Local fixture transport: no test talks to a public release endpoint.
private final class FixtureTransport: URLProtocol {
    nonisolated(unsafe) static var responses: [String: (code: Int, body: Data)] = [:]
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.requests.append(request)
        let fixture = Self.responses[url.path] ?? (500, Data("fixture failure".utf8))
        let response = HTTPURLResponse(url: url, statusCode: fixture.code, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func reset() {
        responses = [:]
        requests = []
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureTransport.self]
        return URLSession(configuration: configuration)
    }
}

final class UpdateContractTests: XCTestCase {
    private let latestPath = "/repos/example/retex/releases/latest"
    private var root: URL!
    private var fixedNow: Date!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-update-contract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        FixtureTransport.reset()
    }

    override func tearDownWithError() throws {
        FixtureTransport.reset()
        try? FileManager.default.removeItem(at: root)
    }

    private func release(tag: String = "v1.10.0", draft: Bool = false, prerelease: Bool = false) -> Data {
        let asset = UpdateChecker.releaseAssetName
        let base = "https://github.com/example/retex/releases/download/\(tag)"
        return Data("""
        {"tag_name":"\(tag)","draft":\(draft),"prerelease":\(prerelease),
         "body":"First release note line.\\nSecond line.\\n",
         "assets":[
           {"name":"\(asset)","browser_download_url":"\(base)/\(asset)"},
           {"name":"SHA256SUMS","browser_download_url":"\(base)/SHA256SUMS"}
         ]}
        """.utf8)
    }

    private func checker() -> UpdateChecker {
        UpdateChecker(repo: "example/retex", session: FixtureTransport.session(), timeout: 4)
    }

    private func stateStore() -> UpdateStateStore {
        UpdateStateStore(url: root.appendingPathComponent("state/update-state.json"))
    }

    // MARK: Version comparison

    func testVersionComparisonAcceptsOnlyStrictlyNewerStableReleases() {
        XCTAssertTrue(UpdateChecker.isNewer(releaseTag: "v1.10.0", current: "1.9.1"))
        XCTAssertTrue(UpdateChecker.isNewer(releaseTag: "2.0.0", current: "1.99.9"))
        XCTAssertFalse(UpdateChecker.isNewer(releaseTag: "v1.9.1", current: "1.9.1"), "equal")
        XCTAssertFalse(UpdateChecker.isNewer(releaseTag: "1.9.0", current: "1.9.1"), "older")
        XCTAssertFalse(UpdateChecker.isNewer(releaseTag: "v1.10.0-beta.1", current: "1.9.1"), "prerelease")
        for garbage in ["latest", "", "v", "1.10", "1.10.0.1", "01.2.3", "1.2.3v", "1.٢.3", "v 1.2.3"] {
            XCTAssertFalse(UpdateChecker.isNewer(releaseTag: garbage, current: "1.9.1"), garbage)
        }
        XCTAssertFalse(UpdateChecker.isNewer(releaseTag: "v9.9.9", current: "dev"), "unparseable current")
        XCTAssertEqual(UpdateChecker.displayVersion("v1.10.0"), "1.10.0")
        XCTAssertEqual(UpdateChecker.displayVersion("1.10.0"), "1.10.0")
    }

    // MARK: Check

    func testLookupIsOneAnonymousGetAndIgnoresDraftsAndPrereleases() throws {
        FixtureTransport.responses[latestPath] = (200, release())
        let found = try checker().latestRelease()
        XCTAssertEqual(found.tag, "v1.10.0")
        XCTAssertTrue(found.notes.contains("First release note line."))
        let request = try XCTUnwrap(FixtureTransport.requests.first)
        XCTAssertEqual(request.httpMethod ?? "GET", "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://api.github.com\(latestPath)")
        XCTAssertNil(request.url?.query, "no query string, id or version")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "retex-update-check")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.httpBody)

        FixtureTransport.responses[latestPath] = (200, release(tag: "v1.11.0-rc.1", prerelease: true))
        XCTAssertThrowsError(try checker().latestRelease())
        FixtureTransport.responses[latestPath] = (200, release(tag: "v1.11.0", draft: true))
        XCTAssertThrowsError(try checker().latestRelease())
    }

    func testFixtureAPIOverrideAcceptsLoopbackOnly() {
        XCTAssertNotNil(UpdateChecker.fixtureAPI("http://127.0.0.1:8765/latest"))
        XCTAssertNotNil(UpdateChecker.fixtureAPI("http://localhost:8765/latest"))
        XCTAssertNil(UpdateChecker.fixtureAPI("https://releases.example.com/latest"))
        XCTAssertNil(UpdateChecker.fixtureAPI("file:///tmp/latest"))
        XCTAssertNil(UpdateChecker.fixtureAPI(nil))
        XCTAssertTrue(UpdateChecker.isValidRepo("owner/repo"))
        XCTAssertFalse(UpdateChecker.isValidRepo("owner/repo/extra"))
        XCTAssertFalse(UpdateChecker.isValidRepo("owner/../x"))
        XCTAssertFalse(UpdateChecker.isValidRepo("owner repo/x"))
    }

    func testCheckIsCachedForADayAndFailuresAreRecordedWithCauseNotRetried() {
        var moment = fixedNow!
        let store = stateStore()
        let coordinator = UpdateCoordinator(checker: checker(), store: store, now: { moment })
        FixtureTransport.responses[latestPath] = (200, release())

        let first = coordinator.check(current: "1.9.1")
        XCTAssertTrue(first.available)
        XCTAssertEqual(first.latestVersion, "1.10.0")
        XCTAssertEqual(coordinator.check(current: "1.9.1"), first)
        moment.addTimeInterval(UpdateState.interval - 1)
        XCTAssertEqual(coordinator.check(current: "1.9.1"), first)
        XCTAssertEqual(FixtureTransport.requests.count, 1, "a check younger than a day must not call the API")
        XCTAssertFalse(coordinator.check(current: "1.10.0").available, "the cached tag is compared to the running version")

        moment.addTimeInterval(2)
        FixtureTransport.responses[latestPath] = (503, Data("fixture unavailable".utf8))
        let failed = coordinator.check(current: "1.9.1")
        XCTAssertFalse(failed.available)
        XCTAssertEqual(failed.error, "release lookup failed (HTTP 503)")
        XCTAssertEqual(store.load().checkError, failed.error)
        XCTAssertEqual(coordinator.check(current: "1.9.1"), failed)
        XCTAssertEqual(FixtureTransport.requests.count, 2, "a failure must not be retried in a loop")

        // `retex update --check` retries a recorded failure once, by hand.
        FixtureTransport.responses[latestPath] = (200, release(tag: "v1.10.1"))
        let explicit = coordinator.check(current: "1.9.1", explicit: true)
        XCTAssertNil(explicit.error)
        XCTAssertEqual(explicit.latestVersion, "1.10.1")
        XCTAssertEqual(coordinator.check(current: "1.9.1", explicit: true), explicit)
        XCTAssertEqual(FixtureTransport.requests.count, 3, "an explicit check reuses a fresh success")
    }

    // MARK: State, skip, auto

    func testStateDefaultsSkipNoticeFrequencyAndAutoPersistInOnePrivateFile() throws {
        let store = stateStore()
        var state = store.load()
        XCTAssertTrue(state.checkAutomatically, "checks are on by default")
        XCTAssertFalse(state.autoInstall, "automatic installs are off by default")
        XCTAssertTrue(state.shouldNotify(version: "1.10.0", now: fixedNow))

        state.skippedVersion = "1.10.0"
        XCTAssertFalse(state.shouldNotify(version: "1.10.0", now: fixedNow), "skipped version is silent")
        XCTAssertTrue(state.shouldNotify(version: "1.10.1", now: fixedNow), "a newer version notifies again")
        state.lastNotifiedVersion = "1.10.1"
        state.lastNotifiedAt = fixedNow
        XCTAssertFalse(state.shouldNotify(version: "1.10.1", now: fixedNow.addingTimeInterval(60)))
        XCTAssertTrue(state.shouldNotify(version: "1.10.1", now: fixedNow.addingTimeInterval(UpdateState.interval)))
        XCTAssertTrue(state.shouldNotify(version: "1.10.2", now: fixedNow.addingTimeInterval(60)))
        state.autoInstall = true
        state.autoChoiceRecorded = true
        state.checkedAt = fixedNow
        state.latestVersion = "1.10.1"
        try store.save(state)
        XCTAssertEqual(store.load(), state, "choices survive a reload")

        try store.update { $0.checkAutomatically = false }
        XCTAssertFalse(store.load().shouldNotify(version: "1.10.9", now: fixedNow), "checks off silences notices")

        let directory = store.url.deletingLastPathComponent()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["update-state.json"])
        let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
        XCTAssertLessThan((attributes[.size] as? NSNumber)?.intValue ?? .max, 1_024)
#if !os(Windows)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
#endif
        store.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
    }

    func testOlderOrPartialStateFilesDecodeWithSafeDefaults() throws {
        let store = stateStore()
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"skippedVersion":"1.10.0"}"#.utf8).write(to: store.url)
        let state = store.load()
        XCTAssertEqual(state.skippedVersion, "1.10.0")
        XCTAssertTrue(state.checkAutomatically)
        XCTAssertFalse(state.autoInstall)
        try Data("not json".utf8).write(to: store.url)
        XCTAssertEqual(store.load(), UpdateState())
    }

    // MARK: Notice

    func testNoticeIsSilentForPipesCIOptOutMachineOutputAndServers() {
        XCTAssertTrue(UpdateNotice.allowed(command: "list", isJSON: false, isTTY: true, environment: [:]))
        XCTAssertFalse(UpdateNotice.allowed(command: "list", isJSON: false, isTTY: false, environment: [:]))
        XCTAssertFalse(UpdateNotice.allowed(command: "list", isJSON: true, isTTY: true, environment: [:]))
        XCTAssertFalse(UpdateNotice.allowed(command: "list", isJSON: false, isTTY: true, environment: ["CI": "true"]))
        XCTAssertFalse(UpdateNotice.allowed(
            command: "list", isJSON: false, isTTY: true, environment: ["RETEX_NO_UPDATE_CHECK": "1"]
        ))
        XCTAssertTrue(UpdateNotice.allowed(
            command: "list", isJSON: false, isTTY: true, environment: ["RETEX_NO_UPDATE_CHECK": "0"]
        ))
        for command in ["mcp", "update", "watch"] {
            XCTAssertFalse(UpdateNotice.allowed(command: command, isJSON: false, isTTY: true, environment: [:]), command)
        }
        XCTAssertEqual(UpdateNotice.lines(current: "1.9.1", new: "1.10.0"), [
            "retex 1.10.0 available (you have 1.9.1) · run: retex update",
            "turn on automatic updates: retex update --auto on · skip: retex update --skip",
        ])
        XCTAssertEqual(
            UpdateNotice.lines(current: "1.9.1", new: "1.10.0", command: "brew upgrade retex")[0],
            "retex 1.10.0 available (you have 1.9.1) · run: brew upgrade retex"
        )
    }

    func testOnlyHomebrewIsTreatedAsAPackageManager() {
        XCTAssertEqual(
            UpdateInstallRoute.packageManager(for: URL(fileURLWithPath: "/opt/homebrew/Cellar/retex/1.9.1/bin/retex"))?.arguments,
            ["brew", "upgrade", "retex"]
        )
        // Retex is not published to cargo, npm or uv: those names could be
        // someone else's package, so such paths use the verified swap.
        for path in ["/home/u/.cargo/bin/retex", "/usr/local/lib/node_modules/retex/bin/retex", "/opt/tools/retex/bin/retex"] {
            XCTAssertNil(UpdateInstallRoute.packageManager(for: URL(fileURLWithPath: path)), path)
        }
        XCTAssertNil(UpdateInstallRoute.packageManager(for: root.appendingPathComponent("retex")))
    }

    // MARK: Install safety

    private func serveAsset(_ asset: Data, sums: String, tag: String = "v1.10.0") throws -> UpdateChecker.Release {
        let base = "/example/retex/releases/download/\(tag)"
        FixtureTransport.responses[latestPath] = (200, release(tag: tag))
        FixtureTransport.responses["\(base)/\(UpdateChecker.releaseAssetName)"] = (200, asset)
        FixtureTransport.responses["\(base)/SHA256SUMS"] = (200, Data(sums.utf8))
        return try checker().latestRelease()
    }

    func testChecksumIsVerifiedBeforeAnythingIsInstalled() throws {
        let asset = Data("release archive".utf8)
        let name = UpdateChecker.releaseAssetName
        let good = try serveAsset(asset, sums: "\(UpdateChecker.sha256(of: asset))  \(name)\n")
        XCTAssertEqual(try checker().downloadVerified(good), asset)

        let tampered = try serveAsset(Data("tampered".utf8), sums: "\(UpdateChecker.sha256(of: asset))  \(name)\n")
        XCTAssertThrowsError(try checker().downloadVerified(tampered)) { error in
            XCTAssertTrue(error.localizedDescription.contains("checksum mismatch"), error.localizedDescription)
        }
        let unlisted = try serveAsset(asset, sums: "\(UpdateChecker.sha256(of: asset))  \(name).evil\n")
        XCTAssertThrowsError(try checker().downloadVerified(unlisted)) { error in
            XCTAssertTrue(error.localizedDescription.contains("no valid entry"), error.localizedDescription)
        }
    }

    func testInstallKeepsOneRollbackCopyAndRollbackRestores() throws {
        let executable = root.appendingPathComponent("retex")
        try "v1".write(to: executable, atomically: true, encoding: .utf8)
        for version in ["v2", "v3"] {
            let candidate = root.appendingPathComponent("candidate-\(version)")
            try version.write(to: candidate, atomically: true, encoding: .utf8)
            try UpdateChecker.install(candidate: candidate, over: executable)
        }
        XCTAssertEqual(try String(contentsOf: executable, encoding: .utf8), "v3")
        let previous = URL(fileURLWithPath: executable.path + ".previous")
        XCTAssertEqual(try String(contentsOf: previous, encoding: .utf8), "v2")
        let rollbackCopies = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("retex") && $0 != "retex" }
        XCTAssertEqual(rollbackCopies, ["retex.previous"], "never more than one rollback copy, no staged leftovers")

        try UpdateChecker.install(candidate: previous, over: executable)
        XCTAssertEqual(try String(contentsOf: executable, encoding: .utf8), "v2", "rollback restores")

        XCTAssertThrowsError(try UpdateChecker.install(
            candidate: root.appendingPathComponent("missing"), over: executable
        ))
        XCTAssertEqual(try String(contentsOf: executable, encoding: .utf8), "v2", "a failed install keeps the current binary")
    }

    func testRollbackCopyIsRemovedAfterTheNewVersionRuns() throws {
        let executable = root.appendingPathComponent("retex")
        let candidate = root.appendingPathComponent("candidate")
        try "old".write(to: executable, atomically: true, encoding: .utf8)
        try "new".write(to: candidate, atomically: true, encoding: .utf8)
        let previous = try UpdateChecker.install(candidate: candidate, over: executable)
        XCTAssertTrue(FileManager.default.fileExists(atPath: previous.path))
        UpdateChecker.removeRollback(beside: executable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: previous.path))
        XCTAssertEqual(try String(contentsOf: executable, encoding: .utf8), "new")
    }

    func testDownloadWorkspaceIsRemovedOnSuccessAndFailure() throws {
        var used: [URL] = []
        try UpdateWorkspace.withTemporary { directory in
            used.append(directory)
            try Data("asset".utf8).write(to: directory.appendingPathComponent("asset"))
        }
        XCTAssertThrowsError(try UpdateWorkspace.withTemporary { directory in
            used.append(directory)
            try Data("asset".utf8).write(to: directory.appendingPathComponent("asset"))
            throw UpdateChecker.UpdateError.checksumMismatch("asset")
        })
        XCTAssertEqual(used.count, 2)
        for directory in used {
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), directory.path)
        }
    }

    // MARK: Scheduler and log

    func testBackgroundLogIsTrimmedInPlaceToTheBound() throws {
        let log = UpdateLog.url(root: root)
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        let marker = String(repeating: "z", count: 64)
        try (String(repeating: "x", count: 300 * 1024) + marker).write(to: log, atomically: true, encoding: .utf8)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }

        UpdateLog.trim(url: log)
        let trimmed = try String(contentsOf: log, encoding: .utf8)
        XCTAssertLessThanOrEqual(trimmed.utf8.count, UpdateLog.limitBytes)
        XCTAssertTrue(trimmed.hasSuffix(marker), "the newest lines are kept")
        // A job's already-open stdout keeps writing into the same file.
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("next run\n".utf8))
        XCTAssertTrue(try String(contentsOf: log, encoding: .utf8).hasSuffix("next run\n"))

        let small = try String(contentsOf: log, encoding: .utf8)
        UpdateLog.trim(url: log)
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), small, "a small log is untouched")
        UpdateLog.removeLogs(root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
    }

    func testSelfUpdateJobIsDedicatedLowPriorityAndLogsToOneFile() throws {
        let executable = root.appendingPathComponent("retex")
        try "#!/bin/sh\n".write(to: executable, atomically: true, encoding: .utf8)
        let scheduler = AutoUpdateScheduler(mode: .selfUpdate, root: root, dryRun: true)
        XCTAssertFalse(scheduler.status().installed)
        let installed = try scheduler.install(executable: executable)
        XCTAssertEqual(installed.mode, "selfUpdate")
        XCTAssertTrue(scheduler.status().installed)
        let log = UpdateLog.url(root: root).path
#if os(macOS)
        let data = try Data(contentsOf: URL(fileURLWithPath: installed.configurationPath))
        let plist = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        )
        XCTAssertEqual(plist["Label"] as? String, "org.retex.cli.update")
        XCTAssertEqual(Array((plist["ProgramArguments"] as? [String] ?? []).dropFirst()), ["update", "--auto-run", "--json"])
        XCTAssertEqual(plist["ProcessType"] as? String, "Background")
        XCTAssertEqual(plist["StandardOutPath"] as? String, log)
        XCTAssertEqual(plist["StandardErrorPath"] as? String, log)
#elseif !os(Windows)
        let service = try String(
            contentsOf: root.appendingPathComponent(".config/systemd/user/retex-self-update.service"), encoding: .utf8
        )
        XCTAssertTrue(service.contains("update --auto-run --json"))
        XCTAssertTrue(service.contains("Nice=10"))
        XCTAssertTrue(service.contains("append:\(log)"))
#endif
        XCTAssertFalse(try scheduler.remove().installed)
        XCTAssertFalse(scheduler.status().installed)
    }
}
