import XCTest
@testable import Resonant

final class DictationModelReadinessPolicyTests: XCTestCase {

    // MARK: - Start disposition

    func testLoadedModelProceeds() {
        XCTAssertEqual(
            DictationModelReadinessPolicy.startDisposition(
                hasActiveModel: true,
                isLoaded: true,
                isDownloaded: true,
                preparationState: .ready
            ),
            .proceed
        )
    }

    func testLoadingModelProceedsWithoutKickingPreparation() {
        XCTAssertEqual(
            DictationModelReadinessPolicy.startDisposition(
                hasActiveModel: true,
                isLoaded: false,
                isDownloaded: true,
                preparationState: .loading
            ),
            .proceed
        )
    }

    func testDownloadedIdleModelProceedsAndPrepares() {
        XCTAssertEqual(
            DictationModelReadinessPolicy.startDisposition(
                hasActiveModel: true,
                isLoaded: false,
                isDownloaded: true,
                preparationState: .idle
            ),
            .proceedAndPrepare
        )
    }

    func testPostSelectReadyRaceWithUnloadedModelRePrepares() {
        // select() can leave preparationState == .ready while the adapter is
        // not actually loaded — treat like idle-with-files.
        XCTAssertEqual(
            DictationModelReadinessPolicy.startDisposition(
                hasActiveModel: true,
                isLoaded: false,
                isDownloaded: true,
                preparationState: .ready
            ),
            .proceedAndPrepare
        )
    }

    func testMidDownloadRejects() {
        XCTAssertEqual(
            DictationModelReadinessPolicy.startDisposition(
                hasActiveModel: true,
                isLoaded: false,
                isDownloaded: false,
                preparationState: .downloading(progress: 0.4)
            ),
            .reject
        )
    }

    func testFailedPreparationRejects() {
        XCTAssertEqual(
            DictationModelReadinessPolicy.startDisposition(
                hasActiveModel: true,
                isLoaded: false,
                isDownloaded: true,
                preparationState: .failed(message: "boom")
            ),
            .reject
        )
    }

    func testMissingFilesRejects() {
        XCTAssertEqual(
            DictationModelReadinessPolicy.startDisposition(
                hasActiveModel: true,
                isLoaded: false,
                isDownloaded: false,
                preparationState: .idle
            ),
            .reject
        )
    }

    func testNoActiveModelRejects() {
        XCTAssertEqual(
            DictationModelReadinessPolicy.startDisposition(
                hasActiveModel: false,
                isLoaded: false,
                isDownloaded: false,
                preparationState: .idle
            ),
            .reject
        )
    }

    // MARK: - Stop-time wait predicate

    func testWaitsWhileUnloadedAndPreparingBeforeDeadline() {
        let now = Date()
        XCTAssertTrue(
            DictationModelReadinessPolicy.shouldKeepWaiting(
                isLoaded: false,
                isPreparing: true,
                now: now,
                deadline: now.addingTimeInterval(5)
            )
        )
    }

    func testStopsWaitingOnceLoaded() {
        let now = Date()
        XCTAssertFalse(
            DictationModelReadinessPolicy.shouldKeepWaiting(
                isLoaded: true,
                isPreparing: true,
                now: now,
                deadline: now.addingTimeInterval(5)
            )
        )
    }

    func testStopsWaitingWhenNothingIsPreparing() {
        // The transcriber's own self-load takes over — waiting would only
        // race a load that isn't happening.
        let now = Date()
        XCTAssertFalse(
            DictationModelReadinessPolicy.shouldKeepWaiting(
                isLoaded: false,
                isPreparing: false,
                now: now,
                deadline: now.addingTimeInterval(5)
            )
        )
    }

    func testStopsWaitingAtDeadline() {
        let now = Date()
        XCTAssertFalse(
            DictationModelReadinessPolicy.shouldKeepWaiting(
                isLoaded: false,
                isPreparing: true,
                now: now,
                deadline: now
            )
        )
    }
}
