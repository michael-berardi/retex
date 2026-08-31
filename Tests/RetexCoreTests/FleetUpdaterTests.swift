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

#if !os(Windows)
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

    private func fakeRetex(named name: String, list: String) throws -> URL {
        let executable = root.appendingPathComponent(name)
        let script = """
        #!/bin/sh
        case "$1" in
          init) mkdir -p "$3/.retex"; printf '{"ok":true}\n' ;;
          doctor) printf '{"ok":true}\n' ;;
          list) printf '%s' '\(list)' ;;
          search) printf '{"data":[],"ok":true,"schema_version":1}\n' ;;
          board) printf '{"columns":[]}\n' ;;
          create) path="$3/RetexFleetProbe/probe.md"; mkdir -p "$(dirname "$path")"; printf '# Probe\n' > "$path"; printf '{"data":{"path":"%s"},"ok":true,"schema_version":1}\n' "$path" ;;
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
