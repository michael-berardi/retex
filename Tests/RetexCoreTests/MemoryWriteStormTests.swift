#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import XCTest
@testable import RetexCore

/// Reads must never rewrite memory records. Before the usage sidecar, every
/// Pi turn in every pane ran `retex memory context` (and agents ran
/// `memory recall`), each call rewriting the emitted record files through a
/// Foundation atomic write; a few hundred records times dozens of callers
/// kept macOS fseventsd at 100% CPU for days.
final class MemoryWriteStormTests: XCTestCase {
    private var vaultDir: URL!
    private var vault: Vault!
    private let memory = AgentMemory()
    private let day0 = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws {
        vaultDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-storm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: vaultDir, withIntermediateDirectories: true)
        _ = try memory.initialize(at: vaultDir)
        vault = Vault(url: vaultDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: vaultDir)
    }

    // MARK: Helpers

    private var globalDir: URL { vaultDir.appendingPathComponent("Memory/global", isDirectory: true) }

    @discardableResult
    private func writeRecord(
        slug: String,
        title: String? = nil,
        support: Int = 1,
        recalled: Int = 0,
        cited: Int = 0,
        recallHits: Int = 0,
        lastUsed: Date? = nil
    ) throws -> URL {
        try FileManager.default.createDirectory(at: globalDir, withIntermediateDirectories: true)
        let url = globalDir.appendingPathComponent(slug).appendingPathExtension("md")
        let record = AgentMemory.MemoryRecord(
            url: url, key: "global/\(slug)", kind: "gotcha", scope: "global",
            title: title ?? "Rule \(slug)",
            body: "Body for \(slug). Apply it always.",
            appliesWhen: nil, evidence: ["pi:s#1"], support: support,
            confidence: "0.7", certainty: "observed", sourceHarness: "agent",
            status: "active", validFrom: nil, validUntil: nil,
            supersedes: nil, supersededBy: [],
            asOf: AgentMemory.isoDay(day0),
            created: AgentMemory.isoDateTime(day0),
            updated: AgentMemory.isoDateTime(day0),
            recalled: recalled, cited: cited, recallHits: recallHits,
            lastUsed: lastUsed.map(AgentMemory.isoDateTime),
            recurrences: 0, retireProposed: nil,
            verifiedBy: nil, confirmation: nil, contentHash: ""
        )
        try memory.serialize(record).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private struct FileState: Equatable {
        let inode: UInt64
        let mtimeSeconds: Int
        let mtimeNanoseconds: Int
        let size: Int64
    }

    private func fileState(_ path: String) -> FileState? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        #if canImport(Darwin)
        let mtime = info.st_mtimespec
        #else
        let mtime = info.st_mtim
        #endif
        return FileState(
            inode: UInt64(info.st_ino), mtimeSeconds: Int(mtime.tv_sec),
            mtimeNanoseconds: Int(mtime.tv_nsec), size: Int64(info.st_size)
        )
    }

    private func recordStates() throws -> [String: FileState] {
        var states: [String: FileState] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: globalDir.path) {
            let path = globalDir.appendingPathComponent(name).path
            states[name] = fileState(path)
        }
        return states
    }

    private var sidecarPath: String { AgentMemory.usageURL(for: vault).path }

    // MARK: Write storm

    func testContextAndRecallNeverRewriteRecordFiles() throws {
        for index in 0..<600 {
            try writeRecord(slug: String(format: "rule-%04d", index), support: 1 + index % 4)
        }
        let before = try recordStates()
        XCTAssertEqual(before.count, 600)

        var sidecarWrites = 0
        var lastSidecar = fileState(sidecarPath)
        func noteSidecar() {
            let current = fileState(sidecarPath)
            if current != lastSidecar { sidecarWrites += 1 }
            lastSidecar = current
        }

        // 200 session packs and 200 recalls over three days, as many panes would.
        for call in 0..<200 {
            let now = day0.addingTimeInterval(Double(call / 67) * 86_400 + Double(call))
            let pack = try memory.context(
                vault: vault, project: nil, budget: 6000, harness: "pi", now: now
            )
            XCTAssertGreaterThan(pack.emitted, 0)
            noteSidecar()
            let recall = try memory.recall(
                vault: vault, query: "apply always", budget: 4000, includeProposed: false, now: now
            )
            XCTAssertFalse(recall.records.isEmpty)
            noteSidecar()
        }

        let after = try recordStates()
        XCTAssertEqual(after.count, 600, "no temp files may be left in the record directory")
        let rewritten = before.keys.filter { before[$0] != after[$0] }.sorted()
        XCTAssertEqual(rewritten, [], "reads rewrote \(rewritten.count) record files")
        // One write per day that brings a new use; nothing else.
        XCTAssertGreaterThan(sidecarWrites, 0, "recall hits must still be recorded")
        XCTAssertLessThanOrEqual(sidecarWrites, 3)
    }

    func testSecondUseOnTheSameDayDoesNotWriteTheSidecar() throws {
        try writeRecord(slug: "deploy", title: "Deploy rule")
        _ = try memory.cite(vault: vault, key: "global/deploy", now: day0)
        let first = fileState(sidecarPath)
        XCTAssertNotNil(first)
        for offset in 1...50 {
            _ = try memory.cite(vault: vault, key: "global/deploy", now: day0.addingTimeInterval(Double(offset)))
            _ = try memory.recall(
                vault: vault, query: "deploy", budget: 4000, includeProposed: false,
                now: day0.addingTimeInterval(Double(offset))
            )
        }
        XCTAssertEqual(fileState(sidecarPath), first)
    }

    // MARK: Ranking

    func testSidecarUsageStillRaisesRank() throws {
        let alphaURL = try writeRecord(slug: "alpha")
        try writeRecord(slug: "beta")
        let alphaBefore = fileState(alphaURL.path)
        let now = day0.addingTimeInterval(86_400)

        // Equal records tie on score and break by key: alpha first.
        var ranked = try memory.context(vault: vault, project: nil, budget: 6000, harness: nil, now: now).records
        XCTAssertEqual(ranked.first?.key, "global/alpha")
        XCTAssertEqual(ranked[0].score, ranked[1].score)

        _ = try memory.cite(vault: vault, key: "global/beta", now: now)
        ranked = try memory.context(vault: vault, project: nil, budget: 6000, harness: nil, now: now).records
        XCTAssertEqual(ranked.first?.key, "global/beta", "a citation must raise the record's rank")
        XCTAssertGreaterThan(ranked[0].score, ranked[1].score)

        let beta = try memory.loadRecord(vault: vault, key: "global/beta")
        XCTAssertEqual(beta.cited, 1)
        XCTAssertEqual(beta.lastUsed, AgentMemory.isoDateTime(now))
        XCTAssertEqual(fileState(alphaURL.path), alphaBefore)
        let betaSource = try String(contentsOf: beta.url, encoding: .utf8)
        XCTAssertTrue(betaSource.contains("cited: 0\n"), "cite must not touch the Markdown")
        XCTAssertFalse(betaSource.contains("last_used:"))
    }

    // MARK: Migration

    func testFrontmatterCountersAreTheBaseline() throws {
        let yesterday = day0.addingTimeInterval(-86_400)
        let url = try writeRecord(slug: "legacy", recalled: 37_578, cited: 2, recallHits: 1, lastUsed: yesterday)
        let original = try Data(contentsOf: url)
        let originalState = fileState(url.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarPath))

        // Upgrade alone changes nothing: no sidecar, same counters.
        var record = try memory.loadRecord(vault: vault, key: "global/legacy")
        XCTAssertEqual(record.cited, 2)
        XCTAssertEqual(record.recallHits, 1)
        XCTAssertEqual(record.lastUsed, AgentMemory.isoDateTime(yesterday))
        _ = try memory.context(vault: vault, project: nil, budget: 6000, harness: nil, now: day0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarPath))

        // New use lands in the sidecar as a delta on top of the frontmatter.
        _ = try memory.cite(vault: vault, key: "global/legacy", now: day0)
        _ = try memory.recall(vault: vault, query: "legacy", budget: 4000, includeProposed: false,
                              now: day0.addingTimeInterval(86_400))
        record = try memory.loadRecord(vault: vault, key: "global/legacy")
        XCTAssertEqual(record.cited, 3)
        XCTAssertEqual(record.recallHits, 2)
        XCTAssertEqual(record.recalled, 37_578)
        XCTAssertEqual(record.lastUsed, AgentMemory.isoDateTime(day0.addingTimeInterval(86_400)))
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(fileState(url.path), originalState)

        let usage = AgentMemory.loadUsage(vault: vault)["global/legacy"]
        XCTAssertEqual(usage?.cited, 1)
        XCTAssertEqual(usage?.recallHits, 1)
        XCTAssertEqual(try fileMode(sidecarPath), 0o600)
    }

    func testFrontmatterLastUsedTodayStillCapsTheDay() throws {
        try writeRecord(slug: "today", cited: 1, lastUsed: day0)
        _ = try memory.cite(vault: vault, key: "global/today", now: day0.addingTimeInterval(60))
        XCTAssertEqual(try memory.loadRecord(vault: vault, key: "global/today").cited, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarPath))
    }

    func testCorruptSidecarReadsAsNoUsage() throws {
        try writeRecord(slug: "solid", cited: 2)
        try "{not json".write(toFile: sidecarPath, atomically: true, encoding: .utf8)
        XCTAssertEqual(try memory.loadRecord(vault: vault, key: "global/solid").cited, 2)
        _ = try memory.cite(vault: vault, key: "global/solid", now: day0)
        XCTAssertEqual(try memory.loadRecord(vault: vault, key: "global/solid").cited, 3)
    }

    private func fileMode(_ path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return (attributes[.posixPermissions] as? Int ?? -1) & 0o777
    }
}
