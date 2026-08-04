import Foundation
import XCTest
@testable import Resonant

final class MeetingTimelineTests: XCTestCase {

    func testBuildIncludesActiveCalendarBoundRecording() {
        let startDate = Date(timeIntervalSince1970: 1_700_000_000)
        let endDate = startDate.addingTimeInterval(1_800)
        let event = MeetingCalendarEvent(
            id: "evt_123",
            title: "Customer sync",
            startDate: startDate,
            endDate: endDate,
            organizerName: "Ada",
            attendeeNames: ["Ada", "Grace"],
            attendeeEmails: ["ada@example.com"],
            conferencingURL: "https://meet.proton.me/room",
            calendarName: "Work",
            calendarColor: nil,
            isRecurring: false
        )
        let entry = MeetingEntry(
            id: UUID(uuidString: "B7A474DA-3DD1-4672-9996-5C9D3741B113")!,
            startedAt: startDate,
            detectedApp: "Zoom",
            customTitle: "Customer sync",
            durationSeconds: 600,
            wordCount: 120,
            activeJSONLPath: "meetings-active/session.jsonl"
        )
        entry.calendarEventID = event.id
        let activeSession = MeetingSessionInfo(
            id: entry.id,
            startedAt: startDate,
            detectedApp: MeetingApp(bundleID: "us.zoom.xos", name: "Zoom"),
            suggestedTitle: event.title,
            captureContext: event.captureContext(origin: .automatic),
            captureMode: .onlineCall,
            transcriptionBackendAtStart: "parakeet",
            jsonlRelativePath: "meetings-active/session.jsonl",
            jsonlURL: URL(fileURLWithPath: "/tmp/session.jsonl")
        )

        let items = MeetingTimelineBuilder.build(
            calendarEvents: [event],
            meetings: [entry],
            activeSession: activeSession,
            hiddenCalendarEventIDs: [],
            ignoredCalendarEventIDs: [],
            now: startDate.addingTimeInterval(300)
        )

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].id, "event:\(event.occurrenceKey)")
        XCTAssertEqual(items[0].status, .recording)
        XCTAssertEqual(items[0].section, .now)
        XCTAssertEqual(items[0].meeting?.id, entry.id)
        XCTAssertTrue(items[0].isBoundToActiveRecording)
    }

    func testBuildIncludesAdHocManualNotesMeetingInRecordedSection() {
        let startedAt = Date(timeIntervalSince1970: 1_700_010_000)
        let entry = MeetingEntry(
            id: UUID(uuidString: "1A0D6DF6-4A17-4EF6-9136-2E5D92BF9D06")!,
            startedAt: startedAt,
            endedAt: startedAt,
            customTitle: "Offline capture",
            durationSeconds: 0,
            wordCount: 0
        )
        entry.applyCaptureContext(.adHoc(title: "Offline capture", recordingOrigin: .manualNotes))
        entry.userNotes = "Talked through launch blockers."

        let items = MeetingTimelineBuilder.build(
            calendarEvents: [],
            meetings: [entry],
            activeSession: nil,
            hiddenCalendarEventIDs: [],
            ignoredCalendarEventIDs: [],
            now: startedAt.addingTimeInterval(60)
        )

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].id, "meeting:\(entry.id.uuidString)")
        XCTAssertEqual(items[0].section, .recorded)
        XCTAssertEqual(items[0].status, .recorded)
        XCTAssertEqual(items[0].meeting?.displayTitle, "Offline capture")
        XCTAssertNil(items[0].calendarEvent)
    }

    func testMeetingBackedItemsExposePersistedConferencingURL() {
        let startedAt = Date(timeIntervalSince1970: 1_700_020_000)
        let entry = MeetingEntry(
            id: UUID(uuidString: "56F3DB54-5F85-49D0-8983-CA448D19A72F")!,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(600),
            customTitle: "Imported browser meeting",
            durationSeconds: 600,
            wordCount: 120
        )
        entry.conferencingURL = "https://meet.google.com/abc-defg-hij"

        let items = MeetingTimelineBuilder.build(
            calendarEvents: [],
            meetings: [entry],
            activeSession: nil,
            hiddenCalendarEventIDs: [],
            ignoredCalendarEventIDs: [],
            now: startedAt.addingTimeInterval(900)
        )

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].conferencingURL, entry.conferencingURL)
        XCTAssertTrue(items[0].hasConferencingURL)
    }
}
