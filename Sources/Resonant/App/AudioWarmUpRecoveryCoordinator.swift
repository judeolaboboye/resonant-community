import Foundation

/// Monotonic hardware-recovery deadline with deterministic calculation seams.
struct AudioWarmUpRecoveryDeadline {
    private(set) var recoveryUntil: ContinuousClock.Instant?

    mutating func extend(
        from now: ContinuousClock.Instant,
        by stabilizationDelay: Duration
    ) {
        let candidate = now.advanced(by: stabilizationDelay)
        guard recoveryUntil.map({ $0 >= candidate }) != true else { return }
        recoveryUntil = candidate
    }

    mutating func remaining(from now: ContinuousClock.Instant) -> Duration? {
        guard let recoveryUntil else { return nil }
        let remaining = now.duration(to: recoveryUntil)
        guard remaining > .zero else {
            self.recoveryUntil = nil
            return nil
        }
        return remaining
    }
}

/// Delays only background/persistent microphone warming while the hardware
/// graph settles after wake or a CoreAudio topology event.
///
/// The recovery deadline and the scheduled activation are deliberately
/// separate: sleep, a disabled setting, or a meeting may cancel work without
/// erasing the hardware truth. A later request still waits the remaining time.
@MainActor
final class AudioWarmUpRecoveryCoordinator {
    private let stabilizationDelay: Duration
    private let clock = ContinuousClock()
    private var deadline = AudioWarmUpRecoveryDeadline()
    private var scheduledActivation: Task<Void, Never>?
    private var scheduleGeneration: UInt64 = 0

    init(stabilizationDelay: Duration = .seconds(5)) {
        self.stabilizationDelay = stabilizationDelay
    }

    var remainingRecoveryDelay: Duration? {
        deadline.remaining(from: clock.now)
    }

    func enterRecovery() {
        deadline.extend(from: clock.now, by: stabilizationDelay)
        cancelPendingActivation()
    }

    /// Returns true when activation was deferred. Callers should activate
    /// immediately only when this returns false.
    @discardableResult
    func deferActivationIfNeeded(
        _ activation: @escaping @MainActor @Sendable () -> Void
    ) -> Bool {
        guard let remaining = deadline.remaining(from: clock.now) else {
            return false
        }

        cancelPendingActivation()
        let generation = scheduleGeneration
        scheduledActivation = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: remaining)
            } catch {
                return
            }

            guard let self, self.scheduleGeneration == generation else { return }
            self.scheduledActivation = nil

            // Re-evaluate instead of trusting the original sleep duration. A
            // later hardware event may have extended the monotonic deadline.
            if self.deferActivationIfNeeded(activation) {
                return
            }
            activation()
        }
        return true
    }

    func cancelPendingActivation() {
        scheduleGeneration &+= 1
        scheduledActivation?.cancel()
        scheduledActivation = nil
    }
}

enum PersistentAudioWarmUpPolicy {
    static func shouldSuppress(
        hasStartupSuppression: Bool,
        isMeetingStarting: Bool,
        isMeetingRecording: Bool,
        isMeetingFinalizing: Bool,
        isLocalCaptureActive: Bool,
        isSystemSleeping: Bool,
        isShuttingDown: Bool,
        isClearingWorkspace: Bool
    ) -> Bool {
        hasStartupSuppression
            || isMeetingStarting
            || isMeetingRecording
            || isMeetingFinalizing
            || isLocalCaptureActive
            || isSystemSleeping
            || isShuttingDown
            || isClearingWorkspace
    }
}

enum LocalAudioCaptureAdmissionPolicy {
    static func allowsCapture(
        hasMeetingStartupSuppression: Bool = false,
        isMeetingStarting: Bool = false,
        isMeetingRecording: Bool = false,
        isMeetingFinalizing: Bool = false,
        isSystemSleeping: Bool,
        isShuttingDown: Bool,
        isClearingWorkspace: Bool
    ) -> Bool {
        !hasMeetingStartupSuppression
            && !isMeetingStarting
            && !isMeetingRecording
            && !isMeetingFinalizing
            && !isSystemSleeping
            && !isShuttingDown
            && !isClearingWorkspace
    }
}

enum AudioStartContinuationPolicy {
    static func shouldContinue(
        ownsStartAttempt: Bool,
        isSystemSleeping: Bool,
        isShuttingDown: Bool,
        isClearingWorkspace: Bool
    ) -> Bool {
        ownsStartAttempt
            && LocalAudioCaptureAdmissionPolicy.allowsCapture(
                isSystemSleeping: isSystemSleeping,
                isShuttingDown: isShuttingDown,
                isClearingWorkspace: isClearingWorkspace
            )
    }
}

enum BackgroundMicrophoneActivationPolicy {
    static func allowsActivation(
        terminalCaptureAllowed: Bool,
        isLocalCaptureRecording: Bool,
        isLocalCaptureStarting: Bool,
        isMeetingStarting: Bool,
        isMeetingRecording: Bool,
        isMeetingFinalizing: Bool
    ) -> Bool {
        terminalCaptureAllowed
            && !isLocalCaptureRecording
            && !isLocalCaptureStarting
            && !isMeetingStarting
            && !isMeetingRecording
            && !isMeetingFinalizing
    }
}

enum FailedLocalCaptureWarmUpPolicy {
    static func shouldRequestPersistentWarmUp(
        isLowLatencyEnabled: Bool,
        isRecording: Bool,
        isStartingRecording: Bool,
        isFinishingCapture: Bool
    ) -> Bool {
        isLowLatencyEnabled
            && !isRecording
            && !isStartingRecording
            && !isFinishingCapture
    }
}
