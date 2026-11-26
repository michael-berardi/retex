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
        public let notes: String
        public let assetURL: URL
        public let checksumsURL: URL
        public let assetName: String
    }

    private let repo: String
    private let session: URLSession
    private let timeout: TimeInterval
    private let fixtureAPI: URL?

    /// Ceiling for one release download (assets are size-limited below).
    static let maximumTransferBytes = 64 * 1024 * 1024

    /// - Parameter repo: `owner/repo` on GitHub. The caller must supply this;
    ///   Retex ships no built-in repository, owner or personal name.
    /// - Parameter timeout: Bound for the lookup; the daily check uses 4 s.
    public init(repo: String, session: URLSession = UpdateChecker.anonymousSession, timeout: TimeInterval = 15) {
        self.repo = repo
        self.session = Self.boundedSession(from: session.configuration)
        self.timeout = timeout
        self.fixtureAPI = Self.fixtureAPI(ProcessInfo.processInfo.environment["RETEX_UPDATE_API"])
    }

    /// A dedicated session that drops a stalled release server after a minute
    /// of silence instead of capping the whole download at a fixed 180 s.
    static func boundedSession(from configuration: URLSessionConfiguration) -> URLSession {
        HTTPDeadline.configure(configuration, maximumBytes: maximumTransferBytes)
    }

    /// No cookies, credentials or response cache: every request is anonymous
    /// and a check writes nothing besides Retex's own state file.
    public static let anonymousSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }()

    /// `owner/repo` with GitHub's name characters only.
    public static func isValidRepo(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { part in
            !part.isEmpty && part != "." && part != ".."
                && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
        }
    }

    /// `RETEX_UPDATE_API` may point the lookup at a loopback fixture server
    /// for tests and release drills. Any other host is ignored.
    public static func fixtureAPI(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              ["127.0.0.1", "localhost", "::1"].contains(url.host?.lowercased() ?? "")
        else { return nil }
        return url
    }

    public var releasesURL: URL {
        fixtureAPI ?? URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
    }

    /// `v1.2.3` → `1.2.3`, the form shown to users and kept in the state file.
    public static func displayVersion(_ tag: String) -> String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
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
        var request = URLRequest(url: releasesURL)
        request.timeoutInterval = timeout
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // Fixed, anonymous User-Agent: no id, version, machine or usage data.
        request.setValue("retex-update-check", forHTTPHeaderField: "User-Agent")
        let (data, response) = try syncRequest(request, deadline: timeout)
        guard response.statusCode == 200 else {
            throw UpdateError.lookupFailed(response.statusCode)
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]]
        else {
            throw UpdateError.malformedResponse
        }
        guard json["draft"] as? Bool != true,
              json["prerelease"] as? Bool != true,
              Self.stableVersion(tag) != nil
        else {
            throw UpdateError.notStable(tag)
        }

        var assetURL: URL?
        var checksumsURL: URL?
        for asset in assets {
            guard let name = asset["name"] as? String,
                  let url = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)),
                  trustedAsset(url)
            else { continue }
            if name == Self.releaseAssetName { assetURL = url }
            if name == "SHA256SUMS" { checksumsURL = url }
        }
        guard let finalAsset = assetURL, let finalChecksums = checksumsURL else {
            throw UpdateError.missingAssets(tag)
        }
        let notes = json["body"] as? String ?? ""
        return Release(
            tag: tag,
            notes: notes,
            assetURL: finalAsset,
            checksumsURL: finalChecksums,
            assetName: Self.releaseAssetName
        )
    }

    /// Release assets come from github.com over HTTPS, or from the loopback
    /// fixture server when `RETEX_UPDATE_API` names one.
    private func trustedAsset(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if let fixtureAPI, host == fixtureAPI.host?.lowercased() { return true }
        return url.scheme?.lowercased() == "https" && host == "github.com"
    }

    /// Stable `x.y.z` (optionally `v`-prefixed) only: prereleases, build
    /// suffixes, leading zeros and anything unparseable return nil.
    public static func stableVersion(_ value: String) -> [Int]? {
        let fields = displayVersion(value).split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3 else { return nil }
        let values = fields.compactMap { field -> Int? in
            guard !field.isEmpty, field.count <= 9,
                  field.allSatisfy({ $0.isASCII && $0.isNumber }),
                  field.count == 1 || field.first != "0"
            else { return nil }
            return Int(field)
        }
        return values.count == 3 ? values : nil
    }

    /// Returns true only when both values are stable semantic versions and
    /// `releaseTag` is newer. Malformed/prerelease tags fail closed.
    public static func isNewer(releaseTag: String, current: String) -> Bool {
        guard let release = stableVersion(releaseTag), let local = stableVersion(current) else {
            return false
        }
        return local.lexicographicallyPrecedes(release)
    }

    // MARK: - Download & verify

    public func download(_ url: URL) throws -> Data {
        var request = URLRequest(url: url)
        // The stall guard, not a cap on the whole download.
        request.timeoutInterval = HTTPDeadline.idle()
        request.setValue("retex-update-check", forHTTPHeaderField: "User-Agent")
        let (data, response) = try syncRequest(request)
        guard response.statusCode == 200 else {
            throw UpdateError.downloadFailed(url.lastPathComponent)
        }
        guard data.count <= 64 * 1024 * 1024 else {
            throw UpdateError.downloadFailed("\(url.lastPathComponent) exceeds size limit")
        }
        return data
    }

    /// Downloads the release asset and returns it only if its SHA-256 matches
    /// the release's `SHA256SUMS` entry. Nothing is written to disk first.
    public func downloadVerified(_ release: Release) throws -> Data {
        let sums = String(decoding: try download(release.checksumsURL), as: UTF8.self)
        guard let expected = Self.expectedChecksum(in: sums, assetName: release.assetName) else {
            throw UpdateError.checksumMissing(release.assetName)
        }
        let asset = try download(release.assetURL)
        guard Self.sha256(of: asset) == expected else {
            throw UpdateError.checksumMismatch(release.assetName)
        }
        return asset
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

    /// Removes the one rollback copy beside `executable`. Retex calls this
    /// after a command has succeeded on the installed binary, so the new
    /// version has run once before its fallback goes.
    public static func removeRollback(beside executable: URL) {
        let previous = URL(fileURLWithPath: executable.path + ".previous")
        guard let values = try? previous.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true
        else { return }
        try? FileManager.default.removeItem(at: previous)
    }
}

extension UpdateChecker {
    public enum UpdateError: LocalizedError {
        case lookupFailed(Int)
        case requestTimedOut
        case malformedResponse
        case notStable(String)
        case missingAssets(String)
        case downloadFailed(String)
        case checksumMissing(String)
        case checksumMismatch(String)
        case installFailed(String)

        public var errorDescription: String? {
            switch self {
            case .lookupFailed(let status): "release lookup failed (HTTP \(status))"
            case .requestTimedOut: "release lookup did not finish in time; check network connectivity"
            case .malformedResponse: "release lookup returned an unreadable response"
            case .notStable(let tag): "latest release \(tag) is not a stable x.y.z version"
            case .missingAssets(let tag): "release \(tag) has no \(UpdateChecker.releaseAssetName) or SHA256SUMS"
            case .downloadFailed(let name): "download failed: \(name)"
            case .checksumMissing(let name): "SHA256SUMS has no valid entry for \(name)"
            case .checksumMismatch(let name): "checksum mismatch for \(name); nothing was installed"
            case .installFailed(let reason): "could not install the verified update: \(reason)"
            }
        }
    }
}

extension UpdateChecker {
    /// Blocking network call; the CLI is synchronous by design.
    /// - Parameter deadline: Total bound for a small exchange (the release
    ///   lookup: 4 s for the daily check). Without one the size-scaled
    ///   download deadline applies.
    fileprivate func syncRequest(_ request: URLRequest, deadline: TimeInterval? = nil) throws -> (Data, HTTPURLResponse) {
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
                box.result = .failure(UpdateError.malformedResponse)
            }
        }
        task.resume()
        let completed: Bool
        if let deadline {
            completed = semaphore.wait(timeout: .now() + deadline) == .success
        } else {
            completed = HTTPDeadline.wait(for: task, semaphore: semaphore).completed
        }
        guard completed else {
            task.cancel()
            throw UpdateError.requestTimedOut
        }
        guard let result = box.result else { throw UpdateError.malformedResponse }
        return try result.get()
    }
}
