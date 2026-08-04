import Foundation

struct MeetingAutoStopEvaluator {
    enum StopReason: String, Equatable {
        case strongLifecycleEnd = "strong_lifecycle_end"
        case weakLifecycleInactivity = "weak_lifecycle_inactivity"
        case calendarInactivity = "calendar_inactivity"
    }

    enum Decision: Equatable {
        case keepRecording
        case pendingStop(StopReason)
        case stop(StopReason)
    }

    struct Snapshot: Equatable {
        let lifecycleSignal: MeetingContextDetector.LifecycleSignal
        let cameraActive: Bool
        let systemAudioSilent: Bool
        let secondsSinceLastUtterance: TimeInterval?
        let recordingDuration: TimeInterval
        let calendarPastEndGrace: Bool
        let pendingStopStartedAt: Date?
        let now: Date
    }

    static let speechInactivityGrace: TimeInterval = 90
    static let pendingStopGrace: TimeInterval = 15

    static func evaluate(_ snapshot: Snapshot) -> Decision {
        if case .strongEndSignal = snapshot.lifecycleSignal {
            return .stop(.strongLifecycleEnd)
        }

        if case .active = snapshot.lifecycleSignal {
            return .keepRecording
        }

        guard hasEndEvidence(snapshot) else {
            return .keepRecording
        }

        guard hasRuntimeInactivity(snapshot) else {
            return .keepRecording
        }

        let reason: StopReason = snapshot.calendarPastEndGrace
            ? .calendarInactivity
            : .weakLifecycleInactivity

        guard let pendingStopStartedAt = snapshot.pendingStopStartedAt else {
            return .pendingStop(reason)
        }

        if snapshot.now.timeIntervalSince(pendingStopStartedAt) >= pendingStopGrace {
            return .stop(reason)
        }

        return .pendingStop(reason)
    }

    static func lifecycleSignalName(_ signal: MeetingContextDetector.LifecycleSignal) -> String {
        switch signal {
        case .active:
            return "active"
        case .ambiguous:
            return "ambiguous"
        case .weakEndSignal:
            return "weak_end"
        case .strongEndSignal:
            return "strong_end"
        }
    }

    private static func hasEndEvidence(_ snapshot: Snapshot) -> Bool {
        if snapshot.calendarPastEndGrace {
            return true
        }

        if case .weakEndSignal = snapshot.lifecycleSignal {
            return true
        }

        return false
    }

    private static func hasRuntimeInactivity(_ snapshot: Snapshot) -> Bool {
        guard !snapshot.cameraActive else { return false }
        return hasSpeechInactivity(snapshot)
    }

    private static func hasSpeechInactivity(_ snapshot: Snapshot) -> Bool {
        guard let secondsSinceLastUtterance = snapshot.secondsSinceLastUtterance else {
            return false
        }

        return secondsSinceLastUtterance >= speechInactivityGrace
    }
}
