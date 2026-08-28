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

    public init() {}

    public func install(executable: URL) throws -> AutoUpdateSchedule {
        try validate(executable)
#if os(macOS)
        let target = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/org.retex.cli.fleet-update.plist")
        let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/retex/logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "Label": "org.retex.cli.fleet-update",
            "ProgramArguments": [executable.path, "update", "--auto", "--fleet", "--json"],
            "StartInterval": 21_600,
            "RunAtLoad": false,
            "StandardOutPath": logs.appendingPathComponent("fleet-update.log").path,
            "StandardErrorPath": logs.appendingPathComponent("fleet-update-error.log").path,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
        _ = try? run(URL(fileURLWithPath: "/bin/launchctl"), ["bootout", "gui/\(getuid())", target.path])
        try run(URL(fileURLWithPath: "/bin/launchctl"), ["bootstrap", "gui/\(getuid())", target.path])
        return AutoUpdateSchedule(platform: "macos", installed: true, configurationPath: target.path)
#elseif os(Windows)
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
        let escapedExecutable = executable.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let serviceBody = """
        [Unit]
        Description=Verify and update the registered Retex vault fleet

        [Service]
        Type=oneshot
        ExecStart="\(escapedExecutable)" update --auto --fleet --json
        """
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
