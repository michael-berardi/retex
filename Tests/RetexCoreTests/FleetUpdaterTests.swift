import XCTest
@testable import RetexCore

final class FleetUpdaterTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("retex-fleet-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testRegistryCanonicalizesAndPersistsAutoUpdateChoice() throws {
        let vault = root.appendingPathComponent("Vault", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        let registry = FleetRegistry(url: root.appendingPathComponent("config/fleet.json"))

        let registered = try registry.register(path: vault.path, autoUpdate: true)
        XCTAssertEqual(registered.vaults, [FleetVault(path: vault.path, autoUpdate: true)])
        XCTAssertEqual(try registry.load(), registered)
#if !os(Windows)
        let permissions = try FileManager.default.attributesOfItem(atPath: registry.url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
#endif

        let updated = try registry.register(path: vault.path, autoUpdate: false)
        XCTAssertEqual(updated.vaults, [FleetVault(path: vault.path, autoUpdate: false)])
        XCTAssertTrue(try registry.unregister(path: vault.path).vaults.isEmpty)
    }

    func testDeletedVaultDoesNotLockTheRegistry() throws {
        let kept = root.appendingPathComponent("Kept", isDirectory: true)
        let deleted = root.appendingPathComponent("Deleted", isDirectory: true)
        let added = root.appendingPathComponent("Added", isDirectory: true)
        for vault in [kept, deleted, added] {
            try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        }
        let registry = FleetRegistry(url: root.appendingPathComponent("config/fleet.json"))
        try registry.register(path: kept.path, autoUpdate: true)
        try registry.register(path: deleted.path, autoUpdate: true)
        try FileManager.default.removeItem(at: deleted)

        XCTAssertEqual(try registry.load().vaults.map(\.path), [deleted.path, kept.path])
        XCTAssertEqual(try registry.register(path: added.path, autoUpdate: false).vaults.count, 3)
        XCTAssertThrowsError(try FleetUpgradeVerifier().confirmLive(
            vaults: registry.load().vaults,
            executable: root.appendingPathComponent("config/fleet.json")
        )) { error in
            XCTAssertEqual(error as? FleetUpgradeVerifier.VerificationError, .missingVault(deleted.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: deleted.path), "Live confirmation must not recreate it")
        XCTAssertEqual(try registry.unregister(path: deleted.path).vaults.map(\.path), [added.path, kept.path])
        XCTAssertThrowsError(try registry.unregister(path: deleted.path)) { error in
            XCTAssertEqual(error as? FleetRegistry.RegistryError, .missingVault)
        }
    }

    func testRegistryRejectsNonCanonicalStoredPaths() throws {
        let registry = FleetRegistry(url: root.appendingPathComponent("fleet.json"))
        for path in ["relative/vault", "/tmp/../tmp/vault"] {
            try registry.save(FleetRegistryDocument(vaults: [FleetVault(path: path, autoUpdate: true)]))
            XCTAssertThrowsError(try registry.load()) { error in
                XCTAssertEqual(error as? FleetRegistry.RegistryError, .invalidRegistry)
            }
        }
    }

#if !os(Windows)
    func testVerifierReportsMissingVaultClearly() throws {
        let missing = root.appendingPathComponent("Gone", isDirectory: true)
        let current = try fakeRetex(named: "current", list: "{}\n")
        XCTAssertThrowsError(try FleetUpgradeVerifier().verify(
            vaults: [FleetVault(path: missing.path, autoUpdate: true)],
            candidate: current,
            current: current
        )) { error in
            XCTAssertEqual(error as? FleetUpgradeVerifier.VerificationError, .missingVault(missing.path))
        }
    }

    func testVerifierClonesArePrivateAndAcceptResolvedClonePaths() throws {
        let vault = root.appendingPathComponent("Vault", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        try "# Original".write(to: vault.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
        // A temporary root reached through a symlink, as with a symlinked TMPDIR.
        let realTemporary = root.appendingPathComponent("real-tmp", isDirectory: true)
        let linkedTemporary = root.appendingPathComponent("linked-tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: realTemporary, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedTemporary, withDestinationURL: realTemporary)
        let fake = try fakeRetex(named: "resolving", list: "{}\n", resolveClonePath: true)

        let reports = try FleetUpgradeVerifier(temporaryRoot: linkedTemporary).verify(
            vaults: [FleetVault(path: vault.path, autoUpdate: true)],
            candidate: fake,
            current: fake
        )
        XCTAssertEqual(reports.map(\.mutationRoundTrip), [true])
        let listing = try String(contentsOf: root.appendingPathComponent("resolving-clone-mode"), encoding: .utf8)
        XCTAssertTrue(listing.hasPrefix("drwx------"), listing)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: realTemporary.path), [])
    }

    func testVerifierUsesClonesAndRequiresExactCompatibility() throws {
        let vault = root.appendingPathComponent("Vault", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        try "# Original".write(to: vault.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
        let current = try fakeRetex(named: "current", list: "{\"notes\":[\"note.md\"]}\n")
        let candidate = try fakeRetex(named: "candidate", list: "{ \"notes\" : [ \"note.md\" ] }\n")

        let reports = try FleetUpgradeVerifier().verify(
            vaults: [FleetVault(path: vault.path, autoUpdate: true)],
            candidate: candidate,
            current: current
        )
        XCTAssertEqual(reports.count, 1)
        XCTAssertTrue(reports[0].verified)
        XCTAssertTrue(reports[0].exactListMatch)
        XCTAssertTrue(reports[0].exactSearchMatch)
        XCTAssertTrue(reports[0].exactBoardMatch)
        XCTAssertTrue(reports[0].mutationRoundTrip)
        XCTAssertTrue(reports[0].previousVersionReadable)
        XCTAssertEqual(try String(contentsOf: vault.appendingPathComponent("note.md"), encoding: .utf8), "# Original")

        let incompatible = try fakeRetex(named: "incompatible", list: "{\"notes\":[]}\n")
        XCTAssertThrowsError(try FleetUpgradeVerifier().verify(
            vaults: [FleetVault(path: vault.path, autoUpdate: true)],
            candidate: incompatible,
            current: current
        ))
    }

    private func fakeRetex(named name: String, list: String, resolveClonePath: Bool = false) throws -> URL {
        let executable = root.appendingPathComponent(name)
        // The real CLI may report the clone through its resolved path.
        let createRoot = resolveClonePath ? "$(cd \"$3\" && pwd -P)" : "$3"
        let script = """
        #!/bin/sh
        case "$1" in
          init) ls -ld "$3" > "\(root.path)/\(name)-clone-mode"; mkdir -p "$3/.retex"; printf '{"ok":true}\n' ;;
          doctor) printf '{"ok":true}\n' ;;
          list) printf '%s' '\(list)' ;;
          search) printf '{"data":[],"ok":true,"schema_version":1}\n' ;;
          board) printf '{"columns":[]}\n' ;;
          create) path="\(createRoot)/RetexFleetProbe/probe.md"; mkdir -p "$(dirname "$path")"; printf '# Probe\n' > "$path"; printf '{"data":{"path":"%s"},"ok":true,"schema_version":1}\n' "$path" ;;
          set|move|archive|undo|show) printf '{"ok":true}\n' ;;
          *) exit 64 ;;
        esac
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }
#endif
}
