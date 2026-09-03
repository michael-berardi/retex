import Foundation
import XCTest
@testable import RetexCore

final class VocabularyExtractorTests: XCTestCase {
    private func note(_ name: String, body: String, metadata: [String: String] = [:]) -> Note {
        Note(
            url: URL(fileURLWithPath: "/tmp/\(name).md"),
            source: body,
            title: name,
            body: body,
            metadata: metadata,
            tags: [],
            modifiedAt: Date(timeIntervalSince1970: 0)
        )
    }

    func testExtractsDistinctiveProductsNamesAndRepeatedOrganizations() {
        let result = VocabularyExtractor.extract(notes: [
            note(
                "Release notes",
                body: "UltraVox integrates with Retex for Marisol Vega at Cloudflare.",
                metadata: ["company": "Northwind Research"]
            ),
            note(
                "Operations",
                body: "Cloudflare supports OpenAI tools. Marisol Vega approved UltraVox."
            ),
        ])
        let terms = Set(result.terms.map(\.term))

        XCTAssertTrue(terms.contains("UltraVox"))
        XCTAssertTrue(terms.contains("Retex"))
        XCTAssertTrue(terms.contains("OpenAI"))
        XCTAssertTrue(terms.contains("Marisol Vega"))
        XCTAssertTrue(terms.contains("Cloudflare"))
        XCTAssertTrue(terms.contains("Northwind Research"))
        XCTAssertFalse(terms.contains("integrates"))
        XCTAssertEqual(result.recordsScanned, 2)
    }

    func testIsDeterministicBoundedAndDoesNotReturnSourceText() throws {
        let privateSentence = "UltraVox secret narrative must not leave this record."
        let notes = [
            note("Zulu", body: privateSentence),
            note("Alpha", body: "Retex and OpenAI"),
        ]
        let first = VocabularyExtractor.extract(notes: notes, limit: 2)
        let second = VocabularyExtractor.extract(notes: Array(notes.reversed()), limit: 2)

        XCTAssertEqual(first.terms, second.terms)
        XCTAssertEqual(first.terms.count, 2)
        let encoded = String(decoding: try JSONEncoder().encode(first), as: UTF8.self)
        XCTAssertFalse(encoded.contains(privateSentence))
        XCTAssertFalse(encoded.contains("/tmp/"))
    }

    func testCommonSentenceStartsNeedRepetitionOrAProperPhrase() {
        let result = VocabularyExtractor.extract(notes: [
            note("Weekly Review", body: "Please update this note. This work is complete."),
        ])
        let terms = Set(result.terms.map(\.term))
        XCTAssertFalse(terms.contains("Please"))
        XCTAssertFalse(terms.contains("This"))
        XCTAssertFalse(terms.contains("Weekly"))
    }

    func testOneOffAllCapsExportWordsAreNotDistinctiveVocabulary() {
        let result = VocabularyExtractor.extract(notes: [
            note("Statement", body: "DESCRIPTION AMOUNT TRANSACTIONS TOTAL"),
        ])
        let terms = Set(result.terms.map(\.term))
        XCTAssertFalse(terms.contains("DESCRIPTION"))
        XCTAssertFalse(terms.contains("AMOUNT"))
        XCTAssertFalse(terms.contains("TRANSACTIONS"))
    }

    func testExtractsNameSubphrasesAndPrefersNaturalCasing() {
        let result = VocabularyExtractor.extract(notes: [
            note("Statement", body: "Description Amount MARISOL VEGA Transactions Total"),
            note("Profile", body: "Marisol Vega CERT approved the profile."),
        ])
        XCTAssertTrue(result.terms.map(\.term).contains("Marisol Vega"))
    }

    func testRecurringBodyEntityOutranksOneOffMetadataNoise() {
        let noise = (0..<300).map { index in
            note("Record \(index)", body: "ordinary text", metadata: ["company": "Vendor \(index)"])
        }
        let names = [
            note("Profile A", body: "Marisol Vega approved the profile."),
            note("Profile B", body: "Marisol Vega reviewed the project."),
        ]
        let result = VocabularyExtractor.extract(notes: noise + names, limit: 10)
        XCTAssertTrue(result.terms.map(\.term).contains("Marisol Vega"))
    }

    func testStructuralBoundariesDoNotCreateSourceExcerptsEvenWhenRepeated() throws {
        let source = """
        /Users/alice/Documents/AcmeProject
        Marisol Vega — Confidential Merger
        Northwind Research, Internal Project
        ClientName=SecretPlans
        InternalPlans: Confidential Merger
        """
        let result = VocabularyExtractor.extract(notes: [
            note("Private export A", body: source),
            note("Private export B", body: source),
        ])
        let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        for fragment in [
            "Users alice", "alice Documents", "Vega Confidential", "Research Internal",
            "ClientName SecretPlans", "InternalPlans Confidential",
        ] {
            XCTAssertFalse(encoded.localizedCaseInsensitiveContains(fragment))
        }
    }

    func testSensitiveIdentifiersAndFinancialLabelsNeverCrossBoundary() throws {
        let privateValues = [
            "Marisol Vega 4111-1111-1111-1111",
            "Northwind Research 202-555-0199",
            "Alpha 123-45-6789",
            "SecureHost 192.168.1.7",
            "OpenAI acct_9F3K2LMN8PQ7RSTU",
            "Retex invoice 849201",
        ]
        let result = VocabularyExtractor.extract(notes: [
            note(
                "Private export",
                body: "ordinary text",
                metadata: [
                    "company": privateValues[0],
                    "customTerms": privateValues.dropFirst().joined(separator: ","),
                ]
            ),
        ])
        let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        for value in ["4111-1111", "202-555", "123-45", "192.168", "9F3K2LMN8PQ7RSTU", "849201", "invoice"] {
            XCTAssertFalse(encoded.localizedCaseInsensitiveContains(value))
        }
    }
}
