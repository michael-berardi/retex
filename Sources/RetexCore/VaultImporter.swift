import Foundation

public enum VaultImportFormat: String, Codable, Sendable {
    case auto
    case notion
    case obsidian
    case markdown
}

public struct VaultImportResult: Codable, Equatable, Sendable {
    public let format: VaultImportFormat
    public let notes: Int
    public let assets: Int
    public let convertedTables: Int
    public let destination: String

    public init(format: VaultImportFormat, notes: Int, assets: Int, convertedTables: Int, destination: String) {
        self.format = format
        self.notes = notes
        self.assets = assets
        self.convertedTables = convertedTables
        self.destination = destination
    }
}

public struct VaultImporter {
    public enum ImportError: LocalizedError, Equatable {
        case unsupportedSource
        case destinationNotEmpty
        case unsafeSource(String)
        case fileTooLarge(String)
        case archiveExtractionFailed
        case fileFailed(String, String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedSource:
                return "Import source must be an extracted vault directory or a Notion ZIP export."
            case .destinationNotEmpty:
                return "Import destination must be new or empty."
            case let .unsafeSource(path):
                return "Import source contains an unsafe path or symlink: \(path)"
            case let .fileTooLarge(path):
                return "Import source exceeds the 64 MiB per-file or 1 GiB total limit: \(path)"
            case .archiveExtractionFailed:
                return "The Notion ZIP export could not be extracted."
            case let .fileFailed(path, reason):
                return "Import failed while copying \(path): \(reason)"
            }
        }
    }

    private static let notionID = try! NSRegularExpression(pattern: #"(?i)(?:\s+|-)[0-9a-f]{32}(?=(?:\.[^./]+)?$)"#)
    private static let markdownLinkTarget = try! NSRegularExpression(pattern: #"\]\(((?:[^()\n]|\([^()\n]*\))+)\)"#)

    let maximumFileBytes: Int
    let maximumTotalBytes: Int
    let temporaryRoot: URL

    public init() {
        self.init(
            maximumFileBytes: 64 * 1024 * 1024,
            maximumTotalBytes: 1024 * 1024 * 1024,
            temporaryRoot: FileManager.default.temporaryDirectory
        )
    }

    init(maximumFileBytes: Int, maximumTotalBytes: Int, temporaryRoot: URL) {
        self.maximumFileBytes = maximumFileBytes
        self.maximumTotalBytes = maximumTotalBytes
        self.temporaryRoot = temporaryRoot
    }

    public func importSource(
        _ source: URL,
        into destination: URL,
        format requestedFormat: VaultImportFormat = .auto
    ) throws -> VaultImportResult {
        let fm = FileManager.default
        let sourceURL = source.standardizedFileURL
        let destinationURL = destination.standardizedFileURL
        try requireEmptyDestination(destinationURL)
        let destinationExisted = fm.fileExists(atPath: destinationURL.path)

        var temporary: URL?
        defer {
            if let temporary { try? fm.removeItem(at: temporary) }
        }
        var importRoot = sourceURL
        if sourceURL.pathExtension.lowercased() == "zip" {
            let values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  (values.fileSize ?? 0) <= maximumTotalBytes
            else { throw ImportError.fileTooLarge(sourceURL.path) }
            let entries = try validateZIP(sourceURL)
            let directory = temporaryRoot.appendingPathComponent("retex-import-\(UUID().uuidString)", isDirectory: true)
            // Register cleanup before anything can fail, and keep the
            // extracted export private to this user.
            temporary = directory
            try Self.createPrivateDirectory(directory)
            try extractZIP(sourceURL, entries: entries, into: directory)
            importRoot = singleContentRoot(in: directory)
        } else {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ImportError.unsupportedSource
            }
        }

        let format = requestedFormat == .auto ? detectFormat(root: importRoot, wasZIP: temporary != nil) : requestedFormat
        let files = try inventory(root: importRoot)
        let (pathMap, tableMap) = normalizedPaths(files: files, root: importRoot, notion: format == .notion)
        try fm.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        var notes = 0
        var assets = 0
        var convertedTables = 0
        do {
            for file in files {
                guard let relative = relativePath(file, root: importRoot), let mapped = pathMap[relative] else {
                    throw ImportError.unsafeSource(file.path)
                }
                let target = destinationURL.appendingPathComponent(mapped).standardizedFileURL
                guard isWithin(target, root: destinationURL) else { throw ImportError.unsafeSource(file.path) }
                do {
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)

                    let ext = file.pathExtension.lowercased()
                    if ext == "md" {
                        // Notes that are not valid UTF-8 are kept byte-for-byte
                        // rather than aborting the whole import.
                        let data = try Data(contentsOf: file)
                        if format == .notion, let markdown = String(data: data, encoding: .utf8) {
                            try rewriteNotionLinks(markdown, note: relative, pathMap: pathMap)
                                .write(to: target, atomically: true, encoding: .utf8)
                        } else {
                            try data.write(to: target, options: .atomic)
                        }
                        notes += 1
                    } else {
                        try fm.copyItem(at: file, to: target)
                        assets += 1
                        if let tablePath = tableMap[relative],
                           let table = try notionTable(from: file, title: ((mapped as NSString).lastPathComponent as NSString).deletingPathExtension) {
                            let tableURL = destinationURL.appendingPathComponent(tablePath).standardizedFileURL
                            guard isWithin(tableURL, root: destinationURL) else { throw ImportError.unsafeSource(file.path) }
                            try table.write(to: tableURL, atomically: true, encoding: .utf8)
                            notes += 1
                            convertedTables += 1
                        }
                    }
                } catch let error as ImportError {
                    throw error
                } catch {
                    throw ImportError.fileFailed(relative, error.localizedDescription)
                }
            }
        } catch {
            // The destination was new or empty, so everything in it is ours;
            // remove it so the import can be retried.
            if destinationExisted {
                for child in (try? fm.contentsOfDirectory(at: destinationURL, includingPropertiesForKeys: nil)) ?? [] {
                    try? fm.removeItem(at: child)
                }
            } else {
                try? fm.removeItem(at: destinationURL)
            }
            throw error
        }

        return VaultImportResult(
            format: format,
            notes: notes,
            assets: assets,
            convertedTables: convertedTables,
            destination: destinationURL.path
        )
    }

    private func requireEmptyDestination(_ destination: URL) throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: destination.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue,
                  (try fm.contentsOfDirectory(atPath: destination.path)).isEmpty
            else { throw ImportError.destinationNotEmpty }
        }
    }

    /// Creates a directory readable only by the current user (0700).
    static func createPrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func inventory(root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { throw ImportError.unsupportedSource }
        var files: [URL] = []
        var total = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            if values.isSymbolicLink == true { throw ImportError.unsafeSource(url.path) }
            guard values.isRegularFile == true else { continue }
            let size = values.fileSize ?? 0
            total += size
            guard size <= maximumFileBytes, total <= maximumTotalBytes else {
                throw ImportError.fileTooLarge(url.path)
            }
            guard isWithin(url.resolvingSymlinksInPath(), root: root.resolvingSymlinksInPath()) else {
                throw ImportError.unsafeSource(url.path)
            }
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    private func detectFormat(root: URL, wasZIP: Bool) -> VaultImportFormat {
        if wasZIP { return .notion }
        if FileManager.default.fileExists(atPath: root.appendingPathComponent(".obsidian", isDirectory: true).path) {
            return .obsidian
        }
        return .markdown
    }

    /// Maps every source-relative path to its destination-relative path and,
    /// for Notion CSV databases, to the Markdown table derived from them.
    /// Real files are reserved first so a derived table never replaces a note.
    private func normalizedPaths(files: [URL], root: URL, notion: Bool) -> (paths: [String: String], tables: [String: String]) {
        var result: [String: String] = [:]
        var tables: [String: String] = [:]
        var used: Set<String> = []
        func reserve(_ base: String) -> String {
            var candidate = base
            var suffix = 2
            while used.contains(candidate.lowercased()) {
                // String path operations: `base` is relative, so it must not
                // be resolved against the process working directory.
                let stem = (base as NSString).deletingPathExtension
                let ext = (base as NSString).pathExtension
                candidate = ext.isEmpty ? "\(stem)-\(suffix)" : "\(stem)-\(suffix).\(ext)"
                suffix += 1
            }
            used.insert(candidate.lowercased())
            return candidate
        }
        for file in files {
            guard let relative = relativePath(file, root: root) else { continue }
            let components = relative.split(separator: "/").map(String.init)
            var normalized: [String] = []
            for (index, component) in components.enumerated() {
                guard notion else { normalized.append(component); continue }
                let stripped = stripNotionID(component)
                if index == components.count - 1 {
                    // Keep the original name rather than produce `.md` or ``.
                    normalized.append(stripped.isEmpty || stripped.hasPrefix(".") ? component : stripped)
                } else if !stripped.isEmpty {
                    // An ID-only folder collapses into its parent instead of
                    // yielding an empty component (`a//b.md`) that dodges dedupe.
                    normalized.append(stripped)
                }
            }
            result[relative] = reserve(normalized.joined(separator: "/"))
        }
        if notion {
            for (relative, mapped) in result.sorted(by: { $0.key < $1.key })
            where (relative as NSString).pathExtension.lowercased() == "csv" {
                tables[relative] = reserve((mapped as NSString).deletingPathExtension + ".md")
            }
        }
        return (result, tables)
    }

    private func stripNotionID(_ component: String) -> String {
        let range = NSRange(component.startIndex..<component.endIndex, in: component)
        let stripped = Self.notionID.stringByReplacingMatches(in: component, range: range, withTemplate: "")
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Rewrites Markdown link targets (`](...)`) that point at other exported
    /// files, resolving each one relative to the note through `pathMap` and
    /// re-encoding it the way the original target was written. One pass per note.
    private func rewriteNotionLinks(_ markdown: String, note source: String, pathMap: [String: String]) -> String {
        guard let destination = pathMap[source] else { return markdown }
        let sourceDirectory = source.split(separator: "/").dropLast().map(String.init)
        let destinationDirectory = destination.split(separator: "/").dropLast().map(String.init)
        let text = markdown as NSString
        var rewritten = ""
        var cursor = 0
        for match in Self.markdownLinkTarget.matches(in: markdown, range: NSRange(location: 0, length: text.length)) {
            let range = match.range(at: 1)
            let target = text.substring(with: range)
            let fragmentStart = target.firstIndex(of: "#") ?? target.endIndex
            let rawPath = String(target[..<fragmentStart])
            guard !rawPath.isEmpty else { continue }
            let decoded = rawPath.removingPercentEncoding
            var replacement: String?
            for (candidate, encoded) in [(decoded, true), (rawPath, false)] {
                guard let candidate, let key = resolveLink(candidate, from: sourceDirectory),
                      let mapped = pathMap[key]
                else { continue }
                let link = relativeLink(from: destinationDirectory, to: mapped)
                replacement = encoded && decoded != rawPath
                    ? link.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
                    : link
                break
            }
            guard let replacement else { continue }
            rewritten += text.substring(with: NSRange(location: cursor, length: range.location - cursor))
            rewritten += replacement + target[fragmentStart...]
            cursor = range.location + range.length
        }
        return rewritten + text.substring(from: cursor)
    }

    private func resolveLink(_ link: String, from directory: [String]) -> String? {
        var components = directory
        for component in link.split(separator: "/") {
            switch component {
            case ".": continue
            case "..":
                guard !components.isEmpty else { return nil }
                components.removeLast()
            default: components.append(String(component))
            }
        }
        return components.isEmpty ? nil : components.joined(separator: "/")
    }

    private func relativeLink(from directory: [String], to path: String) -> String {
        let target = path.split(separator: "/").map(String.init)
        var common = 0
        while common < directory.count, common < target.count - 1, directory[common] == target[common] {
            common += 1
        }
        return (Array(repeating: "..", count: directory.count - common) + target[common...]).joined(separator: "/")
    }

    /// Returns nil for a CSV that is not UTF-8; the CSV itself is still kept.
    private func notionTable(from csvURL: URL, title: String) throws -> String? {
        guard let source = String(data: try Data(contentsOf: csvURL), encoding: .utf8) else { return nil }
        let rows = parseCSV(source)
        guard let header = rows.first, !header.isEmpty else { return "# \(title)\n" }
        let width = header.count
        func cells(_ row: [String]) -> String {
            let padded = row + Array(repeating: "", count: max(0, width - row.count))
            return "| " + padded.prefix(width).map {
                $0.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: "<br>")
            }.joined(separator: " | ") + " |"
        }
        return (["# \(title)", "", cells(header), cells(Array(repeating: "---", count: width))]
            + rows.dropFirst().map(cells)).joined(separator: "\n") + "\n"
    }

    private func parseCSV(_ source: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var index = source.startIndex
        while index < source.endIndex {
            let character = source[index]
            let next = source.index(after: index)
            if character == "\"" {
                if quoted, next < source.endIndex, source[next] == "\"" {
                    field.append("\"")
                    index = source.index(after: next)
                    continue
                }
                quoted.toggle()
            } else if character == ",", !quoted {
                row.append(field)
                field = ""
            } else if (character == "\n" || character == "\r"), !quoted {
                if character == "\r", next < source.endIndex, source[next] == "\n" { index = next }
                row.append(field)
                if !row.allSatisfy({ $0.isEmpty }) { rows.append(row) }
                row = []
                field = ""
            } else {
                field.append(character)
            }
            index = source.index(after: index)
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            if !row.allSatisfy({ $0.isEmpty }) { rows.append(row) }
        }
        return rows
    }

    struct ZIPEntry: Equatable {
        let name: String
        let isDirectory: Bool
    }

    func validateZIP(_ archive: URL) throws -> [ZIPEntry] {
#if os(Windows)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe")
        process.arguments = [
            "-NoProfile", "-NonInteractive", "-Command",
            "Add-Type -AssemblyName System.IO.Compression.FileSystem; $z=[IO.Compression.ZipFile]::OpenRead($args[0]); $total=0; if($z.Entries.Count -gt 100000){throw 'too many entries'}; foreach($e in $z.Entries){$n=$e.FullName; $parts=$n -split '[/\\\\]'; if([IO.Path]::IsPathRooted($n) -or $parts -contains '..' -or $n -match '^[A-Za-z]:' -or (($e.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000){throw 'unsafe entry'}; if($e.Length -gt 67108864){throw 'entry too large'}; $total += $e.Length; if($total -gt 1073741824){throw 'archive too large'}}; $z.Dispose()",
            archive.path,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ImportError.archiveExtractionFailed }
        return []
#else
        let listing = try runUnzip(["-Z", "-l", archive.path])
        var kinds: [(mode: Character, size: Int)] = []
        for line in String(decoding: listing, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(maxSplits: 9, omittingEmptySubsequences: true) { $0.isWhitespace }
            guard fields.count == 10, let size = Int(fields[3]) else { continue }
            kinds.append((fields[0].first ?? "?", size))
        }
        // Names come from `-Z -1`, which prints them verbatim; `-Z -l` supplies
        // the matching mode and declared size in the same order.
        let names = String(decoding: try runUnzip(["-Z", "-1", archive.path]), as: UTF8.self)
            .split(separator: "\n").map(String.init)
        guard names.count == kinds.count else { throw ImportError.archiveExtractionFailed }
        var entries: [ZIPEntry] = []
        var seen: Set<String> = []
        var total = 0
        for (name, kind) in zip(names, kinds) {
            // `?` is a regular file stored without Unix file-type bits (for
            // example by Python's zipfile); symlinks and devices stay unsafe.
            guard kind.mode == "-" || kind.mode == "?" || kind.mode == "d", safeArchivePath(name) else {
                throw ImportError.unsafeSource(name)
            }
            // Duplicate names would make `unzip` prompt or overwrite silently.
            guard let normalized = normalizedArchivePath(name), seen.insert(normalized).inserted else {
                throw ImportError.unsafeSource(name)
            }
            total += kind.size
            guard entries.count < 100_000, kind.size <= maximumFileBytes, total <= maximumTotalBytes else {
                throw ImportError.fileTooLarge(name)
            }
            entries.append(ZIPEntry(name: name, isDirectory: kind.mode == "d" || name.hasSuffix("/")))
        }
        return entries
#endif
    }

    private func runUnzip(_ arguments: [String]) throws -> Data {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw ImportError.archiveExtractionFailed }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, output.count <= 32 * 1024 * 1024 else {
            throw ImportError.archiveExtractionFailed
        }
        return output
    }

    private func safeArchivePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !(path as NSString).isAbsolutePath,
              path.range(of: #"^[A-Za-z]:"#, options: .regularExpression) == nil
        else { return false }
        return !path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).contains("..")
    }

    private func normalizedArchivePath(_ path: String) -> String? {
        let components = path.split(separator: "/").filter { $0 != "." }
        return components.isEmpty ? nil : components.joined(separator: "/")
    }

    func extractZIP(_ archive: URL, entries: [ZIPEntry], into destination: URL) throws {
#if os(Windows)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe")
        process.arguments = ["-NoProfile", "-NonInteractive", "-Command", "Expand-Archive -LiteralPath $args[0] -DestinationPath $args[1] -Force", archive.path, destination.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw ImportError.archiveExtractionFailed
        }
        guard process.terminationStatus == 0 else { throw ImportError.archiveExtractionFailed }
#else
        // Declared sizes can lie. First stream every decompressed byte through
        // a counter without touching the disk, so the real total bounds what
        // extraction may write; one `unzip -p` pass stays linear in archive
        // size, unlike one process per entry.
        let counter = Process()
        let stream = Pipe()
        counter.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        counter.arguments = ["-p", archive.path]
        counter.standardInput = FileHandle.nullDevice
        counter.standardOutput = stream
        counter.standardError = FileHandle.nullDevice
        do { try counter.run() } catch { throw ImportError.archiveExtractionFailed }
        var total = 0
        while let chunk = try stream.fileHandleForReading.read(upToCount: 1 << 20), !chunk.isEmpty {
            total += chunk.count
            guard total <= maximumTotalBytes else {
                counter.terminate()
                counter.waitUntilExit()
                throw ImportError.fileTooLarge(archive.path)
            }
        }
        counter.waitUntilExit()
        guard counter.terminationStatus == 0 else { throw ImportError.archiveExtractionFailed }

        // One extraction pass. Names were validated and deduplicated, and
        // `-n` never overwrites, so nothing can land twice or prompt.
        let extract = Process()
        extract.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        extract.arguments = ["-qq", "-n", archive.path, "-d", destination.path]
        extract.standardInput = FileHandle.nullDevice
        extract.standardOutput = FileHandle.nullDevice
        extract.standardError = FileHandle.nullDevice
        do { try extract.run() } catch { throw ImportError.archiveExtractionFailed }
        extract.waitUntilExit()
        guard extract.terminationStatus == 0 else { throw ImportError.archiveExtractionFailed }

        for entry in entries where !entry.isDirectory {
            guard let normalized = normalizedArchivePath(entry.name) else { throw ImportError.unsafeSource(entry.name) }
            let target = destination.appendingPathComponent(normalized).standardizedFileURL
            let size = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? NSNumber)??.intValue ?? 0
            guard size <= maximumFileBytes else { throw ImportError.fileTooLarge(entry.name) }
        }
#endif
    }

    private func singleContentRoot(in extracted: URL) -> URL {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: extracted,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ), entries.count == 1,
           (try? entries[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        else { return extracted }
        return entries[0]
    }

    private func relativePath(_ file: URL, root: URL) -> String? {
        let fileParts = file.standardizedFileURL.pathComponents
        let rootParts = root.standardizedFileURL.pathComponents
        guard fileParts.starts(with: rootParts) else { return nil }
        return fileParts.dropFirst(rootParts.count).joined(separator: "/")
    }

    private func isWithin(_ candidate: URL, root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }
}
