import XCTest
@testable import Resonant

/// Covers the number-formatting fixes: currency vs time disambiguation,
/// the unified currency style, percent policy, and casual-language guards.
final class ITNNumberFormattingTests: XCTestCase {

    private let processor = ITNProcessor()

    // MARK: - Currency beats time

    func testColloquialAmountBeforeDollarsIsNotATime() {
        XCTAssertEqual(
            processor.process("it cost two fifty dollars"),
            "it cost $250"
        )
    }

    func testPaymentVerbBeforeColloquialAmount() {
        XCTAssertEqual(
            processor.process("she paid two fifty for the shirt"),
            "she paid 250 for the shirt"
        )
    }

    func testRatePeriodAfterColloquialAmount() {
        XCTAssertEqual(
            processor.process("that runs about three fifty a month"),
            "that runs about 350 a month"
        )
    }

    func testColloquialAmountBeforePounds() {
        XCTAssertEqual(
            processor.process("one fifty pounds"),
            "150 pounds"
        )
    }

    func testTimeWithAmPmStillWinsOverCurrencyGuard() {
        XCTAssertEqual(
            processor.process("meet me at two fifty pm"),
            "meet me at 2:50 p.m."
        )
    }

    func testPlainTimeStillConverts() {
        XCTAssertEqual(
            processor.process("the meeting is at two fifty"),
            "the meeting is at 2:50"
        )
    }

    // MARK: - Unified currency style

    func testSpokenThousandDollarsGetsSymbol() {
        XCTAssertEqual(
            processor.process("five thousand dollars"),
            "$5,000"
        )
    }

    func testSpokenLargeAmountGetsSymbolAndGrouping() {
        XCTAssertEqual(
            processor.process("seventy five thousand dollars"),
            "$75,000"
        )
    }

    func testAndAHalfMillionDollars() {
        XCTAssertEqual(
            processor.process("two and a half million dollars"),
            "$2,500,000"
        )
    }

    func testMillionDollarsIsGrouped() {
        XCTAssertEqual(
            processor.process("a million dollars"),
            "$1,000,000"
        )
    }

    func testDigitHundredsDollarsIsGrouped() {
        XCTAssertEqual(
            processor.process("twenty five hundred dollars"),
            "$2,500"
        )
    }

    func testEuroAmountWithCentsMerges() {
        XCTAssertEqual(
            processor.process("fifty euros and twenty cents"),
            "€50.20"
        )
    }

    func testDollarsAndCentsStillMerge() {
        XCTAssertEqual(
            processor.process("five dollars and fifty cents"),
            "$5.50"
        )
    }

    func testQualifiedCurrencyStaysProse() {
        XCTAssertEqual(
            processor.process("it is 50 Australian dollars"),
            "it is 50 Australian dollars"
        )
    }

    func testBucksStayCasual() {
        XCTAssertEqual(
            processor.process("fifty bucks"),
            "50 bucks"
        )
    }

    // MARK: - Percent policy

    func testHalfAPercentBecomesDecimal() {
        XCTAssertEqual(
            processor.process("half a percent"),
            "0.5%"
        )
    }

    func testPercentConvertsWithAutoPunctuationDisabled() {
        XCTAssertEqual(
            processor.process("fifty percent of users", autoPunctuationEnabled: false),
            "50% of users"
        )
    }

    // MARK: - Casual language guards

    func testCoinQuartersStayProse() {
        XCTAssertEqual(
            processor.process("I found two quarters in the couch"),
            "I found 2 quarters in the couch"
        )
    }

    func testCoupleHundredStaysProse() {
        XCTAssertEqual(
            processor.process("a couple hundred people"),
            "a couple hundred people"
        )
    }

    func testFewThousandStaysProse() {
        XCTAssertEqual(
            processor.process("a few thousand requests"),
            "a few thousand requests"
        )
    }

    func testThreeQuartersStillConverts() {
        XCTAssertEqual(
            processor.process("three quarters of the work"),
            "3/4 of the work"
        )
    }
}

/// Golden corpus of realistic dictation sentences plus pipeline-wide
/// properties. Example tests miss cross-rule interference; every historical
/// formatting bug came from two passes interacting.
final class ITNGoldenCorpusTests: XCTestCase {

    private let processor = ITNProcessor()

    private static let corpus: [(input: String, expected: String)] = [
        ("the total comes to five thousand dollars", "the total comes to $5,000"),
        ("it cost two fifty dollars after tax", "it cost $250 after tax"),
        ("rent went up to three eighty five a month", "rent went up to 385 a month"),
        ("we closed at two and a half million dollars", "we closed at $2,500,000"),
        ("conversion improved by two point five percent", "conversion improved by 2.5%"),
        ("ninety nine percent of requests", "99% of requests"),
        ("fees dropped half a percent", "fees dropped 0.5%"),
        ("the meeting is at ten fifteen am", "the meeting is at 10:15 a.m."),
        ("launch slipped to twenty twenty six", "launch slipped to 2026"),
        ("two thirds of the team agreed", "2/3 of the team agreed"),
        ("it took two and a half hours", "it took 2.5 hours"),
        ("the deadline is the fifth of january", "the deadline is the 5th of january"),
        ("call one two three one two three five six seven eight", "call 123-123-5678"),
        ("we are available twenty four seven", "we are available 24/7"),
        ("the room is four m by two m", "the room is 4 m × 2 m"),
        ("about sixteen square meters", "about 16 m²"),
        ("he sent five grand", "he sent $5k"),
        ("a couple hundred people showed up", "a couple hundred people showed up"),
        ("the budget is seventy five thousand", "the budget is 75,000"),
        ("privacy first is the rule", "privacy first is the rule"),
        ("the room number is twenty six seventy seven", "the room number is 2677"),
        ("we pay 120 5 euros", "we pay €125"),
        ("the quote came to 2000 and fifteen", "the quote came to 2015"),
        ("the quote was 2005 hundred", "the quote was 2500"),
    ]

    func testGoldenCorpus() {
        for (input, expected) in Self.corpus {
            XCTAssertEqual(
                processor.process(input),
                expected,
                "input: \(input)"
            )
        }
    }

    /// Formatted output run through the pipeline again must not change —
    /// reformatting on edit/replay would corrupt already-formatted text.
    func testIdempotenceOverCorpus() {
        for (input, _) in Self.corpus {
            let once = processor.process(input)
            XCTAssertEqual(
                processor.process(once),
                once,
                "not idempotent for: \(input)"
            )
        }
    }

    /// Protection placeholders must never survive to output.
    func testNoPlaceholderLeaksOverCorpus() {
        for (input, _) in Self.corpus {
            for autoPunctuation in [true, false] {
                let output = processor.process(input, autoPunctuationEnabled: autoPunctuation)
                XCTAssertFalse(
                    output.contains("__resonant"),
                    "placeholder leaked for: \(input) (autoPunct: \(autoPunctuation))"
                )
            }
        }
    }
}
