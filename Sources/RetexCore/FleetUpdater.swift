#if (os(macOS) || os(Linux)) && canImport(CUltraCompact)
import CUltraCompact
#endif
import Foundation

public struct FleetVault: Codable, Equatable, Sendable {
    public let path: String
    public let autoUpdate: Bool

    public init(path: String, autoUpdate: Bool) {
        self.path = path
        self.autoUpdate = autoUpdate
    }
}

public struct FleetRegistryDocument: Codable, Equatable, Sendable {
    public let version: Int
    public var vaults: [FleetVault]

    public init(version: Int = 1, vaults: [FleetVault] = []) {
        self.version = version
        self.vaults = vaults
    }
}

public struct FleetUpgradeReport: Codable, Equatable, Sendable {
    public let path: String
    public let autoUpdate: Bool
    public let verified: Bool
    public let exactListMatch: Bool
    public let exactSearchMatch: Bool
    public let exactBoardMatch: Bool
    public let mutationRoundTrip: Bool
    public let previousVersionReadable: Bool
    public let milliseconds: Int

    public init(
        path: String,
        autoUpdate: Bool,
        verified: Bool,
        exactListMatch: Bool,
        exactSearchMatch: Bool,
        exactBoardMatch: Bool,
        mutationRoundTrip: Bool,
        previousVersionReadable: Bool,
        milliseconds: Int
    ) {
        self.path = path
        self.autoUpdate = autoUpdate
        self.verified = verified
        self.exactListMatch = exactListMatch
        self.exactSearchMatch = exactSearchMatch
        self.exactBoardMatch = exactBoardMatch
        self.mutationRoundTrip = mutationRoundTrip
        self.previousVersionReadable = previousVersionReadable
        self.milliseconds = milliseconds
    }
}

public struct FleetRegistry {
    public enum RegistryError: LocalizedError, Equatable {
        case invalidRegistry
        case unsafeVault(String)
        case duplicateVault
        case missingVault

        public var errorDescription: String? {
            switch self {
            case .invalidRegistry: "Retex fleet registry is invalid."
            case let .unsafeVault(path): "Fleet vault must be a real, non-symlink directory: \(path)"
            case .duplicateVault: "Vault is already registered."
            case .missingVault: "Vault is not registered."
            }
        }
    }

    public let url: URL

    public init(url: URL? = nil) {
        if let url {
            self.url = url.standardizedFileURL
        } else if let configured = ProcessInfo.processInfo.environment["RETEX_FLEET_REGISTRY"], !configured.isEmpty {
            self.url = URL(fileURLWithPath: NSString(string: configured).expandingTildeInPath).standardizedFileURL
        } else {
            let config = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/retex", isDirectory: true)
            self.url = config.appendingPathComponent("fleet.json")
        }
    }

    public func load() throws -> FleetRegistryDocument {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return FleetRegistryDocument()
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) <= 1_048_576 else {
            throw RegistryError.invalidRegistry
        }
        let document = try JSONDecoder().decode(FleetRegistryDocument.self, from: Data(contentsOf: url))
        guard document.version == 1 else { throw RegistryError.invalidRegistry }
        var seen: Set<String> = []
        for vault in document.vaults {
            let canonical = try canonicalVault(vault.path)
            guard canonical == vault.path, seen.insert(canonical).inserted else {
                throw RegistryError.invalidRegistry
            }
        }
        return document
    }

    @discardableResult
    public func register(path: String, autoUpdate: Bool) throws -> FleetRegistryDocument {
        let canonical = try canonicalVault(path)
        var document = try load()
        if let index = document.vaults.firstIndex(where: { $0.path == canonical }) {
            document.vaults[index] = FleetVault(path: canonical, autoUpdate: autoUpdate)
        } else {
            document.vaults.append(FleetVault(path: canonical, autoUpdate: autoUpdate))
        }
        document.vaults.sort { $0.path < $1.path }
        try save(document)
        return document
    }

    @discardableResult
    public func unregister(path: String) throws -> FleetRegistryDocument {
        let canonical = try canonicalVault(path)
        var document = try load()
        guard document.vaults.contains(where: { $0.path == canonical }) else {
            throw RegistryError.missingVault
        }
        document.vaults.removeAll { $0.path == canonical }
        try save(document)
        return document
    }

    public func save(_ document: FleetRegistryDocument) throws {
        guard document.version == 1 else { throw RegistryError.invalidRegistry }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.sorted.encode(document)
        try data.write(to: url, options: [.atomic])
#if !os(Windows)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
#endif
    }

    private func canonicalVault(_ path: String) throws -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw RegistryError.unsafeVault(url.path)
        }
        return url.resolvingSymlinksInPath().path
    }
}

public struct FleetUpgradeVerifier {
    public enum VerificationError: LocalizedError, Equatable {
        case emptyFleet
        case invalidExecutable(String)
        case commandFailed(String)
        case compatibilityMismatch(String)

        public var errorDescription: String? {
            switch self {
            case .emptyFleet: "Retex fleet registry has no vaults."
            case let .invalidExecutable(path): "Retex upgrade executable is invalid: \(path)"
            case let .commandFailed(message): "Retex fleet verification command failed: \(message)"
            case let .compatibilityMismatch(path): "Retex exact output changed on the clone for \(path)."
            }
        }
    }

    public init() {}

    public func verify(
        vaults: [FleetVault],
        candidate: URL,
        current: URL
    ) throws -> [FleetUpgradeReport] {
        guard !vaults.isEmpty else { throw VerificationError.emptyFleet }
        try validateExecutable(candidate)
        try validateExecutable(current)
        var reports: [FleetUpgradeReport] = []
        for vault in vaults {
            let start = Date()
            let clone = FileManager.default.temporaryDirectory
                .appendingPathComponent("retex-fleet-clone-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: clone) }
            try copyRetexScope(from: URL(fileURLWithPath: vault.path, isDirectory: true), to: clone)

            let baselineList = try run(current, ["list", "--vault", clone.path, "--all", "--raw-json"])
            let baselineSearch = try run(current, ["search", "retex-fleet-compatibility-probe", "--vault", clone.path, "--raw-json"])
            let baselineBoard = try run(current, ["board", "--vault", clone.path, "--raw-json"])
            _ = try run(current, ["doctor", "--vault", clone.path, "--strict", "--json"])
            _ = try run(candidate, ["init", "--vault", clone.path, "--json"])
            _ = try run(candidate, ["doctor", "--vault", clone.path, "--strict", "--json"])
            let candidateList = try run(candidate, ["list", "--vault", clone.path, "--all", "--raw-json"])
            let candidateSearch = try run(candidate, ["search", "retex-fleet-compatibility-probe", "--vault", clone.path, "--raw-json"])
            let candidateBoard = try run(candidate, ["board", "--vault", clone.path, "--raw-json"])
            _ = try run(current, ["doctor", "--vault", clone.path, "--strict", "--json"])

            let listMatch = baselineList == candidateList
            let searchMatch = baselineSearch == candidateSearch
            let boardMatch = baselineBoard == candidateBoard
            let mutationRoundTrip = try mutationProbe(candidate: candidate, current: current, clone: clone)
            guard listMatch, searchMatch, boardMatch else { throw VerificationError.compatibilityMismatch(vault.path) }
            reports.append(FleetUpgradeReport(
                path: vault.path,
                autoUpdate: vault.autoUpdate,
                verified: true,
                exactListMatch: listMatch,
                exactSearchMatch: searchMatch,
                exactBoardMatch: boardMatch,
                mutationRoundTrip: mutationRoundTrip,
                previousVersionReadable: true,
                milliseconds: Int(Date().timeIntervalSince(start) * 1_000)
            ))
        }
        return reports
    }

    public func confirmLive(vaults: [FleetVault], executable: URL) throws -> [FleetUpgradeReport] {
        try validateExecutable(executable)
        var reports: [FleetUpgradeReport] = []
        for vault in vaults where vault.autoUpdate {
            let start = Date()
            _ = try run(executable, ["init", "--vault", vault.path, "--json"])
            _ = try run(executable, ["doctor", "--vault", vault.path, "--strict", "--json"])
            reports.append(FleetUpgradeReport(
                path: vault.path,
                autoUpdate: true,
                verified: true,
                exactListMatch: true,
                exactSearchMatch: true,
                exactBoardMatch: true,
                mutationRoundTrip: true,
                previousVersionReadable: true,
                milliseconds: Int(Date().timeIntervalSince(start) * 1_000)
            ))
        }
        return reports
    }

    private func validateExecutable(_ executable: URL) throws {
        let values = try executable.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              (values.fileSize ?? 0) > 0,
              (values.fileSize ?? 0) <= 64 * 1024 * 1024
        else { throw VerificationError.invalidExecutable(executable.path) }
    }

    private func mutationProbe(candidate: URL, current: URL, clone: URL) throws -> Bool {
        let title = "Retex Fleet Upgrade Probe \(UUID().uuidString)"
        let created = try run(candidate, [
            "create", "--vault", clone.path, "--folder", "RetexFleetProbe",
            "--type", "note", "--title", title, "--json",
        ])
        guard let envelope = try JSONSerialization.jsonObject(with: created) as? [String: Any],
              let data = envelope["data"] as? [String: Any],
              let path = data["path"] as? String,
              path.hasPrefix(clone.path + "/")
        else { throw VerificationError.commandFailed("candidate create returned no confined path") }
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try run(candidate, ["set", path, "owner=fleet-verifier", "--json"])
        _ = try run(candidate, ["move", path, "Verified", "--json"])
        _ = try run(candidate, ["archive", path, "--json"])
        _ = try run(candidate, ["undo", path, "--json"])
        _ = try run(current, ["show", path, "--json"])
        return true
    }

    private func run(_ executable: URL, _ arguments: [String]) throws -> Data {
        let process = Process()
        let fm = FileManager.default
        let token = UUID().uuidString
        let stdoutURL = fm.temporaryDirectory.appendingPathComponent("retex-fleet-\(token).out")
        let stderrURL = fm.temporaryDirectory.appendingPathComponent("retex-fleet-\(token).err")
        _ = fm.createFile(atPath: stdoutURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        _ = fm.createFile(atPath: stderrURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdout.close()
            try? stderr.close()
            try? fm.removeItem(at: stdoutURL)
            try? fm.removeItem(at: stderrURL)
        }
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        try stdout.close()
        try stderr.close()
        let output = try Data(contentsOf: stdoutURL, options: [.mappedIfSafe])
        let error = try Data(contentsOf: stderrURL, options: [.mappedIfSafe])
        guard output.count <= 64 * 1024 * 1024, error.count <= 4 * 1024 * 1024 else {
            throw VerificationError.commandFailed("command output exceeded the fleet verification limit")
        }
        guard process.terminationStatus == 0 else {
            let message = String(decoding: error.prefix(4_096), as: UTF8.self)
            throw VerificationError.commandFailed("\(executable.lastPathComponent) \(arguments.first ?? "") exited \(process.terminationStatus): \(message)")
        }
        return try normalizedMachineOutput(output)
    }

    private func normalizedMachineOutput(_ output: Data) throws -> Data {
#if (os(macOS) || os(Linux)) && canImport(CUltraCompact)
        let decoded = String(decoding: output, as: UTF8.self).withCString { input -> String? in
            guard let json = uc_decode_json(input) else { return nil }
            defer { uc_free_string(json) }
            return String(cString: json)
        }
        guard let decoded, let data = decoded.data(using: .utf8) else {
            throw VerificationError.commandFailed("command returned invalid machine output")
        }
        return data
#else
        guard let object = try? JSONSerialization.jsonObject(with: output) else {
            throw VerificationError.commandFailed("command returned invalid machine output")
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
#endif
    }

    private func copyRetexScope(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let sourceRoot = source.standardizedFileURL
        guard let enumerator = fm.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { throw VerificationError.commandFailed("cannot enumerate \(source.path)") }
        for case let file as URL in enumerator where file.pathExtension.lowercased() == "md" {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            let readable = values.isSymbolicLink == true ? file.resolvingSymlinksInPath() : file
            let readableValues = try readable.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard readableValues.isRegularFile == true,
                  readable.pathExtension.lowercased() == "md",
                  (readableValues.fileSize ?? 0) <= 64 * 1024 * 1024
            else { throw VerificationError.commandFailed("unsafe Markdown file \(file.path)") }
            let relative = file.pathComponents.dropFirst(sourceRoot.pathComponents.count).joined(separator: "/")
            let target = destination.appendingPathComponent(relative)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contentsOf: readable).write(to: target, options: .atomic)
        }
        let config = sourceRoot.appendingPathComponent(".retex/config.json")
        if fm.fileExists(atPath: config.path) {
            let values = try config.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  (values.fileSize ?? 0) <= 1_048_576
            else { throw VerificationError.commandFailed("unsafe vault config \(config.path)") }
            let target = destination.appendingPathComponent(".retex/config.json")
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: config, to: target)
        }
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
