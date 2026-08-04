import AppKit
import Foundation

/// Extracts word-level corrections by diffing pasted text against user-edited text.
/// Only returns corrections that pass validation (normalization, edit distance, phonetic plausibility).
/// `@MainActor` because `isKnownWord` uses `NSSpellChecker.shared`.
@MainActor
struct CorrectionDiffEngine {

    struct Candidate {
        let spoken: String
        let written: String
        let spokenIsRealWord: Bool
        /// Fast-path signal: the written form looks like a proper noun the user
        /// deliberately introduced (capitalized single token, not a common word,
        /// not merely a case variant of the spoken form).
        let writtenIsProperNoun: Bool
        /// The pair only lowercases the spoken form ("Vibe" → "vibe") — a style
        /// preference that must never be applied at sentence starts.
        let isCaseDowncase: Bool
    }

    /// How a validated pair should be handled: learned silently, or offered to
    /// the user because it is plausible but too uncertain to auto-apply.
    enum Classification {
        case learn(Candidate)
        case suggest(Candidate)
    }

    struct ExtractionResult {
        let corrections: [Candidate]
        let suggestions: [Candidate]

        static let empty = ExtractionResult(corrections: [], suggestions: [])
    }

    // MARK: - Configuration

    /// Below this similarity ratio, the readback is too different — user navigated away or rewrote entirely.
    static let minimumSimilarityRatio = 0.5

    /// Max Levenshtein distance between a word pair to consider it a correction vs a content rewrite.
    static let maximumWordEditDistance = 3
    /// Proper-noun pairs beyond the strict cap but within this bound become
    /// user-confirmed suggestions rather than silent auto-learns.
    static let maximumSuggestionEditDistance = 6
    /// Longest run of spoken tokens considered as one merged word ("tie s" → "Thijs").
    static let maximumMergedTokens = 3
    static let maximumFuzzyComparisonWork = 2_500

    // MARK: - Public API

    static func extractCorrections(original: String, edited: String) -> [Candidate] {
        extractWithSuggestions(original: original, edited: edited).corrections
    }

    static func extractWithSuggestions(original: String, edited: String) -> ExtractionResult {
        let originalTokens = tokenize(original)
        let editedTokens = tokenize(edited)

        guard !originalTokens.isEmpty, !editedTokens.isEmpty else { return .empty }

        let similarity = fuzzyOverlapRatio(originalTokens, editedTokens)
        guard similarity >= minimumSimilarityRatio else { return .empty }

        var corrections: [Candidate] = []
        var suggestions: [Candidate] = []
        for gap in alignmentGaps(from: originalTokens, to: editedTokens) {
            if gap.originalWords.count == gap.editedWords.count {
                for (offset, pair) in zip(gap.originalWords, gap.editedWords).enumerated() {
                    let classification = classify(
                        spoken: pair.0,
                        written: pair.1,
                        isSentenceInitial: isSentenceInitial(
                            tokenIndex: gap.originalStartIndex + offset,
                            in: originalTokens
                        )
                    )
                    switch classification {
                    case .learn(let candidate): corrections.append(candidate)
                    case .suggest(let candidate): suggestions.append(candidate)
                    case nil: break
                    }
                }
            } else if gap.editedWords.count == 1,
                      (2...maximumMergedTokens).contains(gap.originalWords.count) {
                switch classifyMerge(spokenWords: gap.originalWords, written: gap.editedWords[0]) {
                case .learn(let candidate): corrections.append(candidate)
                case .suggest(let candidate): suggestions.append(candidate)
                case nil: break
                }
            }
        }
        return ExtractionResult(corrections: corrections, suggestions: suggestions)
    }

    // MARK: - Tokenization

    static func tokenize(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    // MARK: - Similarity

    /// Ratio of words that are either identical or close (edit distance ≤ threshold)
    /// between the two token arrays. More forgiving than Jaccard for transcription
    /// corrections where misspelled words are similar to the intended word.
    static func fuzzyOverlapRatio(_ a: [String], _ b: [String]) -> Double {
        let normA = a.map { normalize($0).lowercased() }
        let normB = b.map { normalize($0).lowercased() }
        let maxLen = max(normA.count, normB.count)
        guard maxLen > 0 else { return 1.0 }
        guard normA.count * normB.count <= maximumFuzzyComparisonWork else {
            let exactMatches = Set(normA).intersection(Set(normB)).count
            return Double(exactMatches) / Double(maxLen)
        }

        // Count words in A that have a close match in B
        var usedB = Set<Int>()
        var matchCount = 0
        for wordA in normA {
            for (j, wordB) in normB.enumerated() where !usedB.contains(j) {
                if wordA == wordB || levenshtein(wordA, wordB) <= maximumWordEditDistance {
                    matchCount += 1
                    usedB.insert(j)
                    break
                }
            }
        }
        return Double(matchCount) / Double(maxLen)
    }

    // MARK: - Substitution extraction via LCS alignment

    /// A run of unmatched words between two LCS anchors.
    struct AlignmentGap {
        let originalWords: [String]
        let editedWords: [String]
        let originalStartIndex: Int
    }

    /// Returns pairs of (original, edited) words that represent 1-to-1 substitutions.
    static func substitutions(from original: [String], to edited: [String]) -> [(String, String)] {
        alignmentGaps(from: original, to: edited).flatMap { gap -> [(String, String)] in
            guard gap.originalWords.count == gap.editedWords.count else { return [] }
            return Array(zip(gap.originalWords, gap.editedWords))
        }
    }

    /// Walks both sequences matching LCS anchors and collects the unmatched
    /// gaps between them, with the gap's starting index in the original tokens.
    static func alignmentGaps(from original: [String], to edited: [String]) -> [AlignmentGap] {
        let normOrig = original.map { normalize($0) }
        let normEdit = edited.map { normalize($0) }

        let lcs = longestCommonSubsequence(normOrig, normEdit)

        var origIdx = 0
        var editIdx = 0
        var lcsIdx = 0
        var gaps: [AlignmentGap] = []

        while lcsIdx <= lcs.count {
            let anchor = lcsIdx < lcs.count ? lcs[lcsIdx] : nil

            // Collect unmatched words until next anchor
            let gapStart = origIdx
            var origGap: [String] = []
            var editGap: [String] = []

            while origIdx < original.count {
                if let a = anchor, normOrig[origIdx] == a { break }
                origGap.append(original[origIdx])
                origIdx += 1
            }
            while editIdx < edited.count {
                if let a = anchor, normEdit[editIdx] == a { break }
                editGap.append(edited[editIdx])
                editIdx += 1
            }

            if !origGap.isEmpty || !editGap.isEmpty {
                gaps.append(AlignmentGap(
                    originalWords: origGap,
                    editedWords: editGap,
                    originalStartIndex: gapStart
                ))
            }

            // Skip the anchor itself
            if anchor != nil {
                origIdx += 1
                editIdx += 1
            }
            lcsIdx += 1
        }

        return gaps
    }

    /// A token starts a sentence when it is the first token or the previous
    /// token ends with terminal punctuation. Tokenization collapses newlines,
    /// so paragraph starts without punctuation are not detected — acceptable
    /// for gating downcase learning, which has its own count threshold.
    static func isSentenceInitial(tokenIndex: Int, in tokens: [String]) -> Bool {
        guard tokenIndex > 0, tokenIndex <= tokens.count else { return true }
        guard let previousLast = tokens[tokenIndex - 1].last else { return true }
        return ".!?…:".contains(previousLast)
    }

    /// Standard LCS on normalized token arrays. Returns the subsequence elements.
    static func longestCommonSubsequence(_ a: [String], _ b: [String]) -> [String] {
        let m = a.count, n = b.count
        guard m > 0, n > 0 else { return [] }

        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 1...m {
            for j in 1...n {
                dp[i][j] = a[i - 1] == b[j - 1]
                    ? dp[i - 1][j - 1] + 1
                    : max(dp[i - 1][j], dp[i][j - 1])
            }
        }

        var result: [String] = []
        var i = m, j = n
        while i > 0, j > 0 {
            if a[i - 1] == b[j - 1] {
                result.append(a[i - 1])
                i -= 1; j -= 1
            } else if dp[i - 1][j] > dp[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }
        return result.reversed()
    }

    // MARK: - Validation

    static func validate(spoken: String, written: String) -> Candidate? {
        guard case .learn(let candidate) = classify(
            spoken: spoken,
            written: written,
            isSentenceInitial: false
        ) else { return nil }
        return candidate
    }

    static func classify(
        spoken: String,
        written: String,
        isSentenceInitial: Bool
    ) -> Classification? {
        let normSpoken = normalize(spoken)
        let normWritten = normalize(written)

        // Identical after stripping punctuation/whitespace — noise
        if normSpoken == normWritten { return nil }

        // Case-only change: learn proper-noun upgrades, and downcase
        // preferences ("Vibe" → "vibe") when not explained by grammar.
        if normSpoken.lowercased() == normWritten.lowercased() {
            let upgradesToProperNoun = written.first?.isUppercase == true
                && spoken.first?.isUppercase == false
            if !upgradesToProperNoun {
                guard normWritten == normWritten.lowercased(), !isSentenceInitial else {
                    return nil
                }
                return .learn(Candidate(
                    spoken: spoken,
                    written: written,
                    spokenIsRealWord: isKnownWord(normSpoken),
                    writtenIsProperNoun: false,
                    isCaseDowncase: true
                ))
            }
        }

        // Filter out pure number/symbol differences
        let lettersOnly = { (s: String) in s.filter(\.isLetter) }
        if lettersOnly(normSpoken) == lettersOnly(normWritten) { return nil }

        let dist = levenshtein(normSpoken.lowercased(), normWritten.lowercased())
        let candidate = Candidate(
            spoken: spoken,
            written: written,
            spokenIsRealWord: isKnownWord(normSpoken),
            writtenIsProperNoun: isProperNoun(spoken: normSpoken, written: normWritten),
            isCaseDowncase: false
        )

        if dist <= maximumWordEditDistance {
            return .learn(candidate)
        }

        // Names often mishear far beyond the strict cap while staying
        // phonetically close ("savior" → "Xavier"). Too uncertain to apply
        // silently — surface as a user-confirmed suggestion instead.
        if candidate.writtenIsProperNoun,
           dist <= maximumSuggestionEditDistance,
           phoneticallySimilar(normSpoken, normWritten) {
            return .suggest(candidate)
        }

        return nil
    }

    /// A multi-word gap replaced by a single word ("tie s" → "Thijs"), compared
    /// on concatenated letters. Exact concatenations auto-learn; phonetically
    /// close proper nouns become suggestions.
    static func classifyMerge(spokenWords: [String], written: String) -> Classification? {
        let normalizedWords = spokenWords.map { normalize($0) }.filter { !$0.isEmpty }
        guard normalizedWords.count > 1 else { return nil }
        let spokenPhrase = normalizedWords.joined(separator: " ")
        let concatenated = normalizedWords.joined().lowercased()
        let normWritten = normalize(written)
        guard !concatenated.isEmpty, !normWritten.isEmpty else { return nil }
        guard !normWritten.contains(where: \.isWhitespace) else { return nil }

        let candidate = Candidate(
            spoken: spokenPhrase,
            written: normWritten,
            spokenIsRealWord: false,
            writtenIsProperNoun: isProperNoun(spoken: concatenated, written: normWritten),
            isCaseDowncase: false
        )

        let dist = levenshtein(concatenated, normWritten.lowercased())
        if dist == 0 {
            // The user only removed the split ("web site" → "website").
            return .learn(candidate)
        }
        if candidate.writtenIsProperNoun,
           dist <= maximumSuggestionEditDistance,
           phoneticallySimilar(concatenated, normWritten) {
            return .suggest(candidate)
        }
        return nil
    }

    // MARK: - Phonetic plausibility

    nonisolated static func phoneticallySimilar(_ a: String, _ b: String) -> Bool {
        let skeletonA = phoneticSkeleton(a)
        let skeletonB = phoneticSkeleton(b)
        guard !skeletonA.isEmpty, !skeletonB.isEmpty else { return false }
        return levenshtein(skeletonA, skeletonB) <= 1
    }

    /// Rough sound-alike skeleton: collapses common spelling variants and strips
    /// vowels so "thijs"/"tice" or "xavier"/"savior" compare as near-equal.
    /// Deliberately cruder than metaphone — only used to gate suggestions that
    /// a human confirms, never silent learning.
    nonisolated static func phoneticSkeleton(_ word: String) -> String {
        var text = word.lowercased().filter(\.isLetter)
        guard !text.isEmpty else { return "" }

        let leadingClusters: [(String, String)] = [
            ("kn", "n"), ("wr", "r"), ("ps", "s"), ("x", "s"),
        ]
        for (cluster, replacement) in leadingClusters where text.hasPrefix(cluster) {
            text = replacement + text.dropFirst(cluster.count)
            break
        }

        let clusters: [(String, String)] = [
            ("sch", "s"), ("tch", "c"), ("th", "t"), ("ph", "f"), ("gh", "g"),
            ("ch", "k"), ("ck", "k"), ("sh", "s"), ("wh", "w"), ("qu", "kw"),
            ("dg", "j"), ("ij", "i"),
        ]
        for (cluster, replacement) in clusters {
            text = text.replacingOccurrences(of: cluster, with: replacement)
        }

        // Vowels and glides carry little signal for mishearings; voiced/voiceless
        // consonant pairs merge so devoiced spellings still align.
        let dropped: Set<Character> = ["a", "e", "i", "o", "u", "y", "h", "w"]
        let chars = Array(text)
        var skeleton: [Character] = []
        for (index, ch) in chars.enumerated() {
            if dropped.contains(ch) {
                if index == 0 { skeleton.append(ch) }
                continue
            }
            let mapped: Character
            switch ch {
            case "c":
                let next = index + 1 < chars.count ? chars[index + 1] : nil
                mapped = (next == "e" || next == "i" || next == "y") ? "s" : "k"
            case "z": mapped = "s"
            case "q", "x", "g": mapped = "k"
            case "v": mapped = "f"
            case "d": mapped = "t"
            case "b": mapped = "p"
            default: mapped = ch
            }
            if skeleton.last != mapped {
                skeleton.append(mapped)
            }
        }
        return String(skeleton)
    }

    /// A written form qualifies as a proper noun when it is a single capitalized
    /// token, is not merely a case variant of the spoken form, and its lowercased
    /// form is not a common dictionary word. Used to fast-path learning of names.
    static func isProperNoun(spoken: String, written: String) -> Bool {
        guard written.first?.isUppercase == true else { return false }
        // Single token only — no embedded whitespace.
        guard !written.contains(where: { $0.isWhitespace }) else { return false }
        // Not just a re-capitalization of the same word (e.g. "the" → "The").
        guard spoken.lowercased() != written.lowercased() else { return false }
        // A recognized common word (lowercased) is not a proper noun.
        guard !isKnownWord(written.lowercased()) else { return false }
        return true
    }

    // MARK: - Normalization

    static func normalize(_ word: String) -> String {
        word.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
    }

    // MARK: - Levenshtein

    nonisolated static func levenshtein(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        let m = aChars.count, n = bChars.count
        if m == 0 { return n }
        if n == 0 { return m }

        var prev = Array(0...n)
        var curr = Array(repeating: 0, count: n + 1)

        for i in 1...m {
            curr[0] = i
            for j in 1...n {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[n]
    }

    // MARK: - Dictionary check

    /// Returns true if the system spellchecker considers this a known word.
    static func isKnownWord(_ word: String) -> Bool {
        let checker = NSSpellChecker.shared
        let range = checker.checkSpelling(of: word, startingAt: 0)
        return range.location == NSNotFound
    }
}
