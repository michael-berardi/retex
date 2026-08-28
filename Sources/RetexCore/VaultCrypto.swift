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

    public enum CryptoError: LocalizedError {
        case badFormat
        case wrongPassphrase
        case keyDerivationFailed
        case invalidArchive
        case weakPassphrase

        public var errorDescription: String? {
            switch self {
            case .badFormat: "Not a Retex encrypted export (missing RETEXENC1 header)."
            case .wrongPassphrase: "Decryption failed: wrong passphrase or corrupted file."
            case .keyDerivationFailed: "Passphrase key derivation failed."
            case .invalidArchive: "Retex archive manifest, checksum, path, or size validation failed."
            case .weakPassphrase: "Export passphrase must contain at least 12 characters."
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

    private static let maximumFileBytes = 64 * 1024 * 1024
    private static let maximumArchiveBytes = 1024 * 1024 * 1024
    private static let portableVaultExtensions: Set<String> = [
        "md", "markdown", "txt", "csv", "json", "canvas", "excalidraw",
        "pdf", "png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "tiff", "heic", "avif",
        "mp3", "m4a", "wav", "flac", "ogg", "mp4", "mov", "webm",
        "doc", "docx", "xls", "xlsx", "ppt", "pptx", "zip",
    ]

    /// Collects portable, non-hidden vault documents and attachments. Retex
    /// state, source code, VCS/editor state, symlinks, and packages are excluded.
    public static func makeArchive(vaultURL: URL) throws -> Data {
        let lexicalRoot = vaultURL.standardizedFileURL
        let resolvedRoot = lexicalRoot.resolvingSymlinksInPath()
        guard let enumerator = FileManager.default.enumerator(
            at: lexicalRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw StoreError.unreadableVault(vaultURL)
        }

        var files: [ArchiveEntry] = []
        var totalBytes = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true else { throw StoreError.pathOutsideVault(url) }
            guard values.isRegularFile == true else { continue }
            guard portableVaultExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let size = values.fileSize ?? 0
            totalBytes += size
            guard size <= maximumFileBytes, totalBytes <= maximumArchiveBytes else {
                throw CryptoError.invalidArchive
            }
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            guard isWithinVault(resolved, root: resolvedRoot) else {
                throw StoreError.pathOutsideVault(url)
            }
            let relative = url.standardizedFileURL.pathComponents
                .dropFirst(lexicalRoot.pathComponents.count)
                .joined(separator: "/")
            let data = try Data(contentsOf: resolved, options: [.mappedIfSafe])
            files.append(ArchiveEntry(path: relative, data: data, sha256: sha256(data)))
        }
        files.sort { $0.path < $1.path }
        return try JSONEncoder().encode(ArchiveEnvelope(version: 2, files: files))
    }

    /// Restores a versioned vault archive. Version 1 Markdown-only exports
    /// remain readable; version 2 also preserves attachments and other
    /// non-hidden vault files with per-file SHA-256 validation.
    @discardableResult
    public static func restoreArchive(_ data: Data, into dir: URL) throws -> Int {
        if let envelope = try? JSONDecoder().decode(ArchiveEnvelope.self, from: data) {
            guard envelope.version == 2 else { throw CryptoError.invalidArchive }
            return try restoreEntries(envelope.files, into: dir)
        }
        let legacy = try JSONDecoder().decode([ArchivedFile].self, from: data)
        guard legacy.allSatisfy({ URL(fileURLWithPath: $0.path).pathExtension.lowercased() == "md" }) else {
            throw CryptoError.invalidArchive
        }
        return try restoreEntries(legacy.map {
            let bytes = Data($0.content.utf8)
            return ArchiveEntry(path: $0.path, data: bytes, sha256: sha256(bytes))
        }, into: dir)
    }

    private static func restoreEntries(_ files: [ArchiveEntry], into dir: URL) throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let lexicalRoot = dir.standardizedFileURL
        let resolvedRoot = lexicalRoot.resolvingSymlinksInPath()
        var seen: Set<String> = []
        var totalBytes = 0

        for file in files {
            let relative = file.path.trimmingCharacters(in: .whitespacesAndNewlines)
            totalBytes += file.data.count
            guard !relative.isEmpty,
                  !(relative as NSString).isAbsolutePath,
                  seen.insert(relative).inserted,
                  file.data.count <= maximumFileBytes,
                  totalBytes <= maximumArchiveBytes,
                  sha256(file.data) == file.sha256
            else {
                throw CryptoError.invalidArchive
            }

            let target = lexicalRoot.appendingPathComponent(relative).standardizedFileURL
            guard isWithinVault(target, root: lexicalRoot) else {
                throw StoreError.pathOutsideVault(target)
            }
            let parent = target.deletingLastPathComponent()
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

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
        let passwordKey = SymmetricKey(data: Data(passphrase.utf8))
        var block = Data(salt)
        block.append(contentsOf: [0, 0, 0, 1])
        var previous = Data(HMAC<SHA256>.authenticationCode(for: block, using: passwordKey))
        var derived = previous
        for _ in 1..<iterations {
            previous = Data(HMAC<SHA256>.authenticationCode(for: previous, using: passwordKey))
            for index in derived.indices {
                derived[index] ^= previous[index]
            }
        }
        return SymmetricKey(data: derived)
        #endif
    }
}
