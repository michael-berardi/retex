#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Foundation

/// Optional encrypted vault sync. The vault is archived and encrypted on this
/// machine (`VaultCrypto`), so the server only ever stores an opaque
/// `RETEXENC1` blob; the passphrase and plaintext never leave the client.
/// Writes use optimistic concurrency (`If-Match` on the blob's SHA-256), so
/// two machines can never silently overwrite each other.
public struct VaultSync {
    public enum SyncError: LocalizedError, Equatable {
        case notConfigured
        case insecureServer(String)
        case invalidVaultID(String)
        case conflict(String)
        case localChanges
        case remoteMissing
        case server(Int, String)
        case network(String)

        public var errorDescription: String? {
            switch self {
            case .notConfigured: "Sync is not configured for this vault. Run `retex sync push --server <url> --vault-id <id>` first."
            case .insecureServer(let url): "Refusing plain-HTTP sync server \(url); use https (http is allowed only for localhost)."
            case .invalidVaultID(let id): "Invalid sync vault id \"\(id)\": use 1-64 letters, digits, '.', '_' or '-'."
            case .conflict(let detail): "Sync conflict: the server has a newer version (\(detail)). Run `retex sync pull` first."
            case .localChanges: "Local changes since the last sync would be overwritten. Push them, or pass --force to discard them."
            case .remoteMissing: "The server has no copy of this vault yet. Run `retex sync push`."
            case .server(let code, let message): "Sync server returned HTTP \(code): \(message)"
            case .network(let message): "Sync server unreachable: \(message)"
            }
        }
    }

    public struct State: Codable, Equatable {
        public var server: String
        public var vaultID: String
        /// SHA-256 of the encrypted blob last pushed or pulled (server revision).
        public var revision: String?
        /// SHA-256 of the local plaintext archive at that point.
        public var localDigest: String?
        public var syncedAt: String?
    }

    public struct Status: Codable, Equatable {
        public let server: String
        public let vaultID: String
        public let revision: String?
        public let syncedAt: String?
        public let localChanges: Bool
        public let remoteRevision: String?
        public let remoteChanged: Bool
    }

    public struct Result: Codable, Equatable {
        public let action: String
        public let revision: String
        public let files: Int
        public let removed: Int
        public let bytes: Int
    }

    private let vault: Vault
    private let token: String
    private let session: URLSession

    /// Ceiling for a single exchange's resource timeout: the largest archive
    /// sync may exchange, plus room for the JSON envelope.
    static let maximumTransferBytes = 2 * 1024 * 1024 * 1024

    public init(vault: Vault, token: String, session: URLSession = .shared) {
        self.vault = vault
        self.token = token
        self.session = Self.boundedSession(from: session.configuration)
    }

    /// A dedicated session whose stall guard is the idle timeout rather than a
    /// fixed cap on the whole transfer, so a big vault on a slow link keeps
    /// flowing while a stalled server is dropped after a minute of silence.
    static func boundedSession(from configuration: URLSessionConfiguration) -> URLSession {
        HTTPDeadline.configure(configuration, maximumBytes: maximumTransferBytes)
    }

    // MARK: - State

    static func stateURL(_ vault: Vault) -> URL {
        vault.url.appendingPathComponent(".retex/sync.json")
    }

    public static func loadState(_ vault: Vault) throws -> State? {
        let url = stateURL(vault)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
    }

    static func saveState(_ state: State, _ vault: Vault) throws {
        let url = stateURL(vault)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func validate(server: String, vaultID: String) throws -> URL {
        guard vaultID.range(of: "^[A-Za-z0-9._-]{1,64}$", options: .regularExpression) != nil,
              vaultID != ".", vaultID != ".."
        else { throw SyncError.invalidVaultID(vaultID) }
        guard var components = URLComponents(string: server), let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty
        else { throw SyncError.insecureServer(server) }
        let loopback = ["localhost", "127.0.0.1", "::1"].contains(host)
        guard scheme == "https" || (scheme == "http" && loopback) else { throw SyncError.insecureServer(server) }
        components.path = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path += "/v1/vaults/\(vaultID)"
        guard let url = components.url else { throw SyncError.insecureServer(server) }
        return url
    }

    // MARK: - Operations

    /// Resolves the target from flags or saved state and persists it.
    private func resolve(server: String?, vaultID: String?) throws -> (State, URL) {
        let saved = try Self.loadState(vault)
        guard let serverValue = server ?? saved?.server, let idValue = vaultID ?? saved?.vaultID else {
            throw SyncError.notConfigured
        }
        let url = try Self.validate(server: serverValue, vaultID: idValue)
        var state = saved ?? State(server: serverValue, vaultID: idValue)
        if state.server != serverValue || state.vaultID != idValue {
            // A different target starts a fresh sync history.
            state = State(server: serverValue, vaultID: idValue)
        }
        return (state, url)
    }

    private func localDigest() throws -> String {
        try VaultCrypto.contentDigest(vaultURL: vault.url)
    }

    public func push(server: String?, vaultID: String?, passphrase: String,
                     force: Bool = false) throws -> Result {
        var (state, url) = try resolve(server: server, vaultID: vaultID)
        // One vault walk yields the archive, the digest recorded for this
        // revision, and the file count.
        let snapshot = try VaultCrypto.snapshot(vaultURL: vault.url)
        let blob = try VaultCrypto().encrypt(snapshot.archive, passphrase: passphrase)
        var request = authorized(URLRequest(url: url))
        request.httpMethod = "PUT"
        request.httpBody = blob
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        if !force {
            request.setValue(state.revision.map { "\"\($0)\"" } ?? "*", forHTTPHeaderField: state.revision == nil ? "If-None-Match" : "If-Match")
        }
        // The upload size is known here, so the deadline covers it even when
        // the session never reports `countOfBytesExpectedToSend`.
        let (body, response) = try send(request, expectedBytes: blob.count)
        switch response.statusCode {
        case 200, 201:
            let revision = Self.revision(from: response, fallback: Self.sha256(blob))
            state.revision = revision
            state.localDigest = snapshot.digest
            state.syncedAt = ISO8601DateFormatter().string(from: Date())
            try Self.saveState(state, vault)
            return Result(action: "push", revision: revision, files: snapshot.fileCount,
                          removed: 0, bytes: blob.count)
        case 409, 412:
            throw SyncError.conflict(Self.message(body))
        default:
            throw SyncError.server(response.statusCode, Self.message(body))
        }
    }

    public func pull(server: String?, vaultID: String?, passphrase: String,
                     force: Bool = false) throws -> Result {
        var (state, url) = try resolve(server: server, vaultID: vaultID)
        if !force {
            if let recorded = state.localDigest {
                // Exactly one walk of the vault for the local-change check.
                if recorded != (try localDigest()) { throw SyncError.localChanges }
            } else if !(try VaultCrypto.portableFilePaths(vaultURL: vault.url)).isEmpty {
                throw SyncError.localChanges
            }
        }
        var request = authorized(URLRequest(url: url))
        request.httpMethod = "GET"
        let (body, response) = try send(request)
        if response.statusCode == 404 { throw SyncError.remoteMissing }
        guard response.statusCode == 200 else { throw SyncError.server(response.statusCode, Self.message(body)) }
        // Decrypt and validate everything before the vault is touched.
        let archive = try VaultCrypto().decrypt(body, passphrase: passphrase)
        let outcome = try VaultCrypto.mirrorArchiveReport(archive, into: vault.url)
        state.revision = Self.revision(from: response, fallback: Self.sha256(body))
        // The mirrored vault holds exactly the archived files, so the digest
        // comes from the archive instead of re-walking the vault.
        state.localDigest = outcome.digest
        state.syncedAt = ISO8601DateFormatter().string(from: Date())
        try Self.saveState(state, vault)
        return Result(action: "pull", revision: state.revision ?? "", files: outcome.written,
                      removed: outcome.removed, bytes: body.count)
    }

    public func status(server: String?, vaultID: String?) throws -> Status {
        let (state, url) = try resolve(server: server, vaultID: vaultID)
        var request = authorized(URLRequest(url: url))
        request.httpMethod = "HEAD"
        let (_, response) = try send(request)
        var remote: String?
        if response.statusCode == 200 {
            remote = Self.etag(from: response)
        } else if response.statusCode != 404 {
            throw SyncError.server(response.statusCode, "status check failed")
        }
        let changed: Bool
        if let recorded = state.localDigest {
            changed = recorded != (try localDigest())
        } else {
            changed = !(try VaultCrypto.portableFilePaths(vaultURL: vault.url)).isEmpty
        }
        return Status(server: state.server, vaultID: state.vaultID, revision: state.revision,
                      syncedAt: state.syncedAt, localChanges: changed,
                      remoteRevision: remote, remoteChanged: remote != state.revision)
    }

    // MARK: - HTTP

    private func authorized(_ request: URLRequest) -> URLRequest {
        var request = request
        // The stall guard: a sync that keeps making progress may run long.
        request.timeoutInterval = HTTPDeadline.idle()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func send(_ request: URLRequest, expectedBytes: Int = 0) throws -> (Data, HTTPURLResponse) {
        final class Box: @unchecked Sendable { var result: Swift.Result<(Data, HTTPURLResponse), Error>? }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                box.result = .failure(SyncError.network(error.localizedDescription))
            } else if let http = response as? HTTPURLResponse {
                box.result = .success((data ?? Data(), http))
            } else {
                box.result = .failure(SyncError.network("no HTTP response"))
            }
        }
        task.resume()
        let waited = HTTPDeadline.wait(for: task, semaphore: semaphore, hint: expectedBytes)
        guard waited.completed else {
            task.cancel()
            throw SyncError.network("no answer within \(Int(waited.deadline)) seconds")
        }
        guard let result = box.result else { throw SyncError.network("no HTTP response") }
        return try result.get()
    }

    /// The server's revision token: its `ETag` when that is a strong SHA-256,
    /// otherwise the SHA-256 of the blob we just exchanged. A server tag in
    /// another namespace is not a content revision — trusting it made `status`
    /// compare two unrelated token namespaces and report spurious changes.
    private static func etag(from response: HTTPURLResponse) -> String? {
        guard let raw = response.value(forHTTPHeaderField: "ETag") else { return nil }
        var token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.hasPrefix("W/") || token.hasPrefix("w/") {
            // A weak validator still names the same blob.
            token = String(token.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        token = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard token.count == 64, token.allSatisfy(\.isHexDigit) else { return nil }
        return token.lowercased()
    }

    private static func revision(from response: HTTPURLResponse, fallback: @autoclosure () -> String) -> String {
        etag(from: response) ?? fallback()
    }

    private static func message(_ body: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let error = object["error"] as? String { return error }
        return String(decoding: body.prefix(200), as: UTF8.self)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
