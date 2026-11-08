import XCTest
import Foundation

/// Retex is a neutral tool. Its shipped source, docs, skills, scripts and README
/// must not name a model, provider, fallback choice, or a person's/client's/project's
/// name: those belong in the operator's own config and vault. This test keeps it that way.
///
/// Exclusions:
/// - LICENSE and package metadata (Package.swift/Package.resolved) are intentionally
///   not scanned: they carry legal attribution (author/copyright) that must remain.
/// - Provider-adapter code that must name its own provider catalog may stay, but must
///   not set defaults. Add such files to `allowedFiles` with a comment when needed.
final class NeutralityTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/RetexCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
    }

    private var shippedPaths: [String] {
        ["Sources", "docs", "skills", "scripts", "Tests", "README.md"]
    }

    // Provider-adapter code that names a provider's own catalog. These may name
    // models but must not set defaults. Empty currently; add relative paths here.
    private let allowedFiles: Set<String> = []

    // Documented exceptions for product technical identity (e.g. bundle ids).
    // Each entry is (relative file path, substring) and must be commented.
    private let allowedLineSubstrings: [(file: String, substring: String)] = [
        // The project's own repository and release URLs (install commands, badges).
        ("README.md", "michael-berardi/retex"),
    ]

    // Model IDs and provider/paid-route choices that only an operator should choose.
    private let modelChoiceRegex = try! NSRegularExpression(
        pattern: #"gpt-[56][a-z0-9.-]*|deepseek[a-z0-9.-]*|opencode-go/|openrouter/|:exacto|mimo-v[0-9][a-z0-9.-]*|glm-[0-9][a-z0-9.-]*|claude-[a-z0-9.-]*-5-5|(haiku|sonnet|opus)[ -]?5[.-]5"#,
        options: [.caseInsensitive]
    )

    // Names of the people and organisations Retex was first built for: never in the shipped tool.
    private let personalRegex = try! NSRegularExpression(
        pattern: #"Mike|Berardi|Dana|Felix|acme|acme|Mouseia|Liberty Design|libertydesign|acme|/Users/"#,
        options: [.caseInsensitive]
    )

    func testShippedFilesShipNoModelChoice() throws {
        let hits = try scanShippedFiles { file, _, line in
            !allowedFiles.contains(file)
                && !isAllowedLine(file: file, line: line)
                && modelChoiceRegex.firstMatch(
                    in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)
                ) != nil
        }
        XCTAssertTrue(
            hits.isEmpty,
            "Found model/provider choices in shipped files:\n\(hits.joined(separator: "\n"))"
        )
    }

    func testShippedFilesNameNoPersonOrProject() throws {
        let hits = try scanShippedFiles { file, _, line in
            !allowedFiles.contains(file)
                && !isAllowedLine(file: file, line: line)
                && personalRegex.firstMatch(
                    in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)
                ) != nil
        }
        XCTAssertTrue(
            hits.isEmpty,
            "Found personal/project names in shipped files:\n\(hits.joined(separator: "\n"))"
        )
    }

    private func isAllowedLine(file: String, line: String) -> Bool {
        allowedLineSubstrings.contains { file == $0.file && line.contains($0.substring) }
    }

    private func scanShippedFiles(
        _ predicate: (String, Int, String) -> Bool
    ) throws -> [String] {
        var hits: [String] = []
        for path in shippedPaths {
            let fullPath = repoRoot.appendingPathComponent(path)
            if path == "README.md" {
                let lines = try String(contentsOf: fullPath, encoding: .utf8)
                    .components(separatedBy: .newlines)
                for (index, line) in lines.enumerated() where predicate(path, index + 1, line) {
                    hits.append("\(path):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
                continue
            }
            guard let enumerator = FileManager.default.enumerator(
                at: fullPath,
                includingPropertiesForKeys: [.isRegularFileKey]
            ) else { continue }
            while let fileURL = enumerator.nextObject() as? URL {
                guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                      values.isRegularFile == true else { continue }
                let relativePath = fileURL.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
                if allowedFiles.contains(relativePath) || relativePath == "Tests/RetexCoreTests/NeutralityTests.swift" { continue }
                guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
                let lines = content.components(separatedBy: .newlines)
                for (index, line) in lines.enumerated() where predicate(relativePath, index + 1, line) {
                    hits.append("\(relativePath):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        return hits
    }
}
