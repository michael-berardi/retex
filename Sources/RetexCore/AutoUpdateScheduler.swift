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
#if os(macOS)
        let target = home
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
        let log = UpdateLog.url(root: home)
        try FileManager.default.createDirectory(
            at: log.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable.path] + jobArguments,
            "StartInterval": 21_600,
            "RunAtLoad": false,
            "ProcessType": "Background",
            "LowPriorityIO": true,
            "Nice": 10,
            "StandardOutPath": log.path,
            "StandardErrorPath": log.path,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
        if !dryRun {
            _ = try? run(URL(fileURLWithPath: "/bin/launchctl"), ["bootout", "gui/\(getuid())", target.path])
            try run(URL(fileURLWithPath: "/bin/launchctl"), ["bootstrap", "gui/\(getuid())", target.path])
        }
        return schedule("macos", installed: true, path: target.path)
#elseif os(Windows)
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
        let escapedExecutable = executable.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let serviceBody = """
        [Unit]
        Description=Verify and \(mode == .fleet ? "update the registered Retex vault fleet" : "install verified Retex CLI updates")

        [Service]
        Type=oneshot
        Nice=10
        IOSchedulingClass=idle
        ExecStart="\(escapedExecutable)" \(jobArguments.joined(separator: " "))
        StandardOutput=append:\(UpdateLog.url(root: home).path)
        StandardError=append:\(UpdateLog.url(root: home).path)
        """
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
        let query = try? run(URL(fileURLWithPath: "C:/Windows/System32/schtasks.exe"), ["/Query", "/TN", taskName])
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

    @discardableResult
    private func run(_ executable: URL, _ arguments: [String]) throws -> Data {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SchedulerError.commandFailed(String(decoding: stderr.fileHandleForReading.readDataToEndOfFile().prefix(4_096), as: UTF8.self))
        }
        return stdout.fileHandleForReading.readDataToEndOfFile()
    }
}
