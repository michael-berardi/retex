import Foundation

/// Append-only undo journal at `<vault>/.retex/history.jsonl`.
/// Each mutation records the full previous file content so any change can be
/// reverted exactly. Entries are capped per file (oldest dropped) to bound
/// size. Cross-process safety: every read-modify-write holds an advisory
/// `flock` on `<vault>/.retex/history.lock`, so an MCP server and CLI runs
/// against the same vault never interleave journal writes.
public struct UndoHistory: Sendable {
    public struct Entry: Sendable, Equatable, Codable {
        public let path: String
        public let previousSource: String
        public let timestamp: Date

        public init(path: String, previousSource: String, timestamp: Date = Date()) {
            self.path = path
            self.previousSource = previousSource
            self.timestamp = timestamp
        }
    }

    private static let capacityPerFile = 50
    private let lock = NSLock()

    public init() {}

    public static func journalURL(for vault: Vault) -> URL {
        vault.url.appendingPathComponent(".retex/history.jsonl")
    }

    private func journalURL(forPath path: String) -> URL {
        Self.journalURL(for: Vault(url: Self.vaultRoot(for: URL(fileURLWithPath: path))))
    }

    /// Resolves the owning vault for a note URL by walking up to the deepest
    /// ancestor containing a `.retex` marker; falls back to the note's parent.
    static func vaultRoot(for noteURL: URL) -> URL {
        var current = noteURL.deletingLastPathComponent().standardizedFileURL
        while current.pathComponents.count > 1 {
            if FileManager.default.fileExists(atPath: current.appendingPathComponent(".retex").path) {
                return current
            }
            current.deleteLastPathComponent()
        }
        return noteURL.deletingLastPathComponent().standardizedFileURL
    }

    /// Runs `body` holding an exclusive advisory lock on `<journal>.lock`,
    /// serializing read-modify-write cycles across processes.
    private func withJournalLock<R>(journalURL: URL, _ body: () throws -> R) rethrows -> R {
        try? FileManager.default.createDirectory(
            at: journalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let lockPath = journalURL.path + ".lock"
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return try body() }
        defer {
            flock(fd, LOCK_UN)
            close(fd)
        }
        flock(fd, LOCK_EX)
        return try body()
    }

    private func readEntries(from url: URL) throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let raw = try String(contentsOf: url, encoding: .utf8)
        var entries: [Entry] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let entry = try? JSONDecoder().decode(Entry.self, from: data)
            else {
                // A corrupt line must not silently truncate the rest of the journal.
                throw StoreError.corruptHistory(url)
            }
            entries.append(entry)
        }
        return entries
    }

    private func writeEntries(_ entries: [Entry], to url: URL) throws {
        let lines = entries.map { entry -> String in
            (try? JSONEncoder().encode(entry)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }.filter { !$0.isEmpty }
        let payload = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        guard let data = payload.data(using: .utf8) else {
            throw StoreError.historyUnwritable(url)
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw StoreError.historyUnwritable(url)
        }
    }

    public func record(_ entry: Entry) throws {
        lock.lock()
        defer { lock.unlock() }
        let url = journalURL(forPath: entry.path)
        try withJournalLock(journalURL: url) {
            var entries = try readEntries(from: url)
            entries.append(entry)

            // Keep only the newest `capacityPerFile` entries for this exact path.
            var survivors: [Entry] = []
            var countForPath = 0
            for existing in entries.reversed() {
                if existing.path == entry.path {
                    countForPath += 1
                    if countForPath > Self.capacityPerFile { continue }
                }
                survivors.insert(existing, at: 0)
            }
            try writeEntries(survivors, to: url)
        }
    }

    /// Pops the newest entry for the given file, returning its previous source.
    @discardableResult
    public func pop(path: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        let url = journalURL(forPath: path)
        return try withJournalLock(journalURL: url) {
            var entries = try readEntries(from: url)
            guard let index = entries.lastIndex(where: { $0.path == path }) else { return nil }
            let restored = entries.remove(at: index)
            try writeEntries(entries, to: url)
            return restored.previousSource
        }
    }

    /// History entries for one file, oldest first. Read-only (`retex log`).
    public func entries(for path: String) throws -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        let url = journalURL(forPath: path)
        return try withJournalLock(journalURL: url) {
            try readEntries(from: url).filter { $0.path == path }
        }
    }
}
