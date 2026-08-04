import Foundation

/// Inserts sentence and paragraph boundaries from decoder token timings —
/// the user's actual pauses — instead of relying on spoken commands.
///
/// When the transcript carries any model punctuation, the decoder's
/// punctuation head is live for the utterance and its boundaries win: gaps
/// then only add layout (paragraph whitespace, capitalization) at sentence
/// ends the model already marked. Gap-invented periods are a fallback
/// reserved for transcripts the head left completely bare — thinking pauses
/// and sentence-end pauses overlap too much in duration for a threshold to
/// separate them, so a pause may only add punctuation where the model
/// offered none at all.
///
/// Alignment is strict: every transcript word must match the token stream
/// exactly (case/punctuation-insensitive) or the text is returned untouched.
/// A wrong split is worse than no split.
enum PauseSegmenter {

    /// Gap between words that ends a sentence.
    static let sentenceGapSeconds = 0.6
    /// Gap between words that starts a new paragraph.
    static let paragraphGapSeconds = 1.6

    /// Words that a pause routinely precedes mid-sentence; breaking before
    /// them produces fragments ("we shipped. And it works").
    private static let continuationOpeners: Set<String> = [
        "and", "but", "or", "so", "because", "which", "that", "then",
        "with", "for", "to", "of", "in", "on", "at", "like", "as",
        "if", "when", "while", "though", "although", "unless",
    ]

    /// A pause right before a self-correction cue ("no wait", "actually no",
    /// "scratch that") is the speaker retracting what they just said, not a
    /// sentence boundary. Inserting a period there hides the correction from
    /// the filler/false-start repairs downstream, so breaks are suppressed
    /// when the next two words open one of these cues.
    private static let correctionCueOpeners: Set<[String]> = [
        ["no", "wait"], ["no", "actually"], ["wait", "no"], ["wait", "actually"],
        ["sorry", "no"], ["actually", "no"], ["actually", "wait"],
        ["scratch", "that"], ["scratch", "this"], ["strike", "that"],
        ["scrap", "that"], ["never", "mind"], ["cancel", "that"],
        ["forget", "that"], ["i", "mean"], ["i", "meant"], ["or", "rather"],
    ]

    /// A pause after one of these means the speaker is thinking, not done —
    /// the sentence is grammatically unfinished ("the budget is <pause> fine").
    private static let unfinishedTrailingWords: Set<String> = [
        "a", "an", "the", "this", "that", "these", "those", "my", "your",
        "his", "her", "its", "our", "their", "some", "any", "no", "every",
        "is", "are", "was", "were", "be", "been", "being", "am",
        "have", "has", "had", "do", "does", "did",
        "will", "would", "shall", "should", "can", "could", "may", "might", "must",
        "and", "but", "or", "nor", "so", "yet", "because", "since", "while",
        "to", "for", "in", "on", "at", "by", "with", "from", "of", "about",
        "into", "over", "under", "between", "through", "during", "before",
        "after", "without", "within", "very", "really", "quite", "not",
    ]

    /// Hesitation sounds, mirroring `FillerRemover`'s list. A pause next to
    /// one is the speaker mid-thought — evidence *against* a boundary — and
    /// FillerRemover later deletes the sound itself, which would strand any
    /// period mid-clause ("using it and uh. We can" → "using it and. We can").
    private static let hesitationFillers: Set<String> = [
        "um", "uh", "er", "ah", "hmm", "hm", "mhm",
    ]

    /// Marker inserted between words separated by a real speech pause in the
    /// annotated transcript sent to cloud cleanup. Chosen so the ASR
    /// vocabulary can never produce it and models read it as markup.
    static let pauseMarker = "<pause>"

    /// Gap between words worth surfacing to the cloud cleanup model. Lower
    /// than `sentenceGapSeconds`: the 0.35–0.6s band is exactly where
    /// hesitations and self-corrections live but no sentence break fires.
    static let annotationGapSeconds = 0.35

    /// Whether every transcript word can be reconstructed from the supplied
    /// token stream. Newly enabled decoder timings are discarded before any
    /// formatting stage when this strict alignment fails.
    static func timingsStrictlyAlign(
        _ text: String,
        timings: [TranscriptTokenTiming]
    ) -> Bool {
        guard !timings.isEmpty else { return false }
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        return !words.isEmpty && align(words: words, timings: timings) != nil
    }

    /// Returns the transcript with `pauseMarker` inserted at every inter-word
    /// gap ≥ `annotationGapSeconds`, or nil when alignment fails or no gap
    /// qualifies. Runs on the raw transcript — the only text token timings
    /// still align with — and is advisory context for the cloud cleanup
    /// prompt, never user-visible output.
    static func annotate(_ text: String, timings: [TranscriptTokenTiming]) -> String? {
        guard timings.count >= 2 else { return nil }
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard words.count >= 3,
              let wordTimings = align(words: words, timings: timings) else { return nil }

        var annotated = ""
        var markerCount = 0
        for index in words.indices {
            annotated += words[index]
            guard index < words.count - 1 else { break }
            let gap = wordTimings[index + 1].start - wordTimings[index].end
            if gap >= annotationGapSeconds {
                annotated += " \(pauseMarker) "
                markerCount += 1
            } else {
                annotated += " "
            }
        }

        return markerCount > 0 ? annotated : nil
    }

    static func segment(_ text: String, timings: [TranscriptTokenTiming]) -> String {
        guard timings.count >= 2 else { return text }
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard words.count >= 3,
              let wordTimings = align(words: words, timings: timings) else { return text }

        // Any punctuation at all means the head handled this utterance; the
        // 0.6s band is dominated by thinking pauses, and second-guessing a
        // punctuated transcript with them measurably backfires (mid-clause
        // "too far apart. The create track", comma upgrades, splits at
        // hesitations).
        let modelPunctuated = text.contains { ",;:.!?…".contains($0) }

        var output = ""
        var capitalizeNext = false

        for index in words.indices {
            var word = words[index]
            if capitalizeNext {
                word = capitalizedLeadingLetter(word)
                capitalizeNext = false
            }

            guard index < words.count - 1 else {
                output += word
                break
            }

            let gap = wordTimings[index + 1].start - wordTimings[index].end

            if modelPunctuated {
                // Layout only, at boundaries the model already marked.
                if gap >= sentenceGapSeconds, endsWithTerminalPunctuation(word),
                   !startsCorrectionCue(words, at: index + 1) {
                    output += word + (gap >= paragraphGapSeconds ? "\n\n" : " ")
                    capitalizeNext = true
                } else {
                    output += word + " "
                }
                continue
            }

            if isHesitationFiller(word) || isHesitationFiller(words[index + 1]) {
                output += word + " "
            } else if gap >= paragraphGapSeconds, shouldBreakParagraph(after: word),
                      !startsCorrectionCue(words, at: index + 1) {
                output += word + ".\n\n"
                capitalizeNext = true
            } else if gap >= sentenceGapSeconds, shouldBreakSentence(after: word, before: words[index + 1]),
                      !startsCorrectionCue(words, at: index + 1) {
                output += word + ". "
                capitalizeNext = true
            } else {
                output += word + " "
            }
        }

        return output
    }

    // MARK: - Break decisions

    private static func startsCorrectionCue(_ words: [String], at index: Int) -> Bool {
        guard index + 1 < words.count else { return false }
        return correctionCueOpeners.contains([normalized(words[index]), normalized(words[index + 1])])
    }

    private static func endsWithTerminalPunctuation(_ word: String) -> Bool {
        guard let last = word.last else { return false }
        return ".!?…".contains(last)
    }

    private static func isHesitationFiller(_ word: String) -> Bool {
        hesitationFillers.contains(normalized(word))
    }

    private static func shouldBreakParagraph(after word: String) -> Bool {
        !unfinishedTrailingWords.contains(normalized(word))
    }

    private static func shouldBreakSentence(after word: String, before next: String) -> Bool {
        // A thinking pause mid-clause leaves the sentence unfinished.
        if !shouldBreakParagraph(after: word) { return false }
        // Pauses before connectives are breath, not sentence ends.
        if continuationOpeners.contains(normalized(next)) { return false }
        return true
    }

    private static func capitalizedLeadingLetter(_ word: String) -> String {
        guard let first = word.first, first.isLetter, first.isLowercase else { return word }
        return first.uppercased() + word.dropFirst()
    }

    // MARK: - Word/token alignment

    /// Strict word/token alignment, shared with `NumberListSegmenter`.
    static func align(
        words: [String],
        timings: [TranscriptTokenTiming]
    ) -> [(start: Double, end: Double)]? {
        var result: [(start: Double, end: Double)] = []
        result.reserveCapacity(words.count)
        var tokenIndex = 0

        for word in words {
            let target = normalized(word)
            guard !target.isEmpty else { return nil }

            var accumulated = ""
            var start: Double?
            var end = 0.0

            while tokenIndex < timings.count, accumulated.count < target.count {
                let timing = timings[tokenIndex]
                tokenIndex += 1
                let piece = normalized(timing.token)
                guard !piece.isEmpty else { continue }
                if start == nil { start = timing.startTime }
                accumulated += piece
                end = timing.endTime
            }

            guard accumulated == target, let wordStart = start else { return nil }
            result.append((start: wordStart, end: end))
        }

        return result
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }
}
