import Foundation

/// Pure trigger transition state extracted from HotkeyManager.
///
/// This is intentionally small for now: it owns the fn+shift command chord
/// state and the related trigger suppression policy while OS event capture
/// remains in HotkeyManager.
struct CaptureTriggerStateMachine {
    struct Configuration: Equatable {
        var mode: HotkeyMode
        var observesFnTrigger: Bool
        var hasCommandShortcut: Bool
    }

    enum CommandChordAction: Equatable {
        case startOrToggleCommand
        case endCommand
    }

    struct CommandChordTransition: Equatable {
        var action: CommandChordAction?
        var shouldCancelPendingHoldTrigger: Bool

        static let none = CommandChordTransition(
            action: nil,
            shouldCancelPendingHoldTrigger: false
        )
    }

    enum TriggerRefreshDecision: Equatable {
        case accept
        case suppressUntilReleased
    }

    private var commandChordDown = false
    private var commandChordStartedCommand = false
    private var suppressTriggerUntilReleased = false

    mutating func reset() {
        commandChordDown = false
        commandChordStartedCommand = false
        suppressTriggerUntilReleased = false
    }

    mutating func handleCommandChord(
        functionDown: Bool,
        shiftDown: Bool,
        configuration: Configuration
    ) -> CommandChordTransition {
        guard configuration.hasCommandShortcut else {
            reset()
            return .none
        }

        let isPressed = functionDown && shiftDown
        if isPressed {
            guard !commandChordDown else { return .none }
            commandChordDown = true
            commandChordStartedCommand = true
            suppressTriggerUntilReleased = true

            return CommandChordTransition(
                action: .startOrToggleCommand,
                shouldCancelPendingHoldTrigger: true
            )
        }

        let shouldEndCommand = commandChordDown && commandChordStartedCommand
        commandChordDown = false
        commandChordStartedCommand = false

        return shouldEndCommand
            ? CommandChordTransition(action: .endCommand, shouldCancelPendingHoldTrigger: false)
            : .none
    }

    mutating func handleTriggerRefresh(isPressed: Bool) -> TriggerRefreshDecision {
        guard suppressTriggerUntilReleased else { return .accept }

        if isPressed {
            return .suppressUntilReleased
        }

        suppressTriggerUntilReleased = false
        return .accept
    }

    func shouldDelayHoldStartForPossibleCommandChord(
        controlHeld: Bool,
        configuration: Configuration
    ) -> Bool {
        configuration.hasCommandShortcut
            && configuration.observesFnTrigger
            && configuration.mode == .hold
            && !controlHeld
    }
}
