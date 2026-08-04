import XCTest
@testable import Resonant

final class PauseSegmenterTests: XCTestCase {

    /// Builds one timing token per word with the given gap *before* each word
    /// (first gap ignored). Word durations are 0.2s.
    private func timings(words: [String], gapsBefore: [Double]) -> [TranscriptTokenTiming] {
        precondition(words.count == gapsBefore.count)
        var result: [TranscriptTokenTiming] = []
        var clock = 0.0
        for (word, gap) in zip(words, gapsBefore) {
            clock += gap
            result.append(TranscriptTokenTiming(token: word, startTime: clock, endTime: clock + 0.2))
            clock += 0.2
        }
        return result
    }

    private func segment(_ text: String, gapsBefore: [Double]) -> String {
        let words = text.split(separator: " ").map(String.init)
        return PauseSegmenter.segment(
            text,
            timings: timings(words: words, gapsBefore: gapsBefore)
        )
    }

    func testSentenceBreakAtMediumGap() {
        XCTAssertEqual(
            segment(
                "we shipped the feature it works now",
                gapsBefore: [0, 0.1, 0.1, 0.1, 0.9, 0.1, 0.1]
            ),
            "we shipped the feature. It works now"
        )
    }

    func testParagraphBreakAtLongGap() {
        XCTAssertEqual(
            segment(
                "that wraps up the update next topic is hiring",
                gapsBefore: [0, 0.1, 0.1, 0.1, 0.1, 2.0, 0.1, 0.1, 0.1]
            ),
            "that wraps up the update.\n\nNext topic is hiring"
        )
    }

    func testNoParagraphBreakAfterUnfinishedWord() {
        let text = "remove the play button and the time from the top right"
        XCTAssertEqual(
            segment(
                text,
                gapsBefore: [0, 0.1, 0.1, 0.1, 0.1, 0.1, 2.0, 0.1, 0.1, 0.1, 0.1]
            ),
            text
        )
    }

    /// Thinking pauses inside one long clause used to be split twice, once
    /// after "to" and once after "that", because the paragraph branch skipped
    /// the unfinished-word check the sentence branch already applied.
    func testNoParagraphBreakAcrossRepeatedThinkingPauses() {
        let text = "we made updates recently to our personalization system and one"
            + " of the problems i have is that we are becoming too overweight"
        var gaps = [Double](repeating: 0.1, count: text.split(separator: " ").count)
        gaps[5] = 1.9   // after "to"
        gaps[17] = 2.1  // after "that"
        XCTAssertEqual(segment(text, gapsBefore: gaps), text)
    }

    func testParagraphBreakBeforeCommonSentenceOpener() {
        XCTAssertEqual(
            segment(
                "that wraps up the update in summary we should ship",
                gapsBefore: [0, 0.1, 0.1, 0.1, 0.1, 2.0, 0.1, 0.1, 0.1, 0.1]
            ),
            "that wraps up the update.\n\nIn summary we should ship"
        )
    }

    func testExplicitTerminalPunctuationAllowsParagraphAfterUnfinishedLexicalWord() {
        XCTAssertEqual(
            segment(
                "we already covered that. here is the next topic",
                gapsBefore: [0, 0.1, 0.1, 0.1, 2.0, 0.1, 0.1, 0.1, 0.1]
            ),
            "we already covered that.\n\nHere is the next topic"
        )
    }

    func testNoBreakBelowThreshold() {
        let text = "just a normal sentence flowing along"
        XCTAssertEqual(
            segment(text, gapsBefore: [0, 0.2, 0.3, 0.2, 0.4, 0.3]),
            text
        )
    }

    func testNoBreakBeforeConnective() {
        let text = "we shipped the feature and it works"
        XCTAssertEqual(
            segment(text, gapsBefore: [0, 0.1, 0.1, 0.1, 0.9, 0.1, 0.1]),
            text
        )
    }

    func testNoBreakAfterComma() {
        let text = "once that lands, we can ship"
        XCTAssertEqual(
            segment(text, gapsBefore: [0, 0.1, 0.1, 0.9, 0.1, 0.1]),
            text
        )
    }

    func testNoBreakAfterUnfinishedWord() {
        // A thinking pause after "is" leaves the sentence unfinished.
        let text = "the budget is fine for now"
        XCTAssertEqual(
            segment(text, gapsBefore: [0, 0.1, 0.1, 0.9, 0.1, 0.1]),
            text
        )
    }

    /// Long gaps used to upgrade a model comma to a period ("in the library,
    /// in the create page" → "in the library. In the create page"). Every
    /// observed upgrade in the field was wrong: a comma is the model saying
    /// the clause continues, and the pause is the speaker thinking.
    func testCommaAtParagraphGapIsKeptNotUpgraded() {
        let text = "let me think about that, here is the plan"
        XCTAssertEqual(
            segment(text, gapsBefore: [0, 0.1, 0.1, 0.1, 0.1, 2.2, 0.1, 0.1, 0.1]),
            text
        )
    }

    /// The dominant field failure: the decoder already punctuated the
    /// utterance, and a 0.6–1.6s thinking pause mid-clause invented a period
    /// anyway ("it's too far apart. The create track and the actual icon").
    /// A punctuated transcript must never gain gap-derived punctuation.
    func testPunctuatedTranscriptGetsNoInventedSentenceBreaks() {
        let text = "I think it's too far apart the create track and the actual icon. Can you fix that?"
        var gaps = [Double](repeating: 0.1, count: text.split(separator: " ").count)
        gaps[6] = 0.9   // thinking pause after "apart"
        XCTAssertEqual(segment(text, gapsBefore: gaps), text)
    }

    /// Same protection at paragraph-length gaps: "a longer term agreement
    /// making videos" must not become "agreement.\n\nMaking videos" just
    /// because the speaker stopped to think.
    func testPunctuatedTranscriptParagraphGapMidClauseLeftAlone() {
        let text = "I proposed a longer term agreement making videos on Devin. I promote it a lot."
        var gaps = [Double](repeating: 0.1, count: text.split(separator: " ").count)
        gaps[6] = 2.0   // after "agreement"
        XCTAssertEqual(segment(text, gapsBefore: gaps), text)
    }

    /// A paragraph-length gap at a boundary the model itself marked is pure
    /// layout and stays allowed.
    func testParagraphBreakAtModelSentenceEnd() {
        XCTAssertEqual(
            segment(
                "is that done? we need it today",
                gapsBefore: [0, 0.1, 0.1, 2.0, 0.1, 0.1, 0.1]
            ),
            "is that done?\n\nWe need it today"
        )
    }

    /// A pause around a hesitation is the speaker mid-thought. Splitting
    /// there stranded a period once FillerRemover deleted the sound:
    /// "using it and uh we can" became "using it and. We can".
    func testBareTranscriptDoesNotBreakAroundHesitationFiller() {
        let text = "keep using it and uh we can assess that later"
        XCTAssertEqual(
            segment(text, gapsBefore: [0, 0.1, 0.1, 0.1, 0.8, 0.8, 0.1, 0.1, 0.1, 0.1]),
            text
        )
    }

    func testExistingTerminalPunctuationNotDuplicated() {
        XCTAssertEqual(
            segment(
                "is that done? we need it today",
                gapsBefore: [0, 0.1, 0.1, 0.9, 0.1, 0.1, 0.1]
            ),
            "is that done? We need it today"
        )
    }

    func testNoSentenceBreakBeforeCorrectionCue() {
        // The pause before "actually no" is the speaker retracting, not a
        // sentence end — a period here would hide the correction from the
        // false-start repairs downstream.
        let text = "the deadline is Tuesday actually no Wednesday"
        XCTAssertEqual(
            segment(text, gapsBefore: [0, 0.1, 0.1, 0.1, 0.9, 0.1, 0.1]),
            text
        )
    }

    func testNoParagraphBreakBeforeCorrectionCue() {
        let text = "call Priya at noon scratch that call her at one"
        XCTAssertEqual(
            segment(text, gapsBefore: [0, 0.1, 0.1, 0.1, 2.0, 0.1, 0.1, 0.1, 0.1, 0.1]),
            text
        )
    }

    func testSentenceBreakStillHappensBeforeOrdinaryNo() {
        // "no issues" is not a correction cue; the pause is a real boundary.
        XCTAssertEqual(
            segment(
                "we shipped the feature no issues found",
                gapsBefore: [0, 0.1, 0.1, 0.1, 0.9, 0.1, 0.1]
            ),
            "we shipped the feature. No issues found"
        )
    }

    func testMisalignedTimingsLeaveTextUntouched() {
        let text = "these words do not match the tokens"
        let mismatched = [
            TranscriptTokenTiming(token: "completely", startTime: 0, endTime: 0.2),
            TranscriptTokenTiming(token: "different", startTime: 0.3, endTime: 0.5),
        ]
        XCTAssertEqual(PauseSegmenter.segment(text, timings: mismatched), text)
        XCTAssertFalse(PauseSegmenter.timingsStrictlyAlign(text, timings: mismatched))
    }

    func testSubwordTokensAlignAcrossWords() {
        // SentencePiece-style pieces: one word split across tokens.
        let text = "transformation arrived here today"
        let pieces = [
            TranscriptTokenTiming(token: "▁trans", startTime: 0.0, endTime: 0.2),
            TranscriptTokenTiming(token: "format", startTime: 0.2, endTime: 0.4),
            TranscriptTokenTiming(token: "ion", startTime: 0.4, endTime: 0.5),
            TranscriptTokenTiming(token: "▁arrived", startTime: 0.6, endTime: 0.7),
            TranscriptTokenTiming(token: "▁here", startTime: 1.6, endTime: 1.8),
            TranscriptTokenTiming(token: "▁today", startTime: 1.9, endTime: 2.0),
        ]
        XCTAssertEqual(
            PauseSegmenter.segment(text, timings: pieces),
            "transformation arrived. Here today"
        )
        XCTAssertTrue(PauseSegmenter.timingsStrictlyAlign(text, timings: pieces))
    }

    func testEmptyTimingsLeaveTextUntouched() {
        let text = "no timings available here"
        XCTAssertEqual(PauseSegmenter.segment(text, timings: []), text)
    }

    // MARK: - Pause annotation for cloud cleanup

    private func annotate(_ text: String, gapsBefore: [Double]) -> String? {
        let words = text.split(separator: " ").map(String.init)
        return PauseSegmenter.annotate(
            text,
            timings: timings(words: words, gapsBefore: gapsBefore)
        )
    }

    func testAnnotateMarksHesitationGapBelowSentenceThreshold() {
        // 0.45s is under the 0.6s sentence gap — invisible to segment(),
        // but exactly the band where self-corrections live.
        XCTAssertEqual(
            annotate(
                "send it Monday actually no Wednesday",
                gapsBefore: [0, 0.1, 0.1, 0.45, 0.1, 0.1]
            ),
            "send it Monday <pause> actually no Wednesday"
        )
    }

    func testAnnotateMarksEveryQualifyingGap() {
        XCTAssertEqual(
            annotate(
                "we get a new recent mem we get a new recent session",
                gapsBefore: [0, 0.1, 0.1, 0.1, 0.1, 0.1, 0.7, 0.1, 0.1, 0.1, 0.1, 0.1]
            ),
            "we get a new recent mem <pause> we get a new recent session"
        )
    }

    func testAnnotateReturnsNilWithoutQualifyingGaps() {
        XCTAssertNil(
            annotate(
                "just a normal sentence flowing along",
                gapsBefore: [0, 0.2, 0.3, 0.2, 0.3, 0.3]
            )
        )
    }

    func testAnnotateReturnsNilOnMisalignedTimings() {
        let mismatched = [
            TranscriptTokenTiming(token: "completely", startTime: 0, endTime: 0.2),
            TranscriptTokenTiming(token: "different", startTime: 0.5, endTime: 0.7),
        ]
        XCTAssertNil(PauseSegmenter.annotate("these words do not match", timings: mismatched))
    }

    func testAnnotateReturnsNilWithoutTimings() {
        XCTAssertNil(PauseSegmenter.annotate("no timings available here", timings: []))
    }

    // MARK: - Pipeline integration

    func testPauseSeparatesNumbersBeforeITNTimeCollapse() {
        // "ten <long pause> fifteen" is two numbers, not 10:15.
        let text = "ten fifteen people showed up"
        let words = text.split(separator: " ").map(String.init)
        let timed = timings(words: words, gapsBefore: [0, 0.9, 0.1, 0.1, 0.1])
        let result = PostProcessingPipeline.run(
            text,
            configuration: PostProcessingConfiguration(
                removeFillersEnabled: false,
                removeFalseStartsEnabled: false,
                itnEnabled: true,
                autoPunctuationEnabled: true,
                bulletPointsEnabled: false
            ),
            corrections: [],
            tokenTimings: timed
        )
        XCTAssertFalse(result.text.contains("10:15"), result.text)
    }
}
