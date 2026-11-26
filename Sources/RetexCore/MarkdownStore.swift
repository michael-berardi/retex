#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

/// @unchecked Sendable wrapper: contents are confined to one concurrent
/// region at a time by construction (distinct indexed slots never alias).
private final class SendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

struct ASCIINeedle: Sendable {
    let bytes: [UInt8]
    let shifts: [Int]

    init(_ bytes: [UInt8]) {
        self.bytes = bytes.map { byte in
            byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte
        }
        var shifts = [Int](repeating: max(bytes.count, 1), count: 256)
        if bytes.count > 1 {
            for index in 0..<(bytes.count - 1) {
                shifts[Int(self.bytes[index])] = bytes.count - 1 - index
            }
        }
        self.shifts = shifts
    }
}

/// One candidate file for raw-byte term matching. Terms match the file name
/// or note text case- and diacritic-insensitively. Built from file bytes on
/// a scan, or from an already decoded note held by a snapshot cache.
struct RawNoteText: @unchecked Sendable {
    /// File bytes; nil when the text came from a cached note.
    private let data: Data?
    let filename: String
    let filenameData: Data
    private var decodedState: String??
    private var foldableState: Bool?
    private var foldedFilename: String?
    private var expandingState: Bool?
    private var foldedText: String?

    init(url: URL, data: Data) {
        self.data = data
        filename = url.deletingPathExtension().lastPathComponent
        filenameData = Data(filename.utf8)
    }

    /// Text of a parsed note with every per-note fact computed up front, so
    /// a cached copy answers any number of queries without recomputing them.
    init(note: Note) {
        data = nil
        filename = note.url.deletingPathExtension().lastPathComponent
        filenameData = Data(filename.utf8)
        decodedState = .some(note.source)
        var source = note.source
        foldableState = source.withUTF8(MarkdownStore.mayFoldToASCII)
        expandingState = MarkdownStore.hasExpandingCaseFold(filename)
            || MarkdownStore.hasExpandingCaseFold(note.source)
        foldedFilename = MarkdownStore.foldedForRanking(filename)
        if foldableState == true || MarkdownStore.mayFoldToASCII(filenameData), expandingState == false {
            foldedText = MarkdownStore.foldedForRanking(note.source)
        }
    }

    /// Strictly decoded note text, computed at most once.
    var decoded: String? {
        mutating get {
            if let decodedState { return decodedState }
            let value = data.flatMap(MarkdownStore.decodeUTF8)
            decodedState = .some(value)
            return value
        }
    }

    private mutating func textContainsASCII(_ needle: ASCIINeedle) -> Bool {
        if let data { return MarkdownStore.containsASCIIInsensitive(data, needle: needle) }
        guard var text = decoded else { return false }
        return text.withUTF8 { MarkdownStore.containsASCIIInsensitive($0, needle: needle) }
    }

    mutating func contains(_ term: String, needle: ASCIINeedle?) -> Bool {
        if let needle {
            if MarkdownStore.containsASCIIInsensitive(filenameData, needle: needle)
                || textContainsASCII(needle) {
                return true
            }
            // Accented Latin letters fold to ASCII ("café" matches "cafe").
            // Only text containing such letters pays for Unicode comparison.
            let filenameFolds = MarkdownStore.mayFoldToASCII(filenameData)
            if foldableState == nil { foldableState = data.map(MarkdownStore.mayFoldToASCII) ?? false }
            guard filenameFolds || foldableState == true else { return false }
        }
        // Letters whose case folding expands ("ß" matches "ss", "ﬁ" matches
        // "fi") break a per-character fold, so they keep Foundation's search.
        if expandingState == nil {
            expandingState = MarkdownStore.hasExpandingCaseFold(filename)
                || decoded.map(MarkdownStore.hasExpandingCaseFold) ?? false
        }
        if expandingState == true || MarkdownStore.hasExpandingCaseFold(term) {
            let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
            return filename.range(of: term, options: options) != nil
                || decoded?.range(of: term, options: options) != nil
        }
        // Otherwise fold the text once and byte-search the folded term:
        // repeated diacritic-insensitive `range(of:)` over whole notes
        // dominated recall on vaults with accented text.
        let foldedTerm = MarkdownStore.foldedForRanking(term)
        if foldedFilename == nil { foldedFilename = MarkdownStore.foldedForRanking(filename) }
        if MarkdownStore.foldedContains(foldedFilename!, foldedTerm) { return true }
        if let foldedText { return MarkdownStore.foldedContains(foldedText, foldedTerm) }
        let folded = decoded.map(MarkdownStore.foldedForRanking) ?? ""
        if data != nil { foldedText = folded }
        return MarkdownStore.foldedContains(folded, foldedTerm)
    }
}

public struct MarkdownStore {
    private let fileManager = FileManager.default
    let history = UndoHistory()
    /// In-memory snapshots for long-running processes; nil reads the files
    /// on every call (the CLI).
    public let cache: VaultSnapshotCache?

    public init(cache: VaultSnapshotCache? = nil) {
        self.cache = cache
    }

    public func scan(_ vault: Vault) throws -> [Note] {
        try scanWithDiagnostics(vault).notes
    }

    /// Search raw Markdown first, then parse only matching notes. Exact mode
    /// preserves the stable phrase-search contract. Ranked mode matches every
    /// whitespace-delimited term and sorts title/path/property hits before body
    /// hits for bounded agent retrieval.
    public func search(
        _ vault: Vault,
        query: String,
        ranked: Bool = false,
        limit: Int? = nil
    ) throws -> [Note] {
        let normalizedQuery = query.trimmingCharacters(in: Self.whitespaceAndNewlineCharacters)
        guard !normalizedQuery.isEmpty else { throw StoreError.invalidQuery }
        if let limit, limit <= 0 { throw StoreError.invalidLimit }

        let terms = ranked
            ? normalizedQuery.split(whereSeparator: \.isWhitespace).map(String.init)
            : [normalizedQuery]
        let asciiNeedles = terms.map(Self.asciiNeedle)
        if let cache {
            let entries = try cache.snapshot(vault).entries
            let found = Self.parallelCompactMap(entries) { entry -> Note? in
                var text = entry.text
                return terms.indices.allSatisfy({ text.contains(terms[$0], needle: asciiNeedles[$0]) }) ? entry.note : nil
            }
            return Self.orderSearch(found, query: normalizedQuery, terms: terms, ranked: ranked, limit: limit)
        }

        let root = vault.url.standardizedFileURL
        let files = try Self.enumerateMarkdownPaths(under: root).map { URL(fileURLWithPath: $0, isDirectory: false) }
        var matches = [Note?](repeating: nil, count: files.count)
        matches.withUnsafeMutableBufferPointer { matchesBuffer in
            let selfBox = SendableBox(self)
            let matchesBox = SendableBox(matchesBuffer)
            @Sendable func inspect(_ index: Int) {
                let url = files[index]
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return }
                var text = RawNoteText(url: url, data: data)
                for (termIndex, term) in terms.enumerated()
                where !text.contains(term, needle: asciiNeedles[termIndex]) {
                    return
                }

                guard let source = text.decoded else { return }
                matchesBox.value[index] = try? selfBox.value.note(from: source, at: url)
            }

            if files.count < 500 {
                for index in files.indices { inspect(index) }
            } else {
                let chunkSize = 64
                let chunkCount = (files.count + chunkSize - 1) / chunkSize
                DispatchQueue.concurrentPerform(iterations: chunkCount) { chunk in
                    for index in (chunk * chunkSize)..<min((chunk + 1) * chunkSize, files.count) {
                        inspect(index)
                    }
                }
            }
        }

        return Self.orderSearch(matches.compacted(), query: normalizedQuery, terms: terms, ranked: ranked, limit: limit)
    }

    private static func orderSearch(
        _ found: [Note],
        query normalizedQuery: String,
        terms: [String],
        ranked: Bool,
        limit: Int?
    ) -> [Note] {
        guard ranked else {
            let sorted = found.sorted(by: Self.precedes)
            return limit.map { Array(sorted.prefix($0)) } ?? sorted
        }
        let phrase = Self.foldedForRanking(normalizedQuery)
        let foldedTerms = terms.map(Self.foldedForRanking)
        let bodyBound = Self.searchBodyBound(terms: foldedTerms)
        // Visit candidates by the best score they could still reach; once a
        // bound falls below the current last place, no remaining note can
        // enter the results and its body is never folded. The result equals
        // scoring every candidate fully and sorting.
        let ordered = found.map { note in
            (note: note, base: Self.searchBaseScore(note, phrase: phrase, terms: foldedTerms))
        }.sorted { left, right in
            let leftBound = left.base + bodyBound
            let rightBound = right.base + bodyBound
            if leftBound != rightBound { return leftBound > rightBound }
            return Self.precedes(left.note, right.note)
        }
        var best: [(note: Note, score: Int)] = []
        func ranksBefore(_ a: (note: Note, score: Int), _ b: (note: Note, score: Int)) -> Bool {
            a.score != b.score ? a.score > b.score : Self.precedes(a.note, b.note)
        }
        for partial in ordered {
            if let limit, best.count >= limit, partial.base + bodyBound < best[limit - 1].score { break }
            let score = partial.base
                + Self.searchBodyScore(foldedBody: Self.foldedForRanking(partial.note.body), terms: foldedTerms)
            let entry = (note: partial.note, score: score)
            let position = best.firstIndex { ranksBefore(entry, $0) } ?? best.count
            best.insert(entry, at: position)
            if let limit, best.count > limit { best.removeLast() }
        }
        return best.map(\.note)
    }

    /// Agent-oriented retrieval. Unlike exact and ranked search, recall drops
    /// common conversational filler, accepts any distinctive term, returns
    /// evidence excerpts, and supports arbitrary record metadata filters.
    public func recall(
        _ vault: Vault,
        query: String,
        type: String? = nil,
        status: String? = nil,
        tag: String? = nil,
        metadata: [String: String] = [:],
        onOrBefore: [String: String] = [:],
        onOrAfter: [String: String] = [:],
        includeArchived: Bool = false,
        limit: Int = 20,
        subdirectory: String? = nil
    ) throws -> [RecallHit] {
        let normalizedQuery = query.trimmingCharacters(in: Self.whitespaceAndNewlineCharacters)
        guard !normalizedQuery.isEmpty else { throw StoreError.invalidQuery }
        guard limit > 0 else { throw StoreError.invalidLimit }
        try Self.validateDateFilters(onOrBefore)
        try Self.validateDateFilters(onOrAfter)

        let terms = Self.recallTerms(normalizedQuery)
        let phrase = Self.foldedForRanking(normalizedQuery)
        let root = vault.url.standardizedFileURL
        let scope = Self.recallScope(subdirectory, root: root)
        guard let scopeRoot = scope.directory else { return [] }
        if let cache {
            let asciiNeedles = terms.map(Self.asciiNeedle)
            let entries = try cache.snapshot(vault).entries
            let scoped: [VaultSnapshotCache.Entry]
            if let prefix = scope.prefix {
                scoped = entries.filter { $0.note.id.hasPrefix(prefix) }
            } else {
                scoped = entries
            }
            let partials = Self.parallelCompactMap(scoped) { entry -> RecallPartial? in
                let note = entry.note
                guard includeArchived || !note.isArchived,
                      Self.matches(note, type: type, status: status, tag: tag, metadata: metadata,
                                   onOrBefore: onOrBefore, onOrAfter: onOrAfter)
                else { return nil }
                var text = entry.text
                let matched = terms.indices.filter { text.contains(terms[$0], needle: asciiNeedles[$0]) }.map { terms[$0] }
                guard !matched.isEmpty else { return nil }
                return RecallPartial(
                    note: note,
                    matched: matched,
                    base: Self.recallBaseScore(note, phrase: phrase, terms: terms, matched: matched)
                )
            }
            return Self.rankRecall(partials, phrase: phrase, limit: limit)
        }
        let files = try Self.enumerateMarkdownPaths(under: scopeRoot).map { URL(fileURLWithPath: $0, isDirectory: false) }
        let asciiNeedles = terms.map(Self.asciiNeedle)
        var hits = [RecallPartial?](repeating: nil, count: files.count)
        hits.withUnsafeMutableBufferPointer { buffer in
            let selfBox = SendableBox(self)
            let hitsBox = SendableBox(buffer)
            @Sendable func inspect(_ index: Int) {
                let url = files[index]
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return }
                var text = RawNoteText(url: url, data: data)
                let matched = terms.indices.filter { termIndex in
                    text.contains(terms[termIndex], needle: asciiNeedles[termIndex])
                }.map { terms[$0] }
                guard !matched.isEmpty,
                      let source = text.decoded,
                      let note = try? selfBox.value.note(from: source, at: url),
                      (includeArchived || !note.isArchived),
                      Self.matches(
                          note,
                          type: type,
                          status: status,
                          tag: tag,
                          metadata: metadata,
                          onOrBefore: onOrBefore,
                          onOrAfter: onOrAfter
                      )
                else { return }
                hitsBox.value[index] = RecallPartial(
                    note: note,
                    matched: matched,
                    base: Self.recallBaseScore(note, phrase: phrase, terms: terms, matched: matched)
                )
            }

            if files.count < 500 {
                for index in files.indices { inspect(index) }
            } else {
                let chunkSize = 64
                let chunkCount = (files.count + chunkSize - 1) / chunkSize
                DispatchQueue.concurrentPerform(iterations: chunkCount) { chunk in
                    for index in (chunk * chunkSize)..<min((chunk + 1) * chunkSize, files.count) {
                        inspect(index)
                    }
                }
            }
        }
        return Self.rankRecall(hits.compactMap { $0 }, phrase: phrase, limit: limit)
    }

    /// Resolves `[[wiki links]]` without depending on an editor or plugin.
    /// Markdown remains authoritative; this graph is derived on read.
    public func links(_ vault: Vault, for url: URL) throws -> NoteLinks {
        let target = try load(url)
        if let cache {
            // Snapshot entries carry their link keys and outgoing link
            // lookups, so the graph is not re-parsed per call.
            let entries = try cache.snapshot(vault).entries
            var index: [String: [Note]] = [:]
            for entry in entries {
                for key in entry.linkKeys { index[key, default: []].append(entry.note) }
            }
            var outgoing: [Note] = []
            var outgoingIDs: Set<String> = []
            var unresolved: Set<String> = []
            for rawLink in Self.wikiLinks(in: target.source) {
                let candidates = Self.lookupKeys(rawLink).flatMap { index[$0] ?? [] }
                if candidates.isEmpty { unresolved.insert(rawLink) }
                for note in candidates where note.id != target.id && outgoingIDs.insert(note.id).inserted {
                    outgoing.append(note)
                }
            }
            let targetKeys = Self.linkKeys(target, root: vault.url)
            let backlinks = entries.filter { entry in
                entry.note.id != target.id && !entry.outgoingLookupKeys.isDisjoint(with: targetKeys)
            }.map(\.note)
            return NoteLinks(
                outgoing: outgoing.sorted(by: Self.precedes),
                backlinks: backlinks.sorted(by: Self.precedes),
                unresolved: unresolved.sorted()
            )
        }
        let notes = try scan(vault)
        var index: [String: [Note]] = [:]
        for note in notes {
            for key in Self.linkKeys(note, root: vault.url) {
                index[key, default: []].append(note)
            }
        }

        var outgoing: [Note] = []
        var outgoingIDs: Set<String> = []
        var unresolved: Set<String> = []
        for rawLink in Self.wikiLinks(in: target.source) {
            let candidates = Self.lookupKeys(rawLink).flatMap { index[$0] ?? [] }
            if candidates.isEmpty {
                unresolved.insert(rawLink)
            }
            for note in candidates where note.id != target.id && outgoingIDs.insert(note.id).inserted {
                outgoing.append(note)
            }
        }

        let targetKeys = Self.linkKeys(target, root: vault.url)
        // Backlink scanning is pure per note, so a large vault splits it
        // across cores; slot order keeps the result deterministic.
        let backlinks = Self.parallelCollect(notes) { note -> Note? in
            guard note.id != target.id else { return nil }
            let linksToTarget = Self.wikiLinks(in: note.source).contains { rawLink in
                Self.lookupKeys(rawLink).contains(where: targetKeys.contains)
            }
            return linksToTarget ? note : nil
        }
        return NoteLinks(
            outgoing: outgoing.sorted(by: Self.precedes),
            backlinks: backlinks.sorted(by: Self.precedes),
            unresolved: unresolved.sorted()
        )
    }

    public static func matches(
        _ note: Note,
        type: String? = nil,
        status: String? = nil,
        tag: String? = nil,
        metadata: [String: String] = [:],
        onOrBefore: [String: String] = [:],
        onOrAfter: [String: String] = [:]
    ) -> Bool {
        if let type, note.recordType.caseInsensitiveCompare(type) != .orderedSame { return false }
        if let status, note.status.caseInsensitiveCompare(status) != .orderedSame { return false }
        if let tag, !note.tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
            return false
        }
        guard metadata.allSatisfy({ key, expected in
            note.metadata[key]?.caseInsensitiveCompare(expected) == .orderedSame
        }) else { return false }
        guard onOrBefore.allSatisfy({ key, bound in
            guard let value = note.metadata[key],
                  let valueDay = isoDay(value),
                  let boundDay = isoDay(bound)
            else { return false }
            return valueDay <= boundDay
        }) else { return false }
        return onOrAfter.allSatisfy { key, bound in
            guard let value = note.metadata[key],
                  let valueDay = isoDay(value),
                  let boundDay = isoDay(bound)
            else { return false }
            return valueDay >= boundDay
        }
    }

    public static func validateDateFilters(_ filters: [String: String]) throws {
        for (key, value) in filters where isoDay(value) == nil {
            throw StoreError.invalidDateFilter(key, value)
        }
    }

    /// Resolves an optional recall subdirectory to the directory that gets
    /// enumerated and the canonical prefix snapshot entries are filtered by.
    /// `directory` is nil when the requested subdirectory is missing or
    /// escapes the vault, which means an empty result.
    static func recallScope(
        _ subdirectory: String?,
        root: URL
    ) -> (directory: URL?, prefix: String?) {
        guard let subdirectory else { return (root, nil) }
        let expanded = NSString(string: subdirectory).expandingTildeInPath
        guard !(expanded as NSString).isAbsolutePath else { return (nil, nil) }
        let candidate = root.appendingPathComponent(expanded).standardizedFileURL
        guard isWithinVault(candidate, root: root) else { return (nil, nil) }
        let path = candidate.path
        let prefix = path.hasSuffix("/") ? path : path + "/"
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return (nil, prefix) }
        return (candidate, prefix)
    }

    private static func isoDay(_ value: String) -> Int? {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              (1...9999).contains(year),
              (1...12).contains(month)
        else { return nil }
        let leap = year.isMultiple(of: 400) || (year.isMultiple(of: 4) && !year.isMultiple(of: 100))
        let monthDays = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...monthDays[month - 1]).contains(day) else { return nil }
        return year * 10_000 + month * 100 + day
    }

    private static func recallTerms(_ query: String) -> [String] {
        let words = query.unicodeScalars.split { !CharacterSet.alphanumerics.contains($0) }
            .map { foldedForRanking(String($0)) }
            .filter { !$0.isEmpty }
        let distinctive = words.filter { $0.count > 1 && !recallStopwords.contains($0) }
        return Array(Set(distinctive.isEmpty ? words : distinctive)).sorted()
    }

    /// Recall score without the body terms. The body is the only field large
    /// enough to make folding expensive, so ranking scores it last and only
    /// for notes that can still reach the top results.
    static func recallBaseScore(
        _ note: Note,
        phrase: String,
        terms: [String],
        matched: [String]
    ) -> Int {
        let title = foldedForRanking(note.title)
        let filename = foldedForRanking(note.url.deletingPathExtension().lastPathComponent)
        let path = foldedForRanking(note.url.path)
        let tags = note.tags.map(foldedForRanking)
        let metadata = note.metadata.map { (foldedForRanking($0.key), foldedForRanking($0.value)) }
        var score = matched.count * 1_000

        if matched.count == terms.count { score += 2_000 }
        if title == phrase { score += 10_000 }
        else if Self.foldedContains(title, phrase) { score += 4_000 }
        for term in matched {
            if Self.foldedContains(title, term) { score += 700 }
            if Self.foldedContains(filename, term) { score += 400 }
            if tags.contains(where: { Self.foldedContains($0, term) }) { score += 300 }
            if metadata.contains(where: { Self.foldedContains($0.0, term) || Self.foldedContains($0.1, term) }) { score += 220 }
            if Self.foldedContains(path, term) { score += 80 }
        }
        return score
    }

    /// Body share of the recall score, from an already folded body.
    static func recallBodyScore(foldedBody body: String, phrase: String, matched: [String]) -> Int {
        var score = Self.foldedContains(body, phrase) ? 800 : 0
        for term in matched where Self.foldedContains(body, term) { score += 30 }
        return score
    }

    /// Highest score `recallBodyScore` can add.
    static func recallBodyBound(matched: [String]) -> Int { 800 + 30 * matched.count }

    struct RecallPartial: Sendable {
        let note: Note
        let matched: [String]
        let base: Int
    }

    /// Exact top-`limit` recall ranking. Candidates are visited by their best
    /// possible score; once that bound falls below the current last place no
    /// remaining note can enter the results, so their bodies are never folded.
    /// The result equals scoring every candidate fully, then sorting.
    static func rankRecall(_ partials: [RecallPartial], phrase: String, limit: Int) -> [RecallHit] {
        let ordered = partials.sorted { left, right in
            let l = left.base + recallBodyBound(matched: left.matched)
            let r = right.base + recallBodyBound(matched: right.matched)
            if l != r { return l > r }
            return precedes(left.note, right.note)
        }
        var best: [(note: Note, score: Int, matched: [String])] = []
        func ranksBefore(_ a: (note: Note, score: Int, matched: [String]), _ b: (note: Note, score: Int, matched: [String])) -> Bool {
            a.score != b.score ? a.score > b.score : precedes(a.note, b.note)
        }
        for partial in ordered {
            let bound = partial.base + recallBodyBound(matched: partial.matched)
            if best.count >= limit, bound < best[limit - 1].score { break }
            let body = foldedForRanking(partial.note.body)
            let entry = (
                note: partial.note,
                score: partial.base + recallBodyScore(foldedBody: body, phrase: phrase, matched: partial.matched),
                matched: partial.matched
            )
            let position = best.firstIndex { ranksBefore(entry, $0) } ?? best.count
            best.insert(entry, at: position)
            if best.count > limit { best.removeLast() }
        }
        return best.map { entry in
            RecallHit(
                note: entry.note,
                score: entry.score,
                matchedTerms: entry.matched,
                excerpt: Self.evidenceExcerpt(entry.note.body, terms: entry.matched)
            )
        }
    }

    /// Best-evidence excerpt: the first line carrying the most matched terms,
    /// with one line of context on either side. Lines stay `Substring`s (a
    /// body can be megabytes of lines) and a term that cannot occur anywhere
    /// in the body is dropped up front instead of being searched per line.
    private static func evidenceExcerpt(_ body: String, terms: [String]) -> String {
        let scoringTerms = Self.termsPresentSomewhere(in: body, terms: terms)
        var lines: [Substring] = []
        Self.forEachLine(in: body[...]) { line, _ in
            lines.append(line)
            return true
        }
        guard !lines.isEmpty else { return "" }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        // First line with the most matched terms; each line is scored once.
        var best = 0
        var bestScore = -1
        for index in lines.indices {
            var score = 0
            for term in scoringTerms where lines[index].range(of: term, options: options) != nil {
                score += 1
            }
            if score > bestScore {
                best = index
                bestScore = score
                if score == scoringTerms.count { break }
            }
        }
        let lower = max(lines.startIndex, best - 1)
        let upper = min(lines.index(before: lines.endIndex), best + 1)
        let excerpt = lines[lower...upper].joined(separator: "\n")
        let trimmed = Self.trimmed(excerpt, in: Self.whitespaceAndNewlineCharacters)
        return String(trimmed.prefix(600))
    }

    /// Terms that can still match a line of `body`. An ASCII term whose bytes
    /// are absent, in a body with nothing that folds to ASCII, cannot match
    /// any line, so searching every line for it is wasted work.
    private static func termsPresentSomewhere(in body: String, terms: [String]) -> [String] {
        var body = body
        return body.withUTF8 { bytes in
            let folds = Self.mayFoldToASCII(bytes)
            return terms.filter { term in
                guard !folds, let needle = Self.asciiNeedle(for: term) else { return true }
                return Self.containsASCIIInsensitive(bytes, needle: needle)
            }
        }
    }

    /// `[[target]]`, `[[target|alias]]`, and `[[target#heading]]` links. A
    /// link cannot span lines, and a later `[[` restarts the link, so a stray
    /// bracket in prose or code cannot swallow the real links that follow.
    /// An escaped opener (`\[[target]]` with an odd run of backslashes) is
    /// text, not a link.
    static func wikiLinks(in body: String) -> [String] {
        let utf8 = body.utf8
        guard Self.containsWikiLinkOpener(utf8) else { return [] }
        var links: [String] = []
        var open: String.Index?
        var backslashes = 0
        var index = utf8.startIndex
        while index != utf8.endIndex {
            let byte = utf8[index]
            let next = utf8.index(after: index)
            if byte == UInt8(ascii: "\\") {
                backslashes += 1
                index = next
                continue
            }
            if byte == 0x0A {
                open = nil
            } else if next != utf8.endIndex, byte == UInt8(ascii: "["), utf8[next] == UInt8(ascii: "[") {
                if backslashes % 2 == 1 {
                    // Escaped: keep looking after the brackets.
                    open = nil
                    backslashes = 0
                    index = utf8.index(after: next)
                    continue
                }
                open = utf8.index(after: next)
                backslashes = 0
                index = open!
                continue
            } else if let start = open, next != utf8.endIndex,
                      byte == UInt8(ascii: "]"), utf8[next] == UInt8(ascii: "]") {
                let value = Substring(utf8[start..<index])
                    .split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)[0]
                    .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                let trimmed = Self.trimmed(value, in: Self.whitespaceAndNewlineCharacters)
                if !trimmed.isEmpty { links.append(trimmed) }
                open = nil
                backslashes = 0
                index = utf8.index(after: next)
                continue
            }
            backslashes = 0
            index = next
        }
        return links
    }

    /// Whether the text contains a `[[` byte pair at all. Most notes carry no
    /// wiki links, and this rejects them without collecting links.
    private static func containsWikiLinkOpener<Bytes: Collection>(_ utf8: Bytes) -> Bool where Bytes.Element == UInt8 {
        var index = utf8.startIndex
        var previousWasBracket = false
        while index != utf8.endIndex {
            let isBracket = utf8[index] == UInt8(ascii: "[")
            if isBracket, previousWasBracket { return true }
            previousWasBracket = isBracket
            index = utf8.index(after: index)
        }
        return false
    }

    static func linkKeys(_ note: Note, root: URL) -> Set<String> {
        let rootComponents = root.standardizedFileURL.pathComponents.count
        let relative = note.url.deletingPathExtension().pathComponents
            .dropFirst(rootComponents)
            .joined(separator: "/")
        return Set([
            normalizedLink(note.title),
            normalizedLink(note.url.deletingPathExtension().lastPathComponent),
            normalizedLink(relative),
        ])
    }

    static func lookupKeys(_ rawLink: String) -> [String] {
        let normalized = normalizedLink(rawLink)
        let filename = normalizedLink((rawLink as NSString).lastPathComponent)
        return normalized == filename ? [normalized] : [normalized, filename]
    }

    private static func normalizedLink(_ value: String) -> String {
        foldedForRanking(value.trimmingCharacters(in: Self.whitespaceAndNewlineCharacters))
    }

    /// Conversational filler dropped from recall questions. Terms match as
    /// substrings, so a kept filler word ("we" in "web", "between") matches
    /// most of a vault and buries the distinctive terms.
    private static let recallStopwords: Set<String> = [
        "a", "about", "all", "also", "am", "an", "and", "any", "are", "as",
        "at", "be", "been", "being", "but", "by", "can", "could", "did", "do",
        "does", "for", "from", "had", "has", "have", "he", "her", "here", "his",
        "how", "i", "if", "in", "into", "is", "it", "its", "just", "may", "me",
        "might", "must", "my", "of", "on", "or", "our", "please", "shall", "she",
        "should", "so", "than", "that", "the", "their", "them", "then", "there",
        "these", "they", "this", "those", "to", "us", "was", "we", "were", "what",
        "when", "where", "which", "who", "why", "will", "with", "would", "you",
        "your",
    ]

    static func foldASCII(_ byte: UInt8) -> UInt8 {
        byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte
    }

    /// Whether UTF-8 bytes contain a character that may fold to ASCII under
    /// case- and diacritic-insensitive comparison: Latin-1 Supplement and
    /// Latin Extended letters, combining diacritics, Latin Extended
    /// Additional, phonetic extensions and small capitals, Latin Extended-C/D,
    /// letterlike symbols such as the Kelvin sign, and the Latin ligatures
    /// ("ﬀ" matches "ff").
    static func mayFoldToASCII(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw in mayFoldToASCII(raw.bindMemory(to: UInt8.self)) }
    }

    static func mayFoldToASCII(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        do {
            var index = 0
            while index < bytes.count {
                let byte = bytes[index]
                if byte >= 0xC3 && byte <= 0xC9 || byte == 0xCC || byte == 0xCD { return true }
                if byte == 0xE1 || byte == 0xE2 || byte == 0xEF, index + 1 < bytes.count {
                    let next = bytes[index + 1]
                    // U+1E00-U+1EFF Latin Extended Additional (E1 B8-BB),
                    // U+1D00-U+1D7F phonetic extensions and small capitals
                    // (E1 B4-B5), U+2100-U+214F letterlike symbols (E2 84),
                    // U+2C60-U+2C7F Latin Extended-C (E2 B1-B2), and the
                    // U+FB00-U+FB4F ligatures (EF AC).
                    if byte == 0xE1 && (next >= 0xB4 && next <= 0xB5 || next >= 0xB8 && next <= 0xBB)
                        || byte == 0xE2 && (next == 0x84 || next >= 0xB1 && next <= 0xB2)
                        || byte == 0xEF && next == 0xAC {
                        return true
                    }
                }
                index += 1
            }
            return false
        }
    }

    /// Byte needle for a search term. A non-ASCII term whose folding is pure
    /// ASCII ("café" -> "cafe") searches the folded form: in text with no
    /// characters that fold to ASCII, the two match exactly the same bytes.
    static func asciiNeedle(for term: String) -> ASCIINeedle? {
        if term.utf8.allSatisfy({ $0 < 0x80 }) { return ASCIINeedle(Array(term.utf8)) }
        guard !hasExpandingCaseFold(term) else { return nil }
        let folded = foldedForRanking(term)
        guard !folded.isEmpty, folded.utf8.allSatisfy({ $0 < 0x80 }) else { return nil }
        return ASCIINeedle(Array(folded.utf8))
    }

    /// Whether the text contains a character with a multi-character Unicode
    /// case folding (CaseFolding.txt status F): "ß", "İ", Greek letters with
    /// iota subscript, Armenian "և", and the Latin and Armenian ligatures.
    static func hasExpandingCaseFold(_ text: String) -> Bool {
        for scalar in text.unicodeScalars where scalar.value >= 0xDF {
            switch scalar.value {
            case 0xDF, 0x130, 0x149, 0x1F0, 0x390, 0x3B0, 0x587,
                 0x1E96...0x1E9A, 0x1E9E, 0x1F50, 0x1F52, 0x1F54, 0x1F56,
                 0x1F80...0x1FAF, 0x1FB2...0x1FB4, 0x1FB6, 0x1FB7, 0x1FBC,
                 0x1FC2...0x1FC4, 0x1FC6, 0x1FC7, 0x1FCC, 0x1FD2, 0x1FD3,
                 0x1FD6, 0x1FD7, 0x1FE2...0x1FE4, 0x1FE6, 0x1FE7,
                 0x1FF2...0x1FF4, 0x1FF6, 0x1FF7, 0x1FFC,
                 0xFB00...0xFB06, 0xFB13...0xFB17:
                return true
            default:
                continue
            }
        }
        return false
    }

    static func containsASCIIInsensitive(_ data: Data, needle: ASCIINeedle) -> Bool {
        data.withUnsafeBytes { raw in containsASCIIInsensitive(raw.bindMemory(to: UInt8.self), needle: needle) }
    }

    static func containsASCIIInsensitive(_ bytes: UnsafeBufferPointer<UInt8>, needle: ASCIINeedle) -> Bool {
        let pattern = needle.bytes
        guard !pattern.isEmpty else { return true }
        guard bytes.count >= pattern.count else { return false }
        do {
            var end = pattern.count - 1
            while end < bytes.count {
                var offset = 0
                while offset < pattern.count,
                      foldASCII(bytes[end - offset]) == pattern[pattern.count - 1 - offset] {
                    offset += 1
                }
                if offset == pattern.count { return true }
                end += needle.shifts[Int(foldASCII(bytes[end]))]
            }
            return false
        }
    }


    private static let rankingLocale = Locale(identifier: "en_US_POSIX")

    /// Case- and diacritic-insensitive folding for ranking. Text that is
    /// already lowercase ASCII is returned as is (copy-on-write, no buffer).
    /// Otherwise ASCII is folded natively and only non-ASCII runs go through
    /// Foundation (memoized, since punctuation and accented letters repeat).
    /// Each run is folded together with the ASCII character before it, so a
    /// combining mark keeps its base ("e" + U+0301 folds to "e") and the
    /// result equals folding the whole string, which on Linux cost more than
    /// the rest of recall combined.
    static func foldedForRanking(_ value: String) -> String {
        if isFoldedASCII(value) { return value }
        var value = value
        return value.withUTF8 { bytes -> String in
            guard bytes.contains(where: { $0 >= 0x41 && ($0 <= 0x5A || $0 >= 0x80) }) else {
                return String(decoding: bytes, as: UTF8.self)
            }
            var output: [UInt8] = []
            output.reserveCapacity(bytes.count)
            // Keyed by exact bytes: String equality is canonical equivalence.
            var foldedRuns: [[UInt8]: String] = [:]
            var index = 0
            while index < bytes.count {
                let byte = bytes[index]
                if byte < 0x80 {
                    output.append(foldASCII(byte))
                    index += 1
                    continue
                }
                var start = index
                if start > 0 {
                    output.removeLast()
                    start -= 1
                }
                var end = index + 1
                while end < bytes.count, bytes[end] >= 0x80 { end += 1 }
                let key = Array(bytes[start..<end])
                let folded: String
                if let cached = foldedRuns[key] {
                    folded = cached
                } else {
                    folded = String(decoding: key, as: UTF8.self)
                        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: rankingLocale)
                    foldedRuns[key] = folded
                }
                output.append(contentsOf: folded.utf8)
                index = end
            }
            return String(decoding: output, as: UTF8.self)
        }
    }

    /// True when folding is the identity: no uppercase ASCII letter and no
    /// character that could fold to something else.
    static func isFoldedASCII(_ value: String) -> Bool {
        var value = value
        return value.withUTF8 { bytes in
            var index = 0
            while index < bytes.count {
                let byte = bytes[index]
                if byte >= 0x80 || (byte >= 0x41 && byte <= 0x5A) { return false }
                index += 1
            }
            return true
        }
    }

    /// Substring test for already-folded ranking text. Uses zero-allocation
    /// `memmem` on POSIX for ASCII needles (ASCII bytes never occur inside
    /// multi-byte UTF-8 sequences); other needles keep Foundation's comparison.
    static func foldedContains(_ haystack: String, _ needle: String) -> Bool {
        guard !needle.isEmpty else { return false }
        guard needle.utf8.allSatisfy({ $0 < 0x80 }) else { return haystack.contains(needle) }
        var haystack = haystack
        var needle = needle
        return needle.withUTF8 { pattern in
            haystack.withUTF8 { text in
                guard pattern.count <= text.count else { return false }
                #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
                guard let textBase = text.baseAddress, let patternBase = pattern.baseAddress else {
                    return false
                }
                return memmem(textBase, text.count, patternBase, pattern.count) != nil
                #else
                let first = pattern[0]
                let last = text.count - pattern.count
                var index = 0
                while index <= last {
                    if text[index] == first,
                       UnsafeBufferPointer(rebasing: text[index..<(index + pattern.count)]).elementsEqual(pattern) {
                        return true
                    }
                    index += 1
                }
                return false
                #endif
            }
        }
    }

    /// Full ranked-search score, body included. Reference implementation for
    /// the pruned path in `orderSearch` (and its equivalence tests).
    static func relevanceScore(_ note: Note, phrase: String, terms: [String]) -> Int {
        searchBaseScore(note, phrase: phrase, terms: terms)
            + searchBodyScore(foldedBody: foldedForRanking(note.body), terms: terms)
    }

    /// Ranked-search score without the body. Only the body is large enough to
    /// make folding expensive, so it is scored last and only for notes that
    /// can still reach the top results.
    static func searchBaseScore(_ note: Note, phrase: String, terms: [String]) -> Int {
        let title = foldedForRanking(note.title)
        let filename = foldedForRanking(note.url.deletingPathExtension().lastPathComponent)
        let path = foldedForRanking(note.url.path)
        let tags = note.tags.map(foldedForRanking)
        let metadata = note.metadata.map { (foldedForRanking($0.key), foldedForRanking($0.value)) }
        var score = 0

        if title == phrase { score += 10_000 }
        else if Self.foldedContains(title, phrase) { score += 4_000 }
        if filename == phrase { score += 3_000 }
        else if Self.foldedContains(filename, phrase) { score += 1_500 }
        if tags.contains(phrase) { score += 1_000 }
        if metadata.contains(where: { $0.0 == phrase || $0.1 == phrase }) { score += 800 }

        for term in terms {
            if Self.foldedContains(title, term) { score += 300 }
            if Self.foldedContains(filename, term) { score += 200 }
            if tags.contains(where: { Self.foldedContains($0, term) }) { score += 120 }
            if metadata.contains(where: { Self.foldedContains($0.0, term) || Self.foldedContains($0.1, term) }) { score += 80 }
            if Self.foldedContains(path, term) { score += 40 }
        }
        return score
    }

    /// Body share of the ranked-search score, from an already folded body.
    static func searchBodyScore(foldedBody body: String, terms: [String]) -> Int {
        var score = 0
        for term in terms where Self.foldedContains(body, term) { score += 10 }
        return score
    }

    /// Highest score `searchBodyScore` can add.
    static func searchBodyBound(terms: [String]) -> Int { 10 * terms.count }

    /// Order-preserving parallel compactMap for snapshot entries; small
    /// inputs stay serial (concurrency overhead loses below a few hundred).
    static func parallelCompactMap<T: Sendable>(
        _ entries: [VaultSnapshotCache.Entry],
        _ transform: @escaping @Sendable (VaultSnapshotCache.Entry) -> T?
    ) -> [T] {
        parallelCollect(entries, transform)
    }

    /// Order-preserving parallel compactMap over any sendable values. Slots
    /// are written through buffer pointers so memory exclusivity is formally
    /// sound: distinct indices never alias.
    static func parallelCollect<T: Sendable, R: Sendable>(
        _ values: [T],
        _ transform: @escaping @Sendable (T) -> R?
    ) -> [R] {
        var output = [R?](repeating: nil, count: values.count)
        let count = values.count
        guard count > 0 else { return [] }
        output.withUnsafeMutableBufferPointer { buffer in
            let box = SendableBox(buffer)
            if count < 500 {
                for index in 0..<count { box.value[index] = transform(values[index]) }
            } else {
                let chunk = 64
                DispatchQueue.concurrentPerform(iterations: (count + chunk - 1) / chunk) { part in
                    for index in (part * chunk)..<min((part + 1) * chunk, count) {
                        box.value[index] = transform(values[index])
                    }
                }
            }
        }
        return output.compactMap { $0 }
    }

    static func precedes(_ a: Note, _ b: Note) -> Bool {
        if a.modifiedAt != b.modifiedAt { return a.modifiedAt > b.modifiedAt }
        if a.title != b.title { return a.title < b.title }
        return a.url.path < b.url.path
    }

    /// Full scan with per-file diagnostics. Files are loaded in parallel;
    /// output ordering is deterministic (modifiedAt desc, then title, then
    /// path — a total order, so concurrency cannot leak into results).
    /// Enumerates visible `.md` file paths under `root`, skipping hidden
    /// entries, macOS package bundles, and never descending symlinked
    /// directories (matching `FileManager.enumerator` with `.skipsHiddenFiles`
    /// and `.skipsPackageDescendants` at a fraction of the per-entry cost).
    static func enumerateMarkdownPaths(under root: URL) throws -> [String] {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        var realBuf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolvedRoot: String
        if realpath(root.path, &realBuf) != nil {
            resolvedRoot = String(decoding: realBuf.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
        } else {
            resolvedRoot = root.resolvingSymlinksInPath().path
        }
        let rootPath = (resolvedRoot.count > 1 && resolvedRoot.hasSuffix("/"))
            ? String(resolvedRoot.dropLast())
            : resolvedRoot
        guard let initialDir = opendir(rootPath) else {
            throw StoreError.unreadableVault(root)
        }
        closedir(initialDir)

        var paths: [String] = []
        var stack: [String] = [rootPath]
        while let currentDir = stack.popLast() {
            guard let dir = opendir(currentDir) else { continue }
            defer { closedir(dir) }
            let prefix = currentDir == "/" ? "/" : currentDir + "/"
            while let entry = readdir(dir) {
                let dType = entry.pointee.d_type
                let action: Int8 = withUnsafePointer(to: entry.pointee.d_name) { namePtr -> Int8 in
                    let raw = UnsafeRawPointer(namePtr).assumingMemoryBound(to: UInt8.self)
                    // Skip `.`, `..`, and all hidden entries.
                    if raw[0] == 0x2E || raw[0] == 0 { return 0 }
                    let len = strlen(UnsafeRawPointer(namePtr).assumingMemoryBound(to: CChar.self))
                    if dType == UInt8(DT_DIR) { return 1 }
                    if dType == UInt8(DT_REG) || dType == UInt8(DT_LNK) {
                        guard len >= 3,
                              raw[len - 3] == 0x2E,
                              (raw[len - 2] | 0x20) == 0x6D,
                              (raw[len - 1] | 0x20) == 0x64
                        else { return 0 }
                        return 2
                    }
                    // DT_UNKNOWN: defer to lstat below.
                    return 3
                }
                if action == 0 { continue }
                let name = withUnsafePointer(to: entry.pointee.d_name) { namePtr -> String in
                    let cstr = UnsafeRawPointer(namePtr).assumingMemoryBound(to: CChar.self)
                    let len = strlen(cstr)
                    let bytes = UnsafeBufferPointer(start: UnsafeRawPointer(cstr).assumingMemoryBound(to: UInt8.self), count: len)
                    return String(decoding: bytes, as: UTF8.self)
                }
                let childPath = prefix + name
                if action == 2 {
                    paths.append(childPath)
                } else if action == 1 {
                    #if os(macOS)
                    if name.utf8.contains(0x2E) {
                        let url = URL(fileURLWithPath: childPath, isDirectory: true)
                        if (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true {
                            continue
                        }
                    }
                    #endif
                    stack.append(childPath)
                } else {
                    var info = stat()
                    guard lstat(childPath, &info) == 0 else { continue }
                    let mode = info.st_mode & S_IFMT
                    if mode == S_IFDIR {
                        #if os(macOS)
                        if name.utf8.contains(0x2E) {
                            let url = URL(fileURLWithPath: childPath, isDirectory: true)
                            if (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true {
                                continue
                            }
                        }
                        #endif
                        stack.append(childPath)
                    } else if mode == S_IFREG || mode == S_IFLNK {
                        if childPath.lowercased().hasSuffix(".md") {
                            paths.append(childPath)
                        }
                    }
                }
            }
        }
        return paths
        #else
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw StoreError.unreadableVault(root)
        }
        var paths: [String] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "md" {
            paths.append(url.path)
        }
        return paths
        #endif
    }

    public func scanWithDiagnostics(_ vault: Vault) throws -> ScanResult {
        if let cache {
            let snapshot = try cache.snapshot(vault)
            return ScanResult(notes: snapshot.notes, unreadable: snapshot.unreadable)
        }
        let root = vault.url.standardizedFileURL
        var unreadable: [String] = []
        let statFiles = try Self.enumerateMarkdownPaths(under: root).map {
            URL(fileURLWithPath: $0, isDirectory: false)
        }
        var loaded = [Note?](repeating: nil, count: statFiles.count)
        var failed = [Bool](repeating: false, count: statFiles.count)

        loaded.withUnsafeMutableBufferPointer { loadedBuf in
            failed.withUnsafeMutableBufferPointer { failedBuf in
                // Direct indexed writes through buffer pointers are sound from
                // concurrent iterations (distinct elements never alias).
                let selfBox = SendableBox(self)
                let loadedBox = SendableBox(loadedBuf)
                let failedBox = SendableBox(failedBuf)
                @Sendable func store(_ index: Int) {
                    if let note = try? selfBox.value.load(statFiles[index]) {
                        loadedBox.value[index] = note
                    } else {
                        failedBox.value[index] = true
                    }
                }

                if statFiles.count < 500 {
                    // Small vaults stay serial: concurrency overhead loses
                    // below a few hundred files (measured).
                    for index in statFiles.indices {
                        store(index)
                    }
                } else {
                    let chunkSize = 64
                    let chunkCount = (statFiles.count + chunkSize - 1) / chunkSize
                    DispatchQueue.concurrentPerform(iterations: chunkCount) { chunk in
                        for index in (chunk * chunkSize)..<min((chunk + 1) * chunkSize, statFiles.count) {
                            store(index)
                        }
                    }
                }
            }
        }
        for (index, didFail) in failed.enumerated() where didFail {
            unreadable.append(statFiles[index].path)
        }

        let notes = loaded.compacted().sorted { a, b in
            if a.modifiedAt != b.modifiedAt { return a.modifiedAt > b.modifiedAt }
            if a.title != b.title { return a.title < b.title }
            return a.url.path < b.url.path
        }

        return ScanResult(notes: notes, unreadable: unreadable.sorted())
    }


    public func load(_ url: URL) throws -> Note {
        if let read = Self.readSource(at: url) {
            guard let source = Self.decodeUTF8(read.data) else {
                throw StoreError.invalidEncoding(url)
            }
            return try note(from: source, at: url, modifiedAt: read.modifiedAt)
        }
        let data = try Data(contentsOf: url)
        guard let source = Self.decodeUTF8(data) else {
            throw StoreError.invalidEncoding(url)
        }
        return try note(from: source, at: url)
    }

    /// Reads a note's bytes and its modification time in one pass. A scan
    /// opens every note anyway, so taking the mtime from the open descriptor
    /// (`fstat`) removes a whole extra `lstat` per file. Any failure — a
    /// non-regular file, a short read, a file that grew, or Windows — falls
    /// back to the Foundation path, which also preserves OS error details.
    static func readSource(at url: URL) -> (data: Data, modifiedAt: Date)? {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return nil }
        defer { _ = close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0
        else { return nil }
        let size = Int(info.st_size)
        let data: Data
        if size == 0 {
            data = Data()
        } else {
            guard let buffer = malloc(size) else { return nil }
            var offset = 0
            while offset < size {
                let bytesRead = read(descriptor, buffer.advanced(by: offset), size - offset)
                if bytesRead < 0 {
                    if errno == EINTR { continue }
                    free(buffer)
                    return nil
                }
                if bytesRead == 0 {
                    free(buffer)
                    return nil
                }
                offset += bytesRead
            }
            data = Data(bytesNoCopy: buffer, count: size, deallocator: .free)
        }
        #if canImport(Darwin)
        let time = info.st_mtimespec
        #else
        let time = info.st_mtim
        #endif
        let modifiedAt = Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000)
        return (data, modifiedAt)
        #else
        return nil
        #endif
    }

    /// Strict UTF-8 decoding with the same contract as
    /// `String(contentsOf:encoding: .utf8)`: a leading byte-order mark is
    /// dropped and malformed input is rejected rather than repaired. The
    /// Foundation path is several times slower on Linux, where it dominated
    /// full-vault scans.
    static func decodeUTF8(_ data: Data) -> String? {
        data.withUnsafeBytes { raw -> String? in
            var bytes = raw.bindMemory(to: UInt8.self)
            if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
                bytes = UnsafeBufferPointer(rebasing: bytes[3...])
            }
            // Pure ASCII is always valid UTF-8 and decodes unchanged, so the
            // verify-by-re-encode pass is skipped for the common case.
            if isASCII(bytes) { return String(decoding: bytes, as: UTF8.self) }
            var string = String(decoding: bytes, as: UTF8.self)
            // Decoding only ever repairs by substituting U+FFFD, so unchanged
            // bytes prove the input was valid UTF-8.
            let unchanged = string.withUTF8 { decoded in decoded.elementsEqual(bytes) }
            return unchanged ? string : nil
        }
    }

    /// Whether every byte is ASCII, checked eight bytes at a time.
    static func isASCII(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        guard let base = bytes.baseAddress else { return true }
        var index = 0
        let count = bytes.count
        while index + 8 <= count {
            let word = UnsafeRawPointer(base + index).loadUnaligned(as: UInt64.self)
            if word & 0x8080_8080_8080_8080 != 0 { return false }
            index += 8
        }
        while index < count {
            if base[index] >= 0x80 { return false }
            index += 1
        }
        return true
    }

    private func note(from source: String, at url: URL, modifiedAt explicitModifiedAt: Date? = nil) throws -> Note {
        let modifiedAt = try explicitModifiedAt ?? Self.modificationDate(of: url)
        var metadata: [String: String] = [:]
        var tags: [String] = []
        var bodySource = source[...]

        // Only front-matter lines are materialized; the body is sliced from
        // the source. Semantics match splitting every CRLF-normalized line.
        var frontmatter: [String] = []
        var isFirstLine = true
        var closed = false
        Self.forEachLine(in: source[...]) { line, rest in
            if isFirstLine {
                isFirstLine = false
                return line == "---"
            }
            if line == "---" {
                closed = true
                bodySource = rest
                return false
            }
            frontmatter.append(String(line))
            return true
        }
        if closed {
            parseFrontmatter(frontmatter, metadata: &metadata, tags: &tags)
        } else {
            bodySource = source[...]
        }

        let body: String
        if bodySource.utf8.contains(0x0D) {
            body = Self.trimmedWhitespace(Self.normalizingLineEndings(bodySource)[...])
        } else {
            // No carriage returns: the slice trims in place, bytewise.
            body = Self.trimmedWhitespace(bodySource)
        }
        var heading: Substring?
        Self.forEachLine(in: bodySource) { line, _ in
            guard line.hasPrefix("# ") else { return true }
            heading = line.dropFirst(2)
            return false
        }
        // An empty or blank `title:` must not shadow the heading or filename.
        let declaredTitle = metadata["title"].map { Self.trimmedWhitespace($0[...]) }
        let title = declaredTitle.flatMap { $0.isEmpty ? nil : $0 }
            ?? heading.map(String.init)
            ?? url.deletingPathExtension().lastPathComponent

        return Note(
            url: url,
            source: source,
            title: title,
            body: body,
            metadata: metadata,
            tags: tags,
            modifiedAt: modifiedAt
        )
    }

    /// Visits LF-delimited lines with a trailing CR removed (CRLF-normalized
    /// lines) plus the text after each line's newline. Stops when `visit`
    /// returns false. A final line without a newline is visited with an
    /// empty remainder.
    static func forEachLine(
        in text: Substring,
        _ visit: (_ line: Substring, _ rest: Substring) -> Bool
    ) {
        let utf8 = text.utf8
        var start = utf8.startIndex
        var index = start
        while index != utf8.endIndex {
            if utf8[index] == 0x0A {
                var end = index
                if end != start, utf8[utf8.index(before: end)] == 0x0D {
                    end = utf8.index(before: end)
                }
                let next = utf8.index(after: index)
                guard visit(Substring(utf8[start..<end]), Substring(utf8[next...])) else { return }
                start = next
            }
            index = utf8.index(after: index)
        }
        _ = visit(Substring(utf8[start...]), text[text.endIndex...])
    }

    /// Modification time of a note. Symlinks are followed so a shared note
    /// reports the target's mtime (matching `URLResourceValues`); a broken
    /// link falls back to the link's own mtime instead of throwing. This is
    /// far cheaper per file than `URLResourceValues`.
    static func modificationDate(of url: URL) throws -> Date {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        var info = stat()
        if lstat(url.path, &info) == 0 {
            if (info.st_mode & S_IFMT) == S_IFLNK {
                var target = stat()
                if stat(url.path, &target) == 0 { info = target }
            }
            return date(from: info)
        }
        #endif
        return try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            ?? .distantPast
    }

    #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
    private static func date(from info: stat) -> Date {
        #if canImport(Darwin)
        let time = info.st_mtimespec
        #else
        let time = info.st_mtim
        #endif
        return Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000)
    }
    #endif

    /// Unicode-scalar trim equivalent to `trimmingCharacters(in:)` for the
    /// whitespace sets Retex uses, without bridging through NSString.
    static func trimmed(_ value: String, in set: CharacterSet) -> String {
        trimmed(value[...], in: set)
    }

    static func trimmed(_ value: Substring, in set: CharacterSet) -> String {
        let scalars = value.unicodeScalars
        var lower = scalars.startIndex
        var upper = scalars.endIndex
        while lower < upper, set.contains(scalars[lower]) {
            lower = scalars.index(after: lower)
        }
        while upper > lower {
            let previous = scalars.index(before: upper)
            guard set.contains(scalars[previous]) else { break }
            upper = previous
        }
        return String(Substring(scalars[lower..<upper]))
    }

    public func createNote(
        in vault: Vault,
        folder: String,
        title: String,
        metadata: [String: String],
        body: String
    ) throws -> Note {
        let cleanTitle = title.trimmingCharacters(in: Self.whitespaceAndNewlineCharacters)
        guard !cleanTitle.isEmpty else { throw StoreError.invalidTitle }

        let directory = try confinedDirectory(in: vault, folder: folder)
        let orderedMetadata = metadata.merging(["title": cleanTitle]) { current, _ in current }
        try validateMetadata(orderedMetadata)
        _ = try UndoHistory.prepare(for: vault)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let frontmatter = orderedMetadata.keys.sorted().map {
            "\($0): \(serializedScalar(orderedMetadata[$0, default: ""]))"
        }
        let cleanBody = body.trimmingCharacters(in: Self.whitespaceAndNewlineCharacters)
        let source = (["---"] + frontmatter + ["---", "", cleanBody, ""]).joined(separator: "\n")
        let data = Data(source.utf8)
        // Claim the name atomically: `.withoutOverwriting` fails when another
        // process created the file between choosing the name and writing it,
        // and the loop then steps to the next suffix instead of overwriting.
        let stem = slug(cleanTitle)
        var url = uniqueURL(in: directory, title: cleanTitle)
        var suffix = 2
        while true {
            do {
                try data.write(to: url, options: .withoutOverwriting)
                break
            } catch {
                guard Self.isFileExistsError(error) else { throw error }
                url = directory.appendingPathComponent("\(stem)-\(suffix)").appendingPathExtension("md")
                suffix += 1
            }
        }
        return try load(url)
    }

    /// Whether a write failed because the destination already exists.
    static func isFileExistsError(_ error: Error) -> Bool {
        let nsError = error as NSError
        // 516 is `NSFileWriteFileExistsError`, spelled numerically so the check
        // is identical on every platform Foundation ships on.
        if nsError.domain == NSCocoaErrorDomain, nsError.code == 516 { return true }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(POSIXErrorCode.EEXIST.rawValue) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isFileExistsError(underlying)
        }
        return false
    }
    public func saveBody(
        _ body: String,
        for note: Note,
        expectedHash: String? = nil
    ) throws {
        try history.performMutation(path: note.url.path) {
            let current = try currentNote(for: note, expectedHash: expectedHash)
            return (
                previousSource: current.source,
                nextSource: replacingBody(in: current.source, with: body)
            )
        }
    }

    public func updateMetadata(
        _ key: String,
        value: String,
        for note: Note,
        expectedHash: String? = nil
    ) throws {
        try updateMetadata([key: value], for: note, expectedHash: expectedHash)
    }

    public func updateMetadata(
        _ updates: [String: String],
        for note: Note,
        expectedHash: String? = nil
    ) throws {
        try validateMetadata(updates)
        try history.performMutation(path: note.url.path) {
            let current = try currentNote(for: note, expectedHash: expectedHash)
            var lines = normalizedLines(current.source)
            guard lines.first == "---", let closingIndex = lines.dropFirst().firstIndex(of: "---") else {
                let properties = updates.keys.sorted().map {
                    "\($0): \(serializedScalar(updates[$0, default: ""]))"
                }
                lines.insert(contentsOf: ["---"] + properties + ["---", ""], at: 0)
                return (
                    previousSource: current.source,
                    nextSource: lines.joined(separator: "\n")
                )
            }

            var insertionIndex = closingIndex
            for key in updates.keys.sorted() {
                let line = "\(key): \(serializedScalar(updates[key, default: ""]))"
                // Replace the first occurrence of the key, then drop any later
                // duplicates (with their values) so last-wins can never lose
                // the write. Keys match by parsed name, so a quoted key such as
                // `"title":` counts as `title`.
                var searchStart = lines.startIndex + 1
                var replaced = false
                while searchStart < insertionIndex,
                      let match = lines[searchStart..<insertionIndex].firstIndex(where: {
                          Self.frontmatterKey(of: $0) == key
                      }) {
                    let end = Self.endOfValue(in: lines, from: match, before: insertionIndex)
                    if replaced {
                        lines.removeSubrange(match..<end)
                        insertionIndex -= end - match
                    } else {
                        lines[match] = line
                        lines.removeSubrange((match + 1)..<end)
                        insertionIndex -= end - match - 1
                        replaced = true
                    }
                    searchStart = match + 1
                }
                if !replaced {
                    lines.insert(line, at: insertionIndex)
                    insertionIndex += 1
                }
            }

            return (
                previousSource: current.source,
                nextSource: lines.joined(separator: "\n")
            )
        }
    }

    private func currentNote(for note: Note, expectedHash: String?) throws -> Note {
        let current = try load(note.url)
        if let expectedHash, current.contentHash != expectedHash {
            throw StoreError.staleNote(
                note.url,
                expected: expectedHash,
                actual: current.contentHash
            )
        }
        return current
    }


    /// Reads the flat, string-valued subset of YAML that Retex models. Only
    /// unindented `key: value` lines are properties; nested mappings and
    /// list items stay with their parent key instead of leaking to the top
    /// level. `tags` accepts flow lists, block lists, and scalars, and block
    /// scalars (`|`, `>`) become their text.
    private func parseFrontmatter(
        _ lines: [String],
        metadata: inout [String: String],
        tags: inout [String]
    ) {
        var activeKey: String?
        var block: (key: String, folded: Bool, lines: [String])?

        func finishBlock() {
            guard let pending = block else { return }
            block = nil
            let indent = pending.lines
                .filter { !Self.trimmed($0, in: Self.whitespaceCharacters).isEmpty }
                .map { $0.prefix { $0 == " " || $0 == "\t" }.count }
                .min() ?? 0
            let content = pending.lines.map { String($0.dropFirst(indent)) }
            let text: String
            if pending.folded {
                text = content.reduce(into: "") { result, line in
                    if line.isEmpty {
                        result += "\n"
                    } else {
                        if !result.isEmpty, !result.hasSuffix("\n") { result += " " }
                        result += line
                    }
                }
            } else {
                text = content.joined(separator: "\n")
            }
            metadata[pending.key] = Self.trimmed(text, in: Self.whitespaceAndNewlineCharacters)
        }

        for rawLine in lines {
            let isIndented = rawLine.first == " " || rawLine.first == "\t"
            let line = Self.trimmed(rawLine, in: Self.whitespaceCharacters)
            if block != nil {
                if isIndented || line.isEmpty {
                    block?.lines.append(rawLine)
                    continue
                }
                finishBlock()
            }
            // A full-line YAML comment is not content and not a key.
            if line.hasPrefix("#") { continue }
            if line.hasPrefix("- ") {
                if activeKey == "tags" {
                    tags.append(cleanValue(Self.strippingInlineComment(String(line.dropFirst(2)))))
                }
                continue
            }
            guard !isIndented, line.contains(":"), let key = Self.frontmatterKey(of: line) else { continue }
            let separator = line.firstIndex(of: ":")!
            // Unquoted ` #...` is a comment; `#` in a URL or tag is not.
            let rawValue = Self.strippingInlineComment(String(line[line.index(after: separator)...]))
            activeKey = key
            if let indicator = Self.blockScalarIndicator(rawValue) {
                metadata[key] = ""
                block = (key, indicator == ">", [])
                continue
            }
            let value = cleanValue(rawValue)
            metadata[key] = value

            if key == "tags" {
                let trimmedValue = Self.trimmed(rawValue, in: Self.whitespaceAndNewlineCharacters)
                // A quoted flow list (`tags: "[a, b]"`) read as a list in 1.2.2;
                // keep that reading instead of splitting the brackets into tags.
                let flowValue = !(trimmedValue.hasPrefix("[") && trimmedValue.hasSuffix("]"))
                    && value.hasPrefix("[") && value.hasSuffix("]")
                    ? value
                    : trimmedValue
                if flowValue.hasPrefix("["), flowValue.hasSuffix("]") {
                    tags = flowValue.dropFirst().dropLast().split(separator: ",").map {
                        cleanValue(String($0))
                    }.filter { !$0.isEmpty }
                } else if !value.isEmpty {
                    tags = value.split(separator: ",").map { cleanValue(String($0)) }.filter { !$0.isEmpty }
                }
            }
        }
        finishBlock()
    }

    /// Removes a YAML inline comment: a `#` preceded by whitespace and lying
    /// outside quotes. A `#` that starts a URL fragment or an inline tag (no
    /// whitespace before it) stays in the value, and quoted text is untouched.
    static func strippingInlineComment(_ value: String) -> String {
        guard value.utf8.contains(UInt8(ascii: "#")) else { return value }
        var inSingle = false
        var inDouble = false
        var escaped = false
        var previousWasSpace = false
        var output = ""
        output.reserveCapacity(value.count)
        for character in value {
            if escaped {
                escaped = false
                output.append(character)
                previousWasSpace = false
                continue
            }
            if character == "\\", inDouble {
                escaped = true
                output.append(character)
                previousWasSpace = false
                continue
            }
            if character == "'", !inDouble {
                inSingle.toggle()
            } else if character == "\"", !inSingle {
                inDouble.toggle()
            } else if character == "#", !inSingle, !inDouble, previousWasSpace {
                // The comment runs to the end of the line.
                break
            }
            output.append(character)
            previousWasSpace = character == " " || character == "\t"
        }
        return trimmed(output[...], in: whitespaceCharacters)
    }

    /// `|` or `>` with optional chomping and indentation indicators.
    private static func blockScalarIndicator(_ rawValue: String) -> Character? {
        let value = trimmed(rawValue, in: whitespaceCharacters)
        guard let first = value.first, first == "|" || first == ">",
              value.dropFirst().allSatisfy({ $0 == "+" || $0 == "-" || ("1"..."9").contains($0) }),
              value.count <= 3
        else { return nil }
        return first
    }

    private func replacingBody(in source: String, with body: String) -> String {
        let lines = normalizedLines(source)
        guard lines.first == "---", let closingIndex = lines.dropFirst().firstIndex(of: "---") else {
            return body.trimmingCharacters(in: Self.whitespaceAndNewlineCharacters) + "\n"
        }

        let frontmatter = lines[...closingIndex].joined(separator: "\n")
        return frontmatter + "\n\n" + body.trimmingCharacters(in: Self.whitespaceAndNewlineCharacters) + "\n"
    }

    /// Replaces CRLF with LF in one pass, leaving lone CRs alone — the same
    /// text as joining `normalizedLines`, without a line array.
    static func normalizingLineEndings(_ value: Substring) -> String {
        let utf8 = value.utf8
        var output: [UInt8] = []
        output.reserveCapacity(utf8.count)
        var previous: UInt8?
        for byte in utf8 {
            if byte == 0x0A, previous == 0x0D {
                // The CR was already copied; turn it into the line break.
                output[output.count - 1] = 0x0A
                previous = 0x0A
                continue
            }
            output.append(byte)
            previous = byte
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// Trim for `whitespaceAndNewlineCharacters` with a byte fast path, so a
    /// body that starts and ends with ASCII never touches `CharacterSet`. A
    /// multi-byte boundary (U+00A0, U+2028, U+3000, ...) defers to the scalar
    /// trim, which knows the full set.
    static func trimmedWhitespace(_ value: Substring) -> String {
        let utf8 = value.utf8
        var lower = utf8.startIndex
        var upper = utf8.endIndex
        while lower < upper, isASCIIWhitespace(utf8[lower]) {
            lower = utf8.index(after: lower)
        }
        while upper > lower, isASCIIWhitespace(utf8[utf8.index(before: upper)]) {
            upper = utf8.index(before: upper)
        }
        guard lower < upper else { return "" }
        if utf8[lower] >= 0x80 || utf8[utf8.index(before: upper)] >= 0x80 {
            return trimmed(value, in: whitespaceAndNewlineCharacters)
        }
        return String(decoding: utf8[lower..<upper], as: UTF8.self)
    }

    /// The bytes `whitespacesAndNewlines` trims inside ASCII.
    static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || (byte >= 0x09 && byte <= 0x0D)
    }

    /// Parsed key of a front-matter line: the unindented text before the first
    /// colon, trimmed, with one matching pair of quotes stripped. nil for
    /// blank lines, comments, list items, and indented continuations.
    static func frontmatterKey(of line: String) -> String? {
        guard let first = line.first, !first.isWhitespace, first != "#",
              let colon = line.firstIndex(of: ":")
        else { return nil }
        var key = trimmed(line[line.startIndex..<colon], in: whitespaceCharacters)
        if key.utf8.count >= 2, let quote = key.first, quote == key.last, quote == "\"" || quote == "'" {
            key = String(key.dropFirst().dropLast())
        }
        return key.isEmpty ? nil : key
    }

    /// Whether a line continues the value of the preceding key: indented
    /// (nested mappings and block scalars) or a list item.
    static func isContinuationLine(_ line: String) -> Bool {
        guard let first = line.first else { return false }
        if first.isWhitespace { return true }
        return line == "-" || line.hasPrefix("- ")
    }

    /// Index just past the value of the key line at `index`: its indented or
    /// list continuation lines, plus blank lines that are followed by more of
    /// the value (block scalars keep intentional gaps). A blank line before
    /// the next key or the closing `---` is not part of the value.
    static func endOfValue(in lines: [String], from index: Int, before end: Int) -> Int {
        var next = index + 1
        while next < end {
            if isContinuationLine(lines[next]) {
                next += 1
                continue
            }
            if trimmed(lines[next][...], in: whitespaceCharacters).isEmpty {
                var following = next + 1
                while following < end, trimmed(lines[following][...], in: whitespaceCharacters).isEmpty {
                    following += 1
                }
                if following < end, isContinuationLine(lines[following]) {
                    next = following
                    continue
                }
            }
            break
        }
        return next
    }

    /// Splits on LF and drops the CR of each CRLF pair, identical to
    /// replacing CRLF with LF and splitting on LF. Lone CRs are preserved.
    private func normalizedLines(_ source: String) -> [String] {
        let utf8 = source.utf8
        var lines: [String] = []
        var start = utf8.startIndex
        var index = start
        while index != utf8.endIndex {
            if utf8[index] == 0x0A {
                var end = index
                if end != start, utf8[utf8.index(before: end)] == 0x0D {
                    end = utf8.index(before: end)
                }
                lines.append(String(Substring(utf8[start..<end])))
                start = utf8.index(after: index)
            }
            index = utf8.index(after: index)
        }
        lines.append(String(Substring(utf8[start..<utf8.endIndex])))
        return lines
    }

    /// Scalar value with YAML quoting removed: double-quoted values are
    /// unescaped and single-quoted values collapse doubled quotes.
    private func cleanValue(_ value: String) -> String {
        let value = Self.trimmed(value, in: Self.whitespaceAndNewlineCharacters)
        guard value.utf8.count >= 2, let first = value.first, first == value.last else { return value }
        let inner = value.dropFirst().dropLast()
        switch first {
        case "\"": return Self.unescapedDoubleQuoted(inner)
        case "'": return inner.replacingOccurrences(of: "''", with: "'")
        default: return value
        }
    }

    private static func unescapedDoubleQuoted(_ value: Substring) -> String {
        guard value.contains("\\") else { return String(value) }
        var result = ""
        var iterator = value.makeIterator()
        while let character = iterator.next() {
            guard character == "\\" else {
                result.append(character)
                continue
            }
            guard let escaped = iterator.next() else {
                result.append(character)
                break
            }
            switch escaped {
            case "\\": result.append("\\")
            case "\"": result.append("\"")
            case "/": result.append("/")
            default:
                // Other escapes stay verbatim: earlier Retex versions wrote
                // backslashes unescaped, so "C:\temp" must keep reading as
                // a path, not a tab.
                result.append(character)
                result.append(escaped)
            }
        }
        return result
    }

    // Cached: Foundation rebuilds these sets on every access on Linux.
    static let whitespaceCharacters = CharacterSet.whitespaces
    static let whitespaceAndNewlineCharacters = CharacterSet.whitespacesAndNewlines

    /// Plain YAML when unambiguous; otherwise a double-quoted scalar that
    /// Retex and standard YAML parsers both read back to the same string.
    /// `[a, b]` values pass through as flow lists (used for tags).
    private func serializedScalar(_ value: String) -> String {
        if value.hasPrefix("["), value.hasSuffix("]") { return value }
        let needsQuotes = value.contains(where: { ":#{}[]\n\t\"".contains($0) })
            || value.first.map { "-?,'&*!|>%@`".contains($0) || $0.isWhitespace } == true
            || value.last?.isWhitespace == true
        guard needsQuotes else { return value }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func confinedDirectory(in vault: Vault, folder: String) throws -> URL {
        let expanded = NSString(string: folder).expandingTildeInPath
        guard !(expanded as NSString).isAbsolutePath else { throw StoreError.folderOutsideVault }
        let root = vault.url.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = root.appendingPathComponent(expanded, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard isWithinVault(candidate, root: root) else {
            throw StoreError.folderOutsideVault
        }
        return candidate
    }

    private func validateMetadata(_ metadata: [String: String]) throws {
        let letters = CharacterSet.letters
        let allowed = letters.union(.decimalDigits).union(CharacterSet(charactersIn: "_-"))
        for (key, value) in metadata {
            let scalars = key.unicodeScalars
            guard !scalars.isEmpty,
                  key.utf8.count <= 128,
                  scalars.first.map({ letters.contains($0) || $0 == "_" }) == true,
                  scalars.allSatisfy(allowed.contains)
            else {
                throw StoreError.invalidMetadataKey(key)
            }
            guard value.utf8.count <= 65_536,
                  !value.contains("\n"),
                  !value.contains("\r"),
                  !value.contains("\0")
            else {
                throw StoreError.invalidMetadataValue(key)
            }
        }
    }

    /// First file URL for `title` that does not exist yet. Only used to start
    /// the create retry loop; the write itself claims the name atomically.
    private func uniqueURL(in directory: URL, title: String) -> URL {
        directory.appendingPathComponent(slug(title)).appendingPathExtension("md")
    }

    // Cached: Foundation rebuilds these sets on every access on Linux.
    private static let slugAllowedCharacters = CharacterSet.alphanumerics

    /// Filename stem for a title. Folding uses a fixed locale so the same title
    /// always produces the same file name, whatever the user's locale is.
    private func slug(_ title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Self.rankingLocale)
        let allowed = Self.slugAllowedCharacters
        let parts = folded.unicodeScalars.split { !allowed.contains($0) }
        let result = parts.map(String.init).joined(separator: "-").lowercased()
        return result.isEmpty ? "untitled" : result
    }
}

public enum StoreError: LocalizedError {
    case unreadableVault(URL)
    case invalidTitle
    case invalidQuery
    case invalidLimit
    case invalidMetadataKey(String)
    case invalidMetadataValue(String)
    case folderOutsideVault
    case pathOutsideVault(URL)
    case corruptHistory(URL)
    case staleNote(URL, expected: String, actual: String)
    case invalidDateFilter(String, String)
    case historyUnwritable(URL)
    case invalidEncoding(URL)

    public var errorDescription: String? {
        switch self {
        case .unreadableVault(let url): "Retex could not read \(url.path)."
        case .invalidTitle: "A note title cannot be empty."
        case .invalidQuery: "A search query cannot be empty."
        case .invalidLimit: "A result limit must be greater than zero."
        case .invalidMetadataKey(let key): "Unsupported front-matter property name: \(key)."
        case .invalidMetadataValue(let key): "Front-matter property \(key) contains an unsupported value."
        case .folderOutsideVault: "A note folder must stay within the vault."
        case .pathOutsideVault(let url): "A Markdown path escapes the vault: \(url.path)."
        case .staleNote(let url, let expected, let actual):
            "Retex refused a stale write to \(url.path): expected \(expected), found \(actual)."
        case .invalidDateFilter(let key, let value):
            "Front-matter date filter \(key)=\(value) must use a valid YYYY-MM-DD date."
        case .corruptHistory(let url): "Retex found a corrupt undo journal entry at \(url.path)."
        case .historyUnwritable(let url): "Retex could not write the undo journal at \(url.path)."
        case .invalidEncoding(let url): "Retex could not read \(url.path) as UTF-8 text."
        }
    }
}
