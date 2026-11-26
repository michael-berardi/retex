import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import RetexCore

/// In-memory stand-in for the sync server, matching deploy/sync-server/server.py.
final class FakeSyncProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var blob: Data?
    nonisolated(unsafe) static var lastBody: Data?
    /// When set, the server answers with this opaque revision token instead of
    /// the blob hash, which proves the client stores the server's ETag rather
    /// than recomputing its own digest.
    nonisolated(unsafe) static var etagOverride: String?
    /// When true the server answers without any ETag header at all.
    nonisolated(unsafe) static var suppressETag = false

    /// The revision token this fake server advertises, honouring the overrides.
    private static func tag(_ fallback: @autoclosure () -> String?) -> String? {
        if suppressETag { return nil }
        if let override = etagOverride { return override }
        return fallback()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        func reply(_ code: Int, _ body: Data = Data(), etag: String? = nil) {
            var headers = ["Content-Length": "\(body.count)"]
            // Quoted like a real strong validator; `W/`-prefixed values are
            // already a complete, quoted weak validator.
            if let etag { headers["ETag"] = etag.hasPrefix("W/") ? etag : "\"\(etag)\"" }
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        guard request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token" else {
            return reply(401, Data(#"{"error":"bad token"}"#.utf8))
        }
        let digest = Self.blob.map { VaultSyncTests.hash($0) }
        switch request.httpMethod {
        case "GET": Self.blob.map { reply(200, $0, etag: Self.tag(digest)) } ?? reply(404)
        case "HEAD": Self.blob == nil ? reply(404) : reply(200, etag: Self.tag(digest))
        case "PUT":
            var body = request.httpBody ?? Data()
            if body.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 65536)
                while stream.hasBytesAvailable {
                    let n = stream.read(&buffer, maxLength: buffer.count)
                    if n <= 0 { break }
                    body.append(buffer, count: n)
                }
            }
            let match = request.value(forHTTPHeaderField: "If-Match")?.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if request.value(forHTTPHeaderField: "If-None-Match") == "*", Self.blob != nil {
                return reply(412, Data(#"{"error":"vault already exists"}"#.utf8))
            }
            if let match, match != digest { return reply(412, Data(#"{"error":"revision is stale"}"#.utf8)) }
            let created = Self.blob == nil
            Self.blob = body
            reply(created ? 201 : 200, Data("{}".utf8), etag: Self.tag(VaultSyncTests.hash(body)))
        default: reply(405)
        }
    }
}

final class VaultSyncTests: XCTestCase {
    static func hash(_ data: Data) -> String { VaultSyncTestsHelper.sha(data) }
    private let server = "https://sync.example.com"
    private let passphrase = "correct horse battery staple"
    private var dirs: [URL] = []

    override func setUp() {
        FakeSyncProtocol.blob = nil
        FakeSyncProtocol.etagOverride = nil
        FakeSyncProtocol.suppressETag = false
    }
    override func tearDown() {
        FakeSyncProtocol.etagOverride = nil
        FakeSyncProtocol.suppressETag = false
        dirs.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    private func vault(_ files: [String: String] = [:]) throws -> Vault {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("retex-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dirs.append(dir)
        for (path, text) in files {
            let url = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return Vault(url: dir)
    }

    private func sync(_ vault: Vault, token: String = "secret-token") -> VaultSync {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeSyncProtocol.self]
        return VaultSync(vault: vault, token: token, session: URLSession(configuration: config))
    }

    func testPushPullRoundTripMirrorsDeletionsAndKeepsServerOpaque() throws {
        let a = try vault(["one.md": "# secret-plan", "gone.md": "old"])
        let pushed = try sync(a).push(server: server, vaultID: "crm", passphrase: passphrase)
        XCTAssertEqual(pushed.action, "push")
        XCTAssertFalse(String(decoding: FakeSyncProtocol.blob!, as: UTF8.self).contains("secret-plan"))

        let b = try vault()
        _ = try sync(b).pull(server: server, vaultID: "crm", passphrase: passphrase)
        XCTAssertEqual(try String(contentsOf: b.url.appendingPathComponent("one.md")), "# secret-plan")

        try FileManager.default.removeItem(at: b.url.appendingPathComponent("gone.md"))
        try "new".write(to: b.url.appendingPathComponent("two.md"), atomically: true, encoding: .utf8)
        _ = try sync(b).push(server: nil, vaultID: nil, passphrase: passphrase)

        let pulled = try sync(a).pull(server: nil, vaultID: nil, passphrase: passphrase)
        XCTAssertEqual(pulled.removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.url.appendingPathComponent("gone.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.url.appendingPathComponent("two.md").path))
        let status = try sync(a).status(server: nil, vaultID: nil)
        XCTAssertFalse(status.localChanges)
        XCTAssertFalse(status.remoteChanged)
    }

    func testStalePushIsAConflictAndLocalChangesBlockPull() throws {
        let a = try vault(["one.md": "a"])
        _ = try sync(a).push(server: server, vaultID: "crm", passphrase: passphrase)
        let b = try vault()
        _ = try sync(b).pull(server: server, vaultID: "crm", passphrase: passphrase)
        try "b".write(to: b.url.appendingPathComponent("one.md"), atomically: true, encoding: .utf8)
        _ = try sync(b).push(server: nil, vaultID: nil, passphrase: passphrase)

        try "a2".write(to: a.url.appendingPathComponent("one.md"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try sync(a).push(server: nil, vaultID: nil, passphrase: passphrase)) {
            guard case VaultSync.SyncError.conflict = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try sync(a).pull(server: nil, vaultID: nil, passphrase: passphrase)) {
            XCTAssertEqual($0 as? VaultSync.SyncError, .localChanges)
        }
        _ = try sync(a).pull(server: nil, vaultID: nil, passphrase: passphrase, force: true)
        XCTAssertEqual(try String(contentsOf: a.url.appendingPathComponent("one.md")), "b")
    }

    func testWrongPassphraseLeavesVaultUntouched() throws {
        let a = try vault(["one.md": "keep"])
        _ = try sync(a).push(server: server, vaultID: "crm", passphrase: passphrase)
        XCTAssertThrowsError(try sync(a).pull(server: nil, vaultID: nil, passphrase: "wrong passphrase!!", force: true)) {
            XCTAssertEqual($0 as? VaultCrypto.CryptoError, .wrongPassphrase)
        }
        XCTAssertEqual(try String(contentsOf: a.url.appendingPathComponent("one.md")), "keep")
    }

    func testServerETagIsStoredAsTheRevisionEverywhere() throws {
        let serverRevision = String(repeating: "ab", count: 32)
        FakeSyncProtocol.etagOverride = serverRevision
        let a = try vault(["one.md": "# shared"])
        let pushed = try sync(a).push(server: server, vaultID: "crm", passphrase: passphrase)
        XCTAssertEqual(pushed.revision, serverRevision)
        XCTAssertEqual(try VaultSync.loadState(a)?.revision, serverRevision)

        let status = try sync(a).status(server: nil, vaultID: nil)
        XCTAssertEqual(status.remoteRevision, serverRevision)
        XCTAssertEqual(status.revision, serverRevision)
        XCTAssertFalse(status.remoteChanged)
        XCTAssertFalse(status.localChanges)

        let b = try vault()
        let pulled = try sync(b).pull(server: server, vaultID: "crm", passphrase: passphrase)
        XCTAssertEqual(pulled.revision, serverRevision)
        XCTAssertEqual(try VaultSync.loadState(b)?.revision, serverRevision)
        XCTAssertEqual(try String(contentsOf: b.url.appendingPathComponent("one.md")), "# shared")
    }

    func testMissingETagFallsBackToTheBlobDigest() throws {
        FakeSyncProtocol.suppressETag = true
        let a = try vault(["one.md": "# shared"])
        let pushed = try sync(a).push(server: server, vaultID: "crm", passphrase: passphrase)
        XCTAssertEqual(pushed.revision, VaultSyncTests.hash(try XCTUnwrap(FakeSyncProtocol.blob)))

        let b = try vault()
        let pulled = try sync(b).pull(server: server, vaultID: "crm", passphrase: passphrase)
        XCTAssertEqual(pulled.revision, pushed.revision)
    }

    func testOnlyADigestETagIsTrustedAsTheRevision() throws {
        // An opaque server tag names a revision of something else; storing it
        // made `status` compare its own digest with a foreign token.
        FakeSyncProtocol.etagOverride = "v17"
        let opaque = try vault(["one.md": "# shared"])
        let pushed = try sync(opaque).push(server: server, vaultID: "crm", passphrase: passphrase)
        XCTAssertEqual(pushed.revision, VaultSyncTests.hash(try XCTUnwrap(FakeSyncProtocol.blob)))

        // A weak validator still carries the digest.
        let digest = String(repeating: "9f", count: 32)
        FakeSyncProtocol.etagOverride = "W/\"\(digest)\""
        let weak = try vault(["one.md": "# shared"])
        let weakPushed = try sync(weak).push(server: server, vaultID: "crm", passphrase: passphrase, force: true)
        XCTAssertEqual(weakPushed.revision, digest)
        XCTAssertEqual(try sync(weak).status(server: nil, vaultID: nil).remoteChanged, false)

        // A hex token of the wrong length is not a SHA-256 either.
        FakeSyncProtocol.etagOverride = String(repeating: "a", count: 40)
        let short = try vault(["one.md": "# shared"])
        let shortPushed = try sync(short).push(server: server, vaultID: "crm", passphrase: passphrase, force: true)
        XCTAssertEqual(shortPushed.revision, VaultSyncTests.hash(try XCTUnwrap(FakeSyncProtocol.blob)))
    }

    func testTransferDeadlineScalesWithTheBodyInsteadOfCappingIt() throws {
        XCTAssertEqual(HTTPDeadline.transfer(expectedBytes: 0, environment: [:]), 180)
        // 64 KiB at 32 KiB/s is 2 s, below the floor.
        XCTAssertEqual(HTTPDeadline.transfer(expectedBytes: 64 * 1024, environment: [:]), 180)
        // A 32 MiB archive needs 1024 s at that rate, so it is not cut off.
        XCTAssertEqual(HTTPDeadline.transfer(expectedBytes: 32 * 1024 * 1024, environment: [:]), 1024)
        // The override raises the floor and the stall guard.
        XCTAssertEqual(HTTPDeadline.transfer(expectedBytes: 0, environment: ["RETEX_SYNC_TIMEOUT_SECONDS": "30"]), 30)
        XCTAssertEqual(HTTPDeadline.idle(environment: [:]), 60)
        XCTAssertEqual(HTTPDeadline.idle(environment: ["RETEX_SYNC_TIMEOUT_SECONDS": "30"]), 60)
        XCTAssertEqual(HTTPDeadline.idle(environment: ["RETEX_SYNC_TIMEOUT_SECONDS": "900"]), 900)
        XCTAssertNil(HTTPDeadline.override(environment: ["RETEX_SYNC_TIMEOUT_SECONDS": "soon"]))

        // Neither session caps a whole transfer at 180 s any more.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 180
        for session in [
            VaultSync.boundedSession(from: configuration),
            UpdateChecker.boundedSession(from: configuration),
        ] {
            XCTAssertEqual(session.configuration.timeoutIntervalForRequest, 60)
            XCTAssertGreaterThan(session.configuration.timeoutIntervalForResource, 180)
        }
    }

    func testRejectsBadTokenInsecureServerAndBadID() throws {
        let a = try vault(["one.md": "x"])
        XCTAssertThrowsError(try sync(a, token: "nope").push(server: server, vaultID: "crm", passphrase: passphrase)) {
            guard case VaultSync.SyncError.server(401, _) = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try VaultSync.validate(server: "http://example.com", vaultID: "crm"))
        XCTAssertNoThrow(try VaultSync.validate(server: "http://localhost:8787", vaultID: "crm"))
        XCTAssertThrowsError(try VaultSync.validate(server: server, vaultID: "../x"))
        XCTAssertThrowsError(try sync(a).pull(server: nil, vaultID: nil, passphrase: passphrase)) {
            XCTAssertEqual($0 as? VaultSync.SyncError, .notConfigured)
        }
    }
}

enum VaultSyncTestsHelper {
    static func sha(_ data: Data) -> String {
        #if canImport(CryptoKit)
        return CryptoKit.SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        return Crypto.SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #endif
    }
}
