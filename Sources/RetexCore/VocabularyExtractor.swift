import Foundation

/// A bounded vocabulary candidate derived locally from Retex records.
/// No record body, excerpt, or path is included in this result.
public struct VocabularyTerm: Codable, Equatable, Sendable {
    public let term: String
    public let occurrences: Int
    public let sourceCount: Int
    /// `high` for distinctive technical spellings, `medium` for explicit
    /// metadata/title entities, and `contextual` for repeated proper names.
    public let confidence: String

    public init(term: String, occurrences: Int, sourceCount: Int, confidence: String) {
        self.term = term
        self.occurrences = occurrences
        self.sourceCount = sourceCount
        self.confidence = confidence
    }
}

public struct VocabularyResult: Codable, Equatable, Sendable {
    public let recordsScanned: Int
    public let terms: [VocabularyTerm]

    public init(recordsScanned: Int, terms: [VocabularyTerm]) {
        self.recordsScanned = recordsScanned
        self.terms = terms
    }
}

/// Extracts likely names, organizations, brands, applications, and technical
/// terms without returning source content. The implementation is deterministic
/// and uses no network service or learned model.
public enum VocabularyExtractor {
    private struct Candidate {
        var display: String
        var occurrences: Int
        var sources: Set<String>
        var priority: Int
    }

    private static let metadataKeys: Set<String> = [
        "name", "fullname", "companyname", "organizationname", "organisationname",
        "displayname", "canonicalname", "person", "people", "company", "organization",
        "organisation", "client", "brand", "app", "application", "product", "project",
        "customterm", "customterms", "vocabulary",
    ]

    private static let commonCapitalizedWords: Set<String> = [
        "about", "after", "all", "also", "and", "archive", "before", "best", "board",
        "build", "client", "complete", "current", "daily", "design", "details", "draft",
        "final", "first", "from", "guide", "help", "home", "important", "index", "into",
        "latest", "list", "monthly", "new", "next", "note", "notes", "plan", "project",
        "report", "review", "settings", "status", "system", "task", "test", "that", "the",
        "this", "todo", "update", "weekly", "with", "work",
    ]

    // Vocabulary is an intentionally lossy privacy boundary. These words are
    // useful in source records but are not safe or distinctive vocabulary,
    // including when they occur inside an otherwise proper-looking phrase.
    private static let rejectedWords: Set<String> = [
        "account", "accounts", "accountid", "amount", "amounts", "balance", "balances",
        "credential", "credentials", "credit", "credits", "debit", "debits", "description",
        "descriptions", "export", "exports", "invoice", "invoices", "key", "keys", "memo",
        "memos", "password", "passwords", "passwd", "payment", "payments", "receipt",
        "receipts", "reference", "references", "secret", "secrets", "statement", "statements",
        "token", "tokens", "total", "totals", "transaction", "transactions",
    ]

    private static let maximumCandidateBytes = 96
    private static let maximumWordBytes = 64
    private static let longIdentifierLength = 16
    private static let longAllCapsLength = 12

    public static func extract(notes: [Note], limit: Int = 256) -> VocabularyResult {
        let boundedLimit = min(max(limit, 1), 10_000)
        var candidates: [String: Candidate] = [:]

        for note in notes {
            var termsInSource: [String: (display: String, count: Int, priority: Int)] = [:]
            collectText(note.title, title: true, into: &termsInSource)
            collectText(note.body, title: false, into: &termsInSource)
            for (key, value) in note.metadata where metadataKeys.contains(normalizeMetadataKey(key)) {
                for part in value.split(separator: ",") {
                    add(String(part), count: 1, priority: 3, into: &termsInSource)
                }
            }

            for (key, local) in termsInSource {
                var candidate = candidates[key] ?? Candidate(
                    display: local.display,
                    occurrences: 0,
                    sources: [],
                    priority: local.priority
                )
                if prefersDisplay(local.display, over: candidate.display) {
                    candidate.display = local.display
                }
                candidate.occurrences += local.count
                candidate.sources.insert(note.id)
                candidate.priority = max(candidate.priority, local.priority)
                candidates[key] = candidate
            }
        }

        let eligible = candidates.values.filter { $0.priority >= 3 || $0.sources.count >= 2 }
        func ranked(_ values: [Candidate]) -> [Candidate] {
            values.sorted {
                if $0.sources.count != $1.sources.count { return $0.sources.count > $1.sources.count }
                if $0.occurrences != $1.occurrences { return $0.occurrences > $1.occurrences }
                let leftWords = $0.display.split(separator: " ").count
                let rightWords = $1.display.split(separator: " ").count
                if leftWords != rightWords { return leftWords > rightWords }
                return lexicallyPrecedes($0.display, $1.display)
            }
        }

        // Reserve capacity for each evidence class. Large imported archives can
        // contain thousands of repeated templates and one-off identifiers; no
        // one class should erase products, people, or conventional entities.
        let highQuota = (boundedLimit + 1) / 2
        let remainingQuota = boundedLimit - highQuota
        let mediumQuota = (remainingQuota + 1) / 2
        let contextualQuota = remainingQuota - mediumQuota
        let buckets: [(values: [Candidate], quota: Int)] = [
            (ranked(eligible.filter { $0.priority >= 4 }), highQuota),
            (ranked(eligible.filter { $0.priority == 3 }), mediumQuota),
            (ranked(eligible.filter { $0.priority <= 2 }), contextualQuota),
        ]
        var chosen: [Candidate] = []
        var chosenKeys: Set<String> = []
        for bucket in buckets {
            for candidate in bucket.values.prefix(bucket.quota) {
                chosen.append(candidate)
                chosenKeys.insert(normalizedKey(candidate.display))
            }
        }
        if chosen.count < boundedLimit {
            let remainder = eligible.filter { !chosenKeys.contains(normalizedKey($0.display)) }.sorted {
                if $0.priority != $1.priority { return $0.priority > $1.priority }
                if $0.sources.count != $1.sources.count { return $0.sources.count > $1.sources.count }
                if $0.occurrences != $1.occurrences { return $0.occurrences > $1.occurrences }
                return lexicallyPrecedes($0.display, $1.display)
            }
            chosen.append(contentsOf: remainder.prefix(boundedLimit - chosen.count))
        }

        let selected = chosen.map {
            VocabularyTerm(
                term: $0.display,
                occurrences: $0.occurrences,
                sourceCount: $0.sources.count,
                confidence: $0.priority >= 4 ? "high" : $0.priority == 3 ? "medium" : "contextual"
            )
        }.sorted { lexicallyPrecedes($0.term, $1.term) }

        return VocabularyResult(recordsScanned: notes.count, terms: selected)
    }

    private static func collectText(
        _ text: String,
        title: Bool,
        into local: inout [String: (display: String, count: Int, priority: Int)]
    ) {
        let words = tokenize(text)
        var distinctiveWords: Set<String> = []
        for word in words {
            if let priority = distinctivePriority(word) {
                add(word, count: 1, priority: priority, into: &local)
                distinctiveWords.insert(normalizedKey(word))
            }
        }

        // Never join proper-looking words across paths, lines, metadata-style
        // delimiters, or sentence boundaries. Body/title phrases require
        // recurrence in independent records; only explicit allowlisted
        // metadata can make a one-off phrase eligible.
        let phraseSegments = text.split {
            if $0.isNewline { return true }
            if $0.isLetter || $0.isNumber || $0.isWhitespace { return false }
            // Preserve only punctuation that can be intrinsic to a name or
            // technical term. Commas, equals signs, typographic dashes, and
            // other structural punctuation always terminate a phrase.
            return !"-'&+#".contains($0)
        }.map { tokenize(String($0)) }
        for segment in phraseSegments {
            var index = 0
            while index < segment.count {
                guard isProperWord(segment[index]) else {
                    index += 1
                    continue
                }
                let start = index
                while index < segment.count && isProperWord(segment[index]) {
                    index += 1
                }
                let end = index
                if end - start >= 2 {
                    for phraseStart in start..<(end - 1) {
                        let maximumLength = min(4, end - phraseStart)
                        for length in 2...maximumLength {
                            let phraseWords = segment[phraseStart..<(phraseStart + length)]
                            add(
                                phraseWords.joined(separator: " "),
                                count: 1,
                                priority: 2,
                                into: &local
                            )
                        }
                    }
                }
            }
        }

        // Repeated, non-generic capitalized words are useful for conventional
        // names such as Cloudflare that do not contain camel case or digits.
        for word in words where isProperWord(word) && !distinctiveWords.contains(normalizedKey(word)) {
            add(word, count: 1, priority: title ? 2 : 1, into: &local)
        }
    }

    private static func add(
        _ raw: String,
        count: Int,
        priority: Int,
        into local: inout [String: (display: String, count: Int, priority: Int)]
    ) {
        let candidate = raw
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard isSafeCandidate(candidate) else { return }
        let key = normalizedKey(candidate)
        let current = local[key]
        let display = current.map { prefersDisplay(candidate, over: $0.display) ? candidate : $0.display }
            ?? candidate
        local[key] = (
            display,
            (current?.count ?? 0) + count,
            max(current?.priority ?? 0, priority)
        )
    }

    private static func prefersDisplay(_ candidate: String, over current: String) -> Bool {
        let candidateLetters = candidate.filter(\.isLetter)
        let currentLetters = current.filter(\.isLetter)
        let candidateIsAllCaps = !candidateLetters.isEmpty && candidateLetters.allSatisfy(\.isUppercase)
        let currentIsAllCaps = !currentLetters.isEmpty && currentLetters.allSatisfy(\.isUppercase)
        if candidateIsAllCaps != currentIsAllCaps {
            return currentIsAllCaps
        }
        return candidate != current && lexicallyPrecedes(candidate, current)
    }

    private static func tokenize(_ text: String) -> [String] {
        text.precomposedStringWithCanonicalMapping.split { character in
            !(character.isLetter || character.isNumber || character == "+" || character == "#" || character == "-")
        }.lazy.map(String.init).map { $0.utf8.count <= maximumWordBytes ? $0 : "" }
    }

    private static func distinctivePriority(_ word: String) -> Int? {
        let letters = word.filter { $0.isLetter || $0.isNumber }
        guard letters.count >= 2,
              word.utf8.count <= maximumWordBytes,
              word.contains(where: { $0.isUppercase }),
              isSafeCandidate(word)
        else {
            return nil
        }
        let isAllCaps = letters.allSatisfy { !$0.isLetter || $0.isUppercase }
        let hasInternalUppercase = !isAllCaps && word.dropFirst().contains(where: { $0.isUppercase })
        let isAcronym = letters.count <= 10 && isAllCaps
        let hasDigit = word.contains(where: { $0.isNumber })
        let hasTechnicalMarker = word.contains("+") || word.contains("#")
        let hasDistinctiveEnding = !isAllCaps
            && (letters.lowercased().last.map { "qxz".contains($0) } ?? false)
        if hasInternalUppercase || hasDigit || hasTechnicalMarker || hasDistinctiveEnding {
            return 4
        }
        // OCR, statements, and exports often contain ordinary words in all
        // caps. Keep acronyms only when they recur across independent records.
        return isAcronym ? 1 : nil
    }

    private static func isProperWord(_ word: String) -> Bool {
        guard word.count >= 3,
              word.utf8.count <= maximumWordBytes,
              word.first?.isUppercase == true,
              word.contains(where: { $0.isLetter }),
              !commonCapitalizedWords.contains(word.lowercased()),
              isSafeCandidate(word)
        else { return false }
        return word.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    private static func isSafeCandidate(_ value: String) -> Bool {
        guard value.utf8.count >= 2, value.utf8.count <= maximumCandidateBytes else { return false }
        let words = value.split(separator: " ")
        guard !words.isEmpty,
              words.count <= 5,
              words.allSatisfy({ $0.utf8.count <= maximumWordBytes }),
              value.contains(where: { $0.isLetter })
        else {
            return false
        }
        guard !value.contains("@"), !value.contains("/"), !value.contains("\\") else { return false }
        guard value.allSatisfy({
            $0.isLetter || $0.isNumber || $0.isWhitespace || "-+#&.'()".contains($0)
        }) else { return false }

        // Canonical composition in `add` and `tokenize` preserves ordinary
        // accented names. Any combining scalar left afterward is malformed or
        // an attempt to hide unbounded bytes in a visually short term.
        guard !value.unicodeScalars.contains(where: CharacterSet.nonBaseCharacters.contains) else {
            return false
        }

        let digitCount = value.unicodeScalars.filter(CharacterSet.decimalDigits.contains).count
        guard digitCount < 6 else { return false }

        let components = value.unicodeScalars.split {
            !CharacterSet.alphanumerics.contains($0)
        }.map(String.init)
        guard !components.contains(where: { rejectedWords.contains($0.lowercased()) }) else {
            return false
        }
        return !components.contains(where: isLikelyIdentifier)
    }

    private static func isLikelyIdentifier(_ value: String) -> Bool {
        let characters = value.filter { $0.isLetter || $0.isNumber }
        let letters = characters.filter(\.isLetter)
        let hasDigit = characters.contains(where: \.isNumber)
        let isAllCaps = !letters.isEmpty && letters.allSatisfy(\.isUppercase)
        if characters.count >= longAllCapsLength && isAllCaps { return true }
        // Metadata fields can contain account, card, phone, or reference
        // numbers next to a person's name. Never allow a long numeric
        // component to cross the vocabulary boundary.
        if letters.isEmpty { return hasDigit && characters.count >= 6 }
        return characters.count >= longIdentifierLength && hasDigit
    }

    private static func normalizedKey(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func lexicallyPrecedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

    private static func normalizeMetadataKey(_ key: String) -> String {
        key.filter { $0.isLetter || $0.isNumber }.lowercased()
    }
}
