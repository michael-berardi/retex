import Foundation

public struct MarkdownStore {
    private let fileManager = FileManager.default
    let history = UndoHistory()

    public init() {}

    public func scan(_ vault: Vault) throws -> [Note] {
        guard let enumerator = fileManager.enumerator(
            at: vault.url,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw StoreError.unreadableVault(vault.url)
        }

        var notes: [Note] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "md" {
            // Skip symlinks and anything unreadable: one dangling agent
            // symlink must not zero out an entire vault view.
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true
            else { continue }
            if let note = try? load(url) {
                notes.append(note)
            }
        }

        return notes.sorted {
            if $0.modifiedAt == $1.modifiedAt { return $0.title < $1.title }
            return $0.modifiedAt > $1.modifiedAt
        }
    }

    public func load(_ url: URL) throws -> Note {
        let source = try String(contentsOf: url, encoding: .utf8)
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

        let directory = vault.url.appendingPathComponent(folder, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = uniqueURL(in: directory, title: cleanTitle)
        let orderedMetadata = metadata.merging(["title": cleanTitle]) { current, _ in current }
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
    case corruptHistory(URL)
    case historyUnwritable(URL)

    public var errorDescription: String? {
        switch self {
        case .unreadableVault(let url): "Retex could not read \(url.path)."
        case .invalidTitle: "A note title cannot be empty."
        case .corruptHistory(let url): "Retex found a corrupt undo journal entry at \(url.path)."
        case .historyUnwritable(let url): "Retex could not write the undo journal at \(url.path)."
        }
    }
}
