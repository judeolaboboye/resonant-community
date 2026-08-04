import AppKit
import XCTest
@testable import Resonant

/// Verifies the clipped-prefix false-start repair: a non-word fragment the
/// speaker abandons mid-word before restarting with the full word
/// ("send it to s Sarah" -> "send it to Sarah") is dropped, gated by strict
/// prefix + non-word fragment + real-word target + back-to-back timing so valid
/// speech is never touched.
///
/// Assertions depend on the `en` spelling dictionary being installed; `setUp`
/// records availability so a missing dictionary skips rather than fails.
final class FragmentedWordRepairClippedPrefixTests: XCTestCase {

    private static var englishDictionaryAvailable = false

    override class func setUp() {
        super.setUp()
        englishDictionaryAvailable = NSSpellChecker.shared.availableLanguages
            .contains { $0.hasPrefix("en") }
    }

    /// One timing per whitespace word, each carrying the leading space the model
    /// emits at a word start, with the requested inter-word gaps in seconds.
    private func timings(
        words: [String],
        gaps: [Double],
        tokenDuration: Double = 0.2
    ) -> [TranscriptTokenTiming] {
        precondition(gaps.count == words.count - 1, "need one gap between each pair")
        var result: [TranscriptTokenTiming] = []
        var clock = 0.0
        for (index, word) in words.enumerated() {
            let core = word.unicodeScalars.prefix { CharacterSet.alphanumerics.contains($0) }
            result.append(
                TranscriptTokenTiming(
                    token: " " + String(String.UnicodeScalarView(core)),
                    startTime: clock,
                    endTime: clock + tokenDuration
                )
            )
            if index < gaps.count { clock += tokenDuration + gaps[index] }
        }
        return result
    }

    private func repair(_ words: [String], gaps: [Double]) -> String {
        FragmentedWordRepair.repair(
            words.joined(separator: " "),
            timings: timings(words: words, gaps: gaps),
            language: "en",
            removeFalseStarts: true
        )
    }

    func testDropsSingleLetterClippedPrefix() throws {
        try XCTSkipUnless(Self.englishDictionaryAvailable)
        // "t" abandoned before "total", emitted back-to-back.
        let words = ["the", "t", "total", "is", "wrong"]
        XCTAssertEqual(repair(words, gaps: [0.1, 0.1, 0.1, 0.1]), "the total is wrong")
    }

    func testDropsMultiCharClippedPrefix() throws {
        try XCTSkipUnless(Self.englishDictionaryAvailable)
        // "transc" is a non-word prefix of "transcription".
        let words = ["we", "need", "the", "transc", "transcription", "now"]
        XCTAssertEqual(repair(words, gaps: [0.1, 0.1, 0.1, 0.1, 0.1]), "we need the transcription now")
    }

    func testKeepsValidWordThatPrefixesNextWord() throws {
        try XCTSkipUnless(Self.englishDictionaryAvailable)
        // "a" is a real word and a prefix of "apple" — never a clipped restart.
        let words = ["bring", "a", "apple", "please"]
        XCTAssertEqual(repair(words, gaps: [0.1, 0.1, 0.1]), "bring a apple please")
    }

    func testKeepsDeliberateUppercaseLetterBeforeWord() throws {
        try XCTSkipUnless(Self.englishDictionaryAvailable)
        // "D" is a deliberately spoken letter (vitamin D), not a clipped restart.
        let words = ["take", "vitamin", "D", "daily"]
        XCTAssertEqual(repair(words, gaps: [0.1, 0.1, 0.1]), "take vitamin D daily")
    }

    func testKeepsLowercaseLetterBeforeCapitalizedName() throws {
        try XCTSkipUnless(Self.englishDictionaryAvailable)
        // A capitalized target reads as a name/initial, not a clipped word-start.
        let words = ["meeting", "with", "s", "Sarah"]
        XCTAssertEqual(repair(words, gaps: [0.1, 0.1, 0.1]), "meeting with s Sarah")
    }

    func testKeepsClippedPrefixWhenPauseBetween() throws {
        try XCTSkipUnless(Self.englishDictionaryAvailable)
        // A real pause (0.5s) before "total" means two intended tokens.
        let words = ["the", "t", "total"]
        XCTAssertEqual(repair(words, gaps: [0.1, 0.5]), "the t total")
    }

    func testNoOpWithoutTimings() {
        // No timings → no-op even with false-start removal enabled.
        XCTAssertEqual(
            FragmentedWordRepair.repair(
                "the t total is wrong",
                timings: [],
                language: "en",
                removeFalseStarts: true
            ),
            "the t total is wrong"
        )
    }

    func testNoOpWhenFalseStartsDisabled() throws {
        try XCTSkipUnless(Self.englishDictionaryAvailable)
        let words = ["the", "t", "total", "is", "wrong"]
        XCTAssertEqual(
            FragmentedWordRepair.repair(
                words.joined(separator: " "),
                timings: timings(words: words, gaps: [0.1, 0.1, 0.1, 0.1]),
                language: "en",
                removeFalseStarts: false
            ),
            "the t total is wrong"
        )
    }
}
