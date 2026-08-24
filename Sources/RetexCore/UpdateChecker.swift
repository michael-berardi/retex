import CryptoKit
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
    }

    private let repo: String
    private let session: URLSession
    private let fm = FileManager.default

    /// - Parameter repo: `owner/repo` on GitHub.
    public init(repo: String = "michael-berardi/retex", session: URLSession = .shared) {
        self.repo = repo
        self.session = session
    }

    // MARK: - Discovery

    public func latestRelease() throws -> Release {
        let api = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        var request = URLRequest(url: api)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try syncRequest(request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
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
                  let url = (asset["browser_download_url"] as? String).flatMap(URL.init(string:))
            else { continue }
            if name == "retex-universal.zip" { assetURL = url }
            if name == "SHA256SUMS" { checksumsURL = url }
        }
        guard let finalAsset = assetURL, let finalChecksums = checksumsURL else {
            throw UpdateError.missingAssets(tag)
        }
        return Release(tag: tag, assetURL: finalAsset, checksumsURL: finalChecksums)
    }

    /// Returns true if `current` is older than `release.tag` (semver-ish compare).
    public static func isNewer(releaseTag: String, current: String) -> Bool {
        let strip: (String) -> String = { $0.trimmingCharacters(in: CharacterSet(charactersIn: "v ")) }
        let release = strip(releaseTag).split(separator: ".").map { Int($0) ?? 0 }
        let local = strip(current).split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(release.count, local.count) {
            let r = index < release.count ? release[index] : 0
            let l = index < local.count ? local[index] : 0
            if r != l { return r > l }
        }
        return false
    }

    // MARK: - Download & verify

    public func download(_ url: URL) throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        let (data, response) = try syncRequest(request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.downloadFailed(url.lastPathComponent)
        }
        guard data.count <= 64 * 1024 * 1024 else {
            throw UpdateError.downloadFailed("\(url.lastPathComponent) exceeds size limit")
        }
        return data
    }

    /// Extracts the expected SHA-256 line for `assetName` from a SHA256SUMS body.
    public static func expectedChecksum(in sumsBody: String, assetName: String) -> String? {
        for line in sumsBody.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            if parts.count == 2,
               let hash = parts.first,
               parts[1].trimmingCharacters(in: .whitespaces).hasPrefix(assetName) {
                return String(hash).lowercased()
            }
        }
        return nil
    }

    public static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension UpdateChecker {
    public enum UpdateError: LocalizedError {
        case lookupFailed
        case malformedResponse
        case missingAssets(String)
        case downloadFailed(String)

        public var errorDescription: String? {
            switch self {
            case .lookupFailed: "GitHub releases lookup failed — check network connectivity"
            case .malformedResponse: "GitHub releases response was malformed"
            case .missingAssets(let tag): "Release \(tag) is missing retex-universal.zip or SHA256SUMS"
            case .downloadFailed(let name): "Download failed: \(name)"
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
        session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                box.result = .failure(error)
            } else if let data, let http = response as? HTTPURLResponse {
                box.result = .success((data, http))
            } else {
                box.result = .failure(UpdateError.lookupFailed)
            }
        }.resume()
        semaphore.wait()
        return try box.result!.get()
    }
}
