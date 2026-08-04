import XCTest
@testable import Resonant

final class MeetingRecapShareBuilderTests: XCTestCase {
    func testPayloadUsesDistilledSummaryAndExtractsShareSections() {
        let meeting = MeetingEntry(
            id: UUID(uuidString: "B7A474DA-3DD1-4672-9996-5C9D3741B113")!,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            customTitle: "Launch sync",
            attendeeNamesJSON: "[\"Tom\",\"Ana\",\"Tom\"]"
        )
        meeting.distilledSummary = """
        We aligned on the launch plan.

        Decisions:
        - Keep recap sharing user-initiated
        - Use the existing Resonant site for guest links

        Action items:
        - Tom to review the final copy
        - Ana to check the app flow
        """

        let payload = MeetingRecapShareBuilder.payload(for: meeting)

        XCTAssertEqual(payload?.meetingTitle, "Launch sync")
        XCTAssertEqual(payload?.summary, "We aligned on the launch plan.")
        XCTAssertEqual(payload?.attendees, ["Tom", "Ana"])
        XCTAssertEqual(payload?.decisions.map(\.text), [
            "Keep recap sharing user-initiated",
            "Use the existing Resonant site for guest links"
        ])
        XCTAssertEqual(payload?.actionItems.map(\.text), [
            "Tom to review the final copy",
            "Ana to check the app flow"
        ])
    }

    func testPayloadSeparatesStructuredMarkdownSummaryFromShareSections() {
        let meeting = MeetingEntry(
            id: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            customTitle: "Launch sync"
        )
        meeting.summary = """
        # Launch sync

        ## Summary
        - We aligned on launch scope.
        - Remaining risk is App Store timing.

        ## Decisions
        - Ship Friday

        ## Action items
        - Ana to review launch email

        ## Open questions
        - Confirm reviewer availability
        """

        let payload = MeetingRecapShareBuilder.payload(for: meeting)

        XCTAssertEqual(payload?.summary, """
        - We aligned on launch scope.
        - Remaining risk is App Store timing.
        """)
        XCTAssertEqual(payload?.decisions.map(\.text), ["Ship Friday"])
        XCTAssertEqual(payload?.actionItems.map(\.text), ["Ana to review launch email"])
        XCTAssertFalse(payload?.summary.contains("## Decisions") == true)
        XCTAssertFalse(payload?.summary.contains("## Action items") == true)
    }

    func testPayloadFallsBackToMeetingSummary() {
        let meeting = MeetingEntry(
            id: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            customTitle: "Customer call",
            summary: "Customer wants a private recap link."
        )

        let payload = MeetingRecapShareBuilder.payload(for: meeting)

        XCTAssertEqual(payload?.summary, "Customer wants a private recap link.")
        XCTAssertEqual(payload?.decisions, [])
        XCTAssertEqual(payload?.actionItems, [])
    }

    func testPayloadRequiresReviewedNotesOrSummary() {
        let meeting = MeetingEntry(id: UUID(), startedAt: Date())

        XCTAssertNil(MeetingRecapShareBuilder.payload(for: meeting))
    }

    func testLocalRecapTextFormatsCopyableSummary() {
        let payload = MeetingRecapPayload(
            meetingTitle: "Launch sync",
            meetingStartedAt: nil,
            summary: "We aligned on launch.",
            decisions: [MeetingRecapDecision(text: "Ship Friday")],
            actionItems: [MeetingRecapActionItem(text: "Review launch email", owner: "Ana")],
            attendees: ["Ana", "Tom"],
            transcriptExcerpt: nil
        )

        XCTAssertEqual(MeetingRecapShareBuilder.localRecapText(from: payload), """
        # Launch sync

        ## Summary
        We aligned on launch.

        ## Decisions
        - Ship Friday

        ## Action items
        - Review launch email (Ana)

        ## Attendees
        - Ana
        - Tom
        """)
    }

    func testPublicDisclosureMentionsExpirationAndPublicAccess() {
        let text = MeetingRecapShareBuilder.publicDisclosureText(expirationDays: 7)

        XCTAssertTrue(text.contains("public web page"))
        XCTAssertTrue(text.contains("7 days"))
        XCTAssertTrue(text.contains("Anyone with the link"))
    }

    func testEmailShareURLIncludesTitleLinkAndExpiration() throws {
        let shareURL = try XCTUnwrap(URL(string: "https://www.onresonant.com/recap/abc123"))
        let url = try XCTUnwrap(MeetingRecapShareBuilder.emailShareURL(
            meetingTitle: "Launch sync",
            shareURL: shareURL,
            expirationDays: 7
        ))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let queryItems = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })

        XCTAssertEqual(components.scheme, "mailto")
        XCTAssertEqual(queryItems["subject"], "Launch sync recap")
        XCTAssertTrue(queryItems["body"]?.contains(shareURL.absoluteString) == true)
        XCTAssertTrue(queryItems["body"]?.contains("expires in 7 days") == true)
    }

    func testContactURLsTargetResonantTeam() throws {
        let privateURL = try XCTUnwrap(MeetingRecapShareBuilder.privateLinkRequestURL(meetingTitle: "Board meeting"))
        let workspaceURL = try XCTUnwrap(MeetingRecapShareBuilder.workspaceSharingContactURL(meetingTitle: "Board meeting"))

        XCTAssertEqual(privateURL.scheme, "mailto")
        XCTAssertEqual(privateURL.path, MeetingRecapShareBuilder.teamContactEmail)
        XCTAssertTrue(privateURL.absoluteString.contains("Private"))
        XCTAssertEqual(workspaceURL.scheme, "mailto")
        XCTAssertEqual(workspaceURL.path, MeetingRecapShareBuilder.teamContactEmail)
        XCTAssertTrue(workspaceURL.absoluteString.contains("Workspace"))
    }
}
