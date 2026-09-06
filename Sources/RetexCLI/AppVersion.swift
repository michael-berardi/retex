import RetexCore

/// Compatibility facade; CLI and MCP share RetexCore's product version.
enum RetexBuild {
    static let version = RetexVersion.version
}
