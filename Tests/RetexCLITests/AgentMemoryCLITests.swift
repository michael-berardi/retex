import XCTest

/// End-to-end agent-memory tests that run the built `retex` binary against a
/// temporary memory vault (always via $AGENT_MEMORY_VAULT — nothing outside
/// $TMPDIR is ever touched).
final class AgentMemoryCLITests: XCTestCase {
    private static var repoRoot: URL {
        let file = URL(fileURLWithPath: #filePath)
        return file.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static let binPath: URL = {
        // The test bundle sits in the same products directory as the retex
        // binary. Asking `swift build --show-bin-path` from inside `swift test`
        // waits on the build lock that `swift test` holds and never returns.
        let products = Bundle(for: BundleLocator.self).bundleURL.deletingLastPathComponent()
        if let override = ProcessInfo.processInfo.environment["RETEX_TEST_BIN_DIR"] {
            return URL(fileURLWithPath: override)
        }
        precondition(
            FileManager.default.isExecutableFile(atPath: products.appendingPathComponent("retex").path),
            "retex binary not found next to the test bundle in \(products.path); set RETEX_TEST_BIN_DIR"
        )
        return products
    }()

    private var vaultDir: URL!
    private var scratchDir: URL!

    override func setUpWithError() throws {
        vaultDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-memory-cli-\(UUID().uuidString)", isDirectory: true)
        scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-memory-scratch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: vaultDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: vaultDir)
        try? FileManager.default.removeItem(at: scratchDir)
    }

    @discardableResult
    private func run(_ arguments: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        let stdout = Pipe(), stderr = Pipe()
        process.executableURL = Self.binPath.appendingPathComponent("retex")
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["AGENT_MEMORY_VAULT": vaultDir.path]
        ) { _, new in new }
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: outData, as: UTF8.self),
            String(decoding: errData, as: UTF8.self)
        )
    }

    private func recordFile(
        key: String,
        title: String,
        body: String,
        kind: String = "correction"
    ) throws -> String {
        let path = scratchDir.appendingPathComponent("\(key.replacingOccurrences(of: "/", with: "-")).json").path
        let object: [String: Any] = [
            "key": key,
            "kind": kind,
            "title": title,
            "body": body,
            "evidence": ["pi:2026-09-25-cli#1"],
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    private func propose(_ key: String, title: String, body: String, kind: String = "correction") throws {
        let file = try recordFile(key: key, title: title, body: body, kind: kind)
        let result = try run([
            "memory", "propose", "--op", "add", "--json-file", file,
            "--evidence", "operator:2026-09-25", "--lean",
        ])
        XCTAssertEqual(result.status, 0, "propose failed: \(result.stderr)")
    }

    // MARK: - Init, context budgets, plain output

    func testInitIsIdempotentAndContextHonorsBudget() throws {
        // Plain (non-machine) output so the human message is assertable.
        var result = try run(["memory", "init"])
        XCTAssertEqual(result.status, 0, result.stderr)
        result = try run(["memory", "init"])
        XCTAssertEqual(result.status, 0, "second init must be idempotent: \(result.stderr)")
        XCTAssertTrue(result.stdout.contains("Initialized agent memory vault"))

        try propose("global/deploy-lds", title: "Deploy LDS with npm run deploy", body: "Run npm run deploy from the repo root. Never Vercel.", kind: "decision")
        try propose("global/vercel-ban", title: "Never deploy LDS to Vercel", body: "Vercel builds break the asset pipeline. Always npm run deploy.", kind: "gotcha")
        try propose("project-lds/preview", title: "Preview URLs need the tunnel", body: "Preview deploys need the local tunnel running. Start it first.", kind: "procedure")

        var promotion = try run(["memory", "promote", "global/deploy-lds", "--operator-approved", "--lean"])
        XCTAssertEqual(promotion.status, 0, promotion.stderr)
        promotion = try run(["memory", "promote", "global/vercel-ban", "--operator-approved", "--lean"])
        XCTAssertEqual(promotion.status, 0, promotion.stderr)
        promotion = try run(["memory", "promote", "project-lds/preview", "--operator-approved", "--lean"])
        XCTAssertEqual(promotion.status, 0, promotion.stderr)

        // Proposed records never reach the pack; active records do.
        try propose("global/unreviewed", title: "Unreviewed claim", body: "Proposed only.")

        for budget in [500, 1200, 6000] {
            let context = try run(["memory", "context", "--budget", "\(budget)"])
            XCTAssertEqual(context.status, 0, context.stderr)
            let printed = context.stdout
            // print() appends one newline on top of the pack's trailing one.
            XCTAssertLessThanOrEqual(
                printed.utf8.count - 1, budget,
                "pack exceeded budget \(budget): \(printed.utf8.count) bytes: \(printed)"
            )
            XCTAssertTrue(printed.contains("## Agent memory ("))
        }

        let withProject = try run(["memory", "context", "--project", "lds", "--raw-json"])
        XCTAssertEqual(withProject.status, 0, withProject.stderr)
        XCTAssertTrue(withProject.stdout.contains("project-lds/preview"))

        // Above the hard ceiling the CLI errors out.
        let tooBig = try run(["memory", "context", "--budget", "8001"])
        XCTAssertNotEqual(tooBig.status, 0)
        XCTAssertTrue(tooBig.stderr.contains("8000"), tooBig.stderr)
    }

    // MARK: - Undo byte-exact round trip through the CLI

    func testUndoRoundTripThroughCLIRestoresOriginalBytes() throws {
        try propose("global/undo-cli", title: "Undo me via CLI", body: "Original body. Keep it byte-exact.")
        let url = vaultDir.appendingPathComponent("Memory/global/undo-cli.md")
        let original = try Data(contentsOf: url)

        var result = try run(["memory", "promote", "global/undo-cli", "--operator-approved", "--lean"])
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertNotEqual(try Data(contentsOf: url), original)

        // First undo reverts the promote; second undo reverts the proposal
        // creation. Both must restore the original bytes exactly.
        result = try run(["undo", url.path])
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(try Data(contentsOf: url), original)

        result = try run(["undo", url.path])
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(try Data(contentsOf: url), original)

        // No history left.
        result = try run(["undo", url.path])
        XCTAssertNotEqual(result.status, 0)
    }

    // MARK: - Recall with proposals

    func testRecallLabelsProposedRecords() throws {
        try propose("global/recall-target", title: "Zebra deploy notes", body: "Zebra deploys run through the npm script.")
        _ = try run(["memory", "promote", "global/recall-target", "--operator-approved", "--lean"])
        try propose("global/recall-pending", title: "Zebra preview rules", body: "Zebra previews need DNS warmup first.")

        let active = try run(["memory", "recall", "zebra", "--lean"])
        XCTAssertEqual(active.status, 0, active.stderr)
        XCTAssertTrue(active.stdout.contains("recall-target"))
        XCTAssertFalse(active.stdout.contains("recall-pending"))

        let withProposed = try run(["memory", "recall", "zebra", "--include-proposed", "--lean"])
        XCTAssertEqual(withProposed.status, 0, withProposed.stderr)
        XCTAssertTrue(withProposed.stdout.contains("[proposed] "), withProposed.stdout)
    }

    // MARK: - Doctor exit code

    func testShowAndDoctorWarningsSurfaceVerificationFields() throws {
        XCTAssertEqual(try run(["memory", "init", "--lean"]).status, 0)
        let file = try recordFile(key: "global/verified-rule", title: "Run the deploy script", body: "Run the deploy script.")
        let proposed = try run([
            "memory", "propose", "--op", "add", "--json-file", file,
            "--evidence", "operator:2026-09-25",
            "--verified-by", "operator run on 2026-09-25", "--confirmation", "confirmed", "--lean",
        ])
        XCTAssertEqual(proposed.status, 0, proposed.stderr)

        let show = try run(["memory", "show", "global/verified-rule"])
        XCTAssertEqual(show.status, 0, show.stderr)
        XCTAssertTrue(show.stdout.contains("verified by operator run on 2026-09-25 (confirmed)"), show.stdout)
        XCTAssertTrue(show.stdout.contains("Run the deploy script."), show.stdout)

        let json = try run(["memory", "show", "global/verified-rule", "--json"])
        XCTAssertTrue(json.stdout.contains("\"confirmation\":\"confirmed\""), json.stdout)

        // Missing optional fields are warnings, never a failure.
        let plain = try recordFile(key: "global/plain-rule", title: "Plain rule", body: "Do the plain thing.")
        XCTAssertEqual(try run(["memory", "propose", "--op", "add", "--json-file", plain, "--lean"]).status, 0)
        let doctor = try run(["memory", "doctor"])
        XCTAssertEqual(doctor.status, 0, doctor.stdout + doctor.stderr)
        XCTAssertTrue(doctor.stdout.contains("no verified_by"), doctor.stdout)
        XCTAssertTrue(doctor.stdout.contains("Warnings (advisory, no failure)"), doctor.stdout)
    }

    func testDoctorExitsNonZeroOnBrokenVault() throws {
        try propose("global/healthy", title: "Healthy record", body: "Fine.")
        var result = try run(["memory", "doctor"])
        XCTAssertEqual(result.status, 0, result.stderr)

        // Corrupt a record: wrong type breaks validation.
        let broken = vaultDir.appendingPathComponent("Memory/global/broken.md")
        try "---\ntype: note\nkey: global/broken\n---\n\nNot a memory record.\n"
            .write(to: broken, atomically: true, encoding: .utf8)
        result = try run(["memory", "doctor"])
        XCTAssertNotEqual(result.status, 0, "doctor must exit non-zero on a broken vault")
        XCTAssertTrue(result.stdout.contains("Issues") || result.stdout.contains("issue"), result.stdout)
    }

    /// Minimal locked collector so concurrent workers can gather results.
    private final class ResultBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [T] = []
        func append(_ item: T) {
            lock.lock()
            defer { lock.unlock() }
            items.append(item)
        }
        var all: [T] {
            lock.lock()
            defer { lock.unlock() }
            return items
        }
    }

    // MARK: - Concurrency: 8 processes x 20 proposes

    func testConcurrentProposesLoseNoWritesAndStayConsistent() throws {
        let keys = (0..<160).map { index in
            String(format: "global/conc-%03d", index)
        }
        // Pre-write the 160 record payloads, then run 8 concurrent workers
        // that each propose 20 records through the built CLI binary.
        let payloadPaths = ResultBox<(Int, String)>()
        DispatchQueue.concurrentPerform(iterations: keys.count) { index in
            let key = keys[index]
            let object: [String: Any] = [
                "key": key,
                "kind": index.isMultiple(of: 2) ? "gotcha" : "preference",
                "title": "Concurrent record \(index)",
                "body": "Written concurrently by worker \(index % 8).",
                "evidence": ["pi:2026-09-25-worker\(index % 8)#\(index)"],
            ]
            let path = scratchDir.appendingPathComponent("payload-\(index).json").path
            let data = try! JSONSerialization.data(withJSONObject: object)
            try! data.write(to: URL(fileURLWithPath: path))
            payloadPaths.append((index, path))
        }
        let payloadByIndex = Dictionary(payloadPaths.all.map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(payloadByIndex.count, 160)

        let bin = Self.binPath.appendingPathComponent("retex").path
        let environment = ProcessInfo.processInfo.environment.merging(
            ["AGENT_MEMORY_VAULT": vaultDir.path]
        ) { _, new in new }
        let failures = ResultBox<String>()
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for index in stride(from: worker, to: keys.count, by: 8) {
                let process = Process()
                let stderr = Pipe()
                process.executableURL = URL(fileURLWithPath: bin)
                process.arguments = [
                    "memory", "propose", "--op", "add",
                    "--json-file", payloadByIndex[index]!, "--lean",
                ]
                process.environment = environment
                process.standardOutput = Pipe()
                process.standardError = stderr
                do {
                    try process.run()
                } catch {
                    failures.append("\(keys[index]): spawn failed \(error)")
                    continue
                }
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    failures.append("\(keys[index]): exit \(process.terminationStatus) \(message)")
                }
            }
        }
        XCTAssertEqual(failures.all, [], "some proposes failed")

        // Every write landed (16 workers-worth of files under Memory/).
        let memoryRoot = vaultDir.appendingPathComponent("Memory", isDirectory: true)
        let enumerator = FileManager.default.enumerator(at: memoryRoot, includingPropertiesForKeys: nil)
        let written = enumerator?.allObjects.compactMap { ($0 as? URL)?.path }
            .filter { $0.hasSuffix(".md") } ?? []
        XCTAssertEqual(written.count, 160, "expected 160 records, found \(written.count)")

        // The vault stays consistent: keys unique, modes private, journal sane.
        let doctor = try run(["memory", "doctor"])
        XCTAssertEqual(doctor.status, 0, "doctor reported issues: \(doctor.stdout)\(doctor.stderr)")
        XCTAssertTrue(doctor.stdout.contains("Agent memory records: 160"), doctor.stdout)
    }
}
