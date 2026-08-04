import XCTest
@testable import Resonant

@MainActor
final class NotchRecordingLiveTextTests: XCTestCase {

    func testRecordingLiveTextClearsWhenRecordingEnds() {
        let coordinator = NotchCoordinator()
        coordinator.setState(.recording(mode: .dictation, level: 0.4, elapsed: 1))
        coordinator.recordingLiveText = "hello world"

        coordinator.setState(.processing(progress: 0, stage: "Transcribing…"))

        XCTAssertNil(coordinator.recordingLiveText)
    }

    func testRecordingLiveTextSurvivesRecordingStateUpdates() {
        // Audio-level updates re-set the .recording state ~20 Hz; live text
        // must persist across them or the preview would flicker.
        let coordinator = NotchCoordinator()
        coordinator.setState(.recording(mode: .dictation, level: 0.2, elapsed: 1))
        coordinator.recordingLiveText = "hello"

        coordinator.setState(.recording(mode: .dictation, level: 0.6, elapsed: 2))

        XCTAssertEqual(coordinator.recordingLiveText, "hello")
    }
}
