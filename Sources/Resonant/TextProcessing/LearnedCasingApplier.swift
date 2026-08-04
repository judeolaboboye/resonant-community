import Foundation

/// Applies learned casing preferences — the case-only corrections the user
/// keeps making that the dictionary pipeline discards ("figma" → "Figma",
/// "John.Doe@Company.com" for a re-cased email). Keys are lowercased tokens;
/// values carry the user's preferred casing.
enum LearnedCasingApplier {
    private static let maxReplacementsPerToken = 12

    static func apply(_ casings: [String: String], to text: String) -> String {
        guard !casings.isEmpty, !text.isEmpty else { return text }

        var result = text
        // Longest keys first so an email preference wins over a word
        // preference embedded inside it. A preferred value equal to its key is
        // still meaningful: it lowercases a token the ASR keeps capitalizing.
        for (key, preferred) in casings.sorted(by: { $0.key.count > $1.key.count }) {
            guard !key.isEmpty else { continue }
            result = applyOne(key: key, preferred: preferred, to: result)
        }
        return result
    }

    private static func applyOne(key: String, preferred: String, to text: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: key)
        let pattern: String
        if key.contains("@") {
            // Full email address: bound by non-address characters.
            pattern = #"(?i)(?<![A-Za-z0-9._%+-])"# + escaped + #"(?![A-Za-z0-9.-])"#
        } else {
            // Plain word: never re-case the leading label of a domain
            // ("substack" in "substack.com"), an email local part or domain
            // label (either side of "@"), or a handle ("@figma").
            pattern = #"(?i)(?<![@.])\b"# + escaped + #"\b(?!\.[A-Za-z]{2,})(?!@)"#
        }

        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        let matches = Array(regex.matches(in: text, range: range).prefix(maxReplacementsPerToken))
        guard !matches.isEmpty else { return text }

        let lowersFirstLetter = preferred.first.map(\.isLowercase) ?? false
        var result = text
        for match in matches.reversed() {
            guard let matchRange = Range(match.range, in: result) else { continue }
            let current = String(result[matchRange])
            guard current != preferred else { continue }
            // A preference whose target starts lowercase must not undo
            // sentence-initial capitalization.
            if lowersFirstLetter, isSentenceInitial(matchRange, in: result) { continue }
            result.replaceSubrange(matchRange, with: preferred)
        }
        return result
    }

    private static func isSentenceInitial(_ range: Range<String.Index>, in text: String) -> Bool {
        var index = range.lowerBound
        while index > text.startIndex {
            index = text.index(before: index)
            let character = text[index]
            if character.isWhitespace || character.isNewline { continue }
            return ".!?".contains(character)
        }
        return true
    }
}
