import CoreServices
import Foundation

/// Watches a vault directory with FSEvents and delivers debounced change
/// batches on a caller-provided callback queue. Internal Retex state under
/// `.retex/` never triggers events, so mutations recorded by this library do
/// not echo back.
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
        self.vaultURL = vault.url.standardizedFileURL
        self.debounce = debounce
        self.onChange = onChange
        callbackQueue = queue
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

        FSEventStreamSetDispatchQueue(created, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(created)
        stream = created
    }

    public func stop() {
        stateLock.lock()
        flushWorkItem?.cancel()
        flushWorkItem = nil
        pendingPaths = []
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

    fileprivate func handleEvents(paths: [String], numEvents: Int, flags: [UInt32]) {
        var fresh: Set<String> = []
        for index in 0..<numEvents {
            for path in paths[index < paths.count ? index : 0].split(separator: "\0") {
                let changed = String(path)
                // Skip internal state; skip directories (events may name parents).
                if changed.hasSuffix("/.retex") || changed.contains("/.retex/") { continue }
                if (try? FileManager.default.contentsOfDirectory(atPath: changed)) != nil { continue }
                fresh.insert(changed)
            }
        }
        guard !fresh.isEmpty else { return }

        stateLock.lock()
        defer { stateLock.unlock() }
        guard stream != nil else { return } // stopped between callback and schedule
        pendingPaths.formUnion(fresh)
        flushWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.flush() }
        flushWorkItem = workItem
        callbackQueue.asyncAfter(deadline: .now() + debounce, execute: workItem)
    }

    private func flush() {
        stateLock.lock()
        let batch = Array(pendingPaths).sorted()
        pendingPaths = []
        stateLock.unlock()
        guard !batch.isEmpty else { return }
        onChange(batch.map { path in
            let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            if standardized.hasPrefix(vaultURL.path + "/") {
                return String(standardized.dropFirst(vaultURL.path.count + 1))
            }
            return path
        })
    }
}
