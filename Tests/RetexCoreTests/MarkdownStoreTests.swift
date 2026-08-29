import XCTest
@testable import RetexCore

final class MarkdownStoreTests: XCTestCase {
    private var vaultDir: URL!

    override func setUpWithError() throws {
        vaultDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: vaultDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: vaultDir)
    }

    private func writeNote(_ name: String, _ source: String) throws -> URL {
        let url = vaultDir.appendingPathComponent(name)
        try source.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Parsing

    func testParsesFlatFrontmatterAndInlineTags() throws {
        let url = try writeNote("deal.md", """
        ---
        title: Acme website rebuild
        type: deal
        status: Proposal
        rank: 3
        value: $11500
        tags: [website, priority]
        archived: false
        ---

        # Acme website rebuild

        Body text.
        """)

        let note = try MarkdownStore().load(url)
        XCTAssertEqual(note.title, "Acme website rebuild")
        XCTAssertEqual(note.type, .deal)
        XCTAssertEqual(note.status, "Proposal")
        XCTAssertEqual(note.rank, 3)
        XCTAssertEqual(note.value, "$11500")
        XCTAssertEqual(note.tags, ["website", "priority"])
        XCTAssertFalse(note.isArchived)
        XCTAssertTrue(note.body.hasPrefix("# Acme website rebuild"))
    }

    func testParsesDashListTagsAndQuotedValues() throws {
        let url = try writeNote("note.md", """
        ---
        title: Quoted
        status: "Won"
        tags:
          - alpha
          - beta
        ---

        Body.
        """)

        let note = try MarkdownStore().load(url)
        XCTAssertEqual(note.status, "Won")
        XCTAssertEqual(note.tags, ["alpha", "beta"])
    }

    func testPreservesUnknownProperties() throws {
        let url = try writeNote("note.md", """
        ---
        title: Unknowns
        type: note
        custom_field: keep me
        another: 42
        ---

        Body.
        """)

        let note = try MarkdownStore().load(url)
        XCTAssertEqual(note.metadata["custom_field"], "keep me")
        XCTAssertEqual(note.metadata["another"], "42")
    }

    func testPreservesArbitraryRecordTypeAlongsideCompatibilityEnum() throws {
        let url = try writeNote("invoice.md", """
        ---
        title: August invoice
        type: invoice
        amount: 11500
        ---

        Due this month.
        """)

        let note = try MarkdownStore().load(url)
        XCTAssertEqual(note.recordType, "invoice")
        XCTAssertEqual(note.type, .note)
    }

    func testNoteWithoutFrontmatterFallsBackToHeadingTitle() throws {
        let url = try writeNote("plain.md", "# My Heading\n\nBody only.")
        let note = try MarkdownStore().load(url)
        XCTAssertEqual(note.title, "My Heading")
        XCTAssertEqual(note.type, .note)
        XCTAssertEqual(note.status, "Unsorted")
    }

    func testNormalizesCRLFLineEndings() throws {
        let url = try writeNote("crlf.md", "---\r\ntitle: CRLF\r\ntype: task\r\n---\r\n\r\nBody.\r\n")
        let note = try MarkdownStore().load(url)
        XCTAssertEqual(note.title, "CRLF")
        XCTAssertEqual(note.body, "Body.")
    }

    // MARK: - Roundtrip mutations

    func testUpdateMetadataPreservesUnknownKeysAndBody() throws {
        let store = MarkdownStore()
        var note = try store.createNote(
            in: Vault(url: vaultDir),
            folder: "Notes",
            title: "Roundtrip",
            metadata: ["type": "task", "custom": "preserve"],
            body: "# Roundtrip\n\n- [x] done\n- [ ] pending"
        )

        note = try store.load(note.url)
        try store.updateMetadata(["status": "Qualified"], for: note)

        let reloaded = try store.load(note.url)
        XCTAssertEqual(reloaded.status, "Qualified")
        XCTAssertEqual(reloaded.metadata["custom"], "preserve")
        XCTAssertTrue(reloaded.body.contains("- [x] done"))
        XCTAssertFalse(reloaded.body.contains("---"))
    }

    func testSetPropertyReplacesExistingValue() throws {
        let store = MarkdownStore()
        let note = try store.createNote(
            in: Vault(url: vaultDir), folder: "Deals",
            title: "Replace", metadata: ["type": "deal", "status": "Inbox"], body: "b"
        )
        let loaded = try store.load(note.url)
        try store.updateMetadata(["status": "Won", "rank": "7"], for: loaded)

        let updated = try store.load(note.url)
        XCTAssertEqual(updated.status, "Won")
        XCTAssertEqual(updated.rank, 7)
    }

    func testExpectedHashRejectsStaleMutationWithoutOverwritingNewerContent() throws {
        let store = MarkdownStore()
        let original = try store.createNote(
            in: Vault(url: vaultDir),
            folder: "Notes",
            title: "Concurrent",
            metadata: ["status": "Inbox"],
            body: "original"
        )
        let expectedHash = original.contentHash

        try store.updateMetadata("status", value: "Proposal", for: original)
        XCTAssertThrowsError(
            try store.updateMetadata(
                "status",
                value: "Won",
                for: original,
                expectedHash: expectedHash
            )
        ) { error in
            guard case StoreError.staleNote = error else {
                return XCTFail("Expected staleNote, received \(error)")
            }
        }
        XCTAssertEqual(try store.load(original.url).status, "Proposal")
    }

    func testCreateSlugifiesAndDeduplicatesFileNames() throws {
        let store = MarkdownStore()
        let vault = Vault(url: vaultDir)
        let first = try store.createNote(in: vault, folder: "Notes", title: "Élan Café!", metadata: [:], body: "")
        let second = try store.createNote(in: vault, folder: "Notes", title: "Elan Cafe?", metadata: [:], body: "")

        XCTAssertEqual(first.url.deletingPathExtension().lastPathComponent, "elan-cafe")
        XCTAssertEqual(second.url.deletingPathExtension().lastPathComponent, "elan-cafe-2")
    }

    func testCreateRejectsFoldersOutsideVault() throws {
        let store = MarkdownStore()
        let outsideName = "retex-outside-\(UUID().uuidString)"
        let outside = vaultDir.deletingLastPathComponent().appendingPathComponent(outsideName)
        defer { try? FileManager.default.removeItem(at: outside) }

        XCTAssertThrowsError(
            try store.createNote(
                in: Vault(url: vaultDir),
                folder: "../\(outsideName)",
                title: "Escaped",
                metadata: [:],
                body: ""
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
    }

    func testRejectsFrontmatterInjectionBeforeJournaling() throws {
        let store = MarkdownStore()
        let note = try store.createNote(
            in: Vault(url: vaultDir),
            folder: "Notes",
            title: "Protected",
            metadata: [:],
            body: "unchanged"
        )

        XCTAssertThrowsError(try store.updateMetadata(["safe\ninjected": "value"], for: note))
        XCTAssertThrowsError(try store.updateMetadata(["safe": "value\n---\ninjected: true"], for: note))
        XCTAssertEqual(try store.load(note.url).body, "unchanged")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: vaultDir.appendingPathComponent(".retex/history.jsonl").path
        ))
    }

    func testScanSkipsNonMarkdownAndSortsDeterministically() throws {
        _ = try writeNote("a-note.md", "---\ntitle: A\n---\nbody")
        _ = try writeNote("ignored.txt", "not markdown")
        try FileManager.default.createDirectory(
            at: vaultDir.appendingPathComponent("Sub"),
            withIntermediateDirectories: true
        )
        try "—\ntitle: B\n—\n".data(using: .utf8)!.write(to: vaultDir.appendingPathComponent("Sub/b.md"))

        let notes = try MarkdownStore().scan(Vault(url: vaultDir))
        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(notes.map(\.title).sorted(), ["A", "b"])
        // b.md has an em-dash frontmatter (invalid) so it parses as plain note titled "b".
        XCTAssertEqual(notes.map { $0.url.lastPathComponent }.sorted(), ["a-note.md", "b.md"])
    }

    func testSearchMatchesFilenameMetadataAndCase() throws {
        _ = try writeNote("filename-only-match.md", "Plain body.")
        _ = try writeNote("metadata.md", "---\ntitle: Metadata\nowner: Needle\n---\nOther body.")
        _ = try writeNote("accent.md", "---\ntitle: Accent\n---\nÉlan Café")
        _ = try writeNote("unrelated.md", "Nothing relevant.")
        let store = MarkdownStore()
        let vault = Vault(url: vaultDir)

        XCTAssertEqual(try store.search(vault, query: "only").map(\.title), ["filename-only-match"])
        XCTAssertEqual(try store.search(vault, query: "needle").map(\.title), ["Metadata"])
        XCTAssertEqual(try store.search(vault, query: "CAFÉ").map(\.title), ["Accent"])
    }

    func testASCIIByteSearchHandlesOverlapsAndFileBoundaries() throws {
        _ = try writeNote("overlap.md", "prefix AAAAAB")
        _ = try writeNote("suffix.md", "content ending in FinalNeedle")
        let store = MarkdownStore()
        let vault = Vault(url: vaultDir)

        XCTAssertEqual(try store.search(vault, query: "aaab").map(\.title), ["overlap"])
        XCTAssertEqual(try store.search(vault, query: "FINALNEEDLE").map(\.title), ["suffix"])
        XCTAssertTrue(try store.search(vault, query: "missing").isEmpty)
    }

    func testRankedSearchMatchesAllTermsPrioritizesTitleAndLimitsResults() throws {
        _ = try writeNote(
            "best.md",
            "---\ntitle: Retex release process\n---\nSafe upgrade instructions."
        )
        _ = try writeNote(
            "body.md",
            "---\ntitle: General operations\n---\nThe release process for Retex is documented here."
        )
        _ = try writeNote(
            "partial.md",
            "---\ntitle: Retex internals\n---\nNo publication notes."
        )

        let results = try MarkdownStore().search(
            Vault(url: vaultDir),
            query: "Retex release",
            ranked: true,
            limit: 1
        )
        XCTAssertEqual(results.map(\.title), ["Retex release process"])
    }

    func testRecallRemovesFillerRanksEvidenceAndFiltersMetadata() throws {
        _ = try writeNote(
            "standard.md",
            """
            ---
            title: Retex Vault Upgrade Standard
            type: standard
            owner: Ops
            ---

            Validate every upgrade on a disposable vault clone.
            """
        )
        _ = try writeNote(
            "partial.md",
            "---\ntitle: Retex notes\nowner: Other\n---\nGeneral release information."
        )
        _ = try writeNote(
            "archived.md",
            "---\ntitle: Retex Vault Upgrade Standard Archive\ntype: standard\nowner: Ops\narchived: true\n---\nOld upgrade standard."
        )

        let results = try MarkdownStore().recall(
            Vault(url: vaultDir),
            query: "what is the Retex vault upgrade standard",
            metadata: ["owner": "Ops"],
            limit: 5
        )

        XCTAssertEqual(results.map(\.note.recordType), ["standard"])
        XCTAssertEqual(results[0].matchedTerms, ["retex", "standard", "upgrade", "vault"])
        XCTAssertTrue(results[0].excerpt.contains("disposable vault clone"))
        XCTAssertEqual(
            try MarkdownStore().recall(
                Vault(url: vaultDir),
                query: "Retex vault upgrade standard",
                metadata: ["owner": "Ops"],
                includeArchived: true,
                limit: 5
            ).count,
            2
        )
    }

    func testLinksResolvesOutgoingBacklinksAndUnresolvedTargets() throws {
        let alpha = try writeNote(
            "alpha.md",
            "---\ntitle: Alpha\n---\nSee [[Beta|the beta note]] and [[Missing]]."
        )
        _ = try writeNote(
            "beta.md",
            "---\ntitle: Beta\n---\nThe decision is linked from [[Alpha#Decision]]."
        )

        let graph = try MarkdownStore().links(Vault(url: vaultDir), for: alpha)

        XCTAssertEqual(graph.outgoing.map(\.title), ["Beta"])
        XCTAssertEqual(graph.backlinks.map(\.title), ["Beta"])
        XCTAssertEqual(graph.unresolved, ["Missing"])
    }

    func testLinksIncludeExplicitFrontmatterRelationships() throws {
        let alpha = try writeNote(
            "alpha-metadata.md",
            "---\ntitle: Alpha Metadata\nsupersedes: \"[[Beta Metadata]]\"\n---\nNo body links."
        )
        _ = try writeNote(
            "beta-metadata.md",
            "---\ntitle: Beta Metadata\nrelated: \"[[Alpha Metadata]]\"\n---\nNo body links."
        )

        let graph = try MarkdownStore().links(Vault(url: vaultDir), for: alpha)

        XCTAssertEqual(graph.outgoing.map(\.title), ["Beta Metadata"])
        XCTAssertEqual(graph.backlinks.map(\.title), ["Beta Metadata"])
    }

    func testMetadataDateRangesAreInclusiveAndIgnoreMissingDates() throws {
        let old = try MarkdownStore().load(try writeNote(
            "old.md",
            "---\ntitle: Old\nreview_after: 2026-08-01\n---\nReview me."
        ))
        let today = try MarkdownStore().load(try writeNote(
            "today.md",
            "---\ntitle: Today\nreview_after: 2026-08-28\n---\nReview me."
        ))
        let future = try MarkdownStore().load(try writeNote(
            "future.md",
            "---\ntitle: Future\nreview_after: 2026-09-01\n---\nReview me later."
        ))
        let missing = try MarkdownStore().load(try writeNote(
            "missing.md",
            "---\ntitle: Missing\n---\nNo review date."
        ))

        let due = [old, today, future, missing].filter {
            MarkdownStore.matches(
                $0,
                onOrBefore: ["review_after": "2026-08-28"]
            )
        }
        XCTAssertEqual(due.map(\.title), ["Old", "Today"])

        let upcoming = [old, today, future, missing].filter {
            MarkdownStore.matches(
                $0,
                onOrAfter: ["review_after": "2026-08-28"]
            )
        }
        XCTAssertEqual(upcoming.map(\.title), ["Today", "Future"])
    }

    func testSearchRejectsEmptyQueriesAndInvalidLimits() throws {
        let store = MarkdownStore()
        let vault = Vault(url: vaultDir)
        XCTAssertThrowsError(try store.search(vault, query: "   "))
        XCTAssertThrowsError(try store.search(vault, query: "note", limit: 0))
    }

    func testSaveBodyKeepsFrontmatterIntact() throws {
        let store = MarkdownStore()
        let note = try store.createNote(
            in: Vault(url: vaultDir), folder: "Notes",
            title: "Body Swap", metadata: ["type": "note", "keep": "yes"], body: "old"
        )
        let loaded = try store.load(note.url)
        try store.saveBody("brand new body", for: loaded)

        let updated = try store.load(note.url)
        XCTAssertEqual(updated.body, "brand new body")
        XCTAssertEqual(updated.metadata["keep"], "yes")
    }
}

final class ChecklistProgressTests: XCTestCase {
    func testCountsCompletedChecklistItems() {
        let note = Note(
            url: URL(fileURLWithPath: "/tmp/x.md"),
            source: "---\ntitle: t\n---\nbody",
            title: "t",
            body: "- [x] one\n- [ ] two\n  - [X] nested\nnot a task\n- [three]",
            metadata: [:],
            tags: [],
            modifiedAt: Date()
        )
        XCTAssertEqual(note.checklistProgress.completed, 2)
        XCTAssertEqual(note.checklistProgress.total, 3)
    }
}

final class ScanResilienceTests: XCTestCase {
    func testScanSkipsDanglingSymlinksInsteadOfFailing() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try "---\ntitle: Real\n---\nbody".write(to: dir.appendingPathComponent("real.md"),
                                                  atomically: true, encoding: .utf8)
        // Dangling symlink, the exact shape of broken agent-memory links.
        try FileManager.default.createSymbolicLink(
            atPath: dir.appendingPathComponent("ghost.md").path,
            withDestinationPath: "/nonexistent/target-xyz.md"
        )

        let notes = try MarkdownStore().scan(Vault(url: dir))
        XCTAssertEqual(notes.map(\.title), ["Real"], "One dangling symlink must not zero out the scan")
    }
}

final class ScanDeterminismTests: XCTestCase {
    func testParallelScanIsDeterministicWithDuplicateTimestamps() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-det-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Same mtime for all files: ordering must fall through to title/path.
        let when = Date(timeIntervalSince1970: 1_000_000)
        for name in ["zulu", "alpha", "mike", "bravo"] {
            let url = dir.appendingPathComponent("\(name).md")
            try "---\ntitle: \(name)\n---\nbody".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.modificationDate: when],
                ofItemAtPath: url.path
            )
        }

        let store = MarkdownStore()
        let first = try store.scan(Vault(url: dir)).map(\.title)
        // Repeat several times: concurrency must never reorder output.
        for _ in 0..<5 {
            XCTAssertEqual(try store.scan(Vault(url: dir)).map(\.title), first)
        }
        XCTAssertEqual(first, ["alpha", "bravo", "mike", "zulu"])
    }
}
