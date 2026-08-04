import XCTest
@testable import Resonant

final class ConvexClientTests: XCTestCase {

    func testConvexBearerTokenRejectsOpaqueWebsiteToken() {
        let token = "fixture-opaque-website-session-token-with-no-jwt-dot-separators0"

        XCTAssertNil(ConvexClient.convexBearerToken(from: token))
    }

    func testConvexBearerTokenAcceptsJWTShape() {
        let token = "header.payload.signature"

        XCTAssertEqual(ConvexClient.convexBearerToken(from: token), token)
    }

    func testInvalidAuthHeaderInvalidatesSession() {
        let responseBody = Data(#"{"code":"InvalidAuthHeader","message":"Could not parse JWT payload."}"#.utf8)

        XCTAssertTrue(
            ConvexClient.shouldInvalidateSession(
                statusCode: 400,
                responseBody: responseBody
            )
        )
    }

    func testDoesNotInvalidateSessionForNonAuthFailure() {
        let responseBody = Data(#"{"status":"error","errorMessage":"Function not found"}"#.utf8)

        XCTAssertFalse(
            ConvexClient.shouldInvalidateSession(
                statusCode: 404,
                responseBody: responseBody
            )
        )
    }

    func testExpiredJWTInvalidatesSession() {
        let responseBody = Data(#"{"code":"Unauthorized","message":"JWT expired"}"#.utf8)

        XCTAssertTrue(
            ConvexClient.shouldInvalidateSession(
                statusCode: 401,
                responseBody: responseBody
            )
        )
    }

    func testDictationCleanupSanitizationRejectsAssistantAcknowledgment() {
        let result = ConvexClient.sanitizeDictationCleanupResponse(
            original: "let me know once the deploy finishes so I can verify",
            result: "No changes needed.",
            profile: .message
        )

        XCTAssertFalse(result.accepted)
        XCTAssertNil(result.text)
        XCTAssertEqual(result.reason, "assistant-response")
    }

    func testDictationCleanupSanitizationReturnsAcceptedText() {
        let result = ConvexClient.sanitizeDictationCleanupResponse(
            original: "let me know once deploy finishes",
            result: "Let me know once deploy finishes.",
            profile: .message
        )

        XCTAssertTrue(result.accepted)
        XCTAssertEqual(result.text, "Let me know once deploy finishes")
        XCTAssertNil(result.reason)
    }

    func testMemoModelRouteFallbackOnlyRetriesUnsupportedRouteField() {
        XCTAssertTrue(ConvexClient.shouldRetryMemoWithoutModelRoute(
            errorText: "ArgumentValidationError: Object contains extra field `modelRoute`"
        ))

        XCTAssertFalse(ConvexClient.shouldRetryMemoWithoutModelRoute(
            errorText: "ArgumentValidationError: Object contains extra field `transcript`"
        ))

        XCTAssertFalse(ConvexClient.shouldRetryMemoWithoutModelRoute(
            errorText: "Validation failed at .transcript because the value was too large"
        ))
    }

    func testMeetingSummaryMemoRouteUsesLongerTimeout() {
        XCTAssertEqual(ConvexClient.memoProcessingTimeoutMs(for: nil), 12_000)
        XCTAssertEqual(ConvexClient.memoProcessingTimeoutMs(for: .meetingSummary), 45_000)
    }

    func testSelectionTransformAdvancedRouteUsesLongerTimeout() {
        XCTAssertEqual(ConvexClient.selectionTransformTimeoutMs(for: .quick), 12_000)
        XCTAssertEqual(ConvexClient.selectionTransformTimeoutMs(for: .advanced), 30_000)
    }

    func testSelectionTransformModelRouteFallbackOnlyRetriesUnsupportedRouteField() {
        XCTAssertTrue(ConvexClient.shouldRetrySelectionTransformWithoutModelRoute(
            errorText: "ArgumentValidationError: Object contains extra field `modelRoute`"
        ))

        XCTAssertFalse(ConvexClient.shouldRetrySelectionTransformWithoutModelRoute(
            errorText: "ArgumentValidationError: Object contains extra field `selectedText`"
        ))

        XCTAssertFalse(ConvexClient.shouldRetrySelectionTransformWithoutModelRoute(
            errorText: "Validation failed at .selectedText because the value was too large"
        ))
    }

    func testWorkspaceCloudUploadUsesSingleFixedScope() {
        XCTAssertFalse(WorkspaceCloudUploadOptions.current.includeContextMetadata)
        XCTAssertTrue(WorkspaceCloudUploadOptions.current.includeMeetingTranscripts)
        XCTAssertFalse(WorkspaceCloudUploadOptions.current.includeMeetingParticipants)
        XCTAssertTrue(WorkspaceCloudUploadOptions.current.includeSmartLinks)
        XCTAssertTrue(WorkspaceCloudUploadOptions.current.includeDictionary)
    }

    @MainActor
    func testWorkspaceDictationPayloadOmitsContextMetadataWhenDisabled() throws {
        let payload = try XCTUnwrap(ConvexClient.workspaceDictationPayload(
            from: [
                "id": "dictation-1",
                "timestamp": "2026-05-11T08:30:00Z",
                "text": "raw words",
                "sentText": "Delivered words",
                "app": "Safari",
                "windowTitle": "Private CRM",
                "url": "https://example.com/customer",
            ],
            options: WorkspaceCloudUploadOptions(
                includeContextMetadata: false,
                includeMeetingTranscripts: true,
                includeMeetingParticipants: false,
                includeSmartLinks: true,
                includeDictionary: true
            )
        ))

        XCTAssertEqual(payload["text"] as? String, "Delivered words")
        XCTAssertNil(payload["appName"])
        XCTAssertNil(payload["bundleId"])
        XCTAssertNil(payload["windowTitle"])
        XCTAssertNil(payload["browserUrl"])
    }

    @MainActor
    func testWorkspaceDictationPayloadIncludesContextWhenEnabled() throws {
        let payload = try XCTUnwrap(ConvexClient.workspaceDictationPayload(
            from: [
                "id": "dictation-1",
                "timestamp": "2026-05-11T08:30:00Z",
                "text": "raw words",
                "sentText": "Delivered words",
                "app": "Safari",
                "windowTitle": "Private CRM",
                "url": "https://example.com/customer",
            ],
            options: WorkspaceCloudUploadOptions(
                includeContextMetadata: true,
                includeMeetingTranscripts: true,
                includeMeetingParticipants: false,
                includeSmartLinks: true,
                includeDictionary: true
            )
        ))

        XCTAssertEqual(payload["appName"] as? String, "Safari")
        XCTAssertEqual(payload["windowTitle"] as? String, "Private CRM")
        XCTAssertEqual(payload["browserUrl"] as? String, "https://example.com/customer")
    }

    @MainActor
    func testWorkspaceMeetingPayloadRespectsTranscriptAndParticipantControls() throws {
        let base: [String: Any] = [
            "id": "meeting-1",
            "timestamp": "2026-05-11T09:00:00Z",
            "title": "Board sync",
            "markdown": "Full transcript",
            "summary": "Summary",
            "app": "Zoom",
            "calendarEventID": "event-secret",
            "organizerName": "Ada",
            "attendeeNames": ["Ada", "Grace"],
            "attendeeEmails": ["ada@example.com"],
            "speakerAliases": ["you": "Ada"],
            "conferencingURL": "https://zoom.us/j/123",
        ]

        let restricted = try XCTUnwrap(ConvexClient.workspaceMeetingPayload(
            from: base,
            options: WorkspaceCloudUploadOptions(
                includeContextMetadata: false,
                includeMeetingTranscripts: false,
                includeMeetingParticipants: false,
                includeSmartLinks: true,
                includeDictionary: true
            )
        ))
        XCTAssertNil(restricted["transcriptMarkdown"])
        XCTAssertNil(restricted["appName"])
        XCTAssertNil(restricted["calendarEventId"])
        XCTAssertNil(restricted["attendeeNames"])
        XCTAssertNil(restricted["attendeeEmails"])
        XCTAssertNil(restricted["speakerAliases"])

        let full = try XCTUnwrap(ConvexClient.workspaceMeetingPayload(
            from: base,
            options: WorkspaceCloudUploadOptions(
                includeContextMetadata: true,
                includeMeetingTranscripts: true,
                includeMeetingParticipants: true,
                includeSmartLinks: true,
                includeDictionary: true
            )
        ))
        XCTAssertEqual(full["transcriptMarkdown"] as? String, "Full transcript")
        XCTAssertEqual(full["appName"] as? String, "Zoom")
        XCTAssertEqual(full["calendarEventId"] as? String, "event-secret")
        XCTAssertEqual(full["attendeeNames"] as? [String], ["Ada", "Grace"])
        XCTAssertEqual(full["attendeeEmails"] as? [String], ["ada@example.com"])
        XCTAssertEqual(full["speakerAliases"] as? String, #"{"you":"Ada"}"#)
    }

    @MainActor
    func testWorkspaceSmartLinkPayloadsTrimAndFilterInvalidLinks() {
        let linkID = UUID(uuidString: "D9E92EC2-4D13-4F49-A43E-9CB7367A291B")!
        let payloads = ConvexClient.workspaceSmartLinkPayloads(from: [
            SmartLink(id: linkID, trigger: " docs ", url: " https://example.com/docs ", label: " Docs ", isEnabled: true),
            SmartLink(trigger: "empty", url: " "),
        ])

        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[0]["externalId"] as? String, "d9e92ec2-4d13-4f49-a43e-9cb7367a291b")
        XCTAssertEqual(payloads[0]["trigger"] as? String, "docs")
        XCTAssertEqual(payloads[0]["url"] as? String, "https://example.com/docs")
        XCTAssertEqual(payloads[0]["label"] as? String, "Docs")
        XCTAssertEqual(payloads[0]["isEnabled"] as? Bool, true)
    }

    @MainActor
    func testWorkspaceDictionaryPayloadsIncludeCorrectionMetadata() {
        let word = DictionaryWord(
            id: UUID(uuidString: "B7A474DA-3DD1-4672-9996-5C9D3741B113")!,
            spoken: " rezzonant ",
            written: " Resonant ",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            correctedCount: 3,
            seenUncorrectedCount: 1,
            isAutoLearned: true,
            isSuppressed: false,
            spokenIsRealWord: false,
            lastSeenAt: Date(timeIntervalSince1970: 1_700_000_060)
        )

        let payloads = ConvexClient.workspaceDictionaryPayloads(from: [
            DictionaryStore.WorkspaceWord(word: word)
        ])

        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[0]["externalId"] as? String, "b7a474da-3dd1-4672-9996-5c9d3741b113")
        XCTAssertEqual(payloads[0]["spoken"] as? String, "rezzonant")
        XCTAssertEqual(payloads[0]["written"] as? String, "Resonant")
        XCTAssertEqual(payloads[0]["createdAt"] as? Double, 1_700_000_000_000)
        XCTAssertEqual(payloads[0]["correctedCount"] as? Int, 3)
        XCTAssertEqual(payloads[0]["isAutoLearned"] as? Bool, true)
        XCTAssertEqual(payloads[0]["lastSeenAt"] as? Double, 1_700_000_060_000)
    }

    @MainActor
    func testMeetingRecapShareURLUsesPublicRecapToken() throws {
        let url = try XCTUnwrap(ConvexClient.meetingRecapShareURL(
            forToken: "abc123",
            baseURL: URL(string: "https://www.onresonant.com")!
        ))

        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "www.onresonant.com")
        XCTAssertEqual(url.path, "/recap/abc123")
        XCTAssertTrue(url.absoluteString.contains("utm_source=shared_recap"))
        XCTAssertTrue(url.absoluteString.contains("utm_medium=product_share"))
        XCTAssertTrue(url.absoluteString.contains("utm_campaign=meeting_recap"))
    }

    func testMeetingCompletionEmailArgsDoNotAcceptClientRecipients() {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let endedAt = startedAt.addingTimeInterval(600)
        let payload = MeetingCompletionEmailPayload(
            meetingId: "meeting-1",
            meetingTitle: "Customer call",
            startedAt: startedAt,
            endedAt: endedAt,
            durationSeconds: 600,
            detectedApp: "Zoom",
            conferencingURL: "https://zoom.us/j/123",
            markdownPath: "Meetings/customer-call.md",
            transcript: "You: Hello\nThem: Hi"
        )

        let args = ConvexClient.meetingCompletionEmailArgs(from: payload)

        XCTAssertEqual(args["recipientScope"] as? String, "authenticated_user")
        XCTAssertNil(args["to"])
        XCTAssertNil(args["email"])
        XCTAssertNil(args["recipient"])
        XCTAssertNil(args["recipients"])
        XCTAssertEqual(args["transcript"] as? String, "You: Hello\nThem: Hi")
        XCTAssertEqual(args["conferencingURL"] as? String, "https://zoom.us/j/123")
    }
}
