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
    /// read/parse problem so a broken config never bricks a vault. Decoded
    /// configs are memoized by (path, mtime, size): an MCP session asks for
    /// the same unchanged file on nearly every request.
    public static func load(for vault: Vault) -> VaultConfig {
        let url = Self.url(for: vault)
        let path = url.path
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let mtime = attributes?[.modificationDate] as? Date
        let size = (attributes?[.size] as? NSNumber)?.intValue
        if let cached = cache.config(for: path, mtime: mtime, size: size) {
            return cached
        }
        let config: VaultConfig
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(VaultConfig.self, from: data) {
            config = decoded
        } else {
            config = .default
        }
        cache.store(config, for: path, mtime: mtime, size: size)
        return config
    }

    // MARK: Config cache

    private static let cache = VaultConfigCache()

    /// Fingerprint-keyed memo for decoded configs. A missing file is cached
    /// too (nil fingerprint), and any appearance of the file changes the
    /// fingerprint, so defaults are never served for a config that exists.
    private final class VaultConfigCache: @unchecked Sendable {
        private struct Entry {
            let mtime: Date?
            let size: Int?
            let config: VaultConfig
        }

        private let lock = NSLock()
        private var entries: [String: Entry] = [:]
        private let limit = 64

        func config(for path: String, mtime: Date?, size: Int?) -> VaultConfig? {
            lock.lock()
            defer { lock.unlock() }
            guard let entry = entries[path], entry.mtime == mtime, entry.size == size else { return nil }
            return entry.config
        }

        func store(_ config: VaultConfig, for path: String, mtime: Date?, size: Int?) {
            lock.lock()
            defer { lock.unlock() }
            if entries.count >= limit, entries[path] == nil { entries.removeAll(keepingCapacity: true) }
            entries[path] = Entry(mtime: mtime, size: size, config: config)
        }
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
        // Each element decodes on its own: one malformed column, view, or
        // record type is dropped instead of discarding the whole config.
        let rawColumns = Self.elements(RawColumn.self, forKey: .columns, in: container)
        let columns = rawColumns.map { BoardColumn(title: $0.title, statuses: Set($0.statuses)) }
        self.init(
            columns: columns.isEmpty ? BoardColumn.defaultColumns : columns,
            views: Self.elements(SavedView.self, forKey: .views, in: container),
            recordTypes: Self.elements(RecordSchema.self, forKey: .recordTypes, in: container)
        )
    }

    /// Decodes any array of a key, keeping the elements that decode and
    /// dropping only the ones that do not.
    private static func elements<Element: Decodable>(
        _ type: Element.Type,
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>
    ) -> [Element] {
        guard let wrapped = (try? container.decodeIfPresent([Failable<Element>].self, forKey: key)) ?? nil else {
            return []
        }
        return wrapped.compactMap(\.value)
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

/// Decodes to `nil` instead of throwing, so one bad array element cannot take
/// its siblings down with it.
private struct Failable<Wrapped: Decodable>: Decodable {
    let value: Wrapped?

    init(from decoder: Decoder) throws {
        value = try? Wrapped(from: decoder)
    }
}

struct RawColumn: Codable {
    let title: String
    let statuses: [String]

    init(title: String, statuses: [String]) {
        self.title = title
        self.statuses = statuses
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        let wrapped = (try? container.decodeIfPresent([Failable<String>].self, forKey: .statuses)) ?? []
        statuses = wrapped.compactMap(\.value)
    }

    private enum CodingKeys: String, CodingKey { case title, statuses }
}
