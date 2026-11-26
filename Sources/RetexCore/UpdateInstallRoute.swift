import Foundation

/// A binary that Homebrew installed is upgraded by Homebrew, never
/// overwritten. Retex ships only as a release binary or a source build, so
/// this is the one package manager that can own it.
public struct UpdateInstallRoute: Equatable, Sendable {
    /// What the notice and `retex update` tell the user to run.
    public let command: String
    /// Arguments for `/usr/bin/env`.
    public let arguments: [String]

    public static func packageManager(for executable: URL) -> UpdateInstallRoute? {
        let parts = executable.resolvingSymlinksInPath().pathComponents
        guard let cellar = parts.lastIndex(of: "Cellar"), cellar + 1 < parts.count else { return nil }
        let formula = parts[cellar + 1]
        guard !formula.isEmpty, formula.allSatisfy({ $0.isLetter || $0.isNumber || "-_@.".contains($0) })
        else { return nil }
        return UpdateInstallRoute(command: "brew upgrade \(formula)", arguments: ["brew", "upgrade", formula])
    }
}
