import XCTest
@testable import RetexCore

/// A cached store must answer exactly like a plain store after every kind of
/// outside change, with and without file events.
final class VaultSnapshotCacheTests: XCTestCase {
    private var root: URL!
    private var vaultDir: URL!
    private var outsideDir: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-cache-\(UUID().uuidString)", isDirectory: true)
        vaultDir = root.appendingPathComponent("vault", isDirectory: true)
        outsideDir = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: vaultDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        for index in 0..<30 {
            try write("seed/note-\(index).md", "---\ntype: memory\n---\n# Seed \(index)\nseed body [[Seed \(index + 1)]]\n")
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var vault: Vault { Vault(url: vaultDir) }

    private func write(_ name: String, _ text: String, in directory: URL? = nil) throws {
        let url = (directory ?? vaultDir).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: false, encoding: .utf8)
    }

    private func assertSame(_ cached: MarkdownStore, _ step: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let plain = MarkdownStore()
        XCTAssertEqual(try cached.scan(vault).map(\.id), try plain.scan(vault).map(\.id), "scan after \(step)", file: file, line: line)
        XCTAssertEqual(try cached.scan(vault).map(\.source), try plain.scan(vault).map(\.source), "sources after \(step)", file: file, line: line)
        for query in ["probe", "seed", "café"] {
            XCTAssertEqual(try cached.search(vault, query: query).map(\.id), try plain.search(vault, query: query).map(\.id),
                           "search \(query) after \(step)", file: file, line: line)
            XCTAssertEqual(try cached.recall(vault, query: query).map(\.note.id), try plain.recall(vault, query: query).map(\.note.id),
                           "recall \(query) after \(step)", file: file, line: line)
        }
        let target = vaultDir.appendingPathComponent("seed/note-3.md")
        let cachedLinks = try cached.links(vault, for: target)
        let plainLinks = try plain.links(vault, for: target)
        XCTAssertEqual(cachedLinks.backlinks.map(\.id), plainLinks.backlinks.map(\.id), "backlinks after \(step)", file: file, line: line)
        XCTAssertEqual(cachedLinks.outgoing.map(\.id), plainLinks.outgoing.map(\.id), "outgoing after \(step)", file: file, line: line)
    }

    private func exerciseChanges(_ store: MarkdownStore) throws {
        try assertSame(store, "first load")
        try write("seed/note-1.md", "---\ntype: memory\n---\n# Seed 1\nprobe one\n")
        try assertSame(store, "edit in place")
        try write("seed/note-1.md", "---\ntype: memory\n---\n# Seed 1\nprobe two\n")
        try assertSame(store, "same-size edit")
        try "# Atomic\nprobe café\n".write(to: vaultDir.appendingPathComponent("seed/note-2.md"), atomically: true, encoding: .utf8)
        try assertSame(store, "atomic replace")
        try write("new.md", "# New\nprobe new [[Seed 3]]\n")
        try assertSame(store, "create")
        try FileManager.default.moveItem(at: vaultDir.appendingPathComponent("new.md"), to: vaultDir.appendingPathComponent("moved.md"))
        try assertSame(store, "rename")
        try FileManager.default.removeItem(at: vaultDir.appendingPathComponent("moved.md"))
        try assertSame(store, "delete")
        try write("target.md", "# Linked\nseed outside\n", in: outsideDir)
        try FileManager.default.createSymbolicLink(at: vaultDir.appendingPathComponent("linked.md"), withDestinationURL: outsideDir.appendingPathComponent("target.md"))
        try assertSame(store, "symlink create")
        try write("target.md", "# Linked\nprobe edited outside\n", in: outsideDir)
        try assertSame(store, "symlink target edit")
        try write("folder/inner.md", "# Inner\nprobe inner\n")
        try assertSame(store, "new folder")
        try FileManager.default.moveItem(at: vaultDir.appendingPathComponent("folder"), to: vaultDir.appendingPathComponent("folder-2"))
        try assertSame(store, "folder rename")
        try write(".hidden/skip.md", "# Hidden\nprobe hidden\n")
        try assertSame(store, "hidden folder")
        try Data([0xFF, 0xFE, 0x41]).write(to: vaultDir.appendingPathComponent("broken.md"))
        XCTAssertEqual(try store.scanWithDiagnostics(vault).unreadable, try MarkdownStore().scanWithDiagnostics(vault).unreadable)
    }

    func testCachedStoreFollowsChangesWithFileEvents() throws {
        try exerciseChanges(MarkdownStore(cache: VaultSnapshotCache()))
    }

    func testCachedStoreFollowsChangesWithoutFileEvents() throws {
        try exerciseChanges(MarkdownStore(cache: VaultSnapshotCache(useFileEvents: false)))
    }

    func testInvalidateForcesAReread() throws {
        let cache = VaultSnapshotCache()
        let store = MarkdownStore(cache: cache)
        _ = try store.scan(vault)
        try write("seed/note-4.md", "# Seed 4\nprobe invalidated\n")
        cache.invalidate(vault)
        XCTAssertEqual(try store.search(vault, query: "probe invalidated").count, 1)
    }

    /// A single-file mutation marks that path dirty: the next request re-reads
    /// it without paying for a full vault walk.
    func testTargetedInvalidationReloadsOnlyTheGivenPaths() throws {
        // File events keep the cache off the "walk every request" path, so the
        // walk counter isolates the cost of the invalidation itself.
        let cache = VaultSnapshotCache(revalidateInterval: 3600)
        let store = MarkdownStore(cache: cache)
        _ = try store.scan(vault)
        let walks = cache.walksPerformed(vault)

        try write("seed/note-5.md", "# Seed 5\nprobe targeted\n")
        cache.invalidate(vault, paths: [vaultDir.appendingPathComponent("seed/note-5.md")])
        XCTAssertEqual(try store.search(vault, query: "probe targeted").count, 1)
        XCTAssertEqual(cache.walksPerformed(vault), walks, "targeted invalidation must not re-walk the vault")

        // An unknown path cannot be reloaded in place: the cache walks instead
        // of silently missing a new file.
        try write("seed/note-31.md", "# Seed 31\nprobe unknown path\n")
        cache.invalidate(vault, paths: [vaultDir.appendingPathComponent("seed/note-31.md")])
        XCTAssertEqual(try store.search(vault, query: "probe unknown path").count, 1)
        XCTAssertEqual(cache.walksPerformed(vault), walks + 1)
    }

    #if os(macOS)
    /// A delete is reported by FSEvents for a file that is gone by the time the
    /// walk finishes. It must not look like a missed event, or the cache walks
    /// the vault forever after.
    func testDeletingANoteDoesNotDisableFileEvents() throws {
        let cache = VaultSnapshotCache(revalidateInterval: 0.2)
        let store = MarkdownStore(cache: cache)
        _ = try store.scan(vault)
        try XCTSkipUnless(cache.eventsAreTrusted(vault), "file events unavailable in this environment")

        try FileManager.default.removeItem(at: vaultDir.appendingPathComponent("seed/note-7.md"))
        // Let the event drain and a timer-driven revalidate walk see the change.
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertEqual(try store.scan(vault).count, 29)
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertEqual(try store.scan(vault).count, 29)
        XCTAssertTrue(cache.eventsAreTrusted(vault), "a deletion must not switch file events off")
    }

    /// A barrier that is never reported must not stay in the sink for the life
    /// of the process: every wait removes its own record, and a flood of late
    /// events cannot grow the set without bound.
    func testBarrierWaitsLeaveNothingBehind() {
        let sink = VaultSnapshotCache.EventSink(rootPrefixes: ["/vault"], barrierDirectory: "/barriers")

        sink.record(path: "/barriers/arrived", flags: 0)
        XCTAssertTrue(
            VaultSnapshotCache.waitForBarrier(
                sink,
                barrier: "/barriers/arrived",
                deadline: DispatchTime.now().uptimeNanoseconds + 40_000_000
            )
        )
        XCTAssertEqual(sink.outstandingBarriers, 0)

        XCTAssertFalse(
            VaultSnapshotCache.waitForBarrier(
                sink,
                barrier: "/barriers/missing",
                deadline: DispatchTime.now().uptimeNanoseconds
            ),
            "a barrier that never arrives times out"
        )
        XCTAssertEqual(sink.outstandingBarriers, 0)

        // Late events for abandoned barriers are bounded, not accumulated.
        for index in 0..<200 { sink.record(path: "/barriers/late-\(index)", flags: 0) }
        XCTAssertLessThanOrEqual(sink.outstandingBarriers, 64)
    }
    #endif
}
