import Foundation
import XCTest
@testable import RetexCore
#if (os(macOS) || os(Linux)) && canImport(CUltraCompact)
import CUltraCompact
#endif

final class AgentOutputTests: XCTestCase {
    private struct Item: Codable, Equatable {
        let id: Int
        let name: String
        let tags: [String]
        let note: String?
    }

    private func baseline<T: Encodable>(_ value: T) throws -> String {
        try AgentOutput.compactJSON(value)
    }

    func testCompactJSONEmptyCountAndTinyAreDeterministic() throws {
        XCTAssertEqual(try baseline([String]()), "[]")
        XCTAssertEqual(try baseline(["count": 0]), "{\"count\":0}")
        XCTAssertEqual(try baseline(["z": 1, "a": 2]), "{\"a\":2,\"z\":1}")
        XCTAssertEqual(try AgentOutput.encode(["z": 1, "a": 2]), try AgentOutput.encode(["a": 2, "z": 1]))
    }

    func testStringsUnicodeAndEscapingPreserveCanonicalJSON() throws {
        let value = ["text": "quotes \\\" slash / newline\n café 日本 😀"]
        let compact = try baseline(value)
        XCTAssertTrue(compact.contains("\\\""))
        XCTAssertTrue(compact.contains("café"))
        XCTAssertFalse(compact.contains("\\/"))
        let output = try AgentOutput.encode(value)
        XCTAssertLessThanOrEqual(output.utf8.count, compact.utf8.count)
        XCTAssertEqual(try jsonObject(output), try jsonObject(compact))
    }

    func testRepeatedObjectsHaveByteReductionGate() throws {
        let value = (0..<80).map { Item(id: $0, name: "customer", tags: ["priority", "renewal"], note: "Repeated account context") }
        let compact = try baseline(value)
        let output = try AgentOutput.encode(value)
        XCTAssertLessThanOrEqual(output.utf8.count, compact.utf8.count)
        XCTAssertEqual(try jsonObject(output), try jsonObject(compact))
    }

    func testExactUCDecodeSemanticEqualityWhenEngineAvailable() throws {
        let value = (0..<40).map { Item(id: $0, name: "契約", tags: ["重要", "renewal"], note: "Escaped \\\"text\\\"") }
        let compact = try baseline(value)
        let output = try AgentOutput.encode(value)
        #if (os(macOS) || os(Linux)) && canImport(CUltraCompact)
        let decoded = try XCTUnwrap(output.withCString { uc_decode_json($0) })
        defer { uc_free_string(decoded) }
        XCTAssertEqual(try jsonObject(String(cString: decoded)), try jsonObject(compact))
        #else
        XCTAssertEqual(try jsonObject(output), try jsonObject(compact))
        #endif
    }

    func testPassThroughForNullAndNonengineFallback() throws {
        let null: String? = nil
        XCTAssertEqual(try AgentOutput.encode(null), "null")
        let value = ["tiny": "x"]
        XCTAssertEqual(try AgentOutput.encode(value), try baseline(value), "Tiny payload must pass through when readable UC cannot beat bytes")
    }

    func testSharedVersionIsValid() {
        XCTAssertNotNil(RetexVersion.version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression))
    }

    private func jsonObject(_ string: String) throws -> Data {
        var json = string
        #if (os(macOS) || os(Linux)) && canImport(CUltraCompact)
        if let decoded = string.withCString({ uc_decode_json($0) }) {
            json = String(cString: decoded)
            uc_free_string(decoded)
        }
        #endif
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])
    }
}
