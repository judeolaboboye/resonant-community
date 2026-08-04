import XCTest
@testable import Resonant

final class MeetingMarkdownExporterTests: XCTestCase {

    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14
    private let sessionID = UUID(uuidString: "A1B2C3D4-E5F6-7890-ABCD-EF1234567890")!

    private func makeSession(
        utterances: [MeetingUtterance] = [],
        detectedApp: MeetingApp? = nil,
        captureContext: MeetingCaptureContext? = nil,
        liveNotes: String = "",
        postMeetingNotes: String = ""
    ) -> CompletedMeetingSession {
        CompletedMeetingSession(
            id: sessionID,
            startedAt: fixedDate,
            endedAt: fixedDate.addingTimeInterval(600),
            detectedApp: detectedApp,
            suggestedTitle: nil,
            captureContext: captureContext,
            speakerAliases: [:],
            utterances: utterances,
            liveNotes: liveNotes,
            postMeetingNotes: postMeetingNotes,
            recordingURL: nil,
            shouldDeleteRecordingAfterSave: false
        )
    }

    // MARK: - Frontmatter

    func testFrontmatterContainsRequiredFields() {
        let session = makeSession()
        let md = MeetingMarkdownExporter.markdown(for: session)

        XCTAssertTrue(md.hasPrefix("---\n"))
        XCTAssertTrue(md.contains("type: meeting"))
        XCTAssertTrue(md.contains("id: \(sessionID.uuidString)"))
        XCTAssertTrue(md.contains("duration_seconds: 600"))
        XCTAssertTrue(md.contains("word_count: 0"))
    }

    func testFrontmatterIncludesAppWhenPresent() {
        let session = makeSession(detectedApp: MeetingApp(bundleID: "us.zoom.xos", name: "Zoom"))
        let md = MeetingMarkdownExporter.markdown(for: session)

        XCTAssertTrue(md.contains("app: Zoom"))
    }

    func testFrontmatterIncludesCalendarMetadata() {
        let ctx = MeetingCaptureContext(
            calendarEventID: "evt_42",
            scheduledStartAt: fixedDate,
            scheduledEndAt: fixedDate.addingTimeInterval(1800),
            organizerName: "Ada",
            attendeeNames: ["Ada", "Grace"],
            attendeeEmails: [],
            conferencingURL: "https://meet.google.com/abc",
            calendarName: "Work",
            title: "Standup",
            recordingOrigin: .automatic
        )
        let session = makeSession(captureContext: ctx)
        let md = MeetingMarkdownExporter.markdown(for: session)

        XCTAssertTrue(md.contains("calendar_event_id: evt_42"))
        XCTAssertTrue(md.contains("organizer: Ada"))
        XCTAssertTrue(md.contains("attendees: [\"Ada\", \"Grace\"]"))
        XCTAssertTrue(md.contains("recording_origin: automatic"))
    }

    func testFrontmatterListsSpeakers() {
        let utterances = [
            MeetingUtterance(text: "hello", speaker: .you, timestamp: fixedDate),
            MeetingUtterance(text: "hi", speaker: .them, timestamp: fixedDate.addingTimeInterval(5)),
        ]
        let session = makeSession(utterances: utterances)
        let md = MeetingMarkdownExporter.markdown(for: session)

        XCTAssertTrue(md.contains("speakers: [\"Them\", \"You\"]") || md.contains("speakers: [\"You\", \"Them\"]"))
    }

    // MARK: - Transcript

    func testTranscriptFormatsUtterancesWithTimestamps() {
        let utterances = [
            MeetingUtterance(text: "Good morning", speaker: .you, timestamp: fixedDate),
            MeetingUtterance(text: "Hey there", speaker: .them, timestamp: fixedDate.addingTimeInterval(65)),
        ]
        let session = makeSession(utterances: utterances)
        let md = MeetingMarkdownExporter.markdown(for: session)

        XCTAssertTrue(md.contains("**You** (0:00) <!-- speaker:you -->"))
        XCTAssertTrue(md.contains("Good morning"))
        XCTAssertTrue(md.contains("**Them** (1:05) <!-- speaker:them -->"))
        XCTAssertTrue(md.contains("Hey there"))
    }

    func testTranscriptUsesSpeakerAliasesWhenProvided() {
        let utterances = [
            MeetingUtterance(text: "Thanks for joining", speaker: .you, timestamp: fixedDate),
            MeetingUtterance(text: "Happy to be here", speaker: .participant(id: "SPEAKER_0"), timestamp: fixedDate.addingTimeInterval(8)),
        ]
        let session = makeSession(utterances: utterances)

        let md = MeetingMarkdownExporter.markdown(
            for: session,
            speakerAliases: [
                "you": "Taylor",
                "participant:SPEAKER_0": "Grace"
            ]
        )

        XCTAssertTrue(md.contains("speakers: [\"Grace\", \"Taylor\"]"))
        XCTAssertTrue(md.contains("**Taylor** (0:00) <!-- speaker:you -->"))
        XCTAssertTrue(md.contains("**Grace** (0:08) <!-- speaker:participant:SPEAKER_0 -->"))
    }

    func testEmptyTranscriptShowsPlaceholder() {
        let session = makeSession()
        let md = MeetingMarkdownExporter.markdown(for: session)

        XCTAssertTrue(md.contains("*No speech detected.*"))
    }

    // MARK: - Notes

    func testIncludesLiveNotes() {
        let session = makeSession(liveNotes: "Action: follow up on Q3 budget")
        let md = MeetingMarkdownExporter.markdown(for: session)

        XCTAssertTrue(md.contains("## Notes"))
        XCTAssertTrue(md.contains("Action: follow up on Q3 budget"))
    }

    func testIncludesPostMeetingNotes() {
        let session = makeSession(postMeetingNotes: "Send recap email")
        let md = MeetingMarkdownExporter.markdown(for: session)

        XCTAssertTrue(md.contains("## Post-Meeting Notes"))
        XCTAssertTrue(md.contains("Send recap email"))
    }

    func testOmitsEmptyNoteSections() {
        let session = makeSession()
        let md = MeetingMarkdownExporter.markdown(for: session)

        XCTAssertFalse(md.contains("## Notes"))
        XCTAssertFalse(md.contains("## Post-Meeting Notes"))
    }

    // MARK: - Title

    func testEffectiveTitlePrefersCustomTitle() {
        XCTAssertEqual(
            MeetingMarkdownExporter.effectiveTitle(appName: "Zoom", customTitle: "Sprint Retro"),
            "Sprint Retro"
        )
    }

    func testEffectiveTitleFallsBackToAppName() {
        XCTAssertEqual(
            MeetingMarkdownExporter.effectiveTitle(appName: "Zoom", customTitle: nil),
            "Meeting · Zoom"
        )
    }

    func testEffectiveTitleFallsBackToGeneric() {
        XCTAssertEqual(
            MeetingMarkdownExporter.effectiveTitle(appName: nil, customTitle: nil),
            "Meeting"
        )
    }

    func testEffectiveTitleFallsBackToOriginSpecificTitle() {
        XCTAssertEqual(
            MeetingMarkdownExporter.effectiveTitle(
                appName: nil,
                customTitle: nil,
                recordingOrigin: .manual
            ),
            "Ad-hoc meeting"
        )
    }

    func testSummaryIncludedWhenProvided() {
        let session = makeSession()
        let md = MeetingMarkdownExporter.markdown(for: session, summary: "Key decisions were made about Q4.")

        XCTAssertTrue(md.contains("## Summary"))
        XCTAssertTrue(md.contains("Key decisions were made about Q4."))
    }

    func testWordCountReflectsUtterances() {
        let utterances = [
            MeetingUtterance(text: "one two three", speaker: .you, timestamp: fixedDate),
            MeetingUtterance(text: "four five", speaker: .them, timestamp: fixedDate.addingTimeInterval(5)),
        ]
        let session = makeSession(utterances: utterances)
        let md = MeetingMarkdownExporter.markdown(for: session)

        XCTAssertTrue(md.contains("word_count: 5"))
    }

    func testExtractTranscriptReturnsTranscriptBodyOnly() {
        let session = makeSession(
            utterances: [
                MeetingUtterance(text: "Good morning", speaker: .you, timestamp: fixedDate),
                MeetingUtterance(text: "Hey there", speaker: .them, timestamp: fixedDate.addingTimeInterval(65)),
            ],
            liveNotes: "Action: follow up on Q3 budget",
            postMeetingNotes: "Send recap email"
        )
        let markdown = MeetingMarkdownExporter.markdown(
            for: session,
            summary: "Key decisions were made about Q4."
        )

        let transcript = MeetingMarkdownExporter.extractTranscript(from: markdown)

        XCTAssertEqual(
            transcript,
            """
            **You** (0:00) <!-- speaker:you -->
            Good morning

            **Them** (1:05) <!-- speaker:them -->
            Hey there
            """
        )
    }

    func testExtractTranscriptReturnsNilWhenTranscriptSectionMissing() {
        let markdown = """
        ---
        type: meeting
        ---

        # Meeting

        ## Summary

        No transcript here.
        """

        XCTAssertNil(MeetingMarkdownExporter.extractTranscript(from: markdown))
    }
}
