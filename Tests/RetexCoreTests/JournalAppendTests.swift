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

    func testRollbackRestoresTheFileAndDropsOnlyItsNewestEntry() throws {
        let note = try makeNote("Restore")
        try store.updateMetadata("status", value: "One", for: note)
        try store.updateMetadata("status", value: "Two", for: note)
        let restored = try XCTUnwrap(store.load(note.url).metadata["status"])

        // One locked write restores the bytes and pops the entry that
        // announced them, so the undo chain keeps only the older entries.
        XCTAssertTrue(try UndoHistory().rollback(to: "# Restored\n", for: note.url, fileMode: 0o600))
        XCTAssertEqual(try String(contentsOf: note.url), "# Restored\n")
        XCTAssertEqual(try UndoHistory().entries(for: note.url.path).count, 1)
        XCTAssertEqual(restored, "Two")
        // With one older entry left, another rollback pops that one and a
        // third still restores the file.
        XCTAssertTrue(try UndoHistory().rollback(to: "# Restored\n", for: note.url))
        XCTAssertEqual(try UndoHistory().entries(for: note.url.path).count, 0)
        XCTAssertFalse(try UndoHistory().rollback(to: "# Restored\n", for: note.url))
        XCTAssertEqual(try String(contentsOf: note.url), "# Restored\n")
        #if !os(Windows)
        let mode = try FileManager.default.attributesOfItem(atPath: note.url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        #endif
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

    func testRestoreLatestWritesTheFileThenDropsThatEntry() throws {
        let note = try makeNote("Restore")
        try store.updateMetadata("status", value: "One", for: note)
        try store.updateMetadata("status", value: "Two", for: note)
        let history = UndoHistory()
        XCTAssertEqual(try history.entries(for: note.url.path).count, 2)
        XCTAssertEqual(try store.load(note.url).status, "Two")

        let restored = try history.restoreLatest(for: note.url)
        XCTAssertEqual(restored?.contains("status: One"), true, "the newest entry is the one before the last write")
        XCTAssertEqual(try store.load(note.url).status, "One", "undo writes the file itself")
        XCTAssertEqual(try history.entries(for: note.url.path).count, 1, "only the used entry is removed")

        XCTAssertNotNil(try history.restoreLatest(for: note.url))
        XCTAssertEqual(try store.load(note.url).status, "Unsorted", "the original source has no status property")
        XCTAssertEqual(try history.entries(for: note.url.path).count, 0)
        XCTAssertNil(try history.restoreLatest(for: note.url), "no history means nothing to restore")
    }

    func testRestoreLatestKeepsTheEntryWhenTheNoteWriteFails() throws {
        let blocked = vaultDir.appendingPathComponent("blocked.md", isDirectory: true)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        let history = UndoHistory()
        try history.record(.init(path: blocked.path, previousSource: "previous"))
        XCTAssertEqual(try history.entries(for: blocked.path).count, 1)

        XCTAssertThrowsError(try history.restoreLatest(for: blocked)) { error in
            XCTAssertTrue(error is StoreError, "unexpected error \(error)")
        }
        XCTAssertEqual(
            try history.entries(for: blocked.path).count, 1,
            "a failed restore must leave the undo retryable"
        )
        XCTAssertEqual(try history.pop(path: blocked.path), "previous", "the entry is still usable afterwards")
    }

    func testRestoreLatestKeepsTheJournalPrivateAndWorksWithoutHistory() throws {
        let plain = vaultDir.appendingPathComponent("plain.md")
        try "# Plain\n".write(to: plain, atomically: true, encoding: .utf8)
        XCTAssertNil(try UndoHistory().restoreLatest(for: plain))

        let note = try makeNote("Private")
        try store.updateMetadata("status", value: "One", for: note)
        _ = try UndoHistory().restoreLatest(for: note.url)
        #if !os(Windows)
        let attributes = try FileManager.default.attributesOfItem(atPath: journal.path)
        let mode = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
        XCTAssertEqual(mode & 0o777, 0o600, "the journal holds note contents and must stay private")
        #endif
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
