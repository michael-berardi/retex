/// Single source of truth for the CLI version. scripts/release.sh verifies
/// this matches the RETEX_VERSION being released.
enum RetexBuild {
    static let version = "0.7.0"
}
