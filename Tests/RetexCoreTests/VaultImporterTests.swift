import XCTest
@testable import RetexCore

final class VaultImporterTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-import-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testObsidianImportPreservesMarkdownAndAttachmentsButNotEditorState() throws {
        let source = root.appendingPathComponent("Obsidian", isDirectory: true)
        let destination = root.appendingPathComponent("Imported", isDirectory: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        try "{}".write(to: source.appendingPathComponent(".obsidian/app.json"), atomically: true, encoding: .utf8)
        try "# Note\n\n![[image.png]]".write(to: source.appendingPathComponent("Note.md"), atomically: true, encoding: .utf8)
        try Data([137, 80, 78, 71]).write(to: source.appendingPathComponent("image.png"))

        let result = try VaultImporter().importSource(source, into: destination)

        XCTAssertEqual(result.format, .obsidian)
        XCTAssertEqual(result.notes, 1)
        XCTAssertEqual(result.assets, 1)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("Note.md"), encoding: .utf8), "# Note\n\n![[image.png]]")
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("image.png")), Data([137, 80, 78, 71]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent(".obsidian").path))
    }

    func testNotionImportRemovesOpaqueIDsRewritesLinksAndConvertsCSV() throws {
        let source = root.appendingPathComponent("Notion", isDirectory: true)
        let destination = root.appendingPathComponent("Imported", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let parent = source.appendingPathComponent("Parent aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.md")
        let child = source.appendingPathComponent("Child bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.md")
        try "# Parent\n\n[Child](Child%20bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.md)".write(to: parent, atomically: true, encoding: .utf8)
        try "# Child".write(to: child, atomically: true, encoding: .utf8)
        try "Name,Status\n\"Launch, site\",Done\nSecond,Queued\n".write(
            to: source.appendingPathComponent("Tasks cccccccccccccccccccccccccccccccc.csv"),
            atomically: true,
            encoding: .utf8
        )

        let result = try VaultImporter().importSource(source, into: destination, format: .notion)

        XCTAssertEqual(result.format, .notion)
        XCTAssertEqual(result.notes, 3)
        XCTAssertEqual(result.assets, 1)
        XCTAssertEqual(result.convertedTables, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Parent.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Child.md").path))
        let parentBody = try String(contentsOf: destination.appendingPathComponent("Parent.md"), encoding: .utf8)
        XCTAssertTrue(parentBody.contains("Child.md"))
        XCTAssertFalse(parentBody.contains("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"))
        let table = try String(contentsOf: destination.appendingPathComponent("Tasks.md"), encoding: .utf8)
        XCTAssertTrue(table.contains("| Name | Status |"))
        XCTAssertTrue(table.contains("| Launch, site | Done |"))
    }

    func testNotionZIPRejectsTraversalBeforeExtraction() throws {
        let encoded = "UEsDBBQAAAAIAHmiG10sEsRhBQAAAAMAAAAMAAAALi4vZXNjYXBlLm1kKyjPAwBQSwECFAMUAAAACAB5ohtdLBLEYQUAAAADAAAADAAAAAAAAAAAAAAAgAEAAAAALi4vZXNjYXBlLm1kUEsFBgAAAAABAAEAOgAAAC8AAAAAAA=="
        let archive = root.appendingPathComponent("malicious.zip")
        try XCTUnwrap(Data(base64Encoded: encoded)).write(to: archive)
        let destination = root.appendingPathComponent("Imported", isDirectory: true)
        let escaped = root.deletingLastPathComponent().appendingPathComponent("escape.md")
        try? FileManager.default.removeItem(at: escaped)

        XCTAssertThrowsError(try VaultImporter().importSource(archive, into: destination, format: .notion))
        XCTAssertFalse(FileManager.default.fileExists(atPath: escaped.path))
    }

    func testImportRefusesNonEmptyDestinationAndSymlinks() throws {
        let source = root.appendingPathComponent("Source", isDirectory: true)
        let destination = root.appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try "keep".write(to: destination.appendingPathComponent("existing.md"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try VaultImporter().importSource(source, into: destination))

        try FileManager.default.removeItem(at: destination)
        let outside = root.appendingPathComponent("outside.md")
        try "outside".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("linked.md"), withDestinationURL: outside)
        XCTAssertThrowsError(try VaultImporter().importSource(source, into: destination))
    }

    // MARK: - Notion path normalization

    func testNotionCollisionRenamesStayInsideDestination() throws {
        let source = root.appendingPathComponent("Notion", isDirectory: true)
        let destination = root.appendingPathComponent("Imported", isDirectory: true)
        try write("first", to: source.appendingPathComponent("Sub/Note aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.md"))
        try write("second", to: source.appendingPathComponent("Sub/Note bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.md"))

        let result = try VaultImporter().importSource(source, into: destination, format: .notion)

        XCTAssertEqual(result.notes, 2)
        XCTAssertEqual(try files(in: destination), ["Sub/Note-2.md", "Sub/Note.md"])
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("Sub/Note-2.md"), encoding: .utf8), "second")
    }

    func testNotionIDOnlyFolderDoesNotOverwriteSibling() throws {
        let source = root.appendingPathComponent("Notion", isDirectory: true)
        let destination = root.appendingPathComponent("Imported", isDirectory: true)
        try write("nested", to: source.appendingPathComponent("a/ 0123456789abcdef0123456789abcdef/b.md"))
        try write("direct", to: source.appendingPathComponent("a/b.md"))

        let result = try VaultImporter().importSource(source, into: destination, format: .notion)

        XCTAssertEqual(result.notes, 2)
        let imported = try files(in: destination)
        XCTAssertEqual(imported, ["a/b-2.md", "a/b.md"])
        let bodies = try Set(imported.map { try String(contentsOf: destination.appendingPathComponent($0), encoding: .utf8) })
        XCTAssertEqual(bodies, ["nested", "direct"])
    }

    func testNotionLinksToNestedPagesAreRewrittenRelativeToEachNote() throws {
        let source = root.appendingPathComponent("Notion", isDirectory: true)
        let destination = root.appendingPathComponent("Imported", isDirectory: true)
        let parentID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let childID = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        try write(
            "# Parent\n\n[Child](Parent%20\(parentID)/Child%20\(childID).md#Section) and ![img](Parent%20\(parentID)/diagram.png) and [web](https://example.com/Child%20\(childID).md)",
            to: source.appendingPathComponent("Parent \(parentID).md")
        )
        try write(
            "# Child\n\n[Up](../Parent%20\(parentID).md) [Raw](../Parent \(parentID).md)",
            to: source.appendingPathComponent("Parent \(parentID)/Child \(childID).md")
        )
        try Data([1, 2, 3]).write(to: source.appendingPathComponent("Parent \(parentID)/diagram.png"))

        _ = try VaultImporter().importSource(source, into: destination, format: .notion)

        let parent = try String(contentsOf: destination.appendingPathComponent("Parent.md"), encoding: .utf8)
        XCTAssertTrue(parent.contains("[Child](Parent/Child.md#Section)"), parent)
        XCTAssertTrue(parent.contains("![img](Parent/diagram.png)"), parent)
        XCTAssertTrue(parent.contains("(https://example.com/Child%20\(childID).md)"), "External links are untouched")
        let child = try String(contentsOf: destination.appendingPathComponent("Parent/Child.md"), encoding: .utf8)
        XCTAssertEqual(child, "# Child\n\n[Up](../Parent.md) [Raw](../Parent.md)")
    }

    func testNotionTableDoesNotOverwriteRealNoteWithTheSameName() throws {
        let source = root.appendingPathComponent("Notion", isDirectory: true)
        let destination = root.appendingPathComponent("Imported", isDirectory: true)
        try write("Name\nRow\n", to: source.appendingPathComponent("Tasks 00000000000000000000000000000000.csv"))
        try write("# Real tasks page", to: source.appendingPathComponent("Tasks ffffffffffffffffffffffffffffffff.md"))

        let result = try VaultImporter().importSource(source, into: destination, format: .notion)

        XCTAssertEqual(result.notes, 2)
        XCTAssertEqual(result.convertedTables, 1)
        XCTAssertEqual(try files(in: destination), ["Tasks-2.md", "Tasks.csv", "Tasks.md"])
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("Tasks.md"), encoding: .utf8), "# Real tasks page")
        XCTAssertTrue(try String(contentsOf: destination.appendingPathComponent("Tasks-2.md"), encoding: .utf8).contains("| Row |"))
    }

    func testNotionLinkRewritingScalesLinearly() throws {
        let source = root.appendingPathComponent("Notion", isDirectory: true)
        let destination = root.appendingPathComponent("Imported", isDirectory: true)
        let count = 1_000
        let ids = (0..<count).map { String(format: "%032x", $0 + 1) }
        for index in 0..<count {
            let next = (index + 1) % count
            try write(
                "# Page \(index)\n\n[Next](Page%20\(next)%20\(ids[next]).md)\n" + String(repeating: "lorem ipsum ", count: 150),
                to: source.appendingPathComponent("Page \(index) \(ids[index]).md")
            )
        }

        let start = Date()
        let result = try VaultImporter().importSource(source, into: destination, format: .notion)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(result.notes, count)
        XCTAssertTrue(try String(contentsOf: destination.appendingPathComponent("Page 7.md"), encoding: .utf8)
            .contains("[Next](Page%208.md)"))
        XCTAssertLessThan(elapsed, 20, "1,000 linked pages took \(elapsed)s")
    }

    // MARK: - Content and failure handling

    func testNonUTF8NoteIsCopiedByteForByte() throws {
        let source = root.appendingPathComponent("Notion", isDirectory: true)
        let destination = root.appendingPathComponent("Imported", isDirectory: true)
        let latin1 = Data([0x23, 0x20, 0x43, 0x61, 0x66, 0xE9, 0x0A])
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try latin1.write(to: source.appendingPathComponent("Legacy aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.md"))
        try write("Name\n", to: source.appendingPathComponent("Other.md"))

        let result = try VaultImporter().importSource(source, into: destination, format: .notion)

        XCTAssertEqual(result.notes, 2)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("Legacy.md")), latin1)
    }

    func testFailedImportRemovesPartialOutputSoItCanBeRetried() throws {
        let source = root.appendingPathComponent("Notion", isDirectory: true)
        // `Parent <id>` (a file) and `Parent <id>/` (a folder) both map to `Parent`.
        try write("asset", to: source.appendingPathComponent("Parent 00000000000000000000000000000000"))
        try write("# Child", to: source.appendingPathComponent("Parent 11111111111111111111111111111111/Child.md"))

        let created = root.appendingPathComponent("Created", isDirectory: true)
        XCTAssertThrowsError(try VaultImporter().importSource(source, into: created, format: .notion)) { error in
            guard case let .fileFailed(path, _)? = error as? VaultImporter.ImportError else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(path, "Parent 11111111111111111111111111111111/Child.md")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: created.path))

        let existing = root.appendingPathComponent("Existing", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        XCTAssertThrowsError(try VaultImporter().importSource(source, into: existing, format: .notion))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: existing.path), [])
    }

    // MARK: - ZIP extraction

#if !os(Windows)
    func testZIPExtractionEnforcesRealSizesNotDeclaredOnes() throws {
        let temporary = root.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let importer = VaultImporter(maximumFileBytes: 1_000, maximumTotalBytes: 1_500, temporaryRoot: temporary)

        var bomb = ZIPFixture()
        bomb.add("Export/big.md", Data(repeating: 0x61, count: 50_000), declaredSize: 10)
        let archive = root.appendingPathComponent("bomb.zip")
        try bomb.data().write(to: archive)

        let extracted = root.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        let entries = try importer.validateZIP(archive)
        XCTAssertThrowsError(try importer.extractZIP(archive, entries: entries, into: extracted)) { error in
            XCTAssertEqual(error as? VaultImporter.ImportError, .fileTooLarge(archive.path))
        }
        // The real size is measured before extraction, so nothing is written.
        XCTAssertFalse(FileManager.default.fileExists(atPath: extracted.appendingPathComponent("Export/big.md").path))

        var spread = ZIPFixture()
        spread.add("Export/one.md", Data(repeating: 0x61, count: 900))
        spread.add("Export/two.md", Data(repeating: 0x62, count: 900))
        try spread.data().write(to: archive)
        let spreadOut = root.appendingPathComponent("spread", isDirectory: true)
        try FileManager.default.createDirectory(at: spreadOut, withIntermediateDirectories: true)
        // Skip the declared-size preflight to show extraction measures the
        // real total across entries before writing any of them.
        let spreadEntries = ["Export/one.md", "Export/two.md"].map { VaultImporter.ZIPEntry(name: $0, isDirectory: false) }
        XCTAssertThrowsError(try importer.extractZIP(archive, entries: spreadEntries, into: spreadOut)) { error in
            XCTAssertEqual(error as? VaultImporter.ImportError, .fileTooLarge(archive.path))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: spreadOut.path), [])

        var single = ZIPFixture()
        single.add("Export/big.md", Data(repeating: 0x61, count: 1_200), declaredSize: 10)
        try single.data().write(to: archive)
        // Within the total but lying about its size: refused either by the
        // per-file limit or by `unzip`'s own size check, never imported.
        XCTAssertThrowsError(try importer.importSource(archive, into: root.appendingPathComponent("Imported"))) { error in
            XCTAssertTrue(
                [.fileTooLarge("Export/big.md"), .archiveExtractionFailed].contains(error as? VaultImporter.ImportError),
                "\(error)"
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Imported/big.md").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporary.path), [])
    }

    func testFailedZIPExtractionRemovesPrivateTemporaryDirectory() throws {
        let temporary = root.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let importer = VaultImporter(maximumFileBytes: 1_000, maximumTotalBytes: 1_500, temporaryRoot: temporary)
        var corrupt = ZIPFixture()
        corrupt.add("Export/Note.md", Data("# Note".utf8), corruptChecksum: true)
        let archive = root.appendingPathComponent("corrupt.zip")
        try corrupt.data().write(to: archive)

        XCTAssertThrowsError(try importer.importSource(archive, into: root.appendingPathComponent("Imported"))) { error in
            XCTAssertEqual(error as? VaultImporter.ImportError, .archiveExtractionFailed)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporary.path), [])

        let privateDirectory = temporary.appendingPathComponent("private", isDirectory: true)
        try VaultImporter.createPrivateDirectory(privateDirectory)
        let mode = try FileManager.default.attributesOfItem(atPath: privateDirectory.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o700)
    }

    func testZIPWithDuplicateEntryNamesIsRejectedWithoutPrompting() throws {
        var duplicate = ZIPFixture()
        duplicate.add("Export/a.md", Data("first".utf8))
        duplicate.add("Export/a.md", Data("second".utf8))
        let archive = root.appendingPathComponent("duplicate.zip")
        try duplicate.data().write(to: archive)
        XCTAssertThrowsError(try VaultImporter().importSource(archive, into: root.appendingPathComponent("Imported"))) { error in
            XCTAssertEqual(error as? VaultImporter.ImportError, .unsafeSource("Export/a.md"))
        }

        var aliased = ZIPFixture()
        aliased.add("Export/a.md", Data("first".utf8))
        aliased.add("Export/./a.md", Data("second".utf8))
        try aliased.data().write(to: archive)
        XCTAssertThrowsError(try VaultImporter().importSource(archive, into: root.appendingPathComponent("Imported")))
    }

    func testZIPEntriesWithoutFileTypeBitsAreImported() throws {
        var archiveBuilder = ZIPFixture()
        // Python's zipfile.writestr stores 0o600 with no S_IFREG bits (`?rw-------`).
        archiveBuilder.add("Export/Note [draft] aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.md", Data("# Note".utf8), unixMode: 0o600)
        archiveBuilder.add("Export/link.md", Data("target.md".utf8), unixMode: 0o120777)
        let archive = root.appendingPathComponent("python.zip")
        try archiveBuilder.data().write(to: archive)
        XCTAssertThrowsError(try VaultImporter().importSource(archive, into: root.appendingPathComponent("Rejected"))) { error in
            XCTAssertEqual(error as? VaultImporter.ImportError, .unsafeSource("Export/link.md"), "Symlink entries stay unsafe")
        }

        archiveBuilder.entries.removeLast()
        try archiveBuilder.data().write(to: archive)
        let destination = root.appendingPathComponent("Imported", isDirectory: true)
        let result = try VaultImporter().importSource(archive, into: destination)

        XCTAssertEqual(result.format, .notion)
        XCTAssertEqual(result.notes, 1)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("Note [draft].md"), encoding: .utf8), "# Note")
    }
#endif

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func files(in directory: URL) throws -> [String] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]))
        return try enumerator.compactMap { item -> String? in
            let url = try XCTUnwrap(item as? URL)
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { return nil }
            return url.standardizedFileURL.pathComponents
                .dropFirst(directory.standardizedFileURL.pathComponents.count)
                .joined(separator: "/")
        }.sorted()
    }
}
