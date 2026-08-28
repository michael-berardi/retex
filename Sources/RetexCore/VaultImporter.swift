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
            }
        }
    }

    private static let maximumFileBytes = 64 * 1024 * 1024
    private static let maximumTotalBytes = 1024 * 1024 * 1024
    private static let notionID = try! NSRegularExpression(pattern: #"(?i)(?:\s+|-)[0-9a-f]{32}(?=(?:\.[^./]+)?$)"#)

    public init() {}

    public func importSource(
        _ source: URL,
        into destination: URL,
        format requestedFormat: VaultImportFormat = .auto
    ) throws -> VaultImportResult {
        let fm = FileManager.default
        let sourceURL = source.standardizedFileURL
        let destinationURL = destination.standardizedFileURL
        try requireEmptyDestination(destinationURL)

        let temporary = fm.temporaryDirectory.appendingPathComponent("retex-import-\(UUID().uuidString)", isDirectory: true)
        var importRoot = sourceURL
        var extracted = false
        if sourceURL.pathExtension.lowercased() == "zip" {
            let values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  (values.fileSize ?? 0) <= Self.maximumTotalBytes
            else { throw ImportError.fileTooLarge(sourceURL.path) }
            try validateZIP(sourceURL)
            try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
            try extractZIP(sourceURL, into: temporary)
            importRoot = singleContentRoot(in: temporary)
            extracted = true
        } else {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ImportError.unsupportedSource
            }
        }
        defer {
            if extracted { try? fm.removeItem(at: temporary) }
        }

        let format = requestedFormat == .auto ? detectFormat(root: importRoot, wasZIP: extracted) : requestedFormat
        let files = try inventory(root: importRoot)
        let pathMap = normalizedPaths(files: files, root: importRoot, notion: format == .notion)
        try fm.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        var notes = 0
        var assets = 0
        var convertedTables = 0
        for file in files {
            guard let relative = relativePath(file, root: importRoot), let mapped = pathMap[relative] else {
                throw ImportError.unsafeSource(file.path)
            }
            let target = destinationURL.appendingPathComponent(mapped).standardizedFileURL
            guard isWithin(target, root: destinationURL) else { throw ImportError.unsafeSource(file.path) }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)

            let ext = file.pathExtension.lowercased()
            if ext == "md" {
                var markdown = try String(contentsOf: file, encoding: .utf8)
                if format == .notion { markdown = rewriteNotionLinks(markdown, pathMap: pathMap) }
                try markdown.write(to: target, atomically: true, encoding: .utf8)
                notes += 1
            } else {
                try fm.copyItem(at: file, to: target)
                assets += 1
                if format == .notion, ext == "csv" {
                    let markdownURL = target.deletingPathExtension().appendingPathExtension("md")
                    if !fm.fileExists(atPath: markdownURL.path) {
                        let table = try notionTable(from: file, title: markdownURL.deletingPathExtension().lastPathComponent)
                        try table.write(to: markdownURL, atomically: true, encoding: .utf8)
                        notes += 1
                        convertedTables += 1
                    }
                }
            }
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
            guard size <= Self.maximumFileBytes, total <= Self.maximumTotalBytes else {
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

    private func normalizedPaths(files: [URL], root: URL, notion: Bool) -> [String: String] {
        var result: [String: String] = [:]
        var used: Set<String> = []
        for file in files {
            guard let relative = relativePath(file, root: root) else { continue }
            let components = relative.split(separator: "/").map(String.init)
            let normalized = components.map { notion ? stripNotionID($0) : $0 }.joined(separator: "/")
            let base = normalized.isEmpty ? file.lastPathComponent : normalized
            var candidate = base
            var suffix = 2
            while used.contains(candidate.lowercased()) {
                let url = URL(fileURLWithPath: base)
                let stem = url.deletingPathExtension().path
                let ext = url.pathExtension
                candidate = ext.isEmpty ? "\(stem)-\(suffix)" : "\(stem)-\(suffix).\(ext)"
                suffix += 1
            }
            used.insert(candidate.lowercased())
            result[relative] = candidate
        }
        return result
    }

    private func stripNotionID(_ component: String) -> String {
        let range = NSRange(component.startIndex..<component.endIndex, in: component)
        let stripped = Self.notionID.stringByReplacingMatches(in: component, range: range, withTemplate: "")
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func rewriteNotionLinks(_ markdown: String, pathMap: [String: String]) -> String {
        var rewritten = markdown
        for (source, destination) in pathMap where source != destination {
            let sourceName = URL(fileURLWithPath: source).lastPathComponent
            let destinationName = URL(fileURLWithPath: destination).lastPathComponent
            rewritten = rewritten.replacingOccurrences(of: sourceName, with: destinationName)
            if let encodedSource = sourceName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
               let encodedDestination = destinationName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
                rewritten = rewritten.replacingOccurrences(of: encodedSource, with: encodedDestination)
            }
        }
        return rewritten
    }

    private func notionTable(from csvURL: URL, title: String) throws -> String {
        let rows = parseCSV(try String(contentsOf: csvURL, encoding: .utf8))
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

    private func validateZIP(_ archive: URL) throws {
#if os(Windows)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe")
        process.arguments = [
            "-NoProfile", "-NonInteractive", "-Command",
            "Add-Type -AssemblyName System.IO.Compression.FileSystem; $z=[IO.Compression.ZipFile]::OpenRead($args[0]); $total=0; if($z.Entries.Count -gt 100000){throw 'too many entries'}; foreach($e in $z.Entries){$n=$e.FullName; $parts=$n -split '[/\\\\]'; if([IO.Path]::IsPathRooted($n) -or $parts -contains '..' -or $n -match '^[A-Za-z]:' -or (($e.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000){throw 'unsafe entry'}; if($e.Length -gt 67108864){throw 'entry too large'}; $total += $e.Length; if($total -gt 1073741824){throw 'archive too large'}}; $z.Dispose()",
            archive.path,
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ImportError.archiveExtractionFailed }
#else
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-Z", "-l", archive.path]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, output.count <= 32 * 1024 * 1024 else {
            throw ImportError.archiveExtractionFailed
        }
        var entries = 0
        var total = 0
        for line in String(decoding: output, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(maxSplits: 9, omittingEmptySubsequences: true) { $0.isWhitespace }
            guard fields.count == 10, let size = Int(fields[3]) else { continue }
            let mode = fields[0]
            let name = String(fields[9])
            guard (mode.first == "-" || mode.first == "d"), safeArchivePath(name) else {
                throw ImportError.unsafeSource(name)
            }
            entries += 1
            total += size
            guard entries <= 100_000, size <= Self.maximumFileBytes, total <= Self.maximumTotalBytes else {
                throw ImportError.fileTooLarge(name)
            }
        }
        let namesProcess = Process()
        let namesOutput = Pipe()
        namesProcess.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        namesProcess.arguments = ["-Z", "-1", archive.path]
        namesProcess.standardOutput = namesOutput
        namesProcess.standardError = Pipe()
        try namesProcess.run()
        let namesData = namesOutput.fileHandleForReading.readDataToEndOfFile()
        namesProcess.waitUntilExit()
        let names = String(decoding: namesData, as: UTF8.self).split(separator: "\n").map(String.init)
        guard namesProcess.terminationStatus == 0,
              names.count == entries,
              names.allSatisfy(safeArchivePath)
        else { throw ImportError.archiveExtractionFailed }
#endif
    }

    private func safeArchivePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !(path as NSString).isAbsolutePath,
              path.range(of: #"^[A-Za-z]:"#, options: .regularExpression) == nil
        else { return false }
        return !path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).contains("..")
    }

    private func extractZIP(_ archive: URL, into destination: URL) throws {
        let process = Process()
#if os(macOS)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, destination.path]
#elseif os(Windows)
        process.executableURL = URL(fileURLWithPath: "C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe")
        process.arguments = ["-NoProfile", "-NonInteractive", "-Command", "Expand-Archive -LiteralPath $args[0] -DestinationPath $args[1] -Force", archive.path, destination.path]
#else
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-qq", archive.path, "-d", destination.path]
#endif
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw ImportError.archiveExtractionFailed
        }
        guard process.terminationStatus == 0 else { throw ImportError.archiveExtractionFailed }
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
