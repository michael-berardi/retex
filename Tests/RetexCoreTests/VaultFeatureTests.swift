import XCTest
@testable import RetexCore

final class UndoHistoryTests: XCTestCase {
    private var vaultDir: URL!

    override func setUpWithError() throws {
        vaultDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-undo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: vaultDir.appendingPathComponent(".retex"),
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: vaultDir)
    }

    func testRecordAndPopRoundtrip() throws {
        let history = UndoHistory()
        let path = vaultDir.appendingPathComponent("Deals/a.md").path
        try history.record(.init(path: path, previousSource: "first"))
        try history.record(.init(path: path, previousSource: "second"))

        XCTAssertEqual(try history.pop(path: path), "second")
        XCTAssertEqual(try history.pop(path: path), "first")
        XCTAssertNil(try history.pop(path: path), "Journal should be exhausted for this file")
    }

    func testEntriesFiltersToRequestedFile() throws {
        let history = UndoHistory()
        let a = vaultDir.appendingPathComponent("a.md").path
        let b = vaultDir.appendingPathComponent("b.md").path
        try history.record(.init(path: a, previousSource: "A1"))
        try history.record(.init(path: b, previousSource: "B1"))

        let entries = try history.entries(for: a)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.previousSource, "A1")
    }

    func testCapsPerFileDepth() throws {
        let history = UndoHistory()
        let path = vaultDir.appendingPathComponent("c.md").path
        for index in 0..<60 {
            try history.record(.init(path: path, previousSource: "v\(index)"))
        }
        XCTAssertLessThanOrEqual(try history.entries(for: path).count, 50)
        // Newest entry survives the cap.
        XCTAssertEqual(try history.pop(path: path), "v59")
    }
}

final class VaultConfigTests: XCTestCase {
    private var vaultDir: URL!

    override func setUpWithError() throws {
        vaultDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: vaultDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: vaultDir)
    }

    func testMissingConfigFallsBackToDefaults() {
        let config = VaultConfig.load(for: Vault(url: vaultDir))
        XCTAssertEqual(config.columns, BoardColumn.defaultColumns)
        XCTAssertTrue(config.views.isEmpty)
    }

    func testCustomColumnsAndViewsLoad() throws {
        let retexDir = vaultDir.appendingPathComponent(".retex", isDirectory: true)
        try FileManager.default.createDirectory(at: retexDir, withIntermediateDirectories: true)
        try """
        {"columns":[{"title":"Backlog","statuses":["Inbox","New"]},{"title":"Done","statuses":["Won"]}],
         "views":[{"name":"pipeline","type":"deal","status":"Proposal"},{"name":"urgent","tag":"hot"}]}
        """.write(to: retexDir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

        let config = VaultConfig.load(for: Vault(url: vaultDir))
        XCTAssertEqual(config.columns.map(\.title), ["Backlog", "Done"])
        XCTAssertEqual(config.view(named: "PIPELINE")?.type, "deal")
        XCTAssertEqual(config.view(named: "urgent")?.tag, "hot")
        XCTAssertNil(config.view(named: "missing"))
    }

    func testCorruptConfigFallsBackToDefaults() throws {
        let retexDir = vaultDir.appendingPathComponent(".retex", isDirectory: true)
        try FileManager.default.createDirectory(at: retexDir, withIntermediateDirectories: true)
        try "{not json".write(to: retexDir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

        let config = VaultConfig.load(for: Vault(url: vaultDir))
        XCTAssertEqual(config.columns, BoardColumn.defaultColumns)
    }
}

final class VaultWatcherTests: XCTestCase {
    func testDeliversDebouncedChangeEvents() throws {
        let vaultDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: vaultDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vaultDir) }

        let expectation = expectation(description: "change batch delivered")
        let received = LockedBox([[String]]())

        let watcher = VaultWatcher(vault: Vault(url: vaultDir), debounce: 0.2, queue: .main) { paths in
            received.with { $0.append(paths) }
            expectation.fulfill()
        }
        try watcher.start()
        defer { watcher.stop() }

        // Give FSEvents a moment to arm, then mutate.
        Thread.sleep(forTimeInterval: 0.3)
        try "hello".write(
            to: vaultDir.appendingPathComponent("new-note.md"),
            atomically: true,
            encoding: .utf8
        )

        wait(for: [expectation], timeout: 10)

        let flattened = received.with { $0.flatMap { $0 } }
        XCTAssertTrue(
            flattened.contains { $0.hasSuffix("new-note.md") },
            "Expected new-note.md in \(flattened)"
        )
        // Internal state must never echo back.
        XCTAssertFalse(flattened.contains { $0.contains(".retex") })
    }
}
