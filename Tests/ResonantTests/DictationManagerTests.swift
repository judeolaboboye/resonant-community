import XCTest
@testable import Resonant

@MainActor
final class DictationManagerTests: XCTestCase {

    func testResolvedSelectionFallsBackToEarlySnapshotWhenLiveSelectionDisappears() {
        let fallbackRange = SelectionRange(location: 12, length: 5)

        let resolved = DictationManager.resolvedSelection(
            liveText: nil,
            liveRange: nil,
            fallbackText: "hello",
            fallbackRange: fallbackRange
        )

        XCTAssertEqual(resolved.selectedText, "hello")
        XCTAssertEqual(resolved.selectedRange, fallbackRange)
    }

    func testResolvedSelectionReusesFallbackRangeWhenLiveTextMatchesButRangeIsMissing() {
        let fallbackRange = SelectionRange(location: 4, length: 6)

        let resolved = DictationManager.resolvedSelection(
            liveText: "selected text",
            liveRange: nil,
            fallbackText: "selected text",
            fallbackRange: fallbackRange
        )

        XCTAssertEqual(resolved.selectedText, "selected text")
        XCTAssertEqual(resolved.selectedRange, fallbackRange)
    }

    func testResolvedSelectionDoesNotReuseFallbackRangeForDifferentLiveSelection() {
        let fallbackRange = SelectionRange(location: 4, length: 6)

        let resolved = DictationManager.resolvedSelection(
            liveText: "new selection",
            liveRange: nil,
            fallbackText: "old selection",
            fallbackRange: fallbackRange
        )

        XCTAssertEqual(resolved.selectedText, "new selection")
        XCTAssertNil(resolved.selectedRange)
    }
}
