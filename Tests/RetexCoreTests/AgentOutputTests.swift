import Foundation
import XCTest
@testable import RetexCore

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
        XCTAssertEqual(try AgentOutput.compactJSON(["z": 1, "a": 2]), try AgentOutput.compactJSON(["a": 2, "z": 1]))
    }

    func testStringsUnicodeAndEscapingPreserveCanonicalJSON() throws {
        let value = ["text": "quotes \\\" slash / newline\n café 日本 😀"]
        let compact = try baseline(value)
        XCTAssertTrue(compact.contains("\\\""))
        XCTAssertTrue(compact.contains("café"))
        XCTAssertFalse(compact.contains("\\/"))
        let output = try AgentOutput.compactJSON(value)
        XCTAssertEqual(output, compact)
        XCTAssertEqual(try jsonObject(output), try jsonObject(compact))
    }

    func testRepeatedObjectsAreCompactJSON() throws {
        let value = (0..<80).map { Item(id: $0, name: "customer", tags: ["priority", "renewal"], note: "Repeated account context") }
        let compact = try baseline(value)
        let output = try AgentOutput.compactJSON(value)
        XCTAssertEqual(output, compact)
        XCTAssertEqual(try jsonObject(output), try jsonObject(compact))
    }

    func testNullAndTinyPayloadsAreCompactJSON() throws {
        let null: String? = nil
        XCTAssertEqual(try AgentOutput.compactJSON(null), "null")
        let value = ["tiny": "x"]
        XCTAssertEqual(try AgentOutput.compactJSON(value), try baseline(value))
    }

    func testSharedVersionIsValid() {
        XCTAssertNotNil(RetexVersion.version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression))
    }

    private func jsonObject(_ string: String) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: Data(string.utf8), options: [.fragmentsAllowed])
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])
    }
}
