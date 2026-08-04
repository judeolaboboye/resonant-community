import XCTest
@testable import Resonant

final class MeetingCompletionEmailBuilderTests: XCTestCase {
    func testPayloadUsesCompletedTranscriptAndMeetingLink() throws {
        let id = UUID(uuidString: "5F8C2D65-8C8D-46F5-9F1C-28B62E974BD0")!
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let endedAt = startedAt.addingTimeInterval(900)
        let context = MeetingCaptureContext(
            calendarEventID: "calendar-1",
            scheduledStartAt: startedAt,
            scheduledEndAt: endedAt,
            organizerName: "Organizer",
            attendeeNames: ["Avery", "Blake"],
            attendeeEmails: ["avery@example.com", "blake@example.com"],
            conferencingURL: "https://meet.google.com/abc-defg-hij",
            calendarName: "Work",
            title: "Customer sync",
            recordingOrigin: .automatic
        )
        let session = CompletedMeetingSession(
            id: id,
            startedAt: startedAt,
            endedAt: endedAt,
            detectedApp: MeetingApp(bundleID: "com.google.Chrome", name: "Google Meet"),
            suggestedTitle: "Customer sync",
            captureContext: context,
            speakerAliases: [:],
            utterances: [
                MeetingUtterance(text: "Thanks for joining.", speaker: .you, timestamp: startedAt),
                MeetingUtterance(text: "Let's review the launch.", speaker: .them, timestamp: startedAt.addingTimeInterval(5)),
            ],
            liveNotes: "",
            postMeetingNotes: "",
            recordingURL: nil,
            shouldDeleteRecordingAfterSave: false
        )
        let entry = MeetingEntry(
            id: id,
            startedAt: startedAt,
            endedAt: endedAt,
            detectedApp: "Google Meet",
            customTitle: "Customer sync",
            durationSeconds: 900,
            wordCount: 7,
            markdownPath: "Meetings/2026-05-21/customer-sync.md",
            conferencingURL: "https://meet.google.com/abc-defg-hij",
            recordingOriginRaw: MeetingRecordingOrigin.automatic.rawValue
        )

        let payload = try XCTUnwrap(MeetingCompletionEmailBuilder.payload(for: session, entry: entry))

        XCTAssertEqual(payload.meetingId, id.uuidString)
        XCTAssertEqual(payload.meetingTitle, "Customer sync")
        XCTAssertEqual(payload.conferencingURL, "https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(payload.markdownPath, "Meetings/2026-05-21/customer-sync.md")
        XCTAssertEqual(payload.transcript, "You: Thanks for joining.\nThem: Let's review the launch.")
    }

    func testPayloadOmitsMeetingsWithNoTranscript() {
        let session = CompletedMeetingSession(
            id: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_060),
            detectedApp: nil,
            suggestedTitle: nil,
            captureContext: nil,
            speakerAliases: [:],
            utterances: [],
            liveNotes: "",
            postMeetingNotes: "",
            recordingURL: nil,
            shouldDeleteRecordingAfterSave: false
        )
        let entry = MeetingEntry(id: session.id, startedAt: session.startedAt)

        XCTAssertNil(MeetingCompletionEmailBuilder.payload(for: session, entry: entry))
    }

    func testPayloadPreservesDiarizedParticipantSpeakerLabels() throws {
        let id = UUID(uuidString: "2C04176B-D298-4C32-BBB4-F3D18E197653")!
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let session = CompletedMeetingSession(
            id: id,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(120),
            detectedApp: MeetingApp(bundleID: "us.zoom.xos", name: "Zoom"),
            suggestedTitle: nil,
            captureContext: nil,
            speakerAliases: [:],
            utterances: [
                MeetingUtterance(text: "Opening from the room.", speaker: .participant(id: "SPEAKER_0"), timestamp: startedAt),
                MeetingUtterance(text: "Second participant replies.", speaker: .participant(id: "SPEAKER_1"), timestamp: startedAt.addingTimeInterval(4)),
            ],
            liveNotes: "",
            postMeetingNotes: "",
            recordingURL: nil,
            shouldDeleteRecordingAfterSave: false
        )
        let entry = MeetingEntry(id: id, startedAt: startedAt, detectedApp: "Zoom")

        let payload = try XCTUnwrap(MeetingCompletionEmailBuilder.payload(for: session, entry: entry))

        XCTAssertEqual(
            payload.transcript,
            "Speaker 1: Opening from the room.\nSpeaker 2: Second participant replies."
        )
    }

    func testCompletionEmailPolicyAllowsAnySignedInAccount() {
        XCTAssertTrue(AppState.canSendMeetingCompletionEmails(
            isEnabled: true,
            userEmail: "user@example.com"
        ))
    }

    func testCompletionEmailPolicyRequiresToggleAndEmail() {
        XCTAssertFalse(AppState.canSendMeetingCompletionEmails(
            isEnabled: false,
            userEmail: "user@example.com"
        ))
        XCTAssertFalse(AppState.canSendMeetingCompletionEmails(
            isEnabled: true,
            userEmail: "   "
        ))
        XCTAssertFalse(AppState.canSendMeetingCompletionEmails(
            isEnabled: true,
            userEmail: nil
        ))
    }
}
