import XCTest
@testable import Resonant

@MainActor
final class CorrectionDiffEngineTests: XCTestCase {

    // MARK: - Basic corrections

    func testDetectsSimpleSpellingCorrection() {
        let corrections = CorrectionDiffEngine.extractCorrections(
            original: "I went to the libary",
            edited: "I went to the library"
        )
        XCTAssertEqual(corrections.count, 1)
        XCTAssertEqual(corrections.first?.spoken, "libary")
        XCTAssertEqual(corrections.first?.written, "library")
    }

    func testDetectsMultipleCorrections() {
        let corrections = CorrectionDiffEngine.extractCorrections(
            original: "definately recieve the package",
            edited: "definitely receive the package"
        )
        XCTAssertEqual(corrections.count, 2)
        let spokenWords = Set(corrections.map(\.spoken))
        XCTAssertTrue(spokenWords.contains("definately"))
        XCTAssertTrue(spokenWords.contains("recieve"))
    }

    // MARK: - Noise filtering

    func testIgnoresPunctuationOnlyDifferences() {
        let corrections = CorrectionDiffEngine.extractCorrections(
            original: "hello world",
            edited: "hello, world."
        )
        XCTAssertTrue(corrections.isEmpty)
    }

    func testIgnoresDowncasingNoise() {
        // "The" → "the" is just capitalization noise, not a correction
        let corrections = CorrectionDiffEngine.extractCorrections(
            original: "The quick brown fox",
            edited: "the quick brown fox"
        )
        XCTAssertTrue(corrections.isEmpty)
    }

    func testLearnsProperNounCapitalization() {
        // "john" → "John" is a name correction — should be learned
        let corrections = CorrectionDiffEngine.extractCorrections(
            original: "I met john today",
            edited: "I met John today"
        )
        XCTAssertEqual(corrections.count, 1)
        XCTAssertEqual(corrections.first?.spoken, "john")
        XCTAssertEqual(corrections.first?.written, "John")
    }

    func testIgnoresLargeEditDistance() {
        // "big" → "enormous" is a content rewrite, not a transcription fix
        let corrections = CorrectionDiffEngine.extractCorrections(
            original: "a big house",
            edited: "a enormous house"
        )
        XCTAssertTrue(corrections.isEmpty)
    }

    // MARK: - Similarity threshold

    func testRejectsCompleteRewrite() {
        let corrections = CorrectionDiffEngine.extractCorrections(
            original: "The quick brown fox jumps over the lazy dog",
            edited: "I went to the store and bought some groceries"
        )
        XCTAssertTrue(corrections.isEmpty)
    }

    func testAcceptsMinorEditsInLongerText() {
        let corrections = CorrectionDiffEngine.extractCorrections(
            original: "Please send the report to the managment team by friday",
            edited: "Please send the report to the management team by friday"
        )
        XCTAssertEqual(corrections.count, 1)
        XCTAssertEqual(corrections.first?.spoken, "managment")
        XCTAssertEqual(corrections.first?.written, "management")
    }

    // MARK: - Real word detection

    func testNonWordMarkedCorrectly() {
        let corrections = CorrectionDiffEngine.extractCorrections(
            original: "I definately want this",
            edited: "I definitely want this"
        )
        XCTAssertEqual(corrections.count, 1)
        // "definately" is not a real word
        XCTAssertFalse(corrections.first?.spokenIsRealWord ?? true)
    }

    // MARK: - LCS alignment

    func testLCSProducesCorrectSubsequence() {
        let lcs = CorrectionDiffEngine.longestCommonSubsequence(
            ["a", "b", "c", "d"],
            ["a", "x", "c", "d"]
        )
        XCTAssertEqual(lcs, ["a", "c", "d"])
    }

    func testSubstitutionExtractionWithSingleChange() {
        let subs = CorrectionDiffEngine.substitutions(
            from: ["the", "cat", "sat"],
            to: ["the", "bat", "sat"]
        )
        XCTAssertEqual(subs.count, 1)
        XCTAssertEqual(subs.first?.0, "cat")
        XCTAssertEqual(subs.first?.1, "bat")
    }

    func testInsertionsAndDeletionsAreNotSubstitutions() {
        // Deletion: 3 words → 2 words
        let subs = CorrectionDiffEngine.substitutions(
            from: ["the", "the", "cat"],
            to: ["the", "cat"]
        )
        XCTAssertTrue(subs.isEmpty)
    }

    // MARK: - Levenshtein

    func testLevenshteinIdentical() {
        XCTAssertEqual(CorrectionDiffEngine.levenshtein("hello", "hello"), 0)
    }

    func testLevenshteinOneDeletion() {
        XCTAssertEqual(CorrectionDiffEngine.levenshtein("library", "libary"), 1)
    }

    func testLevenshteinTwoSubstitutions() {
        XCTAssertEqual(CorrectionDiffEngine.levenshtein("receive", "recieve"), 2)
    }

    // MARK: - Phonetic skeleton

    func testPhoneticSkeletonMatchesKnownMishearings() {
        XCTAssertEqual(
            CorrectionDiffEngine.phoneticSkeleton("tice"),
            CorrectionDiffEngine.phoneticSkeleton("thijs")
        )
        XCTAssertTrue(CorrectionDiffEngine.phoneticallySimilar("savior", "xavier"))
        XCTAssertTrue(CorrectionDiffEngine.phoneticallySimilar("jon", "john"))
        XCTAssertFalse(CorrectionDiffEngine.phoneticallySimilar("big", "enormous"))
    }

    // MARK: - Near-miss suggestions

    func testNearMissProperNounBecomesSuggestionNotCorrection() {
        // "teece" → "Thijs" is edit distance 4: beyond the silent-learn cap,
        // but phonetically the same word — should surface as a suggestion.
        let result = CorrectionDiffEngine.extractWithSuggestions(
            original: "I met teece today",
            edited: "I met Thijs today"
        )
        XCTAssertTrue(result.corrections.isEmpty)
        XCTAssertEqual(result.suggestions.count, 1)
        XCTAssertEqual(result.suggestions.first?.spoken, "teece")
        XCTAssertEqual(result.suggestions.first?.written, "Thijs")
    }

    func testDistantRewriteIsNeitherCorrectionNorSuggestion() {
        let result = CorrectionDiffEngine.extractWithSuggestions(
            original: "a big house",
            edited: "a enormous house"
        )
        XCTAssertTrue(result.corrections.isEmpty)
        XCTAssertTrue(result.suggestions.isEmpty)
    }

    // MARK: - Token merges

    func testMergedTokensLearnExactConcatenation() {
        let result = CorrectionDiffEngine.extractWithSuggestions(
            original: "the web site is done",
            edited: "the website is done"
        )
        XCTAssertEqual(result.corrections.count, 1)
        XCTAssertEqual(result.corrections.first?.spoken, "web site")
        XCTAssertEqual(result.corrections.first?.written, "website")
        XCTAssertTrue(result.suggestions.isEmpty)
    }

    func testMergedTokensSuggestPhoneticProperNoun() {
        let result = CorrectionDiffEngine.extractWithSuggestions(
            original: "talk to tie s later",
            edited: "talk to Thijs later"
        )
        XCTAssertTrue(result.corrections.isEmpty)
        XCTAssertEqual(result.suggestions.count, 1)
        XCTAssertEqual(result.suggestions.first?.spoken, "tie s")
        XCTAssertEqual(result.suggestions.first?.written, "Thijs")
    }

    // MARK: - Downcase preferences

    func testDowncasePreferenceLearnedMidSentence() {
        let corrections = CorrectionDiffEngine.extractCorrections(
            original: "I like Vibe coding",
            edited: "I like vibe coding"
        )
        XCTAssertEqual(corrections.count, 1)
        XCTAssertEqual(corrections.first?.spoken, "Vibe")
        XCTAssertEqual(corrections.first?.written, "vibe")
        XCTAssertTrue(corrections.first?.isCaseDowncase ?? false)
    }

    func testDowncaseAfterSentencePunctuationIgnored() {
        // The capital after "." is grammar being fixed, not an ASR style habit.
        let corrections = CorrectionDiffEngine.extractCorrections(
            original: "Ship it today. Vibe coding works",
            edited: "Ship it today. vibe coding works"
        )
        XCTAssertTrue(corrections.isEmpty)
    }

    // MARK: - Edge cases

    func testEmptyOriginal() {
        let corrections = CorrectionDiffEngine.extractCorrections(original: "", edited: "hello")
        XCTAssertTrue(corrections.isEmpty)
    }

    func testEmptyEdited() {
        let corrections = CorrectionDiffEngine.extractCorrections(original: "hello", edited: "")
        XCTAssertTrue(corrections.isEmpty)
    }

    func testIdenticalText() {
        let corrections = CorrectionDiffEngine.extractCorrections(
            original: "hello world",
            edited: "hello world"
        )
        XCTAssertTrue(corrections.isEmpty)
    }
}
