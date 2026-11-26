#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

public struct AutoUpdateSchedule: Codable, Equatable, Sendable {
    public let platform: String
    public let installed: Bool
    public let configurationPath: String

    public init(platform: String, installed: Bool, configurationPath: String) {
        self.platform = platform
        self.installed = installed
        self.configurationPath = configurationPath
    }
}

public struct AutoUpdateScheduler {
    public enum SchedulerError: LocalizedError, Equatable {
        case invalidExecutable
        case commandFailed(String)

        public var errorDescription: String? {
            switch self {
            case .invalidExecutable: "Auto updater requires the absolute path of a real Retex executable."
            case let .commandFailed(message): "Retex auto updater could not be configured: \(message)"
            }
        }
    }

    /// Environment a scheduled run must inherit so it targets the same update
    /// repository (and fleet registry, when one is configured) as the
    /// invocation that installed it. Without these the six-hourly job exits
    /// 64 and never checks for updates.
    static let forwardedEnvironmentKeys = ["RETEX_UPDATE_REPO", "RETEX_FLEET_REGISTRY"]

    /// `owner/repo` on GitHub: exactly two path segments of word characters,
    /// dots and dashes. Anything else would carry a query string, a newline or
    /// a path traversal into the API URL and into the generated unit file.
    public static func isValidRepository(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return parts.allSatisfy { part in
            part != "." && part != ".." && !part.isEmpty && part.allSatisfy { character in
                character.isLetter || character.isNumber || character == "_"
                    || character == "." || character == "-"
            }
        }
    }

    static func hasControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    public init() {}

    /// The subset of `environment` a scheduled run inherits, verbatim. A value
    /// that could break out of a unit directive (a control character) or that
    /// is not a well-formed repository never reaches the unit at all.
    static func forwardedEnvironment(from environment: [String: String]) -> [String: String] {
        var forwarded: [String: String] = [:]
        for key in forwardedEnvironmentKeys {
            guard let value = environment[key], !value.isEmpty else { continue }
            guard !hasControlCharacters(value), !hasControlCharacters(key) else { continue }
            if key == "RETEX_UPDATE_REPO", !isValidRepository(value) { continue }
            forwarded[key] = value
        }
        return forwarded
    }

    /// launchd property list for the macOS agent.
    static func launchdPlist(executable: URL, logs: URL, environment: [String: String]) -> [String: Any] {
        var plist: [String: Any] = [
            "Label": "org.retex.cli.fleet-update",
            "ProgramArguments": [executable.path, "update", "--auto", "--fleet", "--json"],
            "StartInterval": 21_600,
            "RunAtLoad": false,
            "StandardOutPath": logs.appendingPathComponent("fleet-update.log").path,
            "StandardErrorPath": logs.appendingPathComponent("fleet-update-error.log").path,
        ]
        if !environment.isEmpty {
            plist["EnvironmentVariables"] = environment
        }
        return plist
    }

    /// systemd `Environment=` lines, quoted and escaped per systemd rules.
    /// `%` starts a specifier (`%h`, `%t`), so a literal one must be doubled;
    /// a control character would end the directive and start a new one, so
    /// such a value is dropped instead of being written into the unit.
    static func systemdEnvironmentLines(_ environment: [String: String]) -> [String] {
        environment.keys.sorted().compactMap { key in
            let raw = environment[key, default: ""]
            guard !hasControlCharacters(raw), !hasControlCharacters(key) else { return nil }
            let value = raw
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "%", with: "%%")
            return "Environment=\"\(key)=\(value)\""
        }
    }

    /// systemd service unit for the Linux timer.
    static func systemdServiceUnit(executable: URL, environment: [String: String]) -> String {
        let escapedExecutable = executable.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        var lines = [
            "[Unit]",
            "Description=Verify and update the registered Retex vault fleet",
            "",
            "[Service]",
            "Type=oneshot",
        ]
        lines.append(contentsOf: systemdEnvironmentLines(environment))
        lines.append("ExecStart=\"\(escapedExecutable)\" update --auto --fleet --json")
        return lines.joined(separator: "\n")
    }

    public func install(executable: URL) throws -> AutoUpdateSchedule {
        try validate(executable)
        let environment = Self.forwardedEnvironment(from: ProcessInfo.processInfo.environment)
#if os(macOS)
        let target = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/org.retex.cli.fleet-update.plist")
        let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/retex/logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let plist = Self.launchdPlist(executable: executable, logs: logs, environment: environment)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
        _ = try? run(URL(fileURLWithPath: "/bin/launchctl"), ["bootout", "gui/\(getuid())", target.path])
        try run(URL(fileURLWithPath: "/bin/launchctl"), ["bootstrap", "gui/\(getuid())", target.path])
        return AutoUpdateSchedule(platform: "macos", installed: true, configurationPath: target.path)
#elseif os(Windows)
        // The scheduled task carries no environment of its own; a Windows
        // install forwards nothing.
        _ = environment
        let taskName = "Retex Fleet Update"
        let action = "\"\(executable.path)\" update --auto --fleet --json"
        try run(URL(fileURLWithPath: "C:/Windows/System32/schtasks.exe"), [
            "/Create", "/F", "/SC", "HOURLY", "/MO", "6", "/TN", taskName, "/TR", action,
        ])
        return AutoUpdateSchedule(platform: "windows", installed: true, configurationPath: taskName)
#else
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/systemd/user", isDirectory: true)
        let service = directory.appendingPathComponent("retex-fleet-update.service")
        let timer = directory.appendingPathComponent("retex-fleet-update.timer")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let serviceBody = Self.systemdServiceUnit(executable: executable, environment: environment)
        let timerBody = """
        [Unit]
        Description=Run Retex fleet update every six hours

        [Timer]
        OnBootSec=10m
        OnUnitActiveSec=6h
        Persistent=true

        [Install]
        WantedBy=timers.target
        """
        try serviceBody.write(to: service, atomically: true, encoding: .utf8)
        try timerBody.write(to: timer, atomically: true, encoding: .utf8)
        let systemctl = URL(fileURLWithPath: "/usr/bin/systemctl")
        try run(systemctl, ["--user", "daemon-reload"])
        try run(systemctl, ["--user", "enable", "--now", timer.lastPathComponent])
        return AutoUpdateSchedule(platform: "linux", installed: true, configurationPath: timer.path)
#endif
    }

    public func remove() throws -> AutoUpdateSchedule {
#if os(macOS)
        let target = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/org.retex.cli.fleet-update.plist")
        _ = try? run(URL(fileURLWithPath: "/bin/launchctl"), ["bootout", "gui/\(getuid())", target.path])
        try? FileManager.default.removeItem(at: target)
        return AutoUpdateSchedule(platform: "macos", installed: false, configurationPath: target.path)
#elseif os(Windows)
        let taskName = "Retex Fleet Update"
        _ = try? run(URL(fileURLWithPath: "C:/Windows/System32/schtasks.exe"), ["/Delete", "/F", "/TN", taskName])
        return AutoUpdateSchedule(platform: "windows", installed: false, configurationPath: taskName)
#else
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/systemd/user")
        let timer = directory.appendingPathComponent("retex-fleet-update.timer")
        _ = try? run(URL(fileURLWithPath: "/usr/bin/systemctl"), ["--user", "disable", "--now", timer.lastPathComponent])
        try? FileManager.default.removeItem(at: timer)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("retex-fleet-update.service"))
        _ = try? run(URL(fileURLWithPath: "/usr/bin/systemctl"), ["--user", "daemon-reload"])
        return AutoUpdateSchedule(platform: "linux", installed: false, configurationPath: timer.path)
#endif
    }

    private func validate(_ executable: URL) throws {
        let values = try executable.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard (executable.path as NSString).isAbsolutePath,
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              (values.fileSize ?? 0) > 0
        else { throw SchedulerError.invalidExecutable }
    }

    /// Runs a scheduler command without ever blocking on an unread pipe: the
    /// child's standard output is discarded and its standard error goes to a
    /// private temporary file that is read only after the process exits.
    private func run(_ executable: URL, _ arguments: [String]) throws {
        let fm = FileManager.default
        let errorURL = fm.temporaryDirectory
            .appendingPathComponent("retex-scheduler-\(UUID().uuidString).err")
        _ = fm.createFile(atPath: errorURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let stderr = try FileHandle(forWritingTo: errorURL)
        defer {
            try? stderr.close()
            try? fm.removeItem(at: errorURL)
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = (try? Data(contentsOf: errorURL)) ?? Data()
            throw SchedulerError.commandFailed(String(decoding: data.prefix(4_096), as: UTF8.self))
        }
    }
}
