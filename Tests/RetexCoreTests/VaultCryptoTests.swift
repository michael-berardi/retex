import XCTest
@testable import RetexCore

final class VaultCryptoTests: XCTestCase {
    private var vaultDir: URL!

    override func setUpWithError() throws {
        vaultDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-crypto-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: vaultDir, withIntermediateDirectories: true)
        let store = MarkdownStore()
        _ = try store.createNote(in: Vault(url: vaultDir), folder: "Deals",
                                 title: "Secret Deal", metadata: ["type": "deal"], body: "confidential")
        try FileManager.default.createDirectory(at: vaultDir.appendingPathComponent("deep/sub"), withIntermediateDirectories: true)
        try "nested".write(to: vaultDir.appendingPathComponent("deep/sub/note.md"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: vaultDir)
    }

    func testEncryptDecryptRoundtrip() throws {
        let crypto = VaultCrypto()
        let archive = try VaultCrypto.makeArchive(vaultURL: vaultDir)
        let blob = try crypto.encrypt(archive, passphrase: "hunter2 example")

        XCTAssertTrue(blob.prefix(9) == Data("RETEXENC1".utf8))
        XCTAssertFalse(String(decoding: blob, as: UTF8.self).contains("confidential"),
                       "Plaintext must never appear in the encrypted blob")

        let restored = try crypto.decrypt(blob, passphrase: "hunter2 example")
        XCTAssertEqual(restored, archive)

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-crypto-restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: out) }
        let count = try VaultCrypto.restoreArchive(restored, into: out)
        XCTAssertEqual(count, 2, "Root note plus nested note")
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("Deals/secret-deal.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("deep/sub/note.md").path))
    }

    func testWrongPassphraseFailsCleanly() throws {
        let crypto = VaultCrypto()
        let archive = try VaultCrypto.makeArchive(vaultURL: vaultDir)
        let blob = try crypto.encrypt(archive, passphrase: "right")
        XCTAssertThrowsError(try crypto.decrypt(blob, passphrase: "wrong")) { error in
            XCTAssertEqual(error as? VaultCrypto.CryptoError, .wrongPassphrase)
        }
    }

    func testNonRetexFileIsRejected() throws {
        let crypto = VaultCrypto()
        XCTAssertThrowsError(try crypto.decrypt(Data("hello world".utf8), passphrase: "x")) { error in
            XCTAssertEqual(error as? VaultCrypto.CryptoError, .badFormat)
        }
    }

    func testRestoreRefusesPathTraversal() throws {
        let malicious = try JSONEncoder().encode([
            VaultCrypto.ArchivedFile(path: "../../escape.md", content: "pwn"),
        ])
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-traversal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: out) }
        XCTAssertThrowsError(try VaultCrypto.restoreArchive(malicious, into: out))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: out.deletingLastPathComponent().appendingPathComponent("escape.md").path
        ))
    }
}

final class UpdateCheckerTests: XCTestCase {
    func testVersionComparison() {
        XCTAssertTrue(UpdateChecker.isNewer(releaseTag: "v0.3.0", current: "0.2.0"))
        XCTAssertTrue(UpdateChecker.isNewer(releaseTag: "v1.0", current: "0.9.9"))
        XCTAssertFalse(UpdateChecker.isNewer(releaseTag: "v0.2.0", current: "0.2.0"))
        XCTAssertFalse(UpdateChecker.isNewer(releaseTag: "v0.1.0", current: "0.2.0"))
    }

    func testChecksumExtraction() {
        let sums = """
        abcdef0123456789  retex-universal.zip
        1111222233334444  other-file.zip
        """
        XCTAssertEqual(
            UpdateChecker.expectedChecksum(in: sums, assetName: "retex-universal.zip"),
            "abcdef0123456789"
        )
        XCTAssertNil(UpdateChecker.expectedChecksum(in: sums, assetName: "missing.tar.gz"))
    }
}
