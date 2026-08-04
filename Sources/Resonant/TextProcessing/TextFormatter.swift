import Foundation

enum TextFormatter {

    enum OrdinaryTrailingPeriodState: Sendable, Equatable {
        case present
        case absent
        case inapplicable
    }

    static func finalize(
        _ text: String,
        bulletPointsEnabled: Bool = false,
        ensureTrailingPunctuation: Bool = false,
        capitalizeLeadingLetters: Bool = true
    ) -> String {
        let normalized = normalizedSpacing(text)
        guard !normalized.isEmpty else {
            return normalized
        }

        // Text that already carries explicit line structure (spoken commands,
        // cloud formatting) skips the list heuristics — the user has decided.
        if normalized.contains("\n") {
            var result = capitalizeLeadingLetters ? capitalizedLineLeads(in: normalized) : normalized
            if ensureTrailingPunctuation {
                result = ensuredTrailingPunctuation(result)
            }
            return result
        }

        if bulletPointsEnabled, let list = smartBulletList(from: normalized) {
            return list
        }

        var result = capitalizeLeadingLetters ? capitalizedLeadingLetter(in: normalized) : normalized

        if ensureTrailingPunctuation {
            result = ensuredTrailingPunctuation(result)
        }

        return result
    }

    // MARK: - Smart bullet detection

    private static func smartBulletList(from text: String) -> String? {
        guard let detection = smartListItems(from: text) else { return nil }
        let lines: [String]
        if let numbers = detection.numbers {
            lines = zip(numbers, detection.items).map { number, item in
                "\(number). " + capitalizedLeadingLetter(in: normalizedSpacing(item))
            }
        } else {
            lines = detection.items.map {
                "- " + capitalizedLeadingLetter(in: normalizedSpacing($0))
            }
        }
        let body = lines.joined(separator: "\n")
        if let preamble = detection.preamble {
            return capitalizedLeadingLetter(in: preamble) + "\n" + body
        }
        return body
    }

    /// `numbers` non-nil means the user dictated an explicitly numbered
    /// sequence ("first…", "number two…") and the output is a numbered list
    /// with the markers stripped from the items.
    private struct ListDetection {
        let preamble: String?
        let items: [String]
        let numbers: [Int]?
    }

    /// Returns nil if the text doesn't look like a list.
    /// Checks high-confidence signals first (ordinals, numbering), then requires
    /// multiple weaker signals (comma noun phrases + parallel structure) to co-occur.
    private static func smartListItems(from text: String) -> ListDetection? {
        // Strong signals — each is sufficient alone
        if let result = ordinalSequenceItems(from: text), result.items.count >= 2 {
            return result
        }
        if let result = numberPrefixItems(from: text), result.items.count >= 2 {
            return result
        }

        // Comma-separated noun phrases (3+ short items, no verbs) — strong enough alone
        if let items = commaListItems(from: text), items.count >= 3 {
            return ListDetection(preamble: nil, items: items, numbers: nil)
        }

        // Parallel structure alone is weak — require co-occurrence with another signal
        // (ordinals/numbering already caught above, comma already caught above)

        return nil
    }

    /// Whether the local automatic-list stage has a genuine content-shape
    /// opportunity. Ordinary prose must not confirm an active list policy.
    static func hasAutomaticListOpportunity(in text: String) -> Bool {
        let normalized = normalizedSpacing(text)
        guard !normalized.isEmpty, !normalized.contains("\n") else { return false }
        return smartListItems(from: normalized) != nil
    }

    /// Existing explicit list structure is an opportunity too: `require` may
    /// find it already conformed, while `omit` must not claim confirmation if
    /// the explicit markers remain.
    static func hasListMarkers(in text: String) -> Bool {
        let markerPattern = try! NSRegularExpression(
            pattern: #"^\s*(?:[-*•]\s+|\d+[.)]\s+)"#
        )
        let markerCount = text.split(separator: "\n").reduce(into: 0) { count, line in
            let value = String(line)
            let range = NSRange(value.startIndex..., in: value)
            if markerPattern.firstMatch(in: value, range: range) != nil {
                count += 1
            }
        }
        return markerCount >= 2
    }

    static func hasListMarkerOpportunity(in text: String) -> Bool {
        hasListMarkers(in: text) || hasAutomaticListOpportunity(in: text)
    }

    // MARK: - Signal: Ordinal sequence ("first... second... third...")

    private static let ordinalPattern = try! NSRegularExpression(
        pattern: #"\b(first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|1st|2nd|3rd|\d+th)\b"#,
        options: [.caseInsensitive]
    )

    private static let ordinalWordValues: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5,
        "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10,
        "1st": 1, "2nd": 2, "3rd": 3,
    ]

    private static func ordinalValue(_ marker: String) -> Int? {
        let lower = marker.lowercased()
        if let value = ordinalWordValues[lower] { return value }
        if lower.hasSuffix("th"), let value = Int(lower.dropLast(2)) { return value }
        return nil
    }

    private static func ordinalSequenceItems(from text: String) -> ListDetection? {
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        let matches = ordinalPattern.matches(in: text, range: range)

        guard matches.count >= 2 else { return nil }

        // Require distinct ordinal values — "first … first" is adjective
        // usage (e.g. "privacy first … voice first"), not a numbered list.
        let values = Set(matches.map { nsText.substring(with: $0.range).lowercased() })
        guard values.count >= 2 else { return nil }

        return markerListItems(in: nsText, matches: matches, value: ordinalValue)
    }

    // MARK: - Signal: Number prefix ("number one... number two...")

    private static let numberPrefixPattern = try! NSRegularExpression(
        pattern: #"\bnumber\s+(?:\d+|one|two|three|four|five|six|seven|eight|nine|ten)\b"#,
        options: [.caseInsensitive]
    )

    private static let cardinalWordValues: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
    ]

    private static func numberPrefixValue(_ marker: String) -> Int? {
        guard let last = marker.lowercased().split(whereSeparator: \.isWhitespace).last else {
            return nil
        }
        return cardinalWordValues[String(last)] ?? Int(last)
    }

    private static func numberPrefixItems(from text: String) -> ListDetection? {
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        let matches = numberPrefixPattern.matches(in: text, range: range)

        guard matches.count >= 2 else { return nil }

        return markerListItems(in: nsText, matches: matches, value: numberPrefixValue)
    }

    /// Shared splitter for explicitly numbered dictations: strips each marker
    /// ("first", "number two") from its item and emits a numbered list.
    private static func markerListItems(
        in nsText: NSString,
        matches: [NSTextCheckingResult],
        value: (String) -> Int?
    ) -> ListDetection? {
        // Reject when substantial text precedes the first marker — long
        // preambles suggest mid-sentence modifiers rather than list markers.
        // Short preambles (≤ 3 words) are preserved in the output.
        var preambleText: String?
        let preambleEnd = matches[0].range.location
        if preambleEnd > 0 {
            let preamble = nsText.substring(with: NSRange(location: 0, length: preambleEnd))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let wordCount = preamble.split(whereSeparator: \.isWhitespace)
                .filter { $0.rangeOfCharacter(from: .letters) != nil }
                .count
            if wordCount > 3 {
                return nil
            }
            if !preamble.isEmpty {
                preambleText = preamble
            }
        }

        var items: [String] = []
        var numbers: [Int] = []

        for (i, match) in matches.enumerated() {
            let contentStart = match.range.location + match.range.length
            let end = i + 1 < matches.count ? matches[i + 1].range.location : nsText.length
            guard contentStart <= end else { continue }
            let segment = nsText.substring(
                with: NSRange(location: contentStart, length: end - contentStart)
            )
            let cleaned = cleanBulletItem(segment)
            // An empty item means adjacent markers ("first second left") —
            // that's prose, not a list.
            guard !cleaned.isEmpty else { return nil }
            let marker = nsText.substring(with: match.range)
            items.append(cleaned)
            numbers.append(value(marker) ?? items.count)
        }

        guard items.count >= 2 else { return nil }
        return ListDetection(preamble: preambleText, items: items, numbers: numbers)
    }

    // MARK: - Signal: Comma-separated noun phrases

    private static let verbPattern = try! NSRegularExpression(
        pattern: #"\b(is|are|was|were|have|has|had|do|does|did|will|would|can|could|should|may|might|shall|must)\b"#,
        options: [.caseInsensitive]
    )

    private static func commaListItems(from text: String) -> [String]? {
        let segments = text.components(separatedBy: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard segments.count >= 4 else { return nil }

        // Reject if any segment is too long — a clause with many words is
        // prose, not a list item. Prevents splitting complex sentences.
        if segments.contains(where: { $0.split(separator: " ").count > 7 }) {
            return nil
        }

        // Require enough total words — short conversational phrases shouldn't list-format
        let totalWords = segments.reduce(0) { $0 + $1.split(separator: " ").count }
        guard totalWords >= 8 else { return nil }

        let qualifying = segments.filter { segment in
            let words = segment.split(separator: " ")
            guard words.count >= 2, words.count <= 5 else { return false }
            let nsRange = NSRange(segment.startIndex..., in: segment)
            return verbPattern.firstMatch(in: segment, range: nsRange) == nil
        }

        // At least 80% of segments must qualify as noun phrases
        let threshold = Int((Double(segments.count) * 0.8).rounded(.up))
        guard qualifying.count >= threshold, qualifying.count >= 4 else { return nil }

        return segments.filter { !$0.isEmpty }
    }

    // MARK: - Signal: Parallel structure (3+ segments with same opening word)

    private static func parallelStructureItems(from text: String) -> [String]? {
        let segments = sentenceSegments(in: text)
        guard segments.count >= 3 else { return nil }

        var firstWordCounts: [String: Int] = [:]
        for segment in segments {
            let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            if let firstWord = trimmed.split(separator: " ").first {
                firstWordCounts[firstWord.lowercased(), default: 0] += 1
            }
        }

        guard (firstWordCounts.values.max() ?? 0) >= 3 else { return nil }

        return segments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Helpers

    private static func sentenceSegments(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"[^\n.!?;]+(?:[.!?;]+|$)"#
        ) else {
            return [text]
        }

        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return String(text[range])
        }
    }

    private static func cleanBulletItem(_ item: String) -> String {
        item
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: #"^(?:[-*•,.:;]\s*)+"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Collapses horizontal whitespace while preserving line structure
    /// (newlines come from spoken commands or cloud formatting).
    private static func normalizedSpacing(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(
            of: #"[ \t]+([,.;:!?])"#,
            with: "$1",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"([(\[{])[ \t]+"#,
            with: "$1",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"[ \t]{2,}"#,
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"[ \t]+\n"#,
            with: "\n",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"\n[ \t]+"#,
            with: "\n",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"\n{3,}"#,
            with: "\n\n",
            options: .regularExpression
        )
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let terminalPunctuation: Set<Character> = [
        ".", "!", "?", ",", ":", ";", "…", ")", "]", "\"", "'", "—", "-",
    ]

    /// Words that signal the sentence is unfinished — adding a period after
    /// these would break natural flow across consecutive dictations.
    private static let continuationWords: Set<String> = [
        // Articles / determiners
        "a", "an", "the", "this", "that", "these", "those", "my", "your",
        "his", "her", "its", "our", "their", "some", "any", "no", "every",
        // Prepositions
        "to", "for", "in", "on", "at", "by", "with", "from", "of", "about",
        "into", "onto", "upon", "over", "under", "between", "through",
        "during", "before", "after", "without", "within", "among",
        // Conjunctions
        "and", "but", "or", "nor", "so", "yet", "because", "since", "while",
        "although", "though", "if", "unless", "until", "whether",
        // Relative / subordinating
        "that", "which", "who", "whom", "whose", "when", "where", "how",
        // Auxiliary / linking verbs
        "is", "are", "was", "were", "be", "been", "being",
        "have", "has", "had", "do", "does", "did",
        "will", "would", "shall", "should", "can", "could",
        "may", "might", "must",
        // Common mid-sentence modifiers
        "not", "also", "just", "very", "really", "then", "than",
    ]

    /// Classifies the ordinary declarative-period opportunity shared by local
    /// provenance and final-delivery validation. Questions, exclamations,
    /// ellipses, lists, explicit alternate punctuation, and unfinished clauses
    /// are not evidence for either requiring or omitting a period.
    static func ordinaryTrailingPeriodState(in text: String) -> OrdinaryTrailingPeriodState {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !hasListMarkers(in: trimmed) else {
            return .inapplicable
        }
        if let finalSentence = QuestionInference.finalSemanticSentence(in: trimmed),
           QuestionInference.isQuestion(finalSentence) {
            return .inapplicable
        }
        if trimmed.hasSuffix("."), !trimmed.hasSuffix("..") {
            return .present
        }
        guard let lastCharacter = trimmed.last else { return .inapplicable }
        if terminalPunctuation.contains(lastCharacter) {
            return .inapplicable
        }
        guard let lastWord = trimmed.split(whereSeparator: \.isWhitespace).last,
              !continuationWords.contains(String(lastWord).lowercased()) else {
            return .inapplicable
        }
        return .absent
    }

    private static func ensuredTrailingPunctuation(_ text: String) -> String {
        guard let lastChar = text.last else { return text }
        if terminalPunctuation.contains(lastChar) { return text }

        // List items don't take trailing periods.
        if let lastLine = text.split(separator: "\n").last,
           lastLine.hasPrefix("- ") {
            return text
        }

        // Don't add a period if the sentence looks unfinished
        if let lastWord = text.split(separator: " ").last {
            if continuationWords.contains(String(lastWord).lowercased()) {
                return text
            }
        }

        return text + "."
    }

    /// Collapses multi-line text for single-line targets: list markers are
    /// stripped, lines join with "; " (or a plain space after sentence
    /// punctuation). "We need\n- Milk\n- Eggs" → "We need; Milk; Eggs".
    static func flattenedLineBreaks(_ text: String) -> String {
        guard text.contains("\n") else { return text }
        let lines = text.split(separator: "\n")
            .map { line -> String in
                String(line)
                    .replacingOccurrences(
                        of: #"^\s*(?:[-*•]\s+|\d+[.)]\s+)"#,
                        with: "",
                        options: .regularExpression
                    )
                    .trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }

        var result = ""
        for (index, line) in lines.enumerated() {
            result += line
            guard index < lines.count - 1 else { break }
            if let last = line.last, ".!?…:".contains(last) {
                result += " "
            } else {
                result += "; "
            }
        }
        return result
    }

    /// Capitalizes the lead letter of every line (and bullet item) in
    /// multi-line text produced by spoken structural commands.
    private static func capitalizedLineLeads(in text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let string = String(line)
                if string.hasPrefix("- ") {
                    return "- " + capitalizedLeadingLetter(in: String(string.dropFirst(2)))
                }
                return capitalizedLeadingLetter(in: string)
            }
            .joined(separator: "\n")
    }

    private static func capitalizedLeadingLetter(in text: String) -> String {
        guard let first = text.first else {
            return text
        }

        if first.isLetter && first.isLowercase {
            return first.uppercased() + text.dropFirst()
        }

        return text
    }
}
