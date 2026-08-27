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

        public var errorDescription: String? {
            switch self {
            case .badFormat: "Not a Retex encrypted export (missing RETEXENC1 header)."
            case .wrongPassphrase: "Decryption failed: wrong passphrase or corrupted file."
            case .keyDerivationFailed: "Passphrase key derivation failed."
            }
        }
    }

    // MARK: - Vault archive

    struct ArchivedFile: Codable {
        let path: String
        let content: String
    }

    /// Collects every `.md` file under `vaultURL` into a portable archive blob.
    public static func makeArchive(vaultURL: URL) throws -> Data {
        let lexicalRoot = vaultURL.standardizedFileURL
        let resolvedRoot = lexicalRoot.resolvingSymlinksInPath()
        guard let enumerator = FileManager.default.enumerator(
            at: lexicalRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw StoreError.unreadableVault(vaultURL)
        }

        var files: [ArchivedFile] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "md" {
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            guard isWithinVault(resolved, root: resolvedRoot) else {
                throw StoreError.pathOutsideVault(url)
            }
            let content = try String(contentsOf: resolved, encoding: .utf8)
            let relative = url.standardizedFileURL.pathComponents
                .dropFirst(lexicalRoot.pathComponents.count)
                .joined(separator: "/")
            files.append(ArchivedFile(path: relative, content: content))
        }
        files.sort { $0.path < $1.path }
        return try JSONEncoder().encode(files)
    }

    /// Writes archived files back into an existing directory.
    /// Returns the number of notes written. Refuses paths that escape `into`.
    @discardableResult
    public static func restoreArchive(_ data: Data, into dir: URL) throws -> Int {
        let files = try JSONDecoder().decode([ArchivedFile].self, from: data)
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let lexicalRoot = dir.standardizedFileURL
        let resolvedRoot = lexicalRoot.resolvingSymlinksInPath()
        var seen: Set<String> = []

        for file in files {
            let relative = file.path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !relative.isEmpty,
                  !(relative as NSString).isAbsolutePath,
                  URL(fileURLWithPath: relative).pathExtension.lowercased() == "md",
                  seen.insert(relative).inserted
            else {
                throw StoreError.pathOutsideVault(URL(fileURLWithPath: file.path))
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
            try file.content.write(to: target, atomically: true, encoding: .utf8)
        }
        return files.count
    }

    // MARK: - Symmetric envelope

    public func encrypt(_ plaintext: Data, passphrase: String) throws -> Data {
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
