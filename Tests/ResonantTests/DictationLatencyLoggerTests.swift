import XCTest
@testable import Resonant

@MainActor
final class DictationLatencyLoggerTests: XCTestCase {

    func testFinishMeasuresThroughTerminalFailureAfterLastStageMark() {
        var now = ContinuousClock.now
        let logger = DictationLatencyLogger(targetBundleId: nil, now: { now })

        now = now.advanced(by: .milliseconds(120))
        logger.mark("txStart")
        now = now.advanced(by: .milliseconds(80))
        logger.mark("txEnd")
        now = now.advanced(by: .milliseconds(650))

        let event = logger.finish(outcome: "failure")

        XCTAssertEqual(event.transcriptionMs, 80)
        XCTAssertEqual(event.totalMs, 850)
        XCTAssertEqual(event.outcome, "failure")
    }

    func testFinishIsIdempotentAndKeepsFirstTerminalOutcome() {
        var now = ContinuousClock.now
        let logger = DictationLatencyLogger(targetBundleId: nil, now: { now })
        now = now.advanced(by: .milliseconds(40))
        let first = logger.finish(outcome: "cancelled")
        now = now.advanced(by: .seconds(1))
        let second = logger.finish(outcome: "success")

        XCTAssertEqual(first, second)
        XCTAssertEqual(second.totalMs, 40)
        XCTAssertEqual(second.outcome, "cancelled")
    }
}
