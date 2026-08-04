import XCTest
@testable import Resonant

final class NotchPresentationStateMachineTests: XCTestCase {
    func testPassiveRestoreDoesNotImmediatelyCollapseFreshError() {
        var machine = NotchPresentationStateMachine(minimumErrorVisibleSeconds: 2)
        let startedAt = Date(timeIntervalSince1970: 100)
        let error = NotchPresentationRequest(state: .error(message: "Paste failed", subtype: .paste))
        let passiveRestore = NotchPresentationRequest(state: .hotMic(level: 0, liveText: ""))

        guard case .display = machine.apply(error, current: .idle, now: startedAt) else {
            return XCTFail("Expected the error to display immediately")
        }

        let decision = machine.apply(
            passiveRestore,
            current: error.state,
            now: startedAt.addingTimeInterval(0.25)
        )

        guard case .deferUntil(let releaseDate) = decision else {
            return XCTFail("Expected passive state to defer while the error is fresh")
        }
        XCTAssertEqual(releaseDate, startedAt.addingTimeInterval(2))
        XCTAssertNil(machine.releaseDeferredRequestIfReady(
            current: error.state,
            now: startedAt.addingTimeInterval(1.5)
        ))
        XCTAssertEqual(
            machine.releaseDeferredRequestIfReady(
                current: error.state,
                now: startedAt.addingTimeInterval(2)
            )?.state,
            passiveRestore.state
        )
    }

    func testRecordingInterruptsFreshError() {
        var machine = NotchPresentationStateMachine(minimumErrorVisibleSeconds: 2)
        let startedAt = Date(timeIntervalSince1970: 100)
        let error = NotchPresentationRequest(state: .error(message: "Busy", subtype: .generic))
        let recording = NotchPresentationRequest(state: .recording(mode: .dictation, level: 0, elapsed: 0))

        _ = machine.apply(error, current: .idle, now: startedAt)
        let decision = machine.apply(
            recording,
            current: error.state,
            now: startedAt.addingTimeInterval(0.25)
        )

        guard case .display(let request) = decision else {
            return XCTFail("Expected recording to stay real-time")
        }
        XCTAssertEqual(request.state, recording.state)
    }

    func testNewErrorReplacesVisibleErrorImmediately() {
        var machine = NotchPresentationStateMachine(minimumErrorVisibleSeconds: 2)
        let startedAt = Date(timeIntervalSince1970: 100)
        let firstError = NotchPresentationRequest(state: .error(message: "Paste failed", subtype: .paste))
        let secondError = NotchPresentationRequest(state: .error(message: "Mic failed", subtype: .microphone))

        _ = machine.apply(firstError, current: .idle, now: startedAt)
        let decision = machine.apply(
            secondError,
            current: firstError.state,
            now: startedAt.addingTimeInterval(0.25)
        )

        guard case .display(let request) = decision else {
            return XCTFail("Expected newer error to replace older error")
        }
        XCTAssertEqual(request.state, secondError.state)
    }
}
