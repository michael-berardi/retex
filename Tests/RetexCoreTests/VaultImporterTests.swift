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
}
