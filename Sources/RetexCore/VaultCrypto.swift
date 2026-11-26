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
    /// restored and verified in a sibling staging directory on the same
    /// filesystem. The swap then moves existing files aside, moves the
    /// verified files into place, and only drops obsolete files once every
    /// new file is live; any failure rolls the vault back unchanged.
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

    static func mirrorArchiveReport(_ data: Data, into dir: URL) throws -> MirrorOutcome {
        let fm = FileManager.default
        // Validate the entire archive before the vault is touched at all.
        let entries = try decodeArchive(data)
        let lexicalRoot = dir.standardizedFileURL
        let parent = lexicalRoot.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let token = UUID().uuidString
        // Siblings of the vault: same filesystem, so every move is a rename,
        // and hidden names, so neither directory is ever enumerated as vault
        // content.
        let staged = parent.appendingPathComponent(".retex-mirror-\(token).new", isDirectory: true)
        let stash = parent.appendingPathComponent(".retex-mirror-\(token).old", isDirectory: true)
        defer {
            try? fm.removeItem(at: staged)
            try? fm.removeItem(at: stash)
        }
        let written = try writeEntries(entries, into: staged, requireEmptyDestination: true)
        let relativePaths = entries.map(\.relativePath)
        let keep = Set(relativePaths)

        try fm.createDirectory(at: lexicalRoot, withIntermediateDirectories: true)
        let existing = try portableFilePaths(vaultURL: lexicalRoot)
        let removed = existing.reduce(0) { $0 + (keep.contains($1) ? 0 : 1) }

        var stashed: [(live: URL, saved: URL)] = []
        var installed: [URL] = []
        do {
            for path in existing {
                let live = lexicalRoot.appendingPathComponent(path)
                let saved = stash.appendingPathComponent(path)
                try fm.createDirectory(at: saved.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: live, to: saved)
                stashed.append((live, saved))
            }
            for path in relativePaths {
                let live = lexicalRoot.appendingPathComponent(path)
                try fm.createDirectory(at: live.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: staged.appendingPathComponent(path), to: live)
                installed.append(live)
            }
        } catch {
            // Roll back: drop anything already installed, then restore every
            // file the archive did not replace.
            for url in installed { try? fm.removeItem(at: url) }
            for item in stashed {
                try? fm.createDirectory(at: item.live.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.moveItem(at: item.saved, to: item.live)
            }
            throw error
        }
        return MirrorOutcome(written: written, removed: removed, digest: digest(entries: entries), fileCount: written)
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
            guard isWithinVault(target, root: lexicalRoot) else {
                throw StoreError.pathOutsideVault(target)
            }
            let parent = target.deletingLastPathComponent()
            // Check the deepest existing ancestor before creating anything, so
            // a symlinked intermediate directory cannot make us mkdir outside.
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
            message.withUnsafeBytes { source in
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
