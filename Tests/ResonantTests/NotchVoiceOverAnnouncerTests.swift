import AppKit
import XCTest
@testable import Resonant

@MainActor
final class NotchVoiceOverAnnouncerTests: XCTestCase {

    private final class Recorder {
        var messages: [String] = []
        var priorities: [NSAccessibilityPriorityLevel] = []
    }

    private func makeAnnouncer(
        recorder: Recorder,
        enabled: Bool = true,
        debounceInterval: TimeInterval = 2,
        clock: @escaping () -> Date = { Date(timeIntervalSince1970: 0) }
    ) -> VoiceOverAnnouncer {
        VoiceOverAnnouncer(
            debounceInterval: debounceInterval,
            isEnabled: { enabled },
            now: clock,
            poster: { message, priority in
                recorder.messages.append(message)
                recorder.priorities.append(priority)
            }
        )
    }

    // MARK: - Announcer

    func testAnnouncerNoOpsWhenVoiceOverDisabled() {
        let recorder = Recorder()
        let announcer = makeAnnouncer(recorder: recorder, enabled: false)

        announcer.announce("Recording")

        XCTAssertTrue(recorder.messages.isEmpty)
    }

    func testAnnouncerSkipsRepeatWithinDebounceWindow() {
        let recorder = Recorder()
        var now = Date(timeIntervalSince1970: 0)
        let announcer = makeAnnouncer(recorder: recorder, clock: { now })

        announcer.announce("Recording")
        now = now.addingTimeInterval(0.2)
        announcer.announce("Recording")

        XCTAssertEqual(recorder.messages, ["Recording"])

        // Same message again after the window is a genuine repeat, not flapping.
        now = now.addingTimeInterval(5)
        announcer.announce("Recording")

        XCTAssertEqual(recorder.messages, ["Recording", "Recording"])
    }

    func testAnnouncerIgnoresBlankMessages() {
        let recorder = Recorder()
        let announcer = makeAnnouncer(recorder: recorder)

        announcer.announce("   ")

        XCTAssertTrue(recorder.messages.isEmpty)
    }

    // MARK: - Coordinator wiring

    func testCoordinatorAnnouncesLifecycleTransitions() {
        let recorder = Recorder()
        let coordinator = NotchCoordinator()
        coordinator.voiceOverAnnouncer = makeAnnouncer(recorder: recorder)

        coordinator.setState(.recording(mode: .dictation, level: 0.2, elapsed: 0))
        // ~20 Hz level updates must not re-announce.
        coordinator.setState(.recording(mode: .dictation, level: 0.8, elapsed: 1))
        coordinator.setState(.processing(progress: 0.1, stage: "Transcribing…"))
        coordinator.setState(.processing(progress: 0.9, stage: "Cleaning up…"))
        coordinator.showDone("Delivered to Slack")
        coordinator.setState(.idle)

        XCTAssertEqual(recorder.messages, ["Recording", "Transcribing", "Delivered to Slack"])
    }

    func testCoordinatorAnnouncesErrorsAtHighPriority() {
        let recorder = Recorder()
        let coordinator = NotchCoordinator()
        coordinator.voiceOverAnnouncer = makeAnnouncer(recorder: recorder)

        coordinator.showError("Microphone unavailable", subtype: .microphone)

        XCTAssertEqual(recorder.messages, ["Microphone unavailable"])
        XCTAssertEqual(recorder.priorities, [.high])
    }

    func testAnnouncementTextIsSilentForNonSpeakingStates() {
        XCTAssertNil(NotchCoordinator.announcement(for: .idle))
        XCTAssertNil(NotchCoordinator.announcement(for: .hotMic(level: 0, liveText: "hello")))
        XCTAssertEqual(
            NotchCoordinator.announcement(for: .recording(mode: .memo, level: 0, elapsed: 0)),
            "Recording memo"
        )
    }
}
