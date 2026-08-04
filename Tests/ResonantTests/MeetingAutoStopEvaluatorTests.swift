import XCTest
@testable import Resonant

@MainActor
final class MeetingAutoStopEvaluatorTests: XCTestCase {

    func testStrongLifecycleEndStopsImmediately() {
        let snapshot = makeSnapshot(
            lifecycleSignal: .strongEndSignal,
            cameraActive: true,
            secondsSinceLastUtterance: 2
        )

        XCTAssertEqual(
            MeetingAutoStopEvaluator.evaluate(snapshot),
            .stop(.strongLifecycleEnd)
        )
    }

    func testActiveLifecycleKeepsRecordingEvenWhenRuntimeIsQuiet() {
        let snapshot = makeSnapshot(
            lifecycleSignal: .active(meeting()),
            cameraActive: false,
            secondsSinceLastUtterance: 180,
            recordingDuration: 300
        )

        XCTAssertEqual(MeetingAutoStopEvaluator.evaluate(snapshot), .keepRecording)
    }

    func testWeakEndWithQuietRuntimeEntersPendingStop() {
        let snapshot = makeSnapshot(
            lifecycleSignal: .weakEndSignal,
            cameraActive: false,
            secondsSinceLastUtterance: 120,
            recordingDuration: 300
        )

        XCTAssertEqual(
            MeetingAutoStopEvaluator.evaluate(snapshot),
            .pendingStop(.weakLifecycleInactivity)
        )
    }

    func testPendingWeakEndStopsAfterGrace() {
        let now = Date(timeIntervalSince1970: 1_000)
        let snapshot = makeSnapshot(
            lifecycleSignal: .weakEndSignal,
            cameraActive: false,
            secondsSinceLastUtterance: 120,
            recordingDuration: 300,
            pendingStopStartedAt: now.addingTimeInterval(-MeetingAutoStopEvaluator.pendingStopGrace),
            now: now
        )

        XCTAssertEqual(
            MeetingAutoStopEvaluator.evaluate(snapshot),
            .stop(.weakLifecycleInactivity)
        )
    }

    func testRecentUtteranceCancelsWeakEndStop() {
        let snapshot = makeSnapshot(
            lifecycleSignal: .weakEndSignal,
            cameraActive: false,
            secondsSinceLastUtterance: 20,
            recordingDuration: 300
        )

        XCTAssertEqual(MeetingAutoStopEvaluator.evaluate(snapshot), .keepRecording)
    }

    func testWeakEndWithoutFirstUtteranceDoesNotStopFromRecordingDuration() {
        let snapshot = makeSnapshot(
            lifecycleSignal: .weakEndSignal,
            cameraActive: false,
            secondsSinceLastUtterance: nil,
            recordingDuration: MeetingAutoStopEvaluator.speechInactivityGrace + 30
        )

        XCTAssertEqual(MeetingAutoStopEvaluator.evaluate(snapshot), .keepRecording)
    }

    func testCameraActivityCancelsWeakEndStop() {
        let snapshot = makeSnapshot(
            lifecycleSignal: .weakEndSignal,
            cameraActive: true,
            secondsSinceLastUtterance: 180,
            recordingDuration: 300
        )

        XCTAssertEqual(MeetingAutoStopEvaluator.evaluate(snapshot), .keepRecording)
    }

    func testCalendarPastEndWithoutFirstUtteranceDoesNotStopFromRecordingDuration() {
        let snapshot = makeSnapshot(
            lifecycleSignal: .ambiguous,
            cameraActive: false,
            secondsSinceLastUtterance: nil,
            recordingDuration: MeetingAutoStopEvaluator.speechInactivityGrace + 30,
            calendarPastEndGrace: true
        )

        XCTAssertEqual(MeetingAutoStopEvaluator.evaluate(snapshot), .keepRecording)
    }

    func testCalendarPastEndCanEnterPendingStopFromAmbiguousLifecycle() {
        let snapshot = makeSnapshot(
            lifecycleSignal: .ambiguous,
            cameraActive: false,
            secondsSinceLastUtterance: 180,
            recordingDuration: 300,
            calendarPastEndGrace: true
        )

        XCTAssertEqual(
            MeetingAutoStopEvaluator.evaluate(snapshot),
            .pendingStop(.calendarInactivity)
        )
    }

    private func makeSnapshot(
        lifecycleSignal: MeetingContextDetector.LifecycleSignal,
        cameraActive: Bool = false,
        systemAudioSilent: Bool = false,
        secondsSinceLastUtterance: TimeInterval? = nil,
        recordingDuration: TimeInterval = 0,
        calendarPastEndGrace: Bool = false,
        pendingStopStartedAt: Date? = nil,
        now: Date = Date(timeIntervalSince1970: 1_000)
    ) -> MeetingAutoStopEvaluator.Snapshot {
        MeetingAutoStopEvaluator.Snapshot(
            lifecycleSignal: lifecycleSignal,
            cameraActive: cameraActive,
            systemAudioSilent: systemAudioSilent,
            secondsSinceLastUtterance: secondsSinceLastUtterance,
            recordingDuration: recordingDuration,
            calendarPastEndGrace: calendarPastEndGrace,
            pendingStopStartedAt: pendingStopStartedAt,
            now: now
        )
    }

    private func meeting() -> MeetingContextDetector.DetectedMeeting {
        MeetingContextDetector.DetectedMeeting(
            app: MeetingApp(bundleID: "us.zoom.xos", name: "Zoom"),
            windowTitle: "Weekly sync",
            browserURL: nil,
            calendarHint: nil,
            autoStartEligible: true
        )
    }
}
