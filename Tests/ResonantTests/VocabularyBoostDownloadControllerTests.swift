import Foundation
import XCTest
@testable import Resonant

final class VocabularyBoostDownloadControllerTests: XCTestCase {
    @MainActor
    func testConcurrentManualRequestsStartOneDownload() async {
        let availability = LockedDownloadAvailability()
        let download = ControlledVocabularyDownload()
        let controller = VocabularyBoostDownloadController(
            isDownloaded: { availability.value },
            download: { try await download.run() }
        )

        let first = Task { @MainActor in await controller.startManualDownload() }
        let second = Task { @MainActor in await controller.startManualDownload() }
        await download.waitUntilStarted(1)
        let callCountWhileRunning = await download.callCount
        XCTAssertEqual(callCountWhileRunning, 1)

        availability.value = true
        await download.finishNext(with: .success(()))
        await first.value
        await second.value

        XCTAssertEqual(controller.state, .ready)
        XCTAssertNil(controller.failureDescription)
    }

    @MainActor
    func testReconciliationNeverStartsAHelperDownloadWithoutVisibleConsent() async {
        for isEligible in [false, true] {
            let download = ControlledVocabularyDownload()
            let controller = VocabularyBoostDownloadController(
                isDownloaded: { false },
                download: { try await download.run() }
            )

            await controller.reconcileAutomaticDownload(isEligible: isEligible)

            let callCount = await download.callCount
            XCTAssertEqual(callCount, 0)
            XCTAssertEqual(controller.state, .absent)
        }
    }

    @MainActor
    func testCurrentFailureWithInstalledFilesResolvesReadyWithoutRetryOrRedownload() async {
        let availability = LockedDownloadAvailability()
        let download = ControlledVocabularyDownload()
        let controller = VocabularyBoostDownloadController(
            isDownloaded: { availability.value },
            download: { try await download.run() }
        )

        let activeRun = Task { @MainActor in
            await controller.startManualDownload()
        }
        await download.waitUntilStarted(1)
        availability.value = true
        await download.finishNext(with: .failure(.secretRemoteMessage))
        await activeRun.value

        XCTAssertEqual(controller.state, .ready)
        XCTAssertNil(controller.state.recoveryAction)
        XCTAssertNil(controller.failureDescription)

        await controller.retry()
        await controller.reconcileAutomaticDownload(isEligible: true)
        let finalCallCount = await download.callCount
        XCTAssertEqual(finalCallCount, 1)
    }

    @MainActor
    func testLosingEligibilityDoesNotCancelDeliberateManualPrefetch() async {
        let availability = LockedDownloadAvailability()
        let download = ControlledVocabularyDownload()
        let controller = VocabularyBoostDownloadController(
            isDownloaded: { availability.value },
            download: { try await download.run() }
        )

        let manualRun = Task { @MainActor in await controller.startManualDownload() }
        await download.waitUntilStarted(1)

        await controller.reconcileAutomaticDownload(isEligible: false)
        XCTAssertEqual(controller.state, .downloading)

        availability.value = true
        await download.finishNext(with: .success(()))
        await manualRun.value
        XCTAssertEqual(controller.state, .ready)
    }

    @MainActor
    func testFailureIsBoundedAndExplicitRetryRecovers() async {
        let availability = LockedDownloadAvailability()
        let download = ControlledVocabularyDownload()
        let controller = VocabularyBoostDownloadController(
            isDownloaded: { availability.value },
            download: { try await download.run() }
        )

        let firstRun = Task { @MainActor in await controller.startManualDownload() }
        await download.waitUntilStarted(1)
        await download.finishNext(with: .failure(.secretRemoteMessage))
        await firstRun.value

        XCTAssertEqual(controller.state, .failed(.unknown))
        XCTAssertEqual(controller.failureDescription, VocabularyBoostHelperFailureCategory.unknown.detail)
        XCTAssertFalse(controller.failureDescription?.contains("SECRET_REMOTE_PAYLOAD") == true)

        // Merely re-resolving eligibility must never create network work.
        await controller.reconcileAutomaticDownload(isEligible: true)
        let callCountBeforeRetry = await download.callCount
        XCTAssertEqual(callCountBeforeRetry, 1)

        let retry = Task { @MainActor in await controller.retry() }
        await download.waitUntilStarted(2)
        availability.value = true
        await download.finishNext(with: .success(()))
        await retry.value

        let finalCallCount = await download.callCount
        XCTAssertEqual(finalCallCount, 2)
        XCTAssertEqual(controller.state, .ready)
        XCTAssertNil(controller.failureDescription)
    }

    @MainActor
    func testNetworkStorageIncompleteAndUnknownFailuresUseClosedCategories() async {
        let cases: [(name: String, error: Error, expected: VocabularyBoostHelperFailureCategory)] = [
            ("network", URLError(.notConnectedToInternet), .network),
            ("storage", CocoaError(.fileWriteOutOfSpace), .storage),
            ("unknown", ControlledVocabularyDownload.Failure.secretRemoteMessage, .unknown),
        ]

        for item in cases {
            let controller = VocabularyBoostDownloadController(
                isDownloaded: { false },
                download: { throw item.error }
            )
            await controller.startManualDownload()
            XCTAssertEqual(controller.state, .failed(item.expected), item.name)
            XCTAssertEqual(controller.failureDescription, item.expected.detail, item.name)
        }

        let incomplete = VocabularyBoostDownloadController(
            isDownloaded: { false },
            download: {}
        )
        await incomplete.startManualDownload()
        XCTAssertEqual(incomplete.state, .failed(.incomplete))
        XCTAssertEqual(
            incomplete.failureDescription,
            VocabularyBoostHelperFailureCategory.incomplete.detail
        )
    }
}

private final class LockedDownloadAvailability: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}

private actor ControlledVocabularyDownload {
    enum Failure: LocalizedError, Sendable {
        case secretRemoteMessage

        var errorDescription: String? { "SECRET_REMOTE_PAYLOAD" }
    }

    private(set) var callCount = 0
    private var startedCallCount = 0
    private var continuations: [
        Int: CheckedContinuation<Result<Void, Failure>, Never>
    ] = [:]
    private var startWaiters: [
        (
            expected: Int,
            continuation: CheckedContinuation<Void, Never>
        )
    ] = []

    func run() async throws {
        callCount += 1
        let callID = callCount
        let result = await withCheckedContinuation { continuation in
            continuations[callID] = continuation
            startedCallCount = max(startedCallCount, callID)
            let readyWaiters = startWaiters.filter {
                startedCallCount >= $0.expected
            }
            startWaiters.removeAll {
                startedCallCount >= $0.expected
            }
            for waiter in readyWaiters {
                waiter.continuation.resume()
            }
        }
        try result.get()
    }

    func waitUntilStarted(_ expected: Int) async {
        guard startedCallCount < expected else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append((expected, continuation))
        }
    }

    func finishNext(with result: Result<Void, Failure>) {
        guard let callID = continuations.keys.min() else { return }
        finish(call: callID, with: result)
    }

    func finish(call callID: Int, with result: Result<Void, Failure>) {
        continuations.removeValue(forKey: callID)?.resume(returning: result)
    }
}
