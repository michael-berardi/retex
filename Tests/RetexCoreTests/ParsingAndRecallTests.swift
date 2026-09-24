import XCTest
@testable import RetexCore

/// Regression coverage for front-matter fidelity, accent-insensitive matching,
/// wiki-link scanning, and the native text paths that replaced Foundation
/// bridging on hot paths.
final class ParsingAndRecallTests: XCTestCase {
    private var vaultDir: URL!
    private let store = MarkdownStore()

    override func setUpWithError() throws {
        vaultDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-parsing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: vaultDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: vaultDir)
    }

    private var vault: Vault { Vault(url: vaultDir) }

    @discardableResult
    private func write(_ name: String, _ source: String) throws -> URL {
        let url = vaultDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try source.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Front matter

    func testNestedMappingsListsAndBlockScalarsStayWithTheirKey() throws {
        let url = try write("nested.md", """
        ---
        type: contact
        author:
          name: Bob
          title: Nested Title Must Not Win
        aliases:
          - http://example.com
        summary: |
          status: not a property
          second line
        folded: >
          one
          two
        ---
        # Real Heading
        """)
        let note = try store.load(url)
        XCTAssertEqual(note.title, "Real Heading")
        XCTAssertEqual(note.status, "Unsorted")
        XCTAssertNil(note.metadata["name"])
        XCTAssertNil(note.metadata["- http"])
        XCTAssertEqual(note.metadata["summary"], "status: not a property\nsecond line")
        XCTAssertEqual(note.metadata["folded"], "one two")
        XCTAssertEqual(note.recordType, "contact")
    }

    func testScalarAndCommaSeparatedTagsAreTags() throws {
        let single = try store.load(write("single.md", "---\ntags: urgent\n---\nbody"))
        XCTAssertEqual(single.tags, ["urgent"])
        let several = try store.load(write("several.md", "---\ntags: a, \"b c\"\n---\nbody"))
        XCTAssertEqual(several.tags, ["a", "b c"])
        let empty = try store.load(write("empty.md", "---\ntags:\n---\nbody"))
        XCTAssertEqual(empty.tags, [])
        let quotedList = try store.load(write("quoted-list.md", "---\ntags: \"[work, home]\"\n---\nbody"))
        XCTAssertEqual(quotedList.tags, ["work", "home"])
    }

    func testCreatedScalarTagIsFoundByTagFilter() throws {
        let note = try store.createNote(
            in: vault,
            folder: "Notes",
            title: "Urgent thing",
            metadata: ["tags": "urgent"],
            body: "body"
        )
        XCTAssertEqual(note.tags, ["urgent"])
        XCTAssertTrue(MarkdownStore.matches(note, tag: "urgent"))
    }

    func testMetadataRoundTripsValuesThatNeedQuotingOrEscaping() throws {
        let values = [
            "She said: \"hi\"",
            "'single quoted'",
            "\"double quoted\"",
            "C:\\dir\\file",
            "back\\slash: colon",
            "|",
            ">folded",
            "*anchor",
            "&ref",
            "!tag",
            "- item",
            " padded ",
            "tab\tinside",
            "it's",
            "#hash",
            "plain value",
        ]
        let note = try store.createNote(in: vault, folder: "", title: "Quotes", metadata: [:], body: "body")
        var updates: [String: String] = [:]
        for (index, value) in values.enumerated() { updates["k\(index)"] = value }
        try store.updateMetadata(updates, for: note)
        let reloaded = try store.load(note.url)
        for (index, value) in values.enumerated() {
            XCTAssertEqual(reloaded.metadata["k\(index)"], value, "value \(index) did not round-trip")
        }
    }

    func testLegacyUnescapedBackslashesStillReadAsWritten() throws {
        // Earlier versions quoted values containing ':' without escaping '\'.
        let note = try store.load(write("legacy.md", "---\npath: \"C:\\temp\\new\"\n---\nbody"))
        XCTAssertEqual(note.metadata["path"], "C:\\temp\\new")
    }

    func testLineEndingsBOMAndWhitespaceMatchStringSemantics() throws {
        let crlf = try store.load(write("crlf.md", "---\r\ntitle: CRLF\r\nstatus: Open\r\n---\r\n\r\n# Head\r\nline\r\n"))
        XCTAssertEqual(crlf.title, "CRLF")
        XCTAssertEqual(crlf.status, "Open")
        XCTAssertEqual(crlf.body, "# Head\nline")

        let bomURL = vaultDir.appendingPathComponent("bom.md")
        try Data([0xEF, 0xBB, 0xBF] + Array("---\ntype: task\n---\n# BOM\n".utf8)).write(to: bomURL)
        let bom = try store.load(bomURL)
        XCTAssertEqual(bom.recordType, "task")
        XCTAssertEqual(bom.title, "BOM")
        XCTAssertFalse(bom.source.hasPrefix("\u{FEFF}"))

        let loneCR = try store.load(write("lonecr.md", "body\rmore\n"))
        XCTAssertEqual(loneCR.body, "body\rmore")

        let spaced = try store.load(write("spaced.md", "\u{2003}\n# Title\n\u{3000}text\u{2028}\n"))
        XCTAssertEqual(spaced.body, "# Title\n\u{3000}text")
        XCTAssertEqual(spaced.title, "Title")
    }

    func testInvalidUTF8IsRejectedWithAClearError() throws {
        let url = vaultDir.appendingPathComponent("latin1.md")
        try Data([0x23, 0x20, 0x63, 0x61, 0x66, 0xE9, 0x0A]).write(to: url)
        XCTAssertThrowsError(try store.load(url)) { error in
            XCTAssertTrue(error.localizedDescription.contains("UTF-8"), error.localizedDescription)
        }
        // macOS reports temporary paths as either /var or /private/var.
        let unreadable = try store.scanWithDiagnostics(vault).unreadable
            .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        XCTAssertEqual(unreadable, [url.resolvingSymlinksInPath().path])
    }

    // MARK: - Accent-insensitive search and recall

    func testSearchAndRecallMatchAccentsInBothDirections() throws {
        try write("menu.md", "# Menu\nWe visited the café yesterday.\n")
        try write("plain.md", "# Plain\nThe cafe opens at noon.\n")
        try write("other.md", "# Other\nNothing relevant — just prose.\n")

        for query in ["cafe", "café", "CAFÉ", "Cafe"] {
            let titles = Set(try store.search(vault, query: query).map(\.title))
            XCTAssertEqual(titles, ["Menu", "Plain"], "search \(query)")
            let recalled = Set(try store.recall(vault, query: query).map(\.note.title))
            XCTAssertEqual(recalled, ["Menu", "Plain"], "recall \(query)")
        }
        XCTAssertEqual(try store.search(vault, query: "cafe menu", ranked: true).map(\.title), ["Menu"])
    }

    func testAccentedFileNamesMatchPlainQueries() throws {
        try write("Zürich.md", "no body match here\n")
        XCTAssertEqual(try store.search(vault, query: "zurich").count, 1)
        XCTAssertEqual(try store.recall(vault, query: "zurich").count, 1)
    }

    // MARK: - Wiki links

    func testEmptyAndStrayWikiLinksDoNotCrashOrSwallowRealLinks() throws {
        let target = try write("b.md", "# B\n")
        let source = try write("c.md", """
        # C
        empty [[]] and [[|alias only]] and [[#Heading]]
        array[[0] stray bracket
        then [[B|alias]]
        """)
        let links = try store.links(vault, for: source)
        XCTAssertEqual(links.outgoing.map(\.title), ["B"])
        XCTAssertEqual(links.unresolved, [])
        XCTAssertEqual(try store.links(vault, for: target).backlinks.map(\.title), ["C"])
    }

    func testWikiLinkScannerRestartsAtTheInnermostOpening() {
        XCTAssertEqual(MarkdownStore.wikiLinks(in: "a [[x [[Real]] b"), ["Real"])
        XCTAssertEqual(MarkdownStore.wikiLinks(in: "[[One]][[Two#h|t]]"), ["One", "Two"])
        XCTAssertEqual(MarkdownStore.wikiLinks(in: "[[split\nacross]] [[ok]]"), ["ok"])
        XCTAssertEqual(MarkdownStore.wikiLinks(in: "[[ café ]]"), ["café"])
    }

    // MARK: - Native text paths match Foundation

    func testRankingFoldMatchesFoundationFolding() {
        let alphabet: [String] = [
            "a", "Z", "0", " ", "-", "é", "É", "e\u{301}", "\u{301}", "ß", "Å", "ñ", "Ø", "ł",
            "İ", "ı", "Σ", "ς", "Ж", "中", "—", "’", "👍🏽", "\u{212A}", "ﬁ", "Ǆ", "\r\n", "Straße",
        ]
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<20_000 {
            let length = Int.random(in: 0...12, using: &generator)
            let value = (0..<length).map { _ in alphabet.randomElement(using: &generator)! }.joined()
            let expected = value.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            XCTAssertEqual(MarkdownStore.foldedForRanking(value), expected, "fold of \(value.debugDescription)")
        }
        for byte in UInt8(0)..<0x80 {
            let value = String(decoding: [byte], as: UTF8.self)
            XCTAssertEqual(
                MarkdownStore.foldedForRanking(value),
                value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            )
        }
    }

    func testFoldedContainsMatchesFoundationForFoldedText() {
        let haystacks = ["release notes — café", "", "abc", "ab", "the release", "日本 release 中"]
        let needles = ["release", "notes", "caf", "abc", "b", "zz", "日本", "中", "e", "release notes"]
        for haystack in haystacks {
            let folded = MarkdownStore.foldedForRanking(haystack)
            for needle in needles {
                XCTAssertEqual(
                    MarkdownStore.foldedContains(folded, needle),
                    folded.contains(needle),
                    "\(folded) contains \(needle)"
                )
            }
        }
        XCTAssertFalse(MarkdownStore.foldedContains("abc", ""))
    }
}
