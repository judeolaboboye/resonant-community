import Foundation

/// Pure press→release re-entrancy guard for a screen-awareness capture,
/// mirroring the shape of `MeetingSessionLifecycle`.
struct ScreenAwarenessLifecycle {
    private(set) var isCapturing = false
    private(set) var startedAt: Date?

    var canStart: Bool { !isCapturing }

    @discardableResult
    mutating func beginCapture() -> Bool {
        guard canStart else { return false }
        isCapturing = true
        startedAt = Date()
        return true
    }

    mutating func endCapture() {
        isCapturing = false
        startedAt = nil
    }
}
