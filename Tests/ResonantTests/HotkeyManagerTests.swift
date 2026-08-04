import XCTest
import CoreGraphics
@testable import Resonant

@MainActor
final class HotkeyManagerTests: XCTestCase {

    func testPollingFallbackOnlyRunsWithoutGlobalEventAccess() {
        XCTAssertTrue(HotkeyManager.shouldUsePollingFallback(
            hasAccessibilityPermission: false,
            hasInputMonitoringPermission: false
        ))
        XCTAssertFalse(HotkeyManager.shouldUsePollingFallback(
            hasAccessibilityPermission: true,
            hasInputMonitoringPermission: false
        ))
        XCTAssertFalse(HotkeyManager.shouldUsePollingFallback(
            hasAccessibilityPermission: false,
            hasInputMonitoringPermission: true
        ))
        XCTAssertFalse(HotkeyManager.shouldUsePollingFallback(
            hasAccessibilityPermission: true,
            hasInputMonitoringPermission: true
        ))
    }

    func testSupplementalFnPollingStopsWhenInputMonitoringIsAvailable() {
        XCTAssertTrue(HotkeyManager.shouldUseSupplementalFnPolling(
            observesFn: true,
            hasInputMonitoringPermission: false
        ))
        XCTAssertFalse(HotkeyManager.shouldUseSupplementalFnPolling(
            observesFn: true,
            hasInputMonitoringPermission: true
        ))
        XCTAssertFalse(HotkeyManager.shouldUseSupplementalFnPolling(
            observesFn: false,
            hasInputMonitoringPermission: false
        ))
    }

    func testEventTapWatchdogRequiresInputMonitoringPermission() {
        XCTAssertFalse(HotkeyManager.shouldRunEventTapWatchdog(hasInputMonitoringPermission: false))
        XCTAssertTrue(HotkeyManager.shouldRunEventTapWatchdog(hasInputMonitoringPermission: true))
    }

    func testHoldLockEventTapPolicyIsPassiveWhileIdle() {
        let manager = HotkeyManager()

        manager.debugConfigure(trigger: .rightOption, mode: .hold)

        XCTAssertFalse(manager.debugWantsActiveEventTap)
    }

    func testHoldLockEventTapPolicyArmsOnlyWhileTriggerHeld() {
        let manager = HotkeyManager()

        manager.debugConfigure(trigger: .rightOption, mode: .hold)
        manager.debugSetTriggerHeldForTapPolicy(true)

        XCTAssertTrue(manager.debugWantsActiveEventTap)

        manager.debugSetTriggerHeldForTapPolicy(false)

        XCTAssertFalse(manager.debugWantsActiveEventTap)
    }

    func testHoldLockEventTapPolicyStaysPassiveWhenHoldLockIsDisabled() {
        let manager = HotkeyManager()

        manager.debugConfigure(
            trigger: .rightOption,
            mode: .hold,
            holdToTalkLockEnabled: false
        )
        manager.debugSetTriggerHeldForTapPolicy(true)

        XCTAssertFalse(manager.debugWantsActiveEventTap)
    }

    func testHoldLockEventTapPolicyStaysPassiveOnBareSpacePress() {
        let manager = HotkeyManager()

        manager.debugConfigure(trigger: .rightOption, mode: .hold)
        manager.debugSetLockChordHeldForTapPolicy(true)

        XCTAssertFalse(manager.debugWantsActiveEventTap)
    }

    func testHoldLockEventTapPolicyStaysArmedWhileSuppressedSpaceSequenceIsInFlight() {
        let manager = HotkeyManager()

        manager.debugConfigure(trigger: .rightOption, mode: .hold)

        XCTAssertTrue(manager.debugShouldSuppressSpaceTapEvent(eventType: .keyDown, triggerPressed: true))
        XCTAssertTrue(manager.debugWantsActiveEventTap)

        XCTAssertTrue(manager.debugShouldSuppressSpaceTapEvent(eventType: .keyUp, triggerPressed: false))
        XCTAssertFalse(manager.debugWantsActiveEventTap)
    }

    func testFnShiftTogglesCommandModeOncePerChord() async {
        let manager = HotkeyManager()
        var toggleCount = 0

        manager.debugConfigure(trigger: .rightOption, mode: .hold)
        manager.onCommandToggle = { toggleCount += 1 }

        manager.debugSimulateCommandChord(function: true, shift: false)
        manager.debugSimulateCommandChord(function: true, shift: true)
        await flushCallbacks()
        manager.debugSimulateCommandChord(function: true, shift: true)
        await flushCallbacks()

        XCTAssertEqual(toggleCount, 1)

        manager.debugSimulateCommandChord(function: false, shift: true)
        manager.debugSimulateCommandChord(function: true, shift: true)
        await flushCallbacks()

        XCTAssertEqual(toggleCount, 2)
    }

    func testFnShiftCanUseHoldCommandCallbacks() async {
        let manager = HotkeyManager()
        var events: [String] = []

        manager.debugConfigure(trigger: .rightOption, mode: .hold)
        manager.onCommandStart = { events.append("start") }
        manager.onCommandEnd = { events.append("end") }

        manager.debugSimulateCommandChord(function: true, shift: true)
        await flushCallbacks()
        manager.debugSimulateCommandChord(function: true, shift: false)
        await flushCallbacks()

        XCTAssertEqual(events, ["start", "end"])
    }

    func testFnShiftCommandChordDoesNotStartFnDictation() async {
        let manager = HotkeyManager()
        var toggleCount = 0
        var dictationStarts = 0

        manager.debugConfigure(trigger: .fn, mode: .hold)
        manager.onCommandToggle = { toggleCount += 1 }
        manager.onDictationStart = { dictationStarts += 1 }

        manager.debugSimulateFlagsChanged(function: false, shift: true, keyCode: 56)
        manager.debugSimulateFlagsChanged(function: true, shift: true, keyCode: 63)
        await flushCallbacks()

        XCTAssertEqual(toggleCount, 1)
        XCTAssertEqual(dictationStarts, 0)

        manager.debugSimulateFlagsChanged(function: true, shift: false, keyCode: 56)
        manager.debugSimulateFlagsChanged(function: false, shift: false, keyCode: 63)
        await flushCallbacks()

        XCTAssertEqual(toggleCount, 1)
        XCTAssertEqual(dictationStarts, 0)
    }

    func testFnThenShiftCommandChordDoesNotRaceFnDictation() async {
        let manager = HotkeyManager()
        var toggleCount = 0
        var dictationStarts = 0

        manager.debugConfigure(trigger: .fn, mode: .hold)
        manager.onCommandToggle = { toggleCount += 1 }
        manager.onDictationStart = { dictationStarts += 1 }

        manager.debugSimulateFlagsChanged(function: true, shift: false, keyCode: 63)
        try? await Task.sleep(for: .milliseconds(30))
        manager.debugSimulateFlagsChanged(function: true, shift: true, keyCode: 56)
        await flushCallbacks()
        try? await Task.sleep(for: .milliseconds(150))
        await flushCallbacks()

        XCTAssertEqual(toggleCount, 1)
        XCTAssertEqual(dictationStarts, 0)

        manager.debugSimulateFlagsChanged(function: false, shift: false, keyCode: 63)
        await flushCallbacks()
        XCTAssertEqual(dictationStarts, 0)
    }

    func testFnThenShiftCommandChordAllowsHumanModifierRoll() async {
        let manager = HotkeyManager()
        var toggleCount = 0
        var dictationStarts = 0

        manager.debugConfigure(trigger: .fn, mode: .hold)
        manager.onCommandToggle = { toggleCount += 1 }
        manager.onDictationStart = { dictationStarts += 1 }

        manager.debugSimulateFlagsChanged(function: true, shift: false, keyCode: 63)
        try? await Task.sleep(for: .milliseconds(200))
        manager.debugSimulateFlagsChanged(function: true, shift: true, keyCode: 56)
        await flushCallbacks()
        try? await Task.sleep(for: .milliseconds(100))
        await flushCallbacks()

        XCTAssertEqual(toggleCount, 1)
        XCTAssertEqual(dictationStarts, 0)
    }

    func testPrintableKeysAreNotAllowedAsGlobalTriggers() {
        XCTAssertFalse(HotkeyTrigger.custom(keyCode: 8).isAllowedAsGlobalTrigger) // C
        XCTAssertFalse(HotkeyTrigger.custom(keyCode: 46).isAllowedAsGlobalTrigger) // M
        XCTAssertFalse(HotkeyTrigger.custom(keyCode: 49).isAllowedAsGlobalTrigger) // Space

        XCTAssertTrue(HotkeyTrigger.custom(keyCode: 122).isAllowedAsGlobalTrigger) // F1
        XCTAssertEqual(
            HotkeyTrigger.normalizedList([.custom(keyCode: 8), .rightOption]),
            [.rightOption]
        )
    }

    func testToggleTapStartsAndStopsDictation() async {
        let manager = HotkeyManager()
        var events: [String] = []

        manager.debugConfigure(trigger: .rightOption, mode: .toggle)
        manager.onDictationStart = { events.append("start") }
        manager.onDictationEnd = { events.append("end") }

        manager.debugSimulateTriggerDown()
        await flushCallbacks()
        XCTAssertTrue(events.isEmpty)

        manager.debugSimulateTriggerUp()
        await flushCallbacks()
        XCTAssertEqual(events, ["start"])

        manager.syncRecordingState(isActive: true, isLocked: false)
        manager.debugAllowImmediateToggleStop()
        manager.debugExpireToggleTapBounceCooldown()
        manager.debugSimulateTriggerDown()
        await flushCallbacks()
        manager.debugSimulateTriggerUp()
        await flushCallbacks()

        XCTAssertEqual(events, ["start", "end"])
    }

    func testToggleTapHandlesFnKeyDownUpEvents() async {
        let manager = HotkeyManager()
        var events: [String] = []

        manager.debugConfigure(trigger: .fn, mode: .toggle)
        manager.onDictationStart = { events.append("start") }
        manager.onDictationEnd = { events.append("end") }

        manager.debugSimulateTriggerKeyDown()
        await flushCallbacks()
        XCTAssertTrue(events.isEmpty)

        manager.debugSimulateTriggerKeyUp()
        await flushCallbacks()
        XCTAssertEqual(events, ["start"])

        manager.syncRecordingState(isActive: true, isLocked: false)
        manager.debugAllowImmediateToggleStop()
        manager.debugExpireToggleTapBounceCooldown()
        manager.debugSimulateTriggerKeyDown()
        await flushCallbacks()
        manager.debugSimulateTriggerKeyUp()
        await flushCallbacks()

        XCTAssertEqual(events, ["start", "end"])
    }

    func testToggleTapHandlesGlobeKeyCodeEvents() async {
        let manager = HotkeyManager()
        var events: [String] = []

        manager.debugConfigure(trigger: .fn, mode: .toggle)
        manager.onDictationStart = { events.append("start") }

        manager.debugSimulateTriggerKeyDown(keyCode: 0xB3)
        manager.debugSimulateTriggerKeyUp(keyCode: 0xB3)
        await flushCallbacks()

        XCTAssertEqual(events, ["start"])
    }

    func testToggleTapRescuesMissedFnUp() async {
        let manager = HotkeyManager()
        var events: [String] = []

        manager.debugConfigure(trigger: .fn, mode: .toggle)
        manager.onDictationStart = { events.append("start") }
        manager.debugSetCurrentKeyState(false, for: 63)
        manager.debugSetCurrentKeyState(false, for: 0xB3)

        manager.debugSimulateHIDFnDown()
        await waitForToggleTapRescue()

        XCTAssertEqual(events, ["start"])
    }

    func testToggleTapRescuesMissedFnUpWhileActive() async {
        let manager = HotkeyManager()
        var events: [String] = []

        manager.debugConfigure(trigger: .fn, mode: .toggle)
        manager.onDictationStart = { events.append("start") }
        manager.onDictationEnd = { events.append("end") }
        manager.debugSetCurrentKeyState(false, for: 63)
        manager.debugSetCurrentKeyState(false, for: 0xB3)

        manager.debugSimulateTriggerDown()
        manager.debugSimulateTriggerUp()
        await flushCallbacks()
        XCTAssertEqual(events, ["start"])

        manager.syncRecordingState(isActive: true, isLocked: false)
        manager.debugAllowImmediateToggleStop()
        manager.debugExpireToggleTapBounceCooldown()
        manager.debugSimulateHIDFnDown()
        await waitForToggleTapRescue()

        XCTAssertEqual(events, ["start", "end"])
    }

    func testToggleTapSuppressesImmediateDuplicateStopAfterStart() async {
        let manager = HotkeyManager()
        var events: [String] = []

        manager.debugConfigure(trigger: .fn, mode: .toggle)
        manager.onDictationStart = { events.append("start") }
        manager.onDictationEnd = { events.append("end") }

        manager.debugSimulateTriggerDown()
        manager.debugSimulateTriggerUp()
        await flushCallbacks()
        XCTAssertEqual(events, ["start"])

        manager.syncRecordingState(isActive: true, isLocked: false)
        manager.debugSimulateHIDFnDown()
        await waitForToggleTapRescue()

        XCTAssertEqual(events, ["start"])

        manager.debugAllowImmediateToggleStop()
        manager.debugExpireToggleTapBounceCooldown()
        manager.debugSimulateTriggerDown()
        manager.debugSimulateTriggerUp()
        await flushCallbacks()

        XCTAssertEqual(events, ["start", "end"])
    }

    func testHoldModeRescuesTransientFnReleaseBeforeEnding() async {
        let manager = HotkeyManager()
        var events: [String] = []

        manager.debugConfigure(trigger: .fn, mode: .hold)
        manager.onDictationStart = { events.append("start") }
        manager.onDictationEnd = { events.append("end") }

        manager.debugSetCurrentKeyState(true, for: 63)
        manager.debugSimulateTriggerDown()
        await flushCallbacks()
        manager.syncRecordingState(isActive: true, isLocked: false)

        manager.debugSimulateObservedTriggerDrop()
        try? await Task.sleep(for: .milliseconds(120))
        await flushCallbacks()

        XCTAssertEqual(events, ["start"])

        manager.debugSetCurrentKeyState(false, for: 63)
        manager.debugSimulateObservedTriggerDrop()
        try? await Task.sleep(for: .milliseconds(120))
        await flushCallbacks()

        XCTAssertEqual(events, ["start", "end"])
    }

    func testToggleModeIgnoresTriggerSpaceAsTapShortcut() async {
        let manager = HotkeyManager()
        var events: [String] = []

        manager.debugConfigure(trigger: .rightOption, mode: .toggle)
        manager.onDictationStart = { events.append("start") }

        manager.debugSimulateTriggerDown()
        manager.debugSimulateLockChordKeyDown()
        await flushCallbacks()
        manager.debugSimulateLockChordKeyUp()
        manager.debugSimulateTriggerUp()
        await flushCallbacks()

        XCTAssertTrue(events.isEmpty)
    }

    func testToggleModeMemoStillUsesHoldSemantics() async {
        let manager = HotkeyManager()
        var events: [String] = []

        manager.debugConfigure(trigger: .rightOption, mode: .toggle)
        manager.onMemoStart = { events.append("start") }
        manager.onMemoEnd = { events.append("end") }

        manager.debugSimulateTriggerDown(controlHeld: true)
        await flushCallbacks()
        XCTAssertEqual(events, ["start"])

        manager.syncRecordingState(isActive: true, isLocked: false)
        manager.debugSimulateTriggerUp()
        await flushCallbacks()

        XCTAssertEqual(events, ["start", "end"])
    }

    func testControlBackupKeyStartsDictationInsteadOfMemo() async {
        let manager = HotkeyManager()
        var events: [String] = []

        manager.debugConfigure(triggers: [.fn, .custom(keyCode: 59)], mode: .hold)
        manager.onDictationStart = { events.append("dictation") }
        manager.onMemoStart = { events.append("memo") }

        manager.debugSimulateFlagsChanged(function: false, shift: false, control: true, keyCode: 59)
        await flushCallbacks()

        XCTAssertEqual(events, ["dictation"])
    }

    func testPairedCustomModifierTriggersIgnoreSiblingFlags() async {
        let pairs: [(configured: UInt16, sibling: UInt16)] = [
            (54, 55), // right command, left command
            (55, 54), // left command, right command
            (56, 60), // left shift, right shift
            (60, 56), // right shift, left shift
            (58, 61), // left option, right option
            (61, 58), // right option, left option
            (59, 62), // left control, right control
            (62, 59), // right control, left control
        ]

        for pair in pairs {
            let manager = HotkeyManager()
            var startCount = 0

            manager.debugConfigure(trigger: .custom(keyCode: pair.configured), mode: .hold)
            manager.onDictationStart = { startCount += 1 }

            simulateModifierFlagsChanged(
                manager,
                keyCode: pair.sibling,
                familyDown: true,
                deviceKeyCodes: [pair.sibling]
            )
            await flushCallbacks()

            XCTAssertEqual(
                startCount,
                0,
                "\(KeyCodeNames.name(for: pair.configured)) should ignore \(KeyCodeNames.name(for: pair.sibling))"
            )

            simulateModifierFlagsChanged(
                manager,
                keyCode: pair.configured,
                familyDown: true,
                deviceKeyCodes: [pair.configured]
            )
            await flushCallbacks()

            XCTAssertEqual(
                startCount,
                1,
                "\(KeyCodeNames.name(for: pair.configured)) should start from its own key"
            )
        }
    }

    func testCustomRightCommandReleaseEndsWhileLeftCommandRemainsHeld() async {
        let manager = HotkeyManager()
        var events: [String] = []

        manager.debugConfigure(trigger: .custom(keyCode: 54), mode: .hold)
        manager.onDictationStart = { events.append("start") }
        manager.onDictationEnd = { events.append("end") }

        simulateModifierFlagsChanged(manager, keyCode: 54, familyDown: true, deviceKeyCodes: [54])
        await flushCallbacks()
        manager.syncRecordingState(isActive: true, isLocked: false)

        simulateModifierFlagsChanged(manager, keyCode: 55, familyDown: true, deviceKeyCodes: [54, 55])
        await flushCallbacks()
        XCTAssertEqual(events, ["start"])

        simulateModifierFlagsChanged(manager, keyCode: 54, familyDown: true, deviceKeyCodes: [55])
        await flushCallbacks()

        XCTAssertEqual(events, ["start", "end"])
    }

    func testBothCommandTriggersRemainActiveUntilBothSidesRelease() async {
        let manager = HotkeyManager()
        var events: [String] = []

        manager.debugConfigure(triggers: [.custom(keyCode: 54), .custom(keyCode: 55)], mode: .hold)
        manager.onDictationStart = { events.append("start") }
        manager.onDictationEnd = { events.append("end") }

        simulateModifierFlagsChanged(manager, keyCode: 54, familyDown: true, deviceKeyCodes: [54])
        await flushCallbacks()
        manager.syncRecordingState(isActive: true, isLocked: false)

        simulateModifierFlagsChanged(manager, keyCode: 55, familyDown: true, deviceKeyCodes: [54, 55])
        await flushCallbacks()
        simulateModifierFlagsChanged(manager, keyCode: 54, familyDown: true, deviceKeyCodes: [55])
        await flushCallbacks()

        XCTAssertEqual(events, ["start"])

        simulateModifierFlagsChanged(manager, keyCode: 55, familyDown: false, deviceKeyCodes: [])
        await flushCallbacks()

        XCTAssertEqual(events, ["start", "end"])
    }

    func testRightOptionPresetIgnoresLeftOptionChangesWhileHeld() async {
        let manager = HotkeyManager()
        var events: [String] = []

        manager.debugConfigure(trigger: .rightOption, mode: .hold)
        manager.onDictationStart = { events.append("start") }
        manager.onDictationEnd = { events.append("end") }

        simulateModifierFlagsChanged(manager, keyCode: 61, familyDown: true, deviceKeyCodes: [61])
        await flushCallbacks()
        manager.syncRecordingState(isActive: true, isLocked: false)

        simulateModifierFlagsChanged(manager, keyCode: 58, familyDown: true, deviceKeyCodes: [58, 61])
        await flushCallbacks()

        XCTAssertEqual(events, ["start"])

        simulateModifierFlagsChanged(manager, keyCode: 61, familyDown: true, deviceKeyCodes: [58])
        await flushCallbacks()

        XCTAssertEqual(events, ["start", "end"])
    }

    func testFamilyOnlyModifierFlagsFallbackToChangedKeyCode() async {
        let manager = HotkeyManager()
        var startCount = 0

        manager.debugConfigure(trigger: .custom(keyCode: 54), mode: .hold)
        manager.onDictationStart = { startCount += 1 }
        manager.debugSetCurrentKeyState(true, for: 54)

        simulateModifierFlagsChanged(manager, keyCode: 54, familyDown: true, deviceKeyCodes: [])
        await flushCallbacks()

        XCTAssertEqual(startCount, 1)
    }

    func testFamilyOnlyCustomRightCommandPreservesStateOnSiblingChanges() async {
        let manager = HotkeyManager()
        var events: [String] = []

        manager.debugConfigure(trigger: .custom(keyCode: 54), mode: .hold)
        manager.onDictationStart = { events.append("start") }
        manager.onDictationEnd = { events.append("end") }

        manager.debugSetCurrentKeyState(true, for: 54)
        simulateModifierFlagsChanged(manager, keyCode: 54, familyDown: true, deviceKeyCodes: [])
        await flushCallbacks()
        manager.syncRecordingState(isActive: true, isLocked: false)

        manager.debugSetCurrentKeyState(true, for: 55)
        simulateModifierFlagsChanged(manager, keyCode: 55, familyDown: true, deviceKeyCodes: [])
        await flushCallbacks()
        XCTAssertEqual(events, ["start"])

        manager.debugSetCurrentKeyState(false, for: 54)
        simulateModifierFlagsChanged(manager, keyCode: 54, familyDown: true, deviceKeyCodes: [])
        await flushCallbacks()

        XCTAssertEqual(events, ["start", "end"])
    }

    func testFamilyOnlyRightOptionPresetPreservesStateOnSiblingChanges() async {
        let manager = HotkeyManager()
        var events: [String] = []

        manager.debugConfigure(trigger: .rightOption, mode: .hold)
        manager.onDictationStart = { events.append("start") }
        manager.onDictationEnd = { events.append("end") }

        manager.debugSetCurrentKeyState(true, for: 61)
        simulateModifierFlagsChanged(manager, keyCode: 61, familyDown: true, deviceKeyCodes: [])
        await flushCallbacks()
        manager.syncRecordingState(isActive: true, isLocked: false)

        manager.debugSetCurrentKeyState(false, for: 61)
        manager.debugSetCurrentKeyState(true, for: 58)
        simulateModifierFlagsChanged(manager, keyCode: 58, familyDown: true, deviceKeyCodes: [])
        await flushCallbacks()
        XCTAssertEqual(events, ["start"])

        manager.debugSetCurrentKeyState(false, for: 61)
        simulateModifierFlagsChanged(manager, keyCode: 61, familyDown: true, deviceKeyCodes: [])
        await flushCallbacks()

        XCTAssertEqual(events, ["start", "end"])
    }

    func testSuppressionTracksCustomRightCommandReleaseWhileLeftCommandRemainsHeld() {
        let manager = HotkeyManager()

        manager.debugConfigure(trigger: .custom(keyCode: 54), mode: .hold)

        simulateSuppressionFlagsChanged(manager, keyCode: 54, familyDown: true, deviceKeyCodes: [54])
        XCTAssertTrue(manager.debugSuppressionHasObservedTriggerDown)

        simulateSuppressionFlagsChanged(manager, keyCode: 55, familyDown: true, deviceKeyCodes: [54, 55])
        XCTAssertTrue(manager.debugSuppressionHasObservedTriggerDown)

        simulateSuppressionFlagsChanged(manager, keyCode: 54, familyDown: true, deviceKeyCodes: [55])
        XCTAssertFalse(manager.debugSuppressionHasObservedTriggerDown)
    }

    func testSuppressionTracksRightOptionReleaseWhileLeftOptionRemainsHeld() {
        let manager = HotkeyManager()

        manager.debugConfigure(trigger: .rightOption, mode: .hold)

        simulateSuppressionFlagsChanged(manager, keyCode: 61, familyDown: true, deviceKeyCodes: [61])
        XCTAssertTrue(manager.debugSuppressionHasObservedTriggerDown)

        simulateSuppressionFlagsChanged(manager, keyCode: 58, familyDown: true, deviceKeyCodes: [58, 61])
        XCTAssertTrue(manager.debugSuppressionHasObservedTriggerDown)

        simulateSuppressionFlagsChanged(manager, keyCode: 61, familyDown: true, deviceKeyCodes: [58])
        XCTAssertFalse(manager.debugSuppressionHasObservedTriggerDown)
    }

    func testSuppressionFamilyOnlyCustomRightCommandPreservesStateOnSiblingChanges() {
        let manager = HotkeyManager()

        manager.debugConfigure(trigger: .custom(keyCode: 54), mode: .hold)

        manager.debugSetCurrentKeyState(true, for: 54)
        simulateSuppressionFlagsChanged(manager, keyCode: 54, familyDown: true, deviceKeyCodes: [])
        XCTAssertTrue(manager.debugSuppressionHasObservedTriggerDown)

        manager.debugSetCurrentKeyState(false, for: 54)
        manager.debugSetCurrentKeyState(true, for: 55)
        simulateSuppressionFlagsChanged(manager, keyCode: 55, familyDown: true, deviceKeyCodes: [])
        XCTAssertTrue(manager.debugSuppressionHasObservedTriggerDown)

        simulateSuppressionFlagsChanged(manager, keyCode: 54, familyDown: true, deviceKeyCodes: [])
        XCTAssertFalse(manager.debugSuppressionHasObservedTriggerDown)
    }

    func testSuppressionFamilyOnlyRightOptionPreservesStateOnSiblingChanges() {
        let manager = HotkeyManager()

        manager.debugConfigure(trigger: .rightOption, mode: .hold)

        manager.debugSetCurrentKeyState(true, for: 61)
        simulateSuppressionFlagsChanged(manager, keyCode: 61, familyDown: true, deviceKeyCodes: [])
        XCTAssertTrue(manager.debugSuppressionHasObservedTriggerDown)

        manager.debugSetCurrentKeyState(false, for: 61)
        manager.debugSetCurrentKeyState(true, for: 58)
        simulateSuppressionFlagsChanged(manager, keyCode: 58, familyDown: true, deviceKeyCodes: [])
        XCTAssertTrue(manager.debugSuppressionHasObservedTriggerDown)

        simulateSuppressionFlagsChanged(manager, keyCode: 61, familyDown: true, deviceKeyCodes: [])
        XCTAssertFalse(manager.debugSuppressionHasObservedTriggerDown)
    }

    func testToggleModeLockedMemoStopsWithTriggerTap() async {
        let manager = HotkeyManager()
        var events: [String] = []

        manager.debugConfigure(trigger: .rightOption, mode: .toggle)
        manager.onMemoStart = { events.append("start") }
        manager.onRecordingLock = { events.append("lock") }
        manager.onMemoEnd = { events.append("end") }

        await beginLockedMemo(with: manager)

        manager.debugSimulateTriggerDown()
        await flushCallbacks()
        manager.debugSimulateTriggerUp()
        await flushCallbacks()

        XCTAssertEqual(events, ["start", "lock", "end"])
        XCTAssertFalse(manager.isRecordingLocked)
    }

    func testTriggerTapStopsLockedRecording() async {
        let manager = HotkeyManager()
        var events: [String] = []

        manager.debugConfigure(trigger: .rightOption, mode: .hold)
        manager.onDictationStart = { events.append("start") }
        manager.onRecordingLock = { events.append("lock") }
        manager.onDictationEnd = { events.append("end") }

        await beginLockedDictation(with: manager)

        manager.debugSimulateTriggerDown()
        await flushCallbacks()
        manager.debugSimulateTriggerUp()
        await flushCallbacks()

        XCTAssertEqual(events, ["start", "lock", "end"])
        XCTAssertFalse(manager.isRecordingLocked)
    }

    func testLockChordCanAlsoStopLockedRecording() async {
        let manager = HotkeyManager()
        var events: [String] = []

        manager.debugConfigure(trigger: .rightOption, mode: .hold)
        manager.onDictationStart = { events.append("start") }
        manager.onRecordingLock = { events.append("lock") }
        manager.onDictationEnd = { events.append("end") }

        await beginLockedDictation(with: manager)

        manager.debugSimulateTriggerDown()
        manager.debugSimulateLockChordKeyDown()
        await flushCallbacks()
        manager.debugSimulateLockChordKeyUp()
        manager.debugSimulateTriggerUp()
        await flushCallbacks()

        XCTAssertEqual(events, ["start", "lock", "end"])
        XCTAssertFalse(manager.isRecordingLocked)
    }

    func testHoldLockDisabledLeavesHoldRecordingMomentary() async {
        let manager = HotkeyManager()
        var events: [String] = []

        manager.debugConfigure(
            trigger: .rightOption,
            mode: .hold,
            holdToTalkLockEnabled: false
        )
        manager.onDictationStart = { events.append("start") }
        manager.onRecordingLock = { events.append("lock") }
        manager.onDictationEnd = { events.append("end") }

        manager.debugSimulateTriggerDown()
        await flushCallbacks()
        manager.syncRecordingState(isActive: true, isLocked: false)
        manager.debugSimulateLockChordKeyDown()
        await flushCallbacks()
        manager.debugSimulateLockChordKeyUp()
        manager.debugSimulateTriggerUp()
        await flushCallbacks()

        XCTAssertEqual(events, ["start", "end"])
        XCTAssertFalse(manager.isRecordingLocked)
    }

    func testLockChordStopsLockedRecordingBeforeTriggerRelease() async {
        let manager = HotkeyManager()
        var events: [String] = []

        manager.debugConfigure(trigger: .rightOption, mode: .hold)
        manager.onDictationStart = { events.append("start") }
        manager.onRecordingLock = { events.append("lock") }
        manager.onDictationEnd = { events.append("end") }

        await beginLockedDictation(with: manager)

        manager.debugSimulateTriggerDown()
        manager.debugSimulateLockChordKeyDown()
        await flushCallbacks()

        XCTAssertEqual(events, ["start", "lock", "end"])
        XCTAssertFalse(manager.isRecordingLocked)

        manager.debugSimulateLockChordKeyUp()
        manager.debugSimulateTriggerUp()
        await flushCallbacks()

        XCTAssertEqual(events, ["start", "lock", "end"])
    }

    func testLockChordPressedBeforeTriggerStillLocksRecording() async {
        let manager = HotkeyManager()
        var events: [String] = []

        manager.debugConfigure(trigger: .rightOption, mode: .hold)
        manager.onDictationStart = { events.append("start") }
        manager.onRecordingLock = { events.append("lock") }
        manager.onDictationEnd = { events.append("end") }

        manager.debugSimulateLockChordKeyDown()
        manager.debugSimulateTriggerDown()
        manager.debugSimulateLockChordKeyUp()
        manager.debugSimulateTriggerUp()
        await flushCallbacks()

        XCTAssertEqual(events.first, "start")
        XCTAssertFalse(events.contains("end"))
        XCTAssertTrue(manager.isRecordingLocked)
    }

    func testPendingLockWaitsUntilStartCompletes() async {
        let manager = HotkeyManager()
        var events: [String] = []

        manager.debugConfigure(trigger: .rightOption, mode: .hold)
        manager.onDictationStart = {
            events.append("start")
            await Task.yield()
        }
        manager.onRecordingLock = { events.append("lock") }

        manager.debugSimulateTriggerDown()
        manager.debugSimulateLockChordKeyDown()
        manager.debugSimulateTriggerUp()
        await flushCallbacks()

        XCTAssertEqual(events, ["start", "lock"])
        XCTAssertTrue(manager.isRecordingLocked)
    }

    func testFnHIDSpaceChordLocksWhenSpaceArrivesBeforeFnState() async {
        let manager = HotkeyManager()
        var events: [String] = []

        manager.debugConfigure(trigger: .fn, mode: .hold)
        manager.onDictationStart = { events.append("start") }
        manager.onRecordingLock = { events.append("lock") }
        manager.onDictationEnd = { events.append("end") }

        manager.debugSimulateHIDSpaceDown()
        manager.debugSimulateHIDFnDown()
        manager.debugSimulateHIDSpaceUp()
        manager.debugSimulateHIDFnUp()
        await flushCallbacks()

        XCTAssertEqual(events, ["start", "lock"])
        XCTAssertTrue(manager.isRecordingLocked)
    }

    func testFnHIDSpaceChordStopsLockedRecording() async {
        let manager = HotkeyManager()
        var events: [String] = []

        manager.debugConfigure(trigger: .fn, mode: .hold)
        manager.onDictationStart = { events.append("start") }
        manager.onRecordingLock = { events.append("lock") }
        manager.onDictationEnd = { events.append("end") }

        manager.debugSimulateHIDFnDown()
        await flushCallbacks()
        manager.debugSimulateHIDSpaceDown()
        await flushCallbacks()
        manager.debugSimulateHIDSpaceUp()
        manager.debugSimulateHIDFnUp()
        await flushCallbacks()

        XCTAssertEqual(events, ["start", "lock"])
        XCTAssertTrue(manager.isRecordingLocked)

        manager.debugSimulateHIDSpaceDown()
        manager.debugSimulateHIDFnDown()
        await flushCallbacks()
        manager.debugSimulateHIDSpaceUp()
        manager.debugSimulateHIDFnUp()
        await flushCallbacks()

        XCTAssertEqual(events, ["start", "lock", "end"])
        XCTAssertFalse(manager.isRecordingLocked)
    }

    func testRecentSpaceChordStillLocksWhenTriggerStateArrivesAfterSpaceUp() async {
        let manager = HotkeyManager()
        var events: [String] = []

        manager.debugConfigure(trigger: .fn, mode: .hold)
        manager.onDictationStart = { events.append("start") }
        manager.onRecordingLock = { events.append("lock") }
        manager.onDictationEnd = { events.append("end") }

        manager.debugSimulateLockChordKeyDown()
        manager.debugSimulateLockChordKeyUp()
        manager.debugSimulateTriggerDown()
        await flushCallbacks()
        manager.debugSimulateTriggerUp()
        await flushCallbacks()

        XCTAssertEqual(events, ["start", "lock"])
        XCTAssertTrue(manager.isRecordingLocked)
    }

    func testRecentSpaceChordStillStopsLockedRecordingWhenTriggerStateArrivesAfterSpaceUp() async {
        let manager = HotkeyManager()
        var events: [String] = []

        manager.debugConfigure(trigger: .fn, mode: .hold)
        manager.onDictationStart = { events.append("start") }
        manager.onRecordingLock = { events.append("lock") }
        manager.onDictationEnd = { events.append("end") }

        await beginLockedDictation(with: manager)

        manager.debugSimulateLockChordKeyDown()
        manager.debugSimulateLockChordKeyUp()
        manager.debugSimulateTriggerDown()
        await flushCallbacks()
        manager.debugSimulateTriggerUp()
        await flushCallbacks()

        XCTAssertEqual(events, ["start", "lock", "end"])
        XCTAssertFalse(manager.isRecordingLocked)
    }

    func testToggleTapDuringStoppingQueuesRestartAfterBounceWindow() async {
        let manager = HotkeyManager()
        var events: [String] = []

        manager.debugConfigure(trigger: .rightOption, mode: .toggle)
        manager.onDictationStart = { events.append("start") }
        manager.onDictationEnd = { events.append("end") }

        // Start toggle dictation
        manager.debugSimulateTriggerDown()
        manager.debugSimulateTriggerUp()
        await flushCallbacks()
        XCTAssertEqual(events, ["start"])

        manager.syncRecordingState(isActive: true, isLocked: false)

        // Stop toggle dictation
        manager.debugAllowImmediateToggleStop()
        manager.debugExpireToggleTapBounceCooldown()
        manager.debugSimulateTriggerDown()
        manager.debugSimulateTriggerUp()
        await flushCallbacks()
        XCTAssertEqual(events, ["start", "end"])

        // Tap fn again while still in .stopping (before syncRecordingState clears it).
        // This is outside the bounce window, so it is an intentional restart.
        manager.debugExpireToggleTapBounceCooldown()
        manager.debugExpireToggleStopBounceCooldown()
        manager.debugSimulateTriggerDown()
        manager.debugSimulateTriggerUp()
        await flushCallbacks()

        // Stop hasn't completed yet — no new start fired
        XCTAssertEqual(events, ["start", "end"])

        // Now the stop completes
        manager.syncRecordingState(isActive: false, isLocked: false)
        await flushCallbacks()

        // Pending restart should have fired
        XCTAssertEqual(events, ["start", "end", "start"])
    }

    func testToggleTapDuringStoppingSuppressesImmediateBounceRestart() async {
        let manager = HotkeyManager()
        var events: [String] = []

        manager.debugConfigure(trigger: .rightOption, mode: .toggle)
        manager.onDictationStart = { events.append("start") }
        manager.onDictationEnd = { events.append("end") }

        manager.debugSimulateTriggerDown()
        manager.debugSimulateTriggerUp()
        await flushCallbacks()
        XCTAssertEqual(events, ["start"])

        manager.syncRecordingState(isActive: true, isLocked: false)
        manager.debugAllowImmediateToggleStop()
        manager.debugExpireToggleTapBounceCooldown()
        manager.debugSimulateTriggerDown()
        manager.debugSimulateTriggerUp()
        await flushCallbacks()
        XCTAssertEqual(events, ["start", "end"])

        manager.debugSimulateTriggerDown()
        manager.debugSimulateTriggerUp()
        await flushCallbacks()
        manager.syncRecordingState(isActive: false, isLocked: false)
        await flushCallbacks()

        XCTAssertEqual(events, ["start", "end"])
    }

    func testToggleTapStopBounceIsSuppressedAfterRecordingStateSyncsInactive() async {
        let manager = HotkeyManager()
        var events: [String] = []

        manager.debugConfigure(trigger: .rightOption, mode: .toggle)
        manager.onDictationStart = { events.append("start") }
        manager.onDictationEnd = { events.append("end") }

        manager.debugSimulateTriggerDown()
        manager.debugSimulateTriggerUp()
        await flushCallbacks()
        XCTAssertEqual(events, ["start"])

        manager.syncRecordingState(isActive: true, isLocked: false)
        manager.debugAllowImmediateToggleStop()
        manager.debugExpireToggleTapBounceCooldown()
        manager.debugSimulateTriggerDown()
        manager.debugSimulateTriggerUp()
        await flushCallbacks()
        XCTAssertEqual(events, ["start", "end"])

        manager.syncRecordingState(isActive: false, isLocked: false, isFinishing: true)
        manager.debugExpireToggleTapBounceCooldown()
        manager.debugExpireToggleStopBounceCooldown()
        manager.debugSimulateTriggerDown()
        manager.debugSimulateTriggerUp()
        await flushCallbacks()

        manager.syncRecordingState(isActive: false, isLocked: false)
        await flushCallbacks()

        XCTAssertEqual(events, ["start", "end"])
    }

    func testSpaceChordTapSuppressionDropsSpaceDownAndUp() {
        let manager = HotkeyManager()

        manager.debugConfigure(trigger: .rightOption, mode: .hold)

        XCTAssertTrue(manager.debugShouldSuppressSpaceTapEvent(eventType: .keyDown, triggerPressed: true))
        XCTAssertTrue(manager.debugShouldSuppressSpaceTapEvent(eventType: .keyUp, triggerPressed: false))
    }

    func testSpaceChordTapSuppressionLeavesPlainSpaceUntouched() {
        let manager = HotkeyManager()

        manager.debugConfigure(trigger: .rightOption, mode: .hold)

        XCTAssertFalse(manager.debugShouldSuppressSpaceTapEvent(eventType: .keyDown, triggerPressed: false))
        XCTAssertFalse(manager.debugShouldSuppressSpaceTapEvent(eventType: .keyUp, triggerPressed: false))
    }

    func testSpaceChordTapSuppressionIsDisabledWhenHoldLockIsDisabled() {
        let manager = HotkeyManager()

        manager.debugConfigure(
            trigger: .rightOption,
            mode: .hold,
            holdToTalkLockEnabled: false
        )

        XCTAssertFalse(manager.debugShouldSuppressSpaceTapEvent(eventType: .keyDown, triggerPressed: true))
        XCTAssertFalse(manager.debugShouldSuppressSpaceTapEvent(eventType: .keyUp, triggerPressed: false))
    }

    func testEscapeCancelsOnceUntilReleased() async {
        let manager = HotkeyManager()
        var cancelCount = 0

        manager.debugConfigure(trigger: .rightOption, mode: .hold)
        manager.onCancel = { cancelCount += 1 }

        manager.debugSimulateEscapeKeyDown()
        manager.debugSimulateEscapeKeyDown()
        await flushCallbacks()
        XCTAssertEqual(cancelCount, 1)

        manager.debugSimulateEscapeKeyUp()
        manager.debugSimulateEscapeKeyDown()
        await flushCallbacks()
        XCTAssertEqual(cancelCount, 2)
    }

    func testEscapeCancelsLockedSpaceChordRecording() async {
        let manager = HotkeyManager()
        var cancelCount = 0

        manager.debugConfigure(trigger: .rightOption, mode: .hold)
        manager.onCancel = { cancelCount += 1 }
        await beginLockedDictation(with: manager)

        manager.debugSimulateEscapeKeyDown()
        await flushCallbacks()

        XCTAssertEqual(cancelCount, 1)
        XCTAssertFalse(manager.isRecordingLocked)
    }

    private func beginLockedDictation(with manager: HotkeyManager) async {
        manager.debugSimulateTriggerDown()
        await flushCallbacks()
        manager.syncRecordingState(isActive: true, isLocked: false)
        manager.debugSimulateLockChordKeyDown()
        await flushCallbacks()
        manager.syncRecordingState(isActive: true, isLocked: true)
        manager.debugSimulateLockChordKeyUp()
        manager.debugSimulateTriggerUp()
        await flushCallbacks()

        XCTAssertTrue(manager.isRecordingLocked)
    }

    private func beginLockedMemo(with manager: HotkeyManager) async {
        manager.debugSimulateTriggerDown(controlHeld: true)
        await flushCallbacks()
        manager.syncRecordingState(isActive: true, isLocked: false)
        manager.debugSimulateLockChordKeyDown()
        await flushCallbacks()
        manager.syncRecordingState(isActive: true, isLocked: true)
        manager.debugSimulateLockChordKeyUp()
        manager.debugSimulateTriggerUp()
        await flushCallbacks()

        XCTAssertTrue(manager.isRecordingLocked)
    }

    private func simulateModifierFlagsChanged(
        _ manager: HotkeyManager,
        keyCode: UInt16,
        familyDown: Bool,
        deviceKeyCodes: Set<UInt16>
    ) {
        manager.debugSimulateFlagsChanged(
            function: false,
            shift: familyDown && (keyCode == 56 || keyCode == 60),
            control: familyDown && (keyCode == 59 || keyCode == 62),
            command: familyDown && (keyCode == 54 || keyCode == 55),
            option: familyDown && (keyCode == 58 || keyCode == 61),
            keyCode: keyCode,
            deviceKeyCodes: deviceKeyCodes
        )
    }

    private func simulateSuppressionFlagsChanged(
        _ manager: HotkeyManager,
        keyCode: UInt16,
        familyDown: Bool,
        deviceKeyCodes: Set<UInt16>
    ) {
        manager.debugSimulateSuppressionFlagsChanged(
            function: false,
            shift: familyDown && (keyCode == 56 || keyCode == 60),
            control: familyDown && (keyCode == 59 || keyCode == 62),
            command: familyDown && (keyCode == 54 || keyCode == 55),
            option: familyDown && (keyCode == 58 || keyCode == 61),
            keyCode: keyCode,
            deviceKeyCodes: deviceKeyCodes
        )
    }

    private func flushCallbacks() async {
        for _ in 0..<4 {
            await Task.yield()
        }
    }

    private func waitForToggleTapRescue() async {
        try? await Task.sleep(for: .milliseconds(650))
        await flushCallbacks()
    }
}
