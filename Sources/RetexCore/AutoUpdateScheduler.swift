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
    /// Optional scheduler logs are capped; they can contain vault paths.
    public static let maximumLogBytes = 1 << 20

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

    /// Scheduler log location. The directory argument exists so tests can use
    /// a scratch directory instead of the current user's home.
    public static func logsDirectory(home: URL? = nil) -> URL {
        (home ?? FileManager.default.homeDirectoryForCurrentUser)
            .appendingPathComponent(".config/retex/logs", isDirectory: true)
    }

    /// Keeps optional scheduler logs private and bounded to the newest
    /// `maximumLogBytes` per file. Called at the start of each scheduled run;
    /// trimming in place preserves the file handles launchd holds open.
    @discardableResult
    public static func boundLogs(in directory: URL? = nil) -> [URL] {
        let logs = directory ?? logsDirectory()
        let fm = FileManager.default
        guard fm.fileExists(atPath: logs.path) else { return [] }
#if !os(Windows)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: logs.path)
#endif
        var touched: [URL] = []
        for name in ["fleet-update.log", "fleet-update-error.log"] {
            let url = logs.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else { continue }
#if !os(Windows)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
#endif
            touched.append(url)
            guard let attributes = try? fm.attributesOfItem(atPath: url.path),
                  let size = (attributes[.size] as? NSNumber)?.int64Value,
                  size > Int64(maximumLogBytes),
                  let handle = try? FileHandle(forUpdating: url)
            else { continue }
            defer { try? handle.close() }
            do {
                try handle.seek(toOffset: UInt64(size - Int64(maximumLogBytes)))
                let tail = try handle.read(upToCount: maximumLogBytes) ?? Data()
                try handle.seek(toOffset: 0)
                try handle.write(contentsOf: tail)
                try handle.truncate(atOffset: UInt64(tail.count))
            } catch {
                // A failed trim leaves the log intact for the next run.
            }
        }
        return touched
    }

    public func install(executable: URL) throws -> AutoUpdateSchedule {
        try validate(executable)
#if os(macOS)
        let target = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/org.retex.cli.fleet-update.plist")
        let logs = Self.logsDirectory()
#if os(Windows)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
#else
        try FileManager.default.createDirectory(
            at: logs, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: logs.path)
#endif
        for name in ["fleet-update.log", "fleet-update-error.log"] {
            let file = logs.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: file.path) {
#if os(Windows)
                FileManager.default.createFile(atPath: file.path, contents: nil)
#else
                FileManager.default.createFile(
                    atPath: file.path, contents: nil,
                    attributes: [.posixPermissions: 0o600]
                )
#endif
            }
        }
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
#if !os(Windows)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
#endif
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
#if !os(Windows)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: service.path)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: timer.path)
#endif
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
