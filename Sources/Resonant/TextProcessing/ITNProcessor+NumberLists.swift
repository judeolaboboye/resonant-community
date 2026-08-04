import Foundation

/// Dictated number lists. "some pages like number seven eleven seventeen
/// nineteen twenty three" is textually identical to the times and years the
/// protection passes hunt for, and NeMo fuses whatever they leave behind —
/// so the list used to come out "7:11 1719 23". Two passes keep lists lists:
/// pre-NeMo, an enumeration cue ("number", "pages", "items") marks the
/// following run as labels or list items; post-NeMo, a comma-separated list
/// that arrived half words and half digits is digitized uniformly.
extension ITNProcessor {

    // MARK: - Enumerated number lists (pre-NeMo)

    /// Label nouns whose following numbers are labels or list items, never
    /// times or years. Plural forms read as enumerations outright.
    private static let enumerationCues: Set<String> = [
        "number", "numbers", "page", "pages", "item", "items",
        "chapter", "chapters", "question", "questions", "line", "lines",
        "figure", "figures", "section", "sections", "row", "rows",
        "verse", "verses", "episode", "episodes", "problem", "problems",
        "exercise", "exercises", "track", "tracks", "seat", "seats",
        "room", "rooms", "gate", "gates", "level", "levels",
        "unit", "units", "size", "sizes", "channel", "channels",
    ]

    private static let enumeratedNumberRunPattern: NSRegularExpression = {
        let cues = enumerationCues.sorted { $0.count > $1.count }.joined(separator: "|")
        let word = NumberWords.alternation(NumberWords.ones, NumberWords.teens, NumberWords.tens)
        let token = "(?:\\d{1,4}|\(word)|zero)"
        return try! NSRegularExpression(
            pattern: "\\b(\(cues))\\s+(\(token)(?:,?\\s+\(token))*)\\b",
            options: [.caseInsensitive]
        )
    }()

    private struct EnumeratedToken {
        let value: Int
        let isOnesWord: Bool
        let isTensBase: Bool
        let commaFollows: Bool
    }

    private static func enumeratedTokens(
        from run: String
    ) -> (tokens: [EnumeratedToken], hadCommas: Bool)? {
        var tokens: [EnumeratedToken] = []
        var hadCommas = false

        for raw in run.split(whereSeparator: \.isWhitespace) {
            var body = String(raw)
            var commaFollows = false
            if body.hasSuffix(",") {
                body = String(body.dropLast())
                commaFollows = true
                hadCommas = true
            }
            let lowered = body.lowercased()
            if !body.isEmpty, body.allSatisfy(\.isNumber), let value = Int(body) {
                tokens.append(EnumeratedToken(
                    value: value, isOnesWord: false,
                    isTensBase: value % 10 == 0 && (20...90).contains(value),
                    commaFollows: commaFollows
                ))
            } else if let value = NumberWords.ones[lowered] {
                tokens.append(EnumeratedToken(
                    value: value, isOnesWord: true, isTensBase: false, commaFollows: commaFollows
                ))
            } else if let value = NumberWords.teens[lowered] {
                tokens.append(EnumeratedToken(
                    value: value, isOnesWord: false, isTensBase: false, commaFollows: commaFollows
                ))
            } else if let value = NumberWords.tens[lowered] {
                tokens.append(EnumeratedToken(
                    value: value, isOnesWord: false, isTensBase: true, commaFollows: commaFollows
                ))
            } else if lowered == "zero" {
                tokens.append(EnumeratedToken(
                    value: 0, isOnesWord: false, isTensBase: false, commaFollows: commaFollows
                ))
            } else {
                return nil
            }
        }

        return (tokens, hadCommas)
    }

    /// Maximal-munch grouping: a tens value (word or digit) absorbs a
    /// following ones word when no comma separates them — "twenty three" and
    /// the hybrid per-chunk emission "20 three" are both one number, 23.
    private static func enumeratedGroups(_ tokens: [EnumeratedToken]) -> [Int] {
        var groups: [Int] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token.isTensBase, !token.commaFollows,
               index + 1 < tokens.count, tokens[index + 1].isOnesWord {
                groups.append(token.value + tokens[index + 1].value)
                index += 2
            } else {
                groups.append(token.value)
                index += 1
            }
        }
        return groups
    }

    /// Rewrites a cue-led number run as digits before the time/year
    /// protections can pair adjacent items: "number seven eleven seventeen
    /// nineteen twenty three" → "number 7, 11, 17, 19, 23". A singular cue
    /// with exactly two paired numbers is a composite label the way pages and
    /// rooms are read aloud ("page seven eleven" → "page 711"); an
    /// all-single-digit run after a singular cue stays untouched for the
    /// digit-sequence and phone passes ("number one two three" → 123).
    func normalizingEnumeratedNumberLists(in text: String) -> String {
        var result = text
        let matches = Self.enumeratedNumberRunPattern.matches(
            in: result, range: NSRange(result.startIndex..., in: result)
        ).reversed()

        for match in matches {
            guard let cueRange = Range(match.range(at: 1), in: result),
                  let runRange = Range(match.range(at: 2), in: result),
                  let parsed = Self.enumeratedTokens(from: String(result[runRange]))
            else { continue }

            let groups = Self.enumeratedGroups(parsed.tokens)
            guard groups.count >= 2 else { continue }

            let pluralCue = String(result[cueRange]).lowercased().hasSuffix("s")
            let list = groups.map(String.init).joined(separator: ", ")
            let replacement: String

            if pluralCue || parsed.hadCommas {
                replacement = list
            } else if groups.count == 2,
                      (1...99).contains(groups[0]), (10...99).contains(groups[1]) {
                replacement = "\(groups[0])\(groups[1])"
            } else if groups.count >= 3, groups.contains(where: { $0 >= 10 }) {
                replacement = list
            } else {
                continue
            }

            result.replaceSubrange(runRange, with: replacement)
        }

        return result
    }

    // MARK: - Mixed word/digit list uniformity (post-NeMo)

    private static let mixedNumberListPattern: NSRegularExpression = {
        let tens = NumberWords.alternation(NumberWords.tens)
        let ones = NumberWords.alternation(NumberWords.ones)
        let word = NumberWords.alternation(NumberWords.ones, NumberWords.teens, NumberWords.tens)
        let item = "(?:\\d{1,4}|(?:\(tens))[\\s-](?:\(ones))|\(word)|zero)"
        return try! NSRegularExpression(
            pattern: "\\b\(item)(?:,\\s*(?:and\\s+)?\(item)){2,}\\b",
            options: [.caseInsensitive]
        )
    }()

    /// NeMo digitizes compound number words but leaves single ones as words,
    /// so a pause-delimited list arrives mixed: "seven, eleven, 23". Once a
    /// comma-separated run of three or more bare numbers contains at least one
    /// digit item, digitize the word items to match. All-word lists stay prose.
    func normalizingNumericListUniformity(in text: String) -> String {
        var result = text
        let matches = Self.mixedNumberListPattern.matches(
            in: result, range: NSRange(result.startIndex..., in: result)
        ).reversed()

        for match in matches {
            guard let range = Range(match.range, in: result) else { continue }
            let items = String(result[range])
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }

            var hasDigits = false
            var hasWords = false
            var rebuilt: [String] = []
            var convertible = true

            for item in items {
                var body = item
                var prefix = ""
                if let andRange = body.range(
                    of: #"^and\s+"#, options: [.regularExpression, .caseInsensitive]
                ) {
                    prefix = String(body[andRange])
                    body.removeSubrange(andRange)
                }
                if !body.isEmpty, body.allSatisfy(\.isNumber) {
                    hasDigits = true
                    rebuilt.append(prefix + body)
                } else if let value = Self.listWordValue(body) {
                    hasWords = true
                    rebuilt.append(prefix + String(value))
                } else {
                    convertible = false
                    break
                }
            }

            guard convertible, hasDigits, hasWords else { continue }
            result.replaceSubrange(range, with: rebuilt.joined(separator: ", "))
        }

        return result
    }

    private static func listWordValue(_ item: String) -> Int? {
        let parts = item.lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "-" })
            .map(String.init)
        if parts.count == 1 {
            if parts[0] == "zero" { return 0 }
            return NumberWords.cardinals[parts[0]]
        }
        if parts.count == 2,
           let tens = NumberWords.tens[parts[0]],
           let ones = NumberWords.ones[parts[1]] {
            return tens + ones
        }
        return nil
    }
}
