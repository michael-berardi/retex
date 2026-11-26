#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Self-update channel for the `retex` CLI.
///
/// Talks to the GitHub Releases API, downloads a release asset, verifies its
/// SHA-256 checksum against the published checksums file, then swaps the
/// running binary atomically. The previous binary is kept alongside as
/// `<binary>.previous` so a failed swap or bad upgrade can be rolled back.
public struct UpdateChecker {
    public struct Release: Sendable {
        public let tag: String
        public let assetURL: URL
        public let checksumsURL: URL
        public let assetName: String
    }

    private let repo: String
    private let session: URLSession
    private let fm = FileManager.default

    /// Hard ceiling for one HTTP exchange (matches `VaultSync`).
    static let responseDeadline: TimeInterval = 185

    /// - Parameter repo: `owner/repo` on GitHub. The caller must supply this;
    ///   Retex ships no built-in repository, owner or personal name.
    public init(repo: String, session: URLSession = .shared) {
        self.repo = repo
        self.session = Self.boundedSession(from: session.configuration)
    }

    /// A dedicated session with a bounded resource timeout, so a stalled or
    /// slow-drip release server cannot hang an update forever.
    static func boundedSession(from configuration: URLSessionConfiguration) -> URLSession {
        let config = configuration.copy() as? URLSessionConfiguration ?? configuration
        config.timeoutIntervalForResource = 180
        return URLSession(configuration: config)
    }

    public static var releaseAssetName: String {
#if os(macOS)
        "retex-universal.zip"
#elseif os(Windows)
#if arch(arm64)
        "retex-windows-arm64.zip"
#else
        "retex-windows-x86_64.zip"
#endif
#else
#if arch(arm64)
        "retex-linux-aarch64.tar.gz"
#else
        "retex-linux-x86_64.tar.gz"
#endif
#endif
    }

    // MARK: - Discovery

    public func latestRelease() throws -> Release {
        let api = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        var request = URLRequest(url: api)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try syncRequest(request)
        guard response.statusCode == 200 else {
            throw UpdateError.lookupFailed
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]]
        else {
            throw UpdateError.malformedResponse
        }

        var assetURL: URL?
        var checksumsURL: URL?
        for asset in assets {
            guard let name = asset["name"] as? String,
                  let url = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)),
                  url.scheme == "https",
                  url.host?.lowercased() == "github.com"
            else { continue }
            if name == Self.releaseAssetName { assetURL = url }
            if name == "SHA256SUMS" { checksumsURL = url }
        }
        guard let finalAsset = assetURL, let finalChecksums = checksumsURL else {
            throw UpdateError.missingAssets(tag)
        }
        return Release(tag: tag, assetURL: finalAsset, checksumsURL: finalChecksums, assetName: Self.releaseAssetName)
    }

    /// Returns true only when both values are stable semantic versions and
    /// `releaseTag` is newer. Malformed/prerelease tags fail closed.
    public static func isNewer(releaseTag: String, current: String) -> Bool {
        func components(_ value: String) -> [Int]? {
            let stripped = value.trimmingCharacters(in: CharacterSet(charactersIn: "v "))
            let fields = stripped.split(separator: ".", omittingEmptySubsequences: false)
            guard fields.count == 3 else { return nil }
            let values = fields.compactMap { field -> Int? in
                guard !field.isEmpty, field.allSatisfy(\.isNumber) else { return nil }
                return Int(field)
            }
            return values.count == 3 ? values : nil
        }
        guard let release = components(releaseTag), let local = components(current) else {
            return false
        }
        return local.lexicographicallyPrecedes(release)
    }

    // MARK: - Download & verify

    public func download(_ url: URL) throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        let (data, response) = try syncRequest(request)
        guard response.statusCode == 200 else {
            throw UpdateError.downloadFailed(url.lastPathComponent)
        }
        guard data.count <= 64 * 1024 * 1024 else {
            throw UpdateError.downloadFailed("\(url.lastPathComponent) exceeds size limit")
        }
        return data
    }

    /// Extracts one exact 64-character SHA-256 for `assetName`.
    public static func expectedChecksum(in sumsBody: String, assetName: String) -> String? {
        for line in sumsBody.split(separator: "\n") {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count == 2,
                  parts[1] == Substring(assetName),
                  parts[0].count == 64,
                  parts[0].allSatisfy({ $0.isHexDigit })
            else { continue }
            return String(parts[0]).lowercased()
        }
        return nil
    }

    public static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Atomically installs a verified candidate and retains the current binary
    /// as `<executable>.previous`. The candidate is staged beside the
    /// executable so replacement cannot cross filesystems.
    @discardableResult
    public static func install(candidate: URL, over executable: URL) throws -> URL {
        let executable = executable.resolvingSymlinksInPath()
        let fm = FileManager.default
        let directory = executable.deletingLastPathComponent()
        let staged = directory.appendingPathComponent(".retex-update-\(UUID().uuidString)")
        let previous = URL(fileURLWithPath: executable.path + ".previous")
        do {
            try fm.copyItem(at: candidate, to: staged)
            #if !os(Windows)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
            #endif
            if fm.fileExists(atPath: previous.path) {
                try fm.removeItem(at: previous)
            }
            try fm.copyItem(at: executable, to: previous)
            #if os(Windows)
            try fm.removeItem(at: executable)
            try fm.moveItem(at: staged, to: executable)
            #else
            let status = staged.path.withCString { source in
                executable.path.withCString { destination in
                    rename(source, destination)
                }
            }
            guard status == 0 else {
                throw UpdateError.installFailed(String(cString: strerror(errno)))
            }
            #endif
            guard fm.fileExists(atPath: executable.path),
                  fm.fileExists(atPath: previous.path)
            else {
                throw UpdateError.installFailed("replacement did not preserve both binaries")
            }
            return previous
        } catch {
            if !fm.fileExists(atPath: executable.path),
               fm.fileExists(atPath: previous.path) {
                try? fm.copyItem(at: previous, to: executable)
            }
            try? fm.removeItem(at: staged)
            if let updateError = error as? UpdateError { throw updateError }
            throw UpdateError.installFailed(error.localizedDescription)
        }
    }
}

extension UpdateChecker {
    public enum UpdateError: LocalizedError {
        case lookupFailed
        case requestTimedOut
        case malformedResponse
        case missingAssets(String)
        case downloadFailed(String)
        case installFailed(String)

        public var errorDescription: String? {
            switch self {
            case .lookupFailed: "GitHub releases lookup failed — check network connectivity"
            case .requestTimedOut: "GitHub releases request did not finish in time — check network connectivity"
            case .malformedResponse: "GitHub releases response was malformed"
            case .missingAssets(let tag): "Release \(tag) is missing \(UpdateChecker.releaseAssetName) or SHA256SUMS"
            case .downloadFailed(let name): "Download failed: \(name)"
            case .installFailed(let reason): "Retex could not install the verified update: \(reason)"
            }
        }
    }
}

extension UpdateChecker {
    /// Blocking network call; the CLI is synchronous by design.
    fileprivate func syncRequest(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        final class Box: @unchecked Sendable {
            var result: Result<(Data, HTTPURLResponse), Error>?
        }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                box.result = .failure(error)
            } else if let data, let http = response as? HTTPURLResponse {
                box.result = .success((data, http))
            } else {
                box.result = .failure(UpdateError.lookupFailed)
            }
        }
        task.resume()
        if semaphore.wait(timeout: .now() + UpdateChecker.responseDeadline) == .timedOut {
            task.cancel()
            throw UpdateError.requestTimedOut
        }
        guard let result = box.result else { throw UpdateError.lookupFailed }
        return try result.get()
    }
}
