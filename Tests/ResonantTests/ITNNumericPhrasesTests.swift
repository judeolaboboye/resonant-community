import XCTest
@testable import Resonant

final class ITNNumericPhrasesTests: XCTestCase {

    private let processor = ITNProcessor()

    // MARK: - Fractions

    func testConvertsSpokenFraction() {
        XCTAssertEqual(
            processor.process("two thirds of users upgraded"),
            "2/3 of users upgraded"
        )
    }

    func testConvertsThreeQuarters() {
        XCTAssertEqual(
            processor.process("three quarters of the budget is gone"),
            "3/4 of the budget is gone"
        )
    }

    func testConvertsOneHalf() {
        XCTAssertEqual(
            processor.process("one half of the room agreed"),
            "1/2 of the room agreed"
        )
    }

    func testPluralityMismatchStaysProse() {
        // "two third" is not a fraction phrase.
        let result = processor.process("the two third basemen")
        XCTAssertFalse(result.contains("2/3"), result)
    }

    func testTimeSpanQuartersStayProse() {
        let result = processor.process("revenue grew over the last three quarters")
        XCTAssertFalse(result.contains("3/4"), result)
    }

    func testFinanceFirstQuarterStaysProse() {
        let result = processor.process("first quarter earnings look strong")
        XCTAssertFalse(result.contains("1/4"), result)
    }

    func testSecondsNeverBecomeFractions() {
        let result = processor.process("wait two seconds before retrying")
        XCTAssertFalse(result.contains("2/"), result)
    }

    // MARK: - N and a half

    func testConvertsNumberAndAHalf() {
        XCTAssertEqual(
            processor.process("it took two and a half hours"),
            "it took 2.5 hours"
        )
    }

    func testHourAndAHalfStaysProse() {
        let result = processor.process("it took an hour and a half")
        XCTAssertTrue(result.contains("hour and a half"), result)
    }

    // MARK: - Date ordinals

    func testConvertsOrdinalOfMonth() {
        XCTAssertEqual(
            processor.process("schedule it for the fifth of january"),
            "schedule it for the 5th of january"
        )
    }

    func testConvertsCompoundOrdinalOfMonth() {
        XCTAssertEqual(
            processor.process("we ship on the twenty third of march"),
            "we ship on the 23rd of march"
        )
    }

    func testOrdinalWithoutMonthStaysProse() {
        let result = processor.process("she was the fifth of seven children")
        XCTAssertTrue(result.contains("fifth"), result)
    }

    // MARK: - Currency phrases

    func testConvertsGrandToCompactCurrency() {
        XCTAssertEqual(
            processor.process("the deck costs five grand"),
            "the deck costs $5k"
        )
    }

    func testGrandTotalStaysProse() {
        let result = processor.process("the grand total is 50")
        XCTAssertFalse(result.contains("$"), result)
    }

    func testGrandPianoStaysProse() {
        let result = processor.process("we moved 2 grand pianos")
        XCTAssertFalse(result.contains("$2k"), result)
    }

    func testConvertsEuros() {
        XCTAssertEqual(
            processor.process("the ticket costs fifty euros"),
            "the ticket costs €50"
        )
    }
}
