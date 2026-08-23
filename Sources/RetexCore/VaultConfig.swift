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

        public init(name: String, type: String? = nil, status: String? = nil, tag: String? = nil) {
            self.name = name
            self.type = type
            self.status = status
            self.tag = tag
        }
    }

    public let columns: [BoardColumn]
    public let views: [SavedView]

    public static let `default` = VaultConfig(
        columns: BoardColumn.defaultColumns,
        views: []
    )

    public init(columns: [BoardColumn], views: [SavedView]) {
        self.columns = columns
        self.views = views
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
}

extension VaultConfig: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawColumns = try container.decodeIfPresent([RawColumn].self, forKey: .columns)
        let columns = (rawColumns ?? []).map { BoardColumn(title: $0.title, statuses: Set($0.statuses)) }
        self.init(
            columns: columns.isEmpty ? BoardColumn.defaultColumns : columns,
            views: try container.decodeIfPresent([SavedView].self, forKey: .views) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(
            columns.map { RawColumn(title: $0.title, statuses: Array($0.statuses).sorted()) },
            forKey: .columns
        )
        try container.encode(views, forKey: .views)
    }

    private enum CodingKeys: String, CodingKey { case columns, views }
}

struct RawColumn: Codable {
    let title: String
    let statuses: [String]
}
