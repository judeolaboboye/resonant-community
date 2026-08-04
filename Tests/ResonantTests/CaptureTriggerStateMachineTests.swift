import XCTest
@testable import Resonant

final class CaptureTriggerStateMachineTests: XCTestCase {
    func testCommandChordStartsOncePerChordAndEndsOnRelease() {
        var stateMachine = CaptureTriggerStateMachine()
        let configuration = commandConfiguration()

        XCTAssertEqual(
            stateMachine.handleCommandChord(
                functionDown: true,
                shiftDown: false,
                configuration: configuration
            ),
            .none
        )
        XCTAssertEqual(
            stateMachine.handleCommandChord(
                functionDown: true,
                shiftDown: true,
                configuration: configuration
            ),
            transition(action: .startOrToggleCommand, shouldCancelPendingHoldTrigger: true)
        )
        XCTAssertEqual(
            stateMachine.handleCommandChord(
                functionDown: true,
                shiftDown: true,
                configuration: configuration
            ),
            .none
        )
        XCTAssertEqual(
            stateMachine.handleCommandChord(
                functionDown: false,
                shiftDown: true,
                configuration: configuration
            ),
            transition(action: .endCommand)
        )
    }

    func testCommandChordSuppressesTriggerUntilReleased() {
        var stateMachine = CaptureTriggerStateMachine()
        let configuration = commandConfiguration()

        _ = stateMachine.handleCommandChord(
            functionDown: true,
            shiftDown: true,
            configuration: configuration
        )

        XCTAssertEqual(stateMachine.handleTriggerRefresh(isPressed: true), .suppressUntilReleased)

        _ = stateMachine.handleCommandChord(
            functionDown: false,
            shiftDown: true,
            configuration: configuration
        )

        XCTAssertEqual(stateMachine.handleTriggerRefresh(isPressed: true), .suppressUntilReleased)
        XCTAssertEqual(stateMachine.handleTriggerRefresh(isPressed: false), .accept)
        XCTAssertEqual(stateMachine.handleTriggerRefresh(isPressed: true), .accept)
    }

    func testCommandChordStateResetsWhenShortcutIsDisabled() {
        var stateMachine = CaptureTriggerStateMachine()
        let enabledConfiguration = commandConfiguration()
        let disabledConfiguration = commandConfiguration(hasCommandShortcut: false)

        _ = stateMachine.handleCommandChord(
            functionDown: true,
            shiftDown: true,
            configuration: enabledConfiguration
        )

        XCTAssertEqual(
            stateMachine.handleCommandChord(
                functionDown: true,
                shiftDown: true,
                configuration: disabledConfiguration
            ),
            .none
        )
        XCTAssertEqual(stateMachine.handleTriggerRefresh(isPressed: true), .accept)
        XCTAssertEqual(
            stateMachine.handleCommandChord(
                functionDown: false,
                shiftDown: false,
                configuration: enabledConfiguration
            ),
            .none
        )
    }

    func testHoldStartDelayOnlyAppliesToFnHoldDictationWithCommandShortcut() {
        let stateMachine = CaptureTriggerStateMachine()

        XCTAssertTrue(
            stateMachine.shouldDelayHoldStartForPossibleCommandChord(
                controlHeld: false,
                configuration: commandConfiguration()
            )
        )
        XCTAssertFalse(
            stateMachine.shouldDelayHoldStartForPossibleCommandChord(
                controlHeld: true,
                configuration: commandConfiguration()
            )
        )
        XCTAssertFalse(
            stateMachine.shouldDelayHoldStartForPossibleCommandChord(
                controlHeld: false,
                configuration: commandConfiguration(mode: .toggle)
            )
        )
        XCTAssertFalse(
            stateMachine.shouldDelayHoldStartForPossibleCommandChord(
                controlHeld: false,
                configuration: commandConfiguration(observesFnTrigger: false)
            )
        )
        XCTAssertFalse(
            stateMachine.shouldDelayHoldStartForPossibleCommandChord(
                controlHeld: false,
                configuration: commandConfiguration(hasCommandShortcut: false)
            )
        )
    }

    private func commandConfiguration(
        mode: HotkeyMode = .hold,
        observesFnTrigger: Bool = true,
        hasCommandShortcut: Bool = true
    ) -> CaptureTriggerStateMachine.Configuration {
        CaptureTriggerStateMachine.Configuration(
            mode: mode,
            observesFnTrigger: observesFnTrigger,
            hasCommandShortcut: hasCommandShortcut
        )
    }

    private func transition(
        action: CaptureTriggerStateMachine.CommandChordAction,
        shouldCancelPendingHoldTrigger: Bool = false
    ) -> CaptureTriggerStateMachine.CommandChordTransition {
        CaptureTriggerStateMachine.CommandChordTransition(
            action: action,
            shouldCancelPendingHoldTrigger: shouldCancelPendingHoldTrigger
        )
    }
}
