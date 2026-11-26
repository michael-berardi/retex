import XCTest
@testable import RetexCore

final class MCPServerTests: XCTestCase {
    private var vaultDir: URL!
    private var store: MarkdownStore!

    override func setUpWithError() throws {
        vaultDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-mcp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: vaultDir, withIntermediateDirectories: true)
        store = MarkdownStore()
        _ = try store.createNote(
            in: Vault(url: vaultDir),
            folder: "Deals",
            title: "Acme redesign",
            metadata: ["type": "deal", "status": "Inbox", "owner": "Sam"],
            body: "# Acme redesign\n\nScope the rebuild."
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: vaultDir)
    }

    private func call(
        _ requests: [String],
        readOnly: Bool = false,
        interRequestDelay: TimeInterval = 0
    ) throws -> [[String: Any]] {
        let lines = try MCPTestHarness.run(
            vault: Vault(url: vaultDir),
            requests: requests,
            readOnly: readOnly,
            interRequestDelay: interRequestDelay
        )
        return try lines.map { line in
            guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                throw NSError(domain: "mcp", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not a JSON object: \(line)"])
            }
            return object
        }
    }

    /// tools/call results arrive inside a content[] envelope.
    private func resultText(_ response: [String: Any]) throws -> String {
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        if let content = result["content"] as? [[String: Any]] {
            return try XCTUnwrap(content.first?["text"] as? String)
        }
        // Other methods return their payload directly.
        return try XCTUnwrap(String(
            data: JSONSerialization.data(withJSONObject: result),
            encoding: .utf8
        ))
    }

    /// Tool results are compact JSON inside the content envelope.
    private func toolPayload(_ text: String) throws -> [String: Any] {
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    /// Sends raw bytes so a line that is not valid UTF-8 can be exercised; the
    /// shared harness only accepts strings.
    private func callRaw(_ lines: [Data], readOnly: Bool = false) throws -> [[String: Any]] {
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let collected = LockedBox(Data())

        let feeder = Thread {
            for line in lines {
                inputPipe.fileHandleForWriting.write(line + Data([UInt8(ascii: "\n")]))
            }
            inputPipe.fileHandleForWriting.closeFile()
        }
        let reader = Thread {
            while true {
                let chunk = outputPipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                collected.with { $0.append(chunk) }
            }
        }

        let server = MCPServer(
            vault: Vault(url: vaultDir),
            readOnly: readOnly,
            input: inputPipe.fileHandleForReading,
            output: outputPipe.fileHandleForWriting
        )
        feeder.start()
        reader.start()
        try server.run()

        while !feeder.isFinished { Thread.sleep(forTimeInterval: 0.01) }
        outputPipe.fileHandleForWriting.closeFile()
        while !reader.isFinished { Thread.sleep(forTimeInterval: 0.01) }

        return try collected.with { String(decoding: $0, as: UTF8.self) }
            .split(separator: "\n")
            .map { line in
                let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
                return try XCTUnwrap(object as? [String: Any], "not a JSON object: \(line)")
            }
    }

    /// A single `null`, array, or nested object in `arguments` must not discard
    /// the valid arguments beside it.
    func testNullAndNestedArgumentsKeepTheirSiblings() throws {
        let path = vaultDir.appendingPathComponent("Deals/acme-redesign.md").path
        let responses = try call([
            #"{"jsonrpc":"2.0","id":60,"method":"tools/call","params":{"name":"search_notes","arguments":{"query":"rebuild","ranked":null,"limit":null,"filter":{"owner":"Sam"},"tags":["deal"]}}}"#,
            #"{"jsonrpc":"2.0","id":61,"method":"tools/call","params":{"name":"list_notes","arguments":{"type":"deal","archived":null,"limit":null}}}"#,
            #"{"jsonrpc":"2.0","id":62,"method":"tools/call","params":{"name":"read_note","arguments":{"path":"\#(path)","expected_hash":null}}}"#,
        ], readOnly: true)

        let searched = try toolPayload(try resultText(responses[0]))
        XCTAssertEqual(searched["count"] as? String, "1", "the non-null query must survive its null siblings")

        let listed = try toolPayload(try resultText(responses[1]))
        XCTAssertEqual(listed["count"] as? String, "1", "the non-null type filter must survive")

        let read = try toolPayload(try resultText(responses[2]))
        XCTAssertEqual(read["title"] as? String, "Acme redesign")
    }

    func testInvalidUTF8RequestReturnsParseError() throws {
        // An opening brace, a broken UTF-8 sequence, then a closing brace.
        let invalid = Data([0x7B, 0xC3, 0x28, 0x7D])
        let responses = try callRaw([
            invalid,
            Data(#"{"jsonrpc":"2.0","id":63,"method":"ping"}"#.utf8),
        ])
        XCTAssertEqual(responses.count, 2, "an invalid UTF-8 line must be answered, not silently dropped")
        let error = try XCTUnwrap(responses[0]["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32700)
        XCTAssertTrue(responses[0]["id"] is NSNull, "parse errors carry a null id")
        XCTAssertEqual(responses[1]["id"] as? Int, 63)
    }

    /// The `tools/call` surface already hides write tools in read-only mode;
    /// dispatch refuses them too, so no other path can mutate the vault.
    func testReadOnlyDispatchRefusesWriteToolsDirectly() throws {
        let path = vaultDir.appendingPathComponent("Deals/acme-redesign.md").path
        let server = MCPServer(
            vault: Vault(url: vaultDir),
            readOnly: true,
            input: .nullDevice,
            output: .nullDevice
        )
        let writeArgs: [String: MCPServer.FlexibleValue] = [
            "path": .string(path),
            "key": .string("status"),
            "value": .string("Won"),
        ]
        XCTAssertThrowsError(
            try server.dispatchTool("set_property", args: writeArgs, arg: { writeArgs[$0]?.stringValue })
        ) { error in
            XCTAssertTrue("\(error)".contains("--allow-write"), "unexpected error \(error)")
        }
        XCTAssertEqual(try store.load(URL(fileURLWithPath: path)).status, "Inbox")

        // Reads still dispatch through the same entry point.
        let readArgs: [String: MCPServer.FlexibleValue] = ["path": .string(path)]
        XCTAssertNoThrow(try server.dispatchTool("read_note", args: readArgs, arg: { readArgs[$0]?.stringValue }))
    }

    /// JSON booleans and numbers must keep their types when the tool schemas
    /// are re-encoded; stringifying them corrupts every `tools/list` payload.
    func testToolSchemaEncodingKeepsScalarTypes() throws {
        func wire(_ value: Any) throws -> String {
            String(decoding: try JSONEncoder().encode(MCPServer.anyJSON(value)), as: UTF8.self)
        }
        XCTAssertEqual(try wire(NSNumber(value: 3)), "3")
        XCTAssertEqual(try wire(NSNumber(value: 2.5)), "2.5")
        XCTAssertEqual(try wire([NSNumber(value: 1)]), "[1]")
        #if canImport(Darwin)
        XCTAssertEqual(try wire(true), "true")
        XCTAssertEqual(try wire(false), "false")
        #endif
    }

    func testGetBoardMatchesStatusesCaseInsensitively() throws {
        let retexDir = vaultDir.appendingPathComponent(".retex", isDirectory: true)
        try FileManager.default.createDirectory(at: retexDir, withIntermediateDirectories: true)
        try """
        {"columns":[{"title":"Backlog","statuses":["inbox"]}]}
        """.write(to: retexDir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

        let responses = try call([
            #"{"jsonrpc":"2.0","id":64,"method":"tools/call","params":{"name":"get_board","arguments":{}}}"#,
        ], readOnly: true)
        let board = try toolPayload(try resultText(responses[0]))
        XCTAssertTrue((board["board"] as? String)?.contains("Acme redesign") ?? false, "status matching ignores case")
    }

    func testInitializeHandshake() throws {
        let responses = try call([
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#,
        ])
        XCTAssertEqual(responses.count, 1)
        let result = try XCTUnwrap(responses[0]["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2024-11-05")
        let serverInfo = try XCTUnwrap(result["serverInfo"] as? [String: Any])
        XCTAssertEqual(serverInfo["name"] as? String, "retex")
        XCTAssertNil(result["instructions"])
    }

    func testServerWaitsForTheNextInteractiveRequest() throws {
        let responses = try call([
            #"{"jsonrpc":"2.0","id":20,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}"#,
            #"{"jsonrpc":"2.0","id":21,"method":"tools/list","params":{}}"#,
        ], interRequestDelay: 0.1)
        XCTAssertEqual(responses.count, 2)
        XCTAssertEqual(responses[0]["id"] as? Int, 20)
        XCTAssertEqual(responses[1]["id"] as? Int, 21)
    }

    func testNotificationProducesNoResponse() throws {
        let responses = try call([
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#,
        ])
        XCTAssertEqual(responses.count, 1, "Notification must not get a JSON-RPC response")
        XCTAssertEqual(responses[0]["id"] as? Int, 2)
    }

    func testToolsListExposesExpectedTools() throws {
        let responses = try call([#"{"jsonrpc":"2.0","id":3,"method":"tools/list","params":{}}"#])
        let payload = try XCTUnwrap(responses[0]["result"] as? [String: Any])
        let tools = try XCTUnwrap(payload["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { $0["name"] as? String })
        XCTAssertEqual(names, [
            "list_notes", "search_notes", "read_note", "query_records",
            "recall_context", "get_links", "get_schema", "create_note",
            "set_property", "move_card", "archive_note", "get_board", "get_stats",
            "memory_context", "memory_recall", "memory_review", "memory_propose",
        ])
    }

    func testReadOnlyModeExposesOnlyReadToolsAndRejectsWrites() throws {
        let path = vaultDir.appendingPathComponent("Deals/acme-redesign.md").path
        let responses = try call([
            #"{"jsonrpc":"2.0","id":30,"method":"tools/list","params":{}}"#,
            #"{"jsonrpc":"2.0","id":31,"method":"tools/call","params":{"name":"set_property","arguments":{"path":"\#(path)","key":"status","value":"Proposal"}}}"#,
        ], readOnly: true)

        let payload = try XCTUnwrap(responses[0]["result"] as? [String: Any])
        let tools = try XCTUnwrap(payload["tools"] as? [[String: Any]])
        XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }), [
            "list_notes", "search_notes", "read_note", "query_records",
            "recall_context", "get_links", "get_schema", "get_board", "get_stats",
            "memory_context", "memory_recall", "memory_review",
        ])
        let error = try XCTUnwrap(responses[1]["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
        XCTAssertEqual(try store.load(URL(fileURLWithPath: path)).status, "Inbox")
    }

    func testReadNoteRefusesPathsOutsideVault() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-protected-\(UUID().uuidString).md")
        try "# Protected\n\nDO NOT EXFILTRATE".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }

        let responses = try call([
            #"{"jsonrpc":"2.0","id":32,"method":"tools/call","params":{"name":"read_note","arguments":{"path":"\#(outside.path)"}}}"#,
        ], readOnly: true)
        let result = try XCTUnwrap(responses[0]["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let text = try resultText(responses[0])
        XCTAssertTrue(text.contains("within the vault"))
        XCTAssertFalse(text.contains("DO NOT EXFILTRATE"))
    }

    func testReadNoteRefusesSymlinkEscapes() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-protected-\(UUID().uuidString).md")
        let link = vaultDir.appendingPathComponent("protected.md")
        try "# Protected\n\nDO NOT EXFILTRATE".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        let responses = try call([
            #"{"jsonrpc":"2.0","id":33,"method":"tools/call","params":{"name":"read_note","arguments":{"path":"\#(link.path)"}}}"#,
        ], readOnly: true)
        let text = try resultText(responses[0])
        XCTAssertTrue(text.contains("within the vault"))
        XCTAssertFalse(text.contains("DO NOT EXFILTRATE"))
    }

    func testSearchDoesNotIndexSymlinksOutsideVault() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-protected-\(UUID().uuidString).md")
        let link = vaultDir.appendingPathComponent("protected.md")
        try "# Protected\n\nDO NOT EXFILTRATE".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        let responses = try call([
            #"{"jsonrpc":"2.0","id":35,"method":"tools/call","params":{"name":"search_notes","arguments":{"query":"DO NOT EXFILTRATE"}}}"#,
        ], readOnly: true)
        let payload = try toolPayload(try resultText(responses[0]))
        XCTAssertEqual(payload["count"] as? String, "0")
        XCTAssertFalse(try resultText(responses[0]).contains("DO NOT EXFILTRATE"))
    }

    func testCreateNoteRefusesFolderTraversal() throws {
        let folderName = "retex-escaped-\(UUID().uuidString)"
        let outside = vaultDir.deletingLastPathComponent().appendingPathComponent(folderName)
        defer { try? FileManager.default.removeItem(at: outside) }

        let responses = try call([
            #"{"jsonrpc":"2.0","id":34,"method":"tools/call","params":{"name":"create_note","arguments":{"title":"Escaped","folder":"../\#(folderName)"}}}"#,
        ])
        let text = try resultText(responses[0])
        XCTAssertTrue(text.contains("within the vault"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
    }

    func testListAndSearchNotesTools() throws {
        let responses = try call([
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"list_notes","arguments":{"type":"deal"}}}"#,
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"search_notes","arguments":{"query":"rebuild"}}}"#,
        ])
        let list = try toolPayload(try resultText(responses[0]))
        XCTAssertEqual(list["count"] as? String, "1")
        XCTAssertTrue((list["notes"] as? String)?.contains("Acme redesign") ?? false)

        let search = try toolPayload(try resultText(responses[1]))
        XCTAssertEqual(search["count"] as? String, "1")
    }

    func testStructuredQueryRecallAndSchemaTools() throws {
        _ = try store.createNote(
            in: Vault(url: vaultDir),
            folder: "Records",
            title: "August invoice",
            metadata: ["type": "invoice", "owner": "Sam", "amount": "11500"],
            body: "Payment is due this month."
        )
        let responses = try call([
            #"{"jsonrpc":"2.0","id":40,"method":"tools/call","params":{"name":"query_records","arguments":{"type":"invoice","where":"owner=Sam;amount=11500"}}}"#,
            #"{"jsonrpc":"2.0","id":41,"method":"tools/call","params":{"name":"recall_context","arguments":{"query":"what is the august invoice payment","budget":1000}}}"#,
            #"{"jsonrpc":"2.0","id":42,"method":"tools/call","params":{"name":"get_schema","arguments":{}}}"#,
        ], readOnly: true)

        let queried = try toolPayload(try resultText(responses[0]))
        XCTAssertEqual(queried["count"] as? String, "1")
        XCTAssertEqual((queried["records"] as? [[String: Any]])?.first?["type"] as? String, "invoice")

        let recalled = try toolPayload(try resultText(responses[1]))
        XCTAssertEqual((recalled["records"] as? [[String: Any]])?.first?["title"] as? String, "August invoice")
        XCTAssertLessThanOrEqual(Int(recalled["usedBytes"] as? String ?? "") ?? .max, 1000)

        let schema = try toolPayload(try resultText(responses[2]))
        XCTAssertTrue((schema["recordTypes"] as? [String] ?? []).contains("invoice"))
        XCTAssertTrue((schema["properties"] as? [String] ?? []).contains("amount"))
    }

    func testMCPContentHashGuardsWritesAndDateFiltersQueries() throws {
        let path = vaultDir.appendingPathComponent("Deals/acme-redesign.md").path
        _ = try store.updateMetadata(
            "review_after",
            value: "2026-08-28",
            for: store.load(URL(fileURLWithPath: path))
        )
        let currentHash = try store.load(URL(fileURLWithPath: path)).contentHash

        let responses = try call([
            #"{"jsonrpc":"2.0","id":43,"method":"tools/call","params":{"name":"read_note","arguments":{"path":"\#(path)"}}}"#,
            #"{"jsonrpc":"2.0","id":44,"method":"tools/call","params":{"name":"set_property","arguments":{"path":"\#(path)","key":"status","value":"Proposal","expected_hash":"\#(currentHash)"}}}"#,
            #"{"jsonrpc":"2.0","id":45,"method":"tools/call","params":{"name":"set_property","arguments":{"path":"\#(path)","key":"status","value":"Won","expected_hash":"\#(currentHash)"}}}"#,
            #"{"jsonrpc":"2.0","id":46,"method":"tools/call","params":{"name":"query_records","arguments":{"on_or_before":"review_after=2026-08-28"}}}"#,
        ])

        let read = try toolPayload(try resultText(responses[0]))
        XCTAssertEqual(read["contentHash"] as? String, currentHash)
        XCTAssertEqual((responses[1]["result"] as? [String: Any])?["isError"] as? Bool, false)
        XCTAssertEqual((responses[2]["result"] as? [String: Any])?["isError"] as? Bool, true)
        XCTAssertTrue(try resultText(responses[2]).contains("stale write"))
        XCTAssertEqual(try store.load(URL(fileURLWithPath: path)).status, "Proposal")

        let queried = try toolPayload(try resultText(responses[3]))
        XCTAssertEqual(queried["count"] as? String, "1")
    }

    func testSearchSupportsRankedAllTermQueriesAndLimits() throws {
        _ = try store.createNote(
            in: Vault(url: vaultDir),
            folder: "Notes",
            title: "Retex release process",
            metadata: [:],
            body: "Safe upgrade instructions."
        )
        _ = try store.createNote(
            in: Vault(url: vaultDir),
            folder: "Notes",
            title: "General operations",
            metadata: [:],
            body: "The release process for Retex is documented here."
        )

        let responses = try call([
            #"{"jsonrpc":"2.0","id":36,"method":"tools/call","params":{"name":"search_notes","arguments":{"query":"Retex release","ranked":true,"limit":1}}}"#,
        ], readOnly: true)
        let search = try toolPayload(try resultText(responses[0]))
        XCTAssertEqual(search["count"] as? String, "1")
        XCTAssertTrue((search["notes"] as? String)?.contains("Retex release process") ?? false)
        XCTAssertFalse((search["notes"] as? String)?.contains("General operations") ?? true)
    }

    func testSearchRejectsInvalidLimits() throws {
        let responses = try call([
            #"{"jsonrpc":"2.0","id":37,"method":"tools/call","params":{"name":"search_notes","arguments":{"query":"rebuild","limit":0}}}"#,
        ], readOnly: true)
        let result = try XCTUnwrap(responses[0]["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
    }

    func testReadNoteTool() throws {
        let path = vaultDir.appendingPathComponent("Deals/acme-redesign.md").path
        let responses = try call([
            #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"read_note","arguments":{"path":"\#(path)"}}}"#,
        ])
        let note = try toolPayload(try resultText(responses[0]))
        XCTAssertEqual(note["title"] as? String, "Acme redesign")
        XCTAssertEqual(note["type"] as? String, "deal")
        XCTAssertTrue((note["body"] as? String)?.contains("Scope the rebuild") ?? false)
    }

    func testSetPropertyToolMutatesVault() throws {
        let path = vaultDir.appendingPathComponent("Deals/acme-redesign.md").path
        _ = try call([
            #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"set_property","arguments":{"path":"\#(path)","key":"status","value":"Proposal"}}}"#,
        ])
        let updated = try store.load(URL(fileURLWithPath: path))
        XCTAssertEqual(updated.status, "Proposal", "MCP set_property must write through to the Markdown file")
    }

    func testGetBoardUsesConfiguredColumns() throws {
        let retexDir = vaultDir.appendingPathComponent(".retex", isDirectory: true)
        try FileManager.default.createDirectory(at: retexDir, withIntermediateDirectories: true)
        try """
        {"columns":[{"title":"Backlog","statuses":["Inbox"]}]}
        """.write(to: retexDir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

        let responses = try call([
            #"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"get_board","arguments":{}}}"#,
        ])
        let board = try toolPayload(try resultText(responses[0]))
        let text = try XCTUnwrap(board["board"] as? String)
        XCTAssertTrue(text.contains("Backlog"))
        XCTAssertTrue(text.contains("Acme redesign"))
    }

    func testUnknownToolReturnsInvalidParamsError() throws {
        let responses = try call([
            #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"does_not_exist","arguments":{}}}"#,
        ])
        let error = try XCTUnwrap(responses[0]["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
    }

    func testToolExecutionFailureReturnsIsErrorResult() throws {
        let responses = try call([
            #"{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"read_note","arguments":{"path":"/nonexistent/note.md"}}}"#,
        ])
        let result = try XCTUnwrap(responses[0]["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true, "Runtime tool failures must be isError results")
    }

    func testMalformedLineReturnsParseError() throws {
        let responses = try call(["not json at all"])
        let error = try XCTUnwrap(responses[0]["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32700)
        XCTAssertTrue(responses[0]["id"] is NSNull, "Parse errors carry a null id")
    }

    func testOversizedRequestIsRejectedBeforeDecoding() throws {
        let responses = try call([String(repeating: "x", count: 1_048_577)])
        let error = try XCTUnwrap(responses[0]["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32700)
        XCTAssertTrue((error["message"] as? String)?.contains("1048576") ?? false)
    }

    func testUnknownMethodReturnsMethodNotFound() throws {
        let responses = try call([
            #"{"jsonrpc":"2.0","id":10,"method":"resources/list","params":{}}"#,
        ])
        let error = try XCTUnwrap(responses[0]["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32601)
    }
    func testOversizedRequestYieldsOneErrorAndLaterRequestsStillWork() throws {
        let oversized = #"{"jsonrpc":"2.0","id":1,"method":"ping","params":{"pad":""# + String(repeating: "x", count: 3_000_000) + #""}}"#
        let responses = try call([
            oversized,
            #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#,
        ])
        XCTAssertEqual(responses.count, 2)
        XCTAssertNotNil(responses[0]["error"])
        XCTAssertEqual(responses[1]["id"] as? Int, 2)
        XCTAssertNotNil(responses[1]["result"])
    }

    func testGetLinksSurvivesEmptyWikiLinks() throws {
        try "# Broken\n\nempty [[]] and [[|x]] then [[Acme redesign]]\n"
            .write(to: vaultDir.appendingPathComponent("broken.md"), atomically: true, encoding: .utf8)
        let responses = try call([
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_links","arguments":{"path":"broken.md"}}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"ping"}"#,
        ], readOnly: true)
        XCTAssertEqual(responses.count, 2)
        let payload = try toolPayload(try resultText(responses[0]))
        let outgoing = try XCTUnwrap(payload["outgoing"] as? [[String: Any]])
        XCTAssertEqual(outgoing.map { $0["title"] as? String }, ["Acme redesign"])
    }

    func testListKeepsSymlinksInsideTheVaultAndDropsEscapes() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-outside-\(UUID().uuidString).md")
        try "# Outside".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(
            at: vaultDir.appendingPathComponent("escape.md"),
            withDestinationURL: outside
        )
        try FileManager.default.createSymbolicLink(
            at: vaultDir.appendingPathComponent("alias.md"),
            withDestinationURL: vaultDir.appendingPathComponent("Deals/acme-redesign.md")
        )
        let responses = try call([
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"list_notes","arguments":{}}}"#,
        ], readOnly: true)
        let notes = try XCTUnwrap(try toolPayload(try resultText(responses[0]))["notes"] as? String)
        XCTAssertTrue(notes.contains("alias.md"))
        XCTAssertTrue(notes.contains("acme-redesign.md"))
        XCTAssertFalse(notes.contains("escape.md"))
        XCTAssertFalse(notes.contains("Outside"))
    }

    func testCachedSearchAndRecallWorkThroughSymlinkedVaultRoot() throws {
        // Vaults accessed through a symlinked root (such as /tmp -> /private/tmp
        // on macOS) have `confinedByPath == false` in the snapshot cache and
        // must fall back to full confinement resolution rather than dropping all hits.
        let linkDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-symlink-root-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: linkDir, withDestinationURL: vaultDir)
        defer { try? FileManager.default.removeItem(at: linkDir) }

        let cache = VaultSnapshotCache()
        let server = MCPServer(vault: Vault(url: linkDir), store: MarkdownStore(cache: cache), readOnly: true)
        let searchPayload = try server.dispatchTool(
            "search_notes",
            args: ["query": .string("Acme")],
            arg: { $0 == "query" ? "Acme" : nil }
        )
        let encodedSearch = try AgentOutput.compactJSON(searchPayload)
        XCTAssertTrue(encodedSearch.contains("Acme redesign"), encodedSearch)

        let recallPayload = try server.dispatchTool(
            "recall_context",
            args: ["query": .string("Acme"), "budget": .string("4000")],
            arg: { key in
                if key == "query" { return "Acme" }
                if key == "budget" { return "4000" }
                return nil
            }
        )
        let encodedRecall = try AgentOutput.compactJSON(recallPayload)
        XCTAssertTrue(encodedRecall.contains("Acme redesign"), encodedRecall)
    }
}
