import XCTest
@testable import Resonant

final class SmartInsertionSpacingTests: XCTestCase {
    func testAddsSpaceAndPreservesCapitalizationWhenContinuingProse() {
        XCTAssertEqual(
            adjusted("World", textBeforeCursor: "Hello", continuesFromLastDelivery: true),
            " World"
        )
    }

    func testPreservesExistingSpaceWhenContinuingProse() {
        XCTAssertEqual(
            adjusted("World", textBeforeCursor: "Hello ", continuesFromLastDelivery: true),
            "World"
        )
    }

    func testLowercasesAfterCommaWhenContinuing() {
        XCTAssertEqual(
            adjusted("World", textBeforeCursor: "Hello, ", continuesFromLastDelivery: true),
            "world"
        )
    }

    func testCapitalizesAfterSentenceBoundaryWhenContinuing() {
        XCTAssertEqual(
            adjusted("world", textBeforeCursor: "Hello.\" ", continuesFromLastDelivery: true),
            "World"
        )
    }

    func testCapitalizesAtFieldStartWithoutContinuationSignal() {
        XCTAssertEqual(
            adjusted("hello", textBeforeCursor: nil, continuesFromLastDelivery: false),
            "Hello"
        )
    }

    func testDoesNotTrustCursorContextWithoutContinuationSignal() {
        XCTAssertEqual(
            adjusted("Hello team", textBeforeCursor: "Best,", continuesFromLastDelivery: false),
            "Hello team"
        )
    }

    func testIgnoresFormattingOnlyCursorContext() {
        XCTAssertEqual(
            adjusted("hello", textBeforeCursor: "\u{200B}", continuesFromLastDelivery: true),
            "Hello"
        )
    }

    func testAddsSpaceBeforeFormattingMarkerWhenContinuingProse() {
        XCTAssertEqual(
            adjusted("World", textBeforeCursor: "Hello\u{200B}", continuesFromLastDelivery: true),
            " World"
        )
    }

    func testCursorContextContinuesOnlyForMatchingTargetAndSuffix() {
        let target = SmartInsertionSpacing.Target(
            bundleID: "com.example.editor",
            windowTitle: "Draft",
            browserURL: nil
        )
        let lastDelivery = SmartInsertionSpacing.LastDelivery(
            deliveredText: "Hello",
            target: target
        )

        XCTAssertTrue(
            SmartInsertionSpacing.cursorContext(
                textBeforeCursor: "Draft: Hello",
                lastDelivery: lastDelivery,
                target: target
            ).continuesFromLastDelivery
        )
        XCTAssertFalse(
            SmartInsertionSpacing.cursorContext(
                textBeforeCursor: "Draft: Hello",
                lastDelivery: lastDelivery,
                target: SmartInsertionSpacing.Target(
                    bundleID: "com.example.editor",
                    windowTitle: "Other Draft",
                    browserURL: nil
                )
            ).continuesFromLastDelivery
        )
        XCTAssertFalse(
            SmartInsertionSpacing.cursorContext(
                textBeforeCursor: "Draft: Hell",
                lastDelivery: lastDelivery,
                target: target
            ).continuesFromLastDelivery
        )
    }

    private func adjusted(
        _ text: String,
        textBeforeCursor: String?,
        continuesFromLastDelivery: Bool
    ) -> String {
        SmartInsertionSpacing.adjustedText(
            text,
            context: SmartInsertionSpacing.CursorContext(
                textBeforeCursor: textBeforeCursor,
                continuesFromLastDelivery: continuesFromLastDelivery
            )
        )
    }
}
