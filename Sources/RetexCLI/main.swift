import Darwin
import Foundation
import RetexCore

@main
enum RetexCLI {
    static func main() {
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
            let code: Int32 = error is UsageError ? 64 : 74
            writeError(
                error.localizedDescription,
                code: Int(code),
                json: CommandLine.arguments.contains("--json")
            )
            Darwin.exit(code)
        }
    }

    private static func run(_ invocation: Invocation) throws {
        let store = MarkdownStore()
        switch invocation.command {
        case "list":
            let vault = try invocation.vault()
            var notes = try store.scan(vault)
            if let type = invocation.option("type") { notes = notes.filter { $0.type.rawValue == type } }
            if let status = invocation.option("status") { notes = notes.filter { $0.status.caseInsensitiveCompare(status) == .orderedSame } }
            if !invocation.flag("all") { notes = notes.filter { !$0.isArchived } }
            try output(notes.map(NoteSummary.init), json: invocation.isJSON) {
                $0.map { "\($0.type.padding(toLength: 10, withPad: " ", startingAt: 0)) \($0.status.padding(toLength: 12, withPad: " ", startingAt: 0)) \($0.title)\n  \($0.path)" }.joined(separator: "\n")
            }

        case "search":
            let query = try invocation.positional(0, named: "query")
            let vault = try invocation.vault()
            let notes = try store.scan(vault).filter { note in
                note.title.localizedCaseInsensitiveContains(query)
                    || note.body.localizedCaseInsensitiveContains(query)
                    || note.metadata.values.contains { $0.localizedCaseInsensitiveContains(query) }
                    || note.tags.contains { $0.localizedCaseInsensitiveContains(query) }
            }
            try output(notes.map(NoteSummary.init), json: invocation.isJSON) {
                $0.map { "\($0.title)\n  \($0.path)" }.joined(separator: "\n")
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
            let type = NoteType(rawValue: metadata["type", default: "note"]) ?? .note
            let folder = invocation.option("folder") ?? defaultFolder(for: type)
            let body = invocation.option("body") ?? "# \(title)"
            let note = try store.createNote(in: vault, folder: folder, title: title, metadata: metadata, body: body)
            try output(NoteDetail(note), json: invocation.isJSON) { "Created \($0.path)" }

        case "set":
            let url = try invocation.noteURL()
            let note = try store.load(url)
            let updates = try invocation.keyValuePositionals(startingAt: 1)
            guard !updates.isEmpty else { throw UsageError("set requires one or more key=value pairs") }
            try store.updateMetadata(updates, for: note)
            let updated = try store.load(url)
            try output(NoteDetail(updated), json: invocation.isJSON) { "Updated \($0.path)" }

        case "move":
            let url = try invocation.noteURL()
            let status = try invocation.positional(1, named: "status")
            let note = try store.load(url)
            var updates = ["status": status]
            if let rank = invocation.option("rank") { updates["rank"] = rank }
            try store.updateMetadata(updates, for: note)
            let updated = try store.load(url)
            try output(NoteDetail(updated), json: invocation.isJSON) { "Moved \($0.title) to \($0.status)" }

        case "archive":
            let url = try invocation.noteURL()
            let note = try store.load(url)
            try store.updateMetadata("archived", value: "true", for: note)
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
                if let type = view.type { records = records.filter { $0.type.rawValue.caseInsensitiveCompare(type) == .orderedSame } }
                if let status = view.status { records = records.filter { $0.status.caseInsensitiveCompare(status) == .orderedSame } }
                if let tag = view.tag { records = records.filter { $0.tags.contains(tag) } }
            } else {
                records = records.filter { $0.type == .deal }
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
                ViewSummary(name: view.name, type: view.type, status: view.status, tag: view.tag)
            })
            try output(listing, json: invocation.isJSON) { listing in
                listing.views.isEmpty ? "No saved views." : listing.views.map { view in
                    var parts = [view.name]
                    if let type = view.type { parts.append("type=\(type)") }
                    if let status = view.status { parts.append("status=\(status)") }
                    if let tag = view.tag { parts.append("tag=\(tag)") }
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
            try output(runDoctor(vault), json: invocation.isJSON) { report in
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

        case "mcp":
            let vault = try invocation.vault()
            try MCPServer(vault: vault).run()

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
            let passphrase = try Self.passphrase(invocation)
            let blob = try Data(contentsOf: URL(fileURLWithPath: NSString(string: source).expandingTildeInPath))
            let archive = try VaultCrypto().decrypt(blob, passphrase: passphrase)
            let count = try VaultCrypto.restoreArchive(archive, into: URL(fileURLWithPath: NSString(string: into).expandingTildeInPath, isDirectory: true))
            try output(ImportOutput(into: into, notes: count), json: invocation.isJSON) { _ in
                "Restored \(count) notes into \(into)"
            }

        case "update":
            try runUpdate(invocation)

        case "version":
            print(RetexCLI.version)

        case "count":
            let vault = try invocation.vault()
            var counted = try store.scan(vault)
            if let type = invocation.option("type") { counted = counted.filter { $0.type.rawValue == type } }
            let total = counted.count
            let archivedCount = counted.filter(\.isArchived).count
            let byType = Dictionary(grouping: counted, by: \.type.rawValue)
                .mapValues(\.count)
                .sorted { $0.key < $1.key }
            let report = CountOutput(notes: total, archived: archivedCount, byType: byType.map { pair in
                TypeCount(type: pair.key, count: pair.value)
            })
            try output(report, json: invocation.isJSON) { _ in
                "\(total) notes (\(archivedCount) archived)"
            }

        case "watch":
            let vault = try invocation.vault()
            try runWatch(vault, json: invocation.isJSON)

        case "schema":
            let config = invocation.hasVault ? VaultConfig.load(for: try invocation.vault()) : nil
            let schema = SchemaOutput(
                recordTypes: NoteType.allCases.map(\.rawValue),
                coreProperties: ["title", "type", "status", "rank", "owner", "company", "value", "due", "next_action", "tags", "archived"],
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

    private static func runUpdate(_ invocation: Invocation) throws {
        let checker = UpdateChecker()
        let current = RetexCLI.version
        let release = try checker.latestRelease()
        guard UpdateChecker.isNewer(releaseTag: release.tag, current: current) else {
            try output(UpdateOutput(currentVersion: current, latestVersion: release.tag, updated: false, path: nil),
                       json: invocation.isJSON) { _ in
                "Already on the latest version (\(current))"
            }
            return
        }

        let tarball = try checker.download(release.assetURL)
        let sumsBody = String(decoding: try checker.download(release.checksumsURL), as: UTF8.self)
        guard let expected = UpdateChecker.expectedChecksum(in: sumsBody, assetName: "retex-universal.zip") else {
            throw UsageError("Release checksums do not list retex-universal.zip")
        }
        let actual = UpdateChecker.sha256(of: tarball)
        guard actual == expected.lowercased() else {
            throw UsageError("Checksum mismatch: expected \(expected), got \(actual)")
        }

        // Swap the running binary atomically; keep the old one for rollback.
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let previous = URL(fileURLWithPath: executable.path + ".previous")
        let fm = FileManager.default
        if fm.fileExists(atPath: previous.path) { try fm.removeItem(at: previous) }
        try fm.copyItem(at: executable, to: previous)
        let workDir = fm.temporaryDirectory.appendingPathComponent("retex-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        let zipPath = workDir.appendingPathComponent("retex-universal.zip")
        try tarball.write(to: zipPath, options: .atomic)
        let extract = Process()
        extract.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        extract.arguments = ["-x", "-k", zipPath.path, workDir.path]
        try extract.run()
        extract.waitUntilExit()
        guard extract.terminationStatus == 0,
              let newBinary = (try? fm.contentsOfDirectory(atPath: workDir.path))?
                  .first(where: { $0 == "retex" })
                  .map({ workDir.appendingPathComponent($0) }),
              fm.fileExists(atPath: newBinary.path)
        else {
            throw UsageError("Release archive did not contain a retex binary")
        }
        try fm.removeItem(at: executable)
        try fm.copyItem(at: newBinary, to: executable)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try? fm.removeItem(at: workDir)

        try output(UpdateOutput(currentVersion: current, latestVersion: release.tag, updated: true, path: executable.path),
                   json: invocation.isJSON) { _ in
            "Updated \(executable.path): \(current) -> \(release.tag). Rollback available at \(previous.path)"
        }
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

        signal(SIGINT, SIG_IGN)
        let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signalSource.setEventHandler { exit(0) }
        signalSource.resume()

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
        if FileManager.default.fileExists(atPath: journalURL.path),
           let raw = try? String(contentsOf: journalURL, encoding: .utf8) {
            for line in raw.split(separator: "\n", omittingEmptySubsequences: false) where !line.isEmpty {
                guard let data = String(line).data(using: .utf8),
                      (try? JSONDecoder().decode(UndoHistory.Entry.self, from: data)) != nil
                else {
                    journalOk = false
                    issues.append("Corrupt history entry at \(journalURL.path)")
                    break
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

    private static func output<T: Encodable>(
        _ value: T,
        json: Bool,
        human: (T) -> String
    ) throws {
        if json {
            let response = SuccessResponse(data: value)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            print(String(decoding: try encoder.encode(response), as: UTF8.self))
        } else {
            print(human(value))
        }
    }

    private static func defaultFolder(for type: NoteType) -> String {
        switch type {
        case .deal: "Deals"
        case .contact: "Contacts"
        case .agentRun: "Agent Runs"
        case .task: "Tasks"
        case .note: "Notes"
        }
    }

    private static func writeError(_ message: String, code: Int, json: Bool) {
        let payload: String
        if json, let data = try? JSONEncoder().encode(FailureResponse(error: .init(code: code, message: message))) {
            payload = String(decoding: data, as: UTF8.self) + "\n"
        } else {
            payload = "retex: \(message)\n"
        }
        FileHandle.standardError.write(Data(payload.utf8))
    }

    static let schemaVersion = 1
    static let version = "0.2.0"

    private static let help = """
    Retex CLI. Read and write a Markdown workspace without opening the app.

    USAGE
      retex <command> [arguments] [options]

    COMMANDS
      list      List records in a vault
      search    Search titles, properties, labels, and bodies
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
      doctor    Validate vault structure, config, and history journal
      watch     Stream file-change events for a vault (Ctrl-C to stop)
      mcp       Run the MCP server on stdio (JSON-RPC 2.0)
      export    Encrypt the vault into a portable file (sync by any channel)
      import    Decrypt and restore an encrypted vault export
      update    Check GitHub releases and upgrade this binary (verified)
      version   Print the CLI version

    EXAMPLES
      retex list --vault ~/Documents/CRM --type deal --json
      retex search "website rebuild" --vault ~/Documents/CRM --json
      retex create --vault ./CRM --type deal --title "Acme redesign" --status Inbox --set owner=Sam --set tags="[crm, priority]" --json
      retex set ./CRM/Deals/acme-redesign.md status=Qualified due=2026-08-01 --json
      retex move ./CRM/Deals/acme-redesign.md Proposal --rank 3 --json
      retex board --vault ./CRM --view pipeline --json
      retex undo ./CRM/Deals/acme-redesign.md --json
      retex doctor --vault ./CRM --json
      retex watch --vault ./CRM --json
      retex mcp --vault ./CRM
      retex export --vault ./CRM --out backup.retex --passphrase-env VAULT_PASS
      retex import --from backup.retex --into ~/Vaults/restored --passphrase-env VAULT_PASS
      retex update

    OPTIONS
      --vault <path>    Vault directory (required by most commands)
      --view <name>     Saved view name for board
      --out <file>      Destination for export
      --from <file>     Source encrypted file for import
      --into <dir>      Restore target directory for import
      --passphrase-env <VAR>
                        Environment variable holding the passphrase (never a
                        command-line value; prompts if omitted)
      --json            Stable machine-readable output
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
            } else if ["json", "all", "help"].contains(raw) {
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

    var isJSON: Bool { flag("json") }
    var hasVault: Bool { option("vault") != nil }

    func flag(_ name: String) -> Bool { flags.contains(name) }
    func option(_ name: String) -> String? { options[name]?.last }

    func requiredOption(_ name: String) throws -> String {
        guard let value = option(name) else { throw UsageError("--\(name) is required") }
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
        if expanded.hasPrefix("/") {
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
    let status: String
    let metadata: [String: String]
    let tags: [String]
    let body: String
    let modifiedAt: Date

    init(_ note: Note) {
        id = note.id
        path = note.url.path
        title = note.title
        type = note.type.rawValue
        status = note.status
        metadata = note.metadata
        tags = note.tags
        body = note.body
        modifiedAt = note.modifiedAt
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
    let statuses: [String]
    let views: [String]?
}

private struct ViewsOutput: Encodable {
    let views: [ViewSummary]
}

private struct ViewSummary: Encodable {
    let name: String
    let type: String?
    let status: String?
    let tag: String?
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
    let notes: Int
}

private struct UpdateOutput: Encodable {
    let currentVersion: String
    let latestVersion: String
    let updated: Bool
    let path: String?
}

private struct CountOutput: Encodable {
    let notes: Int
    let archived: Int
    let byType: [TypeCount]
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
