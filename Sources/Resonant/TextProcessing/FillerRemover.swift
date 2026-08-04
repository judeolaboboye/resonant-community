import Foundation

/// Removes filler words and false starts from ASR output.
struct FillerRemover {

    // Words to strip (case-insensitive, whole-word match)
    private static let fillers: Set<String> = [
        "um", "uh", "er", "ah", "hmm", "hm", "mhm",
    ]

    // False start patterns: "call at noon scratch that call at one" → "call at one"
    // Phrase-level corrections strip the abandoned wording before the signal only
    // when a substantive replacement follows the signal, and only within the
    // signal's own sentence so earlier completed sentences survive.
    // "I mean" is handled by applyInlineRepairs (precise 1-word swap) instead
    // of this aggressive prefix-strip to avoid eating valid uses like
    // "yeah I mean yes".
    //
    // Strong retraction cues explicitly cancel prior wording, so they may also
    // reach back across one same-line sentence boundary — pauses before a
    // correction routinely become periods ("Call Priya at noon. Scratch that
    // call her at one"). Weak connective cues are too ambiguous for that:
    // sentence-initial "Actually no, …" is usually a deliberate reply, not a
    // retraction, so they only repair within their own sentence.
    private static let strongCorrectionSignals = [
        "scratch that", "scratch this", "strike that", "scrap that",
        "never mind", "cancel that", "forget that",
    ]
    private static let weakCorrectionSignals = [
        "no actually", "no wait", "wait no", "sorry no",
        "actually no", "wait actually", "wait but actually", "but actually",
    ]
    private static let correctionSignals = strongCorrectionSignals + weakCorrectionSignals
    private static let correctionSignalRegex: NSRegularExpression = {
        let alternation = correctionSignals
            .sorted { $0.count > $1.count }
            .map { signal in
                signal.split(separator: " ")
                    .map { NSRegularExpression.escapedPattern(for: String($0)) }
                    .joined(separator: #"\s+"#)
            }
            .joined(separator: "|")
        return try! NSRegularExpression(
            pattern: #"\b(?:"# + alternation + #")\b"#,
            options: [.caseInsensitive]
        )
    }()
    private static let sentenceBoundaryCharacters: Set<Character> = [".", "!", "?", "…", "\n"]
    private static let leadingTailJunk = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: ".,;:!?-–—"))
    private static let unsafeReplacementLeadingWords: Set<String> = [
        "actually", "although", "and", "because", "but", "however",
        "never", "no", "or", "so", "sorry", "then", "though", "wait",
    ]
    private static let repeatedRestartWeakWords: Set<String> = [
        "a", "an", "and", "are", "be", "been", "being", "but", "did",
        "do", "does", "for", "get", "got", "had", "has", "have", "i",
        "in", "is", "it", "new", "of", "on", "or", "so", "that", "the",
        "this", "to", "was", "we", "were", "with", "you",
    ]
    // Words safe to de-duplicate when stuttered immediately ("the the" → "the",
    // "I I" → "I", "the The" → "the"). Deliberately restricted to articles,
    // subject/possessive pronouns, and subject+copula contractions — none of
    // which is ever validly doubled in English. Auxiliaries and the copula
    // ("had had", "is is"), prepositions/conjunctions that double grammatically
    // ("go to to what", "that that he mentioned"), object pronouns that can sit
    // before a clause subject ("told you you should"), and emphatic content
    // words ("very very", "no no") are all EXCLUDED, because collapsing them
    // would corrupt real speech.
    private static let stutterCollapsibleWords: Set<String> = [
        "a", "an", "the",
        "i", "we", "he", "she", "it", "they",
        "my", "your", "his", "its", "our", "their",
        "i'm", "we're", "you're", "they're", "it's", "he's", "she's",
        "that's", "there's",
    ]
    private static let minimumReplacementTailWordCount = 2
    private static let repeatedRestartMinPhraseWords = 3
    private static let repeatedRestartMaxPhraseWords = 7
    private static let repeatedRestartMaxAbandonedWords = 4
    // The separator groups tolerate sentence punctuation because the pause a
    // speaker takes before correcting themselves routinely becomes a period —
    // from the model itself or from pause segmentation — as in
    // "the deadline is Tuesday. Actually no Wednesday".
    private static let singleWordCorrectionPattern = try! NSRegularExpression(
        pattern: #"\b(\w+)(\s*[,.;:!?]\s+|\s*,?\s+)(no\s+actually|no\s+wait|wait\s+no|sorry\s+no|actually\s+no|wait\s+actually|wait\s+but\s+actually|but\s+actually)[\s,.]+(\w+)\b"#,
        options: [.caseInsensitive]
    )
    // Extra veto for swaps whose X–cue separator crossed a sentence boundary:
    // a sentence-initial "No wait Sarah should join too" is far more often an
    // afterthought clause than a one-word replacement, so the replacement must
    // not read as the start of a new clause or question.
    private static let boundaryCrossingUnsafeReplacements: Set<String> = [
        "am", "are", "can", "could", "did", "do", "does", "had", "has", "have",
        "how", "is", "just", "let", "may", "might", "must", "please", "shall",
        "should", "was", "were", "what", "when", "where", "which", "who",
        "why", "will", "would",
    ]
    private static let maximumBoundaryCrossingTrailingWords = 2

    private struct WordToken {
        let normalized: String
        let range: Range<String.Index>
    }

    func process(_ text: String, removeFillersEnabled: Bool, removeFalseStartsEnabled: Bool) -> String {
        var result = text

        if removeFillersEnabled {
            result = removeFillersFromText(result)
        }

        if removeFalseStartsEnabled {
            result = applyInlineRepairs(result)
            result = removeFalseStarts(result)
        }

        return result
    }

    // MARK: - Filler removal

    private func removeFillersFromText(_ text: String) -> String {
        var result = text
        for filler in Self.fillers {
            // Hyphen guards: `\b` treats "-" as a boundary, so bare `\bhmm\b`
            // matches inside "Mm-hmm" and mangles it to "Mm-".
            let pattern = #"(?i)(?<![\w-])"# + NSRegularExpression.escapedPattern(for: filler) + #"(?![\w-])[,\s]*"#
            if let regex = try? NSRegularExpression(pattern: pattern) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: " "
                )
            }
        }
        // Collapse multiple spaces without flattening the paragraph breaks the
        // pause segmenter inserts upstream.
        result = Self.collapseHorizontalWhitespace(result)
        return result.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Inline repairs
    //
    // High-precision single-word substitutions triggered by explicit
    // correction markers. Runs before the blunt prefix-strip so targeted
    // repairs survive. Patterns only fire when the correction intent is
    // unambiguous (e.g. trailing "sorry" after a choice, or a comma before
    // "I mean"). Default alignment span is one word on each side — wider
    // repairs require semantic alignment and are left to a later stage.

    private static let inlineRepairPatterns: [(NSRegularExpression, String)] = {
        let sources: [(String, String)] = [
            // "X or Y, sorry" → "Y"   (choice + trailing correction marker)
            (#"\b(\w+)\s+or\s+(\w+)\s*,?\s*sorry\b"#, "$2"),
            // "X, I mean Y" → "Y"    (comma required; avoids "yeah I mean yes")
            (#"\b(\w+)\s*,\s*I\s+mean\s+(\w+)\b"#, "$2"),
            // "X, no, Y" → "Y"       (punctuation required; avoids "no Tuesday meetings")
            (#"\b(\w+)\s*,\s*no\s*,\s*(\w+)\b"#, "$2"),
            // "X, or rather Y" → "Y" (comma optional; marker is unambiguous)
            (#"\b(\w+)\s*,?\s+or\s+rather\s+(\w+)\b"#, "$2"),
        ]
        return sources.compactMap { pattern, template in
            guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            ) else { return nil }
            return (regex, template)
        }
    }()

    private func applyInlineRepairs(_ text: String) -> String {
        var result = text
        for (regex, template) in Self.inlineRepairPatterns {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: template
            )
        }
        result = applySingleWordCorrectionRepairs(result)
        result = collapseAdjacentStutters(result)
        result = removeRepeatedRestartFalseStarts(result)
        // Collapse any double spaces introduced by the rewrites, preserving
        // upstream paragraph breaks.
        result = Self.collapseHorizontalWhitespace(result)
        return result
    }

    private func applySingleWordCorrectionRepairs(_ text: String) -> String {
        let nsText = text as NSString
        let matches = Self.singleWordCorrectionPattern.matches(
            in: text,
            range: NSRange(location: 0, length: nsText.length)
        )
        guard !matches.isEmpty else { return text }

        let result = NSMutableString(string: text)
        for match in matches.reversed() where match.numberOfRanges >= 5 {
            let replacement = nsText.substring(with: match.range(at: 4))
            let lowered = replacement.lowercased()
            guard !Self.unsafeReplacementLeadingWords.contains(lowered) else { continue }

            let separator = nsText.substring(with: match.range(at: 2))
            if separator.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?…")) != nil {
                guard !Self.boundaryCrossingUnsafeReplacements.contains(lowered) else { continue }
                // A true one-word replacement ends its clause almost
                // immediately ("…Tuesday. Actually no Wednesday."); a longer
                // continuation means the cue opened a new clause instead.
                let tailRange = match.range(at: 4)
                let remainder = nsText.substring(from: tailRange.location + tailRange.length)
                guard Self.wordCountBeforeSentenceEnd(in: remainder)
                    <= Self.maximumBoundaryCrossingTrailingWords else { continue }
            }

            result.replaceCharacters(in: match.range, with: replacement)
        }

        return result as String
    }

    private static func wordCountBeforeSentenceEnd(in text: String) -> Int {
        var count = 0
        var inWord = false
        for character in text {
            if sentenceBoundaryCharacters.contains(character) { break }
            if isWordCharacter(character) {
                if !inWord {
                    count += 1
                    inWord = true
                }
            } else {
                inWord = false
            }
        }
        return count
    }

    /// Collapses an immediate weak-word stutter the speaker (or the model,
    /// re-capitalizing after a pause) repeats verbatim: "the the button" →
    /// "the button", "I I I think" → "I think", "the The where" → "the where".
    /// Only words in `stutterCollapsibleWords` collapse, and only when the copies
    /// are separated by horizontal whitespace on the same line — a comma, period,
    /// or a paragraph break between them ("the, the second one") signals
    /// deliberate phrasing and is left intact. An article in front of a
    /// "The"-titled proper noun ("the The Office", "the The Who", the band
    /// "The The") is preserved, not flattened. The first occurrence and its
    /// casing are kept.
    private func collapseAdjacentStutters(_ text: String) -> String {
        let tokens = Self.wordTokens(in: text)
        guard tokens.count >= 2 else { return text }

        var deletions: [Range<String.Index>] = []
        var index = 0
        while index < tokens.count {
            let normalized = tokens[index].normalized
            var runEnd = index
            while runEnd + 1 < tokens.count,
                  tokens[runEnd + 1].normalized == normalized,
                  text[tokens[runEnd].range.upperBound..<tokens[runEnd + 1].range.lowerBound]
                    .allSatisfy(Self.isHorizontalWhitespace) {
                runEnd += 1
            }
            if runEnd > index,
               Self.stutterCollapsibleWords.contains(normalized),
               !looksLikeTitledProperNoun(tokens: tokens, runStart: index, runEnd: runEnd, in: text) {
                // Drop every copy after the first, including the whitespace that
                // precedes each duplicate.
                deletions.append(tokens[index].range.upperBound..<tokens[runEnd].range.upperBound)
            }
            index = runEnd + 1
        }

        guard !deletions.isEmpty else { return text }

        var result = text
        for range in deletions.reversed() {
            result.removeSubrange(range)
        }
        return Self.normalizeSpacingAfterRemoval(result)
    }

    /// Distinguishes an article + "The"-titled proper noun ("the The Office",
    /// "the The Who", or the band "The The") from a re-capitalized stutter
    /// ("the The where"). A title is the case where a dropped copy is capitalized
    /// AND the word continuing past the run is also capitalized (or the run ends
    /// the text); a genuine restart continues in lowercase.
    private func looksLikeTitledProperNoun(
        tokens: [WordToken],
        runStart: Int,
        runEnd: Int,
        in text: String
    ) -> Bool {
        let droppedCopyCapitalized = (runStart + 1...runEnd).contains {
            text[tokens[$0].range.lowerBound].isUppercase
        }
        guard droppedCopyCapitalized else { return false }
        guard runEnd + 1 < tokens.count else { return true }
        return text[tokens[runEnd + 1].range.lowerBound].isUppercase
    }

    private func removeRepeatedRestartFalseStarts(_ text: String) -> String {
        var result = text
        var stripped = false

        for _ in 0..<3 {
            guard let range = Self.repeatedRestartRemovalRange(in: result) else { break }
            result.removeSubrange(range)
            stripped = true
            result = Self.normalizeSpacingAfterRemoval(result)
        }

        if stripped, let first = result.first, first.isLowercase {
            result = first.uppercased() + result.dropFirst()
        }

        return result
    }

    // MARK: - False start removal

    private func removeFalseStarts(_ text: String) -> String {
        var result = text

        for _ in 0..<3 {
            guard let removal = Self.falseStartRemovalRange(in: result) else { break }
            let offset = result.distance(from: result.startIndex, to: removal.lowerBound)
            result.removeSubrange(removal)
            // The kept replacement now opens its sentence — capitalize it.
            let tailStart = result.index(result.startIndex, offsetBy: offset)
            if tailStart < result.endIndex, result[tailStart].isLowercase {
                result.replaceSubrange(
                    tailStart...tailStart,
                    with: result[tailStart].uppercased()
                )
            }
            result = Self.normalizeSpacingAfterRemoval(result)
        }

        return result
    }

    /// Finds the abandoned wording + correction cue to delete. The deletion
    /// always starts at a sentence boundary: normally the start of the cue's
    /// own sentence, or — for strong retraction cues that open their sentence —
    /// the start of the previous same-line sentence, because the pause before
    /// a correction routinely becomes a period upstream.
    private static func falseStartRemovalRange(in text: String) -> Range<String.Index>? {
        let matches = correctionSignalRegex.matches(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        )
        for match in matches {
            guard let cueRange = Range(match.range, in: text) else { continue }
            guard let tailStart = safeReplacementTailStart(after: cueRange.upperBound, in: text) else {
                continue
            }

            let sentenceStart = startOfSentence(endingBefore: cueRange.lowerBound, in: text)
            if containsWordCharacter(text[sentenceStart..<cueRange.lowerBound]) {
                return sentenceStart..<tailStart
            }

            // The cue opens its sentence. A bare cue with nothing to retract
            // is content ("Actually no, I disagree"), so weak cues stop here;
            // strong cues retract the previous same-line sentence.
            guard isStrongCorrectionSignal(String(text[cueRange])),
                  let previousStart = startOfPreviousSentence(before: sentenceStart, in: text)
            else { continue }
            return previousStart..<tailStart
        }
        return nil
    }

    private static func safeReplacementTailStart(
        after cueEnd: String.Index,
        in text: String
    ) -> String.Index? {
        var start = cueEnd
        while start < text.endIndex, isTailJunk(text[start]) {
            start = text.index(after: start)
        }
        guard start < text.endIndex else { return nil }
        let tail = String(text[start...])
        guard replacementTailWordCount(tail) >= minimumReplacementTailWordCount else { return nil }
        guard let firstWord = firstWord(in: tail)?.lowercased(),
              !unsafeReplacementLeadingWords.contains(firstWord)
        else { return nil }
        guard !startsWithCorrectionSignal(tail) else { return nil }
        return start
    }

    /// Start of the sentence containing `index`: the first word character
    /// after the nearest preceding sentence terminator (or the text start).
    private static func startOfSentence(
        endingBefore index: String.Index,
        in text: String
    ) -> String.Index {
        var boundary: String.Index?
        var cursor = index
        while cursor > text.startIndex {
            cursor = text.index(before: cursor)
            if sentenceBoundaryCharacters.contains(text[cursor]) {
                boundary = cursor
                break
            }
        }
        var start = boundary.map { text.index(after: $0) } ?? text.startIndex
        while start < index, !isWordCharacter(text[start]) {
            start = text.index(after: start)
        }
        return start
    }

    /// Start of the sentence that ends just before `sentenceStart`, but only
    /// when the two are separated by sentence punctuation on the same line —
    /// a paragraph break is a topic change, not a retractable clause.
    private static func startOfPreviousSentence(
        before sentenceStart: String.Index,
        in text: String
    ) -> String.Index? {
        var cursor = sentenceStart
        var sawSentencePunctuation = false
        while cursor > text.startIndex {
            let previous = text.index(before: cursor)
            let character = text[previous]
            if isWordCharacter(character) { break }
            if character == "\n" { return nil }
            if character == "." || character == "!" || character == "?" || character == "…" {
                sawSentencePunctuation = true
            }
            cursor = previous
        }
        guard sawSentencePunctuation, cursor > text.startIndex else { return nil }

        let previousStart = startOfSentence(endingBefore: cursor, in: text)
        guard previousStart < cursor,
              containsWordCharacter(text[previousStart..<cursor])
        else { return nil }
        return previousStart
    }

    private static func isStrongCorrectionSignal(_ cue: String) -> Bool {
        let normalized = cue
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return strongCorrectionSignals.contains(normalized)
    }

    private static func containsWordCharacter(_ text: Substring) -> Bool {
        text.contains(where: isWordCharacter)
    }

    private static func isTailJunk(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy(leadingTailJunk.contains)
    }

    private static func startsWithCorrectionSignal(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return correctionSignals.contains { signal in
            lowered == signal
                || lowered.hasPrefix(signal + " ")
                || lowered.hasPrefix(signal + ",")
                || lowered.hasPrefix(signal + ".")
        }
    }

    private static func replacementTailWordCount(_ text: String) -> Int {
        text.split(whereSeparator: { !isWordCharacter($0) }).count
    }

    private static func firstWord(in text: String) -> String? {
        text.split(whereSeparator: { !isWordCharacter($0) }).first.map(String.init)
    }

    private static func repeatedRestartRemovalRange(in text: String) -> Range<String.Index>? {
        let tokens = wordTokens(in: text)
        guard tokens.count >= repeatedRestartMinPhraseWords * 2 + 2 else { return nil }

        for phraseLength in stride(
            from: min(repeatedRestartMaxPhraseWords, (tokens.count - 2) / 2),
            through: repeatedRestartMinPhraseWords,
            by: -1
        ) {
            for firstStart in tokens.indices {
                let firstEnd = firstStart + phraseLength
                guard firstEnd < tokens.count else { continue }

                let minimumSecondStart = firstEnd + 1
                let maximumSecondStart = min(
                    firstEnd + repeatedRestartMaxAbandonedWords,
                    tokens.count - phraseLength - 1
                )
                guard minimumSecondStart <= maximumSecondStart else { continue }

                for secondStart in minimumSecondStart...maximumSecondStart {
                    guard phraseMatches(tokens, firstStart: firstStart, secondStart: secondStart, length: phraseLength) else {
                        continue
                    }
                    let phrase = Array(tokens[firstStart..<firstEnd])
                    guard phraseHasDistinctiveToken(phrase) else { continue }

                    let abandoned = Array(tokens[firstEnd..<secondStart])
                    guard abandonedWordsLookLikeRestart(abandoned) else { continue }

                    return tokens[firstStart].range.lowerBound..<tokens[secondStart].range.lowerBound
                }
            }
        }

        return nil
    }

    private static func wordTokens(in text: String) -> [WordToken] {
        var tokens: [WordToken] = []
        var start: String.Index?
        var index = text.startIndex

        while index < text.endIndex {
            if isWordCharacter(text[index]) {
                if start == nil {
                    start = index
                }
            } else if let tokenStart = start {
                appendWordToken(text[tokenStart..<index], range: tokenStart..<index, to: &tokens)
                start = nil
            }
            index = text.index(after: index)
        }

        if let tokenStart = start {
            appendWordToken(text[tokenStart..<text.endIndex], range: tokenStart..<text.endIndex, to: &tokens)
        }

        return tokens
    }

    private static func appendWordToken(
        _ substring: Substring,
        range: Range<String.Index>,
        to tokens: inout [WordToken]
    ) {
        let text = String(substring)
        tokens.append(WordToken(
            normalized: text.lowercased(),
            range: range
        ))
    }

    private static func phraseMatches(
        _ tokens: [WordToken],
        firstStart: Int,
        secondStart: Int,
        length: Int
    ) -> Bool {
        for offset in 0..<length {
            guard tokens[firstStart + offset].normalized == tokens[secondStart + offset].normalized else {
                return false
            }
        }
        return true
    }

    private static func phraseHasDistinctiveToken(_ tokens: [WordToken]) -> Bool {
        tokens.contains {
            $0.normalized.count > 3 && !repeatedRestartWeakWords.contains($0.normalized)
        }
    }

    private static func abandonedWordsLookLikeRestart(_ tokens: [WordToken]) -> Bool {
        guard !tokens.isEmpty,
              tokens.count <= repeatedRestartMaxAbandonedWords,
              let first = tokens.first?.normalized,
              !unsafeReplacementLeadingWords.contains(first)
        else {
            return false
        }

        return tokens.contains {
            $0.normalized.count > 2 && !repeatedRestartWeakWords.contains($0.normalized)
        }
    }

    private static func normalizeSpacingAfterRemoval(_ text: String) -> String {
        collapseHorizontalWhitespace(text)
            .replacingOccurrences(of: "[^\\S\\n]+([.,;:!?])", with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Collapses runs of horizontal whitespace to a single space while keeping
    /// newlines intact, so the pause segmenter's paragraph breaks survive
    /// filler/false-start cleanup. Spaces hugging a newline are trimmed; the
    /// newline (single or blank-line) itself is preserved.
    private static func collapseHorizontalWhitespace(_ text: String) -> String {
        text
            .replacingOccurrences(of: "[^\\S\\n]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " *\\n *", with: "\n", options: .regularExpression)
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "'" || character == "-"
    }

    private static func isHorizontalWhitespace(_ character: Character) -> Bool {
        character == " " || character == "\t"
    }
}
