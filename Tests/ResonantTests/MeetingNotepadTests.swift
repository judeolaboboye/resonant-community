import XCTest
@testable import Resonant

@MainActor
final class MeetingNotepadTests: XCTestCase {

    func testChangeHandlerEmitsSnapshotsForEditedFields() {
        let notepad = MeetingNotepad()
        var snapshots: [MeetingNotepad.Snapshot] = []
        notepad.onChange = { snapshots.append($0) }

        notepad.liveNotes = "Capture project risks"
        notepad.postMeetingNotes = "Send follow-up"

        XCTAssertEqual(
            snapshots,
            [
                .init(liveNotes: "Capture project risks", postMeetingNotes: ""),
                .init(
                    liveNotes: "Capture project risks",
                    postMeetingNotes: "Send follow-up"
                ),
            ]
        )
    }

    func testClearEmitsSingleEmptySnapshot() {
        let notepad = MeetingNotepad()
        notepad.liveNotes = "Live note"
        notepad.postMeetingNotes = "Post note"

        var snapshots: [MeetingNotepad.Snapshot] = []
        notepad.onChange = { snapshots.append($0) }

        notepad.clear()

        XCTAssertEqual(
            snapshots,
            [.init(liveNotes: "", postMeetingNotes: "")]
        )
    }

    func testProcessingLifecycleTracksStagesAndResetsOnClear() {
        let notepad = MeetingNotepad()

        notepad.beginProcessing(stages: [
            ("finalize", "Finalizing transcript"),
            ("save", "Saving meeting"),
        ])

        XCTAssertTrue(notepad.isProcessing)
        XCTAssertEqual(
            notepad.processingStages.map(\.status),
            [.active, .pending]
        )

        notepad.updateProcessingStage(
            id: "finalize",
            status: .complete,
            detail: "Transcript finalized."
        )
        notepad.updateProcessingStage(id: "save", status: .active)

        XCTAssertEqual(notepad.processingDetail, "Transcript finalized.")
        XCTAssertEqual(
            notepad.processingStages.map(\.status),
            [.complete, .active]
        )

        notepad.clear()

        XCTAssertFalse(notepad.isProcessing)
        XCTAssertTrue(notepad.processingStages.isEmpty)
        XCTAssertNil(notepad.processingHeadline)
        XCTAssertNil(notepad.processingDetail)
    }
}
