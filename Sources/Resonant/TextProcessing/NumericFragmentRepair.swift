import Foundation

/// Repairs high-confidence numeric fragments emitted by ASR before NeMo sees
/// them. Rules must be anchored by a semantic unit so ordinary digit runs,
/// times, IDs, product names, and addresses remain untouched.
enum NumericFragmentRepair {

    static func repair(_ input: String) -> String {
        guard !input.isEmpty else {
            return input
        }

        var text = input
        text = repairingUnitAnchoredFragments(in: text)
        return text
    }

    private static func repairingUnitAnchoredFragments(in text: String) -> String {
        var result = text
        let matches = Self.unitAnchoredFragmentPattern.matches(
            in: result,
            range: NSRange(result.startIndex..., in: result)
        ).reversed()

        for match in matches {
            guard let fullRange = Range(match.range, in: result),
                  let leadingRange = Range(match.range(at: 1), in: result),
                  let trailingRange = Range(match.range(at: 2), in: result),
                  let unitRange = Range(match.range(at: 3), in: result),
                  let amount = mergedAmount(
                    leading: String(result[leadingRange]),
                    trailing: String(result[trailingRange])
                  )
            else {
                continue
            }

            // Dollars go straight to house style; other units keep their word
            // so the downstream currency/percent passes apply their own style.
            let unit = String(result[unitRange])
            let replacement = unit.lowercased().hasPrefix("dollar")
                ? "$\(amount)"
                : "\(amount) \(unit)"
            result.replaceSubrange(fullRange, with: replacement)
        }

        return result
    }

    private static func mergedAmount(leading rawLeading: String, trailing: String) -> String? {
        let leading = rawLeading.replacingOccurrences(of: ",", with: "")
        guard !leading.isEmpty,
              !trailing.isEmpty,
              leading.allSatisfy(\.isNumber),
              trailing.allSatisfy(\.isNumber)
        else {
            return nil
        }

        // A year-shaped head is prose, not a fragment: "In 2020 5 percent of
        // users churned" must not merge into 2025.
        if let leadingValue = Int(leading), (1900...2099).contains(leadingValue) {
            return nil
        }

        let zeroSuffixCount = leading.reversed().prefix(while: { $0 == "0" }).count
        if zeroSuffixCount >= trailing.count {
            return String(leading.dropLast(trailing.count)) + trailing
        }

        if leading.count == 2, trailing.count == 1 {
            return leading + trailing
        }

        return nil
    }

    private static let unitAnchoredFragmentPattern = try! NSRegularExpression(
        pattern: #"\b(\d{2,}|\d{1,3}(?:,\d{3})+)\s+(\d{1,2})\s+(dollars?|euros?|cents?|bucks?|pounds?|quid|percent)\b"#,
        options: [.caseInsensitive]
    )
}
