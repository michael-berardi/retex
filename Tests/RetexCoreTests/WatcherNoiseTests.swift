#if os(macOS)
import CoreServices
#endif
import XCTest
@testable import RetexCore

/// Watchers must not react to Retex's own state (the memory usage sidecar
/// under `.retex/`) or to Foundation atomic-save temp files
/// (`note.md.sb-<hash>-<rand>`), so no consumer can be driven into a loop.
final class WatcherNoiseTests: XCTestCase {
    func testReportablePathsAreVisibleMarkdownOnly() {
        #if os(macOS)
        XCTAssertTrue(VaultWatcher.isReportable(relativePath: "note.md"))
        XCTAssertTrue(VaultWatcher.isReportable(relativePath: "Memory/global/rule.MD"))
        XCTAssertFalse(VaultWatcher.isReportable(relativePath: "Memory/global/rule.md.sb-1a2b3c4d-XyZ123"))
        XCTAssertFalse(VaultWatcher.isReportable(relativePath: ".retex/memory-usage.json"))
        XCTAssertFalse(VaultWatcher.isReportable(relativePath: ".retex/history.jsonl"))
        XCTAssertFalse(VaultWatcher.isReportable(relativePath: ".git/notes.md"))
        XCTAssertFalse(VaultWatcher.isReportable(relativePath: "Memory"))
        #endif
    }

    #if os(macOS)
    func testSnapshotCacheEventSinkIgnoresSidecarAndTempFiles() {
        let root = "/vault"
        let sink = VaultSnapshotCache.EventSink(rootPrefixes: [root], barrierDirectory: "/barriers")
        let fileFlags = UInt32(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemRenamed)
        sink.record(path: "\(root)/.retex/memory-usage.json", flags: fileFlags)
        sink.record(path: "\(root)/.retex/memory-usage.json.sb-0a1b2c3d-AbCdEf", flags: fileFlags)
        sink.record(path: "\(root)/Memory/global/rule.md.sb-0a1b2c3d-AbCdEf", flags: fileFlags)
        var pending = sink.drain()
        XCTAssertEqual(pending.paths, [])
        XCTAssertFalse(pending.needsWalk)

        sink.record(path: "\(root)/Memory/global/rule.md", flags: fileFlags)
        pending = sink.drain()
        XCTAssertEqual(pending.paths, ["\(root)/Memory/global/rule.md"])
    }

    /// End to end over a real FSEvents stream: memory telemetry and atomic
    /// saves happen, and the callback only ever sees the `.md` notes.
    func testWatcherIgnoresSidecarWritesAndAtomicTempFiles() throws {
        let vaultDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-watch-noise-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: vaultDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vaultDir) }
        let memory = AgentMemory()
        _ = try memory.initialize(at: vaultDir)
        let vault = Vault(url: vaultDir)
        let globalDir = vaultDir.appendingPathComponent("Memory/global", isDirectory: true)
        try FileManager.default.createDirectory(at: globalDir, withIntermediateDirectories: true)
        let ruleURL = globalDir.appendingPathComponent("deploy.md")
        try """
        ---
        type: memory
        key: global/deploy
        kind: gotcha
        scope: global
        status: active
        title: Deploy rule
        confidence: 0.7
        certainty: observed
        support: 1
        source_harness: agent
        evidence: |
          pi:s#1
        as_of: 2026-01-01
        created: 2026-01-01T00:00:00Z
        updated: 2026-01-01T00:00:00Z
        recalled: 0
        cited: 0
        recurrences: 0
        ---
        Run the deploy script.
        """.write(to: ruleURL, atomically: true, encoding: .utf8)

        let armed = expectation(description: "armed")
        armed.assertForOverFulfill = false
        let sentinel = expectation(description: "sentinel delivered")
        sentinel.assertForOverFulfill = false
        let received = LockedBox([String]())
        let watcher = VaultWatcher(vault: vault, debounce: 0.2, queue: .main) { paths in
            received.with { $0.append(contentsOf: paths) }
            if paths.contains(where: { $0.hasSuffix("probe.md") }) { armed.fulfill() }
            if paths.contains(where: { $0.hasSuffix("sentinel.md") }) { sentinel.fulfill() }
        }
        try watcher.start()
        defer { watcher.stop() }

        let probeURL = vaultDir.appendingPathComponent("probe.md")
        let keepProbing = LockedBox(true)
        DispatchQueue(label: "retex.watch.noise.probe").async {
            var attempt = 0
            while keepProbing.with({ $0 }) {
                attempt += 1
                try? "probe \(attempt)".write(to: probeURL, atomically: true, encoding: .utf8)
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        wait(for: [armed], timeout: 60)
        keepProbing.with { $0 = false }
        // Events arrive in order: everything from setup came with or before
        // the probe, so only what follows is the telemetry under test.
        Thread.sleep(forTimeInterval: 0.5)
        received.with { $0.removeAll() }

        // Telemetry over several days: each one writes the sidecar atomically.
        let start = Date()
        for day in 0..<5 {
            let now = start.addingTimeInterval(Double(day) * 86_400)
            _ = try memory.cite(vault: vault, key: "global/deploy", now: now)
            _ = try memory.recall(vault: vault, query: "deploy", budget: 4000, includeProposed: false, now: now)
            _ = try memory.context(vault: vault, project: nil, budget: 6000, harness: "pi", now: now)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: AgentMemory.usageURL(for: vault).path))
        // A temp file left behind by an interrupted atomic save.
        try "partial".write(
            to: globalDir.appendingPathComponent("deploy.md.sb-0a1b2c3d-AbCdEf"),
            atomically: false, encoding: .utf8
        )
        try "done".write(to: vaultDir.appendingPathComponent("sentinel.md"), atomically: true, encoding: .utf8)
        wait(for: [sentinel], timeout: 60)

        let paths = received.with { $0 }
        XCTAssertEqual(paths.filter { !$0.hasSuffix(".md") }, [], "non-note paths reached the callback")
        XCTAssertFalse(paths.contains { $0.contains(".retex") })
        XCTAssertFalse(paths.contains("Memory/global/deploy.md"), "telemetry must not touch the record")
    }
    #endif
}
