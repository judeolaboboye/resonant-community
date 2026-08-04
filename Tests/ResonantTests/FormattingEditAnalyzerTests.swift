import XCTest
@testable import Resonant

final class FormattingEditAnalyzerTests: XCTestCase {

    func testDetectsStrippedListMarkers() {
        let signals = FormattingEditAnalyzer.signals(
            pasted: "- Milk\n- Eggs\n- Bread",
            edited: "Milk, eggs, bread"
        )
        XCTAssertTrue(signals.strippedListMarkers)
        XCTAssertFalse(signals.addedListMarkers)
    }

    func testDetectsStrippedNumberedMarkers() {
        let signals = FormattingEditAnalyzer.signals(
            pasted: "1. Buy milk\n2. Call john",
            edited: "Buy milk\nCall john"
        )
        XCTAssertTrue(signals.strippedListMarkers)
    }

    func testDetectsAddedListMarkers() {
        let signals = FormattingEditAnalyzer.signals(
            pasted: "Milk\nEggs\nBread",
            edited: "- Milk\n- Eggs\n- Bread"
        )
        XCTAssertTrue(signals.addedListMarkers)
        XCTAssertFalse(signals.strippedListMarkers)
    }

    func testKeepingMarkersWhileEditingContentIsNotDirectionalEvidence() {
        let signals = FormattingEditAnalyzer.signals(
            pasted: "- Milk\n- Eggs",
            edited: "- Milk\n- Eggs\n- Bread"
        )
        XCTAssertFalse(signals.addedListMarkers)
        XCTAssertFalse(signals.strippedListMarkers)
    }

    func testFullRewriteDoesNotCountAsStrippedMarkers() {
        let signals = FormattingEditAnalyzer.signals(
            pasted: "- Milk\n- Eggs\n- Bread",
            edited: "completely different message about the meeting tomorrow"
        )
        XCTAssertFalse(signals.strippedListMarkers)
    }

    func testDetectsStrippedTrailingPeriod() {
        let signals = FormattingEditAnalyzer.signals(
            pasted: "Sounds good.",
            edited: "Sounds good"
        )
        XCTAssertTrue(signals.strippedTrailingPeriod)
        XCTAssertFalse(signals.addedTrailingPeriod)
    }

    func testDetectsAddedTrailingPeriod() {
        let signals = FormattingEditAnalyzer.signals(
            pasted: "Sounds good",
            edited: "Sounds good."
        )
        XCTAssertTrue(signals.addedTrailingPeriod)
        XCTAssertFalse(signals.strippedTrailingPeriod)
    }

    func testRejectsPeriodSignalWhenOtherContentChanged() {
        let signals = FormattingEditAnalyzer.signals(
            pasted: "Sounds good.",
            edited: "Sounds great"
        )
        XCTAssertFalse(signals.strippedTrailingPeriod)
        XCTAssertFalse(signals.addedTrailingPeriod)
    }

    func testEllipsisEditIsNotOrdinaryTrailingPeriodEvidence() {
        let signals = FormattingEditAnalyzer.signals(
            pasted: "Wait...",
            edited: "Wait.."
        )
        XCTAssertFalse(signals.strippedTrailingPeriod)
        XCTAssertFalse(signals.addedTrailingPeriod)
    }

    func testDetectsLowercasedOpening() {
        let signals = FormattingEditAnalyzer.signals(
            pasted: "Sounds good to me",
            edited: "sounds good to me"
        )
        XCTAssertTrue(signals.lowercasedOpening)
        XCTAssertFalse(signals.capitalizedOpening)
    }

    func testDetectsCapitalizedOpening() {
        let signals = FormattingEditAnalyzer.signals(
            pasted: "sounds good to me",
            edited: "Sounds good to me"
        )
        XCTAssertTrue(signals.capitalizedOpening)
        XCTAssertFalse(signals.lowercasedOpening)
    }

    func testNoSignalsOnIdenticalText() {
        XCTAssertTrue(
            FormattingEditAnalyzer.signals(
                pasted: "Sounds good.",
                edited: "Sounds good."
            ).isEmpty
        )
    }

    func testNoSignalsOnContentOnlyEdit() {
        XCTAssertTrue(
            FormattingEditAnalyzer.signals(
                pasted: "Send it to the whole team.",
                edited: "Send it to the design team."
            ).isEmpty
        )
    }
}
