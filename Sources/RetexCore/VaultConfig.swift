import Foundation

/// Per-vault configuration stored at `<vault>/.retex/config.json`.
/// Customizes board columns and defines named saved views. Missing file or
/// missing fields fall back to the built-in defaults.
public struct VaultConfig: Sendable, Equatable {
    public struct SavedView: Sendable, Equatable, Codable {
        public let name: String
        public let type: String?
        public let status: String?
        public let tag: String?
        public let properties: [String: String]?

        public init(
            name: String,
            type: String? = nil,
            status: String? = nil,
            tag: String? = nil
        ) {
            self.init(name: name, type: type, status: status, tag: tag, properties: nil)
        }

        public init(
            name: String,
            type: String?,
            status: String?,
            tag: String?,
            properties: [String: String]?
        ) {
            self.name = name
            self.type = type
            self.status = status
            self.tag = tag
            self.properties = properties
        }
    }

    public struct RecordSchema: Sendable, Equatable, Codable {
        public let name: String
        public let folder: String?
        public let required: [String]
        public let properties: [String]

        public init(
            name: String,
            folder: String? = nil,
            required: [String] = [],
            properties: [String] = []
        ) {
            self.name = name
            self.folder = folder
            self.required = required
            self.properties = properties
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            folder = try container.decodeIfPresent(String.self, forKey: .folder)
            required = try container.decodeIfPresent([String].self, forKey: .required) ?? []
            properties = try container.decodeIfPresent([String].self, forKey: .properties) ?? []
        }

        private enum CodingKeys: String, CodingKey {
            case name, folder, required, properties
        }
    }

    public let columns: [BoardColumn]
    public let views: [SavedView]
    public let recordTypes: [RecordSchema]

    public static let `default` = VaultConfig(
        columns: BoardColumn.defaultColumns,
        views: [],
        recordTypes: []
    )

    public init(columns: [BoardColumn], views: [SavedView]) {
        self.init(columns: columns, views: views, recordTypes: [])
    }

    public init(
        columns: [BoardColumn],
        views: [SavedView],
        recordTypes: [RecordSchema]
    ) {
        self.columns = columns
        self.views = views
        self.recordTypes = recordTypes
    }

    /// Location of the config file for a vault.
    public static func url(for vault: Vault) -> URL {
        vault.url.appendingPathComponent(".retex/config.json")
    }

    /// Loads `<vault>/.retex/config.json`, falling back to defaults on any
    /// read/parse problem so a broken config never bricks a vault.
    public static func load(for vault: Vault) -> VaultConfig {
        let url = Self.url(for: vault)
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(VaultConfig.self, from: data)
        else { return .default }
        return config
    }

    public func view(named name: String) -> SavedView? {
        views.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    public func recordType(named name: String) -> RecordSchema? {
        recordTypes.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    public func folder(for recordType: String) -> String {
        if let folder = self.recordType(named: recordType)?.folder,
           !folder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return folder
        }
        return switch NoteType(rawValue: recordType) {
        case .deal: "Deals"
        case .contact: "Contacts"
        case .agentRun: "Agent Runs"
        case .task: "Tasks"
        case .note: "Notes"
        case nil: "Notes"
        }
    }
}

extension VaultConfig: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawColumns = try container.decodeIfPresent([RawColumn].self, forKey: .columns)
        let columns = (rawColumns ?? []).map { BoardColumn(title: $0.title, statuses: Set($0.statuses)) }
        self.init(
            columns: columns.isEmpty ? BoardColumn.defaultColumns : columns,
            views: try container.decodeIfPresent([SavedView].self, forKey: .views) ?? [],
            recordTypes: try container.decodeIfPresent([RecordSchema].self, forKey: .recordTypes) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(
            columns.map { RawColumn(title: $0.title, statuses: Array($0.statuses).sorted()) },
            forKey: .columns
        )
        try container.encode(views, forKey: .views)
        try container.encode(recordTypes, forKey: .recordTypes)
    }

    private enum CodingKeys: String, CodingKey { case columns, views, recordTypes }
}

struct RawColumn: Codable {
    let title: String
    let statuses: [String]
}
