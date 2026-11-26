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
    public let mode: String

    public init(platform: String, installed: Bool, configurationPath: String, mode: String = "fleet") {
        self.platform = platform
        self.installed = installed
        self.configurationPath = configurationPath
        self.mode = mode
    }
}

/// Installs an opt-in periodic job for either the registered vault fleet or
/// the plain CLI self-update. Both kinds run detached and log to Retex's own
/// log directory; the job is owned by the user and can always be removed.
public struct AutoUpdateScheduler {
    public enum Mode: String, Sendable {
        case fleet
        case selfUpdate
    }

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

    private let mode: Mode
    private let root: URL?
    private let dryRun: Bool

    /// - Parameter root: Override for the job's configuration root (tests).
    /// - Parameter dryRun: Write files but skip platform scheduler commands.
    public init(mode: Mode = .fleet, root: URL? = nil, dryRun: Bool = false) {
        self.mode = mode
        self.root = root
        self.dryRun = dryRun
    }

    /// launchd property list for one scheduled job. Defaults describe the
    /// fleet job; `label` and `arguments` select the self-update job.
    static func launchdPlist(
        executable: URL,
        log: URL,
        environment: [String: String],
        label: String = "org.retex.cli.fleet-update",
        arguments: [String] = ["update", "--auto", "--fleet", "--json"]
    ) -> [String: Any] {
        var plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable.path] + arguments,
            "StartInterval": 21_600,
            "RunAtLoad": false,
            "ProcessType": "Background",
            "LowPriorityIO": true,
            "Nice": 10,
            "StandardOutPath": log.path,
            "StandardErrorPath": log.path,
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

    /// systemd service unit for one scheduled job.
    static func systemdServiceUnit(
        executable: URL,
        environment: [String: String],
        log: URL? = nil,
        description: String = "update the registered Retex vault fleet",
        arguments: [String] = ["update", "--auto", "--fleet", "--json"]
    ) -> String {
        let escapedExecutable = executable.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        var lines = [
            "[Unit]",
            "Description=Verify and \(description)",
            "",
            "[Service]",
            "Type=oneshot",
            "Nice=10",
            "IOSchedulingClass=idle",
        ]
        lines.append(contentsOf: systemdEnvironmentLines(environment))
        lines.append("ExecStart=\"\(escapedExecutable)\" \(arguments.joined(separator: " "))")
        if let log {
            lines.append("StandardOutput=append:\(log.path)")
            lines.append("StandardError=append:\(log.path)")
        }
        return lines.joined(separator: "\n")
    }

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

    private var home: URL { root ?? FileManager.default.homeDirectoryForCurrentUser }

    private var label: String {
        mode == .fleet ? "org.retex.cli.fleet-update" : "org.retex.cli.update"
    }

    private var unitName: String {
        mode == .fleet ? "retex-fleet-update" : "retex-self-update"
    }

    private var taskName: String {
        mode == .fleet ? "Retex Fleet Update" : "Retex Self Update"
    }

    private var jobArguments: [String] {
        mode == .fleet
            ? ["update", "--auto", "--fleet", "--json"]
            : ["update", "--auto-run", "--json"]
    }

    private func schedule(_ platform: String, installed: Bool, path: String) -> AutoUpdateSchedule {
        AutoUpdateSchedule(
            platform: platform,
            installed: installed,
            configurationPath: path,
            mode: mode.rawValue
        )
    }

    public func install(executable: URL) throws -> AutoUpdateSchedule {
        try validate(executable)
        let environment = Self.forwardedEnvironment(from: ProcessInfo.processInfo.environment)
#if os(macOS)
        let target = home
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
        let log = UpdateLog.url(root: home)
        try UpdateLog.preparePrivate(url: log)
        let plist = Self.launchdPlist(
            executable: executable, log: log, environment: environment,
            label: label, arguments: jobArguments
        )
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
#if !os(Windows)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
#endif
        if !dryRun {
            _ = try? run(URL(fileURLWithPath: "/bin/launchctl"), ["bootout", "gui/\(getuid())", target.path])
            try run(URL(fileURLWithPath: "/bin/launchctl"), ["bootstrap", "gui/\(getuid())", target.path])
        }
        return schedule("macos", installed: true, path: target.path)
#elseif os(Windows)
        // The scheduled task carries no environment of its own; a Windows
        // install forwards nothing.
        _ = environment
        let action = "\"\(executable.path)\" \(jobArguments.joined(separator: " "))"
        if !dryRun {
            try run(URL(fileURLWithPath: "C:/Windows/System32/schtasks.exe"), [
                "/Create", "/F", "/SC", "HOURLY", "/MO", "6", "/TN", taskName, "/TR", action,
            ])
        }
        return schedule("windows", installed: true, path: taskName)
#else
        let directory = home
            .appendingPathComponent(".config/systemd/user", isDirectory: true)
        let service = directory.appendingPathComponent("\(unitName).service")
        let timer = directory.appendingPathComponent("\(unitName).timer")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let log = UpdateLog.url(root: home)
        try UpdateLog.preparePrivate(url: log)
        let serviceBody = Self.systemdServiceUnit(
            executable: executable,
            environment: environment,
            log: log,
            description: mode == .fleet ? "update the registered Retex vault fleet" : "install verified Retex CLI updates",
            arguments: jobArguments
        )
        let timerBody = """
        [Unit]
        Description=Run Retex \(mode == .fleet ? "fleet" : "CLI") update every six hours

        [Timer]
        OnBootSec=10m
        OnUnitActiveSec=6h
        Persistent=true

        [Install]
        WantedBy=timers.target
        """
        try serviceBody.write(to: service, atomically: true, encoding: .utf8)
        try timerBody.write(to: timer, atomically: true, encoding: .utf8)
#if !os(Windows)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: service.path)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: timer.path)
#endif
        if !dryRun {
            let systemctl = URL(fileURLWithPath: "/usr/bin/systemctl")
            try run(systemctl, ["--user", "daemon-reload"])
            try run(systemctl, ["--user", "enable", "--now", timer.lastPathComponent])
        }
        return schedule("linux", installed: true, path: timer.path)
#endif
    }

    public func remove() throws -> AutoUpdateSchedule {
#if os(macOS)
        let target = home
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
        if !dryRun {
            _ = try? run(URL(fileURLWithPath: "/bin/launchctl"), ["bootout", "gui/\(getuid())", target.path])
        }
        try? FileManager.default.removeItem(at: target)
        return schedule("macos", installed: false, path: target.path)
#elseif os(Windows)
        let taskName = self.taskName
        if !dryRun {
            _ = try? run(URL(fileURLWithPath: "C:/Windows/System32/schtasks.exe"), ["/Delete", "/F", "/TN", taskName])
        }
        return schedule("windows", installed: false, path: taskName)
#else
        let directory = home.appendingPathComponent(".config/systemd/user")
        let service = directory.appendingPathComponent("\(unitName).service")
        let timer = directory.appendingPathComponent("\(unitName).timer")
        if !dryRun {
            _ = try? run(URL(fileURLWithPath: "/usr/bin/systemctl"), ["--user", "disable", "--now", timer.lastPathComponent])
        }
        try? FileManager.default.removeItem(at: timer)
        try? FileManager.default.removeItem(at: service)
        if !dryRun {
            _ = try? run(URL(fileURLWithPath: "/usr/bin/systemctl"), ["--user", "daemon-reload"])
        }
        return schedule("linux", installed: false, path: timer.path)
#endif
    }

    /// Read-only view of whether this kind of job is installed.
    public func status() -> AutoUpdateSchedule {
#if os(Windows)
        if dryRun { return schedule("windows", installed: false, path: taskName) }
        let query: Void? = try? run(URL(fileURLWithPath: "C:/Windows/System32/schtasks.exe"), ["/Query", "/TN", taskName])
        return schedule("windows", installed: query != nil, path: taskName)
#else
        let path: String
#if os(macOS)
        path = home.appendingPathComponent("Library/LaunchAgents/\(label).plist").path
#else
        path = home.appendingPathComponent(".config/systemd/user/\(unitName).timer").path
#endif
        return schedule(
            operatingSystem,
            installed: FileManager.default.fileExists(atPath: path),
            path: path
        )
#endif
    }

    private var operatingSystem: String {
#if os(macOS)
        "macos"
#elseif os(Windows)
        "windows"
#else
        "linux"
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
