import XCTest
@testable import Resonant

final class EventTapSupportTests: XCTestCase {

    // MARK: - EventTapReenableBackoff

    func testFirstTimeoutReenablesImmediately() {
        var backoff = EventTapReenableBackoff()
        XCTAssertEqual(backoff.recordTimeout(at: Date(timeIntervalSinceReferenceDate: 0)), 0)
    }

    func testRepeatedTimeoutsBackOffExponentiallyUpToCap() {
        var backoff = EventTapReenableBackoff()
        let base = Date(timeIntervalSinceReferenceDate: 0)

        XCTAssertEqual(backoff.recordTimeout(at: base), 0)
        XCTAssertEqual(backoff.recordTimeout(at: base.addingTimeInterval(1)), 0.5)
        XCTAssertEqual(backoff.recordTimeout(at: base.addingTimeInterval(2)), 1)
        XCTAssertEqual(backoff.recordTimeout(at: base.addingTimeInterval(3)), 2)
        XCTAssertEqual(backoff.recordTimeout(at: base.addingTimeInterval(4)), 4)
        XCTAssertEqual(backoff.recordTimeout(at: base.addingTimeInterval(5)), 4)
    }

    func testQuietPeriodResetsBackoff() {
        var backoff = EventTapReenableBackoff()
        let base = Date(timeIntervalSinceReferenceDate: 0)

        XCTAssertEqual(backoff.recordTimeout(at: base), 0)
        XCTAssertEqual(backoff.recordTimeout(at: base.addingTimeInterval(1)), 0.5)

        let afterQuiet = base.addingTimeInterval(1 + EventTapReenableBackoff.resetInterval + 1)
        XCTAssertEqual(backoff.recordTimeout(at: afterQuiet), 0)
        XCTAssertEqual(backoff.consecutiveTimeouts, 1)
    }

    func testTimeoutsWithinResetIntervalKeepEscalating() {
        var backoff = EventTapReenableBackoff()
        let base = Date(timeIntervalSinceReferenceDate: 0)

        XCTAssertEqual(backoff.recordTimeout(at: base), 0)
        let justInside = base.addingTimeInterval(EventTapReenableBackoff.resetInterval - 1)
        XCTAssertEqual(backoff.recordTimeout(at: justInside), 0.5)
        XCTAssertEqual(backoff.consecutiveTimeouts, 2)
    }

    // MARK: - InputRunLoopThread

    func testPerformSyncRunsBlockOnInputThread() {
        let runLoopThread = InputRunLoopThread(name: "test.input-runloop")
        var ranOnMain: Bool?
        let completed = runLoopThread.performSync { _ in
            ranOnMain = Thread.isMainThread
        }
        XCTAssertTrue(completed)
        XCTAssertEqual(ranOnMain, false)
        runLoopThread.stop()
    }

    func testStopIsReentrantSafe() {
        let runLoopThread = InputRunLoopThread(name: "test.input-runloop-stop")
        runLoopThread.performSync { _ in }
        runLoopThread.stop()
        runLoopThread.stop()

        // Restartable after stop.
        XCTAssertTrue(runLoopThread.performSync { _ in })
        runLoopThread.stop()
    }
}
