#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Append-only undo journal at `<vault>/.retex/history.jsonl`.
/// Each mutation records the full previous file content so any change can be
/// reverted exactly. Entries are capped per file (oldest dropped) to bound
/// size. Cross-process safety: every read-modify-write holds an advisory lock
/// so an MCP server and CLI runs against the same vault never interleave
/// journal writes.
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

    /// Creates the vault-local state marker used to keep every future undo
    /// record at the vault root. Safe to call repeatedly.
    @discardableResult
    public static func prepare(for vault: Vault) throws -> URL {
        let stateDirectory = vault.url.standardizedFileURL
            .appendingPathComponent(".retex", isDirectory: true)
        let journalURL = stateDirectory.appendingPathComponent("history.jsonl")
        if (try? stateDirectory.resourceValues(
            forKeys: [.isSymbolicLinkKey]
        ).isSymbolicLink) == true {
            throw StoreError.historyUnwritable(journalURL)
        }
        do {
            #if os(Windows)
            try FileManager.default.createDirectory(
                at: stateDirectory,
                withIntermediateDirectories: true
            )
            #else
            try FileManager.default.createDirectory(
                at: stateDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: stateDirectory.path
            )
            #endif
            return stateDirectory
        } catch {
            throw StoreError.historyUnwritable(journalURL)
        }
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
    /// serializing read-modify-write cycles across processes. Undo state can
    /// contain complete client notes, so the state directory and files are
    /// always private to the current user.
    private func withJournalLock<R>(journalURL: URL, _ body: () throws -> R) throws -> R {
        let stateDirectory = journalURL.deletingLastPathComponent()
        _ = try Self.prepare(
            for: Vault(url: stateDirectory.deletingLastPathComponent())
        )

        #if os(Windows)
        let lockURL = URL(fileURLWithPath: journalURL.path + ".lockdir", isDirectory: true)
        var acquired = false
        for _ in 0..<500 where !acquired {
            do {
                try FileManager.default.createDirectory(at: lockURL, withIntermediateDirectories: false)
                acquired = true
            } catch {
                if let attributes = try? FileManager.default.attributesOfItem(atPath: lockURL.path),
                   let modifiedAt = attributes[.modificationDate] as? Date,
                   modifiedAt < Date().addingTimeInterval(-300) {
                    try? FileManager.default.removeItem(at: lockURL)
                } else {
                    Thread.sleep(forTimeInterval: 0.01)
                }
            }
        }
        guard acquired else { throw StoreError.historyUnwritable(journalURL) }
        defer { try? FileManager.default.removeItem(at: lockURL) }
        return try body()
        #else
        let lockPath = journalURL.path + ".lock"
        let fd = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw StoreError.historyUnwritable(journalURL) }
        defer {
            flock(fd, LOCK_UN)
            close(fd)
        }
        guard fchmod(fd, 0o600) == 0, flock(fd, LOCK_EX) == 0 else {
            throw StoreError.historyUnwritable(journalURL)
        }
        return try body()
        #endif
    }

    private func readEntries(from url: URL) throws -> [Entry] {
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw StoreError.historyUnwritable(url)
        }
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
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw StoreError.historyUnwritable(url)
        }
        let lines = entries.map { entry -> String in
            (try? JSONEncoder().encode(entry)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }.filter { !$0.isEmpty }
        let payload = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        guard let data = payload.data(using: .utf8) else {
            throw StoreError.historyUnwritable(url)
        }
        do {
            try data.write(to: url, options: .atomic)
            #if !os(Windows)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
            #endif
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

            // Keep only the newest `capacityPerFile` entries for this exact
            // path. Append while walking backward, then reverse once: inserting
            // at index zero makes large journals quadratic.
            var survivors: [Entry] = []
            survivors.reserveCapacity(entries.count)
            var countForPath = 0
            for existing in entries.reversed() {
                if existing.path == entry.path {
                    countForPath += 1
                    if countForPath > Self.capacityPerFile { continue }
                }
                survivors.append(existing)
            }
            survivors.reverse()
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
