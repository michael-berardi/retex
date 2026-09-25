#if (os(macOS) || os(Linux)) && canImport(CUltraCompact)
import CUltraCompact
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

/// Minimal MCP (Model Context Protocol) server over stdio, zero dependencies.
/// Speaks JSON-RPC 2.0 with newline-delimited messages (per the MCP stdio
/// transport spec) and exposes the vault through tools so any MCP host can
/// drive Retex.
public struct MCPServer {
    private let vault: Vault
    private let store: MarkdownStore
    private let readOnly: Bool
    private let uc: Bool
    private let input: FileHandle
    private let output: FileHandle
    /// Dedicated agent-memory vault. nil resolves `$AGENT_MEMORY_VAULT` or
    /// `~/.local/share/agent-memory` at call time.
    private let memoryVault: Vault?

    public init(
        vault: Vault,
        store: MarkdownStore = MarkdownStore(),
        readOnly: Bool = true,
        uc: Bool = true,
        memoryVault: Vault? = nil
    ) {
        self.init(
            vault: vault,
            store: store,
            readOnly: readOnly,
            uc: uc,
            memoryVault: memoryVault,
            input: .standardInput,
            output: .standardOutput
        )
    }

    /// Injectable streams keep the server testable without touching real stdio.
    init(
        vault: Vault,
        store: MarkdownStore = MarkdownStore(),
        readOnly: Bool = true,
        uc: Bool = true,
        memoryVault: Vault? = nil,
        input: FileHandle,
        output: FileHandle
    ) {
        self.vault = vault
        self.store = store
        self.readOnly = readOnly
        self.uc = uc
        self.memoryVault = memoryVault
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
        // After an oversized request is rejected, its remaining bytes up to
        // the next newline are dropped instead of parsed as a new request.
        var discardingOversizedLine = false
        while true {
            let chunk = input.availableData
            guard !chunk.isEmpty else { break }
            buffer.append(chunk)

            var lineStart = buffer.startIndex
            while let newline = buffer[lineStart...].firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = buffer[lineStart..<newline]
                lineStart = buffer.index(after: newline)
                if discardingOversizedLine {
                    discardingOversizedLine = false
                    continue
                }
                guard lineData.count <= 1_048_576 else {
                    writeOversizedRequestError()
                    continue
                }
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
            // Consumed lines are dropped once per chunk, not once per line.
            buffer.removeSubrange(buffer.startIndex..<lineStart)
            if buffer.count > 1_048_576 {
                if !discardingOversizedLine { writeOversizedRequestError() }
                discardingOversizedLine = true
                buffer.removeAll(keepingCapacity: false)
            }
        }
    }

    private func writeOversizedRequestError() {
        writeLine([
            "jsonrpc": "2.0",
            "id": NSNull(),
            "error": ["code": -32700, "message": "Request exceeds 1048576 bytes"],
        ])
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
        let protocolVersion: String?
        private enum CodingKeys: String, CodingKey { case name, arguments, protocolVersion }

        let name: String?
        let arguments: [String: FlexibleValue]?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            protocolVersion = try container.decodeIfPresent(String.self, forKey: .protocolVersion)
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

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(String.self) {
                self = .string(value)
            } else if let value = try? container.decode(Bool.self) {
                self = .bool(value)
            } else {
                self = .number(try container.decode(Double.self))
            }
        }

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
            // Negotiate: echo the client's requested revision when retex's
            // tool surface supports it; newer SDKs otherwise drop the
            // response and hang on version mismatch.
            let requested = request.params?.protocolVersion ?? ""
            let supported = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]
            let negotiated = supported.contains(requested) ? requested : "2024-11-05"
            var result: [String: JSONValue] = [
                "protocolVersion": .string(negotiated),
                "capabilities": .object([
                    "tools": .object([:])
                ]),
                "serverInfo": .object([
                    "name": .string("retex"),
                    "version": .string(RetexVersion.version),
                ]),
            ]
            if uc {
                result["instructions"] = .string(
                    "Tool results use UltraCompact, a proprietary token-efficient encoding. Packets are model-readable text; decode to canonical JSON with the uc CLI only when exact JSON form is required."
                )
            }
            writeResponse(id: id, result: .object(result))
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
                writeResponse(id: id, result: toolResult(text: uc ? Self.ucPacket(payload) : ((try? AgentOutput.compactJSON(payload)) ?? "{}"), isError: false))
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

    private func confinedURL(_ path: String, markdownOnly: Bool = true) throws -> URL {
        let root = vault.url.standardizedFileURL.resolvingSymlinksInPath()
        let expanded = NSString(string: path).expandingTildeInPath
        let unresolved = (expanded as NSString).isAbsolutePath
            ? URL(fileURLWithPath: expanded)
            : root.appendingPathComponent(expanded)
        let candidate = unresolved.standardizedFileURL.resolvingSymlinksInPath()
        guard isWithinVault(candidate, root: root) else {
            throw ToolError(message: "path must stay within the vault")
        }
        guard !markdownOnly || candidate.pathExtension.lowercased() == "md" else {
            throw ToolError(message: "path must identify a Markdown note")
        }
        return candidate
    }

    private func notesInVault() throws -> [Note] {
        try store.scan(vault).filter(isConfined)
    }

    /// Scanned notes sit lexically under the vault and the scanner never
    /// descends symlinked directories, so only a symlinked note file can point
    /// outside; everything else skips the two `realpath` calls per note.
    private func isConfined(_ note: Note) -> Bool {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        var info = stat()
        if lstat(note.url.path, &info) == 0,
           (info.st_mode & S_IFMT) != S_IFLNK,
           note.url.pathExtension.lowercased() == "md",
           isWithinVault(note.url, root: vault.url) {
            return true
        }
        #endif
        return (try? confinedURL(note.url.path)) != nil
    }

    private func dispatchTool(
        _ name: String,
        args: [String: FlexibleValue],
        arg: (String) -> String?
    ) throws -> JSONValue {
        switch name {
        case "list_notes":
            var notes = try notesInVault()
            if let type = arg("type") { notes = notes.filter { $0.recordType.caseInsensitiveCompare(type) == .orderedSame } }
            if !((arg("archived") ?? "false").lowercased() == "true") { notes = notes.filter { !$0.isArchived } }
            if let limit = try positiveLimit(arg("limit")) {
                notes = Array(notes.prefix(limit))
            }
            return .stringDict([
                "count": String(notes.count),
                "notes": notes.map { "\($0.title)\t\($0.url.path)" }.joined(separator: "\n"),
            ])

        case "search_notes":
            guard let query = arg("query") else { throw ToolError(message: "search_notes requires query") }
            let requestedLimit = try positiveLimit(arg("limit"))
            var notes = try store.search(
                vault,
                query: query,
                ranked: (arg("ranked") ?? "false").lowercased() == "true"
            ).filter(isConfined)
            if let requestedLimit {
                notes = Array(notes.prefix(requestedLimit))
            }
            return .stringDict([
                "count": String(notes.count),
                "notes": notes.map { "\($0.title)\t\($0.url.path)" }.joined(separator: "\n"),
            ])

        case "read_note":
            guard let path = arg("path") else { throw ToolError(message: "read_note requires path") }
            let note = try store.load(confinedURL(path))
            return .stringDict([
                "title": note.title,
                "type": note.type.rawValue,
                "recordType": note.recordType,
                "status": note.status,
                "tags": note.tags.joined(separator: ", "),
                "metadata": note.metadata.sorted { $0.key < $1.key }
                    .map { "\($0.key): \($0.value)" }.joined(separator: "\n"),
                "body": note.body,
                "contentHash": note.contentHash,
            ])

        case "create_note":
            guard let title = arg("title") else { throw ToolError(message: "create_note requires title") }
            var metadata = ["type": arg("type") ?? NoteType.note.rawValue]
            if let status = arg("status") { metadata["status"] = status }
            for pair in (arg("set") ?? "").split(separator: ";") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                if parts.count == 2 { metadata[String(parts[0])] = String(parts[1]) }
            }
            let config = VaultConfig.load(for: vault)
            let folder = arg("folder") ?? config.folder(
                for: metadata["type", default: NoteType.note.rawValue]
            )
            let expandedFolder = NSString(string: folder).expandingTildeInPath
            guard !(expandedFolder as NSString).isAbsolutePath else {
                throw ToolError(message: "folder must be relative to the vault")
            }
            _ = try confinedURL(expandedFolder, markdownOnly: false)
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
            let url = try confinedURL(path)
            let note = try store.load(url)
            try store.updateMetadata(
                key,
                value: value,
                for: note,
                expectedHash: arg("expected_hash")
            )
            return .stringDict(["updated": url.path, "\(key)": value])

        case "move_card":
            guard let path = arg("path"), let status = arg("status") else {
                throw ToolError(message: "move_card requires path and status")
            }
            let url = try confinedURL(path)
            let note = try store.load(url)
            var updates = ["status": status]
            if let rank = arg("rank") { updates["rank"] = rank }
            try store.updateMetadata(
                updates,
                for: note,
                expectedHash: arg("expected_hash")
            )
            return .stringDict(["moved": note.title, "status": status])

        case "archive_note":
            guard let path = arg("path") else { throw ToolError(message: "archive_note requires path") }
            let url = try confinedURL(path)
            let note = try store.load(url)
            try store.updateMetadata(
                "archived",
                value: "true",
                for: note,
                expectedHash: arg("expected_hash")
            )
            return .stringDict(["archived": url.path])

        case "query_records":
            let filters = try propertyFilters(arg("where"))
            let onOrBefore = try dateFilters(arg("on_or_before"))
            let onOrAfter = try dateFilters(arg("on_or_after"))
            var notes = try notesInVault().filter {
                MarkdownStore.matches(
                    $0,
                    type: arg("type"),
                    status: arg("status"),
                    tag: arg("tag"),
                    metadata: filters,
                    onOrBefore: onOrBefore,
                    onOrAfter: onOrAfter
                )
            }
            if !((arg("archived") ?? "false").lowercased() == "true") {
                notes = notes.filter { !$0.isArchived }
            }
            let total = notes.count
            let limit = try positiveLimit(arg("limit")) ?? 100
            notes = Array(notes.prefix(limit))
            return .object([
                "count": .string(String(notes.count)),
                "total": .string(String(total)),
                "truncated": .bool(notes.count < total),
                "records": .array(notes.map(Self.recordJSON)),
            ])

        case "recall_context":
            guard let query = arg("query") else { throw ToolError(message: "recall_context requires query") }
            let limit = try positiveLimit(arg("limit")) ?? 20
            let budget = try positiveInteger(arg("budget"), name: "budget", maximum: 1_000_000) ?? 12_000
            guard budget >= 256 else {
                throw ToolError(message: "budget must be an integer from 256 through 1000000")
            }
            let includeArchived = (arg("archived") ?? "false").lowercased() == "true"
            let filters = try propertyFilters(arg("where"))
            let hits = try store.recall(
                vault,
                query: query,
                type: arg("type"),
                status: arg("status"),
                tag: arg("tag"),
                metadata: filters,
                onOrBefore: try dateFilters(arg("on_or_before")),
                onOrAfter: try dateFilters(arg("on_or_after")),
                includeArchived: includeArchived,
                limit: limit
            ).filter { isConfined($0.note) }
            let encoder = JSONEncoder()
            var records: [JSONValue] = []
            // A compact JSON array is "[", its elements joined by ",", and
            // "]", so each record is encoded once, not the growing array.
            var usedBytes = 2
            for hit in hits {
                let record = Self.recallJSON(hit)
                guard let recordBytes = try? encoder.encode(record).count else { continue }
                let candidateBytes = usedBytes + recordBytes + (records.isEmpty ? 0 : 1)
                guard candidateBytes <= budget else { continue }
                records.append(record)
                usedBytes = candidateBytes
            }
            return .object([
                "query": .string(query),
                "budgetBytes": .string(String(budget)),
                "usedBytes": .string(String(usedBytes)),
                "truncated": .bool(records.count < hits.count),
                "records": .array(records),
            ])

        case "get_links":
            guard let path = arg("path") else { throw ToolError(message: "get_links requires path") }
            let limit = try positiveLimit(arg("limit")) ?? 100
            let graph = try store.links(vault, for: confinedURL(path))
            let allOutgoing = graph.outgoing.filter(isConfined)
            let allBacklinks = graph.backlinks.filter(isConfined)
            let outgoing = Array(allOutgoing.prefix(limit))
            let backlinks = Array(allBacklinks.prefix(limit))
            return .object([
                "outgoing": .array(outgoing.map(Self.recordJSON)),
                "backlinks": .array(backlinks.map(Self.recordJSON)),
                "unresolved": .array(graph.unresolved.prefix(limit).map(JSONValue.string)),
                "truncated": .bool(
                    outgoing.count < allOutgoing.count
                        || backlinks.count < allBacklinks.count
                        || graph.unresolved.count > limit
                ),
            ])

        case "get_schema":
            let notes = try notesInVault()
            let config = VaultConfig.load(for: vault)
            let types = Set(
                NoteType.allCases.map(\.rawValue)
                    + config.recordTypes.map(\.name)
                    + notes.map(\.recordType)
            ).sorted()
            let properties = Set(notes.flatMap { $0.metadata.keys }).sorted()
            return .object([
                "recordTypes": .array(types.map(JSONValue.string)),
                "properties": .array(properties.map(JSONValue.string)),
                "configuredSchemas": .array(config.recordTypes.map(Self.schemaJSON)),
            ])

        case "get_stats":
            let notes = try notesInVault()
            let byType = Dictionary(grouping: notes, by: \.type.rawValue)
                .mapValues(\.count)
                .sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value)" }
                .joined(separator: ", ")
            let byRecordType = Dictionary(grouping: notes, by: \.recordType)
                .mapValues(\.count)
                .sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value)" }
                .joined(separator: ", ")
            return .stringDict([
                "notes": String(notes.count),
                "archived": String(notes.filter(\.isArchived).count),
                "byType": byType,
                "byRecordType": byRecordType,
            ])

        case "get_board":
            let config = VaultConfig.load(for: vault)
            let deals = try notesInVault().filter { $0.recordType == NoteType.deal.rawValue && !$0.isArchived }
            let columns = config.columns.map { column in
                let cards = deals.filter { column.statuses.contains($0.status) }.sorted { $0.rank < $1.rank }
                return "\(column.title):\n" + cards.map { "  [\($0.rank)] \($0.title)" }.joined(separator: "\n")
            }
            return .stringDict(["board": columns.joined(separator: "\n\n")])

        // Agent memory (read-only; promotion is never exposed over MCP).
        case "memory_context":
            let agentMemory = AgentMemory(store: store)
            if let scope = arg("scope"), scope != "global" {
                throw ToolError(message: "scope must be global")
            }
            let budget = try positiveInteger(arg("budget"), name: "budget", maximum: AgentMemory.maxBudget)
                ?? AgentMemory.defaultBudget
            let result = try agentMemory.context(
                vault: try memoryVaultOrThrow(),
                scope: arg("scope") ?? "global",
                project: arg("project"),
                budget: budget,
                harness: arg("harness")
            )
            return .object([
                "pack": .string(result.pack),
                "budget": .string(String(result.budget)),
                "usedBytes": .string(String(result.usedBytes)),
                "emitted": .string(String(result.emitted)),
                "totalActive": .string(String(result.totalActive)),
                "countersUpdated": .string(result.countersUpdated ? "true" : "false"),
            ])

        case "memory_recall":
            guard let query = arg("query") else { throw ToolError(message: "memory_recall requires query") }
            let budget = try positiveInteger(arg("budget"), name: "budget", maximum: 1_000_000)
                ?? AgentMemory.defaultRecallBudget
            let result = try AgentMemory(store: store).recall(
                vault: try memoryVaultOrThrow(),
                query: query,
                budget: budget,
                includeProposed: (arg("include_proposed") ?? "false").lowercased() == "true"
            )
            return .object([
                "query": .string(result.query),
                "budgetBytes": .string(String(result.budgetBytes)),
                "usedBytes": .string(String(result.usedBytes)),
                "truncated": .string(result.truncated ? "true" : "false"),
                "records": .array(result.records.map { item in
                    .object([
                        "key": .string(item.key),
                        "title": .string(item.title),
                        "path": .string(item.path),
                        "status": .string(item.status),
                        "score": .string(String(item.score)),
                        "excerpt": .string(item.excerpt),
                    ])
                }),
            ])

        case "memory_review":
            let items = try AgentMemory(store: store).review(vault: try memoryVaultOrThrow())
            return .object([
                "count": .string(String(items.count)),
                "proposals": .array(items.map { item in
                    .object([
                        "key": .string(item.key),
                        "title": .string(item.title),
                        "kind": .string(item.kind),
                        "support": .string(String(item.support)),
                        "distinctSessions": .string(String(item.distinctSessions)),
                        "promoteReady": .string(item.promoteReady ? "true" : "false"),
                    ])
                }),
            ])

        case "memory_propose":
            // Write tool: only exposed when the server runs with --allow-write.
            guard !readOnly else {
                throw ToolError(message: "memory_propose requires --allow-write")
            }
            guard let op = arg("op") else { throw ToolError(message: "memory_propose requires op") }
            var recordData: Data?
            if let record = arg("record") { recordData = Data(record.utf8) }
            let evidence = (arg("evidence") ?? "")
                .split(separator: ";")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let result = try AgentMemory(store: store).propose(
                vault: try memoryVaultOrThrow(),
                op: op,
                key: arg("key"),
                recordJSON: recordData,
                evidence: evidence,
                reason: arg("reason"),
                sourceHarness: arg("source_harness"),
                ifHash: arg("if_hash")
            )
            return .stringDict([
                "ok": "true",
                "op": result.op,
                "key": result.key,
                "path": result.path,
                "status": result.status,
                "contentHash": result.contentHash,
            ])

        default:
            throw ToolError(message: "Unknown tool: \(name)")
        }
    }

    private func positiveLimit(_ raw: String?) throws -> Int? {
        guard let raw else { return nil }
        guard let limit = Int(raw), (1...1_000).contains(limit) else {
            throw ToolError(message: "limit must be an integer from 1 through 1000")
        }
        return limit
    }

    /// The agent-memory vault: injected (tests, embedding hosts) or resolved
    /// from the environment. A missing vault is a tool error — memory tools
    /// never create the vault implicitly.
    private func memoryVaultOrThrow() throws -> Vault {
        if let memoryVault { return memoryVault }
        let url = AgentMemory.resolveVaultURL(
            explicit: nil,
            environment: ProcessInfo.processInfo.environment,
            homeDirectory: NSHomeDirectory()
        )
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ToolError(message: "agent memory vault not initialized")
        }
        return Vault(url: url)
    }

    private func positiveInteger(
        _ raw: String?,
        name: String,
        maximum: Int
    ) throws -> Int? {
        guard let raw else { return nil }
        guard let value = Int(raw), (1...maximum).contains(value) else {
            throw ToolError(message: "\(name) must be an integer from 1 through \(maximum)")
        }
        return value
    }

    private func propertyFilters(_ raw: String?) throws -> [String: String] {
        guard let raw, !raw.isEmpty else { return [:] }
        return try raw.split(separator: ";").reduce(into: [:]) { result, pair in
            let fields = pair.split(separator: "=", maxSplits: 1)
            guard fields.count == 2, !fields[0].isEmpty else {
                throw ToolError(message: "where must contain semicolon-separated key=value filters")
            }
            result[String(fields[0])] = String(fields[1])
        }
    }

    private func dateFilters(_ raw: String?) throws -> [String: String] {
        let filters = try propertyFilters(raw)
        try MarkdownStore.validateDateFilters(filters)
        return filters
    }

    private static func recordJSON(_ note: Note) -> JSONValue {
        .object([
            "id": .string(note.id),
            "path": .string(note.url.path),
            "title": .string(note.title),
            "type": .string(note.recordType),
            "status": .string(note.status),
            "tags": .array(note.tags.map(JSONValue.string)),
            "metadata": .object(note.metadata.mapValues(JSONValue.string)),
            "archived": .bool(note.isArchived),
        ])
    }

    private static func recallJSON(_ hit: RecallHit) -> JSONValue {
        .object([
            "id": .string(hit.note.id),
            "path": .string(hit.note.url.path),
            "title": .string(hit.note.title),
            "type": .string(hit.note.recordType),
            "status": .string(hit.note.status),
            "tags": .array(hit.note.tags.map(JSONValue.string)),
            "score": .string(String(hit.score)),
            "matchedTerms": .array(hit.matchedTerms.map(JSONValue.string)),
            "excerpt": .string(hit.excerpt),
        ])
    }

    private static func schemaJSON(_ schema: VaultConfig.RecordSchema) -> JSONValue {
        .object([
            "name": .string(schema.name),
            "folder": .string(schema.folder ?? ""),
            "required": .array(schema.required.map(JSONValue.string)),
            "properties": .array(schema.properties.map(JSONValue.string)),
        ])
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

    /// UC readable-mode packet for a tool payload. Falls back to compact JSON
    /// off macOS or if encoding fails. Agents read the packet directly.
    private static func ucPacket(_ value: JSONValue) -> String {
        (try? AgentOutput.encode(value)) ?? "{}"
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

    private static let readOnlyTools: Set<String> = [
        "list_notes", "search_notes", "read_note", "query_records",
        "recall_context", "get_links", "get_schema", "get_board", "get_stats",
        "memory_context", "memory_recall", "memory_review",
    ]

    private var knownTools: Set<String> {
        Set(toolDefinitions.map(\.name))
    }

    private var toolDefinitions: [ToolDefinition] {
        let definitions = [
            ToolDefinition(
                name: "list_notes",
                description: "List records in the vault. Optional: type, archived, and limit (1-1000).",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "type": .object(["type": .string("string")]),
                        "archived": .object(["type": .string("boolean")]),
                        "limit": .object(["type": .string("integer")]),
                    ]),
                ])
            ),
            ToolDefinition(
                name: "search_notes",
                description: "Search titles, bodies, properties, and tags. Set ranked=true for all-term relevance ordering; use limit to bound agent context.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object(["type": .string("string")]),
                        "ranked": .object(["type": .string("boolean")]),
                        "limit": .object(["type": .string("integer")]),
                    ]),
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
                        "expected_hash": .object(["type": .string("string")]),
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
                        "expected_hash": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("path"), .string("status")]),
                ])
            ),
            ToolDefinition(
                name: "archive_note",
                description: "Archive a note non-destructively (sets archived: true).",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object(["type": .string("string")]),
                        "expected_hash": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("path")]),
                ])
            ),
            ToolDefinition(
                name: "query_records",
                description: "Structured records filtered by arbitrary type, status, tag, and semicolon-separated key=value properties. Defaults to 100 results.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "type": .object(["type": .string("string")]),
                        "status": .object(["type": .string("string")]),
                        "tag": .object(["type": .string("string")]),
                        "where": .object(["type": .string("string")]),
                        "on_or_before": .object(["type": .string("string")]),
                        "on_or_after": .object(["type": .string("string")]),
                        "archived": .object(["type": .string("boolean")]),
                        "limit": .object(["type": .string("integer")]),
                    ]),
                ])
            ),
            ToolDefinition(
                name: "recall_context",
                description: "Agent recall that removes filler words, ranks partial matches, returns evidence excerpts, and enforces a byte budget.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object(["type": .string("string")]),
                        "type": .object(["type": .string("string")]),
                        "status": .object(["type": .string("string")]),
                        "tag": .object(["type": .string("string")]),
                        "where": .object(["type": .string("string")]),
                        "on_or_before": .object(["type": .string("string")]),
                        "on_or_after": .object(["type": .string("string")]),
                        "archived": .object(["type": .string("boolean")]),
                        "limit": .object(["type": .string("integer")]),
                        "budget": .object(["type": .string("integer")]),
                    ]),
                    "required": .array([.string("query")]),
                ])
            ),
            ToolDefinition(
                name: "get_links",
                description: "Resolve one note's outgoing wiki links, backlinks, and unresolved targets. Defaults to 100 per group.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object(["type": .string("string")]),
                        "limit": .object(["type": .string("integer")]),
                    ]),
                    "required": .array([.string("path")]),
                ])
            ),
            ToolDefinition(
                name: "get_schema",
                description: "Discover record types, properties, and configured record schemas in this vault.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                ])
            ),
            ToolDefinition(
                name: "get_stats",
                description: "Vault statistics: total notes (archived included), separate archived count, per-type histogram (includes archived).",
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
        let memoryDefinitions = memoryToolDefinitions
        return readOnly
            ? definitions.filter { Self.readOnlyTools.contains($0.name) } + memoryDefinitions
            : definitions + memoryDefinitions
    }

    /// Agent-memory tools. The three read tools are always available;
    /// `memory_propose` only when the server runs with --allow-write.
    /// Promotion, rejection, retirement, and staleness are operator actions
    /// and are never exposed over MCP.
    private var memoryToolDefinitions: [ToolDefinition] {
        var definitions = [
            ToolDefinition(
                name: "memory_context",
                description: "Budgeted session pack of active agent memories (scope global plus an optional project). Default budget 6000, hard max 8000.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "scope": .object(["type": .string("string")]),
                        "project": .object(["type": .string("string")]),
                        "budget": .object(["type": .string("integer")]),
                        "harness": .object(["type": .string("string")]),
                    ]),
                ])
            ),
            ToolDefinition(
                name: "memory_recall",
                description: "On-demand ranked recall over active agent memories (proposals with include_proposed=true, labelled). Default budget 4000 bytes.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object(["type": .string("string")]),
                        "budget": .object(["type": .string("integer")]),
                        "include_proposed": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("query")]),
                ])
            ),
            ToolDefinition(
                name: "memory_review",
                description: "List proposed agent memories by support, with the promote-ready flag.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                ])
            ),
        ]
        if !readOnly {
            definitions.append(ToolDefinition(
                name: "memory_propose",
                description: "Propose an agent-memory change: op=add|upvote|edit|retire. Args: op (required), record (JSON object as a string), key, evidence (semicolon-separated locators), reason, source_harness, if_hash.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "op": .object(["type": .string("string")]),
                        "key": .object(["type": .string("string")]),
                        "record": .object(["type": .string("string")]),
                        "evidence": .object(["type": .string("string")]),
                        "reason": .object(["type": .string("string")]),
                        "source_harness": .object(["type": .string("string")]),
                        "if_hash": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("op")]),
                ])
            ))
        }
        return definitions
    }

    private struct ToolError: Error {
        let message: String
    }
}
