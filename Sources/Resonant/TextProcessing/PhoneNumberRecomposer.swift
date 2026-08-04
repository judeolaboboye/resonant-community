import Foundation

/// Recomposes dictated phone numbers into a consistent written form after the
/// NeMo pass has already digitized the spoken words. It runs on digitized text,
/// so its job is grouping and light cleanup — never digit recognition.
///
/// Reformatting is deliberately conservative: a run is only touched when a
/// phone cue word sits just before it, or when it already arrives in a phone
/// shape. Years, currency amounts, percentages and bare IDs are left alone.
enum PhoneNumberRecomposer {

    /// Grouping style for the national portion. The learned phone-style
    /// preference selects one of these per dictation.
    enum PhoneStyle {
        case hyphenated
        case parenthesized
        case dotted
        case spaced
        case plain
    }

    /// Maps a learned style name (FormatCorrectionClassifier's vocabulary) to a
    /// grouping style; unknown / absent names keep the hyphenated default.
    static func style(named name: String?) -> PhoneStyle {
        switch name {
        case "parenthesized": return .parenthesized
        case "dotted": return .dotted
        case "spaced": return .spaced
        case "plain": return .plain
        default: return .hyphenated
        }
    }

    static func recompose(_ text: String, style: PhoneStyle = .hyphenated) -> String {
        guard !text.isEmpty else { return text }

        var result = text
        let matches = candidatePattern
            .matches(in: result, range: NSRange(result.startIndex..., in: result))
            .reversed()

        for match in matches {
            guard let fullRange = Range(match.range, in: result) else { continue }
            let span = String(result[fullRange])

            guard let recomposed = recompose(
                span: span,
                precedingText: String(result[result.startIndex..<fullRange.lowerBound]),
                followingText: String(result[fullRange.upperBound...]),
                style: style
            ) else { continue }

            result.replaceSubrange(fullRange, with: recomposed)
        }

        return result
    }

    // MARK: - Per-candidate

    private static func recompose(
        span: String,
        precedingText: String,
        followingText: String,
        style: PhoneStyle
    ) -> String? {
        // Split the span into an optional country prefix and the digit body,
        // preserving whatever trailing extension the pattern absorbed.
        let hasPlus = span.contains("+")
            || span.range(of: #"^\s*plus\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        var body = span
        var extensionSuffix = ""

        if let extRange = body.range(
            of: #"\s*(?:ext\.?|extension|x)\s*(\d{1,6})\s*$"#,
            options: [.regularExpression, .caseInsensitive]
        ) {
            let extDigits = String(body[extRange]).filter(\.isNumber)
            extensionSuffix = " ext. \(extDigits)"
            body.removeSubrange(extRange)
        }

        let digits = body.filter(\.isNumber)
        let nationalDigits: String
        var countryPrefix = ""

        if hasPlus, digits.hasPrefix("1"), digits.count == 11 {
            countryPrefix = "+1 "
            nationalDigits = String(digits.dropFirst())
        } else if digits.count == 11, digits.hasPrefix("1") {
            countryPrefix = "1-"
            nationalDigits = String(digits.dropFirst())
        } else {
            nationalDigits = digits
        }

        guard nationalDigits.count == 10 || nationalDigits.count == 7 else {
            return nil
        }

        // Exclusions that must never be reformatted regardless of cue.
        if isYearLike(nationalDigits, hasCountry: !countryPrefix.isEmpty),
           extensionSuffix.isEmpty {
            return nil
        }
        if touchesCurrencyOrPercent(precedingText: precedingText, followingText: followingText) {
            return nil
        }

        let alreadyGrouped = isAlreadyPhoneGrouped(span)
        let hasCue = phoneCuePrecedes(precedingText)

        // A 7-digit run is ambiguous (dates, codes) — require an explicit cue.
        if nationalDigits.count == 7, !hasCue {
            return nil
        }
        guard hasCue || alreadyGrouped || !countryPrefix.isEmpty else {
            return nil
        }

        let grouped = group(nationalDigits: nationalDigits, style: style)
        return countryPrefix + grouped + extensionSuffix
    }

    // MARK: - Formatting

    private static func group(nationalDigits digits: String, style: PhoneStyle) -> String {
        let chars = Array(digits)
        if digits.count == 10 {
            let area = String(chars[0..<3])
            let prefix = String(chars[3..<6])
            let line = String(chars[6..<10])
            switch style {
            case .hyphenated:
                return "\(area)-\(prefix)-\(line)"
            case .parenthesized:
                return "(\(area)) \(prefix)-\(line)"
            case .dotted:
                return "\(area).\(prefix).\(line)"
            case .spaced:
                return "\(area) \(prefix) \(line)"
            case .plain:
                return "\(area)\(prefix)\(line)"
            }
        }
        // 7 digits.
        let prefix = String(chars[0..<3])
        let line = String(chars[3..<7])
        switch style {
        case .hyphenated, .parenthesized:
            return "\(prefix)-\(line)"
        case .dotted:
            return "\(prefix).\(line)"
        case .spaced:
            return "\(prefix) \(line)"
        case .plain:
            return "\(prefix)\(line)"
        }
    }

    // MARK: - Gating

    private static func phoneCuePrecedes(_ precedingText: String) -> Bool {
        let words = precedingText
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .suffix(6)
            .map { $0.lowercased() }
        // An ID/reference context ("invoice number", "order number") disqualifies
        // the run even when a generic cue like "number" is present.
        if words.contains(where: { Self.antiCues.contains($0) }) {
            return false
        }
        return words.contains { Self.phoneCues.contains($0) }
    }

    /// True when the raw span already carries phone-shaped grouping separators
    /// (3-3-4 or 3-4), which alone is enough to justify normalizing it.
    private static func isAlreadyPhoneGrouped(_ span: String) -> Bool {
        let trimmed = span.trimmingCharacters(in: .whitespaces)
        return groupedShapePattern.firstMatch(
            in: trimmed,
            range: NSRange(trimmed.startIndex..., in: trimmed)
        ) != nil
    }

    private static func isYearLike(_ digits: String, hasCountry: Bool) -> Bool {
        guard !hasCountry, digits.count == 4, let value = Int(digits) else { return false }
        return (1900...2099).contains(value)
    }

    private static func touchesCurrencyOrPercent(
        precedingText: String,
        followingText: String
    ) -> Bool {
        if let last = precedingText.last(where: { !$0.isWhitespace }),
           "$€£¥".contains(last) {
            return true
        }
        if let first = followingText.first(where: { !$0.isWhitespace }),
           "%".contains(first) {
            return true
        }
        return false
    }

    // MARK: - Patterns

    private static let phoneCues: Set<String> = [
        "call", "called", "phone", "number", "text", "reach", "dial",
        "cell", "mobile", "fax", "contact", "whatsapp", "line",
    ]

    /// ID/reference contexts that must never be treated as phone numbers, even
    /// when the generic "number" cue is nearby.
    private static let antiCues: Set<String> = [
        "invoice", "order", "account", "id", "confirmation", "reference",
        "ticket", "sku", "serial", "tracking", "case", "pin", "code",
    ]

    /// Candidate phone spans: an optional "+ 1"/"+1"/"plus 1" country prefix,
    /// then a run of digit groups joined by phone separators, plus any trailing
    /// spoken extension. Length gating happens after the digits are extracted.
    private static let candidatePattern = try! NSRegularExpression(
        pattern: #"(?<![\d.\w])(?:\+|plus\b)?\s?1?[\s\-.]?\(?\d{3,10}\)?(?:[\s\-.]\d{2,4}){0,3}(?:\s*(?:ext\.?|extension|x)\s*\d{1,6})?(?![\d])"#,
        options: [.caseInsensitive]
    )

    /// A separator-grouped phone shape (3-3-4 or 3-4), allowing an optional
    /// parenthesized area code and an optional leading country digit.
    private static let groupedShapePattern = try! NSRegularExpression(
        pattern: #"^(?:\+?\s?1[\s\-.])?\(?\d{3}\)?[\s\-.]\d{3}[\s\-.]\d{4}$|^\d{3}[\s\-.]\d{4}$"#,
        options: []
    )
}
