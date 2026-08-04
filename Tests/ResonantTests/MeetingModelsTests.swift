import XCTest
@testable import Resonant

final class MeetingModelsTests: XCTestCase {

    // MARK: - MeetingSpeaker Codable

    func testSpeakerYouRoundTrips() throws {
        let speaker = MeetingSpeaker.you
        let data = try JSONEncoder().encode(speaker)
        let decoded = try JSONDecoder().decode(MeetingSpeaker.self, from: data)

        XCTAssertEqual(decoded, .you)
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"you\"")
    }

    func testSpeakerThemRoundTrips() throws {
        let speaker = MeetingSpeaker.them
        let data = try JSONEncoder().encode(speaker)
        let decoded = try JSONDecoder().decode(MeetingSpeaker.self, from: data)

        XCTAssertEqual(decoded, .them)
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"them\"")
    }

    func testSpeakerParticipantRoundTrips() throws {
        let speaker = MeetingSpeaker.participant(id: "SPEAKER_2")
        let data = try JSONEncoder().encode(speaker)
        let decoded = try JSONDecoder().decode(MeetingSpeaker.self, from: data)

        XCTAssertEqual(decoded, .participant(id: "SPEAKER_2"))
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"participant:SPEAKER_2\"")
    }

    func testSpeakerUnknownKeyDecodesToThem() throws {
        let data = "\"unknown_value\"".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(MeetingSpeaker.self, from: data)

        XCTAssertEqual(decoded, .them)
    }

    // MARK: - Display Labels

    func testSpeakerDisplayLabels() {
        XCTAssertEqual(MeetingSpeaker.you.displayLabel, "You")
        XCTAssertEqual(MeetingSpeaker.them.displayLabel, "Them")
        XCTAssertEqual(MeetingSpeaker.participant(id: "SPEAKER_0").displayLabel, "Speaker 1")
        XCTAssertEqual(MeetingSpeaker.participant(id: "SPEAKER_2").displayLabel, "Speaker 3")
    }

    func testResolvedDisplayLabelPrefersAlias() {
        XCTAssertEqual(
            MeetingSpeaker.participant(id: "SPEAKER_0").resolvedDisplayLabel(
                using: ["participant:SPEAKER_0": "Grace"]
            ),
            "Grace"
        )
    }

    // MARK: - Storage Keys

    func testSpeakerStorageKeys() {
        XCTAssertEqual(MeetingSpeaker.you.storageKey, "you")
        XCTAssertEqual(MeetingSpeaker.them.storageKey, "them")
        XCTAssertEqual(MeetingSpeaker.participant(id: "SPEAKER_1").storageKey, "participant:SPEAKER_1")
    }

    func testLegacyTranscriptLabelParsesSpeakerKey() {
        XCTAssertEqual(MeetingSpeaker.legacySpeaker(forTranscriptLabel: "You"), .you)
        XCTAssertEqual(MeetingSpeaker.legacySpeaker(forTranscriptLabel: "Them"), .them)
        XCTAssertEqual(
            MeetingSpeaker.legacySpeaker(forTranscriptLabel: "Speaker 2"),
            .participant(id: "SPEAKER_1")
        )
    }

    // MARK: - Capture Mode

    func testManualAdHocRecordingUsesRoomMode() {
        let context = MeetingCaptureContext.adHoc(recordingOrigin: .manual)

        XCTAssertEqual(
            MeetingCaptureMode.resolve(detectedApp: nil, captureContext: context),
            .room
        )
    }

    func testDetectedAppUsesOnlineCallMode() {
        let context = MeetingCaptureContext.adHoc(recordingOrigin: .manual)
        let app = MeetingApp(bundleID: "us.zoom.xos", name: "Zoom")

        XCTAssertEqual(
            MeetingCaptureMode.resolve(detectedApp: app, captureContext: context),
            .onlineCall
        )
    }

    func testConferencingURLUsesOnlineCallMode() {
        let context = MeetingCaptureContext(
            calendarEventID: "event-1",
            scheduledStartAt: nil,
            scheduledEndAt: nil,
            organizerName: nil,
            attendeeNames: [],
            attendeeEmails: [],
            conferencingURL: "https://meet.google.com/abc-defg-hij",
            calendarName: "Work",
            title: "Sync",
            recordingOrigin: .manual
        )

        XCTAssertEqual(
            MeetingCaptureMode.resolve(detectedApp: nil, captureContext: context),
            .onlineCall
        )
    }

    func testCalendarOnlyPromptWithoutConferencingURLUsesRoomMode() {
        let context = MeetingCaptureContext(
            calendarEventID: "event-1",
            scheduledStartAt: nil,
            scheduledEndAt: nil,
            organizerName: nil,
            attendeeNames: [],
            attendeeEmails: [],
            conferencingURL: nil,
            calendarName: "Work",
            title: "In-person sync",
            recordingOrigin: .promptAccepted
        )
        let calendarOnlyApp = MeetingApp(
            bundleID: MeetingContextDetector.calendarOnlyBundleID,
            name: "Scheduled meeting"
        )

        XCTAssertEqual(
            MeetingCaptureMode.resolve(detectedApp: calendarOnlyApp, captureContext: context),
            .room
        )
    }

    func testCalendarOnlyPromptWithConferencingURLUsesOnlineCallMode() {
        let context = MeetingCaptureContext(
            calendarEventID: "event-1",
            scheduledStartAt: nil,
            scheduledEndAt: nil,
            organizerName: nil,
            attendeeNames: [],
            attendeeEmails: [],
            conferencingURL: "https://zoom.us/j/123",
            calendarName: "Work",
            title: "Remote sync",
            recordingOrigin: .promptAccepted
        )
        let calendarOnlyApp = MeetingApp(
            bundleID: MeetingContextDetector.calendarOnlyBundleID,
            name: "Scheduled meeting"
        )

        XCTAssertEqual(
            MeetingCaptureMode.resolve(detectedApp: calendarOnlyApp, captureContext: context),
            .onlineCall
        )
    }

    // MARK: - CompletedMeetingSession Computed Properties

    func testDurationSecondsComputed() {
        let start = Date(timeIntervalSince1970: 1000)
        let session = CompletedMeetingSession(
            id: UUID(),
            startedAt: start,
            endedAt: start.addingTimeInterval(300),
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

        XCTAssertEqual(session.durationSeconds, 300, accuracy: 0.01)
    }

    func testWordCountComputed() {
        let session = CompletedMeetingSession(
            id: UUID(),
            startedAt: .now,
            endedAt: .now,
            detectedApp: nil,
            suggestedTitle: nil,
            captureContext: nil,
            speakerAliases: [:],
            utterances: [
                MeetingUtterance(text: "one two three", speaker: .you),
                MeetingUtterance(text: "four", speaker: .them),
            ],
            liveNotes: "",
            postMeetingNotes: "",
            recordingURL: nil,
            shouldDeleteRecordingAfterSave: false
        )

        XCTAssertEqual(session.wordCount, 4)
    }

    // MARK: - MeetingCaptureContext

    func testAdHocCaptureContextHasNoCalendarFields() {
        let ctx = MeetingCaptureContext.adHoc(title: "Quick sync", recordingOrigin: .manual)

        XCTAssertNil(ctx.calendarEventID)
        XCTAssertNil(ctx.scheduledStartAt)
        XCTAssertNil(ctx.organizerName)
        XCTAssertTrue(ctx.attendeeNames.isEmpty)
        XCTAssertFalse(ctx.isCalendarBacked)
        XCTAssertEqual(ctx.effectiveTitle, "Quick sync")
        XCTAssertEqual(ctx.recordingOrigin, .manual)
    }

    func testCaptureContextIsCalendarBacked() {
        let ctx = MeetingCaptureContext(
            calendarEventID: "evt_1",
            scheduledStartAt: nil,
            scheduledEndAt: nil,
            organizerName: nil,
            attendeeNames: [],
            attendeeEmails: [],
            conferencingURL: nil,
            calendarName: nil,
            title: nil,
            recordingOrigin: .automatic
        )

        XCTAssertTrue(ctx.isCalendarBacked)
    }

    func testEffectiveTitleTrimsWhitespace() {
        let ctx = MeetingCaptureContext.adHoc(title: "  Standup  ", recordingOrigin: .manual)
        XCTAssertEqual(ctx.effectiveTitle, "Standup")
    }

    func testEffectiveTitleReturnsNilForEmpty() {
        let ctx = MeetingCaptureContext.adHoc(title: "  ", recordingOrigin: .manual)
        XCTAssertNil(ctx.effectiveTitle)
    }

    func testFallbackMeetingTitleUsesAdHocLabelForUntitledManualMeeting() {
        XCTAssertEqual(
            fallbackMeetingTitle(detectedApp: nil, recordingOrigin: .manual),
            "Ad-hoc meeting"
        )
    }

    func testFallbackMeetingTitleUsesNotesOnlyLabelForUntitledManualNotesMeeting() {
        XCTAssertEqual(
            fallbackMeetingTitle(detectedApp: nil, recordingOrigin: .manualNotes),
            "Notes-only meeting"
        )
    }

    func testRecordingOriginDetailDisplayLabelIsHumanReadable() {
        XCTAssertEqual(MeetingRecordingOrigin.manualNotes.detailDisplayLabel, "Notes only")
        XCTAssertEqual(MeetingRecordingOrigin.rebound.detailDisplayLabel, "Rebound to calendar event")
    }

    // MARK: - MeetingCalendarHint → CaptureContext

    func testCalendarHintProducesCaptureContext() {
        let hint = MeetingCalendarHint(
            id: "evt_42",
            title: "Sprint Retro",
            startDate: Date(timeIntervalSince1970: 1000),
            endDate: Date(timeIntervalSince1970: 2800),
            organizerName: "Ada",
            attendeeNames: ["Ada", "Grace"],
            attendeeEmails: ["ada@example.com"],
            conferencingURL: "https://meet.google.com/abc",
            calendarName: "Work",
            searchableText: "sprint retro"
        )

        let ctx = hint.captureContext(origin: .automatic)

        XCTAssertEqual(ctx.calendarEventID, "evt_42")
        XCTAssertEqual(ctx.title, "Sprint Retro")
        XCTAssertEqual(ctx.organizerName, "Ada")
        XCTAssertEqual(ctx.attendeeNames, ["Ada", "Grace"])
        XCTAssertEqual(ctx.conferencingURL, "https://meet.google.com/abc")
        XCTAssertEqual(ctx.calendarName, "Work")
        XCTAssertEqual(ctx.recordingOrigin, .automatic)
        XCTAssertTrue(ctx.isCalendarBacked)
    }

    func testCalendarHintTitleOverride() {
        let hint = MeetingCalendarHint(
            title: "Original Title",
            startDate: .now,
            endDate: .now,
            searchableText: "original title"
        )

        let ctx = hint.captureContext(origin: .manual, titleOverride: "Custom Title")

        XCTAssertEqual(ctx.title, "Custom Title")
    }

    func testMergedAliasesInferCounterpartFromCalendarAttendees() {
        let captureContext = MeetingCaptureContext(
            calendarEventID: "evt_1",
            scheduledStartAt: nil,
            scheduledEndAt: nil,
            organizerName: "Grace Hopper",
            attendeeNames: ["Taylor Morgan", "Grace Hopper"],
            attendeeEmails: ["taylor@example.com", "grace@example.com"],
            conferencingURL: nil,
            calendarName: nil,
            title: "1:1",
            recordingOrigin: .automatic
        )

        let aliases = MeetingSpeakerAliasResolver.mergedAliases(
            existing: [:],
            speakers: [.you, .participant(id: "SPEAKER_0")],
            captureContext: captureContext,
            userDisplayName: "Taylor Morgan",
            userEmail: "taylor@example.com"
        )

        XCTAssertEqual(aliases["you"], "Taylor Morgan")
        XCTAssertEqual(aliases["participant:SPEAKER_0"], "Grace Hopper")
    }

    // MARK: - normalizedMeetingURL

    func testNormalizedMeetingURLRecognizesGoogleMeet() {
        XCTAssertNotNil(
            EventKitMeetingCalendarHintSource.normalizedMeetingURL("https://meet.google.com/abc-defg-hij")
        )
    }

    func testNormalizedMeetingURLRecognizesZoom() {
        XCTAssertNotNil(
            EventKitMeetingCalendarHintSource.normalizedMeetingURL("https://us02web.zoom.us/j/123456")
        )
        XCTAssertNotNil(
            EventKitMeetingCalendarHintSource.normalizedMeetingURL("https://zoom.us/j/123456")
        )
    }

    func testNormalizedMeetingURLRecognizesTeams() {
        XCTAssertNotNil(
            EventKitMeetingCalendarHintSource.normalizedMeetingURL("https://teams.microsoft.com/l/meetup-join/abc")
        )
        XCTAssertNotNil(
            EventKitMeetingCalendarHintSource.normalizedMeetingURL("https://teams.live.com/meet/abc")
        )
    }

    func testNormalizedMeetingURLRecognizesWebex() {
        XCTAssertNotNil(
            EventKitMeetingCalendarHintSource.normalizedMeetingURL("https://company.webex.com/meet/room")
        )
    }

    func testNormalizedMeetingURLRecognizesProtonMeet() {
        XCTAssertNotNil(
            EventKitMeetingCalendarHintSource.normalizedMeetingURL("https://meet.proton.me/room-id")
        )
    }

    func testNormalizedMeetingURLRecognizesWorkMeetingTools() {
        let urls = [
            "https://v.ringcentral.com/join/123456",
            "https://global.gotomeeting.com/join/123456789",
            "https://meet.goto.com/team-sync",
            "https://meet.jit.si/team-sync",
            "https://8x8.vc/team/sync",
            "https://whereby.com/team-sync",
            "https://app.chime.aws/meetings/123456",
            "https://meeting.zoho.com/meeting/join?key=abc",
            "https://meetings.dialpad.com/team-sync",
        ]

        for url in urls {
            XCTAssertNotNil(EventKitMeetingCalendarHintSource.normalizedMeetingURL(url), url)
        }
    }

    func testNormalizedMeetingURLAddsSchemeWhenMissing() {
        let result = EventKitMeetingCalendarHintSource.normalizedMeetingURL("meet.google.com/abc")
        XCTAssertEqual(result, "https://meet.google.com/abc")
    }

    func testNormalizedMeetingURLRejectsNonMeetingURLs() {
        XCTAssertNil(EventKitMeetingCalendarHintSource.normalizedMeetingURL("https://google.com"))
        XCTAssertNil(EventKitMeetingCalendarHintSource.normalizedMeetingURL("https://example.com"))
        XCTAssertNil(EventKitMeetingCalendarHintSource.normalizedMeetingURL("https://slack.com/channel"))
    }

    func testNormalizedMeetingURLRejectsNilAndEmpty() {
        XCTAssertNil(EventKitMeetingCalendarHintSource.normalizedMeetingURL(nil))
        XCTAssertNil(EventKitMeetingCalendarHintSource.normalizedMeetingURL(""))
        XCTAssertNil(EventKitMeetingCalendarHintSource.normalizedMeetingURL("   "))
    }

    func testNormalizedMeetingURLRejectsInvalidURLs() {
        XCTAssertNil(EventKitMeetingCalendarHintSource.normalizedMeetingURL("not a url"))
        XCTAssertNil(EventKitMeetingCalendarHintSource.normalizedMeetingURL("://missing-host"))
    }

    // MARK: - MeetingRecordingOrigin

    func testRecordingOriginRawValues() {
        XCTAssertEqual(MeetingRecordingOrigin.automatic.rawValue, "automatic")
        XCTAssertEqual(MeetingRecordingOrigin.manual.rawValue, "manual")
        XCTAssertEqual(MeetingRecordingOrigin.promptAccepted.rawValue, "promptAccepted")
        XCTAssertEqual(MeetingRecordingOrigin.importedAudio.rawValue, "importedAudio")
        XCTAssertEqual(MeetingRecordingOrigin.manualNotes.rawValue, "manualNotes")
        XCTAssertEqual(MeetingRecordingOrigin.rebound.rawValue, "rebound")
    }
}
