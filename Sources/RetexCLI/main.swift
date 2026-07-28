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
            let deals = try store.scan(vault).filter { $0.type == .deal && !$0.isArchived }
            let board = BoardOutput(
                columns: BoardColumn.defaultColumns.map { column in
                    BoardList(
                        name: column.title,
                        cards: deals.filter { column.statuses.contains($0.status) }
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

        case "schema":
            let schema = SchemaOutput(
                recordTypes: NoteType.allCases.map(\.rawValue),
                coreProperties: ["title", "type", "status", "rank", "owner", "company", "value", "due", "next_action", "tags", "archived"],
                statuses: BoardColumn.defaultColumns.map(\.title)
            )
            try output(schema, json: invocation.isJSON) { schema in
                "Record types: \(schema.recordTypes.joined(separator: ", "))\nProperties: \(schema.coreProperties.joined(separator: ", "))\nBoard lists: \(schema.statuses.joined(separator: ", "))"
            }

        default:
            throw UsageError("Unknown command: \(invocation.command ?? "")")
        }
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
      board     Print the Kanban board
      schema    Print the stable Retex record contract

    EXAMPLES
      retex list --vault ~/Documents/CRM --type deal --json
      retex search "website rebuild" --vault ~/Documents/CRM --json
      retex create --vault ./CRM --type deal --title "Acme redesign" --status Inbox --set owner=Sam --set tags="[crm, priority]" --json
      retex set ./CRM/Deals/acme-redesign.md status=Qualified due=2026-08-01 --json
      retex move ./CRM/Deals/acme-redesign.md Proposal --rank 3 --json
      retex board --vault ./CRM --json

    OPTIONS
      --vault <path>    Vault directory
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
    let error: Detail
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
}

private struct UsageError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
