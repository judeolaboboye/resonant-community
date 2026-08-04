import XCTest
@testable import Resonant

final class DispatchFollowUpWindowStateTests: XCTestCase {
    func testEmptyWindowClosesAfterOpenWindow() {
        let openedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        var window = DispatchFollowUpWindowState(
            openedAt: openedAt,
            openWindow: 5,
            trailingSilence: 1.2
        )

        let early = window.observe(level: 0.01, at: openedAt.addingTimeInterval(4.9))
        XCTAssertFalse(early.shouldFinish)
        XCTAssertEqual(early.status, DispatchFollowUpWindowState.waitingStatus)

        let expired = window.observe(level: 0.01, at: openedAt.addingTimeInterval(5.0))
        XCTAssertTrue(expired.shouldFinish)
        XCTAssertFalse(expired.observation.heardSpeech)

        let repeated = window.observe(level: 0.01, at: openedAt.addingTimeInterval(6.0))
        XCTAssertFalse(repeated.shouldFinish)
    }

    func testSpeechWindowStopsAfterTrailingSilence() {
        let openedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        var window = DispatchFollowUpWindowState(
            openedAt: openedAt,
            openWindow: 8,
            trailingSilence: 1.2
        )

        let speech = window.observe(level: 0.2, at: openedAt.addingTimeInterval(1.0))
        XCTAssertFalse(speech.shouldFinish)
        XCTAssertEqual(speech.status, DispatchFollowUpWindowState.activeStatus)
        XCTAssertEqual(speech.observation.firstSpeechAt, openedAt.addingTimeInterval(1.0))

        let duringSilence = window.observe(level: 0.01, at: openedAt.addingTimeInterval(2.1))
        XCTAssertFalse(duringSilence.shouldFinish)

        let finished = window.observe(level: 0.01, at: openedAt.addingTimeInterval(2.2))
        XCTAssertTrue(finished.shouldFinish)
        XCTAssertTrue(finished.observation.heardSpeech)
    }

    func testMaxDurationStopsEvenWhileSpeechContinues() {
        let openedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        var window = DispatchFollowUpWindowState(
            openedAt: openedAt,
            openWindow: 8,
            trailingSilence: 10,
            maxDuration: 3
        )

        XCTAssertFalse(window.observe(level: 0.2, at: openedAt.addingTimeInterval(1)).shouldFinish)
        XCTAssertFalse(window.observe(level: 0.2, at: openedAt.addingTimeInterval(2)).shouldFinish)
        XCTAssertTrue(window.observe(level: 0.2, at: openedAt.addingTimeInterval(3)).shouldFinish)
    }

    func testSpeechTurnMetricsClampMinimums() {
        let firstSpeechAt = Date(timeIntervalSinceReferenceDate: 1_000)
        var window = DispatchFollowUpWindowState(
            openedAt: firstSpeechAt,
            openWindow: 8,
            trailingSilence: 1.2
        )

        let update = window.observe(level: 0.2, at: firstSpeechAt)
        let speechTurn = update.observation.speechTurn(completedAt: firstSpeechAt.addingTimeInterval(0.1))

        XCTAssertEqual(speechTurn?.utteranceDuration, 0.4)
        XCTAssertEqual(speechTurn?.trailingSilence, 0.5)
    }
}
