import Foundation

/// The one small file Retex's update feature writes: the last daily check
/// (time, latest stable version or failure cause) and the user's choices.
/// It is private (0600), atomically replaced, and removed by
/// `retex update --uninstall`.
public struct UpdateState: Codable, Equatable, Sendable {
    /// Checks and notices repeat at most once per this interval.
    public static let interval: TimeInterval = 24 * 60 * 60

    public var checkedAt: Date?
    public var latestVersion: String?
    public var checkError: String?
    public var installError: String?
    /// `owner/repo` saved by `update --auto on`, so the scheduled job works
    /// without the shell's `RETEX_UPDATE_REPO`. Never a built-in default.
    public var repo: String?
    public var checkAutomatically = true
    public var autoInstall = false
    public var autoChoiceRecorded = false
    public var skippedVersion: String?
    public var lastNotifiedVersion: String?
    public var lastNotifiedAt: Date?

    public init() {}

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        checkedAt = try values.decodeIfPresent(Date.self, forKey: .checkedAt)
        latestVersion = try values.decodeIfPresent(String.self, forKey: .latestVersion)
        checkError = try values.decodeIfPresent(String.self, forKey: .checkError)
        installError = try values.decodeIfPresent(String.self, forKey: .installError)
        repo = try values.decodeIfPresent(String.self, forKey: .repo)
        checkAutomatically = try values.decodeIfPresent(Bool.self, forKey: .checkAutomatically) ?? true
        autoInstall = try values.decodeIfPresent(Bool.self, forKey: .autoInstall) ?? false
        autoChoiceRecorded = try values.decodeIfPresent(Bool.self, forKey: .autoChoiceRecorded) ?? false
        skippedVersion = try values.decodeIfPresent(String.self, forKey: .skippedVersion)
        lastNotifiedVersion = try values.decodeIfPresent(String.self, forKey: .lastNotifiedVersion)
        lastNotifiedAt = try values.decodeIfPresent(Date.self, forKey: .lastNotifiedAt)
    }

    /// A check younger than a day is reused, whether it succeeded or failed.
    public func isFresh(now: Date) -> Bool {
        guard let checkedAt else { return false }
        return now >= checkedAt && now.timeIntervalSince(checkedAt) < Self.interval
    }

    /// At most one notice per version per day; a skipped version never
    /// notifies, a newer one does.
    public func shouldNotify(version: String, now: Date) -> Bool {
        guard checkAutomatically, skippedVersion != version else { return false }
        guard lastNotifiedVersion == version, let lastNotifiedAt else { return true }
        return now < lastNotifiedAt || now.timeIntervalSince(lastNotifiedAt) >= Self.interval
    }
}

public struct UpdateStateStore: Sendable {
    public let url: URL

    /// `RETEX_UPDATE_STATE` overrides the path for tests and drills; normal
    /// runs use the platform cache directory.
    public init(url: URL? = nil) {
        if let url {
            self.url = url.standardizedFileURL
        } else if let configured = ProcessInfo.processInfo.environment["RETEX_UPDATE_STATE"],
                  !configured.isEmpty {
            self.url = URL(fileURLWithPath: NSString(string: configured).expandingTildeInPath)
                .standardizedFileURL
        } else {
            let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.url = root.appendingPathComponent("retex/update-state.json", isDirectory: false)
        }
    }

    public func load() -> UpdateState {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              (values.fileSize ?? 0) <= 64 * 1024,
              let data = try? Data(contentsOf: url)
        else { return UpdateState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(UpdateState.self, from: data)) ?? UpdateState()
    }

    public func save(_ state: UpdateState) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: url, options: .atomic)
#if !os(Windows)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
#endif
    }

    /// Load, change and save in one step.
    @discardableResult
    public func update(_ change: (inout UpdateState) -> Void) throws -> UpdateState {
        var state = load()
        change(&state)
        try save(state)
        return state
    }

    public func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Scheduled update jobs share one bounded log file.
public enum UpdateLog {
    public static let limitBytes = 256 * 1024

    public static func url(root: URL? = nil) -> URL {
        let home = root ?? FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/retex/logs/retex-update.log", isDirectory: false)
    }

    /// Creates the log directory (0700) and the log file (0600) before the
    /// platform scheduler opens it, so the log, which can name vault paths,
    /// is never created readable by other users.
    public static func preparePrivate(url: URL) throws {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
#if os(Windows)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
#else
        try fm.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
#endif
    }

    /// Keeps the newest half of an oversized log and re-asserts owner-only
    /// modes. The file is truncated in place, so a job whose stdout/stderr
    /// already point at it keeps logging.
    public static func trim(url: URL, limitBytes: Int = limitBytes) {
#if !os(Windows)
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
#endif
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > limitBytes,
              let handle = try? FileHandle(forUpdating: url)
        else { return }
        defer { try? handle.close() }
        let keep = limitBytes / 2
        guard (try? handle.seek(toOffset: UInt64(size - keep))) != nil,
              let tail = try? handle.readToEnd()
        else { return }
        try? handle.truncate(atOffset: 0)
        try? handle.write(contentsOf: tail)
    }

    /// Removes the update log and the logs older releases wrote.
    public static func removeLogs(root: URL? = nil) {
        let directory = url(root: root).deletingLastPathComponent()
        for name in ["retex-update.log", "fleet-update.log", "fleet-update-error.log"] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}

/// One download directory per install, removed on success and on failure.
public enum UpdateWorkspace {
    public static func withTemporary<T>(body: (URL) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-update-\(UUID().uuidString)", isDirectory: true)
#if os(Windows)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
#else
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
#endif
        defer { try? FileManager.default.removeItem(at: directory) }
        return try body(directory)
    }
}
