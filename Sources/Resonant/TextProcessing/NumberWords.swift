import Foundation

/// Single source of truth for spoken-number word lookups shared by the
/// ITN passes. Pattern helpers emit longest-first alternations so compound
/// words ("fourteen") win over their prefixes ("four") regardless of
/// dictionary ordering.
enum NumberWords {

    static let zero: [String: Int] = ["zero": 0, "oh": 0, "o": 0]

    static let ones: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9,
    ]

    static let teens: [String: Int] = [
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]

    static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    /// 0–9 including the spoken zero forms ("oh", "o").
    static let singleDigits: [String: Int] = zero.merging(ones) { current, _ in current }

    /// 1–90 word values for cardinal phrase parsing.
    static let cardinals: [String: Int] = ones
        .merging(teens) { current, _ in current }
        .merging(tens) { current, _ in current }

    /// Longest-first regex alternation over a table's keys.
    static func alternation(_ table: [String: Int]) -> String {
        table.keys.sorted { $0.count > $1.count }.joined(separator: "|")
    }

    static func alternation(_ tables: [String: Int]...) -> String {
        let keys = tables.flatMap(\.keys)
        return Set(keys).sorted { $0.count > $1.count }.joined(separator: "|")
    }
}

/// Shared context guards for disambiguating spoken numbers. Most ITN
/// misfires come from a rule ignoring the word on either side of a match;
/// rules should reach for these sets instead of growing private lists.
enum NumberContext {

    /// A number followed by one of these is an amount, never a time.
    /// "pounds" also covers weight — either sense reads "one fifty" as 150.
    static let currencyAnchors: Set<String> = [
        "dollar", "dollars", "buck", "bucks", "euro", "euros",
        "cent", "cents", "quid", "usd", "eur", "grand",
        "pound", "pounds", "yen", "pesos", "rupees",
    ]

    /// "two fifty each" / "three fifty apiece" are prices.
    static let rateAnchors: Set<String> = ["each", "apiece", "per"]

    /// "a month" / "a week" after a number marks a recurring price.
    static let ratePeriods: Set<String> = [
        "month", "week", "year", "day", "night", "hour", "person", "head", "unit",
    ]

    /// A payment verb before "two fifty" marks an amount, never a time.
    static let paymentVerbs: Set<String> = [
        "pay", "pays", "paid", "paying", "cost", "costs", "costing",
        "charge", "charges", "charged", "spend", "spends", "spent",
        "worth", "price", "priced", "owe", "owes", "owed", "quoted",
    ]

    /// True when the text after `index` reads as a currency or rate anchor:
    /// "dollars", "each", or "a month"-style periods.
    static func currencyOrRateFollows(_ index: String.Index, in text: String) -> Bool {
        let following = followingWords(after: index, in: text, count: 2)
        guard let first = following.first else { return false }
        if currencyAnchors.contains(first) || rateAnchors.contains(first) {
            return true
        }
        if first == "a" || first == "an" || first == "per",
           following.count > 1, ratePeriods.contains(following[1]) {
            return true
        }
        return false
    }

    static func paymentVerbPrecedes(_ index: String.Index, in text: String) -> Bool {
        guard let word = wordBefore(index, in: text) else { return false }
        return paymentVerbs.contains(word)
    }

    static func wordBefore(_ index: String.Index, in text: String) -> String? {
        let prefix = text[..<index]
        guard let last = prefix.split(whereSeparator: { !$0.isLetter }).last else { return nil }
        return String(last).lowercased()
    }

    private static func followingWords(
        after index: String.Index, in text: String, count: Int
    ) -> [String] {
        text[index...]
            .split(whereSeparator: { !$0.isLetter })
            .prefix(count)
            .map { String($0).lowercased() }
    }
}
