#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

/// Canonical agent memory (design: `agent-memory-and-dream.md` §3–§5).
///
/// One store, one protocol. Memory lives in a dedicated Retex vault of typed
/// `memory` records (`Memory/<scope-dir>/<slug>.md`). Every harness reads it
/// the same way — a budgeted session pack (`context`) plus on-demand `recall`
/// — and writes it the same way (`propose`, validated, locked, journaled,
/// undoable). No harness edits memory files directly: promotion, rejection,
/// retirement and staleness are operator actions gated behind
/// `--operator-approved`.
///
/// Safety invariants (design §5):
/// - every mutation takes the vault-level journal lock, writes atomically,
///   honours `--if-hash` compare-and-set, and is recorded in the undo journal
///   so `retex undo <path>` restores the record byte for byte;
/// - `context` counter bumps and `cite` are telemetry: they use a
///   non-blocking try-lock (a busy lock skips the update and reports it) and
///   never create undo entries;
/// - the vault is private: directories 0700, files 0600.
public struct AgentMemory {
    /// Default session-pack budget in bytes (design §5).
    public static let defaultBudget = 6000
    /// Hard budget ceiling the CLI accepts (design §5).
    public static let maxBudget = 8000
    /// Default on-demand recall budget in bytes (design §5).
    public static let defaultRecallBudget = 4000

    private let store: MarkdownStore
    private let history = UndoHistory()

    public init(store: MarkdownStore = MarkdownStore()) {
        self.store = store
    }

    // MARK: - Vocabulary

    public enum Kind: String, CaseIterable, Sendable {
        case correction, gotcha, decision, procedure, preference

        /// Pack ranking weight (design §5): correction > gotcha > decision >
        /// procedure > preference.
        public var weight: Double {
            switch self {
            case .correction: 1
            case .gotcha: 0.8
            case .decision: 0.6
            case .procedure: 0.5
            case .preference: 0.4
            }
        }
    }

    public enum Status: String, CaseIterable, Sendable {
        case proposed, active, stale, retired, rejected
    }

    public enum Certainty: String, CaseIterable, Sendable {
        case observed, inferred, reported
    }

    /// Locator schemes accepted for `evidence` entries (design §4).
    static let evidenceSchemes = ["pi", "claude", "git", "agents-md", "operator", "usap", "note"]

    // MARK: - Errors

    /// Every rejection carries a stable reason code (design §4): a rejection
    /// is an error, never a silent drop.
    public enum MemoryError: LocalizedError, Sendable {
        case notInitialized(String)
        case validation(code: String, message: String)
        case notAuthorized(String)
        case invalidRecordJSON(String)

        public static func notFound(_ key: String) -> MemoryError {
            .validation(code: "not-found", message: "no memory record for key \(key)")
        }

        public static func hashMismatch(key: String, expected: String, actual: String) -> MemoryError {
            .validation(
                code: "hash-mismatch",
                message: "record \(key) changed since it was read: expected \(expected), found \(actual)"
            )
        }

        public var reasonCode: String {
            switch self {
            case .notInitialized: "not-initialized"
            case .validation(let code, _): code
            case .notAuthorized: "not-authorized"
            case .invalidRecordJSON: "invalid-record-json"
            }
        }

        public var errorDescription: String? {
            switch self {
            case .notInitialized(let message): message
            case .validation(let code, let message):
                "Agent memory validation failed (\(code)): \(message)"
            case .notAuthorized(let message):
                "\(message) (reason: not-authorized)"
            case .invalidRecordJSON(let message):
                "Invalid memory record JSON: \(message)"
            }
        }
    }

    private static func validation(_ code: String, _ message: String) -> MemoryError {
        .validation(code: code, message: message)
    }

    // MARK: - Vault resolution (design §3)

    /// `--vault P`, else `$AGENT_MEMORY_VAULT`, else `~/.local/share/agent-memory`.
    public static func resolveVaultURL(
        explicit: String?,
        environment: [String: String],
        homeDirectory: String
    ) -> URL {
        func expanded(_ path: String) -> URL {
            URL(
                fileURLWithPath: NSString(string: path).expandingTildeInPath,
                isDirectory: true
            ).standardizedFileURL
        }
        if let explicit, !explicit.isEmpty { return expanded(explicit) }
        if let fromEnvironment = environment["AGENT_MEMORY_VAULT"], !fromEnvironment.isEmpty {
            return expanded(fromEnvironment)
        }
        return URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent(".local/share/agent-memory", isDirectory: true)
    }

    /// Resolves and validates the memory vault. The vault is created by
    /// `memory init` only — never implicitly — so any other command on a
    /// missing vault fails with `agent memory vault not initialized`.
    public func vault(explicit: String?, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Vault {
        let url = Self.resolveVaultURL(
            explicit: explicit,
            environment: environment,
            homeDirectory: NSHomeDirectory()
        )
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw MemoryError.notInitialized("agent memory vault not initialized")
        }
        return Vault(url: url)
    }

    /// Creates the private vault layout and runs the existing Retex init
    /// (`UndoHistory.prepare`). Idempotent: an existing vault is left intact
    /// and only re-confirmed private.
    @discardableResult
    public func initialize(at url: URL) throws -> (vault: Vault, memoryDirectory: URL) {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        let memoryDirectory = url.appendingPathComponent("Memory", isDirectory: true)
        try fileManager.createDirectory(at: memoryDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: memoryDirectory.path)
        let vault = Vault(url: url)
        _ = try UndoHistory.prepare(for: vault)
        return (vault, memoryDirectory)
    }

    // MARK: - Keys and paths (design §4)

    /// Key shape: `^[a-z0-9][a-z0-9-]*(/[a-z0-9][a-z0-9-]*)+$`, ≤ 96 chars.
    public static func isValidKeyShape(_ key: String) -> Bool {
        let segments = key.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { return false }
        for segment in segments {
            var iterator = segment.makeIterator()
            guard let first = iterator.next(), Self.isKeyCharacter(first, first: true) else { return false }
            while let next = iterator.next() {
                guard Self.isKeyCharacter(next, first: false) else { return false }
            }
        }
        return true
    }

    private static func isKeyCharacter(_ scalar: Character, first: Bool) -> Bool {
        guard scalar.isASCII else { return false }
        if scalar.isNumber { return true }
        return ("a"..."z").contains(scalar) || (!first && scalar == "-")
    }

    /// The scope directory in a key: `global` or `project-<name>`. Returns the
    /// directory name and the frontmatter scope (`global` | `project:<name>`).
    public static func scopeKey(from key: String) -> (directory: String, scope: String)? {
        guard let slash = key.firstIndex(of: "/") else { return nil }
        let directory = String(key[..<slash])
        if directory == "global" { return (directory, "global") }
        if directory.hasPrefix("project-") {
            return (directory, "project:" + String(directory.dropFirst("project-".count)))
        }
        return nil
    }

    /// `Memory/<scope-dir>/<slug>.md` for a validated key.
    public func recordURL(vault: Vault, key: String) throws -> URL {
        guard !key.isEmpty else {
            throw Self.validation("missing-field:key", "key is required")
        }
        guard key.utf8.count <= 96 else {
            throw Self.validation("too-long:key", "key exceeds 96 characters")
        }
        guard Self.isValidKeyShape(key) else {
            throw Self.validation("bad-key", "key must match ^[a-z0-9][a-z0-9-]*(/[a-z0-9][a-z0-9-]*)+$")
        }
        guard let scope = Self.scopeKey(from: key) else {
            throw Self.validation("bad-scope", "key scope must be global or project-<name>")
        }
        let slug = key.split(separator: "/", maxSplits: 1).last.map(String.init) ?? ""
        return vault.url
            .appendingPathComponent("Memory", isDirectory: true)
            .appendingPathComponent(scope.directory, isDirectory: true)
            .appendingPathComponent(slug)
            .appendingPathExtension("md")
    }

    private func existingURL(vault: Vault, key: String) throws -> URL {
        let url = try recordURL(vault: vault, key: key)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MemoryError.notFound(key)
        }
        return url
    }

    // MARK: - Records

    /// One typed `memory` record (design §4). All fields round-trip through
    /// the deterministic frontmatter serializer; `confidence` is kept as its
    /// canonical decimal text so reads and writes are byte-stable.
    public struct MemoryRecord: Sendable, Equatable {
        public var url: URL
        public var key: String
        public var kind: String
        public var scope: String
        public var title: String
        public var body: String
        public var appliesWhen: String?
        public var evidence: [String]
        public var support: Int
        public var confidence: String
        public var certainty: String
        public var sourceHarness: String
        public var status: String
        public var validFrom: String?
        public var validUntil: String?
        public var supersedes: String?
        public var supersededBy: [String]
        public var asOf: String
        public var created: String
        public var updated: String
        public var recalled: Int
        public var cited: Int
        public var lastUsed: String?
        public var recurrences: Int
        public var retireProposed: String?
        public var contentHash: String

        var scopeDirectory: String? { AgentMemory.scopeKey(from: key)?.directory }
    }

    /// Lenient parse of a memory note. Structural validation is a separate,
    /// strict step (`validate`) so `doctor` can report every defect instead
    /// of failing at the first one.
    public static func parse(note: Note) -> MemoryRecord {
        let metadata = note.metadata
        return MemoryRecord(
            url: note.url,
            key: metadata["key"] ?? "",
            kind: metadata["kind"] ?? "",
            scope: metadata["scope"] ?? "",
            title: metadata["title"] ?? "",
            body: note.body,
            appliesWhen: metadata["applies_when"],
            evidence: (metadata["evidence"] ?? "")
                .split(whereSeparator: \.isNewline)
                .map { MarkdownStore.trimmed($0, in: MarkdownStore.whitespaceCharacters) }
                .filter { !$0.isEmpty },
            support: Int(metadata["support"] ?? "") ?? 0,
            confidence: normalizedConfidence(metadata["confidence"]),
            certainty: metadata["certainty"] ?? "",
            sourceHarness: metadata["source_harness"] ?? "",
            status: metadata["status"] ?? "",
            validFrom: metadata["valid_from"],
            validUntil: metadata["valid_until"],
            supersedes: bareKey(metadata["supersedes"]),
            supersededBy: (metadata["superseded_by"] ?? "")
                .split(separator: ",")
                .compactMap { bareKey(String($0)) },
            asOf: metadata["as_of"] ?? "",
            created: metadata["created"] ?? "",
            updated: metadata["updated"] ?? "",
            recalled: Int(metadata["recalled"] ?? "") ?? 0,
            cited: Int(metadata["cited"] ?? "") ?? 0,
            lastUsed: metadata["last_used"],
            recurrences: Int(metadata["recurrences"] ?? "") ?? 0,
            retireProposed: metadata["retire_proposed"],
            contentHash: note.contentHash
        )
    }

    private static func normalizedConfidence(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        guard let value = Double(raw) else { return raw }
        return String(format: "%g", value)
    }

    /// `[[key]]` (with optional surrounding whitespace) -> `key`.
    private static func bareKey(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.hasPrefix("[["), value.hasSuffix("]]") {
            value = String(value.dropFirst(2).dropLast(2))
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func loadRecord(vault: Vault, key: String) throws -> MemoryRecord {
        let url = try existingURL(vault: vault, key: key)
        return Self.parse(note: try store.load(url))
    }

    /// Every memory record in the vault, sorted by key for determinism.
    public func scanRecords(vault: Vault) throws -> [MemoryRecord] {
        let memoryRoot = vault.url.standardizedFileURL
            .resolvingSymlinksInPath()
            .appendingPathComponent("Memory", isDirectory: true)
        guard FileManager.default.fileExists(atPath: memoryRoot.path) else { return [] }
        guard let enumerator = FileManager.default.enumerator(
            at: memoryRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var records: [MemoryRecord] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "md" {
            guard let note = try? store.load(url) else { continue }
            records.append(Self.parse(note: note))
        }
        return records.sorted { $0.key < $1.key }
    }

    /// Deterministic frontmatter + body for a record. Field order is fixed so
    /// identical records serialize to identical bytes.
    public func serialize(_ record: MemoryRecord) -> String {
        var lines: [String] = [
            "---",
            "type: memory",
            "key: \(Self.scalar(record.key))",
            "kind: \(Self.scalar(record.kind))",
            "scope: \(Self.scalar(record.scope))",
            "status: \(Self.scalar(record.status))",
            "title: \(Self.scalar(record.title))",
            "confidence: \(Self.scalar(record.confidence))",
            "certainty: \(Self.scalar(record.certainty))",
            "support: \(record.support)",
            "source_harness: \(Self.scalar(record.sourceHarness))",
        ]
        lines.append("evidence: |")
        lines.append(contentsOf: record.evidence.map { "  \($0)" })
        if let appliesWhen = record.appliesWhen, !appliesWhen.isEmpty {
            lines.append("applies_when: \(Self.scalar(appliesWhen))")
        }
        if let supersedes = record.supersedes {
            lines.append("supersedes: [[\(supersedes)]]")
        }
        if !record.supersededBy.isEmpty {
            lines.append(
                "superseded_by: "
                    + record.supersededBy.map { "[[\($0)]]" }.joined(separator: ", ")
            )
        }
        if let validFrom = record.validFrom, !validFrom.isEmpty { lines.append("valid_from: \(validFrom)") }
        if let validUntil = record.validUntil, !validUntil.isEmpty { lines.append("valid_until: \(validUntil)") }
        lines.append("as_of: \(record.asOf)")
        lines.append("created: \(record.created)")
        lines.append("updated: \(record.updated)")
        lines.append("recalled: \(record.recalled)")
        lines.append("cited: \(record.cited)")
        if let lastUsed = record.lastUsed, !lastUsed.isEmpty { lines.append("last_used: \(lastUsed)") }
        lines.append("recurrences: \(record.recurrences)")
        if let retireProposed = record.retireProposed, !retireProposed.isEmpty {
            lines.append("retire_proposed: \(Self.scalar(retireProposed))")
        }
        lines.append("---")
        lines.append("")
        lines.append(record.body)
        return lines.joined(separator: "\n") + "\n"
    }

    /// Same quoting contract as the store's scalar serializer: plain YAML
    /// when unambiguous, double-quoted otherwise.
    static func scalar(_ value: String) -> String {
        if value.hasPrefix("["), value.hasSuffix("]") { return value }
        let needsQuotes = value.contains(where: { ":#{}[]\n\t\"".contains($0) })
            || value.first.map { "-?,'&*!|>%@`".contains($0) || $0.isWhitespace } == true
            || value.last?.isWhitespace == true
        guard needsQuotes else { return value }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    // MARK: - Validation (design §4)

    /// Raw fields awaiting validation (CLI flags merged with record JSON).
    public struct RecordInput: Sendable {
        public var key: String?
        public var kind: String?
        public var title: String?
        public var body: String?
        public var appliesWhen: String?
        public var evidence: [String]
        public var confidence: String?
        public var certainty: String?
        public var scope: String?
        public var sourceHarness: String?

        public init(
            key: String? = nil,
            kind: String? = nil,
            title: String? = nil,
            body: String? = nil,
            appliesWhen: String? = nil,
            evidence: [String] = [],
            confidence: String? = nil,
            certainty: String? = nil,
            scope: String? = nil,
            sourceHarness: String? = nil
        ) {
            self.key = key
            self.kind = kind
            self.title = title
            self.body = body
            self.appliesWhen = appliesWhen
            self.evidence = evidence
            self.confidence = confidence
            self.certainty = certainty
            self.scope = scope
            self.sourceHarness = sourceHarness
        }
    }

    /// Parses a `--json`/`--json-file` record payload into an input.
    public static func parseRecordJSON(_ data: Data) throws -> RecordInput {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw MemoryError.invalidRecordJSON("payload is not valid JSON (\(error.localizedDescription))")
        }
        guard let dictionary = object as? [String: Any] else {
            throw MemoryError.invalidRecordJSON("payload must be a JSON object")
        }
        func string(_ field: String) throws -> String? {
            guard let raw = dictionary[field] else { return nil }
            guard let value = raw as? String else {
                throw MemoryError.invalidRecordJSON("field \(field) must be a string")
            }
            return value
        }
        /// Numeric fields accept a JSON number (what every JSON client sends)
        /// or its string form; booleans are never numbers here.
        func numberOrString(_ field: String) throws -> String? {
            guard let raw = dictionary[field] else { return nil }
            if let value = raw as? String { return value }
            if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                return number.stringValue
            }
            throw MemoryError.invalidRecordJSON("field \(field) must be a number")
        }
        var evidence: [String] = []
        if let rawEvidence = dictionary["evidence"] {
            guard let list = rawEvidence as? [Any], !list.isEmpty else {
                throw MemoryError.invalidRecordJSON("field evidence must be a non-empty array of strings")
            }
            for item in list {
                guard let locator = item as? String else {
                    throw MemoryError.invalidRecordJSON("field evidence must contain only strings")
                }
                evidence.append(locator)
            }
        }
        return RecordInput(
            key: try string("key"),
            kind: try string("kind"),
            title: try string("title"),
            body: try string("body"),
            appliesWhen: try string("applies_when"),
            evidence: evidence,
            confidence: try numberOrString("confidence"),
            certainty: try string("certainty"),
            scope: try string("scope"),
            sourceHarness: try string("source_harness")
        )
    }

    /// Strict validation with stable reason codes. Check order is fixed so
    /// identical inputs always produce identical reason codes.
    public static func validate(_ input: RecordInput) throws {
        guard let key = input.key, !key.isEmpty else {
            throw validation("missing-field:key", "key is required")
        }
        guard key.utf8.count <= 96 else {
            throw validation("too-long:key", "key exceeds 96 characters")
        }
        guard isValidKeyShape(key) else {
            throw validation("bad-key", "key must match ^[a-z0-9][a-z0-9-]*(/[a-z0-9][a-z0-9-]*)+$")
        }
        guard let derivedScope = scopeKey(from: key) else {
            throw validation("bad-scope", "key scope must be global or project-<name>")
        }
        if let scope = input.scope, !scope.isEmpty, scope != derivedScope.scope {
            throw validation(
                "bad-scope",
                "scope \(scope) does not match key \(key) (expected \(derivedScope.scope))"
            )
        }

        guard let kind = input.kind, !kind.isEmpty else {
            throw validation("missing-field:kind", "kind is required")
        }
        guard Kind(rawValue: kind) != nil else {
            throw validation(
                "bad-kind",
                "kind must be one of \(Kind.allCases.map(\.rawValue).joined(separator: ", "))"
            )
        }

        guard let title = input.title, !title.isEmpty else {
            throw validation("missing-field:title", "title is required")
        }
        guard title.count <= 120 else {
            throw validation("too-long:title", "title exceeds 120 characters")
        }
        guard !title.contains(where: \.isNewline) else {
            throw validation("bad-title", "title must be a single line")
        }

        guard let body = input.body, !body.isEmpty else {
            throw validation("missing-field:body", "body is required")
        }
        guard body.count <= 600 else {
            throw validation("too-long:body", "body exceeds 600 characters")
        }

        if let appliesWhen = input.appliesWhen, !appliesWhen.isEmpty {
            guard appliesWhen.count <= 160 else {
                throw validation("too-long:applies_when", "applies_when exceeds 160 characters")
            }
            guard !appliesWhen.contains(where: \.isNewline) else {
                throw validation("bad-applies_when", "applies_when must be a single line")
            }
        }

        guard !input.evidence.isEmpty else {
            throw validation("missing-field:evidence", "at least one evidence locator is required")
        }
        for locator in input.evidence where !isValidLocator(locator) {
            throw validation(
                "bad-evidence",
                "evidence locator \(locator) must match ^(pi|claude|git|agents-md|operator|usap|note):\\S+$"
            )
        }

        if let confidence = input.confidence, !confidence.isEmpty {
            guard let value = Double(confidence), (0...1).contains(value) else {
                throw validation("bad-confidence", "confidence must be a number from 0 through 1")
            }
        }
        if let certainty = input.certainty, !certainty.isEmpty {
            guard Certainty(rawValue: certainty) != nil else {
                throw validation(
                    "bad-certainty",
                    "certainty must be one of \(Certainty.allCases.map(\.rawValue).joined(separator: ", "))"
                )
            }
        }
        if let harness = input.sourceHarness, !harness.isEmpty {
            guard harness.count <= 40, !harness.contains(where: { $0.isWhitespace || $0.isNewline }) else {
                throw validation("bad-source_harness", "source_harness must be one token of at most 40 characters")
            }
        }

        // Statements never speculate (design §4) and never carry secrets.
        for (field, text) in [("title", title), ("body", body), ("applies_when", input.appliesWhen ?? "")] {
            guard !text.isEmpty else { continue }
            if containsSpeculation(text) {
                throw validation("speculation", "\(field) contains a speculation word")
            }
            if let pattern = findSecret(in: text) {
                throw validation("secret:\(pattern)", "\(field) matches secret pattern \(pattern)")
            }
        }
    }

    /// `^(pi|claude|git|agents-md|operator|usap|note):\S+$` (commas excluded
    /// so locators round-trip through the comma-joined frontmatter form).
    public static func isValidLocator(_ locator: String) -> Bool {
        guard let colon = locator.firstIndex(of: ":") else { return false }
        let scheme = String(locator[..<colon])
        guard evidenceSchemes.contains(scheme) else { return false }
        let value = locator[locator.index(after: colon)...]
        guard !value.isEmpty else { return false }
        return value.allSatisfy { !$0.isWhitespace && $0 != "," }
    }

    // MARK: - Secret scanner (ported from ultraterm-dream src/sanitize.js)

    /// Word-shaped `sk-…` lookalikes ("sk-learn-tutorial") are identifiers,
    /// not key material.
    private nonisolated(unsafe) static let skWordLike = try! NSRegularExpression(
        pattern: #"^sk-[a-z0-9]{1,10}(?:-[a-z0-9]{1,10})*$"#,
        options: [.caseInsensitive]
    )

    private nonisolated(unsafe) static let pathLike = try! NSRegularExpression(
        pattern: #"^(?:/[A-Za-z0-9._-]+)+/?$"#,
        options: []
    )

    /// (name, pattern, case-insensitive). Order is the detection priority.
    /// NSRegularExpression instances are immutable and thread-safe.
    private nonisolated(unsafe) static let secretPatterns: [(String, NSRegularExpression)] = [
        ("private-key", try! NSRegularExpression(pattern: #"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----"#)),
        ("aws-secret-access-key", try! NSRegularExpression(
            pattern: #"AWS_SECRET_ACCESS_KEY["']?\s*[=:]\s*["']?[^\s"',;`]+"#, options: [.caseInsensitive])),
        ("jwt", try! NSRegularExpression(pattern: #"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#)),
        ("bearer-token", try! NSRegularExpression(
            pattern: #"\b(?:Bearer|Basic)[ \t]+[A-Za-z0-9._~+/=-]{8,}"#, options: [.caseInsensitive])),
        ("anthropic-key", try! NSRegularExpression(
            pattern: #"\bsk-ant-[A-Za-z0-9_-]{8,}"#, options: [.caseInsensitive])),
        ("openai-key", try! NSRegularExpression(
            pattern: #"\bsk-[A-Za-z0-9_-]{16,}"#, options: [.caseInsensitive])),
        ("github-token", try! NSRegularExpression(pattern: #"\bgh[pousr]_[A-Za-z0-9]{16,}"#)),
        ("github-pat", try! NSRegularExpression(pattern: #"github_pat_[A-Za-z0-9_]{20,}"#)),
        ("gitlab-pat", try! NSRegularExpression(
            pattern: #"glpat-[A-Za-z0-9_-]{20,}"#, options: [.caseInsensitive])),
        ("stripe-key", try! NSRegularExpression(
            pattern: #"\b[sr]k_(?:live|test)_[A-Za-z0-9]{16,}"#, options: [.caseInsensitive])),
        ("slack-token", try! NSRegularExpression(
            pattern: #"\bxox[baprs]-[A-Za-z0-9-]{10,}"#, options: [.caseInsensitive])),
        ("slack-app-token", try! NSRegularExpression(
            pattern: #"\bxapp-[A-Za-z0-9-]{10,}"#, options: [.caseInsensitive])),
        ("aws-access-key", try! NSRegularExpression(
            pattern: #"\bAKIA[0-9A-Z]{16}\b"#, options: [.caseInsensitive])),
        ("google-api-key", try! NSRegularExpression(pattern: #"\bAIza[0-9A-Za-z_-]{30,}"#)),
        ("secret-assignment", try! NSRegularExpression(
            pattern: #"\b[A-Za-z0-9_-]{0,24}(?:password|passwd|secret|token|api[_-]?key|authorization|access[_-]?key|private[_-]?key|_key)["']?\s*[=:]\s*["']?(?:bearer[ \t]+|basic[ \t]+)?[^\s"',;`]+"#,
            options: [.caseInsensitive])),
        ("url-userinfo", try! NSRegularExpression(
            pattern: #"\b[a-z][a-z0-9+.-]*://[^\s/@:]+:[^\s/@]+@"#, options: [.caseInsensitive])),
        ("high-entropy-blob", try! NSRegularExpression(pattern: #"[A-Za-z0-9+/_-]{32,}"#)),
    ]

    /// Returns the name of the first secret pattern that matches, or nil.
    public static func findSecret(in text: String) -> String? {
        guard !text.isEmpty else { return nil }
        let full = NSRange(text.startIndex..., in: text)
        for (name, regex) in secretPatterns {
            for match in regex.matches(in: text, options: [], range: full) {
                guard let range = Range(match.range, in: text) else { continue }
                let matched = String(text[range])
                switch name {
                case "openai-key":
                    // sk-learn-tutorial-for-beginners is a tutorial, not a key.
                    if skWordLike.firstMatch(
                        in: matched,
                        options: [],
                        range: NSRange(matched.startIndex..., in: matched)
                    ) != nil { continue }
                case "secret-assignment":
                    // Port of sanitize.js assignIsSecret: paths and code
                    // identifiers are not secrets.
                    let cut = matched.firstIndex(where: { $0 == "=" || $0 == ":" }) ?? matched.startIndex
                    let name = String(matched[..<cut]).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    let value = String(matched[matched.index(after: cut)...]).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    guard assignIsSecret(name: name, value: value) else { continue }
                case "high-entropy-blob":
                    let before = String(text[text.startIndex..<range.lowerBound].suffix(48))
                    guard blobIsSecret(matched, before: before) else { continue }
                default:
                    break
                }
                return name
            }
        }
        return nil
    }

    private static func assignIsSecret(name: String, value: String) -> Bool {
        if value.hasPrefix("./") || value.hasPrefix("../") || value.hasPrefix("~/") { return false }
        // Absolute paths point at a secret, they are not one — unless the
        // value itself is key-shaped material.
        if let match = pathLike.firstMatch(in: value, options: [], range: NSRange(value.startIndex..., in: value)),
           match.range == NSRange(value.startIndex..., in: value) {
            let stripped = value
                .replacingOccurrences(of: "/", with: "")
                .replacingOccurrences(of: ".", with: "")
            if !blobIsSecret(stripped, before: "") { return false }
        }
        let lower = name.lowercased()
        let bareKey = lower.hasSuffix("_key")
            && !["api_key", "api-key", "access_key", "access-key", "private_key", "private-key", "secret_key", "secret-key"].contains(lower)
        if bareKey && name != name.uppercased() { return false }
        return true
    }

    /// Words that make a neighbouring hex blob look like key material.
    private static let keyishWords: Set<String> = [
        "password", "passwords", "passwd", "passwds", "pwd", "pwds", "secret", "secrets",
        "token", "tokens", "key", "keys", "apikey", "api_key", "auth", "authorization",
        "credential", "credentials", "private", "passphrase",
    ]

    private static func keyishContext(_ before: String) -> Bool {
        let scalars = Array(before.unicodeScalars)
        var index = scalars.count - 1
        while index >= 0, !isWordScalar(scalars[index]) { index -= 1 }
        let end = index
        while index >= 0, isWordScalar(scalars[index]) { index -= 1 }
        guard end >= 0, index + 1 <= end else { return false }
        let word = String(String.UnicodeScalarView(scalars[(index + 1)...end])).lowercased()
        if keyishWords.contains(word) { return true }
        return word.contains("_")
            && ["token", "key", "keys", "secret", "secrets", "password", "passwd", "auth", "credential", "credentials"]
                .contains(where: { word.hasSuffix("_" + $0) })
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 0x41 && scalar.value <= 0x5A)
            || (scalar.value >= 0x61 && scalar.value <= 0x7A)
            || (scalar.value >= 0x30 && scalar.value <= 0x39)
            || scalar.value == 0x5F || scalar.value == 0x2D
    }

    /// Port of sanitize.js blobIsSecret: keeps paths, dotted names, and bare
    /// hex ids; redacts mixed-case-with-digit blobs.
    private static func blobIsSecret(_ token: String, before: String) -> Bool {
        guard token.count >= 32 else { return false }
        if token.contains("/") || token.contains(".") { return false }
        let hexCharacters = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        if token.unicodeScalars.allSatisfy({ hexCharacters.contains($0) }) {
            return keyishContext(before)
        }
        let hasLower = token.contains(where: \.isLowercase)
        let hasUpper = token.contains(where: \.isUppercase)
        let hasDigit = token.contains(where: \.isNumber)
        return hasLower && hasUpper && hasDigit
    }

    // MARK: - Speculation guard

    private static let speculationPattern = try! NSRegularExpression(
        pattern: #"\b(?:maybe|probably|i think|might be|possibly|seems like)\b"#,
        options: [.caseInsensitive]
    )

    public static func containsSpeculation(_ text: String) -> Bool {
        !text.isEmpty
            && speculationPattern.firstMatch(
                in: text,
                options: [],
                range: NSRange(text.startIndex..., in: text)
            ) != nil
    }

    // MARK: - Time helpers

    private nonisolated(unsafe) static let dateTimeFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private nonisolated(unsafe) static let dayFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = TimeZone(identifier: "UTC") ?? .current
        return formatter
    }()

    static func isoDateTime(_ date: Date) -> String { dateTimeFormatter.string(from: date) }
    static func isoDay(_ date: Date) -> String { dayFormatter.string(from: date) }

    /// Accepts an ISO datetime or an ISO day; nil when neither.
    public static func parseTimestamp(_ value: String) -> Date? {
        if let date = dateTimeFormatter.date(from: value) { return date }
        return dayFormatter.date(from: value)
    }

    /// Strict YYYY-MM-DD with a real calendar day.
    public static func isValidISODay(_ value: String) -> Bool {
        dayFormatter.date(from: value) != nil
    }

    // MARK: - Propose (agents may propose; design §5)

    public struct MutationResult: Encodable, Sendable {
        public let ok: Bool
        public let op: String
        public let key: String
        public let path: String
        public var status: String
        public let contentHash: String
        public var countersUpdated: Bool?
        /// False when an upvote carried no new evidence: nothing was written.
        public var changed: Bool? = nil
    }

    /// Thrown inside a mutation to abandon it without writing or journaling.
    private struct NoChange: Error {}

    /// `retex memory propose --op add|upvote|edit|retire`.
    public func propose(
        vault: Vault,
        op: String,
        key: String?,
        recordJSON: Data?,
        evidence: [String],
        reason: String?,
        sourceHarness: String?,
        ifHash: String?,
        now: Date = Date()
    ) throws -> MutationResult {
        switch op {
        case "add": return try proposeAdd(vault: vault, recordJSON: recordJSON, evidence: evidence, sourceHarness: sourceHarness, now: now)
        case "upvote": return try proposeUpvote(vault: vault, key: key, evidence: evidence, ifHash: ifHash, now: now)
        case "edit": return try proposeEdit(vault: vault, key: key, recordJSON: recordJSON, evidence: evidence, sourceHarness: sourceHarness, now: now)
        case "retire": return try proposeRetire(vault: vault, key: key, reason: reason, ifHash: ifHash, now: now)
        default:
            throw Self.validation("bad-op", "op must be one of add, upvote, edit, retire")
        }
    }

    private func mergedEvidence(_ fromJSON: [String], _ flags: [String]) -> [String] {
        var seen = Set<String>()
        var merged: [String] = []
        for locator in fromJSON + flags where seen.insert(locator).inserted {
            merged.append(locator)
        }
        return merged
    }

    private func proposeAdd(
        vault: Vault,
        recordJSON: Data?,
        evidence flags: [String],
        sourceHarness: String?,
        now: Date
    ) throws -> MutationResult {
        var input = try Self.recordInput(from: recordJSON)
        input.evidence = mergedEvidence(input.evidence, flags)
        if let sourceHarness, !sourceHarness.isEmpty { input.sourceHarness = sourceHarness }
        try Self.validate(input)
        guard let key = input.key else { throw Self.validation("missing-field:key", "key is required") }
        let url = try recordURL(vault: vault, key: key)
        let scope = Self.scopeKey(from: key)!

        var record = Self.newRecord(
            url: url,
            key: key,
            scope: scope.scope,
            input: input,
            sourceHarness: input.sourceHarness ?? "agent",
            now: now
        )
        record.status = Status.proposed.rawValue
        let source = serialize(record)

        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        try history.performMutation(path: url.path, fileMode: 0o600) {
            if FileManager.default.fileExists(atPath: url.path) {
                let existing = Self.parse(note: try store.load(url))
                throw Self.validation(
                    "key-conflict",
                    "key \(key) already exists (status: \(existing.status.isEmpty ? "unknown" : existing.status))"
                )
            }
            // Creation is journaled with the created source so the undo chain
            // always ends at a coherent, byte-exact state: undoing the create
            // re-writes the proposal itself (retire/reject take it out of
            // circulation). See docs/AGENT-MEMORY.md.
            return (previousSource: source, nextSource: source)
        }
        let stored = try store.load(url)
        return MutationResult(
            ok: true, op: "add", key: key, path: url.path,
            status: record.status, contentHash: stored.contentHash, countersUpdated: nil
        )
    }

    private static func recordInput(from recordJSON: Data?) throws -> RecordInput {
        guard let recordJSON else { return RecordInput() }
        return try Self.parseRecordJSON(recordJSON)
    }

    private static func newRecord(
        url: URL,
        key: String,
        scope: String,
        input: RecordInput,
        sourceHarness: String,
        now: Date
    ) -> MemoryRecord {
        MemoryRecord(
            url: url,
            key: key,
            kind: input.kind ?? "",
            scope: scope,
            title: input.title ?? "",
            body: input.body ?? "",
            appliesWhen: (input.appliesWhen?.isEmpty ?? true) ? nil : input.appliesWhen,
            evidence: input.evidence,
            support: 1,
            confidence: Self.normalizedConfidence(input.confidence),
            certainty: input.certainty ?? Certainty.inferred.rawValue,
            sourceHarness: sourceHarness,
            status: Status.proposed.rawValue,
            validFrom: nil,
            validUntil: nil,
            supersedes: nil,
            supersededBy: [],
            asOf: Self.isoDay(now),
            created: Self.isoDateTime(now),
            updated: Self.isoDateTime(now),
            recalled: 0,
            cited: 0,
            lastUsed: nil,
            recurrences: 0,
            retireProposed: nil,
            contentHash: ""
        )
    }

    /// A live record is one that can still be upvoted or referenced:
    /// proposed, active, or stale.
    static func isLive(status: String) -> Bool {
        [Status.proposed.rawValue, Status.active.rawValue, Status.stale.rawValue].contains(status)
    }

    private func proposeUpvote(
        vault: Vault,
        key: String?,
        evidence: [String],
        ifHash: String?,
        now: Date
    ) throws -> MutationResult {
        guard let key, !key.isEmpty else {
            throw Self.validation("missing-field:key", "--key is required for --op upvote")
        }
        guard !evidence.isEmpty else {
            throw Self.validation("missing-field:evidence", "at least one --evidence locator is required")
        }
        let url = try recordURL(vault: vault, key: key)
        var newStatus = ""
        var unchangedHash: String?
        do {
        try history.performMutation(path: url.path, fileMode: 0o600) {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw MemoryError.notFound(key)
            }
            let note = try store.load(url)
            if let ifHash, note.contentHash != ifHash {
                throw MemoryError.hashMismatch(key: key, expected: ifHash, actual: note.contentHash)
            }
            var record = Self.parse(note: note)
            guard Self.isLive(status: record.status) else {
                throw Self.validation(
                    "bad-status",
                    "key \(key) has status \(record.status); only proposed, active, or stale records can be upvoted"
                )
            }
            // Support counts independent evidence: an upvote whose locators
            // are all already recorded (e.g. the same week dreamed again) is
            // a no-op, so re-runs can never make a proposal promote-ready.
            let fresh = evidence.filter { !record.evidence.contains($0) }
            guard !fresh.isEmpty else {
                newStatus = record.status
                unchangedHash = note.contentHash
                throw NoChange()
            }
            for locator in fresh where !record.evidence.contains(locator) {
                record.evidence.append(locator)
            }
            record.support += 1
            record.updated = Self.isoDateTime(now)
            newStatus = record.status
            return (previousSource: note.source, nextSource: serialize(record))
        }
        } catch is NoChange {
            var result = MutationResult(
                ok: true, op: "upvote", key: key, path: url.path,
                status: newStatus, contentHash: unchangedHash ?? "", countersUpdated: nil
            )
            result.changed = false
            return result
        }
        let stored = try store.load(url)
        var result = MutationResult(
            ok: true, op: "upvote", key: key, path: url.path,
            status: newStatus, contentHash: stored.contentHash, countersUpdated: nil
        )
        result.changed = true
        return result
    }

    /// Smallest free `-v<N>` successor key (v2, v3, …). A key that already
    /// ends in `-v<N>` chains forward from that version.
    private func successorKey(vault: Vault, of key: String) throws -> String {
        var base = key
        var version = 2
        if let dash = key.lastIndex(of: "-") {
            let tail = key[key.index(after: dash)...]
            if tail.first == "v", let current = Int(tail.dropFirst()), current >= 1,
               key[..<dash].contains("/") {
                base = String(key[..<dash])
                version = current + 1
            }
        }
        while version < 1000 {
            let candidate = "\(base)-v\(version)"
            let url = try recordURL(vault: vault, key: candidate)
            if !FileManager.default.fileExists(atPath: url.path) { return candidate }
            version += 1
        }
        throw Self.validation("key-conflict", "no free -v<N> successor key for \(key)")
    }

    private func proposeEdit(
        vault: Vault,
        key: String?,
        recordJSON: Data?,
        evidence flags: [String],
        sourceHarness: String?,
        now: Date
    ) throws -> MutationResult {
        guard let key, !key.isEmpty else {
            throw Self.validation("missing-field:key", "--key is required for --op edit")
        }
        // The edited record must exist.
        let current = try loadRecord(vault: vault, key: key)
        let successor = try successorKey(vault: vault, of: key)

        var input = try Self.recordInput(from: recordJSON)
        // Missing fields are inherited from the record being edited.
        input.key = successor
        if input.kind?.isEmpty ?? true { input.kind = current.kind }
        if input.title?.isEmpty ?? true { input.title = current.title }
        if input.body?.isEmpty ?? true { input.body = current.body }
        if input.appliesWhen?.isEmpty ?? true { input.appliesWhen = current.appliesWhen }
        if input.certainty?.isEmpty ?? true { input.certainty = current.certainty }
        if input.confidence?.isEmpty ?? true { input.confidence = current.confidence }
        input.evidence = mergedEvidence(input.evidence, flags)
        if input.evidence.isEmpty { input.evidence = current.evidence }
        if let sourceHarness, !sourceHarness.isEmpty { input.sourceHarness = sourceHarness }
        if input.sourceHarness?.isEmpty ?? true { input.sourceHarness = current.sourceHarness }

        try Self.validate(input)

        let url = try recordURL(vault: vault, key: successor)
        let scope = Self.scopeKey(from: successor)!
        var record = Self.newRecord(
            url: url,
            key: successor,
            scope: scope.scope,
            input: input,
            sourceHarness: input.sourceHarness ?? "agent",
            now: now
        )
        record.supersedes = key
        let source = serialize(record)

        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        try history.performMutation(path: url.path, fileMode: 0o600) {
            if FileManager.default.fileExists(atPath: url.path) {
                throw Self.validation("key-conflict", "key \(successor) already exists")
            }
            return (previousSource: source, nextSource: source)
        }
        let stored = try store.load(url)
        return MutationResult(
            ok: true, op: "edit", key: successor, path: url.path,
            status: record.status, contentHash: stored.contentHash, countersUpdated: nil
        )
    }

    private func proposeRetire(
        vault: Vault,
        key: String?,
        reason: String?,
        ifHash: String?,
        now: Date
    ) throws -> MutationResult {
        guard let key, !key.isEmpty else {
            throw Self.validation("missing-field:key", "--key is required for --op retire")
        }
        guard let reason, !reason.isEmpty else {
            throw Self.validation("missing-field:reason", "--reason is required for --op retire")
        }
        guard !reason.contains(where: \.isNewline) else {
            throw Self.validation("bad-reason", "reason must be a single line")
        }
        if let pattern = Self.findSecret(in: reason) {
            throw Self.validation("secret:\(pattern)", "reason matches secret pattern \(pattern)")
        }
        let url = try recordURL(vault: vault, key: key)
        var newStatus = ""
        try history.performMutation(path: url.path, fileMode: 0o600) {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw MemoryError.notFound(key)
            }
            let note = try store.load(url)
            if let ifHash, note.contentHash != ifHash {
                throw MemoryError.hashMismatch(key: key, expected: ifHash, actual: note.contentHash)
            }
            var record = Self.parse(note: note)
            // A retirement proposal never changes status by itself.
            record.retireProposed = reason
            record.updated = Self.isoDateTime(now)
            newStatus = record.status
            return (previousSource: note.source, nextSource: serialize(record))
        }
        let stored = try store.load(url)
        return MutationResult(
            ok: true, op: "retire", key: key, path: url.path,
            status: newStatus, contentHash: stored.contentHash, countersUpdated: nil
        )
    }

    // MARK: - Operator actions (design §5)

    /// Promotes a proposal to active. When the record supersedes another, the
    /// superseded record is retired in the same operation: `valid_until` set
    /// to today and `superseded_by` extended with the new key.
    public func promote(
        vault: Vault,
        key: String,
        operatorApproved: Bool,
        ifHash: String?,
        now: Date = Date()
    ) throws -> MutationResult {
        guard operatorApproved else {
            throw MemoryError.notAuthorized("promote requires --operator-approved")
        }
        let url = try existingURL(vault: vault, key: key)

        // Resolve the supersession target up front so a broken chain fails
        // before any record changes.
        let supersededKey = try loadRecord(vault: vault, key: key).supersedes
        var supersededURL: URL?
        if let supersededKey {
            supersededURL = try existingURL(vault: vault, key: supersededKey)
        }

        var newStatus = ""
        try history.performMutation(path: url.path, fileMode: 0o600) {
            let note = try store.load(url)
            if let ifHash, note.contentHash != ifHash {
                throw MemoryError.hashMismatch(key: key, expected: ifHash, actual: note.contentHash)
            }
            var record = Self.parse(note: note)
            guard record.status == Status.proposed.rawValue else {
                throw Self.validation(
                    "bad-status",
                    "key \(key) has status \(record.status); only proposed records can be promoted"
                )
            }
            record.status = Status.active.rawValue
            record.validFrom = Self.isoDay(now)
            record.updated = Self.isoDateTime(now)
            newStatus = record.status
            return (previousSource: note.source, nextSource: serialize(record))
        }

        if let supersededURL {
            try history.performMutation(path: supersededURL.path, fileMode: 0o600) {
                let note = try store.load(supersededURL)
                var record = Self.parse(note: note)
                record.status = Status.retired.rawValue
                record.validUntil = Self.isoDay(now)
                record.updated = Self.isoDateTime(now)
                if !record.supersededBy.contains(key) {
                    record.supersededBy.append(key)
                }
                return (previousSource: note.source, nextSource: serialize(record))
            }
        }

        let stored = try store.load(url)
        return MutationResult(
            ok: true, op: "promote", key: key, path: url.path,
            status: newStatus, contentHash: stored.contentHash, countersUpdated: nil
        )
    }

    /// Rejects a proposal.
    public func reject(
        vault: Vault,
        key: String,
        operatorApproved: Bool,
        ifHash: String?,
        now: Date = Date()
    ) throws -> MutationResult {
        try transition(
            vault: vault, op: "reject", key: key, from: [Status.proposed.rawValue, Status.stale.rawValue],
            to: Status.rejected.rawValue, operatorApproved: operatorApproved,
            requireActive: false, ifHash: ifHash, now: now
        )
    }

    /// Retires an active record (operator action).
    public func retire(
        vault: Vault,
        key: String,
        reason: String?,
        operatorApproved: Bool,
        ifHash: String?,
        now: Date = Date()
    ) throws -> MutationResult {
        guard operatorApproved else {
            throw MemoryError.notAuthorized("retire requires --operator-approved")
        }
        if let reason, let pattern = Self.findSecret(in: reason) {
            throw Self.validation("secret:\(pattern)", "reason matches secret pattern \(pattern)")
        }
        let url = try existingURL(vault: vault, key: key)
        var newStatus = ""
        try history.performMutation(path: url.path, fileMode: 0o600) {
            let note = try store.load(url)
            if let ifHash, note.contentHash != ifHash {
                throw MemoryError.hashMismatch(key: key, expected: ifHash, actual: note.contentHash)
            }
            var record = Self.parse(note: note)
            guard record.status == Status.active.rawValue else {
                throw Self.validation(
                    "bad-status",
                    "key \(key) has status \(record.status); only active records can be retired"
                )
            }
            record.status = Status.retired.rawValue
            record.validUntil = Self.isoDay(now)
            record.updated = Self.isoDateTime(now)
            if let reason, !reason.isEmpty, !reason.contains(where: \.isNewline) {
                record.retireProposed = reason
            }
            newStatus = record.status
            return (previousSource: note.source, nextSource: serialize(record))
        }
        let stored = try store.load(url)
        return MutationResult(
            ok: true, op: "retire", key: key, path: url.path,
            status: newStatus, contentHash: stored.contentHash, countersUpdated: nil
        )
    }

    /// Marks a record stale (operator action).
    public func stale(
        vault: Vault,
        key: String,
        operatorApproved: Bool,
        ifHash: String?,
        now: Date = Date()
    ) throws -> MutationResult {
        try transition(
            vault: vault, op: "stale", key: key, from: [Status.active.rawValue, Status.proposed.rawValue],
            to: Status.stale.rawValue, operatorApproved: operatorApproved,
            requireActive: false, ifHash: ifHash, now: now
        )
    }

    private func transition(
        vault: Vault,
        op: String,
        key: String,
        from allowed: [String],
        to target: String,
        operatorApproved: Bool,
        requireActive: Bool,
        ifHash: String?,
        now: Date
    ) throws -> MutationResult {
        guard operatorApproved else {
            throw MemoryError.notAuthorized("\(op) requires --operator-approved")
        }
        let url = try existingURL(vault: vault, key: key)
        var newStatus = ""
        try history.performMutation(path: url.path, fileMode: 0o600) {
            let note = try store.load(url)
            if let ifHash, note.contentHash != ifHash {
                throw MemoryError.hashMismatch(key: key, expected: ifHash, actual: note.contentHash)
            }
            var record = Self.parse(note: note)
            guard allowed.contains(record.status) else {
                throw Self.validation(
                    "bad-status",
                    "key \(key) has status \(record.status); cannot move to \(target)"
                )
            }
            record.status = target
            record.updated = Self.isoDateTime(now)
            if target == Status.retired.rawValue {
                record.validUntil = Self.isoDay(now)
            }
            newStatus = target
            return (previousSource: note.source, nextSource: serialize(record))
        }
        let stored = try store.load(url)
        return MutationResult(
            ok: true, op: op, key: key, path: url.path,
            status: newStatus, contentHash: stored.contentHash, countersUpdated: nil
        )
    }

    // MARK: - Telemetry (counters; design §5)

    /// Citations bump `cited` and refresh `last_used`. Telemetry: no undo
    /// entry is created, and a busy lock skips the update rather than
    /// blocking the caller.
    public func cite(vault: Vault, key: String, now: Date = Date()) throws -> MutationResult {
        let record = try loadRecord(vault: vault, key: key)
        let updated = try? performTelemetryUpdate(vault: vault, keys: [record.key], mode: .cite, now: now)
        let stored = try store.load(record.url)
        return MutationResult(
            ok: true, op: "cite", key: key, path: record.url.path,
            status: stored.metadata["status", default: ""], contentHash: stored.contentHash,
            countersUpdated: updated
        )
    }

    private enum TelemetryMode { case context, cite }

    /// Non-blocking try-lock on the vault journal lock. Returns nil when the
    /// lock is busy — callers treat that as "skip the counter update".
    private func withTelemetryLock<R>(vault: Vault, _ body: () throws -> R) throws -> R? {
        _ = try? UndoHistory.prepare(for: vault)
        #if os(Windows)
        // The journal lock directory protocol belongs to UndoHistory; memory
        // telemetry is best-effort on Windows and simply runs.
        return try body()
        #else
        let lockPath = UndoHistory.journalURL(for: vault).path + ".lock"
        let fd = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return nil }
        defer { flock(fd, LOCK_UN) }
        return try body()
        #endif
    }

    /// Rewrites counter fields under the try-lock. No undo entry: counters
    /// are telemetry, not content (documented in docs/AGENT-MEMORY.md).
    private func performTelemetryUpdate(vault: Vault, keys: [String], mode: TelemetryMode, now: Date) throws -> Bool {
        guard !keys.isEmpty else { return true }
        let timestamp = Self.isoDateTime(now)
        return try withTelemetryLock(vault: vault) {
            for key in keys {
                guard let url = try? recordURL(vault: vault, key: key),
                      let note = try? store.load(url)
                else { continue }
                var record = Self.parse(note: note)
                switch mode {
                case .context:
                    record.recalled += 1
                case .cite:
                    record.cited += 1
                }
                record.lastUsed = timestamp
                let source = serialize(record)
                try source.write(to: record.url, atomically: true, encoding: .utf8)
                #if !os(Windows)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: record.url.path)
                #endif
            }
            return true
        } ?? false
    }

    // MARK: - Session pack (design §5)

    public struct RankedRecord: Encodable, Sendable {
        public let key: String
        public let title: String
        public let score: Double
    }

    public struct ContextResult: Encodable, Sendable {
        public let pack: String
        public let budget: Int
        public let usedBytes: Int
        public let emitted: Int
        public let totalActive: Int
        public let countersUpdated: Bool
        public let scope: String
        public let project: String?
        public let harness: String?
        public let records: [RankedRecord]
    }

    /// Builds the deterministic session pack for ACTIVE records in
    /// `global` + `project:<name>` scope. Pure: the same records, budget and
    /// `now` always produce the same bytes.
    /// The pack heading: a host-supplied name (single line, no Markdown
    /// control characters, <= 60 characters) or "Agent memory".
    public static func packHeading(_ heading: String?) -> String {
        let trimmed = (heading ?? "").trimmingCharacters(in: .whitespaces)
        let safe = trimmed.count <= 60 && !trimmed.isEmpty
            && trimmed.unicodeScalars.allSatisfy { !CharacterSet.newlines.contains($0) && !"#*`[]<>".unicodeScalars.contains($0) }
        return safe ? trimmed : "Agent memory"
    }

    public func context(
        vault: Vault,
        scope: String = "global",
        project: String?,
        budget: Int,
        harness: String?,
        heading: String? = nil,
        now: Date = Date()
    ) throws -> ContextResult {
        guard (1...Self.maxBudget).contains(budget) else {
            throw Self.validation("bad-budget", "budget must be an integer from 1 through \(Self.maxBudget)")
        }
        // A host names its memory ("UltraTerm memory"); one plain line only.
        let title = Self.packHeading(heading)
        guard scope == "global" else {
            throw Self.validation("bad-scope", "scope must be global")
        }
        let all = try scanRecords(vault: vault)
        let eligible = all.filter { record in
            guard record.status == Status.active.rawValue else { return false }
            if record.scope == "global" { return true }
            if let project, !project.isEmpty, record.scope == "project:\(project)" { return true }
            return false
        }
        let ranked = Self.rankRecords(eligible, now: now)
        let pack = Self.buildContextPack(ranked: ranked, budget: budget, heading: title)
        let countersUpdated = (try? performTelemetryUpdate(
            vault: vault,
            keys: pack.emitted.map(\.record.key),
            mode: .context,
            now: now
        )) ?? false
        return ContextResult(
            pack: pack.text,
            budget: budget,
            usedBytes: pack.text.utf8.count,
            emitted: pack.emitted.count,
            totalActive: eligible.count,
            countersUpdated: countersUpdated,
            scope: scope,
            project: project,
            harness: harness,
            records: pack.emitted.map { ranked in
                RankedRecord(key: ranked.record.key, title: ranked.record.title, score: ranked.score)
            }
        )
    }

    /// Pack ranking (design §5):
    /// `0.35·kind + 0.25·min(support,4)/4 + 0.2·usage + 0.2·recency`, where
    /// usage = min(1, recalled/10 + cited/3) · 0.5^(daysSince(last_used)/60)
    /// and recency = 0.5^(daysSince(updated)/90). Ties break by key.
    public static func rankRecords(_ records: [MemoryRecord], now: Date) -> [(record: MemoryRecord, score: Double)] {
        records.map { record -> (record: MemoryRecord, score: Double) in
            let kindWeight = Kind(rawValue: record.kind)?.weight ?? 0
            let supportComponent = Double(min(record.support, 4)) / 4.0
            let usage = min(1, Double(record.recalled) / 10.0 + Double(record.cited) / 3.0)
                * pow(0.5, daysSince(record.lastUsed ?? record.updated, before: now) / 60.0)
            let recency = pow(0.5, daysSince(record.updated, before: now) / 90.0)
            let score = 0.35 * kindWeight + 0.25 * supportComponent + 0.2 * usage + 0.2 * recency
            return (record, score)
        }
        .sorted { left, right in
            if left.score != right.score { return left.score > right.score }
            return left.record.key < right.record.key
        }
    }

    private static func daysSince(_ timestamp: String, before now: Date) -> Double {
        guard let date = parseTimestamp(timestamp) else { return 0 }
        return max(0, now.timeIntervalSince(date) / 86_400)
    }

    /// Adds whole records in rank order until the budget would be exceeded;
    /// never truncates a record. The rendered text — header, records, and, when
    /// records did not fit, the footer — is always ≤ budget bytes.
    public static func buildContextPack(
        ranked: [(record: MemoryRecord, score: Double)],
        budget: Int,
        heading title: String = "Agent memory"
    ) -> (text: String, emitted: [(record: MemoryRecord, score: Double)], excluded: Int) {
        let total = ranked.count
        var emitted: [(record: MemoryRecord, score: Double)] = []
        var text = ""
        for candidate in ranked {
            let next = emitted + [candidate]
            let attempt = renderPack(
                header: "## \(title) (\(next.count) of \(total) active)",
                records: next,
                excluded: total - next.count
            )
            guard attempt.utf8.count <= budget else { break }
            emitted = next
            text = attempt
        }
        if emitted.isEmpty {
            let attempt = renderPack(
                header: "## \(title) (0 of \(total) active)",
                records: [],
                excluded: total
            )
            if attempt.utf8.count <= budget { text = attempt }
        }
        return (text, emitted, total - emitted.count)
    }

    private static func renderPack(
        header: String,
        records: [(record: MemoryRecord, score: Double)],
        excluded: Int
    ) -> String {
        var text = header
        let lines = records.map { ranked -> String in
            let record = ranked.record
            return "- **\(record.title)** — \(firstSentence(record.body)) (key: \(record.key))"
        }
        if !lines.isEmpty {
            text += "\n\n" + lines.joined(separator: "\n")
        }
        if excluded > 0 {
            text += "\n\n(\(excluded) more active memories; run: retex memory recall \"<topic>\")"
        }
        return text + "\n"
    }

    /// The body's first sentence (newlines collapsed); the whole body when it
    /// has no sentence boundary.
    public static func firstSentence(_ body: String) -> String {
        let flat = body
            .split(whereSeparator: \.isNewline)
            .map { MarkdownStore.trimmed($0, in: MarkdownStore.whitespaceCharacters) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !flat.isEmpty else { return "" }
        var end = flat.endIndex
        var index = flat.startIndex
        while index < flat.endIndex {
            let character = flat[index]
            if character == "." || character == "!" || character == "?" {
                let after = flat.index(after: index)
                if after == flat.endIndex || flat[after] == " " {
                    end = after
                    break
                }
            }
            index = flat.index(after: index)
        }
        return String(flat[flat.startIndex..<end])
    }

    // MARK: - Recall (design §5)

    public struct RecallItem: Encodable, Sendable {
        public let key: String
        public let title: String
        public let path: String
        public let status: String
        public let score: Int
        public let excerpt: String
    }

    public struct RecallResult: Encodable, Sendable {
        public let query: String
        public let budgetBytes: Int
        public let usedBytes: Int
        public let truncated: Bool
        public let records: [RecallItem]
    }

    /// Ranked lexical recall restricted to active Memory/ records (plus
    /// labelled proposals with `includeProposed`). Records are packed whole
    /// under the byte budget using the same accounting as `retex recall`.
    public func recall(
        vault: Vault,
        query: String,
        budget: Int,
        includeProposed: Bool,
        limit: Int = 200
    ) throws -> RecallResult {
        guard (1...1_000_000).contains(budget) else {
            throw Self.validation("bad-budget", "budget must be an integer from 1 through 1000000")
        }
        let memoryRoot = vault.url.standardizedFileURL
            .appendingPathComponent("Memory", isDirectory: true)
        let memoryPrefix = Self.canonicalPath(memoryRoot.path) + "/"
        let hits = try store.recall(vault, query: query, type: "memory", limit: limit)
        let filtered = hits.filter { hit in
            guard Self.canonicalPath(hit.note.url.path).hasPrefix(memoryPrefix) else { return false }
            return hit.note.metadata["status", default: ""] == Status.active.rawValue
                || (includeProposed && hit.note.metadata["status", default: ""] == Status.proposed.rawValue)
        }
        let encoder = JSONEncoder()
        var items: [RecallItem] = []
        var usedBytes = 2
        for hit in filtered {
            let status = hit.note.metadata["status", default: ""]
            let label = status == Status.proposed.rawValue
                ? "[proposed] \(hit.note.title)"
                : hit.note.title
            let item = RecallItem(
                key: hit.note.metadata["key", default: ""],
                title: label,
                path: hit.note.url.path,
                status: status,
                score: hit.score,
                excerpt: hit.excerpt
            )
            guard let encoded = try? encoder.encode(item) else { continue }
            let candidateBytes = usedBytes + encoded.count + (items.isEmpty ? 0 : 1)
            guard candidateBytes <= budget else { break }
            items.append(item)
            usedBytes = candidateBytes
        }
        return RecallResult(
            query: query,
            budgetBytes: budget,
            usedBytes: usedBytes,
            truncated: items.count < filtered.count,
            records: items
        )
    }

    // MARK: - Review (design §6)

    public struct ReviewItem: Encodable, Sendable {
        public let key: String
        public let title: String
        public let kind: String
        public let support: Int
        public let created: String
        public let evidence: [String]
        public let distinctSessions: Int
        public let promoteReady: Bool
    }

    /// Proposed records sorted by support (desc), then created, then key.
    /// `promoteReady` = support ≥ 2 from ≥ 2 distinct sessions, kind
    /// `correction`, and operator-flavoured evidence.
    public func review(vault: Vault) throws -> [ReviewItem] {
        try scanRecords(vault: vault)
            .filter { $0.status == Status.proposed.rawValue }
            .sorted { left, right in
                if left.support != right.support { return left.support > right.support }
                if left.created != right.created { return left.created < right.created }
                return left.key < right.key
            }
            .map { record in
                let sessions = Set(record.evidence.map(Self.sessionID(of:)))
                let operatorFlavoured = record.evidence.contains {
                    $0.hasPrefix("operator:") || $0.contains("#user")
                }
                return ReviewItem(
                    key: record.key,
                    title: record.title,
                    kind: record.kind,
                    support: record.support,
                    created: record.created,
                    evidence: record.evidence,
                    distinctSessions: sessions.count,
                    promoteReady: record.support >= 2
                        && sessions.count >= 2
                        && record.kind == Kind.correction.rawValue
                        && operatorFlavoured
                )
            }
    }

    /// Session id of a locator: the segment after the scheme, up to the first
    /// `#` (entry) or `@` (revision).
    public static func sessionID(of locator: String) -> String {
        guard let colon = locator.firstIndex(of: ":") else { return locator }
        let rest = locator[locator.index(after: colon)...]
        let end = rest.firstIndex(where: { $0 == "#" || $0 == "@" }) ?? rest.endIndex
        return String(rest[..<end])
    }

    // MARK: - Doctor (design §5)

    public struct DoctorReport: Encodable, Sendable {
        public let ok: Bool
        public let records: Int
        public let issues: [String]
    }

    /// Validates every record (schema, key uniqueness, supersession chains,
    /// file and directory modes). Any issue makes the report not-ok; the CLI
    /// exits non-zero.
    public func doctor(vault: Vault) throws -> DoctorReport {
        var issues: [String] = []
        let fileManager = FileManager.default
        // The scanners enumerate under the symlink-resolved vault root, so
        // every path comparison here uses the resolved form too.
        let memoryRoot = vault.url.standardizedFileURL
            .resolvingSymlinksInPath()
            .appendingPathComponent("Memory", isDirectory: true)

        var notes: [Note] = []
        if fileManager.fileExists(atPath: memoryRoot.path) {
            let result = try store.scanWithDiagnostics(vault)
            let memoryPrefix = Self.canonicalPath(memoryRoot.path) + "/"
            notes = result.notes.filter { Self.canonicalPath($0.url.path).hasPrefix(memoryPrefix) }
            for unreadable in result.unreadable where Self.canonicalPath(unreadable).hasPrefix(memoryPrefix) {
                issues.append("Unreadable memory record: \(unreadable)")
            }
            checkDirectoryModes(under: memoryRoot, issues: &issues)
        } else {
            issues.append("Missing Memory/ directory (run: retex memory init)")
        }

        var records: [MemoryRecord] = []
        var keys = [String: Int]()
        for note in notes {
            if note.recordType != "memory" {
                issues.append("\(note.url.path): type \(note.recordType) is not a memory record")
                continue
            }
            let record = Self.parse(note: note)
            records.append(record)
            keys[record.key, default: 0] += 1

            if let expectedScope = Self.scopeKey(from: record.key) {
                let expectedURL = try recordURL(vault: vault, key: record.key)
                if Self.canonicalPath(expectedURL.path) != Self.canonicalPath(record.url.path) {
                    issues.append("\(record.url.path): file does not match key \(record.key)")
                }
                if record.scope != expectedScope.scope {
                    issues.append(
                        "\(record.url.path): scope \(record.scope) does not match key \(record.key) (expected \(expectedScope.scope))"
                    )
                }
            } else {
                issues.append("\(record.url.path): invalid key \(record.key)")
            }

            do {
                try Self.validate(Self.input(from: record))
            } catch let error as MemoryError {
                issues.append("\(record.url.path): \(error.errorDescription ?? "invalid record")")
            }

            if let fileMode = fileMode(of: record.url.path), fileMode != 0o600 {
                issues.append(String(format: "%@: file mode %o should be 600", record.url.path, fileMode))
            }
        }

        for (key, count) in keys where count > 1 {
            issues.append("Duplicate key \(key) across \(count) files")
        }

        let byKey = Dictionary(grouping: records, by: \.key).mapValues(\.first!)
        for record in records {
            if let target = record.supersedes {
                guard let targetRecord = byKey[target] else {
                    issues.append("\(record.url.path): supersedes missing record \(target)")
                    continue
                }
                if record.status == Status.active.rawValue {
                    if targetRecord.status != Status.retired.rawValue {
                        issues.append(
                            "\(record.url.path): active record supersedes \(target) which is \(targetRecord.status), not retired"
                        )
                    }
                    if !targetRecord.supersededBy.contains(record.key) {
                        issues.append("\(record.url.path): superseded record \(target) lacks superseded_by \(record.key)")
                    }
                }
            }
            for source in record.supersededBy where byKey[source] == nil {
                issues.append("\(record.url.path): superseded_by references missing record \(source)")
            }
        }

        // More than one active successor of the same record is a broken chain.
        let activeSuperseding = records.filter {
            $0.status == Status.active.rawValue && $0.supersedes != nil
        }
        let activeByTarget = Dictionary(grouping: activeSuperseding, by: \.supersedes!)
        for (target, successors) in activeByTarget where successors.count > 1 {
            issues.append(
                "Multiple active successors supersede \(target): "
                    + successors.map(\.key).sorted().joined(separator: ", ")
            )
        }

        return DoctorReport(ok: issues.isEmpty, records: records.count, issues: issues.sorted())
    }

    private static func input(from record: MemoryRecord) -> RecordInput {
        RecordInput(
            key: record.key,
            kind: record.kind,
            title: record.title,
            body: record.body,
            appliesWhen: record.appliesWhen,
            evidence: record.evidence,
            confidence: record.confidence,
            certainty: record.certainty,
            scope: record.scope,
            sourceHarness: record.sourceHarness
        )
    }

    /// Canonical (symlink-resolved) form of a path. All memory path
    /// comparisons run through this: FileManager's enumerator returns
    /// resolved paths (/private/var on macOS) while URL builders do not.
    static func canonicalPath(_ path: String) -> String {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        var buffer = [CChar](repeating: 0, count: 4097)
        guard realpath(path, &buffer) != nil else { return path }
        return String(cString: buffer)
        #else
        return path
        #endif
    }

    private func checkDirectoryModes(under root: URL, issues: inout [String]) {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return }
        for case let url as URL in enumerator where url.hasDirectoryPath {
            if let mode = fileMode(of: url.path), mode != 0o700 {
                issues.append(String(format: "%@: directory mode %o should be 700", url.path, mode))
            }
        }
    }

    private func fileMode(of path: String) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? Int
    }
}
