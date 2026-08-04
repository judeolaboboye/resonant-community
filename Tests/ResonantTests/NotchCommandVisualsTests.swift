import XCTest
@testable import Resonant

final class NotchCommandVisualsTests: XCTestCase {
    func testCommandModeHasAgentBadgeTheme() {
        let theme = originalModeTheme(for: "command")

        XCTAssertEqual(theme?.iconName, "point.3.connected.trianglepath.dotted")
        XCTAssertNotNil(theme)
    }

    @MainActor
    func testCommandListeningExposesAudioLevel() {
        let coordinator = NotchCoordinator()

        coordinator.setState(.command(stage: .listening(level: 0.42, elapsed: 1.5)))

        XCTAssertEqual(coordinator.audioLevel, 0.42, accuracy: 0.001)
        XCTAssertEqual(coordinator.recordingElapsed, 1.5, accuracy: 0.001)
    }

    @MainActor
    func testCommandThinkingExposesAgentStatus() {
        let coordinator = NotchCoordinator()

        coordinator.setState(.command(stage: .thinking(status: "Running agent command...")))

        XCTAssertTrue(coordinator.isCommandThinking)
        XCTAssertEqual(coordinator.modeLabel, "Running agent command...")
        XCTAssertGreaterThan(coordinator.preferredSize(for: .notch).height, currentClosedNotchSize().height)
    }

    @MainActor
    func testCommandActionPresentationUsesCompactStatusRow() {
        let coordinator = NotchCoordinator()
        let closedHeight = currentClosedNotchSize().height

        coordinator.setState(.command(stage: .listening(level: 0.2, elapsed: 0.4)))
        let listeningHeight = coordinator.preferredSize(for: .notch).height

        coordinator.setState(.command(stage: .thinking(status: "Running agent command...")))
        let actionHeight = coordinator.preferredSize(for: .notch).height

        XCTAssertEqual(listeningHeight, closedHeight + NotchSizes.minimalTextRowHeight, accuracy: 0.001)
        XCTAssertEqual(actionHeight, closedHeight + NotchSizes.minimalTextRowHeight, accuracy: 0.001)
    }

    @MainActor
    func testCommandFollowUpExposesStatusAndAudioLevel() {
        let coordinator = NotchCoordinator()

        coordinator.setState(.command(stage: .awaitingFollowUp(
            level: 0.31,
            elapsed: 2.0,
            status: "Listening for follow-up..."
        )))

        XCTAssertEqual(coordinator.modeLabel, "Listening for follow-up...")
        XCTAssertEqual(coordinator.audioLevel, 0.31, accuracy: 0.001)
        XCTAssertEqual(coordinator.recordingElapsed, 2.0, accuracy: 0.001)
    }

    @MainActor
    func testPasteSuccessStaysInsideClosedNotch() {
        let coordinator = NotchCoordinator()
        let closedHeight = currentClosedNotchSize().height

        coordinator.showDone("Pasted!")

        XCTAssertEqual(
            coordinator.preferredSize(for: .notch).height,
            closedHeight - 4,
            accuracy: 0.001
        )
        XCTAssertEqual(
            coordinator.preferredSize(for: .notch).width,
            currentClosedNotchSize().width,
            accuracy: 0.001
        )
    }

    @MainActor
    func testLocalModelReadyShowsTextBelowNotchAtCompactWidth() {
        let coordinator = NotchCoordinator()
        let closedSize = currentClosedNotchSize()

        coordinator.showDone("Local model ready")

        XCTAssertEqual(
            coordinator.preferredSize(for: .notch).height,
            closedSize.height + NotchSizes.minimalTextRowHeight,
            accuracy: 0.001
        )
        XCTAssertEqual(
            coordinator.preferredSize(for: .notch).width,
            NotchSizes.minimalStripWidth(for: closedSize),
            accuracy: 0.001
        )
        XCTAssertLessThan(coordinator.preferredSize(for: .notch).width, 460)
    }

    @MainActor
    func testTextBearingMinimalStatesReserveBelowNotchRow() {
        let coordinator = NotchCoordinator()
        let closedHeight = currentClosedNotchSize().height

        coordinator.isMeetingRecording = true
        XCTAssertEqual(
            coordinator.preferredSize(for: .notch).height,
            closedHeight + NotchSizes.minimalTextRowHeight,
            accuracy: 0.001
        )
        XCTAssertGreaterThanOrEqual(coordinator.preferredSize(for: .notch).width, 460)

        coordinator.isMeetingRecording = false
        coordinator.setState(.hotMic(level: 0.2, liveText: "captured hot mic text"))
        XCTAssertEqual(
            coordinator.preferredSize(for: .notch).height,
            closedHeight + NotchSizes.minimalTextRowHeight,
            accuracy: 0.001
        )
        XCTAssertGreaterThanOrEqual(coordinator.preferredSize(for: .notch).width, 460)
    }
}
