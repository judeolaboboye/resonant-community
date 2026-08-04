import Foundation

struct DispatchFollowUpWindowState {
    static let waitingStatus = "Listening for follow-up..."
    static let activeStatus = "Listening..."

    struct Observation: Equatable {
        private(set) var heardSpeech: Bool
        private(set) var firstSpeechAt: Date?
        private(set) var lastSpeechAt: Date?

        static let empty = Observation(
            heardSpeech: false,
            firstSpeechAt: nil,
            lastSpeechAt: nil
        )

        func speechTurn(completedAt: Date) -> SpeechTurn? {
            guard let firstSpeechAt, let lastSpeechAt else { return nil }
            return SpeechTurn(
                utteranceDuration: max(0.4, lastSpeechAt.timeIntervalSince(firstSpeechAt)),
                trailingSilence: max(0.5, completedAt.timeIntervalSince(lastSpeechAt))
            )
        }

        fileprivate mutating func markSpeech(at date: Date) {
            if !heardSpeech {
                firstSpeechAt = date
            }
            heardSpeech = true
            lastSpeechAt = date
        }
    }

    struct SpeechTurn: Equatable {
        var utteranceDuration: TimeInterval
        var trailingSilence: TimeInterval
    }

    struct Update: Equatable {
        var level: Float
        var elapsed: TimeInterval
        var status: String
        var shouldFinish: Bool
        var observation: Observation
    }

    private let openedAt: Date
    private let openWindow: TimeInterval
    private let trailingSilence: TimeInterval
    private let maxDuration: TimeInterval
    private let speechThreshold: Float

    private(set) var observation = Observation.empty
    private(set) var hasRequestedFinish = false

    init(
        openedAt: Date,
        openWindow: TimeInterval,
        trailingSilence: TimeInterval,
        maxDuration: TimeInterval = 30,
        speechThreshold: Float = 0.075
    ) {
        self.openedAt = openedAt
        self.openWindow = openWindow
        self.trailingSilence = trailingSilence
        self.maxDuration = maxDuration
        self.speechThreshold = speechThreshold
    }

    var currentStatus: String {
        observation.heardSpeech ? Self.activeStatus : Self.waitingStatus
    }

    mutating func observe(level: Float, at date: Date) -> Update {
        let elapsed = max(0, date.timeIntervalSince(openedAt))
        if level >= speechThreshold {
            observation.markSpeech(at: date)
        }

        let shouldFinish = shouldFinish(at: date, elapsed: elapsed)
        if shouldFinish {
            hasRequestedFinish = true
        }

        return Update(
            level: level,
            elapsed: elapsed,
            status: currentStatus,
            shouldFinish: shouldFinish,
            observation: observation
        )
    }

    private func shouldFinish(at date: Date, elapsed: TimeInterval) -> Bool {
        guard !hasRequestedFinish else { return false }

        let silenceElapsed = date.timeIntervalSince(observation.lastSpeechAt ?? openedAt)
        let shouldCloseEmptyWindow = !observation.heardSpeech && elapsed >= openWindow
        let shouldStopAfterSpeech = observation.heardSpeech && silenceElapsed >= trailingSilence
        let shouldStopAtMaxDuration = elapsed >= maxDuration

        return shouldCloseEmptyWindow || shouldStopAfterSpeech || shouldStopAtMaxDuration
    }
}
