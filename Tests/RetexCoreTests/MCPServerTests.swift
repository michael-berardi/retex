import XCTest
import RetexCore

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

    private func toolPayload(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
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
            "list_notes", "search_notes", "read_note", "create_note",
            "set_property", "move_card", "archive_note", "get_board",
            "get_stats",
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
            "list_notes", "search_notes", "read_note", "get_board", "get_stats",
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

    func testUnknownMethodReturnsMethodNotFound() throws {
        let responses = try call([
            #"{"jsonrpc":"2.0","id":10,"method":"resources/list","params":{}}"#,
        ])
        let error = try XCTUnwrap(responses[0]["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32601)
    }
}
