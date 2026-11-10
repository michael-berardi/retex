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
        sourceHarness: String? = nil,
        verifiedBy: String? = nil,
        confirmation: String? = nil
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
        if let verifiedBy { object["verified_by"] = verifiedBy }
        if let confirmation { object["confirmation"] = confirmation }
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
        verification: (String, String)? = nil,
        verifiedBy: String? = nil,
        confirmation: String? = nil,
        now: Date = Date(),
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> AgentMemory.MutationResult {
        try memory.propose(
            vault: vault, op: op, key: key, recordJSON: json,
            evidence: evidence, reason: reason, sourceHarness: sourceHarness,
            ifHash: ifHash,
            verifiedBy: verification?.0 ?? verifiedBy,
            confirmation: verification?.1 ?? confirmation,
            now: now
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
        recallHits: Int = 0,
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
            recalled: recalled, cited: cited, recallHits: recallHits,
            lastUsed: lastUsed.map(AgentMemory.isoDateTime),
            recurrences: 0, retireProposed: nil,
            verifiedBy: nil, confirmation: nil, contentHash: ""
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
                recallHits: next(6),
                lastUsed: AgentMemory.isoDateTime(lastUsed),
                recurrences: 0,
                retireProposed: nil,
                verifiedBy: nil,
                confirmation: nil,
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

        // Records are never cut mid-way: every emitted key appears with its
        // key, and a full entry also carries the bold title and a body sentence.
        for item in first.emitted {
            XCTAssertTrue(first.text.contains("(key: \(item.record.key))"))
            switch item.mode {
            case "full":
                XCTAssertTrue(first.text.contains("- **\(item.record.title)** — "))
            case "index":
                XCTAssertFalse(first.text.contains("**\(item.record.title)**"), "index entries carry no body")
            default:
                XCTFail("unexpected mode \(item.mode)")
            }
        }
        // Ties break by key.
        XCTAssertEqual(
            AgentMemory.rankRecords(records, now: fixedNow).map(\.record.key),
            ranked.map(\.record.key)
        )
    }

    // The split: pinned rules in full, then index lines for the rest.
    func testPackIsPinnedFullPlusIndexAndAlwaysWithinBudget() throws {
        let records = seededRandom(120)
        let ranked = AgentMemory.rankRecords(records, now: fixedNow)
        let budget = 2000
        let pack = AgentMemory.buildContextPack(ranked: ranked, budget: budget)
        XCTAssertLessThanOrEqual(pack.text.utf8.count, budget)

        // The five highest-support records (ties by key) are always full.
        let top = records.sorted {
            if $0.support != $1.support { return $0.support > $1.support }
            return $0.key < $1.key
        }.prefix(AgentMemory.pinnedRecordCount)
        for record in top {
            XCTAssertTrue(
                pack.emitted.contains { $0.record.key == record.key && $0.mode == "full" },
                "pinned \(record.key) is not in full: \(pack.text)"
            )
        }

        XCTAssertGreaterThan(pack.indexCount, 0, "no index entries at budget \(budget): \(pack.text)")
        XCTAssertGreaterThan(pack.emitted.count, pack.fullCount)
        XCTAssertTrue(pack.text.contains("Index (recall by key):"))
        // Index entries never carry a body sentence: the line is title + key.
        for item in pack.emitted where item.mode == "index" {
            let line = AgentMemory.indexLine(item.record, width: AgentMemory.defaultIndexTitleWidth)
            XCTAssertTrue(line.hasSuffix("(key: \(item.record.key))"))
            XCTAssertFalse(line.contains(" — "))
            XCTAssertFalse(line.contains("**"))
        }
        // Full entries stay inside the full share of the budget (the pinned
        // set is exempt: support outranks the split).
        let fullBytes = pack.emitted.filter { $0.mode == "full" }
            .reduce(0) { $0 + AgentMemory.fullLine($1.record).utf8.count }
        XCTAssertLessThanOrEqual(fullBytes, budget * AgentMemory.defaultFullShare / 100 + 600)
        XCTAssertEqual(pack.excluded, ranked.count - pack.emitted.count)
        XCTAssertTrue(pack.text.contains("(\(pack.excluded) more active memories"), pack.text)
        XCTAssertTrue(pack.text.hasSuffix("\n"))
    }

    func testFullShareChangesTheSplitAndIsDocumentedAsAnOption() throws {
        let ranked = AgentMemory.rankRecords(seededRandom(120), now: fixedNow)
        let budget = 1500
        let indexOnly = AgentMemory.buildContextPack(ranked: ranked, budget: budget, fullShare: 0)
        let shared = AgentMemory.buildContextPack(ranked: ranked, budget: budget)
        let fullOnly = AgentMemory.buildContextPack(ranked: ranked, budget: budget, fullShare: 100)

        // Share 0: the pinned rules stay full, everything else is indexed, so
        // the most rules are visible.
        XCTAssertEqual(indexOnly.fullCount, AgentMemory.pinnedRecordCount)
        XCTAssertEqual(indexOnly.indexCount, indexOnly.emitted.count - indexOnly.fullCount)
        XCTAssertGreaterThanOrEqual(indexOnly.emitted.count, shared.emitted.count)
        // Share 100: the pre-1.9 pack — full entries only, no index section.
        XCTAssertEqual(fullOnly.fullCount, fullOnly.emitted.count)
        XCTAssertFalse(fullOnly.text.contains("Index (recall by key):"))
        XCTAssertLessThan(fullOnly.emitted.count, indexOnly.emitted.count)
        // Every variant respects the budget.
        for pack in [indexOnly, shared, fullOnly] {
            XCTAssertLessThanOrEqual(pack.text.utf8.count, budget)
        }
        // The index title cap is honoured.
        let narrow = AgentMemory.buildContextPack(ranked: ranked, budget: budget, indexTitleWidth: 20)
        for item in narrow.emitted where item.mode == "index" {
            let line = AgentMemory.indexLine(item.record, width: 20)
            let title = line.dropFirst(2).split(separator: "(").first ?? ""
            XCTAssertLessThanOrEqual(title.utf8.count, 20 + 3)
        }
    }

    // Deterministic daily rotation: one day = one pack, and every non-pinned
    // record gets a turn within a cycle.
    func testIndexRotationIsDeterministicPerDayAndCoversEveryRecord() throws {
        let records = seededRandom(160)
        let ranked = AgentMemory.rankRecords(records, now: fixedNow)
        let day = 20_474 // 2026-01-21 in whole UTC days

        // Same day, same bytes; the next day differs.
        let first = AgentMemory.buildContextPack(ranked: ranked, budget: 2000, dayNumber: day)
        let again = AgentMemory.buildContextPack(ranked: ranked, budget: 2000, dayNumber: day)
        XCTAssertEqual(first.text, again.text)
        XCTAssertEqual(first.emitted.map(\.record.key), again.emitted.map(\.record.key))
        let next = AgentMemory.buildContextPack(ranked: ranked, budget: 2000, dayNumber: day + 1)
        XCTAssertNotEqual(first.emitted.map(\.record.key), next.emitted.map(\.record.key))

        // The five highest-support records are pinned in full every day.
        let top = records.sorted {
            if $0.support != $1.support { return $0.support > $1.support }
            return $0.key < $1.key
        }.prefix(AgentMemory.pinnedRecordCount)
        var seen = Set<String>()
        for offset in 0..<20 {
            let pack = AgentMemory.buildContextPack(ranked: ranked, budget: 2000, dayNumber: day + offset)
            XCTAssertLessThanOrEqual(pack.text.utf8.count, 2000)
            for record in top {
                XCTAssertTrue(
                    pack.emitted.contains { $0.record.key == record.key && $0.mode == "full" },
                    "day +\(offset): pinned \(record.key) not in full"
                )
            }
            for item in pack.emitted where item.mode == "index" {
                seen.insert(item.record.key)
            }
        }
        // Every non-pinned record enters the index within one cycle.
        let nonPinned = Set(records.map(\.key)).subtracting(top.map(\.key))
        XCTAssertEqual(seen.union(top.map(\.key)), Set(records.map(\.key)))
        XCTAssertEqual(nonPinned.subtracting(seen), [], "\(nonPinned.subtracting(seen).count) never indexed")
    }

    func testRotationVectorKeepsRankOrderAndWraps() throws {
        let ranked = AgentMemory.rankRecords(seededRandom(12), now: fixedNow)
        let zero = AgentMemory.rotated(ranked, dayNumber: 0).map(\.record.key)
        XCTAssertEqual(zero, ranked.map(\.record.key))
        let one = AgentMemory.rotated(ranked, dayNumber: 1).map(\.record.key)
        XCTAssertEqual(one.count, ranked.count)
        XCTAssertEqual(Set(one), Set(zero))
        let step = AgentMemory.indexRotationStep % ranked.count
        let expected = Array(zero[step...]) + Array(zero[..<step])
        XCTAssertEqual(one, expected)
        // The seed is the UTC day of the reference date, not the clock time.
        XCTAssertEqual(AgentMemory.dayNumber(fixedNow), AgentMemory.dayNumber(fixedNow.addingTimeInterval(3_600)))
    }

    func testDayOptionMakesThePackStablePerDay() throws {
        _ = try propose(json: try recordJSON(key: "global/day-one", title: "Day one rule", body: "Do the thing."))
        _ = try memory.promote(vault: vault, key: "global/day-one", operatorApproved: true, ifHash: nil)
        let day = Date(timeIntervalSince1970: 1_769_000_000)
        let morning = try memory.context(
            vault: vault, scope: "global", project: nil, budget: 6000, harness: nil, now: day
        )
        let evening = try memory.context(
            vault: vault, scope: "global", project: nil, budget: 6000, harness: nil,
            now: day.addingTimeInterval(8 * 3_600)
        )
        XCTAssertEqual(morning.pack, evening.pack, "the same UTC day must produce the same pack")
    }

    func testPackOptionsAreValidated() {
        expectReason("bad-full-share") {
            try memory.context(vault: vault, scope: "global", project: nil, budget: 6000,
                               harness: nil, fullShare: 101)
        }
        expectReason("bad-index-width") {
            try memory.context(vault: vault, scope: "global", project: nil, budget: 6000,
                               harness: nil, indexTitleWidth: 4)
        }
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

    // Emission is not usage: a pack read must leave the vault byte-identical.
    func testContextIsAPureReadAndNeverFeedsTheScore() throws {
        _ = try propose(json: try recordJSON(key: "global/counted"))
        _ = try memory.promote(vault: vault, key: "global/counted", operatorApproved: true, ifHash: nil)
        let url = try memory.recordURL(vault: vault, key: "global/counted")
        let before = try Data(contentsOf: url)

        let first = try memory.context(
            vault: vault, scope: "global", project: nil, budget: 6000, harness: nil, now: fixedNow
        )
        XCTAssertEqual(first.emitted, 1)
        XCTAssertFalse(first.countersUpdated, "context must not report a counter update")

        // 100 runs change nothing: same pack bytes, same record bytes.
        var last = first.pack
        for _ in 0..<99 {
            let again = try memory.context(
                vault: vault, scope: "global", project: nil, budget: 6000, harness: nil, now: fixedNow
            )
            XCTAssertEqual(again.pack, last)
            last = again.pack
        }
        XCTAssertEqual(try Data(contentsOf: url), before, "context rewrote a record file")

        let record = try memory.loadRecord(vault: vault, key: "global/counted")
        XCTAssertEqual(record.recalled, 0)
        XCTAssertEqual(record.cited, 0)
        XCTAssertEqual(record.recallHits, 0)
        XCTAssertNil(record.lastUsed)
        XCTAssertEqual(try UndoHistory().entries(for: record.url.path).count, 2) // create + promote
    }

    // Legacy `recalled` counted emissions, so it must not create an unearned
    // rank advantage over a record nobody has used.
    func testLegacyEmissionCountersDoNotChangeRank() throws {
        let stale = try directRecord(
            key: "global/never-used", kind: "gotcha", recalled: 37_578, cited: 0,
            created: fixedNow, updated: fixedNow, lastUsed: fixedNow
        )
        let fresh = try directRecord(
            key: "global/used-today", kind: "gotcha", recalled: 0, cited: 3,
            created: fixedNow, updated: fixedNow, lastUsed: fixedNow
        )
        let records = [AgentMemory.parse(note: try MarkdownStore().load(stale)),
                       AgentMemory.parse(note: try MarkdownStore().load(fresh))]
        let ranked = AgentMemory.rankRecords(records, now: fixedNow)
        XCTAssertEqual(ranked.first?.record.key, "global/used-today", "\(ranked.map { ($0.record.key, $0.score) })")
        // The legacy value reads as zero use: both scores differ only by cited.
        XCTAssertEqual(ranked.map(\.score).max()! - ranked.map(\.score).min()!, 0.2, accuracy: 1e-9)
    }

    // Real use counts once per record per day, whatever the session volume,
    // and the two real-use signals share that one increment.
    func testRealUseCountsAtMostOncePerRecordPerDay() throws {
        _ = try propose(json: try recordJSON(key: "global/cited", title: "Deploy rule", body: "Run the deploy script."))
        _ = try memory.promote(vault: vault, key: "global/cited", operatorApproved: true, ifHash: nil)
        _ = try propose(json: try recordJSON(key: "global/recalled", title: "Deploy checklist", body: "Run the deploy script."))
        _ = try memory.promote(vault: vault, key: "global/recalled", operatorApproved: true, ifHash: nil)
        let morning = fixedNow
        let evening = fixedNow.addingTimeInterval(6 * 3_600)
        let tomorrow = fixedNow.addingTimeInterval(26 * 3_600)

        // Citations: three in one morning count once; a new day counts again.
        for _ in 0..<3 {
            _ = try memory.cite(vault: vault, key: "global/cited", now: morning)
        }
        var cited = try memory.loadRecord(vault: vault, key: "global/cited")
        XCTAssertEqual(cited.cited, 1)
        XCTAssertEqual(cited.recallHits, 0)
        _ = try memory.cite(vault: vault, key: "global/cited", now: evening)
        cited = try memory.loadRecord(vault: vault, key: "global/cited")
        XCTAssertEqual(cited.cited, 1, "a second use on the same day must not count")
        _ = try memory.cite(vault: vault, key: "global/cited", now: tomorrow)
        cited = try memory.loadRecord(vault: vault, key: "global/cited")
        XCTAssertEqual(cited.cited, 2)

        // Recall hits: the same one-per-day cap.
        for _ in 0..<3 {
            _ = try memory.recall(vault: vault, query: "deploy", budget: 4000, includeProposed: false, now: morning)
        }
        var recalled = try memory.loadRecord(vault: vault, key: "global/recalled")
        XCTAssertEqual(recalled.recallHits, 1)
        XCTAssertEqual(recalled.cited, 0)
        _ = try memory.recall(vault: vault, query: "deploy", budget: 4000, includeProposed: false, now: evening)
        recalled = try memory.loadRecord(vault: vault, key: "global/recalled")
        XCTAssertEqual(recalled.recallHits, 1)
        _ = try memory.recall(vault: vault, query: "deploy", budget: 4000, includeProposed: false, now: tomorrow)
        recalled = try memory.loadRecord(vault: vault, key: "global/recalled")
        XCTAssertEqual(recalled.recallHits, 2)

        // A day's first real use is the one that counts, whichever it is: the
        // recalls above also hit the cited record once per day, so a citation
        // on a day it was already recalled adds nothing.
        var used = try memory.loadRecord(vault: vault, key: "global/cited")
        XCTAssertEqual(used.recallHits, 2) // day 22 (the recalls above) and day 23 (below)
        let citedBefore = used.cited
        _ = try memory.cite(vault: vault, key: "global/cited", now: tomorrow)
        used = try memory.loadRecord(vault: vault, key: "global/cited")
        XCTAssertEqual(used.cited, citedBefore)

        // Telemetry still leaves no undo entries.
        XCTAssertEqual(try UndoHistory().entries(for: used.url.path).count, 2)
        XCTAssertEqual(try UndoHistory().entries(for: recalled.url.path).count, 2)
    }

    // MARK: - verified_by / confirmation

    func testProposeAcceptsVerificationFields() throws {
        _ = try propose(json: try recordJSON(
            key: "global/verified",
            verifiedBy: "swift test (177 tests) on 2026-11-09",
            confirmation: "confirmed"
        ))
        var record = try memory.loadRecord(vault: vault, key: "global/verified")
        XCTAssertEqual(record.verifiedBy, "swift test (177 tests) on 2026-11-09")
        XCTAssertEqual(record.confirmation, "confirmed")
        // Frontmatter round-trips: the fields survive a re-read of the file.
        let reloaded = AgentMemory.parse(note: try MarkdownStore().load(record.url))
        XCTAssertEqual(reloaded, record)

        // The flags work too, and an older record stays valid without them.
        _ = try propose(json: try recordJSON(key: "global/flags"), verifiedBy: "operator:2026-11-09", confirmation: "unconfirmed")
        record = try memory.loadRecord(vault: vault, key: "global/flags")
        XCTAssertEqual(record.verifiedBy, "operator:2026-11-09")
        XCTAssertEqual(record.confirmation, "unconfirmed")
        _ = try propose(json: try recordJSON(key: "global/legacy"))
        let legacy = try memory.loadRecord(vault: vault, key: "global/legacy")
        XCTAssertNil(legacy.verifiedBy)
        XCTAssertNil(legacy.confirmation)
        let text = try String(contentsOf: legacy.url, encoding: .utf8)
        XCTAssertFalse(text.contains("verified_by:"))
        XCTAssertFalse(text.contains("confirmation:"))
    }

    func testVerificationFieldsAreValidated() throws {
        expectReason("bad-confirmation") {
            _ = try propose(json: try recordJSON(key: "global/bad-conf", confirmation: "probably"))
        }
        expectReason("missing-field:verified_by") {
            _ = try propose(json: try recordJSON(key: "global/conf-only", confirmation: "confirmed"))
        }
        expectReason("too-long:verified_by") {
            _ = try propose(json: try recordJSON(key: "global/long-verified", verifiedBy: String(repeating: "a", count: 201)))
        }
        expectReason("bad-verified_by") {
            _ = try propose(json: try recordJSON(key: "global/multiline-verified", verifiedBy: "line one\nline two"))
        }
        expectReason("speculation") {
            _ = try propose(json: try recordJSON(key: "global/maybe-verified", verifiedBy: "maybe the tests passed"))
        }
        expectReason("secret:bearer-token") {
            _ = try propose(json: try recordJSON(
                key: "global/secret-verified",
                verifiedBy: "curl -H 'Authorization: Bearer \(String(repeating: "a", count: 40))'"
            ))
        }
    }

    func testEditInheritsVerificationFields() throws {
        _ = try propose(json: try recordJSON(key: "global/inherit", verifiedBy: "swift build", confirmation: "confirmed"))
        _ = try memory.promote(vault: vault, key: "global/inherit", operatorApproved: true, ifHash: nil)
        let successor = try propose("edit", key: "global/inherit", json: try recordJSON(key: "global/inherit", title: "Edited rule"))
        let edited = try memory.loadRecord(vault: vault, key: successor.key)
        XCTAssertEqual(edited.verifiedBy, "swift build")
        XCTAssertEqual(edited.confirmation, "confirmed")

        // An explicit value wins over the inherited one.
        let second = try propose("edit", key: successor.key, json: try recordJSON(key: successor.key, title: "Edited again"),
                                 verification: ("npm test", "unconfirmed"))
        let twice = try memory.loadRecord(vault: vault, key: second.key)
        XCTAssertEqual(twice.verifiedBy, "npm test")
        XCTAssertEqual(twice.confirmation, "unconfirmed")
    }

    func testShowAndRecallSurfaceVerificationFields() throws {
        _ = try propose(json: try recordJSON(
            key: "global/shown", title: "Deploy with the script", body: "Run the deploy script.",
            verifiedBy: "operator:2026-11-09", confirmation: "confirmed"
        ))
        _ = try memory.promote(vault: vault, key: "global/shown", operatorApproved: true, ifHash: nil)

        let view = try memory.show(vault: vault, key: "global/shown")
        XCTAssertEqual(view.verifiedBy, "operator:2026-11-09")
        XCTAssertEqual(view.confirmation, "confirmed")
        XCTAssertEqual(view.key, "global/shown")
        XCTAssertEqual(view.body, "Run the deploy script.")
        expectReason("not-found") {
            _ = try memory.show(vault: vault, key: "global/absent")
        }

        let recalled = try memory.recall(vault: vault, query: "deploy", budget: 4000, includeProposed: false, now: fixedNow)
        XCTAssertEqual(recalled.records.count, 1)
        XCTAssertEqual(recalled.records.first?.verifiedBy, "operator:2026-11-09")
        XCTAssertEqual(recalled.records.first?.confirmation, "confirmed")
    }

    func testDoctorWarnsButDoesNotFailOnMissingVerificationFields() throws {
        _ = try propose(json: try recordJSON(key: "global/unverified"))
        _ = try memory.promote(vault: vault, key: "global/unverified", operatorApproved: true, ifHash: nil)
        var report = try memory.doctor(vault: vault)
        XCTAssertTrue(report.ok, "missing optional fields must not fail doctor: \(report.issues)")
        XCTAssertEqual(report.issues, [])
        XCTAssertEqual(report.warnings.count, 2)
        XCTAssertTrue(report.warnings[0].contains("no verified_by"), "\(report.warnings)")
        XCTAssertTrue(report.warnings[1].contains("no confirmation"), "\(report.warnings)")

        // Filled in, the warnings disappear.
        _ = try propose("edit", key: "global/unverified",
                        json: try recordJSON(key: "global/unverified"),
                        verification: ("swift test", "confirmed"))
        // Promoting the successor retires the unverified one it supersedes.
        _ = try memory.promote(vault: vault, key: "global/unverified-v2", operatorApproved: true, ifHash: nil)
        report = try memory.doctor(vault: vault)
        // The retired record still lacks them, so the aggregate counts drop
        // from 1 of 1 to 1 of 2 — a warning either way, never a failure.
        XCTAssertTrue(report.ok)
        XCTAssertEqual(report.warnings.count, 2)
        XCTAssertTrue(report.warnings[0].contains("1 of 2 records have no verified_by"), "\(report.warnings)")
        XCTAssertTrue(report.warnings[1].contains("1 of 2 records have no confirmation"), "\(report.warnings)")
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
        _ = try propose(json: try recordJSON(key: "global/ready", title: "Ready correction"), now: fixedNow)
        _ = try propose("upvote", key: "global/ready", evidence: ["pi:2026-09-26-s2#1", "operator:2026-09-27"], now: fixedNow)
        // support 2 but no operator evidence
        _ = try propose(json: try recordJSON(key: "global/no-operator", kind: "correction", title: "No operator"), now: fixedNow)
        _ = try propose("upvote", key: "global/no-operator", evidence: ["pi:2026-09-26-s2#1"], now: fixedNow)
        // operator evidence but wrong kind
        _ = try propose(json: try recordJSON(key: "global/wrong-kind", kind: "gotcha", title: "Wrong kind"), now: fixedNow)
        _ = try propose("upvote", key: "global/wrong-kind", evidence: ["operator:2026-09-26"], now: fixedNow)
        // operator-flavoured (#user) but a single distinct session
        _ = try propose(json: try recordJSON(
            key: "global/one-session",
            title: "One session",
            evidence: ["claude:session-a#user-1"]
        ), now: fixedNow)
        _ = try propose("upvote", key: "global/one-session", evidence: ["claude:session-a#user-2"], now: fixedNow)

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
        XCTAssertEqual(record.recallHits, 0)
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
            recalled: 0, cited: 0, recallHits: 0, lastUsed: nil, recurrences: 0,
            retireProposed: nil, verifiedBy: nil, confirmation: nil, contentHash: ""
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
