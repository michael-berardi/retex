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
        let words = ["deploy", "cloudflare", "acme", "invoice", "stripe", "release", "rollback", "café", "vault"]
        for index in 0..<400 {
            let picked = (0..<Int.random(in: 1...6, using: &generator)).map { _ in words.randomElement(using: &generator)! }
            let title = Bool.random(using: &generator) ? picked.prefix(2).joined(separator: " ") : "Note \(index)"
            let tag = Bool.random(using: &generator) ? "tags: [\(words.randomElement(using: &generator)!)]\n" : ""
            try write("n\(index % 7)/note-\(index).md", "---\ntype: memory\n\(tag)---\n# \(title)\n\(picked.joined(separator: " filler "))\n")
        }
        let store = MarkdownStore()
        for query in ["deploy cloudflare", "stripe invoice rollback", "cafe", "acme vault release deploy"] {
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

    // MARK: - Ranked search pruning

    func testRankedSearchPruningMatchesFullScoring() throws {
        var generator = SystemRandomNumberGenerator()
        let words = ["deploy", "acme", "invoice", "release", "rollback", "café", "vault", "runbook"]
        for index in 0..<120 {
            let picked = (0..<Int.random(in: 1...5, using: &generator)).map { _ in words.randomElement(using: &generator)! }
            let title = Bool.random(using: &generator) ? picked.prefix(2).joined(separator: " ") : "Note \(index)"
            let tag = Bool.random(using: &generator) ? "tags: [\(words.randomElement(using: &generator)!)]\n" : ""
            try write(
                "f\(index % 5)/note-\(index).md",
                "---\ntype: memory\n\(tag)---\n# \(title)\n\(picked.joined(separator: " filler "))\n"
            )
        }
        let store = MarkdownStore()
        let notes = try store.scan(vault)

        for query in ["deploy acme", "invoice release rollback", "vault", "cafe runbook"] {
            let rawTerms = query.split(whereSeparator: \.isWhitespace).map(String.init)
            let phrases = MarkdownStore.foldedForRanking(query)
            let terms = rawTerms.map(MarkdownStore.foldedForRanking)
            // Full scoring: score every matching note completely, then sort.
            let fullyScored = notes.compactMap { note -> (note: Note, score: Int)? in
                var text = RawNoteText(note: note)
                let matchesAll = rawTerms.allSatisfy {
                    text.contains($0, needle: MarkdownStore.asciiNeedle(for: $0))
                }
                guard matchesAll else { return nil }
                return (note, MarkdownStore.relevanceScore(note, phrase: phrases, terms: terms))
            }.sorted { left, right in
                left.score != right.score ? left.score > right.score : MarkdownStore.precedes(left.note, right.note)
            }

            for limit in [1, 3, 20, 1000] {
                let pruned = try store.search(vault, query: query, ranked: true, limit: limit)
                let expected = fullyScored.prefix(limit)
                XCTAssertEqual(pruned.map(\.id), expected.map(\.note.id), "\(query) limit \(limit)")
                XCTAssertEqual(
                    pruned.map { MarkdownStore.relevanceScore($0, phrase: phrases, terms: terms) },
                    expected.map(\.score),
                    "\(query) limit \(limit) scores"
                )
            }
            // An uncapped search scores and sorts every hit at once.
            let unbounded = try store.search(vault, query: query, ranked: true, limit: nil)
            XCTAssertEqual(unbounded.map(\.id), fullyScored.map(\.note.id), "\(query) unbounded")
        }
    }

    func testRankedInsertionIsBoundedWorkAndKeepsTheResultOrder() {
        // A capped search inserts into a list of at most `limit` entries; a
        // linear scan per candidate would be quadratic in the candidate count
        // and would still return the same notes, so only the comparison count
        // distinguishes the two.
        var generator = SystemRandomNumberGenerator()
        let scored = (0..<2000).map { index -> (note: Note, score: Int) in
            let note = Note(
                url: URL(fileURLWithPath: "/vault/note-\(index).md"),
                source: "# Note \(index)\n",
                title: "Note \(index)",
                body: "body \(index)",
                metadata: [:],
                tags: [],
                modifiedAt: Date(timeIntervalSince1970: TimeInterval(index % 97))
            )
            return (note, Int.random(in: 0...20, using: &generator))
        }
        let reference = MarkdownStore.sortedRanked(scored)

        var comparisons = 0
        var best: [(note: Note, score: Int)] = []
        for entry in scored {
            MarkdownStore.insertRanked(entry, into: &best, limit: 10) { leftNote, leftScore, rightNote, rightScore in
                comparisons += 1
                return MarkdownStore.ranksBeforeScores(leftNote, leftScore, rightNote, rightScore)
            }
            XCTAssertLessThanOrEqual(best.count, 10)
        }
        XCTAssertEqual(best.map(\.note.id), reference.prefix(10).map(\.note.id))
        XCTAssertLessThan(comparisons, scored.count * 12, "insertion did too much work")

        // The uncapped path sorts every scored note, which must agree with the
        // sorted reference exactly.
        XCTAssertEqual(MarkdownStore.sortedRanked(scored).map(\.note.id), reference.map(\.note.id))
    }

    // MARK: - New foldable ranges

    func testFoldedMatcherAgreesWithFoundationForSmallCapitalsAndExtendedC() {
        // U+1D00-U+1D7F phonetic small capitals fold to ASCII letters, and
        // U+2C60-U+2C7F Latin Extended-C folds within its own block. Both
        // ranges must count as "may fold to ASCII", or the byte matcher could
        // answer false for text Foundation would match.
        let texts = [
            "\u{1D00} \u{1D18}\u{029F}\u{1D00}\u{0274}: a plan for release",
            "small capitals: \u{1D05}\u{1D07}\u{1D18}\u{1D0F}\u{1D22} deploy",
            "latin extended-c: \u{2C60}\u{2C61}\u{2C6F}\u{2C71} release",
            "mixed \u{1D20}\u{1D00}\u{1D1C}\u{029F}\u{1D1B} and PLAN",
        ]
        let terms = ["plan", "release", "deploy", "vault", "\u{1D00}", "\u{2C60}"]
        for (index, text) in texts.enumerated() {
            XCTAssertTrue(
                MarkdownStore.mayFoldToASCII(Data(text.utf8)),
                "text \(index) has characters that may fold to ASCII"
            )
            let note = Note(
                url: URL(fileURLWithPath: "/vault/small-\(index).md"),
                source: text, title: "", body: text, metadata: [:], tags: [], modifiedAt: .distantPast
            )
            let filename = "small-\(index)"
            for term in terms {
                let expected = reference(text, filename: filename, term: term)
                var fromFile = RawNoteText(url: note.url, data: Data(text.utf8))
                XCTAssertEqual(
                    fromFile.contains(term, needle: MarkdownStore.asciiNeedle(for: term)),
                    expected,
                    "text \(index) term \(term)"
                )
                var fromCache = RawNoteText(note: note)
                XCTAssertEqual(
                    fromCache.contains(term, needle: MarkdownStore.asciiNeedle(for: term)),
                    expected,
                    "cached text \(index) term \(term)"
                )
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
