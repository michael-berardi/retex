import XCTest
@testable import RetexCore

/// The undo journal appends instead of rewriting; these cover the crash,
/// rollback, and compaction paths that the append design depends on.
final class JournalAppendTests: XCTestCase {
    private var vaultDir: URL!
    private let store = MarkdownStore()

    override func setUpWithError() throws {
        vaultDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-journal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: vaultDir, withIntermediateDirectories: true)
        try UndoHistory.prepare(for: Vault(url: vaultDir))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: vaultDir)
    }

    private var journal: URL { UndoHistory.journalURL(for: Vault(url: vaultDir)) }

    private func makeNote(_ title: String) throws -> Note {
        try store.createNote(in: Vault(url: vaultDir), folder: "", title: title, metadata: [:], body: "body")
    }

    func testMutationsAppendOneLineWithoutRewritingEarlierEntries() throws {
        let note = try makeNote("Append")
        try store.updateMetadata("status", value: "One", for: note)
        let first = try Data(contentsOf: journal)
        try store.updateMetadata("status", value: "Two", for: note)
        let second = try Data(contentsOf: journal)
        XCTAssertTrue(second.starts(with: first), "earlier journal bytes must be untouched")
        XCTAssertEqual(second.split(separator: UInt8(ascii: "\n")).count, 2)
        XCTAssertEqual(try UndoHistory().entries(for: note.url.path).count, 2)
    }

    func testTornFinalLineIsIgnoredThenRepairedByTheNextWrite() throws {
        let note = try makeNote("Torn")
        try store.updateMetadata("status", value: "One", for: note)
        let handle = try FileHandle(forWritingTo: journal)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"path":"/x","previousSo"#.utf8))
        try handle.close()

        XCTAssertEqual(try UndoHistory().entries(for: note.url.path).count, 1)
        try store.updateMetadata("status", value: "Two", for: note)
        let lines = try Data(contentsOf: journal).split(separator: UInt8(ascii: "\n"))
        XCTAssertEqual(lines.count, 2)
        for line in lines {
            XCTAssertNoThrow(try JSONDecoder().decode(UndoHistory.Entry.self, from: line))
        }
        XCTAssertEqual(try UndoHistory().pop(path: note.url.path).map { $0.contains("status: One") }, true)
    }

    func testFailedNoteWriteRemovesItsJournalEntry() throws {
        let note = try makeNote("Rollback")
        try store.updateMetadata("status", value: "One", for: note)
        let before = try Data(contentsOf: journal)
        // Force the note write to fail: its path is a directory.
        let blocked = vaultDir.appendingPathComponent("blocked.md", isDirectory: true)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        XCTAssertThrowsError(try UndoHistory().performMutation(path: blocked.path) {
            (previousSource: "previous", nextSource: "next")
        })
        XCTAssertEqual(try Data(contentsOf: journal), before)
    }

    func testCompactionEnforcesThePerFileCapOnDisk() throws {
        let path = vaultDir.appendingPathComponent("big.md").path
        let history = UndoHistory()
        let payload = String(repeating: "x", count: 20_000)
        // ~20 KB entries cross the 1 MiB compaction threshold at entry 53,
        // after the 50-entry cap is exceeded.
        for index in 0..<60 {
            try history.record(.init(path: path, previousSource: "\(index) \(payload)"))
        }
        let entries = try Data(contentsOf: journal).split(separator: UInt8(ascii: "\n"))
        XCTAssertLessThan(entries.count, 60, "compaction should have dropped entries beyond the cap")
        XCTAssertEqual(try history.entries(for: path).count, 50)
        XCTAssertEqual(try history.pop(path: path)?.hasPrefix("59 "), true)
    }
}
