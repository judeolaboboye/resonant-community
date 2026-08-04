import AppKit
import Foundation
import NaturalLanguage

/// Repairs suspicious ASR output where a single word was split into multiple
/// spaced fragments, e.g. `t rans format i on` -> `transformation`.
///
/// This intentionally stays narrow. It only considers runs with multiple short
/// fragments and only joins them when the concatenated result looks like a
/// single correctly spelled word.
enum FragmentedWordRepair {

    private static let minJoinedLength = 8
    private static let maxWindowWordCount = 8
    private static let minTwoFragmentJoinedLength = 6
    /// A chunk-seam split leaves the two halves nearly adjacent in the token
    /// timeline; a genuine pause between separate words is much longer.
    private static let maxIntraWordGapSeconds = 0.3
    private static let twoFragmentTrailingPunctuation: Set<Character> = [".", ",", "!", "?", ";", ":", "…"]
    private static let commonSuffixFragments: Set<String> = [
        "able", "ed", "er", "ers", "ible", "ing", "ion", "ions",
        "ism", "ist", "ity", "ive", "ly", "ment", "ness", "sion", "tion"
    ]
    private static let standaloneLeadingWords: Set<String> = [
        "a", "an", "and", "but", "for", "in", "of", "on", "or", "the", "to", "with"
    ]
    private static let contractionSuffixFragments: Set<String> = [
        "d", "ll", "m", "re", "s", "t", "ve"
    ]
    private static let knownWholeWords: Set<String> = [
        "diarisation",
        "diarization",
        "reprompt",
        "reprompted",
        "reprompting",
        "reprompts"
    ]
    private static let trailingShortFunctionWords: Set<String> = [
        "am", "as", "at", "be", "by", "do", "go", "he", "if", "in",
        "is", "it", "me", "my", "of", "on", "or", "so", "to", "up",
        "us", "we"
    ]
    private static let collapsedPhraseSubjectPronouns: Set<String> = [
        "he", "i", "it", "she", "they", "we", "you"
    ]
    private static let knownCompoundSplits: [(pattern: String, replacement: String)] = [
        (#"\bevery\s+thing\b"#, "everything"),
        (#"\bunder\s+neath\b"#, "underneath")
    ]
    private static let punctuationSplitPattern = try! NSRegularExpression(
        pattern: #"\b([A-Za-z]{2,})\.([A-Za-z]{2,})\b"#
    )
    private static let debugLock = NSLock()
    private static var didLogDebugSample = false

    static func repair(
        _ text: String,
        timings: [TranscriptTokenTiming] = [],
        language: String? = nil,
        removeFalseStarts: Bool = false
    ) -> String {
        var result = text
        result = repairKnownCompoundSplits(in: result)

        // Resolve the dictation locale ONCE and thread it through every word-ness
        // check below. The merge/split decision hinges on "is this a word?", and
        // an unscoped NSSpellChecker auto-identifies across all installed
        // dictionaries — accepting cross-language junk like "gotoforatest" and
        // "ndu". Scoping to the resolved locale(s) is what makes the signal sound.
        var locales = resolvedLocales(for: language, text: result)
        if locales.isEmpty { locales = ["en"] }

        result = repairPunctuationSplits(in: result)

        // Multilingual over-segmentation re-merge runs on already-merged text so
        // the English heuristics below see whole words. Timings veto; no timings
        // makes this a safe no-op.
        result = repairOverSegmentation(result, timings: timings, language: language)

        // Only the multi-fragment candidateReplacements path is locale-scoped: both
        // production bugs lived there, and the two-fragment / German over-segmentation
        // paths have their own guards (scoping the two-fragment path would let German
        // compound slivers like "Mög lich" -> "Möglich" merge without timing support).
        let replacements = candidateReplacements(in: result, locales: locales)
        for replacement in replacements.reversed() {
            result.replaceSubrange(replacement.range, with: replacement.text)
        }

        result = repairTwoFragmentSplits(in: result, timings: timings)

        // Clipped false-start fragments ("send it to s Sarah" -> "send it to
        // Sarah") are a disfluency, not an ASR split, so this runs only when the
        // user opted into false-start removal. It runs last and aligns timings
        // against the (now whole-word) text; any earlier merge that misaligned
        // the timeline makes it a no-op.
        if removeFalseStarts {
            result = repairClippedPrefixRestart(in: result, timings: timings, language: language)
        }

        return result
    }

    static func shouldLogDebugSample(for text: String) -> Bool {
        guard containsSuspiciousFragmentation(in: text) else { return false }
        return debugLock.withLock {
            guard !didLogDebugSample else { return false }
            didLogDebugSample = true
            return true
        }
    }

    static func containsSuspiciousFragmentation(in text: String) -> Bool {
        let segments = segments(in: text)
        guard !segments.isEmpty else { return false }

        var locales = resolvedLocales(for: nil, text: text)
        if locales.isEmpty { locales = ["en"] }

        var segmentIndex = 0
        while segmentIndex < segments.count {
            guard canStartCandidate(at: segmentIndex, in: segments) else {
                segmentIndex += 1
                continue
            }

            let availableWordCount = contiguousWordCount(from: segmentIndex, in: segments)
            let maxWordCount = min(availableWordCount, maxWindowWordCount)
            if maxWordCount >= 3 {
                for wordCount in stride(from: maxWordCount, through: 3, by: -1) {
                    guard let window = candidateWindow(
                        startingAt: segmentIndex,
                        wordCount: wordCount,
                        in: segments
                    ) else { continue }
                    if isSuspicious(window.words, locales: locales) {
                        return true
                    }
                }
            }

            segmentIndex += 1
        }

        return false
    }

    // MARK: - Multilingual over-segmentation re-merge

    /// Re-merges words the multilingual Parakeet v3 model over-segments, where
    /// each subword arrives as a separate word-initial SentencePiece token
    /// (e.g. German "Mög lich kei ten" -> "Möglichkeiten"). Self-contained and
    /// deliberately conservative: it merges only a contiguous run of tokens with
    /// no acoustic pause where at least one fragment is not a standalone word and
    /// the joined form spell-checks in the resolved locale. Timing is a veto
    /// only; absent timings make this a no-op.
    static func repairOverSegmentation(
        _ text: String, timings: [TranscriptTokenTiming], language: String?
    ) -> String {
        guard !timings.isEmpty else { return text }
        let locales = resolvedLocales(for: language, text: text)
        guard !locales.isEmpty else { return text }

        let words = whitespaceWords(in: text)
        guard words.count >= 2,
              let gaps = interWordGaps(words: words.map(\.text), timings: timings)
        else { return text }

        var memo: [String: Bool] = [:]
        var replacements: [(range: Range<String.Index>, text: String)] = []

        var i = 0
        while i < words.count {
            var j = i
            while j + 1 < words.count, gaps[j] <= maxIntraWordGapSeconds { j += 1 }
            // A real word coarticulated ahead of an over-segmented noun
            // ("mehr Möglichkeiten" spoken with no pause) lands in the same
            // sub-0.3s run. Peel such words off the front so the noun still
            // repairs ("mehr Möglichkeiten", not the fused "mehrmöglichkeiten"
            // nor the unrepaired "mehr Mög lich kei ten"). The peel is deliberately
            // narrow: a fragment is peeled only when it is a LOWERCASE valid
            // standalone word AND the next fragment is CAPITALIZED. That
            // lowercase-word -> Capitalized-fragment transition marks a function
            // word / adverb / adjective ("mehr", "viel") butting against the start
            // of a (capitalized German) noun; it never occurs INSIDE a single
            // over-segmented word, whose pieces all share the original word's
            // casing — so an English run like "trans form ation" (all lowercase)
            // is never peeled and still merges whole. The loop stops before the
            // final fragment so at least one piece always remains to anchor the
            // tail.
            var start = i
            while start < j,
                  words[start].text.first?.isUppercase == false,
                  words[start + 1].text.first?.isUppercase == true,
                  isWordStrict(
                      words[start].text, locales: locales,
                      allowCapitalizeVariant: false, memo: &memo
                  ) {
                start += 1
            }
            if j > start, let merged = mergedWordIfValid(
                words[start...j].map(\.text), locales: locales, memo: &memo
            ) {
                replacements.append((words[start].range.lowerBound..<words[j].range.upperBound, merged))
            }
            i = j + 1
        }

        guard !replacements.isEmpty else { return text }
        var result = text
        for r in replacements.reversed() { result.replaceSubrange(r.range, with: r.text) }
        return result
    }

    private static func mergedWordIfValid(
        _ fragments: [String], locales: [String], memo: inout [String: Bool]
    ) -> String? {
        guard fragments.count >= 2 else { return nil }
        // The final fragment may carry trailing sentence punctuation
        // (e.g. "ten." closing "Möglichkeiten."). Split it off, merge on the
        // bare letter cores, and re-append it to the result.
        var cores = fragments
        var trailingPunctuation = ""
        if let last = cores.last, let split = letterCoreAndTrailing(of: last) {
            cores[cores.count - 1] = split.core
            trailingPunctuation = split.trailing
        }
        guard cores.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isLetter) }) else { return nil }
        let casedFragments = [cores[0]] + cores.dropFirst().map(lowercasingFirstLetter)
        let joined = casedFragments.joined().precomposedStringWithCanonicalMapping
        guard isCasingCompatible(joined) else { return nil }
        // Non-word guard: at least one fragment must not be a standalone word.
        // Each fragment is tested in the casing it actually arrived in — the
        // head as-is, interior pieces lowercased — so a lowercased interior
        // sliver like "hof" is not excused by the capitalized noun "Hof".
        guard casedFragments.contains(where: {
            !isWordStrict($0, locales: locales, allowCapitalizeVariant: false, memo: &memo)
        }) else { return nil }
        // Joined-word gate. The capitalize-variant is allowed ONLY when the head
        // fragment is already capitalized. Over-segmented German nouns start with
        // a capital ("Mög lich kei ten", "Haupt Bahn hof"), so their join is
        // already correctly capitalized and validates without promotion. A real
        // lowercase word coarticulated ahead of the noun ("mehr Möglichkeiten"
        // with no pause) would otherwise be fused: the lowercase join
        // "mehrmöglichkeiten" only spell-checks once the capitalize-variant
        // promotes it to the valid compound "Mehrmöglichkeiten". Gating the
        // promotion on head casing blocks that fusion while keeping recall on
        // genuine lowercase over-segmented words, whose lowercase join already
        // validates on its own. (The leading-word peel upstream is the primary
        // defence; this is the in-place backstop when peeling can't apply.)
        let headIsCapitalized = casedFragments[0].first?.isUppercase == true
        guard isWordStrict(
            joined, locales: locales, allowCapitalizeVariant: headIsCapitalized, memo: &memo
        ) else { return nil }
        return joined + trailingPunctuation
    }

    /// Splits a fragment into its leading letter core and any trailing sentence
    /// punctuation. Returns nil when anything other than letters-then-trailing-
    /// punctuation appears (apostrophes, digits, interior symbols).
    private static func letterCoreAndTrailing(of fragment: String) -> (core: String, trailing: String)? {
        guard let firstNonLetter = fragment.firstIndex(where: { !$0.isLetter }) else {
            return (fragment, "")
        }
        let trailing = fragment[firstNonLetter...]
        guard trailing.allSatisfy({ twoFragmentTrailingPunctuation.contains($0) }) else {
            return nil
        }
        return (String(fragment[fragment.startIndex..<firstNonLetter]), String(trailing))
    }

    /// Locale-scoped word-ness for callers outside the repair pipeline (the
    /// vocabulary-boost veto). Same resolved-locale + strict-variant machinery
    /// as the repair paths, so "is a word" means the same thing everywhere.
    static func isRealWord(_ word: String, language: String?) -> Bool {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var locales = resolvedLocales(for: language, text: trimmed)
        if locales.isEmpty { locales = ["en"] }
        var memo: [String: Bool] = [:]
        return isWordStrict(
            trimmed, locales: locales, allowCapitalizeVariant: true, memo: &memo
        )
    }

    private static func isWordStrict(
        _ word: String,
        locales: [String],
        allowCapitalizeVariant: Bool,
        memo: inout [String: Bool]
    ) -> Bool {
        // Whether the capitalize-variant is allowed changes the answer, so it
        // is part of the memo key. The key keeps the word's EXACT casing: with
        // allowCapitalizeVariant == false the variant set is the bare NFC form,
        // so "Ar" (a valid unit) and "ar" must not share a cache slot.
        let key = (allowCapitalizeVariant ? "C:" : "_:")
            + word.precomposedStringWithCanonicalMapping
        if let hit = memo[key] { return hit }
        let variants = strictSpellVariants(word, allowCapitalizeVariant: allowCapitalizeVariant)
        let ok = SpellCheckSerialization.lock.withLock {
            locales.contains { lang in variants.contains { v in
                NSSpellChecker.shared.checkSpelling(
                    of: v, startingAt: 0, language: lang, wrap: false,
                    inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
            } }
        }
        memo[key] = ok
        return ok
    }

    private static func lowercasingFirstLetter(_ s: String) -> String {
        guard let f = s.first else { return s }
        return String(f).lowercased() + s.dropFirst()
    }

    private static func strictSpellVariants(
        _ word: String, allowCapitalizeVariant: Bool
    ) -> [String] {
        let nfc = word.precomposedStringWithCanonicalMapping
        // The per-fragment non-word guard (allowCapitalizeVariant == false) tests
        // the fragment in exactly the casing it arrived in — head as-is, interior
        // pieces already lowercased — so it gets only the NFC form. The joined and
        // head checks (allowCapitalizeVariant == true) additionally probe the
        // lowercased and capitalized forms so a lowercased German noun matches its
        // canonical capitalized dictionary entry.
        guard allowCapitalizeVariant else { return [nfc] }
        var v = [nfc, nfc.lowercased()]
        // The capitalize-variant is skipped when capitalizing the first letter
        // expands to more than one scalar (the German eszett uppercases to "SS").
        if let f = nfc.first, String(f).uppercased().unicodeScalars.count == 1 {
            v.append(String(f).uppercased() + nfc.dropFirst())
        }
        return Array(Set(v))
    }

    private static func resolvedLocales(for language: String?, text: String) -> [String] {
        // Read under the same lock as every other NSSpellChecker.shared access
        // in this file: concurrent pipeline runs may be inside checkSpelling(...)
        // on the shared singleton, and this keeps to the file's serialization
        // convention even though availableLanguages is a read-only catalog query.
        let available = SpellCheckSerialization.lock.withLock {
            Set(NSSpellChecker.shared.availableLanguages.map { String($0.prefix(2)) })
        }
        if let language, !language.isEmpty, language.lowercased() != "auto" {
            let code = String(language.lowercased().prefix(2))
            return available.contains(code) ? [code] : []
        }
        let r = NLLanguageRecognizer()
        r.processString(text)
        if let lang = r.dominantLanguage {
            let code = String(lang.rawValue.prefix(2))
            if (r.languageHypotheses(withMaximum: 1)[lang] ?? 0) >= 0.5, available.contains(code) {
                return [code]
            }
        }
        return ["en", "de"].filter { available.contains($0) }
    }

    // MARK: - Two-fragment splits

    /// Repairs a single word split into exactly two pieces, the dominant
    /// failure mode at chunk-merge seams (`trans cription` -> `transcription`).
    /// Joins only when at least one half is not a word on its own, the joined
    /// form spell-checks as one word, and — when token timings align — the two
    /// halves are nearly adjacent in the audio timeline.
    private static func repairTwoFragmentSplits(
        in text: String,
        timings: [TranscriptTokenTiming]
    ) -> String {
        let words = whitespaceWords(in: text)
        guard words.count >= 2 else { return text }

        let gaps = interWordGaps(words: words.map(\.text), timings: timings)

        var replacements: [(range: Range<String.Index>, text: String)] = []
        var index = 0
        while index < words.count - 1 {
            let first = words[index]
            let second = words[index + 1]

            guard text[first.range.upperBound..<second.range.lowerBound] == " ",
                  !isPrecededByApostrophe(first.range.lowerBound, in: text),
                  first.text.allSatisfy(\.isLetter),
                  let secondCore = letterCore(of: second.text),
                  shouldJoinTwoFragments(first.text, String(secondCore))
            else {
                index += 1
                continue
            }

            // A measurable pause between the halves means two intended words.
            if let gaps, gaps[index] > maxIntraWordGapSeconds {
                index += 1
                continue
            }

            let coreEnd = text.index(second.range.lowerBound, offsetBy: secondCore.count)
            replacements.append((
                range: first.range.lowerBound..<coreEnd,
                text: first.text + secondCore
            ))
            index += 2
        }

        guard !replacements.isEmpty else { return text }

        var result = text
        for replacement in replacements.reversed() {
            result.replaceSubrange(replacement.range, with: replacement.text)
        }
        return result
    }

    private static func shouldJoinTwoFragments(_ first: String, _ second: String) -> Bool {
        guard first.count >= 2, second.count >= 2 else { return false }

        let joined = first + second
        guard joined.count >= minTwoFragmentJoinedLength else { return false }
        guard isCasingCompatible(first), second.allSatisfy({ !$0.isUppercase }) else { return false }
        guard !(isValidWord(first) && isValidWord(second)) else { return false }

        return isLikelyWholeWord(joined)
    }

    // MARK: - Clipped-prefix false starts

    /// Drops a clipped false-start fragment the speaker abandons mid-word before
    /// restarting with the full word: "send it to s Sarah" -> "send it to
    /// Sarah", "we need the transc transcription" -> "we need the
    /// transcription". Fires only when fragment `F` directly precedes word `W`
    /// with `F` a strict character-prefix of `W`, `F` is NOT itself a real word
    /// (so "a apple", "in index", "to total" are untouched), `W` IS a real word,
    /// and — the safety lever — the two were emitted back-to-back with no
    /// acoustic pause. A single-letter fragment is the riskiest case (spelled
    /// initials like "B Boston"), so it additionally requires a 4+ letter word
    /// target. Timing is required: absent or misaligned timings make this a
    /// no-op, matching the rest of this file's contract.
    private static func repairClippedPrefixRestart(
        in text: String,
        timings: [TranscriptTokenTiming],
        language: String?
    ) -> String {
        guard !timings.isEmpty else { return text }
        let locales = resolvedLocales(for: language, text: text)
        guard !locales.isEmpty else { return text }

        let words = whitespaceWords(in: text)
        guard words.count >= 2,
              let gaps = interWordGaps(words: words.map(\.text), timings: timings)
        else { return text }

        var memo: [String: Bool] = [:]
        var replacements: [(range: Range<String.Index>, text: String)] = []
        var index = 0
        while index < words.count - 1 {
            let fragment = words[index]
            let word = words[index + 1]

            guard text[fragment.range.upperBound..<word.range.lowerBound] == " ",
                  !isPrecededByApostrophe(fragment.range.lowerBound, in: text),
                  fragment.text.allSatisfy(\.isLetter),
                  let wordCore = letterCore(of: word.text),
                  shouldDropClippedPrefix(
                      fragment: fragment.text,
                      word: String(wordCore),
                      gap: gaps[index],
                      locales: locales,
                      memo: &memo
                  )
            else {
                index += 1
                continue
            }

            // Drop the fragment and the single space that follows it.
            replacements.append((
                range: fragment.range.lowerBound..<word.range.lowerBound,
                text: ""
            ))
            index += 2
        }

        guard !replacements.isEmpty else { return text }
        var result = text
        for replacement in replacements.reversed() {
            result.replaceSubrange(replacement.range, with: replacement.text)
        }
        return result
    }

    /// Single letters that are real standalone words; never treated as a clipped
    /// fragment ("a apple", "I index", archaic "O Lord").
    private static let standaloneLetters: Set<String> = ["a", "i", "o"]

    private static func shouldDropClippedPrefix(
        fragment: String,
        word: String,
        gap: Double,
        locales: [String],
        memo: inout [String: Bool]
    ) -> Bool {
        // A measurable pause between the two means two intended words.
        guard gap <= maxIntraWordGapSeconds else { return false }

        let lowerFragment = fragment.lowercased()
        let lowerWord = word.lowercased()
        guard lowerFragment.count < lowerWord.count,
              lowerWord.count >= 4,
              lowerWord.hasPrefix(lowerFragment)
        else { return false }

        // Only delete in front of a confident dictionary word, so a fragment
        // before ASR garbage is left alone.
        guard isWordStrict(word, locales: locales, allowCapitalizeVariant: true, memo: &memo)
        else { return false }

        if lowerFragment.count == 1 {
            // NSSpellChecker accepts bare single letters, so the non-word gate is
            // useless here. Instead: exclude the real single-letter words, and
            // only drop a lowercase letter in front of a lowercase word — a
            // genuine clipped word-start ("the t total") is lowercase mid-clause,
            // whereas a deliberately spoken letter is uppercase or precedes a
            // capitalized proper noun ("vitamin D daily", "plan B", "S Sarah",
            // "B Boston"), which must be preserved.
            return !standaloneLetters.contains(lowerFragment)
                && fragment == lowerFragment
                && word.first?.isUppercase != true
        }

        // A multi-letter fragment must NOT be a real word, or "in index",
        // "to total" — valid speech — would be eaten.
        return !isWordStrict(fragment, locales: locales, allowCapitalizeVariant: true, memo: &memo)
    }

    /// Letters of a word that may carry trailing sentence punctuation.
    /// Returns nil for anything else mixed in (apostrophes, hyphens, digits).
    private static func letterCore(of word: String) -> Substring? {
        guard let firstNonLetter = word.firstIndex(where: { !$0.isLetter }) else {
            return word[...]
        }
        guard word[firstNonLetter...].allSatisfy({ twoFragmentTrailingPunctuation.contains($0) }) else {
            return nil
        }
        let core = word[word.startIndex..<firstNonLetter]
        return core.isEmpty ? nil : core
    }

    private static func isPrecededByApostrophe(_ index: String.Index, in text: String) -> Bool {
        guard index > text.startIndex else { return false }
        return isApostropheSeparator(String(text[text.index(before: index)]))
    }

    /// Spell-checks `word` against a RESOLVED locale set instead of letting macOS
    /// auto-identify across every installed dictionary. The unscoped
    /// `checkSpelling(of:startingAt:)` accepts cross-language junk — "gotoforatest",
    /// "ndu", "ies", "thengram" all validate against *some* installed dictionary —
    /// which both glued real words and hid genuine over-segmentation slivers.
    private static func spellsAsWord(_ word: String, locales: [String]) -> Bool {
        SpellCheckSerialization.lock.withLock {
            locales.contains { language in
                NSSpellChecker.shared.checkSpelling(
                    of: word, startingAt: 0, language: language, wrap: false,
                    inSpellDocumentWithTag: 0, wordCount: nil
                ).location == NSNotFound
            }
        }
    }

    private static func isValidWord(_ word: String, locales: [String]) -> Bool {
        spellsAsWord(word.lowercased(), locales: locales)
    }

    /// Unscoped (auto-identify) word check used ONLY by the two-fragment and
    /// punctuation paths, preserving their original behavior. The multi-fragment
    /// path uses the locale-scoped `isValidWord(_:locales:)` instead.
    private static func isValidWord(_ word: String) -> Bool {
        SpellCheckSerialization.lock.withLock {
            NSSpellChecker.shared.checkSpelling(
                of: word.lowercased(),
                startingAt: 0
            ).location == NSNotFound
        }
    }

    private static func whitespaceWords(in text: String) -> [(text: String, range: Range<String.Index>)] {
        var result: [(text: String, range: Range<String.Index>)] = []
        var index = text.startIndex

        while index < text.endIndex {
            if text[index].isWhitespace {
                index = text.index(after: index)
                continue
            }
            var end = index
            while end < text.endIndex, !text[end].isWhitespace {
                end = text.index(after: end)
            }
            result.append((text: String(text[index..<end]), range: index..<end))
            index = end
        }

        return result
    }

    /// Gap in seconds between consecutive words, aligned the same way as
    /// `PauseSegmenter`: strict accumulation of normalized token pieces.
    /// Returns nil when timings are absent or alignment fails — the timing
    /// gate then stays open and the spell-check gates decide alone.
    private static func interWordGaps(
        words: [String],
        timings: [TranscriptTokenTiming]
    ) -> [Double]? {
        guard !timings.isEmpty, words.count >= 2 else { return nil }

        var spans: [(start: Double, end: Double)] = []
        spans.reserveCapacity(words.count)
        var tokenIndex = 0

        for word in words {
            let target = normalizedForAlignment(word)
            guard !target.isEmpty else { return nil }

            var accumulated = ""
            var start: Double?
            var end = 0.0

            while tokenIndex < timings.count, accumulated.count < target.count {
                let timing = timings[tokenIndex]
                tokenIndex += 1
                let piece = normalizedForAlignment(timing.token)
                guard !piece.isEmpty else { continue }
                if start == nil { start = timing.startTime }
                accumulated += piece
                end = timing.endTime
            }

            guard accumulated == target, let wordStart = start else { return nil }
            spans.append((start: wordStart, end: end))
        }

        return zip(spans, spans.dropFirst()).map { max(0, $1.start - $0.end) }
    }

    private static func normalizedForAlignment(_ text: String) -> String {
        text.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    private static func candidateReplacements(in text: String, locales: [String]) -> [(range: Range<String.Index>, text: String)] {
        let segments = segments(in: text)
        guard !segments.isEmpty else { return [] }

        var replacements: [(range: Range<String.Index>, text: String)] = []
        var segmentIndex = 0

        while segmentIndex < segments.count {
            guard canStartCandidate(at: segmentIndex, in: segments) else {
                segmentIndex += 1
                continue
            }

            let availableWordCount = contiguousWordCount(from: segmentIndex, in: segments)
            let maxWordCount = min(availableWordCount, maxWindowWordCount)
            var matchedReplacement: (endSegmentIndex: Int, range: Range<String.Index>, text: String)?

            if maxWordCount >= 3 {
                for wordCount in stride(from: maxWordCount, through: 3, by: -1) {
                    guard let window = candidateWindow(
                        startingAt: segmentIndex,
                        wordCount: wordCount,
                        in: segments
                    ) else { continue }
                    guard isSuspicious(window.words, locales: locales) else { continue }
                    guard !looksLikeOrdinaryFunctionWordPhrase(window.words) else { continue }
                    guard !isOrdinarySpacedWordRun(window.words, locales: locales) else { continue }

                    let joined = window.words.joined()
                    guard isLikelyWholeWord(joined, locales: locales) else { continue }

                    matchedReplacement = (
                        endSegmentIndex: window.endSegmentIndex,
                        range: window.range,
                        text: joined
                    )
                    break
                }
            }

            if let matchedReplacement {
                replacements.append((range: matchedReplacement.range, text: matchedReplacement.text))
                segmentIndex = matchedReplacement.endSegmentIndex + 1
            } else {
                segmentIndex += 1
            }
        }

        return replacements
    }

    private static func isSuspicious(_ words: [String], locales: [String]) -> Bool {
        guard words.count >= 3 else { return false }
        guard let firstWord = words.first else { return false }

        let joinedLength = words.reduce(0) { $0 + $1.count }
        guard joinedLength >= minJoinedLength else { return false }

        if looksLikeOrdinaryBeArticlePhrase(words) {
            return false
        }

        let shortCount = words.filter { $0.count <= 2 }.count
        let singleLetterCount = words.filter { $0.count == 1 }.count
        let hasLongFragment = words.contains { $0.count >= 4 }
        let hasDenseSmallFragments = words.count >= 5 && singleLetterCount >= 3
        // The length proxies (a 4+ char anchor, or many single letters) are stand-ins
        // for "looks fragmented" and miss runs of several short pieces with no anchor
        // ("i ndu str ies" -> "industries"). A non-word sliver is the direct signal of
        // a real split, and is reliable only now that the spell-check is locale-scoped.
        guard hasLongFragment || hasDenseSmallFragments || hasNonWordSliver(words, locales: locales) else { return false }
        guard words.allSatisfy(isCasingCompatible) else { return false }

        if words.count > 3, standaloneLeadingWords.contains(firstWord.lowercased()) {
            return false
        }

        if hasJoinedSuffixFragment(words) {
            return true
        }

        guard firstWord.count <= 2 else { return false }

        if words.count >= 4, singleLetterCount > 0, shortCount >= 2 {
            return true
        }

        if firstWord.count == 1,
           !["a", "i"].contains(firstWord.lowercased()),
           words.count == 3,
           words[1].count <= 3,
           words[2].count >= 4 {
            return true
        }

        return singleLetterCount >= 1 && words.count >= 4
    }

    private static func looksLikeOrdinaryBeArticlePhrase(_ words: [String]) -> Bool {
        guard words.count >= 4 else { return false }
        let lowercased = words.map { $0.lowercased() }
        guard lowercased[0] == "be",
              ["a", "an", "the"].contains(lowercased[1])
        else {
            return false
        }

        return lowercased.dropFirst(2).contains { $0.count >= 4 }
    }

    private static func looksLikeOrdinaryFunctionWordPhrase(_ words: [String]) -> Bool {
        let lowercased = words.map { $0.lowercased() }
        guard lowercased.count >= 3,
              lowercased.first.map(collapsedPhraseSubjectPronouns.contains) == true
        else {
            return false
        }

        var trailingShortWordCount = 0
        for word in lowercased.reversed() {
            guard word.count <= 2 else { break }
            trailingShortWordCount += 1
        }

        guard trailingShortWordCount > 0,
              trailingShortWordCount <= 2
        else {
            return false
        }

        let tail = lowercased.suffix(trailingShortWordCount)
        guard tail.allSatisfy({ trailingShortFunctionWords.contains($0) }) else {
            return false
        }

        return lowercased.dropLast(trailingShortWordCount).contains { $0.count >= 4 }
    }

    /// Correctly-spaced speech where every token is already a real word
    /// ("go to for a test") must never be glued into one token. A genuine
    /// over-segmentation always leaves at least one fragment that is NOT a
    /// standalone word — a sub-word sliver ("rans", "ation") or a bare consonant
    /// letter ("t" in "t ran scripts") — so the absence of any such fragment is
    /// the signal that this is prose, not a split. The lone exception is a tail
    /// that spells a known inflectional suffix ("detect i on" -> "detection"),
    /// a strong morphological split signal that overrides the all-words check.
    ///
    /// This brings the multi-fragment English path in line with the non-word
    /// guards already enforced on the two-fragment (`shouldJoinTwoFragments`)
    /// and multilingual (`mergedWordIfValid`) merge paths.
    private static func isOrdinarySpacedWordRun(_ words: [String], locales: [String]) -> Bool {
        guard !hasJoinedSuffixFragment(words) else { return false }
        return words.allSatisfy { isStandaloneRealWord($0, locales: locales) }
    }

    /// True when at least one fragment is NOT a standalone real word — a sub-word
    /// sliver ("ndu", "ies", "rans") or a bare consonant. This is the positive
    /// signal of genuine over-segmentation, the inverse of `isOrdinarySpacedWordRun`.
    private static func hasNonWordSliver(_ words: [String], locales: [String]) -> Bool {
        words.contains { !isStandaloneRealWord($0, locales: locales) }
    }

    private static func isStandaloneRealWord(_ word: String, locales: [String]) -> Bool {
        let lowercased = word.lowercased()
        // NSSpellChecker accepts every single letter, so a bare "t"/"b" would be
        // spuriously "valid"; only the genuine one-letter words count here.
        if lowercased.count == 1 {
            return standaloneLetters.contains(lowercased)
        }
        return isValidWord(lowercased, locales: locales)
    }

    private static func hasJoinedSuffixFragment(_ words: [String]) -> Bool {
        guard words.count >= 3 else { return false }

        let lowercased = words.map { $0.lowercased() }
        let maxTailCount = min(4, lowercased.count - 1)

        for tailCount in 1...maxTailCount {
            let tailWords = lowercased.suffix(tailCount)
            guard tailWords.allSatisfy({ $0.count <= 3 }) else { continue }

            let tail = tailWords.joined()
            guard commonSuffixFragments.contains(tail) else { continue }

            if lowercased.dropLast(tailCount).contains(where: { $0.count >= 3 }) {
                return true
            }
        }

        return false
    }

    private static func isCasingCompatible(_ word: String) -> Bool {
        let uppercaseCount = word.reduce(into: 0) { count, character in
            if character.isUppercase {
                count += 1
            }
        }

        guard uppercaseCount > 0 else { return true }
        return uppercaseCount == 1
            && word.first?.isUppercase == true
            && word.dropFirst().allSatisfy { !$0.isUppercase }
    }

    private static func isLikelyWholeWord(_ word: String, locales: [String]) -> Bool {
        let normalized = word.lowercased()
        if knownWholeWords.contains(normalized) {
            return true
        }
        return spellsAsWord(normalized, locales: locales)
    }

    /// Unscoped (auto-identify) whole-word check used ONLY by the two-fragment and
    /// punctuation paths, preserving their original behavior.
    private static func isLikelyWholeWord(_ word: String) -> Bool {
        let normalized = word.lowercased()
        if knownWholeWords.contains(normalized) {
            return true
        }
        return SpellCheckSerialization.lock.withLock {
            NSSpellChecker.shared.checkSpelling(
                of: normalized,
                startingAt: 0
            ).location == NSNotFound
        }
    }

    private static func repairKnownCompoundSplits(in text: String) -> String {
        var result = text
        for split in knownCompoundSplits {
            result = result.replacingOccurrences(
                of: split.pattern,
                with: split.replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return result
    }

    private static func repairPunctuationSplits(in text: String) -> String {
        let matches = punctuationSplitPattern.matches(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        )
        guard !matches.isEmpty else { return text }

        var result = text
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: text),
                  let firstRange = Range(match.range(at: 1), in: text),
                  let secondRange = Range(match.range(at: 2), in: text)
            else { continue }

            let joined = String(text[firstRange]) + String(text[secondRange])
            guard isLikelyWholeWord(joined) else { continue }

            result.replaceSubrange(fullRange, with: joined)
        }
        return result
    }

    private static func contiguousWordCount(from startIndex: Int, in segments: [Segment]) -> Int {
        var count = 0
        var segmentIndex = startIndex

        while segmentIndex < segments.count, segments[segmentIndex].isWord {
            count += 1

            let separatorIndex = segmentIndex + 1
            let nextWordIndex = segmentIndex + 2
            guard nextWordIndex < segments.count else { break }
            guard !segments[separatorIndex].isWord, segments[separatorIndex].text == " " else { break }
            guard segments[nextWordIndex].isWord else { break }

            segmentIndex = nextWordIndex
        }

        return count
    }

    private static func canStartCandidate(at segmentIndex: Int, in segments: [Segment]) -> Bool {
        guard segments[segmentIndex].isWord else { return false }
        guard segmentIndex >= 2 else { return true }

        let previousSeparator = segments[segmentIndex - 1]
        let previousWord = segments[segmentIndex - 2]
        guard previousWord.isWord,
              !previousSeparator.isWord,
              isApostropheSeparator(previousSeparator.text)
        else {
            return true
        }

        return !contractionSuffixFragments.contains(segments[segmentIndex].text.lowercased())
    }

    private static func isApostropheSeparator(_ text: String) -> Bool {
        text == "'" || text == "\u{2019}"
    }

    private static func candidateWindow(
        startingAt startIndex: Int,
        wordCount: Int,
        in segments: [Segment]
    ) -> CandidateWindow? {
        guard wordCount > 0 else { return nil }

        var words: [String] = []
        words.reserveCapacity(wordCount)
        var segmentIndex = startIndex

        for wordOffset in 0..<wordCount {
            guard segmentIndex < segments.count, segments[segmentIndex].isWord else { return nil }
            words.append(segments[segmentIndex].text)

            if wordOffset == wordCount - 1 {
                let range = segments[startIndex].range.lowerBound..<segments[segmentIndex].range.upperBound
                return CandidateWindow(
                    words: words,
                    range: range,
                    endSegmentIndex: segmentIndex
                )
            }

            let separatorIndex = segmentIndex + 1
            let nextWordIndex = segmentIndex + 2
            guard nextWordIndex < segments.count else { return nil }
            guard !segments[separatorIndex].isWord, segments[separatorIndex].text == " " else { return nil }
            guard segments[nextWordIndex].isWord else { return nil }

            segmentIndex = nextWordIndex
        }

        return nil
    }

    private static func segments(in text: String) -> [Segment] {
        guard !text.isEmpty else { return [] }

        var result: [Segment] = []
        var segmentStart = text.startIndex
        var currentIsWord = text[segmentStart].isLetter
        var index = text.index(after: segmentStart)

        while index < text.endIndex {
            let isWord = text[index].isLetter
            if isWord != currentIsWord {
                result.append(
                    Segment(
                        text: String(text[segmentStart..<index]),
                        range: segmentStart..<index,
                        isWord: currentIsWord
                    )
                )
                segmentStart = index
                currentIsWord = isWord
            }
            index = text.index(after: index)
        }

        result.append(
            Segment(
                text: String(text[segmentStart..<text.endIndex]),
                range: segmentStart..<text.endIndex,
                isWord: currentIsWord
            )
        )

        return result
    }

    private struct Segment {
        let text: String
        let range: Range<String.Index>
        let isWord: Bool
    }

    private struct CandidateWindow {
        let words: [String]
        let range: Range<String.Index>
        let endSegmentIndex: Int
    }
}
