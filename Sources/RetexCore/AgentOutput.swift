import Foundation

/// Deterministic compact machine output shared by the CLI and MCP server.
public enum AgentOutput {
    public static func compactJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        // JSON has no non-finite numbers, and the default strategy makes one
        // stray `nan` refuse a whole payload. Model values that reach the wire
        // are already guarded (`Note.rank`), so this only decides what happens
        // to a number a caller passed through verbatim: a stable string token
        // instead of a failed response. Finite numbers are untouched.
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "infinity",
            negativeInfinity: "-infinity",
            nan: "nan"
        )
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
