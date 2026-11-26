#if canImport(CommonCrypto)
import CommonCrypto
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Passphrase-encrypted vault export/import.
///
/// Format: `RETEXENC1` magic + salt (16B) + nonce (12B) + AES-GCM ciphertext.
/// The key is derived from the passphrase with PBKDF2-HMAC-SHA256 (600,000
/// iterations). Sync the resulting file over any channel (iCloud, Dropbox,
/// git) — the vault contents are opaque to every intermediary.
public struct VaultCrypto {
    private static let magic = Data("RETEXENC1".utf8)
    private static let saltLength = 16
    private static let iterations = 600_000

    public init() {}

    public enum CryptoError: LocalizedError, Equatable {
        case badFormat
        case wrongPassphrase
        case keyDerivationFailed
        case invalidArchive
        case weakPassphrase
        case destinationNotEmpty
        /// One archive member is larger than the 64 MiB per-file limit.
        case fileTooLarge(path: String, bytes: Int, limit: Int)
        /// The archive as a whole is larger than the 1 GiB limit.
        case archiveTooLarge(path: String, bytes: Int, limit: Int)
        /// One archive member could not be installed into the vault.
        case mirrorFailed(path: String, reason: String)
        /// A failed pull could not be undone, so the previous vault files stay
        /// in the named stash.
        case mirrorRollbackFailed(stash: String, reason: String)

        public var errorDescription: String? {
            switch self {
            case .badFormat: "Not a Retex encrypted export (missing RETEXENC1 header)."
            case .wrongPassphrase: "Decryption failed: wrong passphrase or corrupted file."
            case .keyDerivationFailed: "Passphrase key derivation failed."
            case .invalidArchive: "Retex archive manifest, checksum, path, or size validation failed."
            case .weakPassphrase: "Export passphrase must contain at least 12 characters."
            case .destinationNotEmpty: "Restore destination must be new or empty."
            case let .fileTooLarge(path, bytes, limit):
                "Retex archive file \(path) is \(bytes) bytes, which exceeds the \(limit)-byte per-file limit."
            case let .archiveTooLarge(path, bytes, limit):
                "Retex archive exceeds the \(limit)-byte archive limit: \(path) brings it to \(bytes) bytes."
            case let .mirrorFailed(path, reason):
                "Retex could not install \(path) from the archive: \(reason)"
            case let .mirrorRollbackFailed(stash, reason):
                "Retex could not restore the vault after a failed pull (\(reason)). "
                    + "The previous files are preserved in \(stash)."
            }
        }
    }

    // MARK: - Vault archive

    struct ArchivedFile: Codable {
        let path: String
        let content: String
    }

    private struct ArchiveEnvelope: Codable {
        let version: Int
        let files: [ArchiveEntry]
    }

    private struct ArchiveEntry: Codable {
        let path: String
        let data: Data
        let sha256: String
    }

    /// A portable file discovered during the single vault walk.
    private struct PortableFile {
        let relativePath: String
        let data: Data
        let sha256: String
    }

    /// An archive member after path, size, and checksum validation.
    private struct ValidatedEntry {
        let relativePath: String
        let data: Data
        let sha256: String
    }

    private static let maximumFileBytes = 64 * 1024 * 1024
    private static let maximumArchiveBytes = 1024 * 1024 * 1024
    private static let portableVaultExtensions: Set<String> = [
        "md", "markdown", "txt", "csv", "json", "canvas", "excalidraw",
        "pdf", "png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "tiff", "heic", "avif",
        "mp3", "m4a", "wav", "flac", "ogg", "mp4", "mov", "webm",
        "doc", "docx", "xls", "xlsx", "ppt", "pptx", "zip",
    ]

    /// One enumeration of the portable vault files, sorted by relative path.
    /// Callers that need an archive *and* its digest reuse this single walk
    /// instead of re-enumerating and re-hashing the vault.
    private static func portableFiles(
        vaultURL: URL,
        skippedSymlink: ((URL) -> Void)? = nil
    ) throws -> [PortableFile] {
        let lexicalRoot = vaultURL.standardizedFileURL
        let resolvedRoot = lexicalRoot.resolvingSymlinksInPath()
        guard let enumerator = FileManager.default.enumerator(
            at: lexicalRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw StoreError.unreadableVault(vaultURL)
        }

        var files: [PortableFile] = []
        var totalBytes = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            if values.isSymbolicLink == true {
                skippedSymlink?(url)
                continue
            }
            guard values.isRegularFile == true else { continue }
            guard portableVaultExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let relative = url.standardizedFileURL.pathComponents
                .dropFirst(lexicalRoot.pathComponents.count)
                .joined(separator: "/")
            let size = values.fileSize ?? 0
            guard size <= maximumFileBytes else {
                throw CryptoError.fileTooLarge(path: relative, bytes: size, limit: maximumFileBytes)
            }
            totalBytes += size
            guard totalBytes <= maximumArchiveBytes else {
                throw CryptoError.archiveTooLarge(path: relative, bytes: totalBytes, limit: maximumArchiveBytes)
            }
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            guard isWithinVault(resolved, root: resolvedRoot) else {
                throw StoreError.pathOutsideVault(url)
            }
            let data = try Data(contentsOf: resolved, options: [.mappedIfSafe])
            files.append(PortableFile(relativePath: relative, data: data, sha256: sha256(data)))
        }
        files.sort { $0.relativePath < $1.relativePath }
        return files
    }

    /// Collects portable, non-hidden vault documents and attachments. Retex
    /// state, source code, VCS/editor state, symlinks, and packages are excluded.
    /// `skippedSymlink` receives each symlink left out, so callers can report
    /// the omission instead of producing a silently incomplete backup.
    public static func makeArchive(vaultURL: URL, skippedSymlink: ((URL) -> Void)? = nil) throws -> Data {
        try encodeArchive(portableFiles(vaultURL: vaultURL, skippedSymlink: skippedSymlink))
    }

    private static func encodeArchive(_ files: [PortableFile]) throws -> Data {
        try JSONEncoder().encode(ArchiveEnvelope(
            version: 2,
            files: files.map { ArchiveEntry(path: $0.relativePath, data: $0.data, sha256: $0.sha256) }
        ))
    }

    /// Relative paths of every portable file `makeArchive` would include.
    public static func portableFilePaths(vaultURL: URL) throws -> [String] {
        let root = vaultURL.standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { throw StoreError.unreadableVault(vaultURL) }
        var paths: [String] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true,
                  portableVaultExtensions.contains(url.pathExtension.lowercased()) else { continue }
            paths.append(url.standardizedFileURL.pathComponents
                .dropFirst(root.pathComponents.count).joined(separator: "/"))
        }
        return paths.sorted()
    }

    /// Stable digest of the portable file set (paths plus content hashes).
    /// The hash is fed incrementally so no intermediate `String` is built.
    public static func contentDigest(vaultURL: URL) throws -> String {
        digest(files: try portableFiles(vaultURL: vaultURL))
    }

    private static func digest(files: [PortableFile]) -> String {
        var hasher = SHA256()
        for file in files {
            hasher.update(data: Data("\(file.sha256)  \(file.relativePath)\n".utf8))
        }
        return hex(hasher.finalize())
    }

    /// Archive bytes, content digest, and file count from one vault walk.
    struct VaultSnapshot {
        let archive: Data
        let digest: String
        let fileCount: Int
    }

    static func snapshot(vaultURL: URL) throws -> VaultSnapshot {
        let files = try portableFiles(vaultURL: vaultURL)
        return VaultSnapshot(
            archive: try encodeArchive(files),
            digest: digest(files: files),
            fileCount: files.count
        )
    }

    // MARK: - Mirroring

    /// Makes `dir` match the archive: writes every archived file and removes
    /// portable files the archive does not contain (remote deletions).
    ///
    /// Nothing in the live vault is touched until the whole archive has been
    /// restored and verified in a staging directory under the vault's own
    /// `.retex` state directory. Staging inside the vault keeps every install
    /// a rename on the vault's filesystem, so a read-only parent directory or
    /// a mount point cannot block a pull, and `.retex` is hidden from every
    /// vault enumeration and archive. Each file is installed by renaming the
    /// verified copy over the live file after the previous contents have been
    /// stashed, and obsolete files are dropped only once every install has
    /// succeeded: an interrupted pull therefore leaves each file either old or
    /// new, never missing. Any failure rolls the vault back unchanged; a
    /// rollback that cannot finish keeps the stash and names it.
    @discardableResult
    public static func mirrorArchive(_ data: Data, into dir: URL) throws -> (written: Int, removed: Int) {
        let outcome = try mirrorArchiveReport(data, into: dir)
        return (outcome.written, outcome.removed)
    }

    struct MirrorOutcome {
        let written: Int
        let removed: Int
        let digest: String
        let fileCount: Int
    }

    /// Name of the vault's own hidden state directory (history, sync state).
    static let stateDirectoryName = ".retex"

    static func mirrorArchiveReport(_ data: Data, into dir: URL) throws -> MirrorOutcome {
        let fm = FileManager.default
        // Validate the entire archive before the vault is touched at all.
        let entries = try decodeArchive(data)
        let lexicalRoot = dir.standardizedFileURL
        let resolvedRoot = lexicalRoot.resolvingSymlinksInPath()
        try fm.createDirectory(at: lexicalRoot, withIntermediateDirectories: true)
        try prepareStateDirectory(lexicalRoot: lexicalRoot, resolvedRoot: resolvedRoot)
        let stagingRoot = lexicalRoot
            .appendingPathComponent(stateDirectoryName, isDirectory: true)
            .appendingPathComponent("mirror-\(UUID().uuidString)", isDirectory: true)
        let stagedFiles = stagingRoot.appendingPathComponent("new", isDirectory: true)
        let stashRoot = stagingRoot.appendingPathComponent("old", isDirectory: true)
        try fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        var keepStaging = false
        defer {
            // A rollback that could not finish leaves the only copy of the
            // previous files in the stash, so that tree must survive.
            if !keepStaging { try? fm.removeItem(at: stagingRoot) }
        }
        let written = try writeEntries(entries, into: stagedFiles, requireEmptyDestination: true)
        let relativePaths = entries.map(\.relativePath)
        let keep = Set(relativePaths)
        let existing = try portableFilePaths(vaultURL: lexicalRoot)
        let removed = existing.reduce(0) { $0 + (keep.contains($1) ? 0 : 1) }

        // Applied changes, oldest first; `stash` is nil for a file the archive
        // created, so undoing it means deleting the installed copy.
        var applied: [(live: URL, stash: URL?)] = []
        func stashLocation(_ path: String) -> URL {
            stashRoot.appendingPathComponent(path).standardizedFileURL
        }
        // Replaces one live file with its verified copy. The live file is
        // never removed before the replacement is ready.
        func install(_ path: String) throws {
            let live = lexicalRoot.appendingPathComponent(path).standardizedFileURL
            // The live path must resolve inside the vault: a symlinked
            // directory in the vault must not let an archive write outside it.
            try prepareWriteTarget(live, lexicalRoot: lexicalRoot, resolvedRoot: resolvedRoot)
            var isDirectory: ObjCBool = false
            var saved: URL?
            if fm.fileExists(atPath: live.path, isDirectory: &isDirectory) {
                guard !isDirectory.boolValue else {
                    throw CryptoError.mirrorFailed(path: path, reason: "a directory is in the way")
                }
                let stash = stashLocation(path)
                try stashFile(live, at: stash)
                saved = stash
            }
            do {
                try installStaged(stagedFiles.appendingPathComponent(path).standardizedFileURL, over: live)
            } catch {
                // The stash is not part of `applied` yet, and the live file is
                // still the stashed copy, so put it back before reporting.
                if let saved { try? putBack(saved, at: live) }
                throw error
            }
            applied.append((live, saved))
        }
        // A remote deletion is stashed rather than deleted, so a later failure
        // can still restore it.
        func retire(_ path: String) throws {
            let live = lexicalRoot.appendingPathComponent(path).standardizedFileURL
            try prepareWriteTarget(live, lexicalRoot: lexicalRoot, resolvedRoot: resolvedRoot)
            guard fm.fileExists(atPath: live.path) else {
                applied.append((live, nil))
                return
            }
            let stash = stashLocation(path)
            try moveIntoStash(live, at: stash)
            applied.append((live, stash))
        }
        do {
            for path in relativePaths { try install(path) }
            // Remote deletions happen only once every archived file is live.
            for path in existing where !keep.contains(path) { try retire(path) }
        } catch {
            let reason = rollBack(applied)
            if let reason {
                keepStaging = true
                throw CryptoError.mirrorRollbackFailed(stash: stashRoot.path, reason: reason)
            }
            throw error
        }
        return MirrorOutcome(written: written, removed: removed, digest: digest(entries: entries), fileCount: written)
    }

    /// Creates the vault's state directory when it is missing and refuses to
    /// stage when it is a symlink or resolves outside the vault.
    private static func prepareStateDirectory(lexicalRoot: URL, resolvedRoot: URL) throws {
        let fm = FileManager.default
        let stateDir = lexicalRoot.appendingPathComponent(stateDirectoryName, isDirectory: true)
        try prepareWriteTarget(stateDir, lexicalRoot: lexicalRoot, resolvedRoot: resolvedRoot)
        guard fm.fileExists(atPath: stateDir.path) else {
            try fm.createDirectory(at: stateDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            return
        }
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: stateDir.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CryptoError.mirrorFailed(path: stateDirectoryName, reason: "it is a file, not a directory")
        }
    }

    /// Confines `target` to the vault before anything is created, written, or
    /// removed there: the deepest existing ancestor and the resolved parent
    /// must both stay inside the vault, and the target itself must not be a
    /// symlink. Mirrors can race with vault edits, so every install re-checks.
    private static func prepareWriteTarget(_ target: URL, lexicalRoot: URL, resolvedRoot: URL) throws {
        let fm = FileManager.default
        guard isWithinVault(target, root: lexicalRoot) else {
            throw StoreError.pathOutsideVault(target)
        }
        let parent = target.deletingLastPathComponent()
        // Check the deepest existing ancestor before creating anything, so a
        // symlinked intermediate directory cannot make us mkdir outside.
        var ancestor = parent
        while (try? fm.attributesOfItem(atPath: ancestor.path)) == nil,
              ancestor.pathComponents.count > lexicalRoot.pathComponents.count {
            ancestor = ancestor.deletingLastPathComponent()
        }
        let resolvedAncestor = ancestor.resolvingSymlinksInPath()
        guard fm.fileExists(atPath: resolvedAncestor.path), isWithinVault(resolvedAncestor, root: resolvedRoot) else {
            throw StoreError.pathOutsideVault(target)
        }
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let resolvedParent = parent.resolvingSymlinksInPath()
        guard isWithinVault(resolvedParent, root: resolvedRoot) else {
            throw StoreError.pathOutsideVault(target)
        }
        if (try? target.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw StoreError.pathOutsideVault(target)
        }
    }

    /// Copies one live file into the stash. A hard link is the cheapest exact
    /// copy on the same filesystem; anything else falls back to a byte copy.
    private static func stashFile(_ live: URL, at stash: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: stash.deletingLastPathComponent(), withIntermediateDirectories: true)
        if link(live.path, stash.path) == 0 { return }
        do {
            try fm.copyItem(at: live, to: stash)
        } catch {
            throw CryptoError.mirrorFailed(path: live.lastPathComponent, reason: error.localizedDescription)
        }
    }

    /// Moves a live file into the stash so a rollback can put it back.
    private static func moveIntoStash(_ live: URL, at stash: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: stash.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(Windows)
        try fm.moveItem(at: live, to: stash)
        #else
        if rename(live.path, stash.path) == 0 { return }
        // Another filesystem inside the vault (a mount point) cannot be
        // renamed across; copy the bytes instead and drop the original.
        try stashFile(live, at: stash)
        do {
            try fm.removeItem(at: live)
        } catch {
            try? fm.removeItem(at: stash)
            throw CryptoError.mirrorFailed(path: live.lastPathComponent, reason: error.localizedDescription)
        }
        #endif
    }

    /// Atomically replaces `live` with `staged` (rename(2) over the live file).
    private static func installStaged(_ staged: URL, over live: URL) throws {
        #if os(Windows)
        let fm = FileManager.default
        if fm.fileExists(atPath: live.path) { try fm.removeItem(at: live) }
        try fm.moveItem(at: staged, to: live)
        #else
        if rename(staged.path, live.path) == 0 { return }
        let code = errno
        guard code == EXDEV else {
            throw CryptoError.mirrorFailed(path: live.path, reason: String(cString: strerror(code)))
        }
        // A mount point inside the vault is the one place the staging tree is
        // on another filesystem: stage beside the target so the replacement is
        // still a single rename.
        let temporary = live.deletingLastPathComponent()
            .appendingPathComponent(".retex-install-\(UUID().uuidString).tmp")
        do {
            try FileManager.default.copyItem(at: staged, to: temporary)
            guard rename(temporary.path, live.path) == 0 else {
                throw CryptoError.mirrorFailed(path: live.path, reason: String(cString: strerror(errno)))
            }
            try? FileManager.default.removeItem(at: staged)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        #endif
    }

    /// Moves a stashed file back over its live path.
    private static func putBack(_ stash: URL, at live: URL) throws {
        try FileManager.default.createDirectory(at: live.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(Windows)
        if FileManager.default.fileExists(atPath: live.path) { try FileManager.default.removeItem(at: live) }
        try FileManager.default.moveItem(at: stash, to: live)
        #else
        guard rename(stash.path, live.path) == 0 else {
            throw CryptoError.mirrorFailed(path: live.path, reason: String(cString: strerror(errno)))
        }
        #endif
    }

    /// Undoes applied changes newest first. Returns the reason the vault could
    /// not be fully restored, or nil when every step succeeded.
    static func rollBack(
        _ applied: [(live: URL, stash: URL?)],
        restore: (URL, URL) throws -> Void = { try putBack($0, at: $1) },
        remove: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) -> String? {
        var failure: String?
        for change in applied.reversed() {
            do {
                if let stash = change.stash {
                    try restore(stash, change.live)
                } else if FileManager.default.fileExists(atPath: change.live.path) {
                    try remove(change.live)
                }
            } catch {
                if failure == nil {
                    failure = "\(change.live.path): \(error.localizedDescription)"
                }
            }
        }
        return failure
    }

    private static func digest(entries: [ValidatedEntry]) -> String {
        var hasher = SHA256()
        // Sorted by path so this matches `digest(files:)` for any archive
        // order, which keeps the recorded sync revision stable.
        for entry in entries.sorted(by: { $0.relativePath < $1.relativePath }) {
            hasher.update(data: Data("\(entry.sha256)  \(entry.relativePath)\n".utf8))
        }
        return hex(hasher.finalize())
    }

    // MARK: - Restore

    /// Restores a versioned vault archive into a new or empty directory.
    /// Version 1 Markdown-only exports remain readable; version 2 also
    /// preserves attachments and other non-hidden vault files with per-file
    /// SHA-256 validation. Only paths `makeArchive` could have produced are
    /// accepted: no hidden components and only portable extensions.
    @discardableResult
    public static func restoreArchive(_ data: Data, into dir: URL) throws -> Int {
        try restoreArchive(data, into: dir, requireEmptyDestination: true)
    }

    static func restoreArchive(_ data: Data, into dir: URL, requireEmptyDestination: Bool) throws -> Int {
        try writeEntries(decodeArchive(data), into: dir, requireEmptyDestination: requireEmptyDestination)
    }

    /// Decodes and fully validates an archive: paths, duplicates, per-file and
    /// total size, and every per-file checksum.
    private static func decodeArchive(_ data: Data) throws -> [ValidatedEntry] {
        let entries: [ArchiveEntry]
        if let envelope = try? JSONDecoder().decode(ArchiveEnvelope.self, from: data) {
            guard envelope.version == 2 else { throw CryptoError.invalidArchive }
            entries = envelope.files
        } else {
            let legacy = try JSONDecoder().decode([ArchivedFile].self, from: data)
            guard legacy.allSatisfy({ URL(fileURLWithPath: $0.path).pathExtension.lowercased() == "md" }) else {
                throw CryptoError.invalidArchive
            }
            entries = legacy.map {
                let bytes = Data($0.content.utf8)
                return ArchiveEntry(path: $0.path, data: bytes, sha256: sha256(bytes))
            }
        }
        var seen: Set<String> = []
        var totalBytes = 0
        var validated: [ValidatedEntry] = []
        for file in entries {
            let trimmed = file.path.trimmingCharacters(in: .whitespacesAndNewlines)
            let components = trimmed.split(separator: "/").filter { $0 != "." }
            let relative = components.joined(separator: "/")
            guard !relative.isEmpty,
                  !(trimmed as NSString).isAbsolutePath,
                  !components.contains(where: { $0.hasPrefix(".") }),
                  portableVaultExtensions.contains((relative as NSString).pathExtension.lowercased()),
                  seen.insert(relative).inserted
            else {
                throw CryptoError.invalidArchive
            }
            guard file.data.count <= maximumFileBytes else {
                throw CryptoError.fileTooLarge(path: relative, bytes: file.data.count, limit: maximumFileBytes)
            }
            totalBytes += file.data.count
            guard totalBytes <= maximumArchiveBytes else {
                throw CryptoError.archiveTooLarge(path: relative, bytes: totalBytes, limit: maximumArchiveBytes)
            }
            guard sha256(file.data) == file.sha256 else { throw CryptoError.invalidArchive }
            validated.append(ValidatedEntry(relativePath: relative, data: file.data, sha256: file.sha256))
        }
        return validated
    }

    private static func writeEntries(
        _ files: [ValidatedEntry],
        into dir: URL,
        requireEmptyDestination: Bool
    ) throws -> Int {
        let fm = FileManager.default
        if requireEmptyDestination {
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: dir.path, isDirectory: &isDirectory) {
                guard isDirectory.boolValue,
                      (try fm.contentsOfDirectory(atPath: dir.path)).isEmpty
                else { throw CryptoError.destinationNotEmpty }
            }
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let lexicalRoot = dir.standardizedFileURL
        let resolvedRoot = lexicalRoot.resolvingSymlinksInPath()
        for file in files {
            let target = lexicalRoot.appendingPathComponent(file.relativePath).standardizedFileURL
            try prepareWriteTarget(target, lexicalRoot: lexicalRoot, resolvedRoot: resolvedRoot)
            try file.data.write(to: target, options: .atomic)
        }
        return files.count
    }

    // MARK: - Hashing

    private static let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)

    private static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        var buffer: [UInt8] = []
        buffer.reserveCapacity(bytes.underestimatedCount * 2)
        for byte in bytes {
            buffer.append(hexDigits[Int(byte >> 4)])
            buffer.append(hexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: buffer, as: UTF8.self)
    }

    private static func sha256(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    // MARK: - Symmetric envelope

    public func encrypt(_ plaintext: Data, passphrase: String) throws -> Data {
        guard passphrase.count >= 12 else { throw CryptoError.weakPassphrase }
        let salt = (0..<Self.saltLength).map { _ in UInt8.random(in: .min ... .max) }
        let key = try Self.deriveKey(passphrase: passphrase, salt: salt)
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
        guard let ciphertext = sealed.combined else {
            throw CryptoError.keyDerivationFailed
        }
        return Self.magic + Data(salt) + ciphertext
    }

    public func decrypt(_ blob: Data, passphrase: String) throws -> Data {
        guard blob.prefix(Self.magic.count) == Self.magic else {
            throw CryptoError.badFormat
        }
        let body = blob.dropFirst(Self.magic.count)
        guard body.count > Self.saltLength else { throw CryptoError.badFormat }
        let salt = Array(body.prefix(Self.saltLength))
        let payload = body.dropFirst(Self.saltLength)

        let key = try Self.deriveKey(passphrase: passphrase, salt: salt)
        do {
            let box = try AES.GCM.SealedBox(combined: payload)
            return try AES.GCM.open(box, using: key)
        } catch {
            throw CryptoError.wrongPassphrase
        }
    }

    private static func deriveKey(passphrase: String, salt: [UInt8]) throws -> SymmetricKey {
        #if canImport(CommonCrypto)
        var derived = Data(repeating: 0, count: 32)
        let status = derived.withUnsafeMutableBytes { (derivedPtr: UnsafeMutableRawBufferPointer) -> CCCryptorStatus in
            passphrase.withCString { passwordPtr in
                salt.withUnsafeBufferPointer { saltPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordPtr,
                        passphrase.utf8.count,
                        saltPtr.baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        derivedPtr.bindMemory(to: UInt8.self).baseAddress,
                        32
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw CryptoError.keyDerivationFailed }
        return SymmetricKey(data: derived)
        #else
        return SymmetricKey(data: deriveKeyFallback(passphrase: passphrase, salt: salt, iterations: iterations))
        #endif
    }

    /// PBKDF2-HMAC-SHA256 (RFC 8018) for platforms without CommonCrypto.
    ///
    /// The chained MAC input lives in one reusable scratch buffer that each
    /// round overwrites in place, so the 600,000 iterations never allocate an
    /// intermediate `Data` value. The result is byte-for-byte identical to
    /// `CCKeyDerivationPBKDF`.
    static func deriveKeyFallback(passphrase: String, salt: [UInt8], iterations: Int) -> [UInt8] {
        let key = SymmetricKey(data: Data(passphrase.utf8))
        var block = Data(salt)
        block.append(contentsOf: [0, 0, 0, 1])
        var message = Data(HMAC<SHA256>.authenticationCode(for: block, using: key))
        var derived = [UInt8](message)
        guard iterations > 1 else { return derived }
        for _ in 1..<iterations {
            let mac = HMAC<SHA256>.authenticationCode(for: message, using: key)
            var position = 0
            for byte in mac {
                message[position] = byte
                position += 1
            }
            // Explicit type: on Linux FoundationEssentials also offers the
            // deprecated typed-pointer overload, which makes a bare closure ambiguous.
            message.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                derived.withUnsafeMutableBufferPointer { target in
                    for index in 0..<target.count {
                        target[index] ^= source[index]
                    }
                }
            }
        }
        return derived
    }
}
