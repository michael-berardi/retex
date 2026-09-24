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
/// or note text case- and diacritic-insensitively.
private struct RawNoteText {
    let data: Data
    let filename: String
    let filenameData: Data
    private var decodedState: String??
    private var foldableState: Bool?

    init(url: URL, data: Data) {
        self.data = data
        filename = url.deletingPathExtension().lastPathComponent
        filenameData = Data(filename.utf8)
    }

    /// Strictly decoded note text, computed at most once.
    var decoded: String? {
        mutating get {
            if let decodedState { return decodedState }
            let value = MarkdownStore.decodeUTF8(data)
            decodedState = .some(value)
            return value
        }
    }

    mutating func contains(_ term: String, needle: ASCIINeedle?) -> Bool {
        if let needle {
            if MarkdownStore.containsASCIIInsensitive(filenameData, needle: needle)
                || MarkdownStore.containsASCIIInsensitive(data, needle: needle) {
                return true
            }
            // Accented Latin letters fold to ASCII ("café" matches "cafe").
            // Only text containing such letters pays for Unicode comparison.
            let filenameFolds = MarkdownStore.mayFoldToASCII(filenameData)
            if foldableState == nil { foldableState = MarkdownStore.mayFoldToASCII(data) }
            guard filenameFolds || foldableState == true else { return false }
        }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return filename.range(of: term, options: options) != nil
            || decoded?.range(of: term, options: options) != nil
    }
}

private struct RecallCandidate: Sendable {
    let note: Note
    let score: Int
    let matchedTerms: [String]
}

public struct MarkdownStore {
    private let fileManager = FileManager.default
    let history = UndoHistory()

    public init() {}

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

        let root = vault.url.standardizedFileURL
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw StoreError.unreadableVault(root)
        }

        var candidates: [URL] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "md" {
            candidates.append(url)
        }
        let files = candidates
        let terms = ranked
            ? normalizedQuery.split(whereSeparator: \.isWhitespace).map(String.init)
            : [normalizedQuery]
        let asciiNeedles: [ASCIINeedle?] = terms.map { term in
            term.utf8.allSatisfy { $0 < 0x80 } ? ASCIINeedle(Array(term.utf8)) : nil
        }

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

        let found = matches.compacted()
        let sorted: [Note]
        if ranked {
            let phrase = Self.foldedForRanking(normalizedQuery)
            let foldedTerms = terms.map(Self.foldedForRanking)
            sorted = found.map { note in
                (note, Self.relevanceScore(note, phrase: phrase, terms: foldedTerms))
            }.sorted { left, right in
                if left.1 != right.1 { return left.1 > right.1 }
                return Self.precedes(left.0, right.0)
            }.map(\.0)
        } else {
            sorted = found.sorted(by: Self.precedes)
        }
        return limit.map { Array(sorted.prefix($0)) } ?? sorted
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
        limit: Int = 20
    ) throws -> [RecallHit] {
        let normalizedQuery = query.trimmingCharacters(in: Self.whitespaceAndNewlineCharacters)
        guard !normalizedQuery.isEmpty else { throw StoreError.invalidQuery }
        guard limit > 0 else { throw StoreError.invalidLimit }
        try Self.validateDateFilters(onOrBefore)
        try Self.validateDateFilters(onOrAfter)

        let terms = Self.recallTerms(normalizedQuery)
        let phrase = Self.foldedForRanking(normalizedQuery)
        let root = vault.url.standardizedFileURL
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw StoreError.unreadableVault(root)
        }
        var candidates: [URL] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "md" {
            candidates.append(url)
        }
        let files = candidates
        let asciiNeedles: [ASCIINeedle?] = terms.map { term in
            term.utf8.allSatisfy { $0 < 0x80 } ? ASCIINeedle(Array(term.utf8)) : nil
        }
        var hits = [RecallCandidate?](repeating: nil, count: files.count)
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
                hitsBox.value[index] = RecallCandidate(
                    note: note,
                    score: Self.recallScore(note, phrase: phrase, terms: terms, matched: matched),
                    matchedTerms: matched
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
        return hits.compactMap { $0 }.sorted { left, right in
            if left.score != right.score { return left.score > right.score }
            return Self.precedes(left.note, right.note)
        }.prefix(limit).map { candidate in
            RecallHit(
                note: candidate.note,
                score: candidate.score,
                matchedTerms: candidate.matchedTerms,
                excerpt: Self.evidenceExcerpt(candidate.note.body, terms: candidate.matchedTerms)
            )
        }
    }

    /// Resolves `[[wiki links]]` without depending on an editor or plugin.
    /// Markdown remains authoritative; this graph is derived on read.
    public func links(_ vault: Vault, for url: URL) throws -> NoteLinks {
        let target = try load(url)
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
        let backlinks = notes.filter { note in
            note.id != target.id && Self.wikiLinks(in: note.source).contains { rawLink in
                !Set(Self.lookupKeys(rawLink)).isDisjoint(with: targetKeys)
            }
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

    private static func recallScore(
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
        let body = foldedForRanking(note.body)
        var score = matched.count * 1_000

        if matched.count == terms.count { score += 2_000 }
        if title == phrase { score += 10_000 }
        else if Self.foldedContains(title, phrase) { score += 4_000 }
        if Self.foldedContains(body, phrase) { score += 800 }
        for term in matched {
            if Self.foldedContains(title, term) { score += 700 }
            if Self.foldedContains(filename, term) { score += 400 }
            if tags.contains(where: { Self.foldedContains($0, term) }) { score += 300 }
            if metadata.contains(where: { Self.foldedContains($0.0, term) || Self.foldedContains($0.1, term) }) { score += 220 }
            if Self.foldedContains(path, term) { score += 80 }
            if Self.foldedContains(body, term) { score += 30 }
        }
        return score
    }

    private static func evidenceExcerpt(_ body: String, terms: [String]) -> String {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return "" }
        // First line with the most matched terms; each line is scored once.
        var best = lines.startIndex
        var bestScore = -1
        for index in lines.indices {
            let score = terms.reduce(into: 0) { count, term in
                if lines[index].range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                    count += 1
                }
            }
            if score > bestScore {
                best = index
                bestScore = score
                if score == terms.count { break }
            }
        }
        let excerpt = lines[max(lines.startIndex, best - 1)...min(lines.index(before: lines.endIndex), best + 1)]
            .joined(separator: "\n")
            .trimmingCharacters(in: Self.whitespaceAndNewlineCharacters)
        return String(excerpt.prefix(600))
    }

    /// `[[target]]`, `[[target|alias]]`, and `[[target#heading]]` links. A
    /// link cannot span lines, and a later `[[` restarts the link, so a stray
    /// bracket in prose or code cannot swallow the real links that follow.
    static func wikiLinks(in body: String) -> [String] {
        var links: [String] = []
        let utf8 = body.utf8
        var open: String.Index?
        var index = utf8.startIndex
        while index != utf8.endIndex {
            let byte = utf8[index]
            let next = utf8.index(after: index)
            if byte == 0x0A {
                open = nil
            } else if next != utf8.endIndex, byte == UInt8(ascii: "["), utf8[next] == UInt8(ascii: "[") {
                open = utf8.index(after: next)
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
                index = utf8.index(after: next)
                continue
            }
            index = next
        }
        return links
    }

    private static func linkKeys(_ note: Note, root: URL) -> Set<String> {
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

    private static func lookupKeys(_ rawLink: String) -> [String] {
        let normalized = normalizedLink(rawLink)
        let filename = normalizedLink((rawLink as NSString).lastPathComponent)
        return normalized == filename ? [normalized] : [normalized, filename]
    }

    private static func normalizedLink(_ value: String) -> String {
        foldedForRanking(value.trimmingCharacters(in: Self.whitespaceAndNewlineCharacters))
    }

    private static let recallStopwords: Set<String> = [
        "a", "about", "an", "and", "are", "as", "at", "be", "by", "did",
        "do", "does", "for", "from", "how", "i", "in", "is", "it", "of",
        "on", "or", "that", "the", "this", "to", "was", "what", "when",
        "where", "which", "who", "why", "with",
    ]

    static func foldASCII(_ byte: UInt8) -> UInt8 {
        byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte
    }

    /// Whether UTF-8 bytes contain a character that may fold to ASCII under
    /// case- and diacritic-insensitive comparison: Latin-1 Supplement and
    /// Latin Extended letters, combining diacritics, Latin Extended
    /// Additional, and letterlike symbols such as the Kelvin sign.
    static func mayFoldToASCII(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var index = 0
            while index < bytes.count {
                let byte = bytes[index]
                if byte >= 0xC3 && byte <= 0xC9 || byte == 0xCC || byte == 0xCD { return true }
                if byte == 0xE1 || byte == 0xE2, index + 1 < bytes.count {
                    let next = bytes[index + 1]
                    if byte == 0xE1 && next >= 0xB8 && next <= 0xBB || byte == 0xE2 && next == 0x84 {
                        return true
                    }
                }
                index += 1
            }
            return false
        }
    }

    static func containsASCIIInsensitive(_ data: Data, needle: ASCIINeedle) -> Bool {
        let pattern = needle.bytes
        guard !pattern.isEmpty else { return true }
        guard data.count >= pattern.count else { return false }
        return data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
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

    /// Case- and diacritic-insensitive folding for ranking. ASCII is folded
    /// natively; only non-ASCII runs go through Foundation (memoized, since
    /// punctuation and accented letters repeat). Each run is folded together
    /// with the ASCII character before it, so a combining mark keeps its base
    /// ("e" + U+0301 folds to "e") and the result equals folding the whole
    /// string, which on Linux cost more than the rest of recall combined.
    static func foldedForRanking(_ value: String) -> String {
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

    /// Substring test for folded ranking text. ASCII needles use a byte
    /// search (ASCII bytes never occur inside multi-byte UTF-8 sequences);
    /// other needles keep Foundation's comparison.
    static func foldedContains(_ haystack: String, _ needle: String) -> Bool {
        guard !needle.isEmpty else { return false }
        guard needle.utf8.allSatisfy({ $0 < 0x80 }) else { return haystack.contains(needle) }
        var haystack = haystack
        var needle = needle
        return haystack.withUTF8 { text in
            needle.withUTF8 { pattern in
                guard pattern.count <= text.count else { return false }
                let first = pattern[0]
                var index = 0
                let last = text.count - pattern.count
                while index <= last {
                    if text[index] == first,
                       UnsafeBufferPointer(rebasing: text[index..<(index + pattern.count)]).elementsEqual(pattern) {
                        return true
                    }
                    index += 1
                }
                return false
            }
        }
    }

    private static func relevanceScore(_ note: Note, phrase: String, terms: [String]) -> Int {
        let title = foldedForRanking(note.title)
        let filename = foldedForRanking(note.url.deletingPathExtension().lastPathComponent)
        let path = foldedForRanking(note.url.path)
        let tags = note.tags.map(foldedForRanking)
        let metadata = note.metadata.map { (foldedForRanking($0.key), foldedForRanking($0.value)) }
        let body = foldedForRanking(note.body)
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
            if Self.foldedContains(body, term) { score += 10 }
        }
        return score
    }

    private static func precedes(_ a: Note, _ b: Note) -> Bool {
        if a.modifiedAt != b.modifiedAt { return a.modifiedAt > b.modifiedAt }
        if a.title != b.title { return a.title < b.title }
        return a.url.path < b.url.path
    }

    /// Full scan with per-file diagnostics. Files are loaded in parallel;
    /// output ordering is deterministic (modifiedAt desc, then title, then
    /// path — a total order, so concurrency cannot leak into results).
    public func scanWithDiagnostics(_ vault: Vault) throws -> ScanResult {
        let root = vault.url.standardizedFileURL
        guard let enumerator = fileManager.enumerator(
            at: root,
            // No prefetched keys: the parser stats each file itself, and
            // prefetching doubled enumeration cost on large vaults.
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw StoreError.unreadableVault(root)
        }

        // Single enumeration pass: collect candidate files and diagnostics.
        var candidates: [URL] = []
        var unreadable: [String] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "md" {
            // Note: do NOT pre-filter on isRegularFile here — it is false for
            // valid symlinks to regular files (shared-fleet links), which must
            // be indexed. Unreadable entries (dangling links, permissions)
            // surface as load failures below and are reported, never fatal.
            candidates.append(url)
        }

        // Parse files into fixed slots. Small vaults stay serial —
        // concurrency overhead loses below a few hundred files (measured).
        // Slot writes go through buffer pointers so memory exclusivity is
        // formally sound; distinct indices never alias.
        let statFiles = candidates
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
        let data = try Data(contentsOf: url)
        guard let source = Self.decodeUTF8(data) else {
            throw StoreError.invalidEncoding(url)
        }
        return try note(from: source, at: url)
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
            var string = String(decoding: bytes, as: UTF8.self)
            // Decoding only ever repairs by substituting U+FFFD, so unchanged
            // bytes prove the input was valid UTF-8.
            let unchanged = string.withUTF8 { decoded in decoded.elementsEqual(bytes) }
            return unchanged ? string : nil
        }
    }

    private func note(from source: String, at url: URL) throws -> Note {
        let modifiedAt = try Self.modificationDate(of: url)
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

        let normalizedBody = bodySource.utf8.contains(0x0D)
            ? normalizedLines(String(bodySource)).joined(separator: "\n")
            : String(bodySource)
        let body = Self.trimmed(normalizedBody, in: Self.whitespaceAndNewlineCharacters)
        var heading: Substring?
        Self.forEachLine(in: bodySource) { line, _ in
            guard line.hasPrefix("# ") else { return true }
            heading = line.dropFirst(2)
            return false
        }
        let title = metadata["title"] ?? heading.map(String.init) ?? url.deletingPathExtension().lastPathComponent

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

    /// Modification time of the directory entry itself (symlinks are not
    /// followed), matching `URLResourceValues.contentModificationDate` at a
    /// fraction of its per-file cost.
    static func modificationDate(of url: URL) throws -> Date {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        var info = stat()
        if lstat(url.path, &info) == 0 {
            #if canImport(Darwin)
            let time = info.st_mtimespec
            #else
            let time = info.st_mtim
            #endif
            return Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000)
        }
        #endif
        return try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            ?? .distantPast
    }

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
        let url = uniqueURL(in: directory, title: cleanTitle)
        let frontmatter = orderedMetadata.keys.sorted().map {
            "\($0): \(serializedScalar(orderedMetadata[$0, default: ""]))"
        }
        let cleanBody = body.trimmingCharacters(in: Self.whitespaceAndNewlineCharacters)
        let source = (["---"] + frontmatter + ["---", "", cleanBody, ""]).joined(separator: "\n")
        try source.write(to: url, atomically: true, encoding: .utf8)
        return try load(url)
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
                if let existingIndex = lines[1..<insertionIndex].firstIndex(where: { $0.hasPrefix("\(key):") }) {
                    lines[existingIndex] = line
                    let continuationIndex = existingIndex + 1
                    while continuationIndex < insertionIndex {
                        let continuation = lines[continuationIndex]
                        let isNestedValue = continuation.first?.isWhitespace == true
                            || continuation.trimmingCharacters(in: Self.whitespaceCharacters).hasPrefix("- ")
                        guard isNestedValue else { break }
                        lines.remove(at: continuationIndex)
                        insertionIndex -= 1
                    }
                } else {
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
            if line.hasPrefix("- ") {
                if activeKey == "tags" {
                    tags.append(cleanValue(String(line.dropFirst(2))))
                }
                continue
            }
            guard !isIndented, let separator = line.firstIndex(of: ":") else { continue }
            let key = Self.trimmed(line[..<separator], in: Self.whitespaceCharacters)
            let rawValue = String(line[line.index(after: separator)...])
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
                if trimmedValue.hasPrefix("["), trimmedValue.hasSuffix("]") {
                    tags = trimmedValue.dropFirst().dropLast().split(separator: ",").map {
                        cleanValue(String($0))
                    }.filter { !$0.isEmpty }
                } else if !value.isEmpty {
                    tags = value.split(separator: ",").map { cleanValue(String($0)) }.filter { !$0.isEmpty }
                }
            }
        }
        finishBlock()
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

    private func uniqueURL(in directory: URL, title: String) -> URL {
        let stem = slug(title)
        var candidate = directory.appendingPathComponent(stem).appendingPathExtension("md")
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(stem)-\(suffix)").appendingPathExtension("md")
            suffix += 1
        }
        return candidate
    }

    private func slug(_ title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let allowed = CharacterSet.alphanumerics
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
