import Foundation

/// @unchecked Sendable wrapper: contents are confined to one concurrent
/// region at a time by construction (distinct indexed slots never alias).
private final class SendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
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
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
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
        let asciiNeedles: [[UInt8]?] = terms.map { term in
            term.utf8.allSatisfy { $0 < 0x80 } ? term.utf8.map(Self.foldASCII) : nil
        }

        var matches = [Note?](repeating: nil, count: files.count)
        matches.withUnsafeMutableBufferPointer { matchesBuffer in
            let selfBox = SendableBox(self)
            let matchesBox = SendableBox(matchesBuffer)
            @Sendable func inspect(_ index: Int) {
                let url = files[index]
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return }
                let filename = url.deletingPathExtension().lastPathComponent
                let filenameData = Data(filename.utf8)
                var decoded: String?

                for (termIndex, term) in terms.enumerated() {
                    let isMatch: Bool
                    if let needle = asciiNeedles[termIndex] {
                        isMatch = Self.containsASCIIInsensitive(filenameData, needle: needle)
                            || Self.containsASCIIInsensitive(data, needle: needle)
                    } else {
                        if decoded == nil { decoded = String(data: data, encoding: .utf8) }
                        isMatch = filename.range(
                            of: term,
                            options: [.caseInsensitive, .diacriticInsensitive]
                        ) != nil || decoded?.range(
                            of: term,
                            options: [.caseInsensitive, .diacriticInsensitive]
                        ) != nil
                    }
                    if !isMatch { return }
                }

                guard let source = decoded ?? String(data: data, encoding: .utf8) else { return }
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

    private static func foldASCII(_ byte: UInt8) -> UInt8 {
        byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte
    }

    private static func containsASCIIInsensitive(_ data: Data, needle: [UInt8]) -> Bool {
        guard !needle.isEmpty else { return true }
        guard data.count >= needle.count else { return false }
        return data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            let finalStart = bytes.count - needle.count
            for start in 0...finalStart {
                var matched = true
                for offset in needle.indices where foldASCII(bytes[start + offset]) != needle[offset] {
                    matched = false
                    break
                }
                if matched { return true }
            }
            return false
        }
    }

    private static func foldedForRanking(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
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
        else if title.contains(phrase) { score += 4_000 }
        if filename == phrase { score += 3_000 }
        else if filename.contains(phrase) { score += 1_500 }
        if tags.contains(phrase) { score += 1_000 }
        if metadata.contains(where: { $0.0 == phrase || $0.1 == phrase }) { score += 800 }

        for term in terms {
            if title.contains(term) { score += 300 }
            if filename.contains(term) { score += 200 }
            if tags.contains(where: { $0.contains(term) }) { score += 120 }
            if metadata.contains(where: { $0.0.contains(term) || $0.1.contains(term) }) { score += 80 }
            if path.contains(term) { score += 40 }
            if body.contains(term) { score += 10 }
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
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
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
        try note(from: String(contentsOf: url, encoding: .utf8), at: url)
    }

    private func note(from source: String, at url: URL) throws -> Note {
        let lines = normalizedLines(source)
        let attributes = try url.resourceValues(forKeys: [.contentModificationDateKey])
        var metadata: [String: String] = [:]
        var tags: [String] = []
        var bodyStart = 0

        if lines.first == "---", let closingIndex = lines.dropFirst().firstIndex(of: "---") {
            parseFrontmatter(Array(lines[1..<closingIndex]), metadata: &metadata, tags: &tags)
            bodyStart = closingIndex + 1
        }

        let body = lines.dropFirst(bodyStart).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let heading = lines.dropFirst(bodyStart).first { $0.hasPrefix("# ") }?.dropFirst(2)
        let title = metadata["title"] ?? heading.map(String.init) ?? url.deletingPathExtension().lastPathComponent

        return Note(
            url: url,
            source: source,
            title: title,
            body: body,
            metadata: metadata,
            tags: tags,
            modifiedAt: attributes.contentModificationDate ?? .distantPast
        )
    }

    public func createNote(
        in vault: Vault,
        folder: String,
        title: String,
        metadata: [String: String],
        body: String
    ) throws -> Note {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
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
        let cleanBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = (["---"] + frontmatter + ["---", "", cleanBody, ""]).joined(separator: "\n")
        try source.write(to: url, atomically: true, encoding: .utf8)
        return try load(url)
    }
    public func saveBody(_ body: String, for note: Note) throws {
        // Journal first (WAL style); if the file write fails, roll the entry back.
        try history.record(.init(path: note.url.path, previousSource: note.source))
        let source = replacingBody(in: note.source, with: body)
        do {
            try source.write(to: note.url, atomically: true, encoding: .utf8)
        } catch {
            _ = try? history.pop(path: note.url.path)
            throw error
        }
    }

    public func updateMetadata(_ key: String, value: String, for note: Note) throws {
        try updateMetadata([key: value], for: note)
    }

    public func updateMetadata(_ updates: [String: String], for note: Note) throws {
        try validateMetadata(updates)
        // Journal first (WAL style); if the file write fails, roll the entry back.
        try history.record(.init(path: note.url.path, previousSource: note.source))
        var lines = normalizedLines(note.source)
        guard lines.first == "---", let closingIndex = lines.dropFirst().firstIndex(of: "---") else {
            let properties = updates.keys.sorted().map {
                "\($0): \(serializedScalar(updates[$0, default: ""]))"
            }
            lines.insert(contentsOf: ["---"] + properties + ["---", ""], at: 0)
            try writeWithRollback(lines.joined(separator: "\n"), note: note)
            return
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
                        || continuation.trimmingCharacters(in: .whitespaces).hasPrefix("- ")
                    guard isNestedValue else { break }
                    lines.remove(at: continuationIndex)
                    insertionIndex -= 1
                }
            } else {
                lines.insert(line, at: insertionIndex)
                insertionIndex += 1
            }
        }

        try writeWithRollback(lines.joined(separator: "\n"), note: note)
    }

    private func writeWithRollback(_ source: String, note: Note) throws {
        do {
            try source.write(to: note.url, atomically: true, encoding: .utf8)
        } catch {
            _ = try? history.pop(path: note.url.path)
            throw error
        }
    }

    private func parseFrontmatter(
        _ lines: [String],
        metadata: inout [String: String],
        tags: inout [String]
    ) {
        var activeKey: String?

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- "), activeKey == "tags" {
                tags.append(cleanValue(String(line.dropFirst(2))))
                continue
            }

            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = cleanValue(String(line[line.index(after: separator)...]))
            activeKey = key
            metadata[key] = value

            if key == "tags", value.hasPrefix("["), value.hasSuffix("]") {
                tags = value.dropFirst().dropLast().split(separator: ",").map {
                    cleanValue(String($0))
                }
            }
        }
    }

    private func replacingBody(in source: String, with body: String) -> String {
        let lines = normalizedLines(source)
        guard lines.first == "---", let closingIndex = lines.dropFirst().firstIndex(of: "---") else {
            return body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        }

        let frontmatter = lines[...closingIndex].joined(separator: "\n")
        return frontmatter + "\n\n" + body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private func normalizedLines(_ source: String) -> [String] {
        source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }

    private func cleanValue(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    private func serializedScalar(_ value: String) -> String {
        if value.hasPrefix("["), value.hasSuffix("]") { return value }
        guard value.contains(where: { ":#{}[]\n".contains($0) }) else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private func confinedDirectory(in vault: Vault, folder: String) throws -> URL {
        let expanded = NSString(string: folder).expandingTildeInPath
        guard !expanded.hasPrefix("/") else { throw StoreError.folderOutsideVault }
        let root = vault.url.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = root.appendingPathComponent(expanded, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path == root.path || candidate.path.hasPrefix(rootPrefix) else {
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
    case historyUnwritable(URL)

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
        case .corruptHistory(let url): "Retex found a corrupt undo journal entry at \(url.path)."
        case .historyUnwritable(let url): "Retex could not write the undo journal at \(url.path)."
        }
    }
}
