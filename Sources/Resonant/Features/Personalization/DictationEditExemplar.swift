import Foundation

/// A pasted→edited pair mined from the correction-event log, injected into the
/// cloud cleanup prompt as a few-shot example of how this user rewrites our
/// output on a surface. Carries style evidence the word-level diff engine
/// discards (multi-word rephrasing, tightening, casing habits).
struct DictationEditExemplar: Codable, Sendable, Hashable {
    var original: String
    var edited: String
}

/// Decides which pasted→edited pairs are safe to show the cleanup model.
/// Full rewrites teach content instead of style, and near-identical pairs
/// teach nothing — both are dropped rather than truncated or repaired.
enum DictationEditExemplarFilter {
    static let maximumCharacters = 240
    static let minimumOriginalCharacters = 12
    static let minimumEditedCharacters = 8
    /// Shared unique tokens over the larger unique-token set. Below this the
    /// edit is a rewrite/navigation artifact, not a style correction.
    static let minimumTokenOverlap = 0.5

    static func candidate(original: String, edited: String) -> DictationEditExemplar? {
        let trimmedOriginal = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEdited = edited.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedOriginal != trimmedEdited else { return nil }
        guard trimmedOriginal.count >= minimumOriginalCharacters,
              trimmedEdited.count >= minimumEditedCharacters,
              trimmedOriginal.count <= maximumCharacters,
              trimmedEdited.count <= maximumCharacters
        else { return nil }
        guard tokenOverlap(trimmedOriginal, trimmedEdited) >= minimumTokenOverlap else { return nil }
        return DictationEditExemplar(original: trimmedOriginal, edited: trimmedEdited)
    }

    private static func tokenOverlap(_ lhs: String, _ rhs: String) -> Double {
        let lhsTokens = uniqueTokens(lhs)
        let rhsTokens = uniqueTokens(rhs)
        guard !lhsTokens.isEmpty, !rhsTokens.isEmpty else { return 0 }
        let shared = lhsTokens.intersection(rhsTokens).count
        return Double(shared) / Double(max(lhsTokens.count, rhsTokens.count))
    }

    private static func uniqueTokens(_ text: String) -> Set<String> {
        let withoutRedactionPlaceholders = text.replacingOccurrences(
            of: #"\[redacted-[^\]]+\]"#,
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )
        return Set(
            withoutRedactionPlaceholders.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        )
    }
}

/// Reduces obvious identifier leakage and neutralizes prompt-shaped text before
/// an opted-in exemplar reaches a cloud instruction. This is deliberately
/// described as limited redaction, not anonymization: consent and the HIPAA
/// veto remain the primary privacy controls.
enum DictationEditExemplarSanitizer {
    static let maximumExamples = 3

    private struct ReplacementRule {
        let regex: NSRegularExpression
        let replacement: String
    }

    private static let promptLineRules = [
        ReplacementRule(
            regex: expression(
                #"(?im)^[\s>*#-]*(?:system(?:\s+message)?|developer|assistant|user|instruction|instructions|prompt)\s*:[^\r\n]*"#
            ),
            replacement: "[redacted-prompt]"
        ),
        ReplacementRule(
            regex: expression(
                #"(?im)^[\s>*#-]*(?:ignore|disregard|forget|override)\b[^\r\n]{0,160}(?:instruction|prompt|system|above|previous)\b[^\r\n]*"#
            ),
            replacement: "[redacted-prompt]"
        ),
    ]

    private static let contentRules = [
        ReplacementRule(
            regex: expression(
                #"(?i)(?:`{3,}|~{3,}|\"{3,}|'{3,}|<<\s*/?\s*SYS\s*>>|\[\s*/?\s*INST\s*\]|<\|[^|\r\n]{1,80}\|>|<\s*/?\s*(?:system|developer|assistant|user|instruction|prompt)\b[^>]*>|\b(?:BEGIN|END)\s+(?:SYSTEM|DEVELOPER|ASSISTANT|USER|INSTRUCTION|PROMPT)\b)"#
            ),
            replacement: "[redacted-prompt]"
        ),
        ReplacementRule(
            regex: expression(#"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,63}\b"#),
            replacement: "[redacted-email]"
        ),
        ReplacementRule(
            regex: expression(
                #"(?i)(?:\b(?:[a-z][a-z0-9+.-]{1,31}://|www\.)[^\s<>\"']+|\b(?:[a-z0-9](?:[a-z0-9-]{0,62})\.)+[a-z]{2,63}\b(?:/[^\s<>\"']*)?)"#
            ),
            replacement: "[redacted-url]"
        ),
        ReplacementRule(
            regex: expression(#"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b"#),
            replacement: "[redacted-identifier]"
        ),
        ReplacementRule(
            regex: expression(
                #"(?i)\b(?=[a-z0-9_-]{12,}\b)(?=[a-z0-9_-]*[a-z])(?=[a-z0-9_-]*\d)[a-z0-9_-]+\b"#
            ),
            replacement: "[redacted-identifier]"
        ),
        ReplacementRule(
            regex: expression(#"(?<!\w)\+?\d(?:[\s().-]*\d){6,}(?!\w)"#),
            replacement: "[redacted-phone]"
        ),
        ReplacementRule(
            regex: expression(#"\b\d{6,}\b"#),
            replacement: "[redacted-identifier]"
        ),
    ]

    private static let whitespaceRegex = expression(#"\s+"#)
    private static let placeholderRegex = expression(
        #"(?i)\[redacted-(?:email|url|phone|identifier|prompt)\]"#
    )

    static func sanitizedCandidates(
        _ exemplars: [DictationEditExemplar]
    ) -> [DictationEditExemplar] {
        var seen = Set<DictationEditExemplar>()
        var result: [DictationEditExemplar] = []

        for exemplar in exemplars {
            guard result.count < maximumExamples else { break }
            guard let candidate = sanitizedCandidate(exemplar), seen.insert(candidate).inserted else {
                continue
            }
            result.append(candidate)
        }
        return result
    }

    static func sanitizedCandidate(
        _ exemplar: DictationEditExemplar
    ) -> DictationEditExemplar? {
        let original = sanitize(exemplar.original)
        let edited = sanitize(exemplar.edited)

        guard !isMostlyPlaceholder(original), !isMostlyPlaceholder(edited) else {
            return nil
        }

        // Re-run every eligibility predicate on the actual text that would be
        // sent. Redaction must not turn a low-overlap or identical pair into a
        // seemingly useful example.
        return DictationEditExemplarFilter.candidate(original: original, edited: edited)
    }

    static func sanitize(_ text: String) -> String {
        // Remove embedded controls before matching syntax so a NUL or bidi
        // mark cannot split `SYSTEM:` or a model delimiter. Preserve line
        // boundaries for the multiline rules, then flatten them below.
        var value = removingUnsafeScalars(from: text, preserveLineBreaks: true)
        for rule in promptLineRules {
            value = replacingMatches(in: value, rule: rule)
        }

        value = removingUnsafeScalars(from: value, preserveLineBreaks: false)

        for rule in contentRules {
            value = replacingMatches(in: value, rule: rule)
        }
        value = whitespaceRegex.stringByReplacingMatches(
            in: value,
            range: NSRange(value.startIndex..<value.endIndex, in: value),
            withTemplate: " "
        )
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isMostlyPlaceholder(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let placeholderCount = placeholderRegex.numberOfMatches(in: text, range: range)
        guard placeholderCount > 0 else { return false }

        let visible = placeholderRegex.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: " "
        )
        let visibleTokens = visible
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return visibleTokens.count <= placeholderCount
    }

    private static func replacingMatches(in value: String, rule: ReplacementRule) -> String {
        rule.regex.stringByReplacingMatches(
            in: value,
            range: NSRange(value.startIndex..<value.endIndex, in: value),
            withTemplate: rule.replacement
        )
    }

    private static func removingUnsafeScalars(
        from value: String,
        preserveLineBreaks: Bool
    ) -> String {
        String(value.unicodeScalars.map { scalar in
            if preserveLineBreaks && (scalar.value == 0x0A || scalar.value == 0x0D) {
                return String(scalar)
            }
            if CharacterSet.controlCharacters.contains(scalar) || isDangerousFormatScalar(scalar) {
                return preserveLineBreaks ? "" : " "
            }
            return String(scalar)
        }.joined())
    }

    private static func isDangerousFormatScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x206F, 0xFEFF:
            true
        default:
            false
        }
    }

    private static func expression(_ pattern: String) -> NSRegularExpression {
        // Patterns are static, covered by focused tests, and programmer-owned.
        try! NSRegularExpression(pattern: pattern)
    }
}
