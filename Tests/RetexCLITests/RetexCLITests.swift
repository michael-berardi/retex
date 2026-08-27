import XCTest

/// End-to-end tests that run the built `retex` binary against temp vaults.
final class RetexCLITests: XCTestCase {
    private static var repoRoot: URL {
        let file = URL(fileURLWithPath: #filePath)
        return file.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static let binPath: URL = {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swift", "build", "--show-bin-path"]
        process.currentDirectoryURL = repoRoot
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            fatalError("Could not resolve retex binary path: \(error)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0, "swift build --show-bin-path failed")
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: path)
    }()

    private var vaultDir: URL!

    override func setUpWithError() throws {
        vaultDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: vaultDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: vaultDir)
    }

    @discardableResult
    private func run(
        _ arguments: [String],
        stdin: String? = nil
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        let stdout = Pipe(), stderr = Pipe(), input = Pipe()
        process.executableURL = Self.binPath.appendingPathComponent("retex")
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        if stdin != nil { process.standardInput = input }
        try process.run()
        if let stdin {
            input.fileHandleForWriting.write(Data(stdin.utf8))
            input.fileHandleForWriting.closeFile()
        }
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: outData, as: UTF8.self),
            String(decoding: errData, as: UTF8.self)
        )
    }

    private var vaultArg: [String] { ["--vault", vaultDir.path] }

    private func jsonEnvelope(_ output: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    }

    // MARK: - Envelope contract

    func testSuccessEnvelopeCarriesSchemaVersionAndOkTrue() throws {
        _ = try run(["create"] + vaultArg + ["--title", "Envelope", "--type", "note"])
        let (status, stdout, _) = try run(["list"] + vaultArg + ["--json"])
        XCTAssertEqual(status, 0)

        let envelope = try jsonEnvelope(stdout)
        XCTAssertEqual(envelope["ok"] as? Bool, true)
        XCTAssertEqual(envelope["schema_version"] as? Int, 1)
        XCTAssertNotNil(envelope["data"])
    }

    func testUsageErrorExits64WithMachineReadableFailure() throws {
        let (status, _, stderr) = try run(["list", "--json"])
        XCTAssertEqual(status, 64)
        let envelope = try jsonEnvelope(stderr)
        XCTAssertEqual(envelope["ok"] as? Bool, false)
        let error = try XCTUnwrap(envelope["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, 64)
    }

    func testStorageErrorExits74() throws {
        let missing = vaultDir.appendingPathComponent("nope.md").path
        let (status, _, _) = try run(["show", missing] + vaultArg)
        XCTAssertEqual(status, 74)
    }

    // MARK: - Record lifecycle

    func testCreateShowMoveArchiveLifecycle() throws {
        let (_, createOut, _) = try run([
            "create"] + vaultArg + [
                "--type", "deal",
                "--title", "Lifecycle Deal",
                "--status", "Inbox",
                "--set", "owner=Sam",
            ] + ["--json"])
        XCTAssertEqual(try jsonEnvelope(createOut)["ok"] as? Bool, true)
        let created = try XCTUnwrap(try jsonEnvelope(createOut)["data"] as? [String: Any])
        let path = try XCTUnwrap(created["path"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        let (_, showOut, _) = try run(["show", path, "--json"])
        let shown = try XCTUnwrap(try jsonEnvelope(showOut)["data"] as? [String: Any])
        XCTAssertEqual(shown["title"] as? String, "Lifecycle Deal")

        let (_, moveOut, _) = try run(["move", path, "Proposal", "--rank", "4", "--json"])
        XCTAssertEqual(try jsonEnvelope(moveOut)["ok"] as? Bool, true)
        let moved = try XCTUnwrap(try jsonEnvelope(moveOut)["data"] as? [String: Any])
        XCTAssertEqual(moved["status"] as? String, "Proposal")

        try run(["archive", path, "--json"])
        // Archived records are hidden by default...
        let (_, listOut, _) = try run(["list"] + vaultArg + ["--json"])
        let list = try XCTUnwrap(try jsonEnvelope(listOut)["data"] as? [[String: Any]])
        XCTAssertTrue(list.isEmpty)
        // ...and visible with --all.
        let (_, allOut, _) = try run(["list"] + vaultArg + ["--all", "--json"])
        let all = try XCTUnwrap(try jsonEnvelope(allOut)["data"] as? [[String: Any]])
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?["archived"] as? Bool, true)
    }

    func testSearchFindsBodyText() throws {
        try run(["create"] + vaultArg + ["--title", "Needle Note", "--body", "The zanzibar keyword lives here"])
        let (_, out, _) = try run(["search", "zanzibar"] + vaultArg + ["--json"])
        XCTAssertEqual(try jsonEnvelope(out)["ok"] as? Bool, true)
        let results = try XCTUnwrap(try jsonEnvelope(out)["data"] as? [[String: Any]])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?["title"] as? String, "Needle Note")
    }

    func testRankedSearchMatchesAllTermsAndHonorsLimit() throws {
        try run([
            "create"] + vaultArg + [
                "--title", "Retex release process",
                "--body", "Safe upgrade instructions",
            ])
        try run([
            "create"] + vaultArg + [
                "--title", "General operations",
                "--body", "The release process for Retex is documented here",
            ])

        let (status, out, _) = try run([
            "search", "Retex release"] + vaultArg + [
                "--ranked", "--limit", "1", "--json",
            ])
        XCTAssertEqual(status, 0)
        let results = try XCTUnwrap(try jsonEnvelope(out)["data"] as? [[String: Any]])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?["title"] as? String, "Retex release process")
    }

    func testArbitraryRecordTypesAndPropertyFiltersStayStructured() throws {
        let (_, createOut, _) = try run([
            "create"] + vaultArg + [
                "--type", "invoice",
                "--title", "Acme August",
                "--set", "owner=Sam",
                "--set", "amount=11500",
                "--set", "tags=[billing, priority]",
                "--json",
            ])
        let created = try XCTUnwrap(try jsonEnvelope(createOut)["data"] as? [String: Any])
        XCTAssertEqual(created["type"] as? String, "note")
        XCTAssertEqual(created["recordType"] as? String, "invoice")
        XCTAssertEqual((created["path"] as? String).map(URL.init(fileURLWithPath:))?.deletingLastPathComponent().lastPathComponent, "Notes")

        let (_, queryOut, _) = try run([
            "query"] + vaultArg + [
                "--type", "invoice",
                "--tag", "priority",
                "--where", "owner=Sam",
                "--where", "amount=11500",
                "--json",
            ])
        let records = try XCTUnwrap(try jsonEnvelope(queryOut)["data"] as? [[String: Any]])
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0]["type"] as? String, "invoice")
        let (_, listOut, _) = try run(["list"] + vaultArg + ["--type", "invoice", "--json"])
        let legacy = try XCTUnwrap(try jsonEnvelope(listOut)["data"] as? [[String: Any]])
        XCTAssertEqual(legacy.first?["type"] as? String, "note")
    }

    func testRecallReturnsBestEvidenceWithinBudget() throws {
        try run([
            "create"] + vaultArg + [
                "--type", "standard",
                "--title", "Retex Vault Upgrade Standard",
                "--body", "Validate upgrades on disposable vault clones.",
            ])
        try run([
            "create"] + vaultArg + [
                "--title", "General Retex notes",
                "--body", "General release information.",
            ])

        let (_, out, _) = try run([
            "recall", "what is the Retex vault upgrade standard"] + vaultArg + [
                "--limit", "5", "--budget", "1000", "--json",
            ])
        let recalled = try XCTUnwrap(try jsonEnvelope(out)["data"] as? [String: Any])
        let records = try XCTUnwrap(recalled["records"] as? [[String: Any]])
        XCTAssertEqual(records.first?["title"] as? String, "Retex Vault Upgrade Standard")
        XCTAssertLessThanOrEqual(recalled["usedBytes"] as? Int ?? .max, 1000)
        XCTAssertTrue((records.first?["excerpt"] as? String)?.contains("disposable vault clones") == true)
    }

    func testLinksReturnsOutgoingBacklinksAndUnresolvedTargets() throws {
        let (_, alphaOut, _) = try run([
            "create"] + vaultArg + [
                "--title", "Alpha",
                "--body", "See [[Beta]] and [[Missing]].",
                "--json",
            ])
        let alpha = try XCTUnwrap((try jsonEnvelope(alphaOut)["data"] as? [String: Any])?["path"] as? String)
        try run([
            "create"] + vaultArg + [
                "--title", "Beta",
                "--body", "Back to [[Alpha#Decision]].",
            ])

        let (_, out, _) = try run(["links", alpha] + vaultArg + ["--json"])
        let graph = try XCTUnwrap(try jsonEnvelope(out)["data"] as? [String: Any])
        XCTAssertEqual((graph["outgoing"] as? [[String: Any]])?.first?["title"] as? String, "Beta")
        XCTAssertEqual((graph["backlinks"] as? [[String: Any]])?.first?["title"] as? String, "Beta")
        XCTAssertEqual(graph["unresolved"] as? [String], ["Missing"])
    }

    func testBoardGroupsDealsByColumn() throws {
        try run(["create"] + vaultArg + ["--type", "deal", "--title", "Board Card", "--status", "Qualified"])
        let (_, out, _) = try run(["board"] + vaultArg + ["--json"])
        let board = try XCTUnwrap(try jsonEnvelope(out)["data"] as? [String: Any])
        let columns = try XCTUnwrap(board["columns"] as? [[String: Any]])
        let qualified = columns.first { ($0["name"] as? String) == "Qualified" }
        let cards = try XCTUnwrap(qualified?["cards"] as? [[String: Any]])
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards.first?["title"] as? String, "Board Card")
    }

    // MARK: - Undo / log / views / doctor / schema

    func testUndoRestoresPreviousState() throws {
        let (_, createOut, _) = try run([
            "create"] + vaultArg + ["--type", "task", "--title", "Undo Me", "--json"])
        let path = try XCTUnwrap((try jsonEnvelope(createOut)["data"] as? [String: Any])?["path"] as? String)

        try run(["set", path, "status=Doing", "--json"])

        let (_, undoOut, _) = try run(["undo", path, "--json"])
        XCTAssertEqual(try jsonEnvelope(undoOut)["ok"] as? Bool, true)
        let restored = try XCTUnwrap(try jsonEnvelope(undoOut)["data"] as? [String: Any])
        XCTAssertEqual(restored["status"] as? String, "Unsorted", "undo must restore pre-mutation status")

        // Journal entry was consumed.
        let (_, logOut, _) = try run(["log", path, "--json"])
        let entries = try XCTUnwrap(try jsonEnvelope(logOut)["data"] as? [String: Any])
        XCTAssertEqual((entries["entries"] as? [[String: Any]])?.count, 0)
    }

    func testUndoWithoutHistoryFailsWithUsageError() throws {
        let (_, createOut, _) = try run([
            "create"] + vaultArg + ["--title", "No History", "--json"])
        let path = try XCTUnwrap((try jsonEnvelope(createOut)["data"] as? [String: Any])?["path"] as? String)

        let (status, _, stderr) = try run(["undo", path, "--json"])
        XCTAssertEqual(status, 64)
        XCTAssertTrue(stderr.contains("No undo history"))
    }

    func testViewsListsSavedViewsAndBoardFiltersByView() throws {
        try run(["create"] + vaultArg + ["--type", "deal", "--title", "Viewed Deal", "--status", "Proposal"])
        let retexDir = vaultDir.appendingPathComponent(".retex", isDirectory: true)
        try FileManager.default.createDirectory(at: retexDir, withIntermediateDirectories: true)
        try """
        {"columns":[{"title":"Inbox","statuses":["Inbox"]},{"title":"Proposal","statuses":["Proposal"]}],
         "views":[{"name":"pipeline","type":"deal","status":"Proposal"}]}
        """.write(to: retexDir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

        let (_, viewsOut, _) = try run(["views"] + vaultArg + ["--json"])
        let views = try XCTUnwrap(try jsonEnvelope(viewsOut)["data"] as? [String: Any])
        let listed = try XCTUnwrap(views["views"] as? [[String: Any]])
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?["name"] as? String, "pipeline")

        let (_, boardOut, _) = try run(["board"] + vaultArg + ["--view", "pipeline", "--json"])
        let board = try XCTUnwrap(try jsonEnvelope(boardOut)["data"] as? [String: Any])
        let columns = try XCTUnwrap(board["columns"] as? [[String: Any]])
        XCTAssertEqual(columns.count, 2, "Custom columns replace defaults")
        XCTAssertTrue(columns.contains { ($0["name"] as? String) == "Proposal" })
        XCTAssertFalse(columns.contains { ($0["name"] as? String) == "Won" })

        let unknown = try run(["board"] + vaultArg + ["--view", "ghost", "--json"])
        XCTAssertEqual(unknown.status, 64)
    }

    func testInitCreatesPrivateVaultStateIdempotently() throws {
        for _ in 0..<2 {
            let (status, out, _) = try run(["init"] + vaultArg + ["--json"])
            XCTAssertEqual(status, 0)
            XCTAssertEqual(try jsonEnvelope(out)["ok"] as? Bool, true)
        }
        #if !os(Windows)
        let state = vaultDir.appendingPathComponent(".retex", isDirectory: true)
        let attributes = try FileManager.default.attributesOfItem(atPath: state.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        #endif
    }

    func testDoctorReportsHealthyVault() throws {
        try run(["create"] + vaultArg + ["--title", "Doctor Note"])
        let (_, out, _) = try run(["doctor"] + vaultArg + ["--json"])
        let report = try XCTUnwrap(try jsonEnvelope(out)["data"] as? [String: Any])
        XCTAssertEqual(report["notes"] as? Int, 1)
        XCTAssertEqual(report["configOk"] as? Bool, true)
        XCTAssertEqual(report["journalOk"] as? Bool, true)
        XCTAssertEqual((report["issues"] as? [String])?.count ?? -1, 0)
    }

    func testStrictDoctorValidatesConfiguredRequiredProperties() throws {
        let retexDir = vaultDir.appendingPathComponent(".retex", isDirectory: true)
        try FileManager.default.createDirectory(at: retexDir, withIntermediateDirectories: true)
        try #"{"recordTypes":[{"name":"invoice","required":["client","amount"]}]}"#
            .write(to: retexDir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        try run(["create"] + vaultArg + ["--type", "invoice", "--title", "Incomplete", "--set", "client=Acme"])

        let (status, out, _) = try run(["doctor"] + vaultArg + ["--strict", "--json"])
        XCTAssertEqual(status, 2)
        let report = try XCTUnwrap(try jsonEnvelope(out)["data"] as? [String: Any])
        XCTAssertTrue((report["issues"] as? [String] ?? []).contains { $0.contains("amount") })
    }

    func testStrictDoctorFailsWhenJournalIsCorrupt() throws {
        let state = vaultDir.appendingPathComponent(".retex", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try "{not-json}\n".write(
            to: state.appendingPathComponent("history.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let (status, out, _) = try run(["doctor"] + vaultArg + ["--strict", "--json"])
        XCTAssertNotEqual(status, 0)
        let report = try XCTUnwrap(try jsonEnvelope(out)["data"] as? [String: Any])
        XCTAssertEqual(report["journalOk"] as? Bool, false)
        XCTAssertFalse((report["issues"] as? [String] ?? []).isEmpty)
    }

    func testSchemaReflectsCustomStatusesWhenVaultGiven() throws {
        let retexDir = vaultDir.appendingPathComponent(".retex", isDirectory: true)
        try FileManager.default.createDirectory(at: retexDir, withIntermediateDirectories: true)
        try """
        {"columns":[{"title":"Sprint","statuses":["Todo"]}],
         "recordTypes":[{"name":"invoice","folder":"Invoices","required":["amount"],"properties":["client","amount"]}]}
        """.write(to: retexDir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        try run(["create"] + vaultArg + ["--type", "invoice", "--title", "August", "--set", "amount=100"])

        let (_, out, _) = try run(["schema"] + vaultArg + ["--json"])
        let schema = try XCTUnwrap(try jsonEnvelope(out)["data"] as? [String: Any])
        XCTAssertEqual(schema["statuses"] as? [String], ["Sprint"])
        XCTAssertTrue((schema["recordTypes"] as? [String] ?? []).contains("invoice"))
        XCTAssertTrue((schema["discoveredProperties"] as? [String] ?? []).contains("amount"))
        XCTAssertEqual((schema["recordSchemas"] as? [[String: Any]])?.first?["folder"] as? String, "Invoices")
        XCTAssertEqual(schema["views"] as? [String], [], "No saved views defined means an empty list")
    }

    func testMCPIsReadOnlyByDefaultWithExplicitWriteOptIn() throws {
        let request = #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"# + "\n"

        func toolNames(_ output: String) throws -> Set<String> {
            let response = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
            )
            let result = try XCTUnwrap(response["result"] as? [String: Any])
            let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
            return Set(tools.compactMap { $0["name"] as? String })
        }

        let safe = try run(["mcp"] + vaultArg, stdin: request)
        XCTAssertEqual(safe.status, 0)
        XCTAssertEqual(try toolNames(safe.stdout), [
            "list_notes", "search_notes", "read_note", "query_records",
            "recall_context", "get_links", "get_schema", "get_board", "get_stats",
        ])

        let writable = try run(["mcp"] + vaultArg + ["--allow-write"], stdin: request)
        XCTAssertEqual(writable.status, 0)
        XCTAssertTrue(try toolNames(writable.stdout).contains("create_note"))
    }
}
