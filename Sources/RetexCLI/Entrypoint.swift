#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(WinSDK)
import WinSDK
#endif
import Foundation
import RetexCore
#if canImport(CUltraCompact)
import CUltraCompact
#endif

private struct SimpleExit: Error {
    let code: Int32
}

@main
enum RetexCLI {
    static func main() {
        // Tag engine telemetry with this consumer (no overwrite of an
        // explicit operator setting). The engine only reads it when the
        // opt-in sink is enabled; no content ever leaves the machine.
        setenv("UC_TELEMETRY_SOURCE", "retex", 0)
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.isEmpty || arguments == ["--help"] {
            print(help)
            return
        }

        do {
            let invocation = try Invocation(arguments)
            if invocation.flag("help") {
                print(help)
                return
            }
            try run(invocation)
        } catch {
            if let simpleExit = error as? SimpleExit {
                terminate(simpleExit.code)
            }
            let code: Int32 = error is UsageError ? 64 : 74
            let lean = CommandLine.arguments.contains("--lean")
            writeError(
                error.localizedDescription,
                code: Int(code),
                json: CommandLine.arguments.contains("--json")
                    || CommandLine.arguments.contains("--raw-json")
                    || CommandLine.arguments.contains("--uc")
                    || lean,
                lean: lean
            )
            terminate(code)
        }
    }

    private static func terminate(_ code: Int32) -> Never {
        #if os(Windows)
        ExitProcess(UInt32(bitPattern: code))
        #else
        exit(code)
        #endif
    }

    private static func run(_ invocation: Invocation) throws {
        let store = MarkdownStore()
        switch invocation.command {
        case "init":
            let vault = try invocation.vault()
            let state = try UndoHistory.prepare(for: vault)
            try output(
                ["vault": vault.url.path, "state": state.path],
                json: invocation.isJSON
            ) { "Initialized Retex state at \($0["state", default: state.path])" }

        case "list":
            let vault = try invocation.vault()
            var notes = try filtered(store.scan(vault), invocation: invocation)
            if !invocation.flag("all") { notes = notes.filter { !$0.isArchived } }
            if let limit = try invocation.positiveIntOption("limit") {
                notes = Array(notes.prefix(limit))
            }
            try output(notes.map(NoteSummary.init), json: invocation.isJSON) {
                $0.map { "\($0.type.padding(toLength: 10, withPad: " ", startingAt: 0)) \($0.status.padding(toLength: 12, withPad: " ", startingAt: 0)) \($0.title)\n  \($0.path)" }.joined(separator: "\n")
            }

        case "query":
            let vault = try invocation.vault()
            var notes = try filtered(store.scan(vault), invocation: invocation)
            if !invocation.flag("all") { notes = notes.filter { !$0.isArchived } }
            if let limit = try invocation.positiveIntOption("limit") {
                notes = Array(notes.prefix(limit))
            }
            try output(notes.map(RecordSummary.init), json: invocation.isJSON) {
                $0.map { "\($0.type) \($0.title)\n  \($0.path)" }.joined(separator: "\n")
            }

        case "vocabulary":
            let vault = try invocation.vault()
            var notes = try filtered(store.scan(vault), invocation: invocation)
            if !invocation.flag("all") { notes = notes.filter { !$0.isArchived } }
            let limit = try invocation.positiveIntOption("limit", maximum: 10_000) ?? 256
            let vocabulary = VocabularyExtractor.extract(notes: notes, limit: limit)
            try output(vocabulary, json: invocation.isJSON) { result in
                result.terms.map { $0.term }.joined(separator: "\n")
            }

        case "search":
            let query = try invocation.positional(0, named: "query")
            let vault = try invocation.vault()
            var notes = try store.search(
                vault,
                query: query,
                ranked: invocation.flag("ranked")
            )
            notes = try filtered(notes, invocation: invocation)
            if !invocation.flag("all") { notes = notes.filter { !$0.isArchived } }
            if let limit = try invocation.positiveIntOption("limit") {
                notes = Array(notes.prefix(limit))
            }
            try output(notes.map(NoteSummary.init), json: invocation.isJSON) {
                $0.map { "\($0.title)\n  \($0.path)" }.joined(separator: "\n")
            }

        case "recall":
            let query = try invocation.positional(0, named: "query")
            let vault = try invocation.vault()
            let limit = try invocation.positiveIntOption("limit") ?? 20
            let budget = try invocation.positiveIntOption("budget", maximum: 1_000_000) ?? 12_000
            guard budget >= 256 else {
                throw UsageError("--budget must be an integer from 256 through 1000000")
            }
            let hits = try store.recall(
                vault,
                query: query,
                type: invocation.option("type"),
                status: invocation.option("status"),
                tag: invocation.option("tag"),
                metadata: invocation.keyValueOptions("where"),
                onOrBefore: invocation.dateFilters("on-or-before"),
                onOrAfter: invocation.dateFilters("on-or-after"),
                includeArchived: invocation.flag("all"),
                limit: limit
            )
            let recalled = packRecall(hits, query: query, budget: budget)
            try output(recalled, json: invocation.isJSON) { result in
                result.records.map {
                    "\($0.title) [score \($0.score)]\n  \($0.path)\n\($0.excerpt)"
                }.joined(separator: "\n\n")
            }

        case "links":
            let graph = try store.links(try invocation.vault(), for: invocation.noteURL())
            let output = LinksOutput(
                outgoing: graph.outgoing.map(RecordSummary.init),
                backlinks: graph.backlinks.map(RecordSummary.init),
                unresolved: graph.unresolved
            )
            try self.output(output, json: invocation.isJSON) { result in
                let outgoing = result.outgoing.map { "  -> \($0.title)\n     \($0.path)" }
                let backlinks = result.backlinks.map { "  <- \($0.title)\n     \($0.path)" }
                let unresolved = result.unresolved.map { "  ? \($0)" }
                return (["Outgoing:"] + outgoing + ["Backlinks:"] + backlinks + ["Unresolved:"] + unresolved)
                    .joined(separator: "\n")
            }

        case "show":
            let note = try store.load(invocation.noteURL())
            try output(NoteDetail(note), json: invocation.isJSON) { detail in
                let properties = detail.metadata.keys.sorted().map { "\($0): \(detail.metadata[$0, default: ""])" }.joined(separator: "\n")
                return "\(properties)\n\n\(detail.body)"
            }

        case "create":
            let vault = try invocation.vault()
            let title = try invocation.requiredOption("title")
            var metadata = try invocation.keyValueOptions("set")
            metadata["type"] = invocation.option("type") ?? metadata["type"] ?? NoteType.note.rawValue
            if let status = invocation.option("status") { metadata["status"] = status }
            let type = metadata["type", default: NoteType.note.rawValue]
            let config = VaultConfig.load(for: vault)
            let folder = invocation.option("folder") ?? config.folder(for: type)
            let body = invocation.option("body") ?? "# \(title)"
            let note = try store.createNote(in: vault, folder: folder, title: title, metadata: metadata, body: body)
            try output(NoteDetail(note), json: invocation.isJSON) { "Created \($0.path)" }

        case "set":
            let url = try invocation.noteURL()
            let note = try store.load(url)
            let updates = try invocation.keyValuePositionals(startingAt: 1)
            guard !updates.isEmpty else { throw UsageError("set requires one or more key=value pairs") }
            try store.updateMetadata(
                updates,
                for: note,
                expectedHash: invocation.option("if-hash")
            )
            let updated = try store.load(url)
            try output(NoteDetail(updated), json: invocation.isJSON) { "Updated \($0.path)" }

        case "move":
            let url = try invocation.noteURL()
            let status = try invocation.positional(1, named: "status")
            let note = try store.load(url)
            var updates = ["status": status]
            if let rank = invocation.option("rank") { updates["rank"] = rank }
            try store.updateMetadata(
                updates,
                for: note,
                expectedHash: invocation.option("if-hash")
            )
            let updated = try store.load(url)
            try output(NoteDetail(updated), json: invocation.isJSON) { "Moved \($0.title) to \($0.status)" }

        case "archive":
            let url = try invocation.noteURL()
            let note = try store.load(url)
            try store.updateMetadata(
                "archived",
                value: "true",
                for: note,
                expectedHash: invocation.option("if-hash")
            )
            let updated = try store.load(url)
            try output(NoteDetail(updated), json: invocation.isJSON) { "Archived \($0.path)" }

        case "board":
            let vault = try invocation.vault()
            let config = VaultConfig.load(for: vault)
            var records = try store.scan(vault).filter { !$0.isArchived }
            if let viewName = invocation.option("view") {
                guard let view = config.view(named: viewName) else {
                    throw UsageError("Unknown view: \(viewName)")
                }
                records = records.filter {
                    MarkdownStore.matches(
                        $0,
                        type: view.type,
                        status: view.status,
                        tag: view.tag,
                        metadata: view.properties ?? [:]
                    )
                }
            } else {
                records = records.filter { $0.recordType == NoteType.deal.rawValue }
            }
            let board = BoardOutput(
                columns: config.columns.map { column in
                    BoardList(
                        name: column.title,
                        cards: records.filter { column.statuses.contains($0.status) }
                            .sorted { $0.rank < $1.rank }
                            .map(NoteSummary.init)
                    )
                }
            )
            try output(board, json: invocation.isJSON) { board in
                board.columns.map { column in
                    let cards = column.cards.map { "  [\($0.rank)] \($0.title)" }.joined(separator: "\n")
                    return "\(column.name) (\(column.cards.count))\n\(cards)"
                }.joined(separator: "\n\n")
            }

        case "views":
            let vault = try invocation.vault()
            let config = VaultConfig.load(for: vault)
            let listing = ViewsOutput(views: config.views.map { view in
                ViewSummary(
                    name: view.name,
                    type: view.type,
                    status: view.status,
                    tag: view.tag,
                    properties: view.properties
                )
            })
            try output(listing, json: invocation.isJSON) { listing in
                listing.views.isEmpty ? "No saved views." : listing.views.map { view in
                    var parts = [view.name]
                    if let type = view.type { parts.append("type=\(type)") }
                    if let status = view.status { parts.append("status=\(status)") }
                    if let tag = view.tag { parts.append("tag=\(tag)") }
                    for (key, value) in (view.properties ?? [:]).sorted(by: { $0.key < $1.key }) {
                        parts.append("\(key)=\(value)")
                    }
                    return parts.joined(separator: " ")
                }.joined(separator: "\n")
            }

        case "undo":
            let url = try invocation.noteURL()
            guard let previous = try UndoHistory().pop(path: url.standardizedFileURL.path) else {
                throw UsageError("No undo history for \(url.path)")
            }
            try previous.write(to: url, atomically: true, encoding: .utf8)
            let restored = try store.load(url)
            try output(NoteDetail(restored), json: invocation.isJSON) { "Restored \($0.path)" }

        case "log":
            let url = try invocation.noteURL()
            let path = url.standardizedFileURL.path
            let entries = try UndoHistory().entries(for: path)
            let listing = HistoryOutput(entries: entries.map { entry in
                HistorySummary(path: entry.path, timestamp: entry.timestamp, bytes: entry.previousSource.utf8.count)
            })
            try output(listing, json: invocation.isJSON) { listing in
                listing.entries.isEmpty ? "No history for \(path)." : listing.entries.map { entry in
                    "\(entry.timestamp) \(entry.bytes) bytes"
                }.joined(separator: "\n")
            }

        case "doctor":
            let vault = try invocation.vault()
            let report = runDoctor(vault)
            try output(report, json: invocation.isJSON) { report in
                var lines = [
                    "Vault: \(report.vault)",
                    "Notes: \(report.notes) (\(report.archived) archived)",
                    "Config: \(report.configOk ? "ok" : "invalid")",
                    "Columns: \(report.columns.joined(separator: ", "))",
                    "Views: \(report.views)",
                    "Journal: \(report.journalOk ? "ok" : "unreadable")",
                ]
                if !report.issues.isEmpty {
                    lines.append("Issues:")
                    lines.append(contentsOf: report.issues.map { "  - \($0)" })
                }
                return lines.joined(separator: "\n")
            }
            if invocation.flag("strict"),
               !report.configOk || !report.journalOk || !report.issues.isEmpty {
                throw SimpleExit(code: 2)
            }

        case "mcp":
            let vault = try invocation.vault()
            try MCPServer(vault: vault, readOnly: !invocation.flag("allow-write"), uc: !invocation.flag("no-uc")).run()

        case "export":
            let vault = try invocation.vault()
            let destination = try invocation.requiredOption("out")
            let passphrase = try Self.passphrase(invocation)
            let archive = try VaultCrypto.makeArchive(vaultURL: vault.url)
            let blob = try VaultCrypto().encrypt(archive, passphrase: passphrase)
            try blob.write(
                to: URL(fileURLWithPath: NSString(string: destination).expandingTildeInPath),
                options: .atomic
            )
            try output(ExportOutput(destination: destination, bytes: blob.count), json: invocation.isJSON) { _ in
                "Encrypted vault written to \(destination) (\(blob.count) bytes)"
            }

        case "import":
            let source = try invocation.requiredOption("from")
            let into = try invocation.requiredOption("into")
            let sourceURL = URL(fileURLWithPath: NSString(string: source).expandingTildeInPath)
                .standardizedFileURL
            let destinationURL = URL(fileURLWithPath: NSString(string: into).expandingTildeInPath, isDirectory: true)
                .standardizedFileURL
            if sourceURL.pathExtension.lowercased() == "retex", invocation.option("format") == nil {
                let passphrase = try Self.passphrase(invocation)
                let blob = try Data(contentsOf: sourceURL)
                let archive = try VaultCrypto().decrypt(blob, passphrase: passphrase)
                let files = try VaultCrypto.restoreArchive(archive, into: destinationURL)
                _ = try UndoHistory.prepare(for: Vault(url: destinationURL))
                let notes = try store.scan(Vault(url: destinationURL)).count
                try output(ImportOutput(into: destinationURL.path, files: files, notes: notes), json: invocation.isJSON) {
                    "Restored \($0.files) files (\($0.notes) notes) into \($0.into)"
                }
            } else {
                let rawFormat = invocation.option("format") ?? VaultImportFormat.auto.rawValue
                guard let format = VaultImportFormat(rawValue: rawFormat) else {
                    throw UsageError("--format must be auto, notion, obsidian, or markdown")
                }
                let result = try VaultImporter().importSource(sourceURL, into: destinationURL, format: format)
                _ = try UndoHistory.prepare(for: Vault(url: destinationURL))
                try output(result, json: invocation.isJSON) {
                    "Imported \($0.notes) notes and \($0.assets) assets from \($0.format.rawValue) into \($0.destination)"
                }
            }

        case "fleet":
            try runFleet(invocation)
        case "update":
            try runUpdate(invocation)

        case "version":
            if invocation.flag("lean") {
                try output(RetexCLI.version, json: true) { $0 }
            } else {
                print(RetexCLI.version)
            }

        case "count":
            let vault = try invocation.vault()
            let counted = try filtered(store.scan(vault), invocation: invocation)
            let total = counted.count
            let archivedCount = counted.filter(\.isArchived).count
            let byType = Dictionary(grouping: counted, by: \.type.rawValue)
                .mapValues(\.count)
                .sorted { $0.key < $1.key }
            let byRecordType = Dictionary(grouping: counted, by: \.recordType)
                .mapValues(\.count)
                .sorted { $0.key < $1.key }
            let report = CountOutput(
                notes: total,
                archived: archivedCount,
                byType: byType.map { TypeCount(type: $0.key, count: $0.value) },
                byRecordType: byRecordType.map { TypeCount(type: $0.key, count: $0.value) }
            )
            try output(report, json: invocation.isJSON) { _ in
                "\(total) notes (\(archivedCount) archived)"
            }

        case "watch":
            let vault = try invocation.vault()
            try runWatch(vault, json: invocation.isJSON)

        case "schema":
            let vault = invocation.hasVault ? try invocation.vault() : nil
            let config = vault.map(VaultConfig.load(for:))
            let notes = try vault.map(store.scan) ?? []
            let recordTypes = Set(
                NoteType.allCases.map(\.rawValue)
                    + (config?.recordTypes.map(\.name) ?? [])
                    + notes.map(\.recordType)
            ).sorted()
            let discoveredProperties = Set(notes.flatMap { $0.metadata.keys }).sorted()
            let schema = SchemaOutput(
                recordTypes: recordTypes,
                coreProperties: ["title", "type", "status", "rank", "owner", "company", "value", "due", "next_action", "tags", "archived"],
                discoveredProperties: discoveredProperties,
                recordSchemas: (config?.recordTypes ?? []).map(RecordSchemaOutput.init),
                statuses: (config?.columns ?? BoardColumn.defaultColumns).map(\.title),
                views: config?.views.map(\.name) ?? []
            )
            try output(schema, json: invocation.isJSON) { schema in
                "Record types: \(schema.recordTypes.joined(separator: ", "))\nProperties: \(schema.coreProperties.joined(separator: ", "))\nBoard lists: \(schema.statuses.joined(separator: ", "))"
            }

        default:
            throw UsageError("Unknown command: \(invocation.command ?? "")")
        }
    }

    private static func promptPassphrase() throws -> String {
        FileHandle.standardError.write(Data("Passphrase: ".utf8))
        guard let line = String(data: FileHandle.standardInput.availableData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty else {
            throw UsageError("A non-empty passphrase is required")
        }
        return line
    }

    private static func passphrase(_ invocation: Invocation) throws -> String {
        // Passphrase comes from --passphrase-env or an interactive prompt;
        // command-line values would leak through process listings.
        if let envVar = invocation.option("passphrase-env"),
           let value = ProcessInfo.processInfo.environment[envVar], !value.isEmpty {
            return value
        }
        return try promptPassphrase()
    }

    private static func executableURL() -> URL {
        Bundle.main.executableURL?.standardizedFileURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    }

    private static func runFleet(_ invocation: Invocation) throws {
        let action = try invocation.positional(0, named: "fleet action")
        let registry = FleetRegistry()
        switch action {
        case "register":
            let vault = try invocation.vault()
            let document = try registry.register(path: vault.url.path, autoUpdate: invocation.flag("auto-update"))
            try output(document, json: invocation.isJSON) { result in
                "Registered \(vault.url.path) (\(result.vaults.count) fleet vaults; auto-update \(invocation.flag("auto-update") ? "on" : "off"))"
            }
        case "unregister":
            let vault = try invocation.vault()
            let document = try registry.unregister(path: vault.url.path)
            try output(document, json: invocation.isJSON) { result in
                "Unregistered \(vault.url.path) (\(result.vaults.count) fleet vaults remain)"
            }
        case "status":
            let document = try registry.load()
            try output(document, json: invocation.isJSON) { result in
                result.vaults.isEmpty ? "No fleet vaults registered." : result.vaults.map {
                    "\($0.autoUpdate ? "auto" : "manual") \($0.path)"
                }.joined(separator: "\n")
            }
        case "verify":
            let candidate = URL(fileURLWithPath: NSString(string: try invocation.requiredOption("candidate")).expandingTildeInPath)
                .standardizedFileURL
            let current = invocation.option("current").map {
                URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath).standardizedFileURL
            } ?? executableURL()
            let reports = try FleetUpgradeVerifier().verify(
                vaults: registry.load().vaults,
                candidate: candidate,
                current: current
            )
            try output(reports, json: invocation.isJSON) { reports in
                "Verified \(reports.count)/\(reports.count) fleet vaults in \(reports.reduce(0) { $0 + $1.milliseconds }) ms"
            }
        case "initialize":
            let reports = try FleetUpgradeVerifier().confirmLive(
                vaults: registry.load().vaults,
                executable: executableURL()
            )
            try output(reports, json: invocation.isJSON) { reports in
                "Initialized and strict-checked \(reports.count)/\(reports.count) opted-in vaults in \(reports.reduce(0) { $0 + $1.milliseconds }) ms"
            }
        case "install-updater":
            let executable = executableURL()
            let schedule = try AutoUpdateScheduler().install(executable: executable)
            try output(schedule, json: invocation.isJSON) { "Installed \($0.platform) updater at \($0.configurationPath)" }
        case "remove-updater":
            let schedule = try AutoUpdateScheduler().remove()
            try output(schedule, json: invocation.isJSON) { "Removed \($0.platform) updater from \($0.configurationPath)" }
        default:
            throw UsageError("fleet action must be register, unregister, status, verify, initialize, install-updater, or remove-updater")
        }
    }

    private static func runUpdate(_ invocation: Invocation) throws {
        guard !invocation.flag("auto") || invocation.flag("fleet") else {
            throw UsageError("--auto requires --fleet and an explicitly registered fleet")
        }
        let checker = UpdateChecker()
        let current = RetexCLI.version
        let release = try checker.latestRelease()
        guard UpdateChecker.isNewer(releaseTag: release.tag, current: current) else {
            try output(UpdateOutput(currentVersion: current, latestVersion: release.tag, updated: false, path: nil, fleetVerified: nil, fleetUpdated: nil, milliseconds: nil),
                       json: invocation.isJSON) { _ in
                "Already on the latest version (\(current))"
            }
            return
        }
        if invocation.flag("check") {
            try output(UpdateOutput(currentVersion: current, latestVersion: release.tag, updated: false, path: nil, fleetVerified: nil, fleetUpdated: nil, milliseconds: nil),
                       json: invocation.isJSON) { _ in
                "Update available: \(current) -> \(release.tag)"
            }
            return
        }

        let tarball = try checker.download(release.assetURL)
        let sumsBody = String(decoding: try checker.download(release.checksumsURL), as: UTF8.self)
        guard let expected = UpdateChecker.expectedChecksum(in: sumsBody, assetName: release.assetName) else {
            throw UsageError("Release checksums do not list one valid \(release.assetName) SHA-256")
        }
        let actual = UpdateChecker.sha256(of: tarball)
        guard actual == expected else {
            throw UsageError("Checksum mismatch: expected \(expected), got \(actual)")
        }

        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent(
            "retex-update-\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }
        let archivePath = workDir.appendingPathComponent(release.assetName)
        try tarball.write(to: archivePath, options: .atomic)
        let extract = Process()
#if os(macOS)
        extract.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        extract.arguments = ["-x", "-k", archivePath.path, workDir.path]
        let binaryName = "retex"
#elseif os(Windows)
        extract.executableURL = URL(fileURLWithPath: "C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe")
        extract.arguments = ["-NoProfile", "-NonInteractive", "-Command", "Expand-Archive -LiteralPath $args[0] -DestinationPath $args[1] -Force", archivePath.path, workDir.path]
        let binaryName = "retex.exe"
#else
        extract.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        extract.arguments = ["-xzf", archivePath.path, "-C", workDir.path]
        let binaryName = "retex"
#endif
        extract.standardOutput = Pipe()
        extract.standardError = Pipe()
        try extract.run()
        extract.waitUntilExit()
        let newBinary = workDir.appendingPathComponent(binaryName)
        guard extract.terminationStatus == 0, fm.fileExists(atPath: newBinary.path) else {
            throw UsageError("Release archive did not contain a \(binaryName) binary")
        }
        try validateUpdateCandidate(newBinary, releaseTag: release.tag)

        let executable = executableURL()
        let fleetDocument = invocation.flag("fleet") ? try FleetRegistry().load() : nil
        let verifier = FleetUpgradeVerifier()
        let verified = try fleetDocument.map {
            try verifier.verify(vaults: $0.vaults, candidate: newBinary, current: executable)
        } ?? []
        let previous = try UpdateChecker.install(candidate: newBinary, over: executable)
        let liveVaults = fleetDocument.map { document in
            invocation.flag("auto")
                ? document.vaults
                : document.vaults.map { FleetVault(path: $0.path, autoUpdate: true) }
        } ?? []
        let confirmed: [FleetUpgradeReport]
        do {
            confirmed = try verifier.confirmLive(vaults: liveVaults, executable: executable)
        } catch {
            _ = try? UpdateChecker.install(candidate: previous, over: executable)
            throw error
        }
        let milliseconds = verified.reduce(0) { $0 + $1.milliseconds } + confirmed.reduce(0) { $0 + $1.milliseconds }
        try output(UpdateOutput(
            currentVersion: current,
            latestVersion: release.tag,
            updated: true,
            path: executable.path,
            fleetVerified: fleetDocument == nil ? nil : verified.count,
            fleetUpdated: fleetDocument == nil ? nil : confirmed.count,
            milliseconds: fleetDocument == nil ? nil : milliseconds
        ), json: invocation.isJSON) { result in
            let fleet = result.fleetVerified.map { " Fleet: \($0) verified, \(result.fleetUpdated ?? 0) initialized in \(result.milliseconds ?? 0) ms." } ?? ""
            return "Updated \(executable.path): \(current) -> \(release.tag). Rollback available at \(previous.path).\(fleet)"
        }
    }

    private static func validateUpdateCandidate(_ candidate: URL, releaseTag: String) throws {
        let values = try candidate.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              (values.fileSize ?? 0) > 0,
              (values.fileSize ?? 0) <= 64 * 1024 * 1024
        else {
            throw UsageError("Release candidate must be one bounded regular file")
        }

#if os(macOS)
        let requirement = #"=identifier "retex" and anchor apple generic and certificate leaf[subject.OU] = "T63VT9UAY2""#
        try runValidationProcess(
            executable: "/usr/bin/codesign",
            arguments: ["--verify", "--strict", "-R", requirement, candidate.path],
            failure: "Release candidate failed Developer ID identity verification"
        )
        try runValidationProcess(
            executable: "/usr/sbin/spctl",
            arguments: ["-a", "-t", "install", candidate.path],
            failure: "Release candidate is not accepted by Gatekeeper"
        )
#endif

        let output = Pipe()
        let version = Process()
        version.executableURL = candidate
        version.arguments = ["version"]
        version.standardOutput = output
        version.standardError = Pipe()
        try version.run()
        let reported = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        version.waitUntilExit()
        let expected = releaseTag.trimmingCharacters(in: CharacterSet(charactersIn: "v "))
        guard version.terminationStatus == 0, reported == expected else {
            throw UsageError("Release candidate version \(reported) does not match \(expected)")
        }
    }

    private static func runValidationProcess(
        executable: String,
        arguments: [String],
        failure: String
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UsageError(failure) }
    }

    private static func runWatch(_ vault: Vault, json: Bool) throws {
        let printQueue = DispatchQueue(label: "retex.watch.output")
        let watcher = VaultWatcher(vault: vault, queue: printQueue) { paths in
            let markdown = paths.filter { $0.lowercased().hasSuffix(".md") }
            guard !markdown.isEmpty else { return }
            if json,
               let data = try? JSONSerialization.data(
                   withJSONObject: ["changed": markdown],
                   options: [.sortedKeys, .withoutEscapingSlashes]
               ) {
                print(String(decoding: data, as: UTF8.self))
            } else {
                for path in markdown { print("changed \(path)") }
            }
        }
        try watcher.start()
        dispatchMain()
    }

    private static func runDoctor(_ vault: Vault) -> DoctorOutput {
        var issues: [String] = []
        let store = MarkdownStore()
        var notes: [Note] = []
        do {
            // Single walk: notes and unreadable diagnostics come together.
            let result = try store.scanWithDiagnostics(vault)
            notes = result.notes
            issues.append(contentsOf: result.unreadable.map { "Unreadable note: \($0)" })
        } catch {
            issues.append("Scan failed: \(error.localizedDescription)")
        }

        let configURL = VaultConfig.url(for: vault)
        var configOk = true
        if FileManager.default.fileExists(atPath: configURL.path) {
            if let data = try? Data(contentsOf: configURL),
               (try? JSONDecoder().decode(VaultConfig.self, from: data)) != nil {
            } else {
                configOk = false
                issues.append("Unreadable .retex/config.json")
            }
        }
        let config = configOk ? VaultConfig.load(for: vault) : .default

        let journalURL = UndoHistory.journalURL(for: vault)
        var journalOk = true
        if FileManager.default.fileExists(atPath: journalURL.path) {
            do {
                let raw = try String(contentsOf: journalURL, encoding: .utf8)
                for line in raw.split(separator: "\n", omittingEmptySubsequences: false) where !line.isEmpty {
                    guard let data = String(line).data(using: .utf8),
                          (try? JSONDecoder().decode(UndoHistory.Entry.self, from: data)) != nil
                    else {
                        journalOk = false
                        issues.append("Corrupt history entry at \(journalURL.path)")
                        break
                    }
                }
            } catch {
                journalOk = false
                issues.append("Unreadable undo journal at \(journalURL.path)")
            }
        }

        for schema in config.recordTypes {
            let name = schema.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty {
                issues.append("Configured record type has an empty name")
                continue
            }
            if let folder = schema.folder,
               (folder as NSString).isAbsolutePath
                || folder.split(whereSeparator: { $0 == "/" || $0 == "\\" }).contains("..") {
                issues.append("Record type \(name) has an unsafe folder")
            }
            for note in notes where note.recordType.caseInsensitiveCompare(name) == .orderedSame {
                let missing = schema.required.filter {
                    note.metadata[$0]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
                }
                if !missing.isEmpty {
                    issues.append("\(note.url.path) is missing required properties: \(missing.sorted().joined(separator: ", "))")
                }
            }
        }


        return DoctorOutput(
            vault: vault.url.path,
            notes: notes.count,
            archived: notes.filter(\.isArchived).count,
            configOk: configOk,
            columns: config.columns.map(\.title),
            views: config.views.count,
            journalOk: journalOk,
            issues: issues
        )
    }

    /// Encode a value as a UC (UltraCompact) packet via the linked Rust
    /// library. Falls back to compact JSON if encoding fails.
    private static func ucPacket<T: Encodable>(_ value: T) throws -> String {
        #if canImport(CUltraCompact) && (os(macOS) || os(Linux))
        let response = SuccessResponse(data: value)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let jsonText = String(decoding: try encoder.encode(response), as: UTF8.self)
        return jsonText.withCString { inPtr in
            // Readable mode: agents read UC packets directly in model context.
            guard let packet = uc_encode_readable_json(inPtr, nil) else { return jsonText }
            defer { uc_free_string(packet) }
            return String(cString: packet)
        }
        #else
        // Public builds without the proprietary engine: canonical JSON.
        let response = SuccessResponse(data: value)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(response), as: UTF8.self)
        #endif
    }

    /// Encode the command payload directly for lean machine output. When the
    /// UC engine is unavailable or declines to encode, compact sorted JSON is
    /// the deterministic fallback.
    private static func leanPacket<T: Encodable>(_ value: T) throws -> String {
        let jsonText = try compactJSON(value)
        #if canImport(CUltraCompact) && (os(macOS) || os(Linux))
        return jsonText.withCString { inPtr in
            guard let packet = uc_encode_readable_json(inPtr, nil) else { return jsonText }
            defer { uc_free_string(packet) }
            return String(cString: packet)
        }
        #else
        return jsonText
        #endif
    }

    private static func compactJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func output<T: Encodable>(
        _ value: T,
        json: Bool,
        human: (T) -> String
    ) throws {
        // Existing machine modes retain their envelope and formatting. Lean
        // is additive: it removes the envelope, while --raw-json still wins
        // when exact JSON parsing is requested.
        let rawJson = CommandLine.arguments.contains("--raw-json")
        let lean = CommandLine.arguments.contains("--lean")
        if json && lean && rawJson {
            print(try compactJSON(value))
        } else if json && lean {
            print(try leanPacket(value))
        } else if json && !rawJson {
            print(try ucPacket(value))
        } else if json {
            let response = SuccessResponse(data: value)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            print(String(decoding: try encoder.encode(response), as: UTF8.self))
        } else {
            print(human(value))
        }
    }

    private static func filtered(_ notes: [Note], invocation: Invocation) throws -> [Note] {
        let type = invocation.option("type")
        let status = invocation.option("status")
        let tag = invocation.option("tag")
        let metadata = try invocation.keyValueOptions("where")
        let onOrBefore = try invocation.dateFilters("on-or-before")
        let onOrAfter = try invocation.dateFilters("on-or-after")
        guard type != nil
                || status != nil
                || tag != nil
                || !metadata.isEmpty
                || !onOrBefore.isEmpty
                || !onOrAfter.isEmpty
        else {
            return notes
        }
        return notes.filter {
            MarkdownStore.matches(
                $0,
                type: type,
                status: status,
                tag: tag,
                metadata: metadata,
                onOrBefore: onOrBefore,
                onOrAfter: onOrAfter
            )
        }
    }


    private static func packRecall(
        _ hits: [RecallHit],
        query: String,
        budget: Int
    ) -> RecallOutput {
        let encoder = JSONEncoder()
        var records: [RecallRecord] = []
        for hit in hits {
            let candidate = records + [RecallRecord(hit)]
            guard let bytes = try? encoder.encode(candidate).count, bytes <= budget else {
                continue
            }
            records = candidate
        }
        let usedBytes = (try? encoder.encode(records).count) ?? 0
        return RecallOutput(
            query: query,
            budgetBytes: budget,
            usedBytes: usedBytes,
            truncated: records.count < hits.count,
            records: records
        )
    }

    private static func writeError(_ message: String, code: Int, json: Bool, lean: Bool) {
        let payload: String
        if json, lean {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            if let data = try? encoder.encode(FailureResponse.Detail(code: code, message: message)) {
                payload = String(decoding: data, as: UTF8.self) + "\n"
            } else {
                payload = "retex: \(message)\n"
            }
        } else if json, let data = try? JSONEncoder().encode(FailureResponse(error: .init(code: code, message: message))) {
            payload = String(decoding: data, as: UTF8.self) + "\n"
        } else {
            payload = "retex: \(message)\n"
        }
        FileHandle.standardError.write(Data(payload.utf8))
    }

    static let schemaVersion = 1
    static let version = RetexBuild.version

    private static let help = """
    Retex CLI. Read and write a Markdown workspace without opening the app.

    USAGE
      retex <command> [arguments] [options]

    COMMANDS
      init      Initialize private vault-local Retex state (idempotent)
      list      Legacy-compatible compact record summaries with filters
      query     Structured records with exact arbitrary types and metadata
      vocabulary Extract bounded local names and custom terms without source text
      search    Exact or all-term ranked search
      recall    Agent recall with filler-word removal, evidence, and byte budget
      links     Resolve outgoing wiki links and backlinks for one record
      show      Print one Markdown record
      create    Create a record
      set       Set one or more YAML properties
      move      Move a card to a board list
      archive   Archive a card without deleting its file
      board     Print the Kanban board (--view <name> for a saved view)
      views     List saved views defined in .retex/config.json
      schema    Print the stable Retex record contract
      count     Fast note counts (--type filter supported)
      undo      Restore a record to its state before the last mutation
      log       List undo history entries for a record
      doctor    Validate vault structure, config, and journal (--strict gates)
      watch     Stream file-change events for a vault (Ctrl-C to stop)
      mcp       Run the read-only MCP server (--allow-write is explicit opt-in)
      export    Encrypt the vault and attachments into a portable file
      import    Restore encrypted Retex exports or import Notion/Obsidian vaults
      fleet     Register, verify, and safely initialize a vault fleet
      update    Check or install a verified GitHub release (--check is read-only)
      version   Print the CLI version

    EXAMPLES
      retex init --vault ~/Documents/CRM --lean
      retex query --vault ~/Documents/CRM --type invoice --where owner=Sam --tag priority --limit 100 --lean
      retex vocabulary --vault ~/Documents/CRM --limit 256 --lean
      retex search "website release" --vault ~/Documents/CRM --ranked --limit 20 --lean
      retex recall "what changed in the release" --vault ~/Documents/CRM --budget 12000 --lean
      retex links ~/Documents/CRM/Notes/release.md --vault ~/Documents/CRM --lean
      retex create --vault ./CRM --type invoice --title "Acme August" --set amount=11500 --lean
      retex set ./CRM/Deals/acme-redesign.md status=Qualified due=2026-08-01 --lean
      retex query --vault ./CRM --on-or-before review_after=2026-08-28 --lean
      retex move ./CRM/Deals/acme-redesign.md Proposal --rank 3 --lean
      retex board --vault ./CRM --view pipeline --lean
      retex undo ./CRM/Deals/acme-redesign.md --lean
      retex doctor --vault ./CRM --strict --lean
      retex watch --vault ./CRM --lean
      retex mcp --vault ./CRM
      retex export --vault ./CRM --out backup.retex --passphrase-env VAULT_PASS
      retex import --from backup.retex --into ~/Vaults/restored --passphrase-env VAULT_PASS
      retex import --from notion-export.zip --into ~/Vaults/notion --format notion --lean
      retex import --from ~/Documents/Obsidian --into ~/Vaults/obsidian --format obsidian --lean
      retex fleet register --vault ~/Vaults/CRM --auto-update --lean
      retex fleet install-updater --lean
      retex update --auto --fleet --lean
      retex update --check --lean
      retex list --vault ./CRM --all --raw-json  # compatibility gate

    OPTIONS
      --vault <path>    Vault directory (required by most commands)
      --view <name>     Saved view name for board
      --limit <count>   Bound list/search/recall/vocabulary results (1-10000)
      --budget <bytes>  Bound recall record array (256-1000000; default 12000)
      --type <name>     Filter any configured or ad-hoc record type
      --status <name>   Filter workflow state
      --tag <name>      Filter a tag
      --where k=v       Filter any property; repeat for AND semantics
      --on-or-before k=YYYY-MM-DD
                        Include records whose property date is on/before the value
      --on-or-after k=YYYY-MM-DD
                        Include records whose property date is on/after the value
      --if-hash <sha256>
                        Mutate only the exact record version previously read
      --ranked          Match all search terms and relevance-rank results
      --out <file>      Destination for export
      --from <path>     Retex export, Notion ZIP, or extracted vault directory
      --into <dir>      New or empty import destination
      --format <name>   auto, notion, obsidian, or markdown
      --passphrase-env <VAR>
                        Environment variable holding the passphrase (never a
                        command-line value; prompts if omitted)
      --allow-write     Add MCP mutation tools for a trusted local host
      --uc              Request UC machine output; equivalent to --json when
                        the engine is linked, canonical JSON otherwise
      --lean            Emit the command payload directly (UC when linked,
                        compact deterministic JSON otherwise)
      --no-uc           Disable UC for MCP tool results
      --raw-json        Force canonical JSON for CLI machine output; with
                        --lean, emit compact deterministic direct JSON
      --strict          Exit nonzero when doctor finds any integrity issue
      --auto-update     Opt one registered vault into post-verification init
      --fleet           Clone-verify every registered vault before update
      --auto            Scheduled fleet update; requires --fleet
      --candidate <bin> Verify one candidate against registered vault clones
      --current <bin>   Installed Retex binary for explicit fleet comparison
      --check           Check update availability without installing
      --json            Stable machine output (UC when linked, JSON otherwise)
      --all             Include archived records
      --help            Show this help
    """
}

private struct Invocation {
    let command: String?
    let positionals: [String]
    private let options: [String: [String]]
    private let flags: Set<String>

    init(_ arguments: [String]) throws {
        command = arguments.first
        var positionals: [String] = []
        var options: [String: [String]] = [:]
        var flags: Set<String> = []
        var index = 1

        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("--") else {
                positionals.append(argument)
                index += 1
                continue
            }

            let raw = String(argument.dropFirst(2))
            if let equals = raw.firstIndex(of: "=") {
                let key = String(raw[..<equals])
                let value = String(raw[raw.index(after: equals)...])
                options[key, default: []].append(value)
                index += 1
            } else if ["json", "uc", "lean", "raw-json", "no-uc", "all", "help", "allow-write", "ranked", "strict", "check", "auto", "fleet", "auto-update"].contains(raw) {
                flags.insert(raw)
                index += 1
            } else {
                guard index + 1 < arguments.count else { throw UsageError("--\(raw) requires a value") }
                options[raw, default: []].append(arguments[index + 1])
                index += 2
            }
        }

        self.positionals = positionals
        self.options = options
        self.flags = flags
    }

    var isJSON: Bool { flag("json") || flag("uc") || flag("lean") || flag("raw-json") }
    var hasVault: Bool { option("vault") != nil }

    func flag(_ name: String) -> Bool { flags.contains(name) }
    func option(_ name: String) -> String? { options[name]?.last }

    func requiredOption(_ name: String) throws -> String {
        guard let value = option(name) else { throw UsageError("--\(name) is required") }
        return value
    }

    func positiveIntOption(_ name: String, maximum: Int = 10_000) throws -> Int? {
        guard let raw = option(name) else { return nil }
        guard let value = Int(raw), value > 0, value <= maximum else {
            throw UsageError("--\(name) must be an integer from 1 through \(maximum)")
        }
        return value
    }

    func positional(_ index: Int, named name: String) throws -> String {
        guard positionals.indices.contains(index) else { throw UsageError("Missing \(name)") }
        return positionals[index]
    }

    func vault() throws -> Vault {
        let path = try requiredOption("vault")
        let url = resolve(path, directory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw UsageError("Vault does not exist: \(url.path)")
        }
        return Vault(url: url)
    }

    func noteURL() throws -> URL {
        resolve(try positional(0, named: "Markdown file"), directory: false)
    }

    func keyValueOptions(_ name: String) throws -> [String: String] {
        try parseKeyValues(options[name] ?? [])
    }

    func dateFilters(_ name: String) throws -> [String: String] {
        let filters = try keyValueOptions(name)
        do {
            try MarkdownStore.validateDateFilters(filters)
            return filters
        } catch {
            throw UsageError(error.localizedDescription)
        }
    }

    func keyValuePositionals(startingAt index: Int) throws -> [String: String] {
        try parseKeyValues(Array(positionals.dropFirst(index)))
    }

    private func parseKeyValues(_ values: [String]) throws -> [String: String] {
        try values.reduce(into: [:]) { result, pair in
            guard let separator = pair.firstIndex(of: "=") else {
                throw UsageError("Expected key=value, received \(pair)")
            }
            let key = String(pair[..<separator])
            let value = String(pair[pair.index(after: separator)...])
            guard !key.isEmpty else { throw UsageError("Property name cannot be empty") }
            result[key] = value
        }
    }

    private func resolve(_ path: String, directory: Bool) -> URL {
        let expanded = NSString(string: path).expandingTildeInPath
        if (expanded as NSString).isAbsolutePath {
            return URL(fileURLWithPath: expanded, isDirectory: directory).standardizedFileURL
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(expanded, isDirectory: directory)
            .standardizedFileURL
    }
}
private struct SuccessResponse<T: Encodable>: Encodable {

    let ok = true
    let data: T

    private enum CodingKeys: String, CodingKey {
        case ok
        case schemaVersion = "schema_version"
        case data
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(true, forKey: .ok)
        try container.encode(RetexCLI.schemaVersion, forKey: .schemaVersion)
        try container.encode(data, forKey: .data)
    }
}

private struct NoteSummary: Encodable {
    let id: String
    let path: String
    let title: String
    let type: String
    let status: String
    let owner: String
    let rank: Double
    let tags: [String]
    let due: String?
    let archived: Bool

    init(_ note: Note) {
        id = note.id
        path = note.url.path
        title = note.title
        type = note.type.rawValue
        status = note.status
        owner = note.owner
        rank = note.rank
        tags = note.tags
        due = note.dueDate
        archived = note.isArchived
    }
}

private struct RecordSummary: Encodable {
    let id: String
    let path: String
    let title: String
    let type: String
    let status: String
    let tags: [String]
    let metadata: [String: String]
    let archived: Bool

    init(_ note: Note) {
        id = note.id
        path = note.url.path
        title = note.title
        type = note.recordType
        status = note.status
        tags = note.tags
        metadata = note.metadata
        archived = note.isArchived
    }
}

private struct RecallOutput: Encodable {
    let query: String
    let budgetBytes: Int
    let usedBytes: Int
    let truncated: Bool
    let records: [RecallRecord]
}

private struct RecallRecord: Encodable {
    let id: String
    let path: String
    let title: String
    let type: String
    let status: String
    let tags: [String]
    let score: Int
    let matchedTerms: [String]
    let excerpt: String

    init(_ hit: RecallHit) {
        id = hit.note.id
        path = hit.note.url.path
        title = hit.note.title
        type = hit.note.recordType
        status = hit.note.status
        tags = hit.note.tags
        score = hit.score
        matchedTerms = hit.matchedTerms
        excerpt = hit.excerpt
    }
}

private struct LinksOutput: Encodable {
    let outgoing: [RecordSummary]
    let backlinks: [RecordSummary]
    let unresolved: [String]
}

private struct FailureResponse: Encodable {
    struct Detail: Encodable {
        let code: Int
        let message: String
    }

    let ok = false
    let schemaVersion = RetexCLI.schemaVersion
    let error: Detail

    private enum CodingKeys: String, CodingKey {
        case ok
        case schemaVersion = "schema_version"
        case error
    }
}

private struct NoteDetail: Encodable {
    let id: String
    let path: String
    let title: String
    let type: String
    let recordType: String
    let status: String
    let metadata: [String: String]
    let tags: [String]
    let body: String
    let modifiedAt: Date
    let contentHash: String

    init(_ note: Note) {
        id = note.id
        path = note.url.path
        title = note.title
        type = note.type.rawValue
        recordType = note.recordType
        status = note.status
        metadata = note.metadata
        tags = note.tags
        body = note.body
        modifiedAt = note.modifiedAt
        contentHash = note.contentHash
    }
}

private struct BoardOutput: Encodable {
    let columns: [BoardList]
}

private struct BoardList: Encodable {
    let name: String
    let cards: [NoteSummary]
}

private struct SchemaOutput: Encodable {
    let recordTypes: [String]
    let coreProperties: [String]
    let discoveredProperties: [String]
    let recordSchemas: [RecordSchemaOutput]
    let statuses: [String]
    let views: [String]?
}

private struct RecordSchemaOutput: Encodable {
    let name: String
    let folder: String?
    let required: [String]
    let properties: [String]

    init(_ schema: VaultConfig.RecordSchema) {
        name = schema.name
        folder = schema.folder
        required = schema.required
        properties = schema.properties
    }
}

private struct ViewsOutput: Encodable {
    let views: [ViewSummary]
}

private struct ViewSummary: Encodable {
    let name: String
    let type: String?
    let status: String?
    let tag: String?
    let properties: [String: String]?
}

private struct HistoryOutput: Encodable {
    let entries: [HistorySummary]
}

private struct HistorySummary: Encodable {
    let path: String
    let timestamp: Date
    let bytes: Int
}

private struct DoctorOutput: Encodable {
    let vault: String
    let notes: Int
    let archived: Int
    let configOk: Bool
    let columns: [String]
    let views: Int
    let journalOk: Bool
    let issues: [String]
}

private struct ExportOutput: Encodable {
    let destination: String
    let bytes: Int
}

private struct ImportOutput: Encodable {
    let into: String
    let files: Int
    let notes: Int
}

private struct UpdateOutput: Encodable {
    let currentVersion: String
    let latestVersion: String
    let updated: Bool
    let path: String?
    let fleetVerified: Int?
    let fleetUpdated: Int?
    let milliseconds: Int?
}

private struct CountOutput: Encodable {
    let notes: Int
    let archived: Int
    let byType: [TypeCount]
    let byRecordType: [TypeCount]
}

private struct TypeCount: Encodable {
    let type: String
    let count: Int
}

private struct UsageError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
