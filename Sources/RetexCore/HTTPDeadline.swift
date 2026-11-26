import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Deadlines for the blocking HTTP exchanges the CLI makes (vault sync and
/// release downloads).
///
/// A fixed total timeout caps big transfers as hard as small ones: a 1 GiB
/// vault on a slow link needs hours, while a stalled server should fail in a
/// minute. So the stall guard is the idle timeout, and the total exchange
/// deadline is the floor (`minTransfer`, 180 s) or the time the body needs at
/// the slowest supported link, whichever is longer.
/// `RETEX_SYNC_TIMEOUT_SECONDS` raises the floor and the idle guard for links
/// slower than that.
enum HTTPDeadline {
    /// Abort a connection that makes no progress (no bytes either way) for
    /// this long.
    static let idleTimeout: TimeInterval = 60
    /// The slowest link a transfer is still expected to survive.
    static let minimumThroughput: Double = 32 * 1024
    /// Floor for one exchange, so a small request is never cut short.
    static let minTransfer: TimeInterval = 180
    /// Environment variable that raises the floor for slow links.
    static let environmentKey = "RETEX_SYNC_TIMEOUT_SECONDS"

    /// A positive override from the environment, if any.
    static func override(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TimeInterval? {
        guard let raw = environment[environmentKey]?.trimmingCharacters(in: .whitespaces),
              let value = Double(raw),
              value.isFinite,
              value > 0
        else { return nil }
        return value
    }

    /// The stall guard: never shorter than the default, longer when the
    /// operator declared a slower link.
    static func idle(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TimeInterval {
        max(idleTimeout, override(environment: environment) ?? 0)
    }

    /// Total time allowed for one exchange carrying `expectedBytes`.
    static func transfer(
        expectedBytes: Int,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TimeInterval {
        let floor = override(environment: environment) ?? minTransfer
        let scaled = Double(max(expectedBytes, 0)) / minimumThroughput
        return max(floor, scaled)
    }

    /// Applies the idle stall guard and a resource ceiling suited to the
    /// largest body the caller can receive.
    static func configure(
        _ configuration: URLSessionConfiguration,
        maximumBytes: Int,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URLSession {
        let config = configuration.copy() as? URLSessionConfiguration ?? configuration
        config.timeoutIntervalForRequest = idle(environment: environment)
        config.timeoutIntervalForResource = transfer(expectedBytes: maximumBytes, environment: environment)
        return URLSession(configuration: config)
    }

    /// Waits for `task` to finish. The deadline follows the size the task
    /// reports for itself, so a large body gets the time its size needs while
    /// a stalled one still gives up. Returns the deadline that applied and
    /// whether the task finished in time; the caller cancels it otherwise.
    static func wait(
        for task: URLSessionTask,
        semaphore: DispatchSemaphore,
        hint: Int = 0,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (completed: Bool, deadline: TimeInterval) {
        let startedAt = Date()
        var expected = max(hint, 0)
        while true {
            let deadline = transfer(expectedBytes: expected, environment: environment)
            let remaining = deadline - Date().timeIntervalSince(startedAt)
            guard remaining > 0 else { return (false, deadline) }
            // Poll so a growing transfer can extend its own deadline.
            if semaphore.wait(timeout: .now() + min(remaining, 0.05)) == .success {
                return (true, deadline)
            }
            expected = max(expected, reportedSize(of: task))
        }
    }

    /// The size the task reports: the request body for an upload, the
    /// advertised response body (`Content-Length`) for a download.
    /// `NSURLSessionTransferSizeUnknown` and zero mean "not known yet".
    static func reportedSize(of task: URLSessionTask) -> Int {
        let received = task.countOfBytesExpectedToReceive
        let sent = task.countOfBytesExpectedToSend
        let size = max(received, sent)
        guard size > 0, size <= Int64(Int.max) else { return 0 }
        return Int(size)
    }
}
