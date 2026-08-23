import Foundation

/// Thread-safe mutable cell for closures that cross concurrency domains.
final class LockedBox<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()

    init(_ initial: T) {
        value = initial
    }

    func with<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
