import Foundation
import Observation

/// Simple text buffer for live notes during a meeting and post-meeting notes.
/// Persisted into the final markdown under Notes / Post-Meeting Notes sections.
@MainActor
@Observable
final class MeetingNotepad {
    struct ProcessingStage: Identifiable, Sendable, Equatable {
        enum Status: Sendable, Equatable {
            case pending
            case active
            case complete
        }

        let id: String
        let title: String
        var status: Status
    }

    struct Snapshot: Sendable, Equatable {
        let liveNotes: String
        let postMeetingNotes: String
    }

    @ObservationIgnored var onChange: ((Snapshot) -> Void)?
    @ObservationIgnored private var isApplyingBatchUpdate = false
    @ObservationIgnored private(set) var processingStartedAt: Date?

    /// Notes jotted by the user during the meeting.
    var liveNotes: String = "" {
        didSet {
            emitChange(
                previous: Snapshot(
                    liveNotes: oldValue,
                    postMeetingNotes: postMeetingNotes
                )
            )
        }
    }

    /// Notes added by the user after the meeting ends.
    var postMeetingNotes: String = "" {
        didSet {
            emitChange(
                previous: Snapshot(
                    liveNotes: liveNotes,
                    postMeetingNotes: oldValue
                )
            )
        }
    }

    var isProcessing = false
    var processingHeadline: String?
    var processingDetail: String?
    var processingStages: [ProcessingStage] = []

    var snapshot: Snapshot {
        Snapshot(liveNotes: liveNotes, postMeetingNotes: postMeetingNotes)
    }

    func clear() {
        resetProcessing()
        replace(liveNotes: "", postMeetingNotes: "")
    }

    func replace(liveNotes: String, postMeetingNotes: String) {
        let previous = snapshot
        isApplyingBatchUpdate = true
        self.liveNotes = liveNotes
        self.postMeetingNotes = postMeetingNotes
        isApplyingBatchUpdate = false
        emitChange(previous: previous)
    }

    func beginProcessing(
        headline: String = "Analyzing the meeting",
        detail: String = "Pulling structure out of the transcript before saving it.",
        stages: [(id: String, title: String)]
    ) {
        processingHeadline = headline
        processingDetail = detail
        processingStartedAt = Date()
        processingStages = stages.enumerated().map { index, stage in
            ProcessingStage(
                id: stage.id,
                title: stage.title,
                status: index == 0 ? .active : .pending
            )
        }
        isProcessing = !processingStages.isEmpty
    }

    func updateProcessingStage(
        id: String,
        status: ProcessingStage.Status,
        detail: String? = nil
    ) {
        guard let index = processingStages.firstIndex(where: { $0.id == id }) else { return }
        processingStages[index].status = status
        if let detail {
            processingDetail = detail
        }
    }

    func resetProcessing() {
        isProcessing = false
        processingHeadline = nil
        processingDetail = nil
        processingStages = []
        processingStartedAt = nil
    }

    private func emitChange(previous: Snapshot) {
        guard !isApplyingBatchUpdate else { return }
        let current = snapshot
        guard current != previous else { return }
        onChange?(current)
    }
}
