import AppKit
import XCTest
@testable import Resonant

/// Verifies the multilingual over-segmentation re-merge pass that stitches back
/// words the Parakeet v3 model splits into per-subword word-initial pieces
/// (e.g. German "Mög lich kei ten" -> "Möglichkeiten").
///
/// The German assertions depend on the system having the `de` spelling
/// dictionary installed. `setUp` logs whether it is available so a failure on a
/// machine without the dictionary is distinguishable from a logic regression.
final class FragmentedWordRepairOverSegmentationTests: XCTestCase {

    private static var germanDictionaryAvailable = false

    override class func setUp() {
        super.setUp()
        let available = NSSpellChecker.shared.availableLanguages
        germanDictionaryAvailable = available.contains { $0.hasPrefix("de") }
        NSLog(
            "[FragmentedWordRepairOverSegmentationTests] NSSpellChecker.availableLanguages=\(available) de_available=\(germanDictionaryAvailable)"
        )
        if !germanDictionaryAvailable {
            NSLog(
                "[FragmentedWordRepairOverSegmentationTests] German system dictionary is ABSENT; 'de' assertions are skipped on this machine."
            )
        }
    }

    /// Builds one timing per whitespace word, each token carrying the leading
    /// space the model emits for a word-start, with the requested inter-word
    /// gaps in seconds. `gaps.count` must be `words.count - 1`.
    private func timings(
        words: [String],
        gaps: [Double],
        tokenDuration: Double = 0.2
    ) -> [TranscriptTokenTiming] {
        precondition(gaps.count == words.count - 1, "need one gap between each pair")
        var result: [TranscriptTokenTiming] = []
        var clock = 0.0
        for (index, word) in words.enumerated() {
            // Strip any trailing sentence punctuation from the spoken token; the
            // model emits the bare word piece, punctuation is added downstream.
            let core = word.unicodeScalars.prefix { CharacterSet.alphanumerics.contains($0) }
            let token = " " + String(String.UnicodeScalarView(core))
            result.append(
                TranscriptTokenTiming(token: token, startTime: clock, endTime: clock + tokenDuration)
            )
            if index < gaps.count {
                clock += tokenDuration + gaps[index]
            }
        }
        return result
    }

    // MARK: - German over-segmentation

    /// Genuine word boundaries carry a real acoustic pause; over-segmented
    /// subword pieces do not. `boundary` is the gap (in seconds) between
    /// separate words, `intra` the tiny gap between pieces of one
    /// over-segmented word. `intraRuns` lists the [start, end] word-index
    /// ranges that form a single over-segmented word.
    private func timings(
        words: [String],
        intraRuns: [ClosedRange<Int>],
        boundary: Double = 0.5,
        intra: Double = 0.05
    ) -> [TranscriptTokenTiming] {
        var gaps: [Double] = []
        for index in 0..<(words.count - 1) {
            // The gap after word `index` is intra only when both `index` and
            // `index + 1` lie inside the same over-segmented run.
            let isIntra = intraRuns.contains { $0.contains(index) && $0.contains(index + 1) }
            gaps.append(isIntra ? intra : boundary)
        }
        return timings(words: words, gaps: gaps)
    }

    func testGermanOverSegmentedWordMerges() throws {
        try XCTSkipUnless(Self.germanDictionaryAvailable, "de dictionary absent")
        let words = ["Wir", "brauchen", "mehr", "Mög", "lich", "kei", "ten"]
        let text = "Wir brauchen mehr Mög lich kei ten."
        // Only the four-piece run (indices 3...6) is contiguous sub-0.3s.
        let t = timings(words: words, intraRuns: [3...6])
        let result = FragmentedWordRepair.repair(text, timings: t, language: "de")
        XCTAssertTrue(
            result.contains("Möglichkeiten"),
            "expected merged 'Möglichkeiten' in: \(result)"
        )
    }

    func testGermanCapitalInteriorCompoundMergesWithCorrectCasing() throws {
        try XCTSkipUnless(Self.germanDictionaryAvailable, "de dictionary absent")
        let words = ["Ich", "fahre", "zum", "Haupt", "Bahn", "hof"]
        let text = "Ich fahre zum Haupt Bahn hof."
        // Only the three-piece compound (indices 3...5) is contiguous sub-0.3s.
        let t = timings(words: words, intraRuns: [3...5])
        let result = FragmentedWordRepair.repair(text, timings: t, language: "de")
        XCTAssertTrue(
            result.contains("Hauptbahnhof"),
            "expected 'Hauptbahnhof' (interior-lowercased) in: \(result)"
        )
        XCTAssertFalse(
            result.contains("HauptBahnhof"),
            "interior capital must be lowercased, got: \(result)"
        )
    }

    func testGermanRunWithInternalPauseStaysSplit() throws {
        try XCTSkipUnless(Self.germanDictionaryAvailable, "de dictionary absent")
        let words = ["Wir", "brauchen", "mehr", "Mög", "lich", "kei", "ten"]
        let text = "Wir brauchen mehr Mög lich kei ten."
        // The four-piece run would normally merge, but one genuine pause
        // greater than 0.3s lands between "lich" (index 4) and "kei" (index 5).
        var gaps = Array(repeating: 0.5, count: words.count - 1)
        gaps[3] = 0.05 // Mög|lich
        gaps[5] = 0.05 // kei|ten
        gaps[4] = 0.5  // lich|kei — the vetoing pause
        let t = timings(words: words, gaps: gaps)
        let result = FragmentedWordRepair.repair(text, timings: t, language: "de")
        XCTAssertFalse(
            result.contains("Möglichkeiten"),
            "an internal pause must veto the merge, got: \(result)"
        )
    }

    func testGermanAllValidWordsAreNotMerged() throws {
        try XCTSkipUnless(Self.germanDictionaryAvailable, "de dictionary absent")
        // "in" and "der" are both standalone German words: the non-word guard
        // must block the merge even though the gap between them is small.
        let words = ["Das", "gilt", "in", "der", "Stadt"]
        let text = "Das gilt in der Stadt."
        let t = timings(words: words, intraRuns: [2...3])
        let result = FragmentedWordRepair.repair(text, timings: t, language: "de")
        XCTAssertTrue(
            result.contains("in der"),
            "all-valid run must stay separate, got: \(result)"
        )
        XCTAssertFalse(result.contains("inder"), "must not merge valid words, got: \(result)")
    }

    /// Over-merge regression: a real adverb ("mehr") coarticulated with no pause
    /// ahead of an over-segmented noun must NOT be fused into it. German's
    /// productive compounding makes the spell checker accept the run-on
    /// "Mehrmöglichkeiten", so timing and the joined-word check alone do not stop
    /// the fusion — the leading-word peel and the head-casing-gated promotion do.
    func testCoarticulatedLeadingWordIsNotFused() throws {
        try XCTSkipUnless(Self.germanDictionaryAvailable, "de dictionary absent")
        let words = ["Wir", "brauchen", "mehr", "Mög", "lich", "kei", "ten"]
        let text = "Wir brauchen mehr Mög lich kei ten."
        // The whole tail from "mehr" onward is sub-0.3s: mehr|Mög is a tight 0.05s
        // gap, exactly the coarticulation the blocker described.
        let t = timings(words: words, intraRuns: [2...6])
        let result = FragmentedWordRepair.repair(text, timings: t, language: "de")
        XCTAssertFalse(
            result.lowercased().contains("mehrmöglichkeiten"),
            "adverb must not be fused into the noun, got: \(result)"
        )
        // The noun is still repaired and the adverb survives as its own word.
        XCTAssertTrue(
            result.contains("mehr Möglichkeiten"),
            "expected 'mehr Möglichkeiten' (noun repaired, adverb intact), got: \(result)"
        )
    }

    /// Recall companion to the over-merge guard: peeling the valid leading word
    /// off a fully-coarticulated run must not leave the noun unrepaired.
    func testCoarticulatedLeadingWordStillRepairsNoun() throws {
        try XCTSkipUnless(Self.germanDictionaryAvailable, "de dictionary absent")
        let words = ["viel", "Ar", "beit"]
        let text = "viel Ar beit"
        let t = timings(words: words, intraRuns: [0...2])
        let result = FragmentedWordRepair.repair(text, timings: t, language: "de")
        XCTAssertTrue(
            result.contains("viel Arbeit"),
            "expected 'viel Arbeit' (adjective intact, noun merged), got: \(result)"
        )
        XCTAssertFalse(
            result.lowercased().contains("vielarbeit"),
            "adjective must not be fused into the noun, got: \(result)"
        )
    }

    /// Two over-segmented words separated by a real pause both repair: the
    /// >0.3s boundary holds the two sub-0.3s runs apart so each merges on its own.
    func testTwoOverSegmentedWordsSeparatedByPauseBothRepair() throws {
        try XCTSkipUnless(Self.germanDictionaryAvailable, "de dictionary absent")
        let words = ["Mög", "lich", "kei", "ten", "Haupt", "Bahn", "hof"]
        let text = "Mög lich kei ten Haupt Bahn hof."
        // Two separate over-segmented words; a genuine pause divides them.
        let t = timings(words: words, intraRuns: [0...3, 4...6])
        let result = FragmentedWordRepair.repair(text, timings: t, language: "de")
        XCTAssertTrue(result.contains("Möglichkeiten"), "first word must repair, got: \(result)")
        XCTAssertTrue(result.contains("Hauptbahnhof"), "second word must repair, got: \(result)")
    }

    // MARK: - English

    func testEnglishOverSegmentedWordMerges() {
        let words = ["trans", "form", "ation"]
        let text = "trans form ation"
        let t = timings(words: words, intraRuns: [0...2])
        let result = FragmentedWordRepair.repair(text, timings: t, language: "en")
        XCTAssertTrue(
            result.contains("transformation"),
            "expected merged 'transformation' in: \(result)"
        )
    }

    func testEnglishValidPhraseStaysIntact() {
        // "a way back into the app" — none of these should fuse into "awayback".
        // Tight gaps everywhere; the non-word guard must still keep them apart.
        let words = ["We", "found", "a", "way", "back", "into", "the", "app"]
        let text = "We found a way back into the app."
        let t = timings(words: words, intraRuns: [0...7])
        let result = FragmentedWordRepair.repair(text, timings: t, language: "en")
        XCTAssertFalse(result.contains("awayback"), "must not fuse 'a way back', got: \(result)")
        XCTAssertFalse(result.contains("wayback"), "must not fuse 'way back', got: \(result)")
        XCTAssertTrue(result.contains("a way back"), "phrase must survive intact, got: \(result)")
    }

    // MARK: - No-op guards

    func testNoTimingsLeavesTextUnchanged() {
        let text = "Wir brauchen mehr Mög lich kei ten."
        let result = FragmentedWordRepair.repair(text, timings: [], language: "de")
        XCTAssertEqual(result, text)
    }
}
