import Foundation

/// Result of an update check. A failed check carries its cause.
public struct UpdateStatus: Codable, Equatable, Sendable {
    public let currentVersion: String
    public let latestVersion: String?
    public let available: Bool
    public let error: String?

    public init(state: UpdateState, current: String) {
        currentVersion = current
        latestVersion = state.latestVersion
        error = state.checkError
        available = state.checkError == nil
            && state.latestVersion.map { UpdateChecker.isNewer(releaseTag: $0, current: current) } == true
    }
}

/// Applies the privacy rules (one anonymous request, cached for a day, short
/// timeout, failures recorded and not retried) on top of the release lookup.
public struct UpdateCoordinator {
    public let checker: UpdateChecker
    public let store: UpdateStateStore
    private let now: () -> Date

    public init(
        checker: UpdateChecker,
        store: UpdateStateStore = UpdateStateStore(),
        now: @escaping () -> Date = Date.init
    ) {
        self.checker = checker
        self.store = store
        self.now = now
    }

    /// Reuses a check younger than a day. An `explicit` check (the user ran
    /// `retex update --check`) reuses only a successful one, so a recorded
    /// failure can be retried by hand.
    public func check(current: String, explicit: Bool = false) -> UpdateStatus {
        let moment = now()
        var state = store.load()
        if state.isFresh(now: moment), !(explicit && state.checkError != nil) {
            return UpdateStatus(state: state, current: current)
        }
        state.checkedAt = moment
        do {
            state.latestVersion = UpdateChecker.displayVersion(try checker.latestRelease().tag)
            state.checkError = nil
        } catch {
            state.checkError = error.localizedDescription
        }
        try? store.save(state)
        return UpdateStatus(state: state, current: current)
    }
}

/// The post-command CLI notice: stderr, after the command, only for a person
/// at a terminal. Never in machine output, CI, MCP/stdio or long-running modes.
public enum UpdateNotice {
    public static let silentCommands: Set<String> = ["mcp", "update", "watch"]

    public static func optedOut(_ environment: [String: String]) -> Bool {
        let value = environment["RETEX_NO_UPDATE_CHECK"] ?? ""
        return !value.isEmpty && value != "0"
    }

    public static func allowed(
        command: String?,
        isJSON: Bool,
        isTTY: Bool,
        environment: [String: String]
    ) -> Bool {
        guard isTTY, !isJSON, (environment["CI"] ?? "").isEmpty, !optedOut(environment) else {
            return false
        }
        return !silentCommands.contains(command ?? "")
    }

    public static func lines(current: String, new: String, command: String = "retex update") -> [String] {
        [
            "retex \(new) available (you have \(current)) · run: \(command)",
            "turn on automatic updates: retex update --auto on · skip: retex update --skip",
        ]
    }
}
