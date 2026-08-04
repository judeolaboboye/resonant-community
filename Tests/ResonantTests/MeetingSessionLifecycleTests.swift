import XCTest
@testable import Resonant

final class MeetingSessionLifecycleTests: XCTestCase {
    func testStartingAndRecordingStateGatesNewSessions() {
        var lifecycle = MeetingSessionLifecycle()
        let session = makeSessionInfo()

        XCTAssertTrue(lifecycle.beginStartingSession())
        XCTAssertTrue(lifecycle.isStartingSession)
        XCTAssertFalse(lifecycle.canStartSession)
        XCTAssertFalse(lifecycle.beginStartingSession())
        XCTAssertFalse(lifecycle.beginImport())

        lifecycle.markRecordingStarted(session)

        XCTAssertTrue(lifecycle.isRecording)
        XCTAssertEqual(lifecycle.activeSession?.id, session.id)
        XCTAssertEqual(lifecycle.recordingStartedAt, session.startedAt)
        XCTAssertFalse(lifecycle.canStartSession)
        XCTAssertFalse(lifecycle.canImportAudio)

        lifecycle.finishStartingSession()

        XCTAssertFalse(lifecycle.isStartingSession)
        XCTAssertTrue(lifecycle.isRecording)
    }

    func testEndingKeepsFinalizingUntilCallerCompletesCallbackWindow() {
        var lifecycle = MeetingSessionLifecycle()
        let session = makeSessionInfo()
        lifecycle.markRecordingStarted(session)

        let endingSession = lifecycle.beginEndingSession()

        XCTAssertEqual(endingSession?.id, session.id)
        XCTAssertFalse(lifecycle.isRecording)
        XCTAssertTrue(lifecycle.isFinalizing)
        XCTAssertEqual(lifecycle.activeSession?.id, session.id)

        lifecycle.detachFinalizedSession()

        XCTAssertNil(lifecycle.activeSession)
        XCTAssertNil(lifecycle.recordingStartedAt)
        XCTAssertTrue(lifecycle.isFinalizing)
        XCTAssertFalse(lifecycle.canStartSession)

        lifecycle.finishFinalizingSession()

        XCTAssertFalse(lifecycle.isFinalizing)
        XCTAssertTrue(lifecycle.canStartSession)
    }

    func testDiscardResetsToIdle() {
        var lifecycle = MeetingSessionLifecycle()
        let session = makeSessionInfo()
        lifecycle.markRecordingStarted(session)

        let discardedSession = lifecycle.beginDiscardingSession()
        lifecycle.finishDiscardingSession()

        XCTAssertEqual(discardedSession?.id, session.id)
        XCTAssertFalse(lifecycle.isRecording)
        XCTAssertFalse(lifecycle.isFinalizing)
        XCTAssertFalse(lifecycle.isStartingSession)
        XCTAssertNil(lifecycle.activeSession)
        XCTAssertNil(lifecycle.recordingStartedAt)
        XCTAssertTrue(lifecycle.canStartSession)
    }

    func testImportUsesFinalizingGateWithoutCreatingActiveSession() {
        var lifecycle = MeetingSessionLifecycle()

        XCTAssertTrue(lifecycle.beginImport())
        XCTAssertTrue(lifecycle.isFinalizing)
        XCTAssertFalse(lifecycle.isRecording)
        XCTAssertNil(lifecycle.activeSession)
        XCTAssertFalse(lifecycle.canStartSession)
        XCTAssertFalse(lifecycle.beginImport())

        lifecycle.finishImport()

        XCTAssertFalse(lifecycle.isFinalizing)
        XCTAssertTrue(lifecycle.canImportAudio)
        XCTAssertTrue(lifecycle.canStartSession)
    }

    func testImportGateCanCoverSessionEndedCallbackWindow() async {
        var lifecycle = MeetingSessionLifecycle()
        XCTAssertTrue(lifecycle.beginImport())

        var callbackObservedBlockedStart = false
        await simulateSessionEndedCallback {
            callbackObservedBlockedStart = !lifecycle.canStartSession && !lifecycle.canImportAudio
        }

        XCTAssertTrue(callbackObservedBlockedStart)

        lifecycle.finishImport()

        XCTAssertFalse(lifecycle.isFinalizing)
        XCTAssertTrue(lifecycle.canStartSession)
    }

    func testClearInconsistentSessionClearsStaleActiveSession() {
        var lifecycle = MeetingSessionLifecycle()
        let session = makeSessionInfo()
        lifecycle.markRecordingStarted(session)

        lifecycle.clearInconsistentSession()

        XCTAssertFalse(lifecycle.isRecording)
        XCTAssertFalse(lifecycle.isFinalizing)
        XCTAssertNil(lifecycle.activeSession)
        XCTAssertNil(lifecycle.recordingStartedAt)
    }

    func testRebindActiveSessionNormalizesTitlePriority() {
        var lifecycle = MeetingSessionLifecycle()
        let session = makeSessionInfo(suggestedTitle: "Original")
        lifecycle.markRecordingStarted(session)

        let calendarContext = MeetingCaptureContext.adHoc(
            title: "  Calendar Sync  ",
            recordingOrigin: .rebound
        )
        let reboundSession = lifecycle.rebindActiveSession(
            to: calendarContext,
            suggestedTitle: "   "
        )

        XCTAssertEqual(reboundSession?.suggestedTitle, "Calendar Sync")
        XCTAssertEqual(lifecycle.activeSession?.captureContext?.recordingOrigin, .rebound)

        let manualContext = MeetingCaptureContext.adHoc(
            title: "Calendar Fallback",
            recordingOrigin: .manual
        )
        let manualSession = lifecycle.rebindActiveSession(
            to: manualContext,
            suggestedTitle: "  Manual Override  "
        )

        XCTAssertEqual(manualSession?.suggestedTitle, "Manual Override")
        XCTAssertEqual(lifecycle.activeSession?.suggestedTitle, "Manual Override")
    }

    private func makeSessionInfo(
        id: UUID = UUID(),
        startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        suggestedTitle: String? = nil,
        captureContext: MeetingCaptureContext? = nil
    ) -> MeetingSessionInfo {
        MeetingSessionInfo(
            id: id,
            startedAt: startedAt,
            detectedApp: MeetingApp(bundleID: "com.example.meet", name: "Example Meet"),
            suggestedTitle: suggestedTitle,
            captureContext: captureContext,
            captureMode: .onlineCall,
            transcriptionBackendAtStart: "parakeet",
            jsonlRelativePath: "meetings-active/\(id.uuidString).jsonl",
            jsonlURL: URL(fileURLWithPath: "/tmp/\(id.uuidString).jsonl")
        )
    }

    private func simulateSessionEndedCallback(_ body: () -> Void) async {
        body()
    }
}
