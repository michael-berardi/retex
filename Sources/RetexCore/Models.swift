import Foundation
import Crypto

public struct Vault: Identifiable, Hashable, Sendable {
    public let url: URL
    public var name: String { url.lastPathComponent }
    public var id: String { url.standardizedFileURL.path }

    public init(url: URL) {
        self.url = url
    }
}

public struct Note: Identifiable, Hashable, Sendable, Codable {
    public let url: URL
    /// Canonical identity of the note, computed once when the note is built.
    /// `standardizedFileURL` is a filesystem round-trip per call, and every
    /// scan, link lookup and sort used to pay for it.
    public let id: String
    public var source: String
    public var title: String
    public var body: String
    public var metadata: [String: String]
    public var tags: [String]
    public var modifiedAt: Date
    /// Exact front-matter record type. Retex accepts any non-empty type so a
    /// vault can model CRM records, agent memory, or project-specific data
    /// without changing the binary.
    public var recordType: String {
        let value = metadata["type", default: NoteType.note.rawValue]
        return value.isEmpty ? NoteType.note.rawValue : value
    }

    /// Compatibility view for clients that use the original built-in enum.
    /// Unknown record types remain available through `recordType`.
    public var type: NoteType { NoteType(rawValue: recordType) ?? .note }
    public var status: String { metadata["status", default: "Unsorted"] }
    public var owner: String { metadata["owner", default: "Unassigned"] }
    public var value: String? { metadata["value"] }
    public var company: String? { metadata["company"] }
    public var nextAction: String? { metadata["next_action"] }
    public var model: String? { metadata["model"] }
    public var duration: String? { metadata["duration"] }
    public var dueDate: String? { metadata["due"] }
    /// A finite rank only: `nan`, `inf` and `-inf` are readable YAML scalars,
    /// and a non-finite `Double` makes `JSONEncoder` refuse the whole payload.
    public var rank: Double {
        guard let value = Double(metadata["rank", default: "0"]), value.isFinite else { return 0 }
        return value
    }
    public var isArchived: Bool { metadata["archived"]?.lowercased() == "true" }
    /// Lowercase hex digest of the source text. `SHA256.hash` hands back a
    /// sequence of bytes, so the digest is expanded through a byte table into
    /// one pre-sized buffer instead of 32 `String(format:)` calls.
    public var contentHash: String {
        let digest = SHA256.hash(data: Data(source.utf8))
        let digits = Self.hexDigits
        var bytes = [UInt8](repeating: 0, count: SHA256.byteCount * 2)
        var offset = 0
        for byte in digest {
            bytes[offset] = digits[Int(byte >> 4)]
            bytes[offset + 1] = digits[Int(byte & 0x0F)]
            offset += 2
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)
    public var displayPath: String { url.deletingPathExtension().lastPathComponent }

    public var checklistProgress: (completed: Int, total: Int) {
        let tasks = body.components(separatedBy: .newlines).map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { line in
            line.hasPrefix("- [ ]")
                || line.lowercased().hasPrefix("- [x]")
        }
        let completed = tasks.filter {
            $0.lowercased().hasPrefix("- [x]")
        }.count
        return (completed, tasks.count)
    }

    private static func canonicalID(for url: URL) -> String {
        let path = url.path
        guard !path.isEmpty,
              !path.contains("/."),
              !path.contains("//"),
              (path.count == 1 || !path.hasSuffix("/"))
        else {
            return url.standardizedFileURL.path
        }
        #if os(macOS)
        if path.hasPrefix("/private/tmp/") || path.hasPrefix("/private/var/") || path.hasPrefix("/private/etc/") {
            return String(path.dropFirst(8))
        }
        #endif
        return path
    }

    public init(
        url: URL,
        source: String,
        title: String,
        body: String,
        metadata: [String: String],
        tags: [String],
        modifiedAt: Date
    ) {
        self.url = url
        self.id = Self.canonicalID(for: url)
        self.source = source
        self.title = title
        self.body = body
        self.metadata = metadata
        self.tags = tags
        self.modifiedAt = modifiedAt
    }

    /// The stored `id` derives from `url`, so it stays out of the encoded
    /// shape: existing JSON readers keep seeing exactly the fields they had.
    private enum CodingKeys: String, CodingKey {
        case url, source, title, body, metadata, tags, modifiedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let url = try container.decode(URL.self, forKey: .url)
        self.url = url
        self.id = Self.canonicalID(for: url)
        self.source = try container.decode(String.self, forKey: .source)
        self.title = try container.decode(String.self, forKey: .title)
        self.body = try container.decode(String.self, forKey: .body)
        self.metadata = try container.decode([String: String].self, forKey: .metadata)
        self.tags = try container.decode([String].self, forKey: .tags)
        self.modifiedAt = try container.decode(Date.self, forKey: .modifiedAt)
    }
}

public enum NoteType: String, CaseIterable, Sendable, Codable {
    case note
    case contact
    case deal
    case task
    case agentRun = "agent-run"

    public var label: String {
        switch self {
        case .note: "Note"
        case .contact: "Contact"
        case .deal: "Deal"
        case .task: "Task"
        case .agentRun: "Agent run"
        }
    }
}

public struct RecallHit: Sendable {
    public let note: Note
    public let score: Int
    public let matchedTerms: [String]
    public let excerpt: String

    public init(note: Note, score: Int, matchedTerms: [String], excerpt: String) {
        self.note = note
        self.score = score
        self.matchedTerms = matchedTerms
        self.excerpt = excerpt
    }
}

public struct NoteLinks: Sendable {
    public let outgoing: [Note]
    public let backlinks: [Note]
    public let unresolved: [String]

    public init(outgoing: [Note], backlinks: [Note], unresolved: [String]) {
        self.outgoing = outgoing
        self.backlinks = backlinks
        self.unresolved = unresolved
    }
}

public struct BoardColumn: Identifiable, Hashable, Sendable {
    public let title: String
    public let statuses: Set<String>
    public var id: String { title }

    public init(title: String, statuses: Set<String>) {
        self.title = title
        self.statuses = statuses
    }

    public static let defaultColumns = [
        BoardColumn(title: "Inbox", statuses: ["Inbox", "New"]),
        BoardColumn(title: "Qualified", statuses: ["Qualified"]),
        BoardColumn(title: "Proposal", statuses: ["Proposal", "Negotiation"]),
        BoardColumn(title: "Won", statuses: ["Won"]),
    ]
}


/// Outcome of a vault scan: parsed notes plus diagnostics for entries that
/// could not be read (dangling symlinks, permission problems).
public struct ScanResult: Sendable {
    public let notes: [Note]
    public let unreadable: [String]

    public init(notes: [Note], unreadable: [String]) {
        self.notes = notes
        self.unreadable = unreadable
    }
}

extension Array where Element == Note? {
    func compacted() -> [Note] {
        filter { $0 != nil }.map { $0! }
    }
}

func isWithinVault(_ candidate: URL, root: URL) -> Bool {
    #if os(Windows)
    let candidateComponents = candidate.standardizedFileURL.pathComponents.map { $0.lowercased() }
    let rootComponents = root.standardizedFileURL.pathComponents.map { $0.lowercased() }
    #else
    let candidateComponents = candidate.standardizedFileURL.pathComponents
    let rootComponents = root.standardizedFileURL.pathComponents
    #endif
    return candidateComponents.starts(with: rootComponents)
}
