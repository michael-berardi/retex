import Foundation

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
    public var source: String
    public var title: String
    public var body: String
    public var metadata: [String: String]
    public var tags: [String]
    public var modifiedAt: Date

    public var id: String { url.standardizedFileURL.path }
    public var type: NoteType { NoteType(rawValue: metadata["type", default: "note"]) ?? .note }
    public var status: String { metadata["status", default: "Unsorted"] }
    public var owner: String { metadata["owner", default: "Unassigned"] }
    public var value: String? { metadata["value"] }
    public var company: String? { metadata["company"] }
    public var nextAction: String? { metadata["next_action"] }
    public var model: String? { metadata["model"] }
    public var duration: String? { metadata["duration"] }
    public var dueDate: String? { metadata["due"] }
    public var rank: Double { Double(metadata["rank", default: "0"]) ?? 0 }
    public var isArchived: Bool { metadata["archived"]?.lowercased() == "true" }
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
        self.source = source
        self.title = title
        self.body = body
        self.metadata = metadata
        self.tags = tags
        self.modifiedAt = modifiedAt
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
