import XCTest
#if canImport(CommonCrypto)
import CommonCrypto
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
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

        // The public entry point refuses a non-empty destination outright.
        XCTAssertThrowsError(try VaultCrypto.restoreArchive(malicious, into: out)) { error in
            XCTAssertEqual(error as? VaultCrypto.CryptoError, .destinationNotEmpty)
        }
        // The symlink confinement still holds on its own.
        XCTAssertThrowsError(try VaultCrypto.restoreArchive(malicious, into: out, requireEmptyDestination: false))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("escape.md").path))
    }

    func testRestoreDoesNotCreateDirectoriesThroughSymlinkedParent() throws {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-symlink-mkdir-\(UUID().uuidString)", isDirectory: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-symlink-mkdir-outside-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: out)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: out.appendingPathComponent("linked"), withDestinationURL: outside)
        let malicious = try JSONEncoder().encode([
            VaultCrypto.ArchivedFile(path: "linked/created/deeper/escape.md", content: "pwn"),
        ])

        XCTAssertThrowsError(try VaultCrypto.restoreArchive(malicious, into: out, requireEmptyDestination: false))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("created").path))
    }

    func testRestoreRefusesHiddenNonPortableAndAliasedPaths() throws {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-hidden-restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: out) }

        for paths in [
            [".git/config.json"],
            [".retex/state.json"],
            ["notes/.hidden.md"],
            ["hooks/post-checkout"],
            ["script.sh"],
            ["a/./b.md", "a//b.md"],
        ] {
            XCTAssertThrowsError(try VaultCrypto.restoreArchive(try archive(paths: paths), into: out), "\(paths)") { error in
                XCTAssertEqual(error as? VaultCrypto.CryptoError, .invalidArchive, "\(paths)")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent(".git").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent(".retex").path))
        }
        XCTAssertEqual(try VaultCrypto.restoreArchive(try archive(paths: ["a/./b.md", "c.json"]), into: out), 2)
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("a/b.md"), encoding: .utf8), "content 0")
    }

    func testRestoreRequiresNewOrEmptyDestination() throws {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-nonempty-restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: out) }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let data = try archive(paths: ["note.md"])

        XCTAssertEqual(try VaultCrypto.restoreArchive(data, into: out), 1)
        XCTAssertThrowsError(try VaultCrypto.restoreArchive(data, into: out)) { error in
            XCTAssertEqual(error as? VaultCrypto.CryptoError, .destinationNotEmpty)
        }
    }

    /// Builds a genuine version 2 archive, then rewrites its entry paths.
    private func archive(paths: [String]) throws -> Data {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-crafted-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: source) }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for index in paths.indices {
            try "content \(index)".write(to: source.appendingPathComponent("f\(index).md"), atomically: true, encoding: .utf8)
        }
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: VaultCrypto.makeArchive(vaultURL: source)) as? [String: Any])
        var files = try XCTUnwrap(envelope["files"] as? [[String: Any]])
        for index in files.indices { files[index]["path"] = paths[index] }
        envelope["files"] = files
        return try JSONSerialization.data(withJSONObject: envelope)
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

    func testArchiveSkipsSymlinksAsDocumented() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-export-outside-\(UUID().uuidString).md")
        let link = vaultDir.appendingPathComponent("outside.md")
        try "protected".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(
            at: vaultDir.appendingPathComponent("inside-link.md"),
            withDestinationURL: vaultDir.appendingPathComponent("deep/sub/note.md")
        )
        defer { try? FileManager.default.removeItem(at: outside) }

        var skipped: [String] = []
        let archive = try VaultCrypto.makeArchive(vaultURL: vaultDir) { skipped.append($0.lastPathComponent) }
        XCTAssertEqual(skipped.sorted(), ["inside-link.md", "outside.md"])
        XCTAssertFalse(String(decoding: archive, as: UTF8.self).contains("outside.md"))
        XCTAssertFalse(String(decoding: archive, as: UTF8.self).contains("inside-link.md"))
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-symlink-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: out) }
        XCTAssertEqual(try VaultCrypto.restoreArchive(archive, into: out), 3)
    }

    // MARK: - Staged mirroring

    func testMirrorArchiveSwapsFilesAndRemovesObsoleteOnes() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-mirror-source-\(UUID().uuidString)", isDirectory: true)
        let live = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-mirror-live-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: live)
        }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        try "# new".write(to: source.appendingPathComponent("new.md"), atomically: true, encoding: .utf8)
        try "# keep".write(to: live.appendingPathComponent("keep.md"), atomically: true, encoding: .utf8)
        try "# old".write(to: live.appendingPathComponent("old.md"), atomically: true, encoding: .utf8)

        let outcome = try VaultCrypto.mirrorArchive(try VaultCrypto.makeArchive(vaultURL: source), into: live)

        XCTAssertEqual(outcome.written, 1)
        XCTAssertEqual(outcome.removed, 2)
        XCTAssertEqual(try String(contentsOf: live.appendingPathComponent("new.md"), encoding: .utf8), "# new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: live.appendingPathComponent("old.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: live.appendingPathComponent("keep.md").path))
    }

    func testMirrorArchiveRollsBackWhenAWriteFails() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-mirror-fail-source-\(UUID().uuidString)", isDirectory: true)
        let live = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-mirror-fail-live-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: live)
        }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        // Sorted install order: a-keep.md first, so the originals are replaced
        // before the failure hits z-blocker.md.
        try "# replacement".write(to: source.appendingPathComponent("a-keep.md"), atomically: true, encoding: .utf8)
        try "# fresh".write(to: source.appendingPathComponent("b-fresh.md"), atomically: true, encoding: .utf8)
        try "# blocker".write(to: source.appendingPathComponent("z-blocker.md"), atomically: true, encoding: .utf8)
        try "# original".write(to: live.appendingPathComponent("a-keep.md"), atomically: true, encoding: .utf8)
        try "# untouched".write(to: live.appendingPathComponent("c-obsolete.md"), atomically: true, encoding: .utf8)
        // A directory where the archive wants a file makes the swap fail after
        // a successful install, which is exactly the rollback path.
        try FileManager.default.createDirectory(
            at: live.appendingPathComponent("z-blocker.md"),
            withIntermediateDirectories: true
        )
        try "# inner".write(
            to: live.appendingPathComponent("z-blocker.md/inner.md"),
            atomically: true,
            encoding: .utf8
        )
        let archive = try VaultCrypto.makeArchive(vaultURL: source)

        XCTAssertThrowsError(try VaultCrypto.mirrorArchive(archive, into: live))
        // Every original is still in place and nothing the archive created and
        // later abandoned is left behind.
        XCTAssertEqual(try String(contentsOf: live.appendingPathComponent("a-keep.md"), encoding: .utf8), "# original")
        XCTAssertEqual(try String(contentsOf: live.appendingPathComponent("c-obsolete.md"), encoding: .utf8), "# untouched")
        XCTAssertEqual(
            try String(contentsOf: live.appendingPathComponent("z-blocker.md/inner.md"), encoding: .utf8),
            "# inner"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: live.appendingPathComponent("b-fresh.md").path))
        XCTAssertEqual(try mirrorStagingDirectories(in: live), [])
    }

    func testMirrorArchiveRefusesToInstallThroughASymlinkedDirectory() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-mirror-link-source-\(UUID().uuidString)", isDirectory: true)
        let live = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-mirror-link-live-\(UUID().uuidString)", isDirectory: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-mirror-link-outside-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: live)
            try? FileManager.default.removeItem(at: outside)
        }
        for dir in [source, live, outside] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("Shared"),
            withIntermediateDirectories: true
        )
        try "# inside".write(to: source.appendingPathComponent("a-inside.md"), atomically: true, encoding: .utf8)
        try "# escaped".write(to: source.appendingPathComponent("Shared/escaped.md"), atomically: true, encoding: .utf8)
        try "# original".write(to: live.appendingPathComponent("a-inside.md"), atomically: true, encoding: .utf8)
        // A vault subdirectory that points outside the vault must never be a
        // way for a pulled archive to write there.
        try FileManager.default.createSymbolicLink(
            at: live.appendingPathComponent("Shared"),
            withDestinationURL: outside
        )
        let archive = try VaultCrypto.makeArchive(vaultURL: source)

        XCTAssertThrowsError(try VaultCrypto.mirrorArchive(archive, into: live)) { error in
            switch error as? StoreError {
            case .pathOutsideVault(let url):
                XCTAssertEqual(url.pathComponents.suffix(2), ["Shared", "escaped.md"])
            default:
                XCTFail("unexpected error \(error)")
            }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
        XCTAssertEqual(try String(contentsOf: live.appendingPathComponent("a-inside.md"), encoding: .utf8), "# original")
    }

    func testMirrorArchiveRefusesToStageThroughASymlinkedStateDirectory() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-mirror-state-source-\(UUID().uuidString)", isDirectory: true)
        let live = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-mirror-state-live-\(UUID().uuidString)", isDirectory: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-mirror-state-outside-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: live)
            try? FileManager.default.removeItem(at: outside)
        }
        for dir in [source, live, outside] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try "# a".write(to: source.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: live.appendingPathComponent(VaultCrypto.stateDirectoryName),
            withDestinationURL: outside
        )
        let archive = try VaultCrypto.makeArchive(vaultURL: source)

        XCTAssertThrowsError(try VaultCrypto.mirrorArchive(archive, into: live))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: live.appendingPathComponent("a.md").path))
    }

    func testMirrorArchiveStagesInsideTheVaultSoAReadOnlyParentStillPulls() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-mirror-ro-parent-\(UUID().uuidString)", isDirectory: true)
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-mirror-ro-source-\(UUID().uuidString)", isDirectory: true)
        let live = parent.appendingPathComponent("vault", isDirectory: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)
            try? FileManager.default.removeItem(at: parent)
            try? FileManager.default.removeItem(at: source)
        }
        for dir in [source, live] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try "# pulled".write(to: source.appendingPathComponent("pulled.md"), atomically: true, encoding: .utf8)
        try "# stale".write(to: live.appendingPathComponent("stale.md"), atomically: true, encoding: .utf8)
        let archive = try VaultCrypto.makeArchive(vaultURL: source)
        // A vault on a mount point or under a read-only parent directory is
        // normal (an app-managed folder); a pull must not need to write there.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path)

        let outcome = try VaultCrypto.mirrorArchive(archive, into: live)

        XCTAssertEqual(outcome.written, 1)
        XCTAssertEqual(outcome.removed, 1)
        XCTAssertEqual(try String(contentsOf: live.appendingPathComponent("pulled.md"), encoding: .utf8), "# pulled")
        XCTAssertFalse(FileManager.default.fileExists(atPath: live.appendingPathComponent("stale.md").path))
    }

    func testMirrorArchiveDrawsASuccessfulRollbackWithoutLeavingAStash() {
        let live = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-mirror-rollback-\(UUID().uuidString).md")
        let stash = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-mirror-rollback-stash-\(UUID().uuidString).md")
        defer {
            try? FileManager.default.removeItem(at: live)
            try? FileManager.default.removeItem(at: stash)
        }
        try? "# new".write(to: live, atomically: true, encoding: .utf8)
        try? "# old".write(to: stash, atomically: true, encoding: .utf8)

        XCTAssertNil(VaultCrypto.rollBack([(live: live, stash: stash)]))
        XCTAssertEqual(try? String(contentsOf: live, encoding: .utf8), "# old")
    }

    func testMirrorArchiveNamesTheStashWhenARollbackStepFails() throws {
        let live = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-mirror-rollback-fail-\(UUID().uuidString).md")
        let stash = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-mirror-rollback-fail-stash-\(UUID().uuidString).md")
        defer {
            try? FileManager.default.removeItem(at: live)
            try? FileManager.default.removeItem(at: stash)
        }
        let reason = VaultCrypto.rollBack(
            [
                (live: live, stash: stash),
                (live: live.appendingPathExtension("created"), stash: nil),
            ],
            restore: { _, _ in throw VaultCrypto.CryptoError.mirrorFailed(path: live.path, reason: "injected") },
            remove: { _ in }
        )
        let reported = try XCTUnwrap(reason)
        XCTAssertTrue(reported.contains(live.path), reported)
        XCTAssertTrue(reported.contains("injected"), reported)
    }

    func testMirrorStagingIsNeverEnumeratedOrArchived() throws {
        // Everything the mirror writes lives in the hidden state directory, so
        // neither vault enumeration nor an export can pick it up mid-pull.
        let staging = vaultDir
            .appendingPathComponent(VaultCrypto.stateDirectoryName, isDirectory: true)
            .appendingPathComponent("mirror-test/new", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try "# staged".write(to: staging.appendingPathComponent("staged.md"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: vaultDir.appendingPathComponent(VaultCrypto.stateDirectoryName)) }

        let archive = try VaultCrypto.makeArchive(vaultURL: vaultDir)
        XCTAssertFalse(String(decoding: archive, as: UTF8.self).contains("staged.md"))
        XCTAssertFalse(try VaultCrypto.portableFilePaths(vaultURL: vaultDir).contains { $0.contains("mirror-test") })
        XCTAssertFalse(
            try MarkdownStore().scan(Vault(url: vaultDir)).contains { $0.id.contains("mirror-test") }
        )
    }

    /// Staging trees the mirror leaves behind in the vault's state directory.
    private func mirrorStagingDirectories(in vault: URL) throws -> [String] {
        let stateDir = vault.appendingPathComponent(VaultCrypto.stateDirectoryName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: stateDir.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: stateDir.path).filter { $0.hasPrefix("mirror-") }
    }

    func testOversizedFileErrorNamesThePathAndSize() throws {
        let limit = 64 * 1024 * 1024
        let oversized = vaultDir.appendingPathComponent("big.png")
        FileManager.default.createFile(atPath: oversized.path, contents: nil)
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: UInt64(limit + 1))
        try handle.close()

        XCTAssertThrowsError(try VaultCrypto.makeArchive(vaultURL: vaultDir)) { error in
            guard case let VaultCrypto.CryptoError.fileTooLarge(path, bytes, reportedLimit) = error else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(path, "big.png")
            XCTAssertEqual(bytes, limit + 1)
            XCTAssertEqual(reportedLimit, limit)
            XCTAssertTrue(error.localizedDescription.contains("big.png"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("\(limit + 1)"), error.localizedDescription)
        }
    }

    // MARK: - Key derivation

    func testFastPBKDF2FallbackMatchesTheReferenceLoop() {
        let salt = Array("salted-example-value".utf8)
        let passphrase = "correct horse battery staple"
        let fast = VaultCrypto.deriveKeyFallback(passphrase: passphrase, salt: salt, iterations: 64)
        XCTAssertEqual(fast, Self.referencePBKDF2(passphrase: passphrase, salt: salt, iterations: 64))
        XCTAssertEqual(fast.count, 32)
    }

    #if canImport(CommonCrypto)
    func testPBKDF2FallbackMatchesCommonCryptoByteForByte() {
        let salt = Array("salted-example-value".utf8)
        let passphrase = "correct horse battery staple"
        let iterations: UInt32 = 1_000
        let fast = VaultCrypto.deriveKeyFallback(passphrase: passphrase, salt: salt, iterations: Int(iterations))
        var expected = Data(repeating: 0, count: 32)
        let status = expected.withUnsafeMutableBytes { (derived: UnsafeMutableRawBufferPointer) -> Int32 in
            passphrase.withCString { password in
                salt.withUnsafeBufferPointer { saltPointer in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        password,
                        strlen(password),
                        saltPointer.baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        iterations,
                        derived.bindMemory(to: UInt8.self).baseAddress,
                        32
                    )
                }
            }
        }
        XCTAssertEqual(status, Int32(kCCSuccess))
        XCTAssertEqual(Data(fast), expected)
    }
    #endif

    /// The straightforward PBKDF2 loop, kept as the byte-for-byte reference
    /// for the allocation-free implementation.
    private static func referencePBKDF2(passphrase: String, salt: [UInt8], iterations: Int) -> [UInt8] {
        let passwordKey = SymmetricKey(data: Data(passphrase.utf8))
        var block = Data(salt)
        block.append(contentsOf: [0, 0, 0, 1])
        var previous = Data(HMAC<SHA256>.authenticationCode(for: block, using: passwordKey))
        var derived = previous
        for _ in 1..<iterations {
            previous = Data(HMAC<SHA256>.authenticationCode(for: previous, using: passwordKey))
            for index in derived.indices { derived[index] ^= previous[index] }
        }
        return [UInt8](derived)
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
