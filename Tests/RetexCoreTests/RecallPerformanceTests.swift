import XCTest
@testable import RetexCore

/// The folded byte matcher, recall pruning and the added recall stopwords
/// are performance work: each must give the answers the slower path gives.
final class RecallPerformanceTests: XCTestCase {
    private var vaultDir: URL!

    override func setUpWithError() throws {
        vaultDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-recall-perf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: vaultDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: vaultDir)
    }

    private var vault: Vault { Vault(url: vaultDir) }

    private func write(_ name: String, _ source: String) throws {
        let url = vaultDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try source.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Foundation's case- and diacritic-insensitive search, which the folded
    /// matcher replaces for speed.
    private func reference(_ text: String, filename: String, term: String) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return filename.range(of: term, options: options) != nil || text.range(of: term, options: options) != nil
    }

    func testFoldedMatcherAgreesWithFoundationSearch() {
        let texts = [
            "Die Straße in Zürich. ﬁnance office. İstanbul trip.",
            "We met on the STRASSE near Zurich; FINANCE is closed.",
            "Café niño São Paulo résumé ŒUVRE naïve Ångström",
            "plain ascii text with cafe and nino and resume",
            "Greek: Σίσυφος ὀδύσσεια; Kelvin K; Ω; ﬀ ligature",
            "dashes — and “quotes” and emoji 🚀 only",
            "ǅemal and ǆ, Ĳssel, ŉ, ǰ",
        ]
        let terms = [
            "cafe", "café", "CAFÉ", "nino", "niño", "sao paulo", "São", "resume", "résumé",
            "strasse", "straße", "STRASSE", "ß", "ss", "finance", "ﬁnance", "fi", "istanbul",
            "İstanbul", "i̇stanbul", "oeuvre", "œuvre", "naive", "angstrom", "Ångström",
            "σίσυφος", "σισυφος", "k", "K", "ω", "ff", "ﬀ", "—", "“quotes”", "🚀", "dzemal", "ǆ",
            "ijssel", "Ĳssel", "zurich", "zürich",
        ]
        for (index, text) in texts.enumerated() {
            let note = Note(
                url: URL(fileURLWithPath: "/vault/note-\(index).md"),
                source: text, title: "", body: text, metadata: [:], tags: [], modifiedAt: .distantPast
            )
            for term in terms {
                let expected = reference(text, filename: "note-\(index)", term: term)
                var fromFile = RawNoteText(url: note.url, data: Data(text.utf8))
                XCTAssertEqual(fromFile.contains(term, needle: MarkdownStore.asciiNeedle(for: term)), expected,
                               "file text \(index) term \(term)")
                var fromCache = RawNoteText(note: note)
                XCTAssertEqual(fromCache.contains(term, needle: MarkdownStore.asciiNeedle(for: term)), expected,
                               "cached text \(index) term \(term)")
            }
        }
    }

    func testRecallPruningMatchesFullScoring() throws {
        var generator = SystemRandomNumberGenerator()
        let words = ["deploy", "cloudflare", "lucero", "invoice", "stripe", "release", "rollback", "café", "vault"]
        for index in 0..<400 {
            let picked = (0..<Int.random(in: 1...6, using: &generator)).map { _ in words.randomElement(using: &generator)! }
            let title = Bool.random(using: &generator) ? picked.prefix(2).joined(separator: " ") : "Note \(index)"
            let tag = Bool.random(using: &generator) ? "tags: [\(words.randomElement(using: &generator)!)]\n" : ""
            try write("n\(index % 7)/note-\(index).md", "---\ntype: memory\n\(tag)---\n# \(title)\n\(picked.joined(separator: " filler "))\n")
        }
        let store = MarkdownStore()
        for query in ["deploy cloudflare", "stripe invoice rollback", "cafe", "lucero vault release deploy"] {
            for limit in [1, 3, 20, 1000] {
                let fast = try store.recall(vault, query: query, limit: limit)
                // Full scoring: every match scored completely, then sorted.
                let notes = try store.scan(vault)
                let terms = Array(Set(query.split(separator: " ").map { MarkdownStore.foldedForRanking(String($0)) })).sorted()
                let phrase = MarkdownStore.foldedForRanking(query)
                let full = notes.compactMap { note -> (Note, Int)? in
                    var text = RawNoteText(note: note)
                    let matched = terms.filter { text.contains($0, needle: MarkdownStore.asciiNeedle(for: $0)) }
                    guard !matched.isEmpty else { return nil }
                    let score = MarkdownStore.recallBaseScore(note, phrase: phrase, terms: terms, matched: matched)
                        + MarkdownStore.recallBodyScore(foldedBody: MarkdownStore.foldedForRanking(note.body), phrase: phrase, matched: matched)
                    return (note, score)
                }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : MarkdownStore.precedes($0.0, $1.0) }.prefix(limit)
                XCTAssertEqual(fast.map(\.note.id), full.map(\.0.id), "\(query) limit \(limit)")
                XCTAssertEqual(fast.map(\.score), full.map(\.1), "\(query) limit \(limit)")
            }
        }
    }

    func testRecallIgnoresConversationalFiller() throws {
        try write("deploy.md", "# Deploy\nHow to deploy the site.\n")
        try write("web.md", "# Web\nThe web server and everything between.\n")
        let hits = try MarkdownStore().recall(vault, query: "how should we deploy it")
        XCTAssertEqual(hits.map(\.note.title), ["Deploy"])
        XCTAssertEqual(hits.first?.matchedTerms, ["deploy"])
    }
}
