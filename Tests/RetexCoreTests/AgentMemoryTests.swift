#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import XCTest
@testable import RetexCore

final class AgentMemoryTests: XCTestCase {
    private var vaultDir: URL!
    private var vault: Vault!
    private let memory = AgentMemory()

    override func setUpWithError() throws {
        vaultDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-memory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: vaultDir, withIntermediateDirectories: true)
        _ = try memory.initialize(at: vaultDir)
        vault = Vault(url: vaultDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: vaultDir)
    }

    // MARK: - Helpers

    private var globalDir: URL { vaultDir.appendingPathComponent("Memory/global", isDirectory: true) }

    private func recordJSON(
        key: String,
        kind: String = "correction",
        title: String = "Deploy LDS with npm run deploy",
        body: String = "Run npm run deploy from the repo root. Never deploy LDS through Vercel.",
        appliesWhen: String? = nil,
        evidence: [String] = ["pi:2026-09-25-s1#3"],
        confidence: String? = nil,
        certainty: String? = nil,
        scope: String? = nil,
        sourceHarness: String? = nil
    ) throws -> Data {
        var object: [String: Any] = [
            "key": key,
            "kind": kind,
            "title": title,
            "body": body,
        ]
        if let appliesWhen { object["applies_when"] = appliesWhen }
        if let confidence { object["confidence"] = confidence }
        if let certainty { object["certainty"] = certainty }
        if let scope { object["scope"] = scope }
        if let sourceHarness { object["source_harness"] = sourceHarness }
        if !evidence.isEmpty { object["evidence"] = evidence }
        return try JSONSerialization.data(withJSONObject: object)
    }

    @discardableResult
    private func propose(
        _ op: String = "add",
        key: String? = nil,
        json: Data? = nil,
        evidence: [String] = [],
        reason: String? = nil,
        sourceHarness: String? = nil,
        ifHash: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> AgentMemory.MutationResult {
        try memory.propose(
            vault: vault, op: op, key: key, recordJSON: json,
            evidence: evidence, reason: reason, sourceHarness: sourceHarness,
            ifHash: ifHash
        )
    }

    private func expectReason(
        _ code: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> Void
    ) {
        do {
            try body()
            XCTFail("Expected memory error \(code)", file: file, line: line)
        } catch let error as AgentMemory.MemoryError {
            XCTAssertEqual(error.reasonCode, code, "\(error.errorDescription ?? "")", file: file, line: line)
        } catch {
            XCTFail("Unexpected error \(error)", file: file, line: line)
        }
    }

    private func directRecord(
        key: String,
        status: String = "active",
        kind: String = "gotcha",
        support: Int = 1,
        recalled: Int = 0,
        cited: Int = 0,
        created: Date,
        updated: Date,
        lastUsed: Date? = nil,
        scope: (String, String)? = nil
    ) throws -> URL {
        let (directory, recordScope): (String, String)
        if let scope {
            directory = vaultDir.appendingPathComponent("Memory/\(scope.0)", isDirectory: true).path
            recordScope = scope.1
        } else {
            try FileManager.default.createDirectory(at: globalDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            directory = globalDir.path
            recordScope = "global"
        }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let slug = key.split(separator: "/").last.map(String.init) ?? key
        let url = URL(fileURLWithPath: directory).appendingPathComponent(slug).appendingPathExtension("md")
        let record = AgentMemory.MemoryRecord(
            url: url, key: key, kind: kind, scope: recordScope,
            title: "Rule \(slug)",
            body: "Body for \(slug). Apply it always.",
            appliesWhen: nil,
            evidence: ["pi:s#1"], support: support,
            confidence: "0.7", certainty: "observed", sourceHarness: "agent",
            status: status, validFrom: nil, validUntil: nil,
            supersedes: nil, supersededBy: [],
            asOf: AgentMemory.isoDay(created),
            created: AgentMemory.isoDateTime(created),
            updated: AgentMemory.isoDateTime(updated),
            recalled: recalled, cited: cited,
            lastUsed: lastUsed.map(AgentMemory.isoDateTime),
            recurrences: 0, retireProposed: nil, contentHash: ""
        )
        try memory.serialize(record).write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    // MARK: - Vault init and resolution

    func testInitCreatesPrivateLayoutIdempotently() throws {
        // initialize() already ran in setUp; run it again to prove idempotence.
        _ = try memory.initialize(at: vaultDir)
        XCTAssertEqual(try fileMode(vaultDir.path), 0o700)
        XCTAssertEqual(try fileMode(vaultDir.appendingPathComponent("Memory").path), 0o700)
        XCTAssertEqual(try fileMode(vaultDir.appendingPathComponent(".retex").path), 0o700)
        XCTAssertTrue(FileManager.default.fileExists(atPath: vaultDir.appendingPathComponent(".retex").path))
    }

    func testUninitializedVaultFailsWithoutImplicitCreation() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-memory-missing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: missing) }
        XCTAssertThrowsError(try memory.vault(explicit: missing.path)) { error in
            XCTAssertEqual(
                (error as? AgentMemory.MemoryError)?.reasonCode,
                "not-initialized"
            )
            XCTAssertEqual(error.localizedDescription, "agent memory vault not initialized")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testVaultResolutionOrder() {
        let home = "/home/tester"
        let explicit = AgentMemory.resolveVaultURL(explicit: "/tmp/v", environment: ["AGENT_MEMORY_VAULT": "/tmp/env"], homeDirectory: home)
        XCTAssertEqual(explicit.path, "/tmp/v")
        let fromEnvironment = AgentMemory.resolveVaultURL(explicit: nil, environment: ["AGENT_MEMORY_VAULT": "/tmp/env"], homeDirectory: home)
        XCTAssertEqual(fromEnvironment.path, "/tmp/env")
        let fallback = AgentMemory.resolveVaultURL(explicit: nil, environment: [:], homeDirectory: home)
        XCTAssertEqual(fallback.path, "/home/tester/.local/share/agent-memory")
    }

    private func fileMode(_ path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return attributes[.posixPermissions] as? Int ?? -1
    }

    // MARK: - Validation reason codes

    func testValidationReasonCodes() throws {
        expectReason("missing-field:key") {
            try propose(json: try recordJSON(key: "global/x").dropping(["key"]))
        }
        expectReason("too-long:key") {
            try propose(json: try recordJSON(key: "global/" + String(repeating: "a", count: 90)))
        }
        expectReason("bad-key") {
            try propose(json: try recordJSON(key: "Global/x"))
        }
        expectReason("bad-key") {
            try propose(json: try recordJSON(key: "global"))
        }
        expectReason("bad-scope") {
            try propose(json: try recordJSON(key: "misc/tool"))
        }
        expectReason("bad-scope") {
            try propose(json: try recordJSON(key: "global/tool", scope: "project:other"))
        }
        expectReason("missing-field:kind") {
            try propose(json: try recordJSON(key: "global/x").dropping(["kind"]))
        }
        expectReason("bad-kind") {
            try propose(json: try recordJSON(key: "global/x", kind: "hunch"))
        }
        expectReason("missing-field:title") {
            try propose(json: try recordJSON(key: "global/x").dropping(["title"]))
        }
        expectReason("too-long:title") {
            try propose(json: try recordJSON(key: "global/x", title: String(repeating: "t", count: 121)))
        }
        expectReason("missing-field:body") {
            try propose(json: try recordJSON(key: "global/x").dropping(["body"]))
        }
        expectReason("too-long:body") {
            try propose(json: try recordJSON(key: "global/x", body: String(repeating: "b", count: 601)))
        }
        expectReason("too-long:applies_when") {
            try propose(json: try recordJSON(key: "global/x", appliesWhen: String(repeating: "w", count: 161)))
        }
        expectReason("missing-field:evidence") {
            try propose(json: try recordJSON(key: "global/x", evidence: []))
        }
        expectReason("bad-evidence") {
            try propose(json: try recordJSON(key: "global/x"), evidence: ["smtp:mailserver"])
        }
        expectReason("bad-confidence") {
            try propose(json: try recordJSON(key: "global/x", confidence: "1.5"))
        }
        expectReason("bad-certainty") {
            try propose(json: try recordJSON(key: "global/x", certainty: "guessed"))
        }
        expectReason("speculation") {
            try propose(json: try recordJSON(
                key: "global/x",
                body: "The maybe-correct approach is to restart the server."
            ))
        }
        expectReason("speculation") {
            try propose(json: try recordJSON(
                key: "global/x",
                title: "It seems like npm run deploy is right"
            ))
        }
    }

    func testSecretRejectionReasonCodes() throws {
        // Token-shaped fixtures are assembled at runtime so this public source
        // never contains a literal that secret scanners flag; the scanner under
        // test still sees exactly these shapes.
        func fake(_ prefix: String, _ body: String) -> String { prefix + body }
        let cases: [(String, String)] = [
            ("secret:aws-secret-access-key", "Set " + fake("AWS_SECRET_", "ACCESS_KEY=") + fake("wJalrXUtnFEMI/K7MDENG/", "bPxRfiCYEXAMPLEKEY") + " first."),
            ("secret:bearer-token", "Send Authorization: " + fake("Bearer ", "abcdefgh12345678") + " in the header."),
            ("secret:anthropic-key", "Use " + fake("sk-ant-", "api03-" + String(repeating: "A", count: 22)) + " for the call."),
            ("secret:openai-key", "The key " + fake("sk-", "abcdefghijklmnopqrstuvwx") + " must rotate."),
            ("secret:github-token", "Token " + fake("ghp_", "ABCDEFGHIJKLMNOPQRSTUVWXYZ123456") + " leaked."),
            ("secret:gitlab-pat", "PAT " + fake("glpat-", "ABCDEFGHIJKLMNOPQRSTUVWXYZ12") + " expired."),
            ("secret:stripe-key", "Charge with " + fake("sk_live_", "ABCDEFGHIJKLMNOPQR") + "."),
            ("secret:slack-token", "Slack token " + fake("xoxb-", "123456789012-abcdefghijklmnop") + "."),
            ("secret:private-key", fake("-----BEGIN RSA ", "PRIVATE KEY-----") + " MIIEpAIBAAKCAQEA"),
            ("secret:secret-assignment", fake("MY_DEPLOY_", "TOKEN=") + "sup3rs3cretvalue123 in the env file."),
        ]
        for (code, body) in cases {
            expectReason(code) {
                try propose(json: try recordJSON(key: "global/secret-test", body: body))
            }
        }
        // Ported precision filter: word-shaped sk- lookalikes are identifiers.
        let kept = try propose(json: try recordJSON(
            key: "global/sk-learn-note",
            body: "Read the sk-learn-tutorial-for-beginners guide before coding."
        ))
        XCTAssertEqual(kept.status, "proposed")
    }

    // MARK: - Propose ops

    func testProposeAddCreatesProposedRecordWithPrivateMode() throws {
        let result = try propose(
            json: try recordJSON(key: "global/deploy-lds"),
            evidence: ["operator:2026-09-25"],
            sourceHarness: "claude-code"
        )
        XCTAssertEqual(result.ok, true)
        XCTAssertEqual(result.op, "add")
        XCTAssertEqual(result.key, "global/deploy-lds")
        XCTAssertEqual(result.status, "proposed")
        XCTAssertTrue(result.path.hasSuffix("Memory/global/deploy-lds.md"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))
        XCTAssertEqual(try fileMode(result.path), 0o600)
        XCTAssertEqual(try fileMode(globalDir.path), 0o700)

        let record = try memory.loadRecord(vault: vault, key: "global/deploy-lds")
        XCTAssertEqual(record.status, "proposed")
        XCTAssertEqual(record.support, 1)
        XCTAssertEqual(record.certainty, "inferred")
        XCTAssertEqual(record.sourceHarness, "claude-code")
        XCTAssertEqual(record.evidence, ["pi:2026-09-25-s1#3", "operator:2026-09-25"])
        XCTAssertEqual(record.recalled, 0)
        XCTAssertEqual(record.cited, 0)
        XCTAssertEqual(record.scope, "global")
    }

    func testProposeAddKeyConflictReportsExistingStatus() throws {
        _ = try propose(json: try recordJSON(key: "global/dup"))
        expectReason("key-conflict") {
            try propose(json: try recordJSON(key: "global/dup"))
        }
        // ...and the error message carries the existing status.
        do {
            _ = try memory.propose(
                vault: vault, op: "add", key: nil,
                recordJSON: try recordJSON(key: "global/dup"),
                evidence: [], reason: nil, sourceHarness: nil, ifHash: nil
            )
            XCTFail("expected key-conflict")
        } catch let error as AgentMemory.MemoryError {
            XCTAssertTrue(error.errorDescription?.contains("status: proposed") == true)
        }
    }

    func testProposeUpvoteAppendsEvidenceAndIncrementsSupport() throws {
        _ = try propose(json: try recordJSON(key: "global/up"))
        _ = try memory.promote(vault: vault, key: "global/up", operatorApproved: true, ifHash: nil)
        // Same evidence again plus one new locator: dedup keeps one copy.
        let result = try propose(
            "upvote",
            key: "global/up",
            evidence: ["pi:2026-09-25-s1#3", "pi:2026-09-26-s2#7"]
        )
        XCTAssertEqual(result.status, "active")
        let record = try memory.loadRecord(vault: vault, key: "global/up")
        XCTAssertEqual(record.support, 2)
        XCTAssertEqual(record.evidence, ["pi:2026-09-25-s1#3", "pi:2026-09-26-s2#7"])

        expectReason("bad-status") {
            // Retired records are not live and cannot be upvoted.
            _ = try memory.retire(vault: vault, key: "global/up", reason: "obsolete", operatorApproved: true, ifHash: nil)
            try propose("upvote", key: "global/up", evidence: ["git:repo@abc123"])
        }
    }

    func testContextHeadingIsHostNamedAndSanitized() throws {
        XCTAssertEqual(AgentMemory.packHeading("UltraTerm memory"), "UltraTerm memory")
        XCTAssertEqual(AgentMemory.packHeading(nil), "Agent memory")
        XCTAssertEqual(AgentMemory.packHeading("two\nlines"), "Agent memory")
        XCTAssertEqual(AgentMemory.packHeading("# injected"), "Agent memory")
        let pack = try memory.context(vault: vault, project: nil, budget: 2000, harness: "claude-code", heading: "UltraTerm memory")
        XCTAssertTrue(pack.pack.hasPrefix("## UltraTerm memory ("), pack.pack)
    }

    func testRecordJSONAcceptsNumericConfidence() throws {
        let numeric = try AgentMemory.parseRecordJSON(Data(#"{"key":"global/n","confidence":0.75}"#.utf8))
        XCTAssertEqual(numeric.confidence, "0.75")
        let text = try AgentMemory.parseRecordJSON(Data(#"{"key":"global/n","confidence":"0.5"}"#.utf8))
        XCTAssertEqual(text.confidence, "0.5")
        XCTAssertThrowsError(try AgentMemory.parseRecordJSON(Data(#"{"key":"global/n","confidence":true}"#.utf8)))
    }

    func testUpvoteWithoutNewEvidenceChangesNothing() throws {
        _ = try propose(json: try recordJSON(key: "global/idem"))
        let first = try propose("upvote", key: "global/idem", evidence: ["pi:2026-09-26-s2#7"])
        XCTAssertEqual(first.changed, true)
        let before = try memory.loadRecord(vault: vault, key: "global/idem")
        let beforeBytes = try Data(contentsOf: URL(fileURLWithPath: first.path))
        // The same week dreamed again: every locator is already recorded.
        let repeat_ = try propose("upvote", key: "global/idem", evidence: ["pi:2026-09-26-s2#7", "pi:2026-09-25-s1#3"])
        XCTAssertEqual(repeat_.changed, false)
        XCTAssertTrue(repeat_.ok)
        let after = try memory.loadRecord(vault: vault, key: "global/idem")
        XCTAssertEqual(after.support, before.support)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: first.path)), beforeBytes, "no write")
    }

    func testProposeUpvoteCASAndNotFound() throws {
        _ = try propose(json: try recordJSON(key: "global/cas"))
        let stale = try memory.loadRecord(vault: vault, key: "global/cas").contentHash
        _ = try propose("upvote", key: "global/cas", evidence: ["operator:2026-09-26"])
        expectReason("hash-mismatch") {
            try propose("upvote", key: "global/cas", evidence: ["operator:2026-09-27"], ifHash: stale)
        }
        expectReason("not-found") {
            try propose("upvote", key: "global/absent", evidence: ["operator:2026-09-27"])
        }
        expectReason("missing-field:evidence") {
            try propose("upvote", key: "global/cas", evidence: [])
        }
    }

    func testProposeEditCreatesSuccessorWithSupersedes() throws {
        _ = try propose(json: try recordJSON(key: "global/edit-me", body: "Old wording."))
        let result = try propose(
            "edit",
            key: "global/edit-me",
            json: try recordJSON(key: "ignored", body: "New wording with npm run deploy.")
        )
        XCTAssertEqual(result.key, "global/edit-me-v2")
        XCTAssertEqual(result.status, "proposed")
        let successor = try memory.loadRecord(vault: vault, key: "global/edit-me-v2")
        XCTAssertEqual(successor.supersedes, "global/edit-me")
        XCTAssertEqual(successor.title, "Deploy LDS with npm run deploy") // inherited
        XCTAssertEqual(successor.body, "New wording with npm run deploy.")
        XCTAssertEqual(successor.evidence, ["pi:2026-09-25-s1#3"]) // inherited

        // A second edit chains to v3.
        let third = try propose("edit", key: "global/edit-me-v2", json: nil)
        XCTAssertEqual(third.key, "global/edit-me-v3")
    }

    func testProposeEditRequiresExistingKey() throws {
        expectReason("not-found") {
            try propose("edit", key: "global/ghost", json: try recordJSON(key: "x", body: "b"))
        }
    }

    func testProposeRetireMarksFieldWithoutStatusChange() throws {
        _ = try propose(json: try recordJSON(key: "global/retire-me"))
        let result = try propose("retire", key: "global/retire-me", reason: "superseded by the new flow")
        XCTAssertEqual(result.status, "proposed")
        let record = try memory.loadRecord(vault: vault, key: "global/retire-me")
        XCTAssertEqual(record.status, "proposed")
        XCTAssertEqual(record.retireProposed, "superseded by the new flow")

        expectReason("missing-field:reason") {
            try propose("retire", key: "global/retire-me", reason: nil)
        }
    }

    // MARK: - Operator actions

    func testOperatorActionsRequireApproval() throws {
        _ = try propose(json: try recordJSON(key: "global/gated"))
        expectReason("not-authorized") {
            try memory.promote(vault: vault, key: "global/gated", operatorApproved: false, ifHash: nil)
        }
        expectReason("not-authorized") {
            try memory.reject(vault: vault, key: "global/gated", operatorApproved: false, ifHash: nil)
        }
        expectReason("not-authorized") {
            try memory.retire(vault: vault, key: "global/gated", reason: nil, operatorApproved: false, ifHash: nil)
        }
        expectReason("not-authorized") {
            try memory.stale(vault: vault, key: "global/gated", operatorApproved: false, ifHash: nil)
        }
    }

    func testPromoteRejectRetireStaleTransitions() throws {
        _ = try propose(json: try recordJSON(key: "global/flow"))
        let promoted = try memory.promote(vault: vault, key: "global/flow", operatorApproved: true, ifHash: nil)
        XCTAssertEqual(promoted.status, "active")
        var record = try memory.loadRecord(vault: vault, key: "global/flow")
        XCTAssertEqual(record.validFrom?.count, 10)

        // promote only accepts proposed records
        expectReason("bad-status") {
            try memory.promote(vault: vault, key: "global/flow", operatorApproved: true, ifHash: nil)
        }

        _ = try memory.stale(vault: vault, key: "global/flow", operatorApproved: true, ifHash: nil)
        record = try memory.loadRecord(vault: vault, key: "global/flow")
        XCTAssertEqual(record.status, "stale")

        _ = try memory.reject(vault: vault, key: "global/flow", operatorApproved: true, ifHash: nil)
        record = try memory.loadRecord(vault: vault, key: "global/flow")
        XCTAssertEqual(record.status, "rejected")

        // retire requires an active record
        expectReason("bad-status") {
            try memory.retire(vault: vault, key: "global/flow", reason: nil, operatorApproved: true, ifHash: nil)
        }
    }

    func testPromoteSupersessionChain() throws {
        _ = try propose(json: try recordJSON(key: "global/chain", body: "Old rule."))
        _ = try memory.promote(vault: vault, key: "global/chain", operatorApproved: true, ifHash: nil)
        _ = try propose("edit", key: "global/chain", json: try recordJSON(key: "x", body: "New rule."))
        _ = try memory.promote(vault: vault, key: "global/chain-v2", operatorApproved: true, ifHash: nil)

        let successor = try memory.loadRecord(vault: vault, key: "global/chain-v2")
        XCTAssertEqual(successor.status, "active")
        XCTAssertNotNil(successor.validFrom)

        let superseded = try memory.loadRecord(vault: vault, key: "global/chain")
        XCTAssertEqual(superseded.status, "retired")
        XCTAssertNotNil(superseded.validUntil)
        XCTAssertEqual(superseded.supersededBy, ["global/chain-v2"])

        // doctor sees a consistent chain
        let report = try memory.doctor(vault: vault)
        XCTAssertTrue(report.ok, "\(report.issues)")
    }

    // MARK: - Serialization round trip

    func testSerializeParseRoundTrip() throws {
        _ = try propose(
            json: try recordJSON(
                key: "global/round-trip",
                appliesWhen: "when deploying LDS",
                confidence: "0.85",
                certainty: "observed"
            ),
            evidence: ["operator:2026-09-25", "git:repo@deadbeef"]
        )
        _ = try memory.promote(vault: vault, key: "global/round-trip", operatorApproved: true, ifHash: nil)
        let record = try memory.loadRecord(vault: vault, key: "global/round-trip")
        let url = record.url
        let before = try Data(contentsOf: url)
        let reparsed = AgentMemory.parse(note: try MarkdownStore().load(url))
        XCTAssertEqual(memory.serialize(reparsed), String(decoding: before, as: UTF8.self))
    }

    // MARK: - Session pack

    private let fixedNow = Date(timeIntervalSince1970: 1_769_000_000) // 2026-01

    private func seededRandom(_ count: Int) -> [AgentMemory.MemoryRecord] {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
        let kinds = ["correction", "gotcha", "decision", "procedure", "preference"]
        return (0..<count).map { index -> AgentMemory.MemoryRecord in
            let created = fixedNow.addingTimeInterval(-Double(next(300)) * 86_400)
            let updated = created.addingTimeInterval(Double(next(200)) * 86_400)
            let lastUsed = next(2) == 0 ? updated.addingTimeInterval(Double(next(120)) * 86_400) : updated
            let url = globalDir.appendingPathComponent("r\(index)").appendingPathExtension("md")
            return AgentMemory.MemoryRecord(
                url: url,
                key: String(format: "global/r%03d", index),
                kind: kinds[next(kinds.count)],
                scope: "global",
                title: String(format: "Rule %03d for deploys", index),
                body: String(format: "Body %03d explains the npm run deploy rule in detail.", index),
                appliesWhen: nil,
                evidence: ["pi:s#\(index)"],
                support: 1 + next(6),
                confidence: "0.7",
                certainty: "observed",
                sourceHarness: "agent",
                status: "active",
                validFrom: nil,
                validUntil: nil,
                supersedes: nil,
                supersededBy: [],
                asOf: AgentMemory.isoDay(created),
                created: AgentMemory.isoDateTime(created),
                updated: AgentMemory.isoDateTime(updated),
                recalled: next(30),
                cited: next(10),
                lastUsed: AgentMemory.isoDateTime(lastUsed),
                recurrences: 0,
                retireProposed: nil,
                contentHash: ""
            )
        }
    }

    func testContextBudgetNeverExceededAcrossBudgets() throws {
        let ranked = AgentMemory.rankRecords(seededRandom(200), now: fixedNow)
        XCTAssertEqual(ranked.count, 200)
        var previousEmitted = 0
        var budget = 500
        while budget <= 8000 {
            let pack = AgentMemory.buildContextPack(ranked: ranked, budget: budget)
            XCTAssertLessThanOrEqual(
                pack.text.utf8.count, budget,
                "pack exceeded budget \(budget): \(pack.text.utf8.count) bytes"
            )
            XCTAssertGreaterThanOrEqual(pack.emitted.count, previousEmitted)
            if pack.excluded > 0 {
                XCTAssertTrue(pack.text.contains("(\(pack.excluded) more active memories; run: retex memory recall \"<topic>\")"))
            }
            if !pack.emitted.isEmpty {
                XCTAssertTrue(pack.text.hasPrefix("## Agent memory (\(pack.emitted.count) of 200 active)"))
            }
            previousEmitted = pack.emitted.count
            budget += 100
        }
        XCTAssertGreaterThan(previousEmitted, 0)
    }

    func testContextPackIsDeterministicAndWholeRecords() throws {
        let records = seededRandom(60)
        let ranked = AgentMemory.rankRecords(records, now: fixedNow)
        let first = AgentMemory.buildContextPack(ranked: ranked, budget: 2000)
        let second = AgentMemory.buildContextPack(ranked: ranked, budget: 2000)
        XCTAssertEqual(first.text, second.text)
        XCTAssertEqual(first.emitted.map(\.record.key), second.emitted.map(\.record.key))

        // Records are never cut mid-way: every emitted key appears in full.
        for ranked in first.emitted {
            XCTAssertTrue(first.text.contains("(key: \(ranked.record.key))"))
            XCTAssertTrue(first.text.contains("- **\(ranked.record.title)** — "))
        }
        // Ties break by key.
        XCTAssertEqual(
            AgentMemory.rankRecords(records, now: fixedNow).map(\.record.key),
            ranked.map(\.record.key)
        )
    }

    func testContextExcludesProposedAndRespectsScope() throws {
        _ = try propose(json: try recordJSON(key: "global/active-one"))
        _ = try memory.promote(vault: vault, key: "global/active-one", operatorApproved: true, ifHash: nil)
        _ = try propose(json: try recordJSON(key: "global/still-proposed"))

        // A project-scoped record: key project-lds/x, scope project:lds.
        _ = try directRecord(
            key: "project-lds/x", created: fixedNow, updated: fixedNow,
            scope: ("project-lds", "project:lds")
        )

        let result = try memory.context(
            vault: vault, scope: "global", project: nil, budget: 6000, harness: "pi", now: fixedNow
        )
        XCTAssertEqual(result.totalActive, 1) // only the active global record
        XCTAssertFalse(result.pack.contains("still-proposed"))
        XCTAssertFalse(result.pack.contains("project-lds/x"))
        XCTAssertFalse(result.pack.contains("proposed"))

        let withProject = try memory.context(
            vault: vault, scope: "global", project: "lds", budget: 6000, harness: nil, now: fixedNow
        )
        XCTAssertEqual(withProject.totalActive, 2)
        XCTAssertTrue(withProject.pack.contains("(key: project-lds/x)"))
        XCTAssertTrue(withProject.pack.contains("## Agent memory (2 of 2 active)"))
    }

    func testContextCounterUpdateUnderTryLock() throws {
        _ = try propose(json: try recordJSON(key: "global/counted"))
        _ = try memory.promote(vault: vault, key: "global/counted", operatorApproved: true, ifHash: nil)

        let lockPath = UndoHistory.journalURL(for: vault).path + ".lock"
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer {
            flock(fd, LOCK_UN)
            close(fd)
        }
        XCTAssertEqual(flock(fd, LOCK_EX), 0, errno_descr())

        // A busy lock skips the counter update instead of blocking.
        let skipped = try memory.context(
            vault: vault, scope: "global", project: nil, budget: 6000, harness: nil, now: fixedNow
        )
        XCTAssertFalse(skipped.countersUpdated)
        XCTAssertEqual(skipped.emitted, 1)
        var record = try memory.loadRecord(vault: vault, key: "global/counted")
        XCTAssertEqual(record.recalled, 0)
        XCTAssertNil(record.lastUsed)

        // With the lock released the update lands.
        XCTAssertEqual(flock(fd, LOCK_UN), 0)
        let updated = try memory.context(
            vault: vault, scope: "global", project: nil, budget: 6000, harness: nil, now: fixedNow
        )
        XCTAssertTrue(updated.countersUpdated)
        record = try memory.loadRecord(vault: vault, key: "global/counted")
        XCTAssertEqual(record.recalled, 1)
        XCTAssertNotNil(record.lastUsed)

        // Telemetry leaves no undo entries.
        let entries = try UndoHistory().entries(for: record.url.path)
        XCTAssertEqual(entries.count, 2) // create + promote only
    }

    private func errno_descr() -> String { String(describing: errno) }

    func testBudgetAboveHardMaxRejected() {
        expectReason("bad-budget") {
            try memory.context(vault: vault, scope: "global", project: nil, budget: 8001, harness: nil)
        }
    }

    // MARK: - Recall

    func testRecallFiltersStatusAndLabelsProposed() throws {
        _ = try propose(json: try recordJSON(key: "global/recall-active", title: "Vercel deploy rule", body: "Deploy with npm run deploy."))
        _ = try memory.promote(vault: vault, key: "global/recall-active", operatorApproved: true, ifHash: nil)
        _ = try propose(json: try recordJSON(key: "global/recall-proposed", title: "Preview DNS note", body: "Preview DNS needs the deploy token rotation."))

        let activeOnly = try memory.recall(vault: vault, query: "deploy", budget: 4000, includeProposed: false)
        XCTAssertEqual(activeOnly.records.map(\.key), ["global/recall-active"])
        XCTAssertFalse(activeOnly.truncated)

        let withProposed = try memory.recall(vault: vault, query: "deploy", budget: 4000, includeProposed: true)
        XCTAssertTrue(withProposed.records.contains { $0.key == "global/recall-proposed" && $0.title.hasPrefix("[proposed] ") })
        XCTAssertEqual(withProposed.records.count, 2)

        // Byte budget respected: a tiny budget packs nothing.
        let tiny = try memory.recall(vault: vault, query: "deploy", budget: 10, includeProposed: true)
        XCTAssertTrue(tiny.records.isEmpty)
        XCTAssertEqual(tiny.usedBytes, 2)

        expectReason("bad-budget") {
            try memory.recall(vault: vault, query: "deploy", budget: 0, includeProposed: false)
        }
    }

    // MARK: - Review

    func testReviewSortsAndFlagsPromoteReady() throws {
        // promote-ready: correction, support 2, two distinct sessions, operator evidence.
        _ = try propose(json: try recordJSON(key: "global/ready", title: "Ready correction"))
        _ = try propose("upvote", key: "global/ready", evidence: ["pi:2026-09-26-s2#1", "operator:2026-09-27"])
        // support 2 but no operator evidence
        _ = try propose(json: try recordJSON(key: "global/no-operator", kind: "correction", title: "No operator"))
        _ = try propose("upvote", key: "global/no-operator", evidence: ["pi:2026-09-26-s2#1"])
        // operator evidence but wrong kind
        _ = try propose(json: try recordJSON(key: "global/wrong-kind", kind: "gotcha", title: "Wrong kind"))
        _ = try propose("upvote", key: "global/wrong-kind", evidence: ["operator:2026-09-26"])
        // operator-flavoured (#user) but a single distinct session
        _ = try propose(json: try recordJSON(
            key: "global/one-session",
            title: "One session",
            evidence: ["claude:session-a#user-1"]
        ))
        _ = try propose("upvote", key: "global/one-session", evidence: ["claude:session-a#user-2"])

        let items = try memory.review(vault: vault)
        XCTAssertEqual(items.count, 4)
        let byKey = Dictionary(uniqueKeysWithValues: items.map { ($0.key, $0) })
        let ready = try XCTUnwrap(byKey["global/ready"])
        XCTAssertTrue(ready.promoteReady)
        XCTAssertEqual(ready.distinctSessions, 3)
        XCTAssertFalse(try XCTUnwrap(byKey["global/no-operator"]).promoteReady)
        XCTAssertFalse(try XCTUnwrap(byKey["global/wrong-kind"]).promoteReady)
        XCTAssertFalse(try XCTUnwrap(byKey["global/one-session"]).promoteReady)
        XCTAssertEqual(try XCTUnwrap(byKey["global/one-session"]).distinctSessions, 1)
        // Same-support proposals tie-break by created then key.
        XCTAssertEqual(items.map(\.key), items.map(\.key).sorted())
    }

    func testReviewSupportOrderingBeatsCreation() throws {
        // A higher-support proposal created later must come first.
        _ = try propose(json: try recordJSON(key: "global/aaa-early", title: "Early"))
        _ = try propose(json: try recordJSON(key: "global/zzz-late", title: "Late"))
        _ = try propose("upvote", key: "global/zzz-late", evidence: ["pi:2026-09-26-s9#1"])
        let items = try memory.review(vault: vault)
        XCTAssertEqual(items.map(\.key), ["global/zzz-late", "global/aaa-early"])
    }

    // MARK: - Cite

    func testCiteIncrementsCitedCounterAsTelemetry() throws {
        _ = try propose(json: try recordJSON(key: "global/cited"))
        _ = try memory.promote(vault: vault, key: "global/cited", operatorApproved: true, ifHash: nil)
        let result = try memory.cite(vault: vault, key: "global/cited", now: fixedNow)
        XCTAssertEqual(result.countersUpdated, true)
        let record = try memory.loadRecord(vault: vault, key: "global/cited")
        XCTAssertEqual(record.cited, 1)
        XCTAssertEqual(record.recalled, 0)
        XCTAssertNotNil(record.lastUsed)
        // No undo entry for telemetry.
        XCTAssertEqual(try UndoHistory().entries(for: record.url.path).count, 2)

        expectReason("not-found") {
            try memory.cite(vault: vault, key: "global/missing")
        }
    }

    // MARK: - Doctor

    func testDoctorClean() throws {
        _ = try propose(json: try recordJSON(key: "global/healthy"))
        _ = try memory.promote(vault: vault, key: "global/healthy", operatorApproved: true, ifHash: nil)
        let report = try memory.doctor(vault: vault)
        XCTAssertEqual(report.records, 1)
        XCTAssertTrue(report.ok, "\(report.issues)")
    }

    func testDoctorDetectsDuplicateKeysModesAndBrokenChains() throws {
        _ = try propose(json: try recordJSON(key: "global/duplicated"))
        // Same key in a second file.
        let original = try Data(contentsOf: globalDir.appendingPathComponent("duplicated.md"))
        try original.write(to: globalDir.appendingPathComponent("duplicate-copy.md"))
        // Wrong file mode.
        _ = try propose(json: try recordJSON(key: "global/loose-mode"))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: globalDir.appendingPathComponent("loose-mode.md").path)
        // Broken supersedes chain.
        let record = AgentMemory.MemoryRecord(
            url: globalDir.appendingPathComponent("broken-chain.md"),
            key: "global/broken-chain", kind: "gotcha", scope: "global",
            title: "Broken", body: "Points at a missing key.",
            appliesWhen: nil, evidence: ["pi:s#1"], support: 1,
            confidence: "0.7", certainty: "inferred", sourceHarness: "agent",
            status: "active", validFrom: nil, validUntil: nil,
            supersedes: "global/missing-target", supersededBy: [],
            asOf: "2026-01-01", created: "2026-01-01T00:00:00Z", updated: "2026-01-01T00:00:00Z",
            recalled: 0, cited: 0, lastUsed: nil, recurrences: 0,
            retireProposed: nil, contentHash: ""
        )
        try memory.serialize(record).write(to: record.url, atomically: true, encoding: .utf8)

        let report = try memory.doctor(vault: vault)
        XCTAssertFalse(report.ok)
        XCTAssertTrue(report.issues.contains { $0.contains("Duplicate key global/duplicated") }, "\(report.issues)")
        XCTAssertTrue(report.issues.contains { $0.contains("file mode 644 should be 600") }, "\(report.issues)")
        XCTAssertTrue(report.issues.contains { $0.contains("supersedes missing record global/missing-target") }, "\(report.issues)")
        XCTAssertTrue(report.issues.contains { $0.contains("file does not match key") }, "\(report.issues)")
    }

    func testDoctorFlagsActiveRecordSupersedingNonRetiredTarget() throws {
        _ = try propose(json: try recordJSON(key: "global/target-still-active"))
        _ = try memory.promote(vault: vault, key: "global/target-still-active", operatorApproved: true, ifHash: nil)
        _ = try propose("edit", key: "global/target-still-active", json: try recordJSON(key: "x", body: "New."))
        _ = try memory.promote(vault: vault, key: "global/target-still-active-v2", operatorApproved: true, ifHash: nil)
        // Hand-edit the superseded record back to active (broken chain).
        let record = try memory.loadRecord(vault: vault, key: "global/target-still-active")
        var edited = record
        edited.status = "active"
        edited.validUntil = nil
        try memory.serialize(edited).write(to: record.url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: record.url.path)

        let report = try memory.doctor(vault: vault)
        XCTAssertFalse(report.ok)
        XCTAssertTrue(
            report.issues.contains { $0.contains("active record supersedes global/target-still-active") },
            "\(report.issues)"
        )
    }

    // MARK: - Undo byte-exact round trip (propose -> promote -> undo -> undo)

    func testUndoRoundTripRestoresOriginalBytes() throws {
        _ = try propose(json: try recordJSON(key: "global/undo-me"))
        let url = try memory.recordURL(vault: vault, key: "global/undo-me")
        let original = try Data(contentsOf: url)

        _ = try memory.promote(vault: vault, key: "global/undo-me", operatorApproved: true, ifHash: nil)
        XCTAssertNotEqual(try Data(contentsOf: url), original)

        let history = UndoHistory()
        // Undo the promote.
        let promoteEntry = try XCTUnwrap(history.pop(path: url.path))
        try promoteEntry.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(try Data(contentsOf: url), original)

        // Undo the create: the creation entry restores the proposal bytes.
        let createEntry = try XCTUnwrap(history.pop(path: url.path))
        try createEntry.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertNil(try history.pop(path: url.path))
    }

    // MARK: - MCP tools

    func testMCPToolsListRespectsReadOnly() throws {
        setenv("AGENT_MEMORY_VAULT", vaultDir.path, 1)
        defer { unsetenv("AGENT_MEMORY_VAULT") }

        let readList = try MCPTestHarness.run(
            vault: vault,
            requests: [#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#],
            readOnly: true
        )
        XCTAssertTrue(readList[0].contains("memory_context"))
        XCTAssertTrue(readList[0].contains("memory_recall"))
        XCTAssertTrue(readList[0].contains("memory_review"))
        XCTAssertFalse(readList[0].contains("memory_propose"))

        let writeList = try MCPTestHarness.run(
            vault: vault,
            requests: [#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#],
            readOnly: false
        )
        XCTAssertTrue(writeList[0].contains("memory_propose"))
    }

    func testMCPMemoryToolsRoundTrip() throws {
        setenv("AGENT_MEMORY_VAULT", vaultDir.path, 1)
        defer { unsetenv("AGENT_MEMORY_VAULT") }

        // A read-only server refuses the write tool outright.
        let refused = try MCPTestHarness.run(
            vault: vault,
            requests: [
                #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"memory_propose","arguments":{"op":"add"}}}"#,
            ],
            readOnly: true
        )
        XCTAssertTrue(refused[0].contains("error"), refused[0])

        // With --allow-write the propose tool writes through the same
        // validation, locking, and journal path as the CLI. Requests are
        // built with JSONSerialization so string escaping stays valid.
        func request(id: Int, tool: String, arguments: [String: Any] = [:]) -> String {
            let object: [String: Any] = [
                "jsonrpc": "2.0",
                "id": id,
                "method": "tools/call",
                "params": [
                    "name": tool,
                    "arguments": arguments,
                ],
            ]
            let data = try! JSONSerialization.data(withJSONObject: object)
            return String(decoding: data, as: UTF8.self)
        }
        let record = String(decoding: try recordJSON(
            key: "global/via-mcp",
            title: "MCP rule",
            body: "Proposed over MCP."
        ), as: UTF8.self)

        let responses = try MCPTestHarness.run(
            vault: vault,
            requests: [
                request(id: 1, tool: "memory_propose", arguments: ["op": "add", "record": record]),
                request(id: 2, tool: "memory_review"),
                request(id: 3, tool: "memory_context", arguments: ["budget": 2000]),
                request(id: 5, tool: "memory_recall", arguments: ["query": "MCP", "include_proposed": "true"]),
            ],
            readOnly: false
        )
        XCTAssertTrue(responses[0].contains("global/via-mcp"), responses[0])
        XCTAssertTrue(responses[0].contains("proposed"), responses[0])
        XCTAssertTrue(responses[1].contains("MCP rule"), responses[1])
        XCTAssertTrue(responses[2].contains("pack"), responses[2])
        XCTAssertTrue(responses[3].contains("via-mcp"), responses[3])
    }
}

private extension Data {
    /// Drops the given frontmatter fields from a small JSON record payload
    /// (used to build missing-field validation cases).
    func dropping(_ fields: [String]) -> Data {
        guard var object = try? JSONSerialization.jsonObject(with: self) as? [String: Any] else { return self }
        for field in fields { object.removeValue(forKey: field) }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? self
    }
}
