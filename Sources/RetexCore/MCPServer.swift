import Foundation

/// Minimal MCP (Model Context Protocol) server over stdio, zero dependencies.
/// Speaks JSON-RPC 2.0 with newline-delimited messages (per the MCP stdio
/// transport spec) and exposes the vault through tools so any MCP host can
/// drive Retex.
public struct MCPServer {
    private let vault: Vault
    private let store: MarkdownStore
    private let input: FileHandle
    private let output: FileHandle

    public init(vault: Vault, store: MarkdownStore = MarkdownStore()) {
        self.init(
            vault: vault,
            store: store,
            input: .standardInput,
            output: .standardOutput
        )
    }

    /// Injectable streams keep the server testable without touching real stdio.
    init(
        vault: Vault,
        store: MarkdownStore = MarkdownStore(),
        input: FileHandle,
        output: FileHandle
    ) {
        self.vault = vault
        self.store = store
        self.input = input
        self.output = output
    }

    struct ToolDefinition: Encodable {
        let name: String
        let description: String
        let inputSchema: JSONValue
    }

    enum JSONValue: Encodable {
        case object([String: JSONValue])
        case string(String)
        case array([JSONValue])
        case bool(Bool)

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .object(let dict): try container.encode(dict)
            case .string(let value): try container.encode(value)
            case .array(let values): try container.encode(values)
            case .bool(let value): try container.encode(value)
            }
        }

        static func stringDict(_ dict: [String: String]) -> JSONValue {
            .object(dict.mapValues { .string($0) })
        }
    }

    /// Runs until stdin closes. Never writes anything but newline-delimited
    /// JSON-RPC messages to stdout; diagnostics belong on stderr.
    public func run() throws {
        var buffer = Data()
        while true {
            let chunk = input.readData(ofLength: 64 * 1024)
            guard !chunk.isEmpty else { break }
            buffer.append(chunk)

            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                let raw = String(data: Data(lineData), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                guard !raw.isEmpty else { continue }
                guard let request = try? JSONDecoder().decode(Request.self, from: Data(raw.utf8))
                else {
                    // JSON-RPC 2.0: unparseable requests get a -32700 with null id.
                    writeLine([
                        "jsonrpc": "2.0",
                        "id": NSNull(),
                        "error": ["code": -32700, "message": "Parse error"],
                    ])
                    continue
                }
                handle(request)
            }
        }
    }

    // MARK: - Wire types

    private struct Request: Decodable {
        let jsonrpc: String?
        let id: Id?
        let method: String
        let params: Params?

        enum CodingKeys: String, CodingKey { case jsonrpc, id, method, params }
    }

    private struct Params: Decodable {
        private enum CodingKeys: String, CodingKey { case name, arguments }

        let name: String?
        let arguments: [String: FlexibleValue]?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            if let raw = try? container.decodeIfPresent([String: FlexibleValue].self, forKey: .arguments) {
                arguments = raw
            } else if let strings = try? container.decodeIfPresent([String: String].self, forKey: .arguments) {
                arguments = strings.mapValues { .string($0) }
            } else {
                arguments = nil
            }
        }
    }

    private enum FlexibleValue: Decodable {
        case string(String)
        case number(Double)
        case bool(Bool)

        var stringValue: String {
            switch self {
            case .string(let value): value
            case .number(let value):
                // Plain formatting for integral values; %g would mangle large numbers.
                value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : "\(value)"
            case .bool(let value): value ? "true" : "false"
            }
        }
    }

    private enum Id: Codable {
        case number(Int)
        case string(String)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Int.self) {
                self = .number(value)
            } else {
                self = .string(try container.decode(String.self))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .number(let value): try container.encode(value)
            case .string(let value): try container.encode(value)
            }
        }
    }

    // MARK: - Dispatch

    private func handle(_ request: Request) {
        // Notifications (no id) get no response per JSON-RPC.
        guard let rawId = request.id else { return }
        let id = rawId

        switch request.method {
        case "initialize":
            writeResponse(id: id, result: .object([
                "protocolVersion": .string("2024-11-05"),
                "capabilities": .object([
                    "tools": .object([:])
                ]),
                "serverInfo": .object([
                    "name": .string("retex"),
                    "version": .string("1.0.0"),
                ]),
            ]))
        case "ping":
            writeResponse(id: id, result: .object([:]))
        case "tools/list":
            writeResponse(id: id, result: .object(["tools": .array(toolDefinitions.map { tool in
                guard let data = try? JSONEncoder().encode(tool),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return .object([:]) }
                return Self.anyJSON(object)
            })]))
        case "tools/call":
            if let requested = request.params?.name, !knownTools.contains(requested) {
                writeError(id: id, code: -32602, message: "Unknown tool: \(requested)")
                return
            }
            do {
                let payload = try callTool(request.params)
                writeResponse(id: id, result: toolResult(text: Self.encodePretty(payload), isError: false))
            } catch let error as ToolError {
                // Tool execution failures are results with isError, not protocol errors.
                writeResponse(id: id, result: toolResult(text: error.message, isError: true))
            } catch {
                writeError(id: id, code: -32603, message: error.localizedDescription)
            }
        default:
            writeError(id: id, code: -32601, message: "Method not found: \(request.method)")
        }
    }

    private func toolResult(text: String, isError: Bool) -> JSONValue {
        .object([
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(text),
                ])
            ]),
            "isError": .bool(isError),
        ])
    }

    private func callTool(_ params: Params?) throws -> JSONValue {
        guard let name = params?.name else {
            throw ToolError(message: "tools/call requires params.name")
        }
        let args = params?.arguments ?? [:]
        func arg(_ key: String) -> String? {
            args[key]?.stringValue.isEmpty == false ? args[key]?.stringValue : nil
        }

        do {
            return try dispatchTool(name, args: args, arg: arg)
        } catch let error as ToolError {
            throw error
        } catch {
            // Storage-level failures are tool execution errors, not protocol errors.
            throw ToolError(message: "\(name) failed: \(error.localizedDescription)")
        }
    }

    private func dispatchTool(
        _ name: String,
        args: [String: FlexibleValue],
        arg: (String) -> String?
    ) throws -> JSONValue {
        switch name {
        case "list_notes":
            var notes = try store.scan(vault)
            if let type = arg("type") { notes = notes.filter { $0.type.rawValue == type } }
            if !((arg("archived") ?? "false").lowercased() == "true") { notes = notes.filter { !$0.isArchived } }
            return .stringDict([
                "count": String(notes.count),
                "notes": notes.map { "\($0.title)\t\($0.url.path)" }.joined(separator: "\n"),
            ])

        case "search_notes":
            guard let query = arg("query") else { throw ToolError(message: "search_notes requires query") }
            let notes = try store.scan(vault).filter { note in
                note.title.localizedCaseInsensitiveContains(query)
                    || note.body.localizedCaseInsensitiveContains(query)
                    || note.metadata.values.contains { $0.localizedCaseInsensitiveContains(query) }
                    || note.tags.contains { $0.localizedCaseInsensitiveContains(query) }
            }
            return .stringDict([
                "count": String(notes.count),
                "notes": notes.map { "\($0.title)\t\($0.url.path)" }.joined(separator: "\n"),
            ])

        case "read_note":
            guard let path = arg("path") else { throw ToolError(message: "read_note requires path") }
            let note = try store.load(URL(fileURLWithPath: NSString(string: path).expandingTildeInPath))
            return .stringDict([
                "title": note.title,
                "type": note.type.rawValue,
                "status": note.status,
                "tags": note.tags.joined(separator: ", "),
                "metadata": note.metadata.sorted { $0.key < $1.key }
                    .map { "\($0.key): \($0.value)" }.joined(separator: "\n"),
                "body": note.body,
            ])

        case "create_note":
            guard let title = arg("title") else { throw ToolError(message: "create_note requires title") }
            var metadata = ["type": arg("type") ?? NoteType.note.rawValue]
            if let status = arg("status") { metadata["status"] = status }
            for pair in (arg("set") ?? "").split(separator: ";") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                if parts.count == 2 { metadata[String(parts[0])] = String(parts[1]) }
            }
            let folder = arg("folder") ?? "Notes"
            let note = try store.createNote(
                in: vault,
                folder: folder,
                title: title,
                metadata: metadata,
                body: arg("body") ?? "# \(title)"
            )
            return .stringDict(["created": note.url.path])

        case "set_property":
            guard let path = arg("path") else { throw ToolError(message: "set_property requires path") }
            guard let key = arg("key"), let value = arg("value") else {
                throw ToolError(message: "set_property requires key and value")
            }
            let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            let note = try store.load(url)
            try store.updateMetadata(key, value: value, for: note)
            return .stringDict(["updated": url.path, "\(key)": value])

        case "move_card":
            guard let path = arg("path"), let status = arg("status") else {
                throw ToolError(message: "move_card requires path and status")
            }
            let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            let note = try store.load(url)
            var updates = ["status": status]
            if let rank = arg("rank") { updates["rank"] = rank }
            try store.updateMetadata(updates, for: note)
            return .stringDict(["moved": note.title, "status": status])

        case "archive_note":
            guard let path = arg("path") else { throw ToolError(message: "archive_note requires path") }
            let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            let note = try store.load(url)
            try store.updateMetadata("archived", value: "true", for: note)
            return .stringDict(["archived": url.path])

        case "get_stats":
            let notes = try store.scan(vault)
            let byType = Dictionary(grouping: notes, by: \.type.rawValue)
                .mapValues(\.count)
                .sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value)" }
                .joined(separator: ", ")
            return .stringDict([
                "notes": String(notes.count),
                "archived": String(notes.filter(\.isArchived).count),
                "byType": byType,
            ])

        case "get_board":
            let config = VaultConfig.load(for: vault)
            let deals = try store.scan(vault).filter { $0.type == .deal && !$0.isArchived }
            let columns = config.columns.map { column in
                let cards = deals.filter { column.statuses.contains($0.status) }.sorted { $0.rank < $1.rank }
                return "\(column.title):\n" + cards.map { "  [\($0.rank)] \($0.title)" }.joined(separator: "\n")
            }
            return .stringDict(["board": columns.joined(separator: "\n\n")])

        default:
            throw ToolError(message: "Unknown tool: \(name)")
        }
    }

    // MARK: - Output

    private func writeResponse(id: Id, result: JSONValue) {
        writeLine([
            "jsonrpc": "2.0",
            "id": Self.idJSON(id),
            "result": Self.raw(result),
        ])
    }

    private func writeError(id: Id, code: Int, message: String) {
        writeLine([
            "jsonrpc": "2.0",
            "id": Self.idJSON(id),
            "error": ["code": code, "message": message],
        ])
    }

    private func writeLine(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.withoutEscapingSlashes]
              )
        else { return }
        output.write(Data(data + [UInt8(ascii: "\n")]))
    }

    private static func encodePretty(_ value: JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return "{}" }
        return String(decoding: pretty, as: UTF8.self)
    }

    private static func idJSON(_ id: Id) -> Any {
        switch id {
        case .number(let value): value
        case .string(let value): value
        }
    }

    private static func raw(_ value: JSONValue) -> Any {
        switch value {
        case .string(let string): string
        case .array(let items): items.map(raw)
        case .object(let dict): dict.mapValues(raw)
        case .bool(let value): value
        }
    }

    private static func anyJSON(_ any: Any) -> JSONValue {
        if let string = any as? String { return .string(string) }
        if let array = any as? [Any] { return .array(array.map(anyJSON)) }
        if let dict = any as? [String: Any] {
            return .object(dict.mapValues(anyJSON))
        }
        if let number = any as? NSNumber { return .string(number.stringValue) }
        return .string("\(any)")
    }

    private var knownTools: Set<String> {
        Set(toolDefinitions.map(\.name))
    }

    private var toolDefinitions: [ToolDefinition] {
        [
            ToolDefinition(
                name: "list_notes",
                description: "List records in the vault. Optional: type (note|contact|deal|task|agent-run), archived (true|false).",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "type": .object(["type": .string("string")]),
                        "archived": .object(["type": .string("boolean")]),
                    ]),
                ])
            ),
            ToolDefinition(
                name: "search_notes",
                description: "Full-text search across titles, bodies, properties, and tags.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["query": .object(["type": .string("string")])]),
                    "required": .array([.string("query")]),
                ])
            ),
            ToolDefinition(
                name: "read_note",
                description: "Read one note's front matter properties and body.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["path": .object(["type": .string("string")])]),
                    "required": .array([.string("path")]),
                ])
            ),
            ToolDefinition(
                name: "create_note",
                description: "Create a note. Args: title (required), type, status, folder, body, set ('k=v;k=v').",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "title": .object(["type": .string("string")]),
                        "type": .object(["type": .string("string")]),
                        "status": .object(["type": .string("string")]),
                        "folder": .object(["type": .string("string")]),
                        "body": .object(["type": .string("string")]),
                        "set": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("title")]),
                ])
            ),
            ToolDefinition(
                name: "set_property",
                description: "Set one YAML front matter property on a note.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object(["type": .string("string")]),
                        "key": .object(["type": .string("string")]),
                        "value": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("path"), .string("key"), .string("value")]),
                ])
            ),
            ToolDefinition(
                name: "move_card",
                description: "Move a card to a board status. Optional rank.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object(["type": .string("string")]),
                        "status": .object(["type": .string("string")]),
                        "rank": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("path"), .string("status")]),
                ])
            ),
            ToolDefinition(
                name: "archive_note",
                description: "Archive a note non-destructively (sets archived: true).",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["path": .object(["type": .string("string")])]),
                    "required": .array([.string("path")]),
                ])
            ),
            ToolDefinition(
                name: "get_stats",
                description: "Vault statistics: total notes, archived count, per-type histogram.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                ])
            ),
            ToolDefinition(
                name: "get_board",
                description: "Get the Kanban board grouped by configured columns.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                ])
            ),
        ]
    }

    private struct ToolError: Error {
        let message: String
    }
}
