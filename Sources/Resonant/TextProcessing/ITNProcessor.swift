import Foundation

/// Inverse Text Normalization backed by the vendored Rust text formatter.
struct ITNProcessor {

    func process(
        _ input: String,
        autoPunctuationEnabled: Bool = true,
        phoneStyle: PhoneNumberRecomposer.PhoneStyle = .hyphenated
    ) -> String {
        guard !input.isEmpty else {
            return input
        }

        var text = input
        var allReplacements: [String: String] = [:]

        // 0. Assemble + protect spoken email addresses ("alex at example
        //    dot com" -> "alex@example.com") before anything else touches the
        //    "at"/"dot" tokens. NeMo's electronic grammar otherwise classifies
        //    the whole surrounding clause as one email token and strips every
        //    interior space, fusing "...welcome email to asa at growthfarm dot
        //    com" into "...welcomeemailtoalex@example.com". Running first —
        //    before spoken-punctuation protection (which would hide a standalone
        //    "dot") and before NeMo — keeps the local part bounded to the spoken
        //    handle and preserves the spacing of the surrounding prose.
        let emailProtection = protectingSpokenEmailAddresses(in: text)
        text = emailProtection.text
        allReplacements.merge(emailProtection.replacements) { _, new in new }

        // 0.25. Shield any remaining bare "at" from NeMo. Real emails were just
        //       extracted above, so every surviving "at" is prose — yet NeMo's
        //       electronic grammar still converts it to "@" and fuses the
        //       neighbours ("look at this" -> "look@this"). "at sign" is left
        //       alone so it can still become "@".
        let atProtection = protectingPrepositionalAt(in: text)
        text = atProtection.text
        allReplacements.merge(atProtection.replacements) { _, new in new }

        // 0.5. Protect spoken punctuation (when auto-punctuation is disabled)
        if !autoPunctuationEnabled {
            let pp = protectingSpokenPunctuation(in: text)
            text = pp.text
            allReplacements.merge(pp.replacements) { _, new in new }
        }

        // 0.75. Rewrite enumerated number lists ("pages like number seven
        //       eleven seventeen nineteen twenty three") as comma-separated
        //       digits before the time/year protections below can pair
        //       adjacent items into "7:11" or "1719".
        text = normalizingEnumeratedNumberLists(in: text)

        // 1. Protect time patterns from NeMo incorrectly adding adjacent numbers
        //    e.g. "ten fifteen" would become 25 (10+15) without this
        let tp = protectingTimePatterns(in: text)
        text = tp.text
        allReplacements.merge(tp.replacements) { _, new in new }

        // 2. Protect spoken year patterns from NeMo combining components
        //    e.g. "twenty twenty six" would become "40 six" (20+20, 6) without this
        let yp = protectingYearPatterns(in: text)
        text = yp.text
        allReplacements.merge(yp.replacements) { _, new in new }

        // 3. Protect "X and/to Y" number connectors from being combined
        //    e.g. "ten and fifteen" would become 25, "ten to fifteen" → "14:50"
        let nc = protectingNumberConnectors(in: text)
        text = nc.text
        allReplacements.merge(nc.replacements) { _, new in new }

        // 4. Protect spoken "twenty four seven" from NeMo turning it into "20 47"
        let tf = protectingTwentyFourSeven(in: text)
        text = tf.text
        allReplacements.merge(tf.replacements) { _, new in new }

        // 4.5. Protect vague quantities ("a couple hundred people") so NeMo
        //      doesn't digitize the magnitude word ("a couple 100 people").
        let vq = protectingVagueQuantities(in: text)
        text = vq.text
        allReplacements.merge(vq.replacements) { _, new in new }

        // 5. Normalize colloquial hundreds before NeMo can add the parts
        //    e.g. "three sixty five" would become 68 (3+60+5) without this
        text = normalizingColloquialHundreds(in: text)

        // 6. Normalize compact spoken hundreds after upstream STT has already
        //    digitized part of the phrase (e.g. "25 hundred" -> "2500").
        text = normalizingDigitHundreds(in: text)

        // 6.5. Recombine a digit-form hundred with a word-form remainder that
        //      upstream STT left behind (e.g. "100 forty" -> "140",
        //      "200 fifty five" -> "255"). Runs before NeMo so the rejoined
        //      cardinal is treated as a single number.
        text = normalizingDigitHundredsPlusWordNumber(in: text)

        // 7. Repair unit-anchored numeric fragments from upstream STT chunks
        //    (e.g. "120 5 dollars" -> "$125").
        text = NumericFragmentRepair.repair(text)

        // 7.3. Convert spoken date ordinals before ordinal protection hides
        //      them (e.g. "fifth of january" → "5th of january").
        text = normalizingDateOrdinals(in: text)

        // 7.5. Convert spoken fractions and "N and a half" before NeMo can
        //      mangle the word forms (e.g. "two thirds" → "2/3",
        //      "two and a half hours" → "2.5 hours").
        text = normalizingSpokenFractions(in: text)
        text = normalizingAndAHalf(in: text)
        text = normalizingHalfAPercent(in: text)

        // 8. Protect spoken/digit magnitude phrases before NeMo splits them
        //    (e.g. "75 thousand people" → "75,000 people").
        let mp = protectingMagnitudePhrases(in: text)
        text = mp.text
        allReplacements.merge(mp.replacements) { _, new in new }

        // 9. Protect ordinal adjectives from NeMo converting "first" → "1st"
        let op = protectingOrdinalWords(in: text)
        text = op.text
        allReplacements.merge(op.replacements) { _, new in new }

        // 10. Handle spoken digit sequences ("one two three" → "123")
        text = preservingSpokenDigitSequences(in: text)

        // 11. NeMo normalization
        text = NemoTextProcessing.normalizeSentence(text)

        // 12. Restore all protected text
        text = restoringProtectedPunctuation(in: text, replacements: allReplacements)

        // 12.5. Recompose dictated phone numbers on the now-digitized text
        //       (cue-gated grouping, country codes, extensions).
        text = PhoneNumberRecomposer.recompose(text, style: phoneStyle)

        // 12.7. Digitize mixed word/digit lists NeMo half-converted
        //       ("seven, eleven, 23" → "7, 11, 23").
        text = normalizingNumericListUniformity(in: text)

        // 13. Normalize spoken area units after NeMo has produced numeric forms
        text = normalizingAreaMeasurements(in: text)

        // 14. Normalize dimension "by" to × symbol (e.g. "4 m by 2 m" → "4 m × 2 m")
        text = normalizingDimensionBy(in: text)

        // 15. Normalize hybrid STT output like "ninety-nine %" before spacing cleanup.
        text = normalizingSpokenPercentSymbols(in: text)

        // 16. Collapse space between digits and % (NeMo emits "99 %" but "99%" is standard)
        text = collapsingPercentSpacing(in: text)

        // 17. Collapse spoken decimals → "N.M" (e.g. "2 point 5" → "2.5", "3 .6" → "3.6")
        text = collapsingDecimalPoint(in: text)

        // 18. Collapse "X N.M" → "XN.M" for version-style letter-digit (e.g. "K 2.5" → "K2.5")
        text = collapsingVersionSpacing(in: text)

        // 19. Normalize compact suffix spacing NeMo can leave behind
        //     (e.g. "75 k" → "75k").
        text = normalizingDigitMagnitudes(in: text)

        // 20. Currency phrases over NeMo's digit output
        //     ("5 grand" → "$5k", "50 euros" → "€50").
        text = normalizingGrandAmounts(in: text)
        text = normalizingEuroAmounts(in: text)

        // 21. Converge all currency on one house style: "$N", comma-grouped,
        //     cents merged ("5,000 dollars" → "$5,000", "€50 $0.20" → "€50.20").
        text = CurrencyStyler.style(text)

        return text
    }

    // MARK: - Time pattern protection

    /// Detects spoken time patterns like "ten fifteen" or "eleven forty five"
    /// and converts them to "10:15", "11:45" before NeMo can incorrectly add them.
    private func protectingTimePatterns(in text: String) -> ProtectedPunctuation {
        var result = text
        var replacements: [String: String] = [:]
        let matches = Self.timePattern.matches(
            in: text, range: NSRange(text.startIndex..., in: text)
        ).reversed()

        for (index, match) in matches.enumerated() {
            guard let fullRange = Range(match.range, in: result),
                  let hourRange = Range(match.range(at: 1), in: result),
                  let minuteRange = Range(match.range(at: 2), in: result) else { continue }

            let hasExplicitAmPm = match.numberOfRanges > 3 && match.range(at: 3).location != NSNotFound
            if !hasExplicitAmPm,
               let previousWord = word(before: fullRange.lowerBound, in: result),
               Self.rangeConnectorWords.contains(previousWord) {
                continue
            }

            let hourWord = String(result[hourRange]).lowercased()
            let minuteWords = String(result[minuteRange]).lowercased()

            guard let hour = Self.hourWordValues[hourWord],
                  let minute = spokenMinuteValue(minuteWords) else { continue }

            // "two fifty dollars" / "paid two fifty" / "three fifty a month"
            // are amounts, not times. With a single-digit hour the colloquial
            // hundreds reading is safe ("two fifty" → 250); ten–twelve stay
            // ambiguous ("ten fifty" could be $10.50), so they pass through
            // for NeMo to handle as plain cardinals.
            if !hasExplicitAmPm,
               NumberContext.currencyOrRateFollows(fullRange.upperBound, in: result)
                || NumberContext.paymentVerbPrecedes(fullRange.lowerBound, in: result) {
                if hour <= 9 {
                    result.replaceSubrange(fullRange, with: "\(hour * 100 + minute)")
                }
                continue
            }

            var timeStr = "\(hour):\(String(format: "%02d", minute))"

            if hasExplicitAmPm,
               let ampmRange = Range(match.range(at: 3), in: result) {
                let raw = String(result[ampmRange])
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()
                if raw.hasPrefix("a") {
                    timeStr += " a.m."
                } else if raw.hasPrefix("p") {
                    timeStr += " p.m."
                }
            }

            let placeholder = "__resonanttime\(index)__"
            replacements[placeholder] = timeStr
            result.replaceSubrange(fullRange, with: placeholder)
        }

        return ProtectedPunctuation(text: result, replacements: replacements)
    }

    private func spokenMinuteValue(_ words: String) -> Int? {
        let parts = words.split(whereSeparator: \.isWhitespace).map { String($0).lowercased() }

        if parts.count == 1 {
            return Self.minuteWordValues[parts[0]]
        }

        if parts.count == 2 {
            if parts[0] == "oh" {
                return Self.onesWordValues[parts[1]]
            }
            if let tens = Self.tensWordValues[parts[0]],
               let ones = Self.onesWordValues[parts[1]] {
                return tens + ones
            }
        }

        return nil
    }

    // MARK: - Year pattern protection

    /// Detects spoken year patterns like "twenty twenty six" or "nineteen ninety
    /// nine" and pairwise four-digit numbers like "twenty six seventy seven",
    /// converting them to "2026", "1999", "2677" before NeMo can add the parts.
    private func protectingYearPatterns(in text: String) -> ProtectedPunctuation {
        var result = text
        var replacements: [String: String] = [:]
        let matches = Self.yearPattern.matches(
            in: text, range: NSRange(text.startIndex..., in: text)
        ).reversed()

        for (index, match) in matches.enumerated() {
            guard let fullRange = Range(match.range, in: result),
                  let centuryRange = Range(match.range(at: 1), in: result),
                  let yearPartRange = Range(match.range(at: 2), in: result) else { continue }

            let centuryWord = String(result[centuryRange]).lowercased()
            let yearPartWords = String(result[yearPartRange]).lowercased()

            guard let century = spokenCenturyValue(centuryWord),
                  let yearPart = spokenYearPartValue(yearPartWords) else { continue }

            // The classic centuries ("nineteen ninety nine", "twenty fifteen")
            // convert unconditionally. The wider pairwise forms ("twenty six
            // seventy seven" → 2677, "seventeen seventy six" → 1776) yield to
            // amount context so "paid seventeen seventy" stays money-shaped.
            if Self.centuryWordValues[centuryWord] == nil,
               NumberContext.currencyOrRateFollows(fullRange.upperBound, in: result)
                || NumberContext.paymentVerbPrecedes(fullRange.lowerBound, in: result) {
                continue
            }

            let year = century * 100 + yearPart
            let placeholder = "__resonantyear\(index)__"
            replacements[placeholder] = "\(year)"
            result.replaceSubrange(fullRange, with: placeholder)
        }

        return ProtectedPunctuation(text: result, replacements: replacements)
    }

    /// Century value for the year/pairwise pattern: the classic words
    /// ("nineteen", "twenty"), any teen ("seventeen seventy six" → 17), or a
    /// compound tens-ones pair ("twenty six seventy seven" → 26).
    private func spokenCenturyValue(_ words: String) -> Int? {
        if let value = Self.centuryWordValues[words] { return value }

        let parts = words
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" })
            .map { String($0).lowercased() }

        if parts.count == 1 {
            return Self.yearTeenValues[parts[0]]
        }

        if parts.count == 2,
           let tens = Self.yearTensValues[parts[0]],
           let ones = Self.onesWordValues[parts[1]] {
            return tens + ones
        }

        return nil
    }

    private func spokenYearPartValue(_ words: String) -> Int? {
        let parts = words
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" })
            .map { String($0).lowercased() }

        if parts.count == 1 {
            if let value = Self.yearTeenValues[parts[0]] { return value }
            if let value = Self.yearTensValues[parts[0]] { return value }
            return nil
        }

        if parts.count == 2 {
            if parts[0] == "oh" {
                return Self.onesWordValues[parts[1]]
            }
            if let tens = Self.yearTensValues[parts[0]],
               let ones = Self.onesWordValues[parts[1]] {
                return tens + ones
            }
        }

        return nil
    }

    // MARK: - Number connector protection

    /// Detects "X and Y" or "X to Y" where both are number words and converts
    /// each number individually, preventing NeMo from adding them together.
    private func protectingNumberConnectors(in text: String) -> ProtectedPunctuation {
        var result = text
        var replacements: [String: String] = [:]
        let matches = Self.numberConnectorPattern.matches(
            in: result, range: NSRange(result.startIndex..., in: result)
        ).reversed()

        for (index, match) in matches.enumerated() {
            guard let fullRange = Range(match.range, in: result),
                  let firstRange = Range(match.range(at: 1), in: result),
                  let connRange = Range(match.range(at: 2), in: result),
                  let secondRange = Range(match.range(at: 3), in: result) else { continue }

            // Skip if preceded by "hundred" or "thousand" (valid cardinal connector)
            let before = result[result.startIndex..<fullRange.lowerBound]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            if before.hasSuffix("hundred") || before.hasSuffix("thousand") {
                continue
            }

            let firstWord = String(result[firstRange])
            let connector = String(result[connRange])
            let secondWord = String(result[secondRange])
            let firstIsDigits = Self.digitOnlyPattern.firstMatch(
                in: firstWord,
                range: NSRange(firstWord.startIndex..., in: firstWord)
            ) != nil
            let secondIsDigits = Self.digitOnlyPattern.firstMatch(
                in: secondWord,
                range: NSRange(secondWord.startIndex..., in: secondWord)
            ) != nil

            if firstIsDigits != secondIsDigits {
                continue
            }

            let firstDigit = normalizedConnectorNumber(firstWord)
            let secondDigit = normalizedConnectorNumber(secondWord)

            let replacement = "\(firstDigit) \(connector) \(secondDigit)"
            let placeholder = "__resonantconn\(index)__"
            replacements[placeholder] = replacement
            result.replaceSubrange(fullRange, with: placeholder)
        }

        return ProtectedPunctuation(text: result, replacements: replacements)
    }

    private func normalizedConnectorNumber(_ phrase: String) -> String {
        if let value = colloquialHundredValue(from: phrase) {
            return "\(value)"
        }

        return NemoTextProcessing.normalizeSentence(phrase)
            .trimmingCharacters(in: .whitespaces)
    }

    private func colloquialHundredValue(from phrase: String) -> Int? {
        let tokens = phrase
            .lowercased()
            .split { $0.isWhitespace || $0 == "-" }
            .map(String.init)

        guard (2...3).contains(tokens.count),
              let hundreds = Self.onesWordValues[tokens[0]],
              let tens = Self.tensWordValues[tokens[1]]
        else {
            return nil
        }

        let ones: Int
        if tokens.count == 3 {
            guard let value = Self.onesWordValues[tokens[2]] else { return nil }
            ones = value
        } else {
            ones = 0
        }

        return hundreds * 100 + tens + ones
    }

    /// Preserves the idiomatic availability phrase "twenty four seven"
    /// as "24/7" instead of letting NeMo split it into "20 47".
    private func protectingTwentyFourSeven(in text: String) -> ProtectedPunctuation {
        var result = text
        var replacements: [String: String] = [:]
        let matches = Self.twentyFourSevenPattern.matches(
            in: result, range: NSRange(result.startIndex..., in: result)
        ).reversed()

        for (index, match) in matches.enumerated() {
            guard let range = Range(match.range, in: result) else { continue }
            let placeholder = "__resonant247\(index)__"
            replacements[placeholder] = "24/7"
            result.replaceSubrange(range, with: placeholder)
        }

        return ProtectedPunctuation(text: result, replacements: replacements)
    }

    // MARK: - Vague quantity protection

    /// "a couple hundred", "a few thousand" are prose quantities; NeMo would
    /// digitize the magnitude word in place ("a couple 100 people").
    private func protectingVagueQuantities(in text: String) -> ProtectedPunctuation {
        var result = text
        var replacements: [String: String] = [:]
        let matches = Self.vagueQuantityPattern.matches(
            in: result, range: NSRange(result.startIndex..., in: result)
        ).reversed()

        for (index, match) in matches.enumerated() {
            guard let range = Range(match.range, in: result) else { continue }
            let placeholder = "__resonantvague\(index)__"
            replacements[placeholder] = String(result[range])
            result.replaceSubrange(range, with: placeholder)
        }

        return ProtectedPunctuation(text: result, replacements: replacements)
    }

    // MARK: - Ordinal word protection

    /// Prevents NeMo from converting spoken ordinals like "first" → "1st".
    /// In dictated prose ordinals are almost always adjective modifiers
    /// ("privacy first", "the first thing") rather than numeric labels.
    /// Skips ordinals that follow a month name (date context: "january fifth" → "january 5").
    private func protectingOrdinalWords(in text: String) -> ProtectedPunctuation {
        var result = text
        var replacements: [String: String] = [:]
        let matches = Self.ordinalWordPattern.matches(
            in: result, range: NSRange(result.startIndex..., in: result)
        ).reversed()

        for (index, match) in matches.enumerated() {
            guard let range = Range(match.range, in: result) else { continue }

            // Don't protect ordinals in date context ("january fifth")
            let before = result[result.startIndex..<range.lowerBound]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            if Self.monthNames.contains(where: { before.hasSuffix($0) }) {
                continue
            }

            let original = String(result[range])
            let placeholder = "__resonantord\(index)__"
            replacements[placeholder] = original
            result.replaceSubrange(range, with: placeholder)
        }

        return ProtectedPunctuation(text: result, replacements: replacements)
    }

    // MARK: - Spoken digit sequences

    private func preservingSpokenDigitSequences(in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: Self.spokenDigitSequencePattern, options: [.caseInsensitive]) else {
            return text
        }

        var result = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed()

        for match in matches {
            guard let range = Range(match.range, in: result) else { continue }
            let spokenSequence = String(result[range])
            let concatenatedDigits = concatenatedDigitString(from: spokenSequence)

            guard concatenatedDigits.count >= 2 else { continue }

            let upstreamNormalized = NemoTextProcessing.normalize(spokenSequence)
            let replacement: String

            let upstreamDigits = normalizedDigits(from: upstreamNormalized)
            if strippedLeadingZeros(upstreamDigits) == strippedLeadingZeros(concatenatedDigits) {
                replacement = upstreamNormalized
            } else {
                replacement = concatenatedDigits
            }

            result.replaceSubrange(range, with: replacement)
        }

        return result
    }

    private func concatenatedDigitString(from spokenSequence: String) -> String {
        let tokens = spokenSequence
            .split(whereSeparator: \.isWhitespace)
            .map { String($0).lowercased() }

        var digits = ""
        var repeatCount = 1
        for token in tokens {
            if token == "double" {
                repeatCount = 2
                continue
            }
            if token == "triple" {
                repeatCount = 3
                continue
            }
            guard let digit = Self.singleDigitWords[token] else {
                repeatCount = 1
                continue
            }
            digits += String(repeating: digit, count: repeatCount)
            repeatCount = 1
        }
        return digits
    }

    private func normalizedDigits(from text: String) -> String {
        text.filter(\.isNumber)
    }

    private func strippedLeadingZeros(_ digits: String) -> Substring {
        let stripped = digits.drop(while: { $0 == "0" })
        return stripped.isEmpty && !digits.isEmpty ? digits.suffix(1) : stripped
    }

    // MARK: - Colloquial hundreds

    private func normalizingColloquialHundreds(in text: String) -> String {
        var result = text
        let matches = Self.colloquialHundredsPattern.matches(
            in: result,
            range: NSRange(result.startIndex..., in: result)
        ).reversed()

        for match in matches {
            guard let fullRange = Range(match.range, in: result),
                  let hundredsRange = Range(match.range(at: 1), in: result),
                  let tensRange = Range(match.range(at: 2), in: result) else { continue }

            let hundredsWord = String(result[hundredsRange]).lowercased()
            let tensWord = String(result[tensRange]).lowercased()

            guard let hundreds = Self.onesWordValues[hundredsWord],
                  let tens = Self.colloquialHundredsTensValues[tensWord] else { continue }

            let ones: Int
            if match.range(at: 3).location != NSNotFound,
               let onesRange = Range(match.range(at: 3), in: result) {
                let onesWord = String(result[onesRange]).lowercased()
                guard let value = Self.singleDigitIntValues[onesWord] else { continue }
                ones = value
            } else {
                ones = 0
            }

            let replacement = "\(hundreds)\(String(format: "%02d", tens + ones))"
            result.replaceSubrange(fullRange, with: replacement)
        }

        return result
    }

    private func normalizingDigitHundreds(in text: String) -> String {
        var result = text
        let matches = Self.digitHundredsPattern.matches(
            in: result,
            range: NSRange(result.startIndex..., in: result)
        ).reversed()

        for match in matches {
            guard let fullRange = Range(match.range, in: result),
                  let numberRange = Range(match.range(at: 1), in: result) else { continue }

            let numberText = String(result[numberRange]).replacingOccurrences(of: ",", with: "")
            guard let number = Int(numberText) else { continue }

            if (2...99).contains(number) {
                result.replaceSubrange(fullRange, with: "\(number * 100)")
            } else if (200...990).contains(number), number % 10 == 0 {
                // Some STT engines render "twenty five hundred" as
                // "250 hundred"; treat the trailing zero as a digitization
                // artifact instead of multiplying by another hundred.
                result.replaceSubrange(fullRange, with: "\((number / 10) * 100)")
            } else if number > 1000, (1...9).contains(number % 1000) {
                // A seam inside "two thousand five | hundred" digitizes to
                // "2005 hundred" — the trailing ones digit was the hundreds
                // count, so 2005 hundred → 2500.
                result.replaceSubrange(fullRange, with: "\(number - number % 1000 + (number % 1000) * 100)")
            }
        }

        return result
    }

    private static let digitHundredsPlusWordPattern: NSRegularExpression = {
        let tens = "twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety"
        let teens = "ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen"
        let ones = "one|two|three|four|five|six|seven|eight|nine"
        // Remainder is a tens word (optionally + ones) or a teen — intentionally
        // not a bare ones word, since "100 five" is ambiguous ("100 five-star").
        let remainder = "(?:(?:\(tens))(?:[\\s-](?:\(ones)))?|(?:\(teens)))"
        return try! NSRegularExpression(
            pattern: "\\b([1-9][\\d,]*00)\\b[\\s-]+((?:and)[\\s-]+)?(\(remainder))\\b(?!-\\w)",
            options: [.caseInsensitive]
        )
    }()

    private static let digitHundredsRemainderTens = NumberWords.tens

    private static let digitHundredsRemainderTeens = NumberWords.teens

    private static func digitHundredsRemainderValue(_ text: String) -> Int? {
        let parts = text.split { $0 == " " || $0 == "-" }.map(String.init)
        if parts.count == 1 {
            return digitHundredsRemainderTens[parts[0]] ?? digitHundredsRemainderTeens[parts[0]]
        }
        if parts.count == 2,
           let tens = digitHundredsRemainderTens[parts[0]],
           let ones = onesWordValues[parts[1]] {
            return tens + ones
        }
        return nil
    }

    /// Combines a digit-form hundred that upstream STT already produced with a
    /// trailing word-form remainder it left behind: "100 forty" → "140",
    /// "200 fifty five" → "255", "2000 and fifteen" → "2015". Thousand-scale
    /// heads only recombine across an explicit "and": without it, "in 1900
    /// forty people" reads as a year followed by a count, not one number.
    private func normalizingDigitHundredsPlusWordNumber(in text: String) -> String {
        var result = text
        let matches = Self.digitHundredsPlusWordPattern.matches(
            in: result,
            range: NSRange(result.startIndex..., in: result)
        ).reversed()

        for match in matches {
            guard let fullRange = Range(match.range, in: result),
                  let headRange = Range(match.range(at: 1), in: result),
                  let remainderRange = Range(match.range(at: 3), in: result),
                  let head = Int(String(result[headRange]).replacingOccurrences(of: ",", with: ""))
            else { continue }
            if head >= 1000, match.range(at: 2).location == NSNotFound { continue }
            let remainderText = String(result[remainderRange]).lowercased()
            guard let remainder = Self.digitHundredsRemainderValue(remainderText) else { continue }
            result.replaceSubrange(fullRange, with: "\(head + remainder)")
        }

        return result
    }

    private func protectingMagnitudePhrases(in text: String) -> ProtectedPunctuation {
        var result = text
        var replacements: [String: String] = [:]
        let matches = Self.magnitudePhrasePattern.matches(
            in: result,
            range: NSRange(result.startIndex..., in: result)
        ).reversed()

        for (index, match) in matches.enumerated() {
            guard let fullRange = Range(match.range, in: result),
                  let numberRange = Range(match.range(at: 1), in: result),
                  let magnitudeRange = Range(match.range(at: 2), in: result) else { continue }

            if let priorWord = word(before: fullRange.lowerBound, in: result),
               Self.numberPhraseWords.contains(priorWord) {
                continue
            }

            let numberPhrase = String(result[numberRange])
            let magnitudeText = String(result[magnitudeRange]).lowercased()
            guard let number = magnitudeBaseValue(from: numberPhrase),
                  let multiplier = Self.magnitudeMultipliers[magnitudeText] else { continue }

            var value = number * Decimal(multiplier)
            var rounded = Decimal()
            NSDecimalRound(&rounded, &value, 0, .plain)
            guard let formatted = Self.decimalIntegerFormatter.string(from: rounded as NSDecimalNumber) else {
                continue
            }

            let placeholder = "__resonantmag\(index)__"
            replacements[placeholder] = formatted
            result.replaceSubrange(fullRange, with: placeholder)
        }

        return ProtectedPunctuation(text: result, replacements: replacements)
    }

    private func magnitudeBaseValue(from phrase: String) -> Decimal? {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let digitText = trimmed.replacingOccurrences(of: ",", with: "")
        if let value = Decimal(string: digitText) {
            return value
        }

        let tokens = trimmed
            .lowercased()
            .split { $0.isWhitespace || $0 == "-" }
            .map(String.init)
            .filter { $0 != "and" }

        guard !tokens.isEmpty else { return nil }

        var value = 0
        for token in tokens {
            if token == "hundred" {
                value = max(value, 1) * 100
            } else if let tokenValue = Self.cardinalWordValues[token] {
                value += tokenValue
            } else {
                return nil
            }
        }

        return value > 0 ? Decimal(value) : nil
    }

    private func word(before index: String.Index, in text: String) -> String? {
        let prefix = text[..<index].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = prefix.split(whereSeparator: { !$0.isLetter }).last else { return nil }
        return String(last).lowercased()
    }

    // MARK: - Measurement normalization

    private func normalizingDimensionBy(in text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return Self.dimensionByPattern.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: "$1 × $2"
        )
    }

    private func normalizingSpokenPercentSymbols(in text: String) -> String {
        var result = text
        let matches = Self.spokenPercentSymbolPattern.matches(
            in: result,
            range: NSRange(result.startIndex..., in: result)
        ).reversed()

        for match in matches {
            guard let fullRange = Range(match.range, in: result),
                  let numberRange = Range(match.range(at: 1), in: result),
                  let value = magnitudeBaseValue(from: String(result[numberRange])) else { continue }

            var rounded = Decimal()
            var decimalValue = value
            NSDecimalRound(&rounded, &decimalValue, 0, .plain)
            result.replaceSubrange(fullRange, with: "\(rounded)%")
        }

        return result
    }

    private func collapsingPercentSpacing(in text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return Self.percentSpacingPattern.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: "$1%"
        )
    }

    private func collapsingDecimalPoint(in text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return Self.decimalPointPattern.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: "$1.$2"
        )
    }

    private func collapsingVersionSpacing(in text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return Self.versionSpacingPattern.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: "$1$2"
        )
    }

    private func normalizingAreaMeasurements(in text: String) -> String {
        var result = text

        for pattern in [Self.squareMetersPattern, Self.metersSquaredPattern] {
            let range = NSRange(result.startIndex..., in: result)
            result = pattern.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: "$1 m²"
            )
        }

        return result
    }

    private func normalizingDigitMagnitudes(in text: String) -> String {
        var result = text

        let compactMatches = Self.compactKSpacingPattern.matches(
            in: result,
            range: NSRange(result.startIndex..., in: result)
        ).reversed()

        for match in compactMatches {
            guard let fullRange = Range(match.range, in: result),
                  let numberRange = Range(match.range(at: 1), in: result) else { continue }

            result.replaceSubrange(fullRange, with: "\(result[numberRange])k")
        }

        let matches = Self.digitMagnitudePattern.matches(
            in: result,
            range: NSRange(result.startIndex..., in: result)
        ).reversed()

        for match in matches {
            guard let fullRange = Range(match.range, in: result),
                  let numberRange = Range(match.range(at: 1), in: result),
                  let magnitudeRange = Range(match.range(at: 2), in: result) else { continue }

            let numberText = String(result[numberRange]).replacingOccurrences(of: ",", with: "")
            let magnitudeText = String(result[magnitudeRange]).lowercased()
            guard let number = Decimal(string: numberText),
                  let multiplier = Self.magnitudeMultipliers[magnitudeText] else { continue }

            var value = number * Decimal(multiplier)
            var rounded = Decimal()
            NSDecimalRound(&rounded, &value, 0, .plain)
            guard let formatted = Self.decimalIntegerFormatter.string(from: rounded as NSDecimalNumber) else {
                continue
            }

            result.replaceSubrange(fullRange, with: formatted)
        }

        return result
    }

    // MARK: - Spoken email protection

    /// Detects spoken email addresses, assembles them with a correctly-bounded
    /// local part, and replaces each with a placeholder so NeMo can never fuse
    /// the surrounding clause. Restored verbatim in `restoringProtectedPunctuation`.
    private func protectingSpokenEmailAddresses(in text: String) -> ProtectedPunctuation {
        let matches = Self.spokenEmailPattern.matches(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        )
        guard !matches.isEmpty else {
            return ProtectedPunctuation(text: text, replacements: [:])
        }

        var result = text
        var replacements: [String: String] = [:]
        var index = 0

        // Reversed so earlier (leftmost) ranges stay valid as we splice from
        // the right, matching the other protection passes.
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: result),
                  let localRange = Range(match.range(at: 1), in: result),
                  let domainRange = Range(match.range(at: 2), in: result),
                  let email = Self.assembleSpokenEmail(
                      local: String(result[localRange]),
                      domainSpan: String(result[domainRange])
                  )
            else { continue }

            let placeholder = "__resonantemail\(index)__"
            replacements[placeholder] = email
            result.replaceSubrange(fullRange, with: placeholder)
            index += 1
        }

        return ProtectedPunctuation(text: result, replacements: replacements)
    }

    /// Builds `local@domain.tld` from the captured spoken halves, or returns
    /// nil when the candidate fails the email guards (unknown TLD, a determiner
    /// domain such as "this"/"that", or a purely-numeric domain label). The
    /// assembled address is lowercased — only the address, never the prose that
    /// surrounds it in the caller.
    private static func assembleSpokenEmail(local: String, domainSpan: String) -> String? {
        let domain = domainSpan
            .replacingOccurrences(of: #"\s+dot\s+"#, with: ".", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        let labels = domain.split(separator: ".", omittingEmptySubsequences: true).map(String.init)
        guard labels.count >= 2,
              let tld = labels.last?.lowercased(),
              Self.emailTopLevelDomains.contains(tld),
              let mainLabel = labels.first?.lowercased(),
              !Self.nonEmailDomainWords.contains(mainLabel),
              labels[0].contains(where: { $0.isLetter })
        else {
            return nil
        }

        guard let localPart = assembleEmailLocalPart(local) else {
            return nil
        }

        return "\(localPart)@\(domain)".lowercased()
    }

    /// Collapses the spoken local part into its written form: explicit spoken
    /// connectors (dot/underscore/dash/hyphen/plus) map to their symbols, and a
    /// trailing run of digit words absorbs onto a real handle token
    /// ("john seven seven" -> "john77"). Returns nil when the local is nothing
    /// but digit words, so a standalone "seven at gmail dot com" is left to the
    /// single-token path rather than fused into a spurious handle.
    private static func assembleEmailLocalPart(_ local: String) -> String? {
        let connected = local
            .replacingOccurrences(of: #"\s+dot\s+"#, with: ".", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s+underscore\s+"#, with: "_", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s+(?:dash|hyphen)\s+"#, with: "-", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s+plus\s+"#, with: "+", options: [.regularExpression, .caseInsensitive])

        let tokens = connected.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let head = tokens.first else { return nil }

        // Multiple whitespace-separated tokens can only be a handle followed by
        // a spoken digit run. A pure digit-word run (no real handle) is left for
        // the caller's other paths.
        if tokens.count > 1 {
            let isDigitWord = { (token: String) in Self.singleDigitWords[token.lowercased()] != nil }
            guard !isDigitWord(head) else { return nil }
            var localPart = head
            for token in tokens.dropFirst() {
                guard let digit = Self.singleDigitWords[token.lowercased()] else { return nil }
                localPart += digit
            }
            return localPart.contains(where: { $0.isLetter || $0.isNumber }) ? localPart : nil
        }

        guard head.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return head
    }

    /// Shields bare prepositional "at" from NeMo's electronic grammar. Real
    /// spoken emails were already extracted by `protectingSpokenEmailAddresses`,
    /// so every surviving "at" is prose; NeMo would otherwise convert it to "@"
    /// and fuse neighbouring words into a bogus address. "at sign" is excluded
    /// so it can still normalize to "@".
    private func protectingPrepositionalAt(in text: String) -> ProtectedPunctuation {
        let matches = Self.prepositionalAtPattern.matches(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        )
        guard !matches.isEmpty else {
            return ProtectedPunctuation(text: text, replacements: [:])
        }

        var result = text
        var replacements: [String: String] = [:]
        for (index, match) in matches.reversed().enumerated() {
            guard let range = Range(match.range, in: result) else { continue }
            let placeholder = "__resonantat\(index)__"
            replacements[placeholder] = String(result[range])
            result.replaceSubrange(range, with: placeholder)
        }
        return ProtectedPunctuation(text: result, replacements: replacements)
    }

    // MARK: - Spoken punctuation protection

    private func protectingSpokenPunctuation(in text: String) -> ProtectedPunctuation {
        guard let regex = try? NSRegularExpression(
            pattern: Self.spokenPunctuationPattern,
            options: [.caseInsensitive]
        ) else {
            return ProtectedPunctuation(text: text, replacements: [:])
        }

        var result = text
        var replacements: [String: String] = [:]
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed()

        for (index, match) in matches.enumerated() {
            guard let range = Range(match.range, in: result) else { continue }
            let originalPhrase = String(result[range])
            let placeholder = "__resonantpunct\(index)__"
            replacements[placeholder] = originalPhrase
            result.replaceSubrange(range, with: placeholder)
        }

        return ProtectedPunctuation(text: result, replacements: replacements)
    }

    private func restoringProtectedPunctuation(
        in text: String,
        replacements: [String: String]
    ) -> String {
        guard !replacements.isEmpty else { return text }

        var restored = text
        for (placeholder, originalPhrase) in replacements {
            restored = restored.replacingOccurrences(of: placeholder, with: originalPhrase)
        }
        return restored
    }

    // MARK: - Patterns

    /// Matches a spoken email: a bounded local handle, the literal "at", and a
    /// domain that ends in one or more spoken "dot <label>" segments. The local
    /// half only absorbs words joined by explicit spoken connectors
    /// (dot/underscore/dash/hyphen/plus) plus an optional trailing run of digit
    /// words, so a plain-space-separated preposition like "to" in "...email to
    /// Asa at growthfarm dot com" stays outside the match. "plus" and the digit
    /// run only carry weight because the whole "at <domain> dot <tld>" anchor is
    /// present, so arithmetic prose ("two plus two") is never touched.
    private static let spokenEmailPattern = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9._%+\-@])([A-Za-z0-9]+(?:[._\-][A-Za-z0-9]+)*(?:\s+(?:dot|underscore|dash|hyphen|plus)\s+[A-Za-z0-9]+)*(?:\s+(?:zero|oh|one|two|three|four|five|six|seven|eight|nine))*)\s+at\s+([A-Za-z0-9\-]+(?:\s+dot\s+[A-Za-z0-9\-]+)+)\b"#,
        options: [.caseInsensitive]
    )

    /// Trailing labels that confirm a "<word> dot <word>" run is an address
    /// rather than incidental "X at Y dot Z" prose. Kept broad but explicit so
    /// the "at"/"dot" trigger only fires on a real top-level domain.
    private static let emailTopLevelDomains: Set<String> = [
        "com", "org", "net", "edu", "gov", "mil", "int", "co", "io", "ai",
        "app", "dev", "me", "info", "biz", "xyz", "tech", "online", "store",
        "site", "cloud", "email", "news", "live", "team", "design", "page",
        "us", "uk", "ca", "au", "de", "fr", "es", "it", "nl", "se", "no",
        "fi", "dk", "ie", "ch", "at", "be", "pl", "pt", "cz", "eu", "jp",
        "cn", "in", "br", "mx", "ru", "za", "nz", "kr", "tv", "fm", "gg",
        "ly", "sh", "so", "to", "cc", "ws", "id", "ai",
    ]

    /// Domain main-labels that signal "at <word> dot <tld>" is prose, not an
    /// address (e.g. "look at this dot com", "look at that dot org"). Without
    /// this, those determiners would be assembled into bogus emails.
    private static let nonEmailDomainWords: Set<String> = [
        "this", "that", "these", "those", "here", "there", "the", "it",
    ]

    /// Bare "at" used as a preposition (anything except "at sign", which is a
    /// legitimate spoken "@"). Matched after email assembly so it only ever
    /// covers prose, never an address operator.
    private static let prepositionalAtPattern = try! NSRegularExpression(
        pattern: #"\bat\b(?!\s+sign\b)"#,
        options: [.caseInsensitive]
    )

    private static let timePattern: NSRegularExpression = {
        let hours = "one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve"

        let ohMinutes = "oh\\s+(?:one|two|three|four|five|six|seven|eight|nine)"
        let tensOnes = "(?:twenty|thirty|forty|fifty)\\s+(?:one|two|three|four|five|six|seven|eight|nine)"
        let teens = "ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen"
        let tensOnly = "twenty|thirty|forty|fifty"
        // Order: longer compound forms first so regex greedily matches them
        let minutes = "\(ohMinutes)|\(tensOnes)|\(teens)|\(tensOnly)"

        let ampm = "(?:\\s+(?:a\\.?\\s*m\\.?|p\\.?\\s*m\\.?))"

        return try! NSRegularExpression(
            pattern: "\\b(\(hours))\\s+(\(minutes))(\(ampm))?\\b",
            options: [.caseInsensitive]
        )
    }()

    private static let yearPattern: NSRegularExpression = {
        let ones = "one|two|three|four|five|six|seven|eight|nine"
        let teens = "ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen"
        let tens = "twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety"

        // Beyond the classic "nineteen"/"twenty" centuries, four-digit numbers
        // are spoken in pairs: compound tens ("twenty six seventy seven" →
        // 2677) and teens ("seventeen seventy six" → 1776). Compound first so
        // "twenty six" wins over bare "twenty".
        let centuryCompound = "(?:\(tens))(?:\\s+|\\s*-\\s*)(?:\(ones))"
        let century = "\(centuryCompound)|\(teens)|twenty"

        let ohOnes = "oh\\s+(?:\(ones))"
        let tensOnes = "(?:\(tens))(?:\\s+|\\s*-\\s*)(?:\(ones))"
        // Order: longer compound forms first so regex greedily matches them
        let yearPart = "\(ohOnes)|\(tensOnes)|\(teens)|\(tens)"

        return try! NSRegularExpression(
            pattern: "\\b(\(century))\\s+(\(yearPart))(?!\\s+(?:hundred|thousand))\\b",
            options: [.caseInsensitive]
        )
    }()

    private static let numberConnectorPattern: NSRegularExpression = {
        let digits = #"\d[\d,]*"#
        let ones = "one|two|three|four|five|six|seven|eight|nine"
        let teens = "ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen"
        let tens = "twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety"
        let colloquialHundred = "(?:\(ones))\\s+(?:\(tens))(?:\\s+(?:\(ones)))?"
        let compound = "(?:\(tens))\\s+(?:\(ones))"
        let simple = "\(ones)|\(teens)|\(tens)"
        let number = "(?:\(digits)|\(colloquialHundred)|\(compound)|\(simple))"

        return try! NSRegularExpression(
            pattern: "\\b(\(number))\\s+(and|to)\\s+(\(number))\\b",
            options: [.caseInsensitive]
        )
    }()

    private static let twentyFourSevenPattern = try! NSRegularExpression(
        pattern: #"\btwenty(?:\s+|-)four\s+seven\b"#,
        options: [.caseInsensitive]
    )

    private static let vagueQuantityPattern = try! NSRegularExpression(
        pattern: #"\b(?:couple|few|several)(?:\s+of)?\s+(?:hundred|thousand|million|billion|dozen)\b"#,
        options: [.caseInsensitive]
    )

    private static let colloquialHundredsPattern = try! NSRegularExpression(
        pattern: #"\b(one|two|three|four|five|six|seven|eight|nine)\s+(sixty|seventy|eighty|ninety)(?:[\s-]+(zero|oh|o|one|two|three|four|five|six|seven|eight|nine))?\b"#,
        options: [.caseInsensitive]
    )

    private static let magnitudePhrasePattern: NSRegularExpression = {
        let digits = #"\d[\d,]*(?:\.\d+)?"#
        let ones = "one|two|three|four|five|six|seven|eight|nine"
        let teens = "ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen"
        let tens = "twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety"
        let word = "\(ones)|\(teens)|\(tens)|hundred|and"
        let words = "(?:\(word))(?:[\\s-]+(?:\(word)))*"

        return try! NSRegularExpression(
            pattern: "\\b(\(digits)|\(words))\\s+(thousand|million|billion)\\b",
            options: [.caseInsensitive]
        )
    }()

    private static let digitHundredsPattern = try! NSRegularExpression(
        pattern: #"\b(\d{1,3}(?:,\d{3})+|\d{1,7})\s+hundred\b"#,
        options: [.caseInsensitive]
    )

    private static let digitOnlyPattern = try! NSRegularExpression(
        pattern: #"^\d[\d,]*$"#,
        options: []
    )

    private static let monthNames: Set<String> = [
        "january", "february", "march", "april", "may", "june",
        "july", "august", "september", "october", "november", "december",
    ]

    private static let ordinalWordPattern = try! NSRegularExpression(
        pattern: #"\b(first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|eleventh|twelfth)\b"#,
        options: [.caseInsensitive]
    )

    /// A spoken-digit run element is a bare digit word, optionally prefixed by
    /// "double"/"triple" to repeat the following digit. Two or more elements are
    /// required so a stray "double two" outside a sequence is left untouched.
    private static let spokenDigitSequencePattern: String = {
        let digit = "zero|oh|o|one|two|three|four|five|six|seven|eight|nine"
        let element = "(?:(?:double|triple)\\s+)?(?:\(digit))"
        return "\\b\(element)(?:[\\s]+\(element))+\\b"
    }()

    // MARK: - Lookup tables

    private static let singleDigitWords: [String: String] =
        NumberWords.singleDigits.mapValues(String.init)

    private static let singleDigitIntValues = NumberWords.singleDigits

    private static let cardinalWordValues = NumberWords.cardinals

    private static let numberPhraseWords: Set<String> = Set(cardinalWordValues.keys).union(["hundred", "and", "oh", "o", "zero"])
    private static let rangeConnectorWords: Set<String> = ["to", "through", "between", "from", "and"]

    private static let hourWordValues: [String: Int] = NumberWords.ones
        .merging(["ten": 10, "eleven": 11, "twelve": 12]) { current, _ in current }

    private static let minuteWordValues: [String: Int] = NumberWords.teens
        .merging(tensWordValues) { current, _ in current }

    private static let tensWordValues: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
    ]

    private static let colloquialHundredsTensValues: [String: Int] = [
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    private static let onesWordValues = NumberWords.ones

    private static let centuryWordValues: [String: Int] = [
        "nineteen": 19, "twenty": 20,
    ]

    private static let yearTeenValues = NumberWords.teens

    private static let yearTensValues = NumberWords.tens

    private static let spokenPunctuationPattern: String = {
        let terms = [
            "exclamation point",
            "exclamation mark",
            "question mark",
            "open parenthesis",
            "close parenthesis",
            "left parenthesis",
            "right parenthesis",
            "open bracket",
            "close bracket",
            "left bracket",
            "right bracket",
            "open brace",
            "close brace",
            "left brace",
            "right brace",
            "double quote",
            "single quote",
            "forward slash",
            "back slash",
            "at sign",
            "period",
            "dot",
            "comma",
            "colon",
            "semicolon",
            "hyphen",
            "dash",
            "ellipsis",
            "ampersand",
            "asterisk",
            "hash",
            // "percent" is a unit, not punctuation — it converts to "%"
            // regardless of the auto-punctuation setting.
            "plus",
            "equals",
            "tilde",
            "underscore",
            "pipe",
            "slash",
        ]
            .sorted { $0.count > $1.count }
            .map(NSRegularExpression.escapedPattern(for:))
            .joined(separator: "|")

        return #"\b(?:\#(terms))\b"#
    }()

    /// Matches "4 m by 2 m", "10 feet by 12 feet", etc.
    /// First unit is required to avoid false positives; second unit is optional.
    private static let dimensionByPattern = try! NSRegularExpression(
        pattern: #"\b(\d[\d,]*(?:\.\d+)?\s*(?:m|cm|mm|km|ft|in|meters?|metres?|feet|inch(?:es)?|yards?|yd))\s+by\s+(\d[\d,]*(?:\.\d+)?(?:\s*(?:m|cm|mm|km|ft|in|meters?|metres?|feet|inch(?:es)?|yards?|yd))?)\b"#,
        options: [.caseInsensitive]
    )

    private static let percentSpacingPattern = try! NSRegularExpression(
        pattern: #"(\d)\s+%"#,
        options: []
    )

    private static let spokenPercentSymbolPattern: NSRegularExpression = {
        let ones = "one|two|three|four|five|six|seven|eight|nine"
        let teens = "ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen"
        let tens = "twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety"
        let word = "\(ones)|\(teens)|\(tens)|hundred|and"
        let words = "(?:\(word))(?:[\\s-]+(?:\(word)))*"

        return try! NSRegularExpression(
            pattern: "\\b(\(words))\\s*%",
            options: [.caseInsensitive]
        )
    }()

    private static let decimalPointPattern = try! NSRegularExpression(
        pattern: #"(\d+)(?:\s+point\s+|\s+\.)(\d+)"#,
        options: [.caseInsensitive]
    )

    private static let versionSpacingPattern = try! NSRegularExpression(
        pattern: #"\b([A-Z])\s+(\d+\.\d+)"#,
        options: []
    )

    private static let squareMetersPattern = try! NSRegularExpression(
        pattern: #"\b(\d[\d,]*(?:\.\d+)?)\s+square\s+(?:m|meter|meters|metre|metres)\b"#,
        options: [.caseInsensitive]
    )

    private static let metersSquaredPattern = try! NSRegularExpression(
        pattern: #"\b(\d[\d,]*(?:\.\d+)?)\s+(?:m|meter|meters|metre|metres)\s+squared\b"#,
        options: [.caseInsensitive]
    )

    private static let compactKSpacingPattern = try! NSRegularExpression(
        pattern: #"\b(\d[\d,]*(?:\.\d+)?)\s+([kK])\b"#,
        options: []
    )

    private static let digitMagnitudePattern = try! NSRegularExpression(
        pattern: #"\b(\d[\d,]*(?:\.\d+)?)\s+(thousand|million|billion)\b"#,
        options: [.caseInsensitive]
    )

    private static let magnitudeMultipliers: [String: Int] = [
        "thousand": 1_000,
        "million": 1_000_000,
        "billion": 1_000_000_000,
    ]

    private static let decimalIntegerFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.groupingSize = 3
        return formatter
    }()

    private struct ProtectedPunctuation {
        let text: String
        let replacements: [String: String]
    }
}
