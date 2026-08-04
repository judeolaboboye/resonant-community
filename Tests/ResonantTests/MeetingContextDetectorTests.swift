import XCTest
@testable import Resonant

@MainActor
final class MeetingContextDetectorTests: XCTestCase {

    func testDetectMeetingRecognizesGoogleMeetBrowserURL() {
        var context = ContextExtractor.Context()
        context.appName = "Arc"
        context.bundleId = "company.thebrowser.Browser"
        context.windowTitle = "Weekly sync"
        context.browserURL = "https://meet.google.com/abc-defg-hij"

        let detectedMeeting = MeetingContextDetector.detectMeeting(from: context)

        XCTAssertEqual(detectedMeeting?.app.name, "Google Meet")
        XCTAssertEqual(detectedMeeting?.browserURL, context.browserURL)
        XCTAssertTrue(detectedMeeting?.autoStartEligible == true)
    }

    func testDetectMeetingRejectsGoogleMeetLandingPage() {
        var context = ContextExtractor.Context()
        context.appName = "Arc"
        context.bundleId = "company.thebrowser.Browser"
        context.windowTitle = "Google Meet"
        context.browserURL = "https://meet.google.com/landing"

        XCTAssertNil(MeetingContextDetector.detectMeeting(from: context))
    }

    func testDetectMeetingRecognizesSlackHuddleFromTitleEvidence() {
        var context = ContextExtractor.Context()
        context.appName = "Slack"
        context.bundleId = "com.tinyspeck.slackmacgap"
        context.windowTitle = "Engineering Huddle"
        context.visibleTextSnippets = ["Leave huddle", "Mute"]

        let detectedMeeting = MeetingContextDetector.detectMeeting(from: context)

        XCTAssertEqual(detectedMeeting?.app.name, "Slack Huddle")
        XCTAssertTrue(detectedMeeting?.autoStartEligible == true)
    }

    func testDetectMeetingRejectsGenericSlackWorkspaceWindow() {
        var context = ContextExtractor.Context()
        context.appName = "Slack"
        context.bundleId = "com.tinyspeck.slackmacgap"
        context.windowTitle = "Resonant"
        context.visibleTextSnippets = ["Threads", "Later", "Canvas"]

        XCTAssertNil(MeetingContextDetector.detectMeeting(from: context))
    }

    func testDetectMeetingRecognizesMessagingAppCalls() {
        let cases = [
            (appName: "Messenger", bundleID: "com.facebook.archon", expectedName: "Messenger Call"),
            (appName: "WhatsApp", bundleID: "net.whatsapp.WhatsApp", expectedName: "WhatsApp Call"),
            (appName: "Telegram", bundleID: "ru.keepcoder.Telegram", expectedName: "Telegram Call"),
            (appName: "Signal", bundleID: "org.whispersystems.signal-desktop", expectedName: "Signal Call"),
            (appName: "Skype", bundleID: "com.skype.skype", expectedName: "Skype Call"),
            (appName: "Viber", bundleID: "com.viber.osx", expectedName: "Viber Call"),
            (appName: "LINE", bundleID: "jp.naver.line.mac", expectedName: "LINE Call"),
            (appName: "WeChat", bundleID: "com.tencent.xinWeChat", expectedName: "WeChat Call"),
        ]

        for appCase in cases {
            var context = ContextExtractor.Context()
            context.appName = appCase.appName
            context.bundleId = appCase.bundleID
            context.windowTitle = "Alex"
            context.visibleTextSnippets = ["2 participants", "Mute", "End call"]

            let detectedMeeting = MeetingContextDetector.detectMeeting(from: context)

            XCTAssertEqual(detectedMeeting?.app.name, appCase.expectedName)
            XCTAssertTrue(detectedMeeting?.autoStartEligible == true)
        }
    }

    func testDetectMeetingRejectsGenericWhatsAppChat() {
        var context = ContextExtractor.Context()
        context.appName = "WhatsApp"
        context.bundleId = "net.whatsapp.WhatsApp"
        context.windowTitle = "Alex"
        context.visibleTextSnippets = ["Chats", "Status", "Call me later"]

        XCTAssertNil(MeetingContextDetector.detectMeeting(from: context))
    }

    func testDetectMeetingRecognizesMessagingCallInBrowser() {
        let cases = [
            (url: "https://web.whatsapp.com/", expectedName: "WhatsApp Call"),
            (url: "https://web.telegram.org/a/", expectedName: "Telegram Call"),
            (url: "https://app.slack.com/client/T123/C456", expectedName: "Slack Huddle"),
            (url: "https://discord.com/channels/1/2", expectedName: "Discord Call"),
            (url: "https://chat.google.com/room/abc", expectedName: "Google Chat Call"),
            (url: "https://www.messenger.com/t/123", expectedName: "Messenger Call"),
            (url: "https://www.facebook.com/messages/t/123", expectedName: "Messenger Call"),
            (url: "https://www.instagram.com/direct/t/123", expectedName: "Instagram Call"),
            (url: "https://web.skype.com/", expectedName: "Skype Call"),
        ]

        for appCase in cases {
            var context = ContextExtractor.Context()
            context.appName = "Arc"
            context.bundleId = "company.thebrowser.Browser"
            context.windowTitle = appCase.expectedName
            context.browserURL = appCase.url
            context.visibleTextSnippets = ["Alex", "2 speakers", "Mute", "End call"]

            let detectedMeeting = MeetingContextDetector.detectMeeting(from: context)

            XCTAssertEqual(detectedMeeting?.app.name, appCase.expectedName)
            XCTAssertEqual(detectedMeeting?.browserURL, context.browserURL)
            XCTAssertTrue(detectedMeeting?.autoStartEligible == true)
        }
    }

    func testDetectMeetingRecognizesWorkMeetingBrowserURLs() {
        let cases = [
            (url: "https://v.ringcentral.com/join/123456", expectedName: "RingCentral"),
            (url: "https://global.gotomeeting.com/join/123456789", expectedName: "GoTo Meeting"),
            (url: "https://meet.goto.com/team-sync", expectedName: "GoTo Meeting"),
            (url: "https://meet.jit.si/team-sync", expectedName: "Jitsi Meet"),
            (url: "https://8x8.vc/team/sync", expectedName: "Jitsi Meet"),
            (url: "https://whereby.com/team-sync", expectedName: "Whereby"),
            (url: "https://app.chime.aws/meetings/123456", expectedName: "Amazon Chime"),
            (url: "https://meeting.zoho.com/meeting/join?key=abc", expectedName: "Zoho Meeting"),
            (url: "https://meetings.dialpad.com/team-sync", expectedName: "Dialpad Meetings"),
        ]

        for appCase in cases {
            var context = ContextExtractor.Context()
            context.appName = "Arc"
            context.bundleId = "company.thebrowser.Browser"
            context.windowTitle = appCase.expectedName
            context.browserURL = appCase.url

            let detectedMeeting = MeetingContextDetector.detectMeeting(from: context)

            XCTAssertEqual(detectedMeeting?.app.name, appCase.expectedName)
            XCTAssertEqual(detectedMeeting?.browserURL, context.browserURL)
            XCTAssertTrue(detectedMeeting?.autoStartEligible == true)
        }
    }

    func testCanHostMeetingRecognizesNativeAppsAndBrowsers() {
        XCTAssertTrue(MeetingContextDetector.canHostMeeting(bundleID: "us.zoom.xos"))
        XCTAssertTrue(MeetingContextDetector.canHostMeeting(bundleID: "com.facebook.archon"))
        XCTAssertTrue(MeetingContextDetector.canHostMeeting(bundleID: "net.whatsapp.WhatsApp"))
        XCTAssertTrue(MeetingContextDetector.canHostMeeting(bundleID: "ru.keepcoder.Telegram"))
        XCTAssertTrue(MeetingContextDetector.canHostMeeting(bundleID: "org.whispersystems.signal-desktop"))
        XCTAssertTrue(MeetingContextDetector.canHostMeeting(bundleID: "com.skype.skype"))
        XCTAssertTrue(MeetingContextDetector.canHostMeeting(bundleID: "com.viber.osx"))
        XCTAssertTrue(MeetingContextDetector.canHostMeeting(bundleID: "jp.naver.line.mac"))
        XCTAssertTrue(MeetingContextDetector.canHostMeeting(bundleID: "com.tencent.xinWeChat"))
        XCTAssertTrue(MeetingContextDetector.canHostMeeting(bundleID: "company.thebrowser.browser"))
        XCTAssertFalse(MeetingContextDetector.canHostMeeting(bundleID: "com.apple.TextEdit"))
    }

    func testShouldPromptSuppressesRepeatWithinCooldown() {
        let now = Date()

        XCTAssertFalse(
            MeetingContextDetector.shouldPrompt(
                signature: "zoom|weekly-sync",
                lastSignature: "zoom|weekly-sync",
                lastPromptedAt: now.addingTimeInterval(-60),
                now: now
            )
        )
        XCTAssertTrue(
            MeetingContextDetector.shouldPrompt(
                signature: "zoom|weekly-sync",
                lastSignature: "zoom|weekly-sync",
                lastPromptedAt: now.addingTimeInterval(-(16 * 60)),
                now: now
            )
        )
        XCTAssertTrue(
            MeetingContextDetector.shouldPrompt(
                signature: "teams|customer-call",
                lastSignature: "zoom|weekly-sync",
                lastPromptedAt: now,
                now: now
            )
        )
    }

    func testLifecycleSignalTreatsBackgroundNativeMissAsAmbiguous() {
        let expected = MeetingContextDetector.DetectedMeeting(
            app: MeetingApp(bundleID: "us.zoom.xos", name: "Zoom"),
            windowTitle: "Weekly sync",
            browserURL: nil,
            calendarHint: nil,
            autoStartEligible: true
        )
        var context = ContextExtractor.Context()
        context.appName = "Zoom"
        context.bundleId = "us.zoom.xos"
        context.windowTitle = "Home"
        context.visibleTextSnippets = ["Team Chat", "Phone", "Schedule"]

        XCTAssertEqual(
            MeetingContextDetector.lifecycleSignal(
                for: context,
                expected: expected,
                isFrontmostApp: false
            ),
            .ambiguous
        )
    }

    func testLifecycleSignalTreatsBackgroundBrowserMissAsWeakEndSignalWhenTrackingMeetingURL() {
        let expected = MeetingContextDetector.DetectedMeeting(
            app: MeetingApp(bundleID: "company.thebrowser.Browser", name: "Google Meet"),
            windowTitle: "Weekly sync",
            browserURL: "https://meet.google.com/abc-defg-hij",
            calendarHint: nil,
            autoStartEligible: true
        )
        var context = ContextExtractor.Context()
        context.appName = "Arc"
        context.bundleId = "company.thebrowser.Browser"
        context.windowTitle = "Inbox"
        context.browserURL = "https://mail.google.com/mail/u/0/#inbox"

        XCTAssertEqual(
            MeetingContextDetector.lifecycleSignal(
                for: context,
                expected: expected,
                isFrontmostApp: false
            ),
            .weakEndSignal
        )
    }

    func testLifecycleSignalTreatsFrontmostMissAsWeakEndSignal() {
        let expected = MeetingContextDetector.DetectedMeeting(
            app: MeetingApp(bundleID: "us.zoom.xos", name: "Zoom"),
            windowTitle: "Weekly sync",
            browserURL: nil,
            calendarHint: nil,
            autoStartEligible: true
        )
        var context = ContextExtractor.Context()
        context.appName = "zoom.us"
        context.bundleId = "us.zoom.xos"
        context.windowTitle = "Zoom Workplace"
        context.visibleTextSnippets = ["Home", "Team Chat", "Phone"]

        XCTAssertEqual(
            MeetingContextDetector.lifecycleSignal(
                for: context,
                expected: expected,
                isFrontmostApp: true
            ),
            .weakEndSignal
        )
    }

    func testLifecycleSignalRecognizesExplicitMeetingEnd() {
        let expected = MeetingContextDetector.DetectedMeeting(
            app: MeetingApp(bundleID: "company.thebrowser.Browser", name: "Google Meet"),
            windowTitle: "Weekly sync",
            browserURL: "https://meet.google.com/abc-defg-hij",
            calendarHint: nil,
            autoStartEligible: true
        )
        var context = ContextExtractor.Context()
        context.appName = "Arc"
        context.bundleId = "company.thebrowser.Browser"
        context.windowTitle = "Meeting ended"
        context.browserURL = "https://meet.google.com/abc-defg-hij"
        context.visibleTextSnippets = ["You left the meeting"]

        XCTAssertEqual(
            MeetingContextDetector.lifecycleSignal(
                for: context,
                expected: expected,
                isFrontmostApp: false
            ),
            .strongEndSignal
        )
    }

    func testLifecycleSignalRecognizesGoogleMeetLandingPageAsMeetingEnd() {
        let expected = MeetingContextDetector.DetectedMeeting(
            app: MeetingApp(bundleID: "company.thebrowser.Browser", name: "Google Meet"),
            windowTitle: "Weekly sync",
            browserURL: "https://meet.google.com/abc-defg-hij",
            calendarHint: nil,
            autoStartEligible: true
        )
        var context = ContextExtractor.Context()
        context.appName = "Arc"
        context.bundleId = "company.thebrowser.Browser"
        context.windowTitle = "Google Meet"
        context.browserURL = "https://meet.google.com/landing"

        XCTAssertEqual(
            MeetingContextDetector.lifecycleSignal(
                for: context,
                expected: expected,
                isFrontmostApp: false
            ),
            .strongEndSignal
        )
    }

    func testMicrophoneInactivityAutoStopRequiresEndEvidence() {
        XCTAssertTrue(
            MeetingContextDetector.shouldAutoStopAfterMicrophoneInactivity(.weakEndSignal)
        )
        XCTAssertTrue(
            MeetingContextDetector.shouldAutoStopAfterMicrophoneInactivity(.strongEndSignal)
        )
        XCTAssertFalse(
            MeetingContextDetector.shouldAutoStopAfterMicrophoneInactivity(.ambiguous)
        )
        XCTAssertFalse(
            MeetingContextDetector.shouldAutoStopAfterMicrophoneInactivity(
                .active(
                    MeetingContextDetector.DetectedMeeting(
                        app: MeetingApp(bundleID: "us.zoom.xos", name: "Zoom"),
                        windowTitle: "Weekly sync",
                        browserURL: nil,
                        calendarHint: nil,
                        autoStartEligible: true
                    )
                )
            )
        )
    }

    func testBestCalendarHintPrefersMatchingConferenceURL() {
        let detectedMeeting = MeetingContextDetector.DetectedMeeting(
            app: MeetingApp(bundleID: "company.thebrowser.Browser", name: "Google Meet"),
            windowTitle: "Weekly sync",
            browserURL: "https://meet.google.com/abc-defg-hij",
            calendarHint: nil,
            autoStartEligible: true
        )
        let hints = [
            MeetingCalendarHint(
                title: "1:1",
                startDate: .distantPast,
                endDate: .distantFuture,
                conferencingURL: "https://zoom.us/j/123",
                searchableText: "1:1 zoom"
            ),
            MeetingCalendarHint(
                title: "Weekly sync",
                startDate: .distantPast,
                endDate: .distantFuture,
                conferencingURL: "https://meet.google.com/abc-defg-hij",
                searchableText: "weekly sync google meet"
            ),
        ]

        XCTAssertEqual(
            MeetingContextDetector.bestCalendarHint(for: detectedMeeting, hints: hints)?.title,
            "Weekly sync"
        )
    }

    func testCalendarSuggestsMeetingEndedAfterScheduledEndGracePeriod() {
        let meeting = MeetingContextDetector.DetectedMeeting(
            app: MeetingApp(bundleID: "us.zoom.xos", name: "Zoom"),
            windowTitle: "Customer call",
            browserURL: nil,
            calendarHint: MeetingCalendarHint(
                title: "Customer call",
                startDate: Date(timeIntervalSince1970: 100),
                endDate: Date(timeIntervalSince1970: 200),
                conferencingURL: "https://zoom.us/j/123",
                searchableText: "customer call zoom"
            ),
            autoStartEligible: false
        )

        XCTAssertFalse(
            MeetingContextDetector.calendarSuggestsMeetingEnded(
                meeting,
                now: Date(timeIntervalSince1970: 799)
            )
        )
        XCTAssertTrue(
            MeetingContextDetector.calendarSuggestsMeetingEnded(
                meeting,
                now: Date(timeIntervalSince1970: 801)
            )
        )
    }

    func testShouldAutoStartRequiresStrongEvidenceWithoutCalendarMatch() {
        let meeting = MeetingContextDetector.DetectedMeeting(
            app: MeetingApp(bundleID: "us.zoom.xos", name: "Zoom"),
            windowTitle: "Weekly sync",
            browserURL: nil,
            calendarHint: nil,
            autoStartEligible: false
        )

        XCTAssertFalse(MeetingContextDetector.shouldAutoStart(meeting))
    }

    func testShouldAutoStartAllowsCalendarMatchedPromptOnlyMeeting() {
        let meeting = MeetingContextDetector.DetectedMeeting(
            app: MeetingApp(bundleID: "us.zoom.xos", name: "Zoom"),
            windowTitle: "Customer call",
            browserURL: nil,
            calendarHint: MeetingCalendarHint(
                title: "Customer call",
                startDate: .distantPast,
                endDate: .distantFuture,
                conferencingURL: "https://zoom.us/j/123",
                searchableText: "customer call zoom"
            ),
            autoStartEligible: false
        )

        XCTAssertTrue(MeetingContextDetector.shouldAutoStart(meeting))
    }

    func testShouldAutoStartRequiresConferenceLinkForCalendarOnlyAutoStart() {
        let meeting = MeetingContextDetector.DetectedMeeting(
            app: MeetingApp(bundleID: "us.zoom.xos", name: "Zoom"),
            windowTitle: "Customer call",
            browserURL: nil,
            calendarHint: MeetingCalendarHint(
                title: "Customer call",
                startDate: .distantPast,
                endDate: .distantFuture,
                searchableText: "customer call zoom"
            ),
            autoStartEligible: false
        )

        XCTAssertFalse(MeetingContextDetector.shouldAutoStart(meeting))
    }

    func testShouldPromptImmediatelyForActiveGoogleMeetURL() {
        let meeting = MeetingContextDetector.DetectedMeeting(
            app: MeetingApp(bundleID: "company.thebrowser.Browser", name: "Google Meet"),
            windowTitle: "Weekly sync",
            browserURL: "https://meet.google.com/abc-defg-hij",
            calendarHint: nil,
            autoStartEligible: true
        )

        XCTAssertTrue(MeetingContextDetector.shouldPromptImmediately(meeting))
    }

    func testShouldPromptImmediatelyRejectsCalendarOnlyPrompt() {
        let meeting = MeetingContextDetector.DetectedMeeting(
            app: MeetingApp(
                bundleID: MeetingContextDetector.calendarOnlyBundleID,
                name: "Scheduled meeting"
            ),
            windowTitle: "Weekly sync",
            browserURL: "https://meet.google.com/abc-defg-hij",
            calendarHint: MeetingCalendarHint(
                title: "Weekly sync",
                startDate: .distantPast,
                endDate: .distantFuture,
                conferencingURL: "https://meet.google.com/abc-defg-hij",
                searchableText: "weekly sync google meet"
            ),
            autoStartEligible: false
        )

        XCTAssertFalse(MeetingContextDetector.shouldPromptImmediately(meeting))
    }

    func testCalendarAutomationPrimedRequiresScheduledWindowAndLink() {
        let meeting = MeetingContextDetector.DetectedMeeting(
            app: MeetingApp(bundleID: "us.zoom.xos", name: "Zoom"),
            windowTitle: "Customer call",
            browserURL: nil,
            calendarHint: MeetingCalendarHint(
                title: "Customer call",
                startDate: Date(timeIntervalSince1970: 100),
                endDate: Date(timeIntervalSince1970: 200),
                conferencingURL: "https://zoom.us/j/123",
                searchableText: "customer call zoom"
            ),
            autoStartEligible: false
        )

        XCTAssertTrue(
            MeetingContextDetector.isCalendarAutomationPrimed(
                meeting,
                now: Date(timeIntervalSince1970: 110)
            )
        )
        XCTAssertFalse(
            MeetingContextDetector.isCalendarAutomationPrimed(
                meeting,
                now: Date(timeIntervalSince1970: 2_000)
            )
        )
    }

    func testMarkedAutoRecordDoesNotStartCalendarOnlyBeforeScheduledStart() {
        let now = Date(timeIntervalSince1970: 1_000)
        let meeting = MeetingContextDetector.DetectedMeeting(
            app: MeetingApp(
                bundleID: MeetingContextDetector.calendarOnlyBundleID,
                name: "Scheduled meeting"
            ),
            windowTitle: "Customer call",
            browserURL: "https://zoom.us/j/123",
            calendarHint: MeetingCalendarHint(
                title: "Customer call",
                startDate: now.addingTimeInterval(60),
                endDate: now.addingTimeInterval(1_860),
                conferencingURL: "https://zoom.us/j/123",
                searchableText: "customer call zoom"
            ),
            autoStartEligible: false
        )

        XCTAssertFalse(
            MeetingContextDetector.shouldStartMarkedAutoRecord(
                meeting,
                hasRuntimeMeetingSignal: false,
                now: now
            )
        )
    }

    func testMarkedAutoRecordStartsCalendarOnlyAtScheduledStart() {
        let now = Date(timeIntervalSince1970: 1_000)
        let meeting = MeetingContextDetector.DetectedMeeting(
            app: MeetingApp(
                bundleID: MeetingContextDetector.calendarOnlyBundleID,
                name: "Scheduled meeting"
            ),
            windowTitle: "Customer call",
            browserURL: "https://zoom.us/j/123",
            calendarHint: MeetingCalendarHint(
                title: "Customer call",
                startDate: now,
                endDate: now.addingTimeInterval(1_800),
                conferencingURL: "https://zoom.us/j/123",
                searchableText: "customer call zoom"
            ),
            autoStartEligible: false
        )

        XCTAssertTrue(
            MeetingContextDetector.shouldStartMarkedAutoRecord(
                meeting,
                hasRuntimeMeetingSignal: false,
                now: now
            )
        )
    }

    func testMarkedAutoRecordRequiresRuntimeSignalForPromptOnlyCallSurface() {
        let now = Date(timeIntervalSince1970: 1_000)
        let meeting = MeetingContextDetector.DetectedMeeting(
            app: MeetingApp(bundleID: "us.zoom.xos", name: "Zoom"),
            windowTitle: "Customer call",
            browserURL: nil,
            calendarHint: MeetingCalendarHint(
                title: "Customer call",
                startDate: now.addingTimeInterval(60),
                endDate: now.addingTimeInterval(1_860),
                conferencingURL: "https://zoom.us/j/123",
                searchableText: "customer call zoom"
            ),
            autoStartEligible: false
        )

        XCTAssertFalse(
            MeetingContextDetector.shouldStartMarkedAutoRecord(
                meeting,
                hasRuntimeMeetingSignal: false,
                now: now
            )
        )
        XCTAssertTrue(
            MeetingContextDetector.shouldStartMarkedAutoRecord(
                meeting,
                hasRuntimeMeetingSignal: true,
                now: now
            )
        )
    }

    func testDetectMeetingRecognizesPromptOnlyZoomWindowWithoutAutoStartEvidence() {
        var context = ContextExtractor.Context()
        context.appName = "zoom.us"
        context.bundleId = "us.zoom.xos"
        context.windowTitle = "Weekly sync"
        context.visibleTextSnippets = ["Weekly sync", "Join meeting"]

        let detectedMeeting = MeetingContextDetector.detectMeeting(from: context)

        XCTAssertEqual(detectedMeeting?.app.name, "Zoom")
        XCTAssertFalse(detectedMeeting?.autoStartEligible == true)
    }

    func testPromptSignatureStaysStableForSameMeetingURLWhenQueryChanges() {
        let firstMeeting = MeetingContextDetector.DetectedMeeting(
            app: MeetingApp(bundleID: "company.thebrowser.Browser", name: "Google Meet"),
            windowTitle: "Weekly sync",
            browserURL: "https://meet.google.com/abc-defg-hij?authuser=1",
            calendarHint: nil,
            autoStartEligible: true
        )
        let secondMeeting = MeetingContextDetector.DetectedMeeting(
            app: MeetingApp(bundleID: "company.thebrowser.Browser", name: "Google Meet"),
            windowTitle: "Weekly sync (2)",
            browserURL: "https://meet.google.com/abc-defg-hij?pli=1#details",
            calendarHint: nil,
            autoStartEligible: true
        )

        XCTAssertEqual(firstMeeting.promptSignature, secondMeeting.promptSignature)
        XCTAssertEqual(firstMeeting.promptSuppressionKey, secondMeeting.promptSuppressionKey)
    }

    func testPromptSignaturePrefersCalendarEventIdentityOverTitleChanges() {
        let firstMeeting = MeetingContextDetector.DetectedMeeting(
            app: MeetingApp(bundleID: "us.zoom.xos", name: "Zoom"),
            windowTitle: "Customer sync",
            browserURL: nil,
            calendarHint: MeetingCalendarHint(
                id: "calendar-event-123",
                title: "Customer sync",
                startDate: .distantPast,
                endDate: .distantFuture,
                conferencingURL: "https://zoom.us/j/123",
                searchableText: "customer sync zoom"
            ),
            autoStartEligible: false
        )
        let secondMeeting = MeetingContextDetector.DetectedMeeting(
            app: MeetingApp(bundleID: "us.zoom.xos", name: "Zoom"),
            windowTitle: "Renamed window title",
            browserURL: nil,
            calendarHint: MeetingCalendarHint(
                id: "calendar-event-123",
                title: "Customer sync follow-up",
                startDate: .distantPast,
                endDate: .distantFuture,
                conferencingURL: "https://zoom.us/j/123",
                searchableText: "customer sync follow-up zoom"
            ),
            autoStartEligible: false
        )

        XCTAssertEqual(firstMeeting.promptSignature, secondMeeting.promptSignature)
        XCTAssertEqual(firstMeeting.promptSuppressionKey, secondMeeting.promptSuppressionKey)
    }

    func testCalendarPromptSuppressionIgnoresDetectionSurfaceForSameEvent() {
        let hint = MeetingCalendarHint(
            id: "calendar-event-123",
            title: "Customer sync",
            startDate: .distantPast,
            endDate: .distantFuture,
            conferencingURL: "https://zoom.us/j/123",
            searchableText: "customer sync zoom"
        )
        let calendarOnlyMeeting = MeetingContextDetector.DetectedMeeting(
            app: MeetingApp(
                bundleID: MeetingContextDetector.calendarOnlyBundleID,
                name: "Scheduled meeting"
            ),
            windowTitle: "Customer sync",
            browserURL: "https://zoom.us/j/123",
            calendarHint: hint,
            autoStartEligible: false
        )
        let zoomMeeting = MeetingContextDetector.DetectedMeeting(
            app: MeetingApp(bundleID: "us.zoom.xos", name: "Zoom"),
            windowTitle: "Customer sync",
            browserURL: nil,
            calendarHint: hint,
            autoStartEligible: false
        )

        XCTAssertEqual(calendarOnlyMeeting.promptSignature, zoomMeeting.promptSignature)
        XCTAssertEqual(calendarOnlyMeeting.promptSuppressionKey, zoomMeeting.promptSuppressionKey)
        XCTAssertEqual(zoomMeeting.promptSuppressionKey, "calendar|calendar-event-123")
    }

    func testLifecycleIdentityMatchesCalendarOnlyPromotionForSameEvent() {
        let hint = MeetingCalendarHint(
            id: "calendar-event-123",
            title: "Customer sync",
            startDate: .distantPast,
            endDate: .distantFuture,
            conferencingURL: "https://zoom.us/j/123",
            searchableText: "customer sync zoom"
        )
        let calendarOnlyMeeting = MeetingContextDetector.DetectedMeeting(
            app: MeetingApp(
                bundleID: MeetingContextDetector.calendarOnlyBundleID,
                name: "Scheduled meeting"
            ),
            windowTitle: "Customer sync",
            browserURL: "https://zoom.us/j/123",
            calendarHint: hint,
            autoStartEligible: false
        )
        let promotedMeeting = MeetingContextDetector.DetectedMeeting(
            app: MeetingApp(bundleID: "us.zoom.xos", name: "Zoom"),
            windowTitle: "Customer sync",
            browserURL: nil,
            calendarHint: hint,
            autoStartEligible: true
        )

        XCTAssertTrue(calendarOnlyMeeting.matchesLifecycleIdentity(of: promotedMeeting))
        XCTAssertTrue(promotedMeeting.matchesLifecycleIdentity(of: calendarOnlyMeeting))
    }

    func testLifecycleIdentityKeepsDifferentCalendarEventsSeparateAcrossApps() {
        let firstHint = MeetingCalendarHint(
            id: "calendar-event-123",
            title: "Customer sync",
            startDate: .distantPast,
            endDate: .distantFuture,
            conferencingURL: "https://zoom.us/j/123",
            searchableText: "customer sync zoom"
        )
        let secondHint = MeetingCalendarHint(
            id: "calendar-event-456",
            title: "Customer sync",
            startDate: .distantPast,
            endDate: .distantFuture,
            conferencingURL: "https://zoom.us/j/456",
            searchableText: "customer sync zoom"
        )
        let calendarOnlyMeeting = MeetingContextDetector.DetectedMeeting(
            app: MeetingApp(
                bundleID: MeetingContextDetector.calendarOnlyBundleID,
                name: "Scheduled meeting"
            ),
            windowTitle: "Customer sync",
            browserURL: "https://zoom.us/j/123",
            calendarHint: firstHint,
            autoStartEligible: false
        )
        let promotedMeeting = MeetingContextDetector.DetectedMeeting(
            app: MeetingApp(bundleID: "us.zoom.xos", name: "Zoom"),
            windowTitle: "Customer sync",
            browserURL: nil,
            calendarHint: secondHint,
            autoStartEligible: true
        )

        XCTAssertFalse(calendarOnlyMeeting.matchesLifecycleIdentity(of: promotedMeeting))
    }

    func testURLPromptSuppressionIgnoresBrowserBundleForSameMeetingURL() {
        let arcMeeting = MeetingContextDetector.DetectedMeeting(
            app: MeetingApp(bundleID: "company.thebrowser.Browser", name: "Google Meet"),
            windowTitle: "Weekly sync",
            browserURL: "https://meet.google.com/abc-defg-hij?authuser=1",
            calendarHint: nil,
            autoStartEligible: true
        )
        let safariMeeting = MeetingContextDetector.DetectedMeeting(
            app: MeetingApp(bundleID: "com.apple.Safari", name: "Google Meet"),
            windowTitle: "Weekly sync",
            browserURL: "https://meet.google.com/abc-defg-hij?pli=1#details",
            calendarHint: nil,
            autoStartEligible: true
        )

        XCTAssertEqual(arcMeeting.promptSignature, safariMeeting.promptSignature)
        XCTAssertEqual(arcMeeting.promptSuppressionKey, safariMeeting.promptSuppressionKey)
        XCTAssertEqual(arcMeeting.promptSuppressionKey, "url|https://meet.google.com/abc-defg-hij")
    }

    func testShouldSuppressDismissedPromptOnlyForMatchingKeyBeforeExpiry() {
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(
            MeetingContextDetector.shouldSuppressDismissedPrompt(
                suppressionKey: "calendar|abc",
                dismissedPromptKey: "calendar|abc",
                dismissedUntil: now.addingTimeInterval(300),
                now: now
            )
        )
        XCTAssertFalse(
            MeetingContextDetector.shouldSuppressDismissedPrompt(
                suppressionKey: "calendar|abc",
                dismissedPromptKey: "calendar|different",
                dismissedUntil: now.addingTimeInterval(300),
                now: now
            )
        )
        XCTAssertFalse(
            MeetingContextDetector.shouldSuppressDismissedPrompt(
                suppressionKey: "calendar|abc",
                dismissedPromptKey: "calendar|abc",
                dismissedUntil: now.addingTimeInterval(-1),
                now: now
            )
        )
    }

    func testActiveMeetingScanIsPrimedByCameraEvenBeforeMicrophoneDebounce() {
        XCTAssertTrue(
            MeetingContextDetector.shouldScanForActiveMeeting(
                isMicrophoneDetectionReady: false,
                isCameraActive: true,
                isCalendarHintsEnabled: false
            )
        )
    }

    func testActiveMeetingScanWaitsWhenNoRuntimeOrCalendarSignalExists() {
        XCTAssertFalse(
            MeetingContextDetector.shouldScanForActiveMeeting(
                isMicrophoneDetectionReady: false,
                isCameraActive: false,
                isCalendarHintsEnabled: false
            )
        )
    }

    func testCalendarOnlyMeetingPrefersInProgressHint() {
        let now = Date(timeIntervalSince1970: 1_000)
        let hints = [
            MeetingCalendarHint(
                id: "later",
                title: "Later meeting",
                startDate: now.addingTimeInterval(1_800),
                endDate: now.addingTimeInterval(3_600),
                searchableText: "later meeting"
            ),
            MeetingCalendarHint(
                id: "active",
                title: "In-person sync",
                startDate: now.addingTimeInterval(-300),
                endDate: now.addingTimeInterval(1_500),
                searchableText: "in-person sync"
            ),
        ]

        let detectedMeeting = MeetingContextDetector.calendarOnlyMeeting(from: hints, now: now)

        XCTAssertEqual(detectedMeeting?.calendarHint?.id, "active")
        XCTAssertEqual(
            detectedMeeting?.app.bundleID,
            MeetingContextDetector.calendarOnlyBundleID
        )
        XCTAssertFalse(detectedMeeting?.autoStartEligible == true)
    }

    func testCalendarOnlyLifecyclePromotesToMatchingRealCallDuringScheduledWindow() {
        let hint = MeetingCalendarHint(
            id: "calendar-event-123",
            title: "Customer call",
            startDate: Date(timeIntervalSince1970: 100),
            endDate: Date(timeIntervalSince1970: 200),
            conferencingURL: "https://zoom.us/j/123",
            searchableText: "customer call zoom"
        )
        let calendarOnlyMeeting = MeetingContextDetector.DetectedMeeting(
            app: MeetingApp(
                bundleID: MeetingContextDetector.calendarOnlyBundleID,
                name: "Scheduled meeting"
            ),
            windowTitle: "Customer call",
            browserURL: "https://zoom.us/j/123",
            calendarHint: hint,
            autoStartEligible: false
        )
        let zoomMeeting = MeetingContextDetector.DetectedMeeting(
            app: MeetingApp(bundleID: "us.zoom.xos", name: "Zoom"),
            windowTitle: "Customer call",
            browserURL: nil,
            calendarHint: nil,
            autoStartEligible: true
        )

        XCTAssertTrue(
            MeetingContextDetector.shouldPromoteCalendarOnlyLifecycle(
                from: calendarOnlyMeeting,
                to: zoomMeeting,
                now: Date(timeIntervalSince1970: 110)
            )
        )
    }

    func testCalendarOnlyLifecycleDoesNotPromoteOutsideScheduledWindow() {
        let hint = MeetingCalendarHint(
            id: "calendar-event-123",
            title: "Customer call",
            startDate: Date(timeIntervalSince1970: 100),
            endDate: Date(timeIntervalSince1970: 200),
            conferencingURL: "https://zoom.us/j/123",
            searchableText: "customer call zoom"
        )
        let calendarOnlyMeeting = MeetingContextDetector.DetectedMeeting(
            app: MeetingApp(
                bundleID: MeetingContextDetector.calendarOnlyBundleID,
                name: "Scheduled meeting"
            ),
            windowTitle: "Customer call",
            browserURL: "https://zoom.us/j/123",
            calendarHint: hint,
            autoStartEligible: false
        )
        let zoomMeeting = MeetingContextDetector.DetectedMeeting(
            app: MeetingApp(bundleID: "us.zoom.xos", name: "Zoom"),
            windowTitle: "Customer call",
            browserURL: nil,
            calendarHint: nil,
            autoStartEligible: true
        )

        XCTAssertFalse(
            MeetingContextDetector.shouldPromoteCalendarOnlyLifecycle(
                from: calendarOnlyMeeting,
                to: zoomMeeting,
                now: Date(timeIntervalSince1970: 1_000)
            )
        )
    }

    func testCalendarPromptTriggerDateUsesNinetySecondLeadTime() {
        let now = Date(timeIntervalSince1970: 1_000)
        let event = makeCalendarEvent(
            startDate: now.addingTimeInterval(600),
            endDate: now.addingTimeInterval(2_400),
            conferencingURL: "https://meet.google.com/abc-defg-hij"
        )

        XCTAssertEqual(
            MeetingPromptNotifier.calendarPromptTriggerDate(for: event, now: now),
            event.startDate.addingTimeInterval(-MeetingPromptNotifier.calendarPromptLeadTime)
        )
    }

    func testCalendarPromptTriggerDateRequiresConferenceURL() {
        let now = Date(timeIntervalSince1970: 1_000)
        let event = makeCalendarEvent(
            startDate: now.addingTimeInterval(600),
            endDate: now.addingTimeInterval(2_400),
            conferencingURL: nil
        )

        XCTAssertNil(MeetingPromptNotifier.calendarPromptTriggerDate(for: event, now: now))
    }

    private func makeCalendarEvent(
        startDate: Date,
        endDate: Date,
        conferencingURL: String?
    ) -> MeetingCalendarEvent {
        MeetingCalendarEvent(
            id: "event-123",
            title: "Customer call",
            startDate: startDate,
            endDate: endDate,
            organizerName: nil,
            attendeeNames: [],
            attendeeEmails: [],
            conferencingURL: conferencingURL,
            calendarName: "Work",
            calendarColor: nil,
            isRecurring: false
        )
    }
}
