import Foundation

/// Spoken fraction, currency, and date-ordinal normalization.
/// Pre-NeMo passes work on word forms ("two thirds", "fifth of january");
/// post-NeMo passes work on the digit forms NeMo leaves behind ("5 grand").
extension ITNProcessor {

    // MARK: - Fractions (pre-NeMo)

    private static let fractionNumeratorValues = NumberWords.ones

    private static let fractionDenominatorValues: [String: Int] = [
        "third": 3, "thirds": 3,
        "quarter": 4, "quarters": 4,
        "fourth": 4, "fourths": 4,
        "fifth": 5, "fifths": 5,
        "sixth": 6, "sixths": 6,
        "seventh": 7, "sevenths": 7,
        "eighth": 8, "eighths": 8,
        "ninth": 9, "ninths": 9,
        "tenth": 10, "tenths": 10,
        // "half" only pairs with numerator one; "halves" stays prose.
        "half": 2,
    ]

    /// "the last three quarters" is a time span, not 3/4.
    private static let fractionBlockedPrecedingWords: Set<String> = [
        "last", "past", "next", "first", "final", "previous", "recent",
        "coming", "few", "several",
    ]

    private static let spokenFractionPattern: NSRegularExpression = {
        let numerators = fractionNumeratorValues.keys.joined(separator: "|")
        let denominators = fractionDenominatorValues.keys
            .sorted { $0.count > $1.count }
            .joined(separator: "|")
        return try! NSRegularExpression(
            pattern: "\\b(\(numerators)|[1-9])[\\s-]+(\(denominators))\\b",
            options: [.caseInsensitive]
        )
    }()

    /// "two thirds" → "2/3", "three quarters" → "3/4", "one half" → "1/2".
    /// Plurality must agree ("two third" stays prose), and time-span phrasing
    /// ("the last three quarters") is left alone.
    func normalizingSpokenFractions(in text: String) -> String {
        var result = text
        let nsText = text as NSString
        let matches = Self.spokenFractionPattern.matches(
            in: text, range: NSRange(location: 0, length: nsText.length)
        ).reversed()

        for match in matches {
            guard let fullRange = Range(match.range, in: result),
                  let numeratorRange = Range(match.range(at: 1), in: result),
                  let denominatorRange = Range(match.range(at: 2), in: result) else { continue }

            let numeratorText = String(result[numeratorRange]).lowercased()
            let denominatorText = String(result[denominatorRange]).lowercased()
            let numerator = Self.fractionNumeratorValues[numeratorText] ?? Int(numeratorText)
            guard let numerator,
                  let denominator = Self.fractionDenominatorValues[denominatorText] else { continue }

            let denominatorIsPlural = denominatorText.hasSuffix("s")
            if numerator == 1, denominatorIsPlural { continue }
            if numerator > 1, !denominatorIsPlural { continue }
            if denominatorText == "half", numerator != 1 { continue }
            // Nobody dictates the unreduced fraction 2/4 — "two quarters" is
            // coins or fiscal quarters, so it stays prose.
            if denominator == 4, numerator == 2 { continue }

            if let preceding = Self.wordPreceding(match.range.location, in: nsText),
               Self.fractionBlockedPrecedingWords.contains(preceding) {
                continue
            }

            result.replaceSubrange(fullRange, with: "\(numerator)/\(denominator)")
        }

        return result
    }

    private static let andAHalfPattern: NSRegularExpression = {
        let numbers = (fractionNumeratorValues.keys + ["ten", "eleven", "twelve"])
            .joined(separator: "|")
        return try! NSRegularExpression(
            pattern: "\\b(\(numbers)|\\d+)\\s+and\\s+a\\s+half\\b",
            options: [.caseInsensitive]
        )
    }()

    private static let andAHalfWordValues: [String: Int] = fractionNumeratorValues
        .merging(["ten": 10, "eleven": 11, "twelve": 12]) { current, _ in current }

    /// "two and a half hours" → "2.5 hours". A bare "an hour and a half"
    /// has no leading number and stays prose.
    func normalizingAndAHalf(in text: String) -> String {
        var result = text
        let nsText = text as NSString
        let matches = Self.andAHalfPattern.matches(
            in: text, range: NSRange(location: 0, length: nsText.length)
        ).reversed()

        for match in matches {
            guard let fullRange = Range(match.range, in: result),
                  let numberRange = Range(match.range(at: 1), in: result) else { continue }
            let numberText = String(result[numberRange]).lowercased()
            guard let number = Self.andAHalfWordValues[numberText] ?? Int(numberText) else { continue }
            result.replaceSubrange(fullRange, with: "\(number).5")
        }

        return result
    }

    private static let halfAPercentPattern = try! NSRegularExpression(
        pattern: #"\bhalf\s+a\s+percent\b(?!age)"#,
        options: [.caseInsensitive]
    )

    /// "half a percent" → "0.5 percent" before NeMo converts the unit,
    /// so the output reads "0.5%" instead of "half a %".
    func normalizingHalfAPercent(in text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return Self.halfAPercentPattern.stringByReplacingMatches(
            in: text, range: range, withTemplate: "0.5 percent"
        )
    }

    // MARK: - Date ordinals (pre-NeMo, before ordinal protection)

    private static let dateOrdinalValues: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5,
        "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10,
        "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14,
        "fifteenth": 15, "sixteenth": 16, "seventeenth": 17, "eighteenth": 18,
        "nineteenth": 19, "twentieth": 20, "thirtieth": 30,
    ]

    private static let dateOrdinalOnesValues: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5,
        "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9,
    ]

    private static let monthNames = [
        "january", "february", "march", "april", "may", "june", "july",
        "august", "september", "october", "november", "december",
    ]

    private static let dateOrdinalOfMonthPattern: NSRegularExpression = {
        let simple = dateOrdinalValues.keys.sorted { $0.count > $1.count }.joined(separator: "|")
        let ones = dateOrdinalOnesValues.keys.joined(separator: "|")
        let compound = "(?:twenty|thirty)[\\s-](?:\(ones))"
        let months = monthNames.joined(separator: "|")
        return try! NSRegularExpression(
            pattern: "\\b(\(compound)|\(simple))\\s+of\\s+(\(months))\\b",
            options: [.caseInsensitive]
        )
    }()

    /// "the fifth of january" → "the 5th of january",
    /// "twenty third of march" → "23rd of march".
    /// Complements the existing month-then-ordinal handling ("january fifth").
    func normalizingDateOrdinals(in text: String) -> String {
        var result = text
        let nsText = text as NSString
        let matches = Self.dateOrdinalOfMonthPattern.matches(
            in: text, range: NSRange(location: 0, length: nsText.length)
        ).reversed()

        for match in matches {
            guard let ordinalRange = Range(match.range(at: 1), in: result) else { continue }
            let ordinalText = String(result[ordinalRange]).lowercased()
            guard let day = Self.dateOrdinalDay(from: ordinalText) else { continue }
            result.replaceSubrange(ordinalRange, with: Self.ordinalNumeral(day))
        }

        return result
    }

    private static func dateOrdinalDay(from text: String) -> Int? {
        if let simple = dateOrdinalValues[text] { return simple }
        let parts = text.split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)
        guard parts.count == 2,
              let ones = dateOrdinalOnesValues[parts[1]] else { return nil }
        switch parts[0] {
        case "twenty": return 20 + ones
        case "thirty": return 30 + ones
        default: return nil
        }
    }

    private static func ordinalNumeral(_ value: Int) -> String {
        let suffix: String
        switch value % 100 {
        case 11, 12, 13: suffix = "th"
        default:
            switch value % 10 {
            case 1: suffix = "st"
            case 2: suffix = "nd"
            case 3: suffix = "rd"
            default: suffix = "th"
            }
        }
        return "\(value)\(suffix)"
    }

    // MARK: - Currency phrases (post-NeMo)

    private static let grandAmountPattern = try! NSRegularExpression(
        pattern: #"\b(\d[\d,]*(?:\.\d+)?)\s+grand\b(?!\s+(?:total|piano|pianos|prix|canyon|slam|jury|jeté|opening|finale|theft|scheme|tour))"#,
        options: [.caseInsensitive]
    )

    /// "5 grand" → "$5k" (NeMo has already digitized the cardinal).
    func normalizingGrandAmounts(in text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return Self.grandAmountPattern.stringByReplacingMatches(
            in: text, range: range, withTemplate: "\\$$1k"
        )
    }

    private static let euroAmountPattern = try! NSRegularExpression(
        pattern: #"\b(\d[\d,]*(?:\.\d+)?)\s+euros?\b"#,
        options: [.caseInsensitive]
    )

    /// "50 euros" → "€50".
    func normalizingEuroAmounts(in text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return Self.euroAmountPattern.stringByReplacingMatches(
            in: text, range: range, withTemplate: "€$1"
        )
    }

    // MARK: - Helpers

    private static func wordPreceding(_ location: Int, in text: NSString) -> String? {
        var end = location
        while end > 0, text.character(at: end - 1) == 0x20 { end -= 1 }
        var start = end
        while start > 0 {
            guard let scalar = Unicode.Scalar(text.character(at: start - 1)),
                  CharacterSet.letters.contains(scalar) else { break }
            start -= 1
        }
        guard start < end else { return nil }
        return text.substring(with: NSRange(location: start, length: end - start)).lowercased()
    }
}
