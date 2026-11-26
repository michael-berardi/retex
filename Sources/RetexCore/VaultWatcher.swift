#if os(macOS)
import CoreServices
import Foundation

/// Watches a vault directory with FSEvents and delivers debounced change
/// batches on a caller-provided callback queue. Only Markdown notes outside
/// hidden directories are reported: internal Retex state under `.retex/`
/// (journal, memory usage sidecar) and atomic-save temp files never trigger
/// a callback, so this library's own writes do not echo back.
public final class VaultWatcher: @unchecked Sendable {
    private let vaultURL: URL
    private let debounce: TimeInterval
    private let onChange: @Sendable ([String]) -> Void
    private let callbackQueue: DispatchQueue

    private var stream: FSEventStreamRef?
    private var retainedSelf: Unmanaged<VaultWatcher>?
    private let stateLock = NSLock()
    private var pendingPaths: Set<String> = []
    private var flushWorkItem: DispatchWorkItem?
    /// When the oldest unflushed change arrived. A steady stream of writes
    /// keeps resetting the debounce, so the flush is never pushed past
    /// `maxLatency` after it; otherwise continuous writes starve the callback.
    private var pendingSince: DispatchTime?
    private var maxLatency: TimeInterval { max(1.0, debounce * 4) }

    /// - Parameters:
    ///   - vault: vault root to watch (recursive).
    ///   - debounce: coalescing window; bursts collapse into one callback.
    ///   - queue: queue the debounced callback runs on.
    ///   - onChange: receives changed paths relative to the vault root.
    public init(
        vault: Vault,
        debounce: TimeInterval = 0.3,
        queue: DispatchQueue = .main,
        onChange: @escaping @Sendable ([String]) -> Void
    ) {
        self.vaultURL = Self.canonicalURL(for: vault.url)
        self.debounce = debounce
        self.onChange = onChange
        callbackQueue = queue
    }

    /// FSEvents reports realpaths (for example `/private/var/...` for a path
    /// under `/var`) and misses changes when subscribed through a symlink.
    /// The stream and the relative-path prefix both use this canonical form.
    private static func canonicalURL(for url: URL) -> URL {
        let standard = url.standardizedFileURL
        guard let resolved = realpath(standard.path, nil) else { return standard }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    public func start() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard stream == nil else { return }

        // The stream retains the watcher so an in-flight callback can never
        // touch a freed instance; stop() balances it via retainedSelf.
        retainedSelf = Unmanaged.passRetained(self)
        var context = FSEventStreamContext(
            version: 0,
            info: retainedSelf!.toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagUseCFTypes
        )
        let queue = DispatchQueue.global(qos: .utility)
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, clientInfo, numEvents, eventPaths, eventFlags, _ in
                guard let clientInfo else { return }
                let watcher = Unmanaged<VaultWatcher>.fromOpaque(clientInfo).takeUnretainedValue()
                let paths = Unmanaged<NSArray>.fromOpaque(eventPaths)
                    .takeUnretainedValue() as? [String] ?? []
                let flagArray = Array(UnsafeBufferPointer(start: eventFlags, count: numEvents))
                watcher.handleEvents(paths: paths, numEvents: numEvents, flags: flagArray)
            },
            &context,
            [vaultURL.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1,
            flags
        ) else {
            // Balance the passRetained above; the stream never took ownership.
            retainedSelf?.release()
            retainedSelf = nil
            throw StoreError.unreadableVault(vaultURL)
        }

        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            // A stream that refuses to start would leave a watcher that looks
            // healthy but never reports anything: fail loudly instead.
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            queue.sync {}
            // Balance the passRetained above; the stream never took ownership.
            retainedSelf?.release()
            retainedSelf = nil
            throw StoreError.unreadableVault(vaultURL)
        }
        stream = created
    }

    public func stop() {
        stateLock.lock()
        flushWorkItem?.cancel()
        flushWorkItem = nil
        pendingPaths = []
        pendingSince = nil
        guard let existing = stream else {
            stateLock.unlock()
            return
        }
        stream = nil
        stateLock.unlock()

        FSEventStreamStop(existing)
        FSEventStreamInvalidate(existing)
        FSEventStreamRelease(existing)
        // Balance the retain taken in start().
        retainedSelf?.release()
        retainedSelf = nil
    }

    deinit { stop() }

    /// A vault-relative path the watcher reports: a `.md` file with no
    /// hidden component.
    static func isReportable(relativePath: String) -> Bool {
        let components = relativePath.split(separator: "/")
        guard let last = components.last, !components.contains(where: { $0.hasPrefix(".") }) else { return false }
        return last.lowercased().hasSuffix(".md")
    }

    fileprivate func handleEvents(paths: [String], numEvents: Int, flags: [UInt32]) {
        var fresh: Set<String> = []
        let root = vaultURL.path
        for index in 0..<numEvents {
            // File-level flags save a directory probe per event path.
            let eventFlags = index < flags.count ? flags[index] : 0
            for path in paths[index < paths.count ? index : 0].split(separator: "\0") {
                let changed = String(path)
                guard changed.hasPrefix(root + "/") else { continue }
                // Only Markdown notes outside hidden directories, matching the
                // polling watcher: internal state (`.retex/`, including the
                // memory usage sidecar) and atomic-save temp files
                // (`note.md.sb-<hash>-<rand>`) never reach the callback.
                guard Self.isReportable(relativePath: String(changed.dropFirst(root.count + 1))) else { continue }
                // Directories never reach the callback: events name parents,
                // and `ItemIsFile` comes with file-level event reporting. The
                // probe is only a fallback for events that carry neither flag.
                if eventFlags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0 { continue }
                if eventFlags & UInt32(kFSEventStreamEventFlagItemIsFile) == 0,
                   (try? FileManager.default.contentsOfDirectory(atPath: changed)) != nil {
                    continue
                }
                fresh.insert(changed)
            }
        }
        guard !fresh.isEmpty else { return }

        stateLock.lock()
        defer { stateLock.unlock() }
        guard stream != nil else { return } // stopped between callback and schedule
        pendingPaths.formUnion(fresh)
        flushWorkItem?.cancel()
        let now = DispatchTime.now()
        let since = pendingSince ?? now
        pendingSince = since
        let deadline = min(now + debounce, since + maxLatency)
        let workItem = DispatchWorkItem { [weak self] in self?.flush() }
        flushWorkItem = workItem
        callbackQueue.asyncAfter(deadline: deadline, execute: workItem)
    }

    private func flush() {
        stateLock.lock()
        let batch = Array(pendingPaths).sorted()
        pendingPaths = []
        pendingSince = nil
        stateLock.unlock()
        guard !batch.isEmpty else { return }
        // Standardize both sides the same way so /private prefixes match.
        let root = vaultURL.standardizedFileURL.path
        onChange(batch.map { path in
            let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            if standardized.hasPrefix(root + "/") {
                return String(standardized.dropFirst(root.count + 1))
            }
            return path
        })
    }
}

#else
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

/// Portable polling watcher for Linux and Windows. It keeps no persistent
/// index and reports only changed Markdown paths, matching the macOS contract.
public final class VaultWatcher: @unchecked Sendable {
    /// What a poll compares. Size and mtime alone miss a same-size edit made
    /// inside one timestamp tick, so ctime and inode (where the platform
    /// reports them) join the comparison.
    private struct Signature: Equatable {
        let modifiedAt: Date
        let bytes: Int
        let changedAt: Date
        let inode: UInt64
    }

    private struct Scan {
        var signatures: [String: Signature]
        /// Notes whose mtime is too close to the scan to prove they are
        /// unchanged: they are reported again on the next poll.
        var racy: Set<String>
    }

    /// A write this close to a scan may happen again inside the same
    /// filesystem timestamp tick, so such a note is re-reported once (the same
    /// racy-clean rule git uses to avoid missing a change).
    private static let racyWindow: TimeInterval = 2

    private let vaultURL: URL
    private let interval: TimeInterval
    private let onChange: @Sendable ([String]) -> Void
    private let callbackQueue: DispatchQueue
    private let stateLock = NSLock()
    private var snapshot: [String: Signature] = [:]
    private var timer: DispatchSourceTimer?

    public init(
        vault: Vault,
        debounce: TimeInterval = 0.3,
        queue: DispatchQueue = .main,
        onChange: @escaping @Sendable ([String]) -> Void
    ) {
        vaultURL = vault.url.standardizedFileURL
        interval = max(debounce, 1.0)
        callbackQueue = queue
        self.onChange = onChange
    }

    public func start() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard timer == nil else { return }
        snapshot = try makeSnapshot(scanStartedAt: Date()).signatures
        let source = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        source.schedule(deadline: .now() + interval, repeating: interval)
        source.setEventHandler { [weak self] in self?.poll() }
        timer = source
        source.resume()
    }

    public func stop() {
        stateLock.lock()
        let source = timer
        timer = nil
        snapshot = [:]
        stateLock.unlock()
        source?.cancel()
    }

    deinit { stop() }

    private func poll() {
        let scanStartedAt = Date()
        guard let scan = try? makeSnapshot(scanStartedAt: scanStartedAt) else { return }
        stateLock.lock()
        guard timer != nil else {
            stateLock.unlock()
            return
        }
        let previous = snapshot
        snapshot = scan.signatures
        stateLock.unlock()

        let changed = Set(previous.keys).union(scan.signatures.keys).filter {
            previous[$0] != scan.signatures[$0] || scan.racy.contains($0)
        }.sorted()
        guard !changed.isEmpty else { return }
        callbackQueue.async { [onChange] in onChange(changed) }
    }

    private func makeSnapshot(scanStartedAt: Date) throws -> Scan {
        guard let enumerator = FileManager.default.enumerator(
            at: vaultURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw StoreError.unreadableVault(vaultURL)
        }
        let racyAfter = scanStartedAt.addingTimeInterval(-Self.racyWindow)
        let rootComponents = vaultURL.pathComponents.count
        var signatures: [String: Signature] = [:]
        var racy: Set<String> = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "md" {
            guard let signature = Self.signature(of: url) else { continue }
            let relative = url.pathComponents.dropFirst(rootComponents).joined(separator: "/")
            signatures[relative] = signature
            if signature.modifiedAt >= racyAfter { racy.insert(relative) }
        }
        return Scan(signatures: signatures, racy: racy)
    }

    /// Size and mtime come from the enumeration; ctime and inode come from
    /// `lstat` where the platform has it, in one extra syscall.
    private static func signature(of url: URL) -> Signature? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        else { return nil }
        let modifiedAt = values.contentModificationDate ?? .distantPast
        let bytes = values.fileSize ?? 0
        #if canImport(Darwin)
        var info = Darwin.stat()
        let statted = lstat(url.path, &info) == 0
        return Signature(
            modifiedAt: modifiedAt,
            bytes: bytes,
            changedAt: statted
                ? Date(timeIntervalSince1970: Double(info.st_ctimespec.tv_sec) + Double(info.st_ctimespec.tv_nsec) / 1_000_000_000)
                : .distantPast,
            inode: statted ? UInt64(info.st_ino) : 0
        )
        #elseif canImport(Glibc)
        var info = Glibc.stat()
        let statted = lstat(url.path, &info) == 0
        return Signature(
            modifiedAt: modifiedAt,
            bytes: bytes,
            changedAt: statted
                ? Date(timeIntervalSince1970: Double(info.st_ctim.tv_sec) + Double(info.st_ctim.tv_nsec) / 1_000_000_000)
                : .distantPast,
            inode: statted ? UInt64(info.st_ino) : 0
        )
        #elseif canImport(Musl)
        var info = Musl.stat()
        let statted = lstat(url.path, &info) == 0
        return Signature(
            modifiedAt: modifiedAt,
            bytes: bytes,
            changedAt: statted
                ? Date(timeIntervalSince1970: Double(info.st_ctim.tv_sec) + Double(info.st_ctim.tv_nsec) / 1_000_000_000)
                : .distantPast,
            inode: statted ? UInt64(info.st_ino) : 0
        )
        #else
        return Signature(modifiedAt: modifiedAt, bytes: bytes, changedAt: .distantPast, inode: 0)
        #endif
    }
}

#endif
