#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
#if os(macOS)
import CoreServices
#endif
import Foundation

/// In-memory parsed-vault snapshots for long-running processes (`retex mcp`).
///
/// Markdown stays the source of truth. A snapshot is reused only while the
/// files are known to be unchanged:
///
/// - On macOS a raw FSEvents stream marks changed paths. FSEvents delivers
///   events about 10 ms after a write, so each request first creates a
///   barrier file in a private directory watched by the same stream and waits
///   for its event. Events arrive in order, so every write that finished
///   before the request has been seen by then. Changed known files are
///   re-read; creates, deletes, renames and directory changes re-walk.
/// - A barrier that has not arrived within 40 ms falls back to a fingerprint
///   walk for that request; three late barriers in a row, or a walk that
///   finds a change no event reported, switch events off for the process
///   (reported on stderr).
/// - Symlinked notes are re-checked by stat on every request, because edits
///   to a target outside the vault produce no event inside it.
/// - Without file events (Linux, Windows, a vault on another volume, or a
///   failed stream) every request walks and stats the vault; only changed
///   files are parsed again.
public final class VaultSnapshotCache: @unchecked Sendable {
    /// Files modified this close to their load are re-read on the next walk
    /// even when their stats match (git's racy-clean rule).
    static let racyWindowNanoseconds: Int64 = 2_000_000_000

    private let revalidateInterval: TimeInterval
    private let useFileEvents: Bool
    /// `RETEX_CACHE_TRACE=1` prints how each snapshot was served to stderr.
    private let trace = ProcessInfo.processInfo.environment["RETEX_CACHE_TRACE"] == "1"
    private let lock = NSLock()
    private var vaults: [String: VaultState] = [:]

    /// - Parameters:
    ///   - revalidateInterval: longest time between full fingerprint walks.
    ///   - useFileEvents: false walks the vault on every request.
    public init(revalidateInterval: TimeInterval = 60, useFileEvents: Bool = true) {
        self.revalidateInterval = revalidateInterval
        self.useFileEvents = useFileEvents
    }

    /// One parsed note plus the facts needed to reuse and match it.
    final class Entry: @unchecked Sendable {
        let note: Note
        let fingerprint: Fingerprint
        let loadedAt: Int64
        let isSymlink: Bool
        let text: RawNoteText
        /// Keys other notes' `[[links]]` resolve to this note by.
        let linkKeys: Set<String>
        /// Every lookup key of this note's own `[[links]]`.
        let outgoingLookupKeys: Set<String>
        /// A regular Markdown file lexically under the vault root: confined
        /// without resolving symlinks.
        let confinedByPath: Bool

        init(note: Note, fingerprint: Fingerprint, loadedAt: Int64, root: URL) {
            self.note = note
            self.fingerprint = fingerprint
            self.loadedAt = loadedAt
            isSymlink = fingerprint.isSymlink
            text = RawNoteText(note: note)
            linkKeys = MarkdownStore.linkKeys(note, root: root)
            outgoingLookupKeys = Set(MarkdownStore.wikiLinks(in: note.source).flatMap(MarkdownStore.lookupKeys))
            let path = note.url.path
            let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
            confinedByPath = !fingerprint.isSymlink && path.hasPrefix(rootPath) && !path.contains("/../")
                && note.url.pathExtension.lowercased() == "md"
        }

        var isRacy: Bool {
            fingerprint.mtime >= loadedAt - VaultSnapshotCache.racyWindowNanoseconds
                || fingerprint.lmtime >= loadedAt - VaultSnapshotCache.racyWindowNanoseconds
        }
    }

    struct Fingerprint: Equatable {
        let size: Int64
        let mtime: Int64
        let ctime: Int64
        let inode: Int64
        let lmtime: Int64
        let isSymlink: Bool
    }

    /// A consistent view of one vault: entries sorted like a scan.
    struct Snapshot {
        let entries: [Entry]
        let unreadable: [String]
        var notes: [Note] { entries.map(\.note) }
    }

    private final class VaultState {
        let root: URL
        init(root: URL) { self.root = root }
        var entries: [String: Entry] = [:]
        var sorted: [Entry]?
        var unreadable: [String] = []
        var loaded = false
        var lastFullCheck: Date = .distantPast
        var eventsTrusted = false
        var warned = false
        /// Set by `invalidate`: the next walk is deliberate, not a check of
        /// whether events were missed.
        var forceWalk = false
        #if os(macOS)
        var stream: FSEventStreamRef?
        var events: EventSink?
        var barrierDirectory: URL?
        var barrierSequence = 0
        var lateBarriers = 0
        #endif
    }

    // MARK: Public surface

    /// Forget the cached state of one vault (or all) so the next request
    /// re-walks it. Mutations made through this process call this.
    public func invalidate(_ vault: Vault? = nil) {
        lock.lock()
        defer { lock.unlock() }
        let states = vault.map { [vaults[Self.key($0)]].compactMap { $0 } } ?? Array(vaults.values)
        for state in states { state.forceWalk = true }
    }

    deinit {
        #if os(macOS)
        for state in vaults.values { Self.stopStream(state) }
        #endif
    }

    // MARK: Snapshots

    /// Notes of the vault for MCP listing: entries that are not symlinks and
    /// sit lexically under the root are confined by construction; the rest
    /// go through `confined`.
    func confinedNotes(_ vault: Vault, confined: (Note) -> Bool) throws -> [Note] {
        try snapshot(vault).entries.compactMap { entry in
            entry.confinedByPath || confined(entry.note) ? entry.note : nil
        }
    }

    func snapshot(_ vault: Vault) throws -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        let started = DispatchTime.now().uptimeNanoseconds
        var mode = "events"
        let key = Self.key(vault)
        let state = vaults[key] ?? {
            let created = VaultState(root: vault.url.standardizedFileURL)
            vaults[key] = created
            return created
        }()
        let root = vault.url.standardizedFileURL

        #if os(macOS)
        // Events must be flowing before the first walk, or a change made
        // during it could go unreported.
        if useFileEvents, state.stream == nil, !state.loaded {
            startStream(state, root: root)
        }
        let pending = awaitEvents(state, root: root)
        #else
        let pending = PendingChanges(paths: [], needsWalk: true)
        #endif

        let waited = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        let now = Date()
        let timerDue = now.timeIntervalSince(state.lastFullCheck) >= revalidateInterval
        var needsWalk = !state.loaded || !state.eventsTrusted || pending.needsWalk || timerDue || state.forceWalk

        if !needsWalk {
            // Changed files that are already known: re-read just those.
            for path in pending.paths {
                guard let entryKey = entryKey(forEventPath: path, state: state, root: root) else {
                    needsWalk = true
                    break
                }
                guard try reload(entryKey, state: state) else {
                    needsWalk = true
                    break
                }
            }
        }
        if !needsWalk {
            // Symlink targets can change without an event inside the vault.
            for (entryKey, entry) in state.entries where entry.isSymlink {
                if Self.fingerprint(entryKey) != entry.fingerprint {
                    guard try reload(entryKey, state: state) else {
                        needsWalk = true
                        break
                    }
                }
            }
        }
        if needsWalk {
            mode = "walk"
            let reported = Set(pending.paths)
            let changed = try walk(state, root: root)
            #if os(macOS)
            // A timer-driven walk that finds changes no event reported means
            // the event stream cannot be trusted (a stalled fseventsd does
            // exactly this). Changes reported while walking are not misses.
            if state.loaded, state.eventsTrusted, timerDue, !state.forceWalk, !pending.needsWalk {
                let late = awaitEvents(state, root: root)
                let known = reported.union(late.paths).compactMap { entryKey(forEventPath: $0, state: state, root: root) }
                let missed = changed.subtracting(known)
                if !late.needsWalk, !missed.isEmpty {
                    state.eventsTrusted = false
                    if !state.warned {
                        state.warned = true
                        FileHandle.standardError.write(Data(
                            "retex: file events missed \(missed.count) change(s) in \(root.path) (first: \(missed.sorted()[0])); checking every file on each request from now on\n".utf8
                        ))
                    }
                }
            }
            #endif
            state.loaded = true
            state.forceWalk = false
            state.lastFullCheck = now
        }

        if state.sorted == nil {
            state.sorted = state.entries.values.sorted { MarkdownStore.precedes($0.note, $1.note) }
        }
        if trace {
            let total = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            FileHandle.standardError.write(Data(
                "retex cache: \(mode) \(state.entries.count) notes, \(pending.paths.count) changed, events wait \(waited) ms, total \(total) ms\n".utf8
            ))
        }
        return Snapshot(entries: state.sorted!, unreadable: state.unreadable)
    }

    /// Re-reads one known file. Returns false when the file is gone or
    /// unreadable, so the caller re-walks to settle membership.
    private func reload(_ entryKey: String, state: VaultState) throws -> Bool {
        guard let fingerprint = Self.fingerprint(entryKey) else { return false }
        if let existing = state.entries[entryKey], existing.fingerprint == fingerprint, !existing.isRacy {
            return true
        }
        let loadedAt = Self.nowNanoseconds()
        guard let note = try? MarkdownStore().load(URL(fileURLWithPath: entryKey)) else { return false }
        state.entries[entryKey] = Entry(note: note, fingerprint: fingerprint, loadedAt: loadedAt, root: state.root)
        state.sorted = nil
        return true
    }

    /// Full walk with the same enumeration rules as a scan. Unchanged files
    /// keep their parsed entry. Returns the keys that were added, changed or
    /// removed.
    private func walk(_ state: VaultState, root: URL) throws -> Set<String> {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw StoreError.unreadableVault(root)
        }
        var paths: [String] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "md" {
            paths.append(url.path)
        }

        var changed = Set<String>()
        var unreadable: [String] = []
        var next: [String: Entry] = [:]
        next.reserveCapacity(paths.count)
        var toLoad: [(path: String, fingerprint: Fingerprint)] = []
        for path in paths {
            // Stat before reading: a write after this point changes the
            // fingerprint and is picked up next time.
            guard let fingerprint = Self.fingerprint(path) else {
                unreadable.append(path)
                continue
            }
            if let existing = state.entries[path], existing.fingerprint == fingerprint, !existing.isRacy {
                next[path] = existing
            } else {
                toLoad.append((path, fingerprint))
            }
        }

        let loadedAt = Self.nowNanoseconds()
        var loaded = [Note?](repeating: nil, count: toLoad.count)
        let count = toLoad.count
        loaded.withUnsafeMutableBufferPointer { buffer in
            let box = UnsafeBox(buffer)
            let work = UnsafeBox(toLoad)
            let load: @Sendable (Int) -> Void = { index in
                box.value[index] = try? MarkdownStore().load(URL(fileURLWithPath: work.value[index].path))
            }
            if count < 500 {
                for index in 0..<count { load(index) }
            } else {
                let chunk = 64
                DispatchQueue.concurrentPerform(iterations: (count + chunk - 1) / chunk) { part in
                    for index in (part * chunk)..<min((part + 1) * chunk, count) { load(index) }
                }
            }
        }
        for (index, item) in toLoad.enumerated() {
            guard let note = loaded[index] else {
                unreadable.append(item.path)
                continue
            }
            let previous = state.entries[item.path]
            if previous == nil || previous!.note.source != note.source || previous!.note.modifiedAt != note.modifiedAt {
                changed.insert(item.path)
            }
            next[item.path] = Entry(note: note, fingerprint: item.fingerprint, loadedAt: loadedAt, root: root)
        }
        for key in state.entries.keys where next[key] == nil {
            changed.insert(key)
        }
        if !changed.isEmpty || state.sorted == nil || next.count != state.entries.count {
            state.sorted = nil
        }
        state.entries = next
        state.unreadable = unreadable.sorted()
        return changed
    }

    // MARK: Paths

    private static func key(_ vault: Vault) -> String {
        vault.url.standardizedFileURL.path
    }

    /// Maps a real path reported by FSEvents to the key a walk would use.
    /// nil means "not a known note", which the caller settles by walking.
    private func entryKey(forEventPath path: String, state: VaultState, root: URL) -> String? {
        if state.entries[path] != nil { return path }
        for prefix in Self.rootPrefixes(root) where path.hasPrefix(prefix + "/") {
            let relative = path.dropFirst(prefix.count)
            for candidate in Self.rootPrefixes(root) {
                let key = candidate + relative
                if state.entries[key] != nil { return key }
            }
        }
        return nil
    }

    private static func rootPrefixes(_ root: URL) -> [String] {
        let plain = root.path
        let resolved = root.resolvingSymlinksInPath().path
        var prefixes = [plain]
        if resolved != plain { prefixes.append(resolved) }
        // /tmp and /var are symlinks into /private on macOS; enumerators and
        // FSEvents may report either form.
        for prefix in prefixes where prefix.hasPrefix("/private/") {
            prefixes.append(String(prefix.dropFirst("/private".count)))
        }
        for prefix in prefixes where !prefix.hasPrefix("/private/")
            && (prefix.hasPrefix("/tmp/") || prefix.hasPrefix("/var/")) {
            prefixes.append("/private" + prefix)
        }
        return Array(Set(prefixes)).sorted { $0.count > $1.count }
    }

    // MARK: Stat

    static func fingerprint(_ path: String) -> Fingerprint? {
        var target = StatInfo()
        var link = StatInfo()
        guard fstatat(AT_FDCWD, path, &target, 0) == 0,
              fstatat(AT_FDCWD, path, &link, AT_SYMLINK_NOFOLLOW) == 0
        else { return nil }
        return Fingerprint(
            size: Int64(target.st_size),
            mtime: nanoseconds(mtime(target)),
            ctime: nanoseconds(ctime(target)),
            inode: Int64(bitPattern: UInt64(target.st_ino)),
            lmtime: nanoseconds(mtime(link)),
            isSymlink: (link.st_mode & S_IFMT) == S_IFLNK
        )
    }

    private static func nanoseconds(_ time: timespec) -> Int64 {
        Int64(time.tv_sec) * 1_000_000_000 + Int64(time.tv_nsec)
    }

    static func nowNanoseconds() -> Int64 {
        var time = timespec()
        clock_gettime(CLOCK_REALTIME, &time)
        return nanoseconds(time)
    }

    #if canImport(Darwin)
    typealias StatInfo = Darwin.stat
    private static func mtime(_ info: StatInfo) -> timespec { info.st_mtimespec }
    private static func ctime(_ info: StatInfo) -> timespec { info.st_ctimespec }
    #elseif canImport(Glibc)
    typealias StatInfo = Glibc.stat
    private static func mtime(_ info: StatInfo) -> timespec { info.st_mtim }
    private static func ctime(_ info: StatInfo) -> timespec { info.st_ctim }
    #elseif canImport(Musl)
    typealias StatInfo = Musl.stat
    private static func mtime(_ info: StatInfo) -> timespec { info.st_mtim }
    private static func ctime(_ info: StatInfo) -> timespec { info.st_ctim }
    #endif

    // MARK: File events

    struct PendingChanges {
        var paths: [String]
        var needsWalk: Bool
    }

    #if os(macOS)
    /// Collects raw FSEvents. Paths inside hidden directories of the vault
    /// (.git, .retex, .obsidian) are ignored, matching the walk; events under
    /// the barrier directory only mark barriers as seen.
    final class EventSink: @unchecked Sendable {
        private let lock = NSLock()
        private let rootPrefixes: [String]
        private let barrierPrefix: String
        private var paths = Set<String>()
        private var needsWalk = false
        private var barriers = Set<String>()

        init(rootPrefixes: [String], barrierDirectory: String) {
            self.rootPrefixes = rootPrefixes
            barrierPrefix = barrierDirectory + "/"
        }

        func record(path: String, flags: UInt32) {
            lock.lock()
            defer { lock.unlock() }
            if path.hasPrefix(barrierPrefix) {
                barriers.insert(path)
                return
            }
            let walkFlags = UInt32(
                kFSEventStreamEventFlagMustScanSubDirs
                    | kFSEventStreamEventFlagUserDropped
                    | kFSEventStreamEventFlagKernelDropped
                    | kFSEventStreamEventFlagEventIdsWrapped
                    | kFSEventStreamEventFlagRootChanged
                    | kFSEventStreamEventFlagMount
                    | kFSEventStreamEventFlagUnmount
            )
            if flags & walkFlags != 0 {
                needsWalk = true
                return
            }
            guard let prefix = rootPrefixes.first(where: { path.hasPrefix($0 + "/") }) else { return }
            let relative = path.dropFirst(prefix.count + 1)
            if relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { return }
            if flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0 {
                let membership = UInt32(
                    kFSEventStreamEventFlagItemCreated
                        | kFSEventStreamEventFlagItemRemoved
                        | kFSEventStreamEventFlagItemRenamed
                )
                if flags & membership != 0 { needsWalk = true }
                return
            }
            // A known path is re-read (atomic saves arrive as create or
            // rename); an unknown or vanished one makes the caller walk.
            guard path.lowercased().hasSuffix(".md") else { return }
            paths.insert(path)
        }

        func sawBarrier(_ path: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return barriers.remove(path) != nil
        }

        func drain() -> PendingChanges {
            lock.lock()
            defer {
                paths.removeAll()
                needsWalk = false
                lock.unlock()
            }
            return PendingChanges(paths: Array(paths), needsWalk: needsWalk)
        }
    }

    private func startStream(_ state: VaultState, root: URL) {
        let realRoot = root.resolvingSymlinksInPath().path
        Self.removeStaleBarrierDirectories()
        let barriers = Self.barrierBase()
            .appendingPathComponent("\(getpid())-\(UUID().uuidString.prefix(8))", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: barriers,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            reportEventFailure(state, root: root, reason: "barrier directory \(barriers.path) failed: \(error.localizedDescription)")
            return
        }
        // Event order is only guaranteed within one volume.
        var rootInfo = StatInfo()
        var barrierInfo = StatInfo()
        guard stat(realRoot, &rootInfo) == 0, stat(barriers.path, &barrierInfo) == 0,
              rootInfo.st_dev == barrierInfo.st_dev
        else {
            try? FileManager.default.removeItem(at: barriers)
            state.eventsTrusted = false
            return
        }
        let realBarriers = barriers.resolvingSymlinksInPath().path
        let sink = EventSink(rootPrefixes: Self.rootPrefixes(root), barrierDirectory: realBarriers)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(sink).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, count, paths, flags, _ in
                guard let info else { return }
                let sink = Unmanaged<EventSink>.fromOpaque(info).takeUnretainedValue()
                let list = Unmanaged<NSArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
                for index in 0..<count where index < list.count {
                    sink.record(path: list[index], flags: flags[index])
                }
            },
            &context,
            [realRoot, realBarriers] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0,
            flags
        ) else {
            try? FileManager.default.removeItem(at: barriers)
            reportEventFailure(state, root: root, reason: "the event stream could not be created")
            return
        }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "retex.snapshot-events"))
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            try? FileManager.default.removeItem(at: barriers)
            reportEventFailure(state, root: root, reason: "the event stream did not start")
            return
        }
        state.stream = stream
        state.events = sink
        state.barrierDirectory = URL(fileURLWithPath: realBarriers, isDirectory: true)
        state.eventsTrusted = true
    }

    /// Waits until every file event that happened before this call has been
    /// delivered, then returns the changes. A barrier that is late makes the
    /// caller walk instead; repeated late barriers switch events off.
    private func awaitEvents(_ state: VaultState, root: URL) -> PendingChanges {
        guard state.eventsTrusted, let sink = state.events, let directory = state.barrierDirectory else {
            return PendingChanges(paths: [], needsWalk: true)
        }
        state.barrierSequence += 1
        let barrier = directory.appendingPathComponent("b\(state.barrierSequence)").path
        guard FileManager.default.createFile(atPath: barrier, contents: nil) else {
            reportEventFailure(state, root: root, reason: "barrier file \(barrier) could not be created")
            return PendingChanges(paths: [], needsWalk: true)
        }
        defer { unlink(barrier) }
        let deadline = DispatchTime.now().uptimeNanoseconds + 40_000_000
        while !sink.sawBarrier(barrier) {
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                state.lateBarriers += 1
                if state.lateBarriers >= 3 {
                    reportEventFailure(state, root: root, reason: "file events arrived late 3 times in a row (fseventsd may be stalled)")
                }
                // Changes still queued are covered by the walk this triggers.
                var pending = sink.drain()
                pending.needsWalk = true
                return pending
            }
            usleep(250)
        }
        state.lateBarriers = 0
        return sink.drain()
    }

    /// Barrier directories are named `<pid>-<id>`; remove those whose
    /// process has exited (a server killed before its cleanup ran).
    private static func removeStaleBarrierDirectories() {
        let base = barrierBase()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: base.path) else { return }
        for name in names {
            guard let pid = name.split(separator: "-").first.flatMap({ Int32($0) }), pid > 0 else { continue }
            if kill(pid, 0) != 0, errno == ESRCH {
                try? FileManager.default.removeItem(at: base.appendingPathComponent(name))
            }
        }
    }

    private static func barrierBase() -> URL {
        if let override = ProcessInfo.processInfo.environment["RETEX_EVENT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/retex/events", isDirectory: true)
    }

    private func reportEventFailure(_ state: VaultState, root: URL, reason: String) {
        state.eventsTrusted = false
        Self.stopStream(state)
        if !state.warned {
            state.warned = true
            FileHandle.standardError.write(Data(
                "retex: no file events for \(root.path): \(reason); checking every file on each request\n".utf8
            ))
        }
    }

    private static func stopStream(_ state: VaultState) {
        if let directory = state.barrierDirectory {
            try? FileManager.default.removeItem(at: directory)
            state.barrierDirectory = nil
        }
        guard let stream = state.stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        state.stream = nil
        state.events = nil
    }
    #endif
}

private final class UnsafeBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
