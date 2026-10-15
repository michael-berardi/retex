#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import CSQLite
import Crypto
import Foundation

/// Disposable SQLite query index. Markdown stays the only source of truth:
/// the index lives outside the vault, is rebuilt from the files on demand,
/// and is validated against file stats before every read, so deleting it
/// never changes results. It replaces per-command file reads and front-matter
/// parsing with one stat walk plus indexed lookups.
public final class NoteIndex: @unchecked Sendable {
    /// Bumped whenever the stored shape or the parser semantics change.
    static let schemaVersion = "3"
    /// Files modified this close to the last index pass are re-read even when
    /// their stats match (the racy-clean window git also guards against).
    static let racyWindowNanoseconds: Int64 = 2_000_000_000

    public struct RefreshStats: Sendable, Equatable {
        public var files = 0
        public var reparsed = 0
        public var removed = 0
        public var unreadable: [String] = []
    }

    /// A raw index row; `note()` materializes it (JSON decoding included),
    /// so callers verify the cheap byte match before paying for that.
    struct Candidate: @unchecked Sendable {
        let path: String
        let source: String
        let title: String
        let body: String?
        let bodyRange: Range<Int>
        let metadata: String
        let tags: String
        let modifiedAt: Double
        let foldedFields: String
        let foldedBody: String

        var url: URL { URL(fileURLWithPath: path) }

        func folded() -> FoldedNote {
            let object = (try? JSONSerialization.jsonObject(with: Data(foldedFields.utf8))) as? [String: Any] ?? [:]
            return FoldedNote(
                title: object["title"] as? String ?? "",
                filename: object["filename"] as? String ?? "",
                path: object["path"] as? String ?? "",
                tags: object["tags"] as? [String] ?? [],
                metadata: object["metadata"] as? [[String]] ?? [],
                body: foldedBody
            )
        }

        func note() -> Note {
            let metadata = (try? JSONSerialization.jsonObject(with: Data(metadata.utf8))) as? [String: String] ?? [:]
            let tags = (try? JSONSerialization.jsonObject(with: Data(tags.utf8))) as? [String] ?? []
            var body = self.body
            if body == nil {
                var source = source
                body = source.withUTF8 { bytes in
                    String(decoding: UnsafeBufferPointer(rebasing: bytes[bodyRange]), as: UTF8.self)
                }
            }
            return Note(
                url: url,
                source: source,
                title: title,
                body: body ?? "",
                metadata: metadata,
                tags: tags,
                modifiedAt: Date(timeIntervalSince1970: modifiedAt)
            )
        }
    }

    /// Maps rows in parallel above a few hundred, preserving order.
    static func parallelMap<T: Sendable>(_ rows: [Candidate], _ transform: @escaping @Sendable (Candidate) -> T?) -> [T] {
        var output = [T?](repeating: nil, count: rows.count)
        let count = rows.count
        output.withUnsafeMutableBufferPointer { buffer in
            let box = UnsafeSendable(buffer)
            let input = UnsafeSendable(rows)
            if count < 300 {
                for index in 0..<count { box.value[index] = transform(input.value[index]) }
            } else {
                let chunk = 64
                DispatchQueue.concurrentPerform(iterations: (count + chunk - 1) / chunk) { part in
                    for index in (part * chunk)..<min((part + 1) * chunk, count) {
                        box.value[index] = transform(input.value[index])
                    }
                }
            }
        }
        return output.compactMap { $0 }
    }

    public let vault: Vault
    public let location: URL
    private let db: OpaquePointer

    /// The index is opt-in while it is evaluated: `RETEX_INDEX=sqlite`.
    public static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["RETEX_INDEX"]?.lowercased() == "sqlite"
    }

    /// `$RETEX_INDEX_DIR`, else the platform cache directory. Never inside
    /// the vault: indexing must not dirty a synced or versioned folder.
    public static func defaultLocation(for vault: Vault) -> URL {
        let environment = ProcessInfo.processInfo.environment
        let base: URL
        if let override = environment["RETEX_INDEX_DIR"], !override.isEmpty {
            base = URL(fileURLWithPath: override, isDirectory: true)
        } else if let xdg = environment["XDG_CACHE_HOME"], !xdg.isEmpty {
            base = URL(fileURLWithPath: xdg, isDirectory: true).appendingPathComponent("retex/index")
        } else {
            #if canImport(Darwin)
            base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches/retex/index", isDirectory: true)
            #else
            base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache/retex/index", isDirectory: true)
            #endif
        }
        let key = SHA256.hash(data: Data(vault.url.standardizedFileURL.path.utf8))
            .prefix(12).map { String(format: "%02x", $0) }.joined()
        return base.appendingPathComponent("\(key).sqlite")
    }

    public init(vault: Vault, location: URL? = nil) throws {
        self.vault = vault
        self.location = location ?? Self.defaultLocation(for: vault)
        try FileManager.default.createDirectory(
            at: self.location.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(self.location.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            sqlite3_close(handle)
            throw IndexError.open(self.location, message)
        }
        db = handle
        sqlite3_busy_timeout(db, 10_000)
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA temp_store=MEMORY;")
        try migrate()
    }

    deinit { sqlite3_close_v2(db) }

    // MARK: Schema

    private func migrate() throws {
        try exec("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        let identity = "\(Self.schemaVersion)|\(RetexVersion.version)|\(vault.url.standardizedFileURL.path)"
        if try metaValue("identity") == identity { return }
        // Unknown or older shape: the index is disposable, so rebuild.
        try exec("""
        BEGIN IMMEDIATE;
        DROP TABLE IF EXISTS notes_fts;
        DROP TABLE IF EXISTS notes;
        CREATE TABLE notes(
            id INTEGER PRIMARY KEY,
            path TEXT NOT NULL UNIQUE,
            size INTEGER NOT NULL,
            mtime_ns INTEGER NOT NULL,
            ctime_ns INTEGER NOT NULL,
            inode INTEGER NOT NULL,
            lmtime_ns INTEGER NOT NULL,
            indexed_ns INTEGER NOT NULL,
            valid INTEGER NOT NULL,
            filename TEXT NOT NULL DEFAULT '',
            source TEXT NOT NULL DEFAULT '',
            title TEXT NOT NULL DEFAULT '',
            body TEXT,
            body_start INTEGER NOT NULL DEFAULT 0,
            body_end INTEGER NOT NULL DEFAULT 0,
            metadata TEXT NOT NULL DEFAULT '{}',
            tags TEXT NOT NULL DEFAULT '[]',
            modified_at REAL NOT NULL DEFAULT 0,
            record_type TEXT NOT NULL DEFAULT 'note',
            folded TEXT NOT NULL DEFAULT '{}',
            folded_body TEXT NOT NULL DEFAULT '',
            archived INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX notes_type ON notes(record_type);
        CREATE VIRTUAL TABLE notes_fts USING fts5(
            text, content='', contentless_delete=1,
            tokenize='trigram', detail=none
        );
        INSERT OR REPLACE INTO meta(key, value) VALUES('identity', '\(identity.replacingOccurrences(of: "'", with: "''"))');
        COMMIT;
        """)
    }

    // MARK: Refresh

    private struct FileStat: Equatable {
        let size: Int64
        let mtime: Int64
        let ctime: Int64
        let inode: Int64
        let lmtime: Int64
    }

    private struct Stored {
        let id: Int64
        let stat: FileStat
        let indexed: Int64
        let valid: Bool
    }

    /// Brings the index in line with the vault: one directory walk and one
    /// stat per file; only new, changed, or racily-clean files are read.
    @discardableResult
    public func refresh() throws -> RefreshStats {
        // Measurement only: the ceiling a watcher-backed index could reach.
        if ProcessInfo.processInfo.environment["RETEX_INDEX_ASSUME_FRESH"] == "1" { return RefreshStats() }
        let trace = ProcessInfo.processInfo.environment["RETEX_INDEX_TRACE"] != nil
        var mark = DispatchTime.now().uptimeNanoseconds
        func lap(_ label: String) {
            guard trace else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            FileHandle.standardError.write(Data("index \(label): \((now - mark) / 1_000_000) ms\n".utf8))
            mark = now
        }
        defer { lap("tail") }
        let root = vault.url.standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { throw StoreError.unreadableVault(root) }

        var stats = RefreshStats()
        var seen: [(String, FileStat?)] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "md" {
            seen.append((url.path, Self.fileStat(url.path)))
        }
        stats.files = seen.count
        lap("walk+stat \(seen.count)")

        var stored: [String: Stored] = [:]
        stored.reserveCapacity(seen.count)
        try query("SELECT id, path, size, mtime_ns, ctime_ns, inode, lmtime_ns, indexed_ns, valid FROM notes") { row in
            let path = row.text(1)
            stored[path] = Stored(
                id: row.int(0),
                stat: FileStat(size: row.int(2), mtime: row.int(3), ctime: row.int(4), inode: row.int(5), lmtime: row.int(6)),
                indexed: row.int(7),
                valid: row.int(8) != 0
            )
        }

        var changed: [(path: String, stat: FileStat)] = []
        var unreadable: [String] = []
        var seenPaths = Set<String>()
        seenPaths.reserveCapacity(seen.count)
        for (path, stat) in seen {
            seenPaths.insert(path)
            guard let stat else { unreadable.append(path); continue }
            if let existing = stored[path], existing.stat == stat,
               stat.mtime < existing.indexed - Self.racyWindowNanoseconds,
               stat.lmtime < existing.indexed - Self.racyWindowNanoseconds {
                if !existing.valid { unreadable.append(path) }
                continue
            }
            changed.append((path, stat))
        }
        lap("load-stored \(stored.count)")
        // Rows for deleted files, and for entries that can no longer be stat'ed.
        let statFailed = Set(unreadable)
        let removed = stored.filter { !seenPaths.contains($0.key) || statFailed.contains($0.key) }

        // Parse outside the write transaction, in parallel for big batches.
        let store = UnsafeSendable(MarkdownStore())
        let count = changed.count
        var parsed = [Note?](repeating: nil, count: changed.count)
        parsed.withUnsafeMutableBufferPointer { buffer in
            let box = UnsafeSendable(buffer)
            let work = UnsafeSendable(changed)
            let parse: @Sendable (Int) -> Void = { index in
                box.value[index] = try? store.value.load(URL(fileURLWithPath: work.value[index].path))
            }
            if changed.count < 200 {
                for index in changed.indices { parse(index) }
            } else {
                let chunk = 64
                DispatchQueue.concurrentPerform(iterations: (count + chunk - 1) / chunk) { part in
                    for index in (part * chunk)..<min((part + 1) * chunk, count) { parse(index) }
                }
            }
        }

        lap("parse \(changed.count)")
        if changed.isEmpty && removed.isEmpty {
            stats.unreadable = unreadable.sorted()
            return stats
        }

        let now = Self.nowNanoseconds()
        try exec("BEGIN IMMEDIATE")
        do {
            // Keyed by path inside the write lock: another process may have
            // refreshed the same files since this one read the table.
            for path in removed.keys {
                try deleteRow(path: path)
            }
            stats.removed = removed.count
            for (index, item) in changed.enumerated() {
                try deleteRow(path: item.path)
                try insert(path: item.path, stat: item.stat, note: parsed[index], indexed: now)
                if parsed[index] == nil { unreadable.append(item.path) }
            }
            stats.reparsed = changed.count
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        stats.unreadable = unreadable.sorted()
        return stats
    }

    private func deleteRow(path: String) throws {
        try run("DELETE FROM notes_fts WHERE rowid IN (SELECT id FROM notes WHERE path = ?)", .text(path))
        try run("DELETE FROM notes WHERE path = ?", .text(path))
    }

    private func insert(path: String, stat: FileStat, note: Note?, indexed: Int64) throws {
        guard let note else {
            try run(
                "INSERT INTO notes(path, size, mtime_ns, ctime_ns, inode, lmtime_ns, indexed_ns, valid) VALUES(?,?,?,?,?,?,?,0)",
                .text(path), .int(stat.size), .int(stat.mtime), .int(stat.ctime), .int(stat.inode), .int(stat.lmtime), .int(indexed)
            )
            return
        }
        let filename = note.url.deletingPathExtension().lastPathComponent
        let folded = FoldedNote(note)
        let foldedFields = String(decoding: try JSONSerialization.data(withJSONObject: [
            "title": folded.title, "filename": folded.filename, "path": folded.path,
            "tags": folded.tags, "metadata": folded.metadata,
        ]), as: UTF8.self)
        let metadata = String(decoding: try JSONSerialization.data(withJSONObject: note.metadata, options: [.sortedKeys]), as: UTF8.self)
        let tags = String(decoding: try JSONSerialization.data(withJSONObject: note.tags), as: UTF8.self)
        // The body is nearly always a byte range of the source; store the
        // range instead of a second copy, and the text only when it differs.
        let range = Self.bodyRange(of: note)
        try run(
            """
            INSERT INTO notes(path, size, mtime_ns, ctime_ns, inode, lmtime_ns, indexed_ns, valid,
                filename, source, title, body, body_start, body_end, metadata, tags, modified_at, record_type, archived,
                folded, folded_body)
            VALUES(?,?,?,?,?,?,?,1,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """,
            .text(path), .int(stat.size), .int(stat.mtime), .int(stat.ctime), .int(stat.inode), .int(stat.lmtime),
            .int(indexed), .text(filename), .text(note.source), .text(note.title),
            range == nil ? .text(note.body) : .null, .int(Int64(range?.lowerBound ?? 0)), .int(Int64(range?.upperBound ?? 0)),
            .text(metadata), .text(tags), .double(note.modifiedAt.timeIntervalSince1970),
            .text(note.recordType.lowercased()), .int(note.isArchived ? 1 : 0),
            .text(foldedFields), .text(folded.body)
        )
        // The exact matcher folds case and diacritics with Foundation, so the
        // trigram index holds Foundation-folded text and queries fold terms
        // the same way. Filename and source are both searchable.
        try run(
            "INSERT INTO notes_fts(rowid, text) VALUES(last_insert_rowid(), ?)",
            .text(folded.filename + "\n" + MarkdownStore.foldedForRanking(note.source))
        )
    }

    /// UTF-8 offsets of the body within the source, when it is a verbatim
    /// slice (no CRLF normalization happened).
    static func bodyRange(of note: Note) -> Range<Int>? {
        let source = Array(note.source.utf8)
        let body = Array(note.body.utf8)
        if body.isEmpty { return 0..<0 }
        var end = source.count
        while end > 0 {
            let byte = source[end - 1]
            guard byte == 0x20 || byte == 0x0A || byte == 0x09 || byte == 0x0D || byte == 0x0B || byte == 0x0C else { break }
            end -= 1
        }
        let start = end - body.count
        guard start >= 0, source[start..<end].elementsEqual(body) else { return nil }
        return start..<end
    }

    // MARK: Reads

    /// Every indexed note, unsorted. Call `refresh()` first.
    func allNotes() throws -> [Note] {
        Self.parallelMap(try rows("SELECT \(Self.columns) FROM notes n WHERE n.valid = 1", [])) { $0.note() }
    }

    /// Notes that may contain every term (`all`) or any term. The result is a
    /// superset of the true matches: trigram hits on folded text for terms
    /// that fold to three or more ASCII bytes, otherwise every note. Callers
    /// apply the exact matcher.
    func candidates(terms: [String], requireAll: Bool) throws -> [Candidate] {
        let eligible = terms.map(MarkdownStore.foldedForRanking).filter { term in
            term.utf8.count >= 3 && term.utf8.allSatisfy { $0 >= 0x20 && $0 < 0x80 }
        }
        let sql: String
        var bindings: [Binding] = []
        // All-terms search: dropping an ineligible term only widens the set.
        // Any-term recall: one ineligible term means any note could match.
        let usable = requireAll ? !eligible.isEmpty : (!eligible.isEmpty && eligible.count == terms.count)
        if usable {
            // detail=none keeps the index small but has no phrase queries, so
            // each term becomes the AND of its trigrams (still a superset).
            let expression = eligible.map { term -> String in
                let bytes = Array(term.utf8)
                let grams = Set((0...(bytes.count - 3)).map { String(decoding: bytes[$0..<($0 + 3)], as: UTF8.self) })
                return "(" + grams.sorted().map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
                    .joined(separator: " AND ") + ")"
            }.joined(separator: requireAll ? " AND " : " OR ")
            sql = """
            SELECT \(Self.columns) FROM notes n WHERE n.valid = 1 AND
                n.id IN (SELECT rowid FROM notes_fts WHERE notes_fts MATCH ?)
            """
            bindings = [.text(expression)]
        } else {
            sql = "SELECT \(Self.columns) FROM notes n WHERE n.valid = 1"
        }
        return try rows(sql, bindings)
    }

    private static let columns = "n.path, n.source, n.title, n.body, n.body_start, n.body_end, n.metadata, n.tags, n.modified_at, n.folded, n.folded_body"

    private func rows(_ sql: String, _ bindings: [Binding]) throws -> [Candidate] {
        var results: [Candidate] = []
        try query(sql, bindings) { row in
            let isNull = sqlite3_column_type(row.statement, 3) == SQLITE_NULL
            results.append(Candidate(
                path: row.text(0),
                source: row.text(1),
                title: row.text(2),
                body: isNull ? nil : row.text(3),
                bodyRange: Int(row.int(4))..<Int(row.int(5)),
                metadata: row.text(6),
                tags: row.text(7),
                modifiedAt: row.double(8),
                foldedFields: row.text(9),
                foldedBody: row.text(10)
            ))
        }
        return results
    }

    // MARK: SQLite plumbing

    enum Binding {
        case int(Int64)
        case double(Double)
        case text(String)
        case null
    }

    struct Row {
        let statement: OpaquePointer
        func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
        func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
        func text(_ column: Int32) -> String {
            guard let pointer = sqlite3_column_text(statement, column) else { return "" }
            let count = Int(sqlite3_column_bytes(statement, column))
            return String(decoding: UnsafeBufferPointer(start: pointer, count: count), as: UTF8.self)
        }
        func data(_ column: Int32) -> Data {
            guard let pointer = sqlite3_column_blob(statement, column) else { return Data() }
            return Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, column)))
        }
    }

    private func error(_ context: String) -> IndexError {
        .sqlite(location, context, String(cString: sqlite3_errmsg(db)))
    }

    private func exec(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(message)
            throw IndexError.sqlite(location, String(sql.prefix(60)), text)
        }
    }

    private func prepare(_ sql: String, _ bindings: [Binding]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw error(String(sql.prefix(60)))
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch binding {
            case .int(let value): sqlite3_bind_int64(statement, index, value)
            case .double(let value): sqlite3_bind_double(statement, index, value)
            case .text(let value): sqlite3_bind_text(statement, index, value, -1, transient)
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }

    private func run(_ sql: String, _ bindings: Binding...) throws {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error(String(sql.prefix(60))) }
    }

    private func query(_ sql: String, _ bindings: [Binding] = [], _ visit: (Row) throws -> Void) throws {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return }
            guard code == SQLITE_ROW else { throw error(String(sql.prefix(60))) }
            try visit(Row(statement: statement))
        }
    }

    private func metaValue(_ key: String) throws -> String? {
        var value: String?
        try query("SELECT value FROM meta WHERE key = ?", [.text(key)]) { value = $0.text(0) }
        return value
    }

    private static func fileStat(_ path: String) -> FileStat? {
        var target = Self.StatInfo()
        var link = Self.StatInfo()
        guard fstatat(AT_FDCWD, path, &target, 0) == 0,
              fstatat(AT_FDCWD, path, &link, AT_SYMLINK_NOFOLLOW) == 0
        else { return nil }
        return FileStat(
            size: Int64(target.st_size),
            mtime: nanoseconds(Self.mtime(target)),
            ctime: nanoseconds(Self.ctime(target)),
            inode: Int64(bitPattern: UInt64(target.st_ino)),
            lmtime: nanoseconds(Self.mtime(link))
        )
    }

    private static func nanoseconds(_ time: timespec) -> Int64 {
        Int64(time.tv_sec) * 1_000_000_000 + Int64(time.tv_nsec)
    }

    private static func nowNanoseconds() -> Int64 {
        var time = timespec()
        clock_gettime(CLOCK_REALTIME, &time)
        return nanoseconds(time)
    }

    #if canImport(Darwin)
    typealias StatInfo = Darwin.stat
    private static func mtime(_ info: StatInfo) -> timespec { info.st_mtimespec }
    private static func ctime(_ info: StatInfo) -> timespec { info.st_ctimespec }
    #else
    typealias StatInfo = Glibc.stat
    private static func mtime(_ info: StatInfo) -> timespec { info.st_mtim }
    private static func ctime(_ info: StatInfo) -> timespec { info.st_ctim }
    #endif
}

private final class UnsafeSendable<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

public enum IndexError: LocalizedError {
    case open(URL, String)
    case sqlite(URL, String, String)

    public var errorDescription: String? {
        switch self {
        case .open(let url, let message): "Retex could not open its query index at \(url.path): \(message)."
        case .sqlite(let url, let context, let message):
            "Retex query index \(url.path) failed (\(context)): \(message)."
        }
    }
}
