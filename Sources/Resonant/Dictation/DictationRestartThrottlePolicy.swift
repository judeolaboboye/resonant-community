import Foundation

/// Stabilizes the hold-mode dictation lifecycle against rapid Fn/space "fumble"
/// churn.
///
/// When a user fumbles the Fn+space lock chord, each failed attempt produces a
/// too-short / silent capture that surfaces a "no speech / not picking up audio"
/// error; an immediate re-press then restarts recording, and the notch overlay
/// oscillates between the error and the recording strip ("jumping back and
/// forth"). Hold mode — unlike toggle mode — has no start/stop cooldown, so the
/// only thing bounding the churn is the speed of the user's fingers.
///
/// These are pure decisions so they can be unit-tested in isolation; `AppState`
/// owns the timestamps and flags they read.
enum DictationRestartThrottlePolicy {
    /// How long after an *unproductive* hold capture (empty / silent / cancelled
    /// — not one that produced text) a brand-new hold start is swallowed, so a
    /// fumbled lock cannot churn start→stop→error repeatedly. Kept short so it
    /// only absorbs finger-speed bounces; a deliberate retry after reading the
    /// error is well past it. (Toggle mode uses its own, longer cooldowns.)
    static let holdUnproductiveRestartCooldownMs = 450

    /// Suppress a fresh hold-mode dictation start that lands within the cooldown
    /// of the previous *unproductive* capture.
    ///
    /// Productive captures clear the timestamp (the caller passes `nil`), so
    /// legitimate back-to-back dictation is never throttled — only re-triggers
    /// that follow a failed/empty capture, which is exactly the fumble case.
    static func shouldSuppressUnproductiveRestart(
        mode: HotkeyMode,
        millisecondsSinceUnproductiveStop: Int?
    ) -> Bool {
        guard mode == .hold, let elapsed = millisecondsSinceUnproductiveStop else {
            return false
        }
        return elapsed >= 0 && elapsed < holdUnproductiveRestartCooldownMs
    }

    /// In hold mode, a second Fn press while the previous capture is still
    /// *starting* or *finishing* (transcribing) is the same fumble, not genuine
    /// contention — absorb it silently instead of raising a hard "Resonant is
    /// busy" error (which itself adds an error frame to the oscillation).
    ///
    /// An already-active recording (`isRecording`) is intentionally excluded so
    /// the normal busy guard still surfaces real concurrent contention.
    static func shouldSilenceSelfCollision(
        mode: HotkeyMode,
        isRecording: Bool,
        isStartingRecording: Bool,
        isFinishingCapture: Bool
    ) -> Bool {
        guard mode == .hold, !isRecording else { return false }
        return isStartingRecording || isFinishingCapture
    }
}
