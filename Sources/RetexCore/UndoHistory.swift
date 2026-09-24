#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

/// Append-only undo journal at `<vault>/.retex/history.jsonl`.
/// Each mutation records the full previous file content so any change can be
/// reverted exactly. Entries are capped per file (oldest dropped) to bound
/// size. Cross-process safety: every read-modify-write holds an advisory lock
/// so an MCP server and CLI runs against the same vault never interleave
/// journal writes.
///
/// Mutations append one line instead of rewriting the journal, so their cost
/// no longer grows with journal size. The per-file cap applies to every read
/// immediately and is enforced on disk by compaction whenever the journal
/// crosses a power-of-two size (amortized), and by `pop`.
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
        let raw = try Data(contentsOf: url)
        let lines = raw.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        let decoder = JSONDecoder()
        var entries: [Entry] = []
        entries.reserveCapacity(lines.count)
        for (index, line) in lines.enumerated() {
            guard let entry = try? decoder.decode(Entry.self, from: line) else {
                // An append interrupted by a crash leaves an unterminated
                // final line; that torn write is the only line skipped.
                if index == lines.count - 1, raw.last != UInt8(ascii: "\n") { break }
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
            let append = try appendEntry(entry, to: url)
            compactIfNeeded(url, previousSize: append.previousSize, newSize: append.newSize)
        }
    }

    /// Serializes a note mutation with its undo journal across Retex processes.
    /// `prepare` runs after the lock is acquired so expected-hash checks and
    /// writes form one compare-and-set operation for cooperating clients.
    func performMutation(
        path: String,
        prepare: () throws -> (previousSource: String, nextSource: String)
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        let journalURL = journalURL(forPath: path)
        try withJournalLock(journalURL: journalURL) {
            let change = try prepare()
            let entry = Entry(path: path, previousSource: change.previousSource)
            let append = try appendEntry(entry, to: journalURL)
            do {
                try change.nextSource.write(
                    to: URL(fileURLWithPath: path),
                    atomically: true,
                    encoding: .utf8
                )
            } catch {
                try? truncateJournal(journalURL, to: append.previousSize)
                throw error
            }
            compactIfNeeded(journalURL, previousSize: append.previousSize, newSize: append.newSize)
        }
    }

    /// Appends one JSON line with private permissions. A torn final line from
    /// an interrupted earlier append is truncated first: its note write never
    /// happened, and keeping it would corrupt the middle of the journal.
    private func appendEntry(_ entry: Entry, to url: URL) throws -> (previousSize: UInt64, newSize: UInt64) {
        guard var line = try? JSONEncoder().encode(entry) else {
            throw StoreError.historyUnwritable(url)
        }
        line.append(UInt8(ascii: "\n"))
        #if os(Windows)
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw StoreError.historyUnwritable(url)
        }
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forUpdating: url)
            defer { try? handle.close() }
            var previousSize = try handle.seekToEnd()
            // Find the end of the last complete line.
            while previousSize > 0 {
                try handle.seek(toOffset: previousSize - 1)
                if try handle.read(upToCount: 1) == Data([UInt8(ascii: "\n")]) { break }
                previousSize -= 1
            }
            try handle.truncate(atOffset: previousSize)
            try handle.seek(toOffset: previousSize)
            try handle.write(contentsOf: line)
            return (previousSize, previousSize + UInt64(line.count))
        } catch {
            throw StoreError.historyUnwritable(url)
        }
        #else
        let fd = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw StoreError.historyUnwritable(url) }
        defer { close(fd) }
        var end = lseek(fd, 0, SEEK_END)
        guard end >= 0, fchmod(fd, 0o600) == 0 else { throw StoreError.historyUnwritable(url) }
        // Find the end of the last complete line, scanning back in blocks.
        var block = [UInt8](repeating: 0, count: 4096)
        var complete = end
        scan: while complete > 0 {
            let start = max(0, complete - off_t(block.count))
            let count = Int(complete - start)
            guard pread(fd, &block, count, start) == count else { throw StoreError.historyUnwritable(url) }
            for index in stride(from: count - 1, through: 0, by: -1) {
                if block[index] == UInt8(ascii: "\n") { break scan }
                complete -= 1
            }
        }
        if complete != end {
            guard ftruncate(fd, complete) == 0 else { throw StoreError.historyUnwritable(url) }
            end = complete
        }
        let written = line.withUnsafeBytes { bytes -> Int in
            var offset = 0
            while offset < bytes.count {
                let count = pwrite(fd, bytes.baseAddress! + offset, bytes.count - offset, end + off_t(offset))
                if count < 0 {
                    if errno == EINTR { continue }
                    return -1
                }
                offset += count
            }
            return offset
        }
        guard written == line.count else {
            _ = ftruncate(fd, end)
            throw StoreError.historyUnwritable(url)
        }
        return (UInt64(end), UInt64(end) + UInt64(line.count))
        #endif
    }

    private func truncateJournal(_ url: URL, to size: UInt64) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: size)
    }

    /// Rewrites the journal with per-file caps applied once it crosses a
    /// power-of-two size of at least 1 MiB, bounding amortized cost. A journal
    /// that cannot be read is left untouched for `retex doctor` to report.
    private func compactIfNeeded(_ url: URL, previousSize: UInt64, newSize: UInt64) {
        guard newSize >= Self.compactionFloor,
              previousSize.leadingZeroBitCount != newSize.leadingZeroBitCount,
              let entries = try? readEntries(from: url)
        else { return }
        let capped = Self.capped(entries)
        if capped.count < entries.count {
            try? writeEntries(capped, to: url)
        }
    }

    private static let compactionFloor: UInt64 = 1 << 20

    /// Keeps only the newest `capacityPerFile` entries for each path.
    private static func capped(_ entries: [Entry]) -> [Entry] {
        var survivors: [Entry] = []
        survivors.reserveCapacity(entries.count)
        var counts: [String: Int] = [:]
        for existing in entries.reversed() {
            counts[existing.path, default: 0] += 1
            if counts[existing.path]! > capacityPerFile { continue }
            survivors.append(existing)
        }
        survivors.reverse()
        return survivors
    }

    /// Pops the newest entry for the given file, returning its previous source.
    @discardableResult
    public func pop(path: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        let url = journalURL(forPath: path)
        return try withJournalLock(journalURL: url) {
            var entries = Self.capped(try readEntries(from: url))
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
            Self.capped(try readEntries(from: url)).filter { $0.path == path }
        }
    }
}
