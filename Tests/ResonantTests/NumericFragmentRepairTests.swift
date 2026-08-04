import XCTest
@testable import Resonant

final class NumericFragmentRepairTests: XCTestCase {

    func testRepairsFragmentedPaddedDollarAmount() {
        XCTAssertEqual(
            NumericFragmentRepair.repair("otherwise we pay 120 5 dollars"),
            "otherwise we pay $125"
        )
    }

    func testRepairsFragmentedTensDollarAmount() {
        XCTAssertEqual(
            NumericFragmentRepair.repair("it costs 20 5 dollars"),
            "it costs $25"
        )
    }

    func testRepairsGroupedPaddedDollarAmount() {
        XCTAssertEqual(
            NumericFragmentRepair.repair("the invoice is 1,200 5 dollars"),
            "the invoice is $1205"
        )
    }

    func testLeavesUnanchoredDigitFragmentsAlone() {
        XCTAssertEqual(
            NumericFragmentRepair.repair("call 120 5"),
            "call 120 5"
        )
    }

    func testLeavesTimesAlone() {
        XCTAssertEqual(
            NumericFragmentRepair.repair("meet at 10 15 pm"),
            "meet at 10 15 pm"
        )
    }

    func testLeavesIssueIdsAlone() {
        XCTAssertEqual(
            NumericFragmentRepair.repair("issue 120 5 is next"),
            "issue 120 5 is next"
        )
    }

    func testLeavesAddressesAlone() {
        XCTAssertEqual(
            NumericFragmentRepair.repair("send it to 120 5 Main Street"),
            "send it to 120 5 Main Street"
        )
    }

    func testLeavesProductNamesAlone() {
        XCTAssertEqual(
            NumericFragmentRepair.repair("Microsoft 365 is installed"),
            "Microsoft 365 is installed"
        )
    }
}
