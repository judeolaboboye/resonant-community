import XCTest
@testable import Resonant

final class FormatCorrectionClassifierTests: XCTestCase {
    func testDetectsURLExpansionRevert() {
        let signals = FormatCorrectionClassifier.classify(
            pasted: "Check out substack.com for more",
            edited: "Check out Substack for more"
        )
        let signal = signals.first { $0.category == .urlExpansionRevert }
        XCTAssertNotNil(signal)
        XCTAssertEqual(signal?.scopeHint, "substack.com")
        XCTAssertEqual(signal?.observedValue, "Substack")
    }

    func testDetectsPhoneStyleReformatToParenthesized() {
        let signals = FormatCorrectionClassifier.classify(
            pasted: "call 555-123-4567 today",
            edited: "call (555) 123-4567 today"
        )
        let signal = signals.first { $0.category == .phoneStyle }
        XCTAssertNotNil(signal)
        XCTAssertEqual(signal?.observedValue, "parenthesized")
    }

    func testDetectsPhoneStyleReformatToDotted() {
        let signals = FormatCorrectionClassifier.classify(
            pasted: "call 5551234567 today",
            edited: "call 555.123.4567 today"
        )
        XCTAssertEqual(signals.first { $0.category == .phoneStyle }?.observedValue, "dotted")
    }

    func testDetectsEmailCasing() {
        let signals = FormatCorrectionClassifier.classify(
            pasted: "reach me at Alex@Example.COM soon",
            edited: "reach me at alex@example.com soon"
        )
        let signal = signals.first { $0.category == .emailCasing }
        XCTAssertNotNil(signal)
        XCTAssertEqual(signal?.observedValue, "alex@example.com")
    }

    func testDetectsWordCasing() {
        let signals = FormatCorrectionClassifier.classify(
            pasted: "the resonant team shipped it",
            edited: "the Resonant team shipped it"
        )
        let signal = signals.first { $0.category == .wordCasing }
        XCTAssertNotNil(signal)
        XCTAssertEqual(signal?.observedValue, "Resonant")
    }

    func testIgnoresSentenceInitialCapitalization() {
        let signals = FormatCorrectionClassifier.classify(
            pasted: "resonant shipped today",
            edited: "Resonant shipped today"
        )
        XCTAssertFalse(signals.contains { $0.category == .wordCasing })
    }

    func testNeverEmitsGlobalPunctuationForTrailingPeriodRemoval() {
        let signals = FormatCorrectionClassifier.classify(
            pasted: "sounds good.",
            edited: "sounds good"
        )
        XCTAssertFalse(signals.contains { $0.category == .punctuation })
    }

    func testNeverEmitsGlobalPunctuationForTrailingPeriodAddition() {
        let signals = FormatCorrectionClassifier.classify(
            pasted: "sounds good",
            edited: "sounds good."
        )
        XCTAssertFalse(signals.contains { $0.category == .punctuation })
    }

    func testUnrelatedEditProducesNoSignals() {
        let signals = FormatCorrectionClassifier.classify(
            pasted: "meet at noon",
            edited: "meet at three"
        )
        XCTAssertTrue(signals.isEmpty)
    }

    func testIdenticalTextProducesNoSignals() {
        XCTAssertTrue(FormatCorrectionClassifier.classify(pasted: "same", edited: "same").isEmpty)
    }

    func testMultiSignalEdit() {
        let signals = FormatCorrectionClassifier.classify(
            pasted: "ping the resonant team at substack.com.",
            edited: "ping the Resonant team at Substack"
        )
        XCTAssertTrue(signals.contains { $0.category == .wordCasing && $0.observedValue == "Resonant" })
        XCTAssertTrue(signals.contains { $0.category == .urlExpansionRevert && $0.observedValue == "Substack" })
    }

    func testPlainWordReplacementIsNotWordCasing() {
        // Different words (not case-insensitively equal) must not register.
        let signals = FormatCorrectionClassifier.classify(
            pasted: "the cat sat",
            edited: "the dog sat"
        )
        XCTAssertFalse(signals.contains { $0.category == .wordCasing })
    }
}
