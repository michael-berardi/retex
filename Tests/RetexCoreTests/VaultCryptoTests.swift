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
        try Data([0, 1, 2, 255]).write(to: vaultDir.appendingPathComponent("deep/sub/attachment.png"))
        try "const secret = true".write(to: vaultDir.appendingPathComponent("deep/sub/source.ts"), atomically: true, encoding: .utf8)
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
        XCTAssertEqual(count, 3, "Two Markdown notes plus one attachment")
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("Deals/secret-deal.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("deep/sub/note.md").path))
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("deep/sub/attachment.png")), Data([0, 1, 2, 255]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("deep/sub/source.ts").path))
    }

    func testWrongPassphraseFailsCleanly() throws {
        let crypto = VaultCrypto()
        let archive = try VaultCrypto.makeArchive(vaultURL: vaultDir)
        let blob = try crypto.encrypt(archive, passphrase: "correct horse battery staple")
        XCTAssertThrowsError(try crypto.decrypt(blob, passphrase: "wrong but long enough")) { error in
            XCTAssertEqual(error as? VaultCrypto.CryptoError, .wrongPassphrase)
        }
    }

    func testExportRejectsWeakPassphrases() throws {
        XCTAssertThrowsError(try VaultCrypto().encrypt(Data("secret".utf8), passphrase: "short")) { error in
            XCTAssertEqual(error as? VaultCrypto.CryptoError, .weakPassphrase)
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

    func testRestoreRefusesSymlinkParentEscape() throws {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-symlink-restore-\(UUID().uuidString)", isDirectory: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-symlink-outside-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: out)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: out.appendingPathComponent("linked"),
            withDestinationURL: outside
        )
        let malicious = try JSONEncoder().encode([
            VaultCrypto.ArchivedFile(path: "linked/escape.md", content: "pwn"),
        ])

        XCTAssertThrowsError(try VaultCrypto.restoreArchive(malicious, into: out))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("escape.md").path))
    }

    func testRestoreRefusesNonMarkdownAndDuplicateEntries() throws {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-invalid-restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: out) }

        let nonMarkdown = try JSONEncoder().encode([
            VaultCrypto.ArchivedFile(path: "config.json", content: "{}"),
        ])
        XCTAssertThrowsError(try VaultCrypto.restoreArchive(nonMarkdown, into: out))

        let duplicate = try JSONEncoder().encode([
            VaultCrypto.ArchivedFile(path: "same.md", content: "first"),
            VaultCrypto.ArchivedFile(path: "same.md", content: "second"),
        ])
        XCTAssertThrowsError(try VaultCrypto.restoreArchive(duplicate, into: out))
    }

    func testArchiveRefusesSymlinksOutsideVault() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-export-outside-\(UUID().uuidString).md")
        let link = vaultDir.appendingPathComponent("outside.md")
        try "protected".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        XCTAssertThrowsError(try VaultCrypto.makeArchive(vaultURL: vaultDir))
    }
}

final class UpdateCheckerTests: XCTestCase {
    func testVersionComparison() {
        XCTAssertTrue(UpdateChecker.isNewer(releaseTag: "v0.5.0", current: "0.4.4"))
        XCTAssertTrue(UpdateChecker.isNewer(releaseTag: "v1.0.0", current: "0.9.9"))
        XCTAssertFalse(UpdateChecker.isNewer(releaseTag: "v0.4.4", current: "0.4.4"))
        XCTAssertFalse(UpdateChecker.isNewer(releaseTag: "v0.4.3", current: "0.4.4"))
        XCTAssertFalse(UpdateChecker.isNewer(releaseTag: "v0.5.0-beta", current: "0.4.4"))
        XCTAssertFalse(UpdateChecker.isNewer(releaseTag: "latest", current: "0.4.4"))
    }

    func testChecksumExtractionRequiresExactAssetAndSHA256() {
        let hash = String(repeating: "a", count: 64)
        let sums = """
        \(hash)  retex-universal.zip
        \(String(repeating: "b", count: 64))  other-file.zip
        """
        XCTAssertEqual(
            UpdateChecker.expectedChecksum(in: sums, assetName: "retex-universal.zip"),
            hash
        )
        XCTAssertNil(UpdateChecker.expectedChecksum(
            in: "\(hash)  retex-universal.zip.evil",
            assetName: "retex-universal.zip"
        ))
        XCTAssertNil(UpdateChecker.expectedChecksum(
            in: "abcdef  retex-universal.zip",
            assetName: "retex-universal.zip"
        ))
    }

    func testInstallKeepsPreviousExecutableAsRollback() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-install-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("retex")
        let candidate = directory.appendingPathComponent("candidate")
        try "old".write(to: executable, atomically: true, encoding: .utf8)
        try "new".write(to: candidate, atomically: true, encoding: .utf8)

        let previous = try UpdateChecker.install(candidate: candidate, over: executable)

        XCTAssertEqual(try String(contentsOf: executable, encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOf: previous, encoding: .utf8), "old")
    }

    #if !os(Windows)
    func testInstallThroughSymlinkUpdatesCanonicalExecutableAndKeepsLink() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-install-link-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("retex")
        let link = directory.appendingPathComponent("retex-link")
        let candidate = directory.appendingPathComponent("candidate")
        try "old".write(to: executable, atomically: true, encoding: .utf8)
        try "new".write(to: candidate, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)

        let previous = try UpdateChecker.install(candidate: candidate, over: link)

        XCTAssertEqual(try String(contentsOf: executable, encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOf: previous, encoding: .utf8), "old")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), executable.path)
    }
    #endif
}
