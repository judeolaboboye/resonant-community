import Foundation

/// Final money-styling pass. Earlier stages (NeMo, magnitude protection,
/// fragment repair) leave currency in mixed shapes — "5,000 dollars",
/// "$1000000", "€50 $0.20". This pass converges them on one house style:
/// symbol-prefixed, comma-grouped, cents merged into the decimal.
/// Casual forms without a digit ("a few dollars", "fifty bucks") stay prose.
enum CurrencyStyler {

    static func style(_ input: String) -> String {
        guard !input.isEmpty else { return input }

        var text = input
        text = attachingDollarSymbol(in: text)
        text = mergingTrailingCents(in: text)
        text = groupingSymbolAmounts(in: text)
        return text
    }

    // "5,000 dollars" → "$5,000". Adjacency required, so qualified currencies
    // ("50 Australian dollars") are left alone.
    private static let digitsDollarsPattern = try! NSRegularExpression(
        pattern: #"(?<![\w$€.])(\d[\d,]*(?:\.\d+)?)\s+dollars?\b"#,
        options: [.caseInsensitive]
    )

    private static func attachingDollarSymbol(in text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return digitsDollarsPattern.stringByReplacingMatches(
            in: text, range: range, withTemplate: "\\$$1"
        )
    }

    // "€50 $0.20" / "€50 and 20 cents" / "$5 and 50 cents" → cents merged
    // into a two-digit decimal on the leading amount.
    private static let nemoCentsPattern = try! NSRegularExpression(
        pattern: #"([$€]\d[\d,]*)\s+(?:and\s+)?\$0\.(\d{2})\b"#,
        options: [.caseInsensitive]
    )

    private static let wordCentsPattern = try! NSRegularExpression(
        pattern: #"([$€]\d[\d,]*)\s+and\s+(\d{1,2})\s+cents?\b"#,
        options: [.caseInsensitive]
    )

    private static func mergingTrailingCents(in text: String) -> String {
        var result = text
        var range = NSRange(result.startIndex..., in: result)
        result = nemoCentsPattern.stringByReplacingMatches(
            in: result, range: range, withTemplate: "$1.$2"
        )

        let matches = wordCentsPattern.matches(
            in: result, range: NSRange(result.startIndex..., in: result)
        ).reversed()
        for match in matches {
            guard let fullRange = Range(match.range, in: result),
                  let amountRange = Range(match.range(at: 1), in: result),
                  let centsRange = Range(match.range(at: 2), in: result),
                  let cents = Int(result[centsRange]) else { continue }
            let amount = String(result[amountRange])
            result.replaceSubrange(fullRange, with: amount + String(format: ".%02d", cents))
        }

        range = NSRange(result.startIndex..., in: result)
        return result
    }

    // "$1000000" → "$1,000,000", "$2500" → "$2,500". Only ungrouped integer
    // parts of 4+ digits; existing commas and compact forms ("$5k") untouched.
    private static let ungroupedAmountPattern = try! NSRegularExpression(
        pattern: #"([$€])(\d{4,})(?![\d,])"#
    )

    private static func groupingSymbolAmounts(in text: String) -> String {
        var result = text
        let matches = ungroupedAmountPattern.matches(
            in: result, range: NSRange(result.startIndex..., in: result)
        ).reversed()

        for match in matches {
            guard let digitsRange = Range(match.range(at: 2), in: result) else { continue }
            let digits = result[digitsRange]
            var grouped = ""
            for (offset, character) in digits.reversed().enumerated() {
                if offset > 0, offset % 3 == 0 {
                    grouped.append(",")
                }
                grouped.append(character)
            }
            result.replaceSubrange(digitsRange, with: String(grouped.reversed()))
        }

        return result
    }
}
