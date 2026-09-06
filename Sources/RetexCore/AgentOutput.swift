import Foundation
#if (os(macOS) || os(Linux)) && canImport(CUltraCompact)
import CUltraCompact
#endif

/// Shared agent-facing output. The linked engine compares complete readable
/// packets against minified JSON using its default o200k tokenizer. Retex also
/// requires a byte reduction, and otherwise emits deterministic compact JSON.
/// This is not a guarantee for other tokenizers or an entire model round trip.
public enum AgentOutput {
    public static func compactJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    public static func encode<T: Encodable>(_ value: T) throws -> String {
        let baseline = try compactJSON(value)
        #if (os(macOS) || os(Linux)) && canImport(CUltraCompact)
        return baseline.withCString { input in
            guard let packet = uc_encode_readable_json(input, nil) else { return baseline }
            defer { uc_free_string(packet) }
            let encoded = String(cString: packet)
            return encoded.utf8.count < baseline.utf8.count ? encoded : baseline
        }
        #else
        return baseline
        #endif
    }
}
