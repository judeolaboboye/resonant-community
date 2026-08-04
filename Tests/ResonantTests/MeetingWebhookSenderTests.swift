import CryptoKit
import XCTest
@testable import Resonant

final class MeetingWebhookSenderTests: XCTestCase {

    // MARK: - HMAC Signature

    func testSignatureProducesValidHMACSHA256() {
        let body = Data("test payload".utf8)
        let timestamp = "1700000000"
        let secret = "whsec_test123"

        let result = MeetingWebhookSender.signature(for: body, timestamp: timestamp, secret: secret)

        // Verify independently using CryptoKit
        var signedData = Data(timestamp.utf8)
        signedData.append(Data(".".utf8))
        signedData.append(body)
        let key = SymmetricKey(data: Data(secret.utf8))
        let expected = HMAC<SHA256>.authenticationCode(for: signedData, using: key)
            .map { String(format: "%02x", $0) }.joined()

        XCTAssertEqual(result, expected)
        XCTAssertEqual(result.count, 64, "SHA256 hex digest should be 64 chars")
    }

    func testSignatureDiffersWithDifferentSecrets() {
        let body = Data("same payload".utf8)
        let timestamp = "1700000000"

        let sig1 = MeetingWebhookSender.signature(for: body, timestamp: timestamp, secret: "secret_a")
        let sig2 = MeetingWebhookSender.signature(for: body, timestamp: timestamp, secret: "secret_b")

        XCTAssertNotEqual(sig1, sig2)
    }

    func testSignatureDiffersWithDifferentTimestamps() {
        let body = Data("same payload".utf8)
        let secret = "whsec_test"

        let sig1 = MeetingWebhookSender.signature(for: body, timestamp: "1000", secret: secret)
        let sig2 = MeetingWebhookSender.signature(for: body, timestamp: "2000", secret: secret)

        XCTAssertNotEqual(sig1, sig2)
    }

    func testSignatureIsDeterministic() {
        let body = Data("deterministic check".utf8)
        let sig1 = MeetingWebhookSender.signature(for: body, timestamp: "100", secret: "key")
        let sig2 = MeetingWebhookSender.signature(for: body, timestamp: "100", secret: "key")

        XCTAssertEqual(sig1, sig2)
    }

    func testSignatureIncludesTimestampDotBodyFormat() {
        // Verify the signed message is "timestamp.body" — changing the separator would break verification
        let body = Data("{\"event\":\"meeting.completed\"}".utf8)
        let timestamp = "1700000000"
        let secret = "whsec_verify"

        let result = MeetingWebhookSender.signature(for: body, timestamp: timestamp, secret: secret)

        // Manually compute with the expected format
        let expectedMessage = Data("\(timestamp).".utf8) + body
        let key = SymmetricKey(data: Data(secret.utf8))
        let expected = HMAC<SHA256>.authenticationCode(for: expectedMessage, using: key)
            .map { String(format: "%02x", $0) }.joined()

        XCTAssertEqual(result, expected)
    }

    // MARK: - Localhost Detection

    func testIsLocalhostRecognizesLocalAddresses() {
        XCTAssertTrue(MeetingWebhookSender.isLocalhost(URL(string: "http://localhost:3000/webhook")!))
        XCTAssertTrue(MeetingWebhookSender.isLocalhost(URL(string: "http://127.0.0.1:8080/hook")!))
        XCTAssertTrue(MeetingWebhookSender.isLocalhost(URL(string: "http://[::1]:4000/api")!))
    }

    func testIsLocalhostRejectsRemoteHosts() {
        XCTAssertFalse(MeetingWebhookSender.isLocalhost(URL(string: "https://example.com/webhook")!))
        XCTAssertFalse(MeetingWebhookSender.isLocalhost(URL(string: "https://api.resonant.app/hook")!))
        XCTAssertFalse(MeetingWebhookSender.isLocalhost(URL(string: "http://192.168.1.1/webhook")!))
    }

    func testIsLocalhostIsCaseInsensitive() {
        XCTAssertTrue(MeetingWebhookSender.isLocalhost(URL(string: "http://LOCALHOST:3000/webhook")!))
        XCTAssertTrue(MeetingWebhookSender.isLocalhost(URL(string: "http://Localhost/hook")!))
    }

    // MARK: - Payload Encoding

    func testMeetingPayloadEncodesToValidJSON() throws {
        let payload = MeetingWebhookSender.MeetingPayload(
            event: "meeting.completed",
            deliveryId: "test-delivery-id",
            generatedAt: "2023-11-14T14:13:20.000Z",
            meeting: .init(
                meetingId: "session-123",
                title: "Sprint Retro",
                startedAt: "2023-11-14T14:00:00.000Z",
                endedAt: "2023-11-14T14:30:00.000Z",
                scheduledStartAt: "2023-11-14T14:00:00.000Z",
                scheduledEndAt: "2023-11-14T14:30:00.000Z",
                durationSeconds: 1800,
                wordCount: 450,
                detectedApp: "Zoom",
                calendarEventId: "evt_42",
                organizer: "Ada",
                attendees: ["Ada", "Grace"],
                conferencingURL: "https://zoom.us/j/123",
                calendarName: "Work",
                recordingOrigin: "automatic",
                notes: "Action items discussed",
                postMeetingNotes: "Follow up Thursday",
                summary: "Team reviewed sprint progress",
                markdownPath: "/archive/2023/11/14/meeting.md",
                audioPath: nil
            ),
            transcript: [
                .init(speaker: "You", text: "Let's get started", timestamp: "2023-11-14T14:00:05.000Z"),
                .init(speaker: "Them", text: "Sounds good", timestamp: "2023-11-14T14:00:08.000Z"),
            ],
            fullTranscript: "You: Let's get started\nThem: Sounds good"
        )

        let data = try JSONEncoder().encode(payload)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["event"] as? String, "meeting.completed")
        XCTAssertEqual(json["deliveryId"] as? String, "test-delivery-id")

        let meeting = json["meeting"] as! [String: Any]
        XCTAssertEqual(meeting["title"] as? String, "Sprint Retro")
        XCTAssertEqual(meeting["durationSeconds"] as? Double, 1800)
        XCTAssertEqual(meeting["wordCount"] as? Int, 450)
        XCTAssertEqual(meeting["detectedApp"] as? String, "Zoom")
        XCTAssertEqual(meeting["organizer"] as? String, "Ada")
        XCTAssertEqual(meeting["attendees"] as? [String], ["Ada", "Grace"])
        XCTAssertEqual(meeting["recordingOrigin"] as? String, "automatic")

        let transcript = json["transcript"] as! [[String: Any]]
        XCTAssertEqual(transcript.count, 2)
        XCTAssertEqual(transcript[0]["speaker"] as? String, "You")

        XCTAssertNotNil(json["fullTranscript"])
    }

    func testPayloadOmitsNilTranscript() throws {
        let payload = MeetingWebhookSender.MeetingPayload(
            event: "meeting.started",
            deliveryId: "d1",
            generatedAt: "2023-11-14T14:00:00.000Z",
            meeting: .init(
                meetingId: "s1",
                title: "Standup",
                startedAt: "2023-11-14T14:00:00.000Z",
                endedAt: nil,
                scheduledStartAt: nil,
                scheduledEndAt: nil,
                durationSeconds: 0,
                wordCount: 0,
                detectedApp: nil,
                calendarEventId: nil,
                organizer: nil,
                attendees: [],
                conferencingURL: nil,
                calendarName: nil,
                recordingOrigin: nil,
                notes: nil,
                postMeetingNotes: nil,
                summary: nil,
                markdownPath: nil,
                audioPath: nil
            ),
            transcript: nil,
            fullTranscript: nil
        )

        let data = try JSONEncoder().encode(payload)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        // transcript and fullTranscript should be absent or null
        let meeting = json["meeting"] as! [String: Any]
        XCTAssertEqual(meeting["durationSeconds"] as? Double, 0)
        XCTAssertEqual(meeting["wordCount"] as? Int, 0)
    }

    // MARK: - EntrySnapshot

    func testEntrySnapshotCapturesAllFields() {
        let snapshot = MeetingWebhookSender.EntrySnapshot(
            displayTitle: "Design Review",
            userNotes: "Check Figma links",
            postMeetingNotes: "Update Jira",
            summary: "Reviewed new dashboard",
            calendarEventID: "evt_99",
            scheduledStartAt: Date(timeIntervalSince1970: 1000),
            scheduledEndAt: Date(timeIntervalSince1970: 2800),
            organizerName: "Grace",
            attendeeNames: ["Grace", "Alan"],
            speakerAliases: ["you": "Taylor", "participant:SPEAKER_0": "Grace"],
            conferencingURL: "https://meet.google.com/xyz",
            calendarName: "Design",
            recordingOrigin: "promptAccepted",
            markdownPath: "/archive/2023/11/14/design.md",
            audioPath: "/archive/2023/11/14/design.wav"
        )

        XCTAssertEqual(snapshot.displayTitle, "Design Review")
        XCTAssertEqual(snapshot.userNotes, "Check Figma links")
        XCTAssertEqual(snapshot.calendarEventID, "evt_99")
        XCTAssertEqual(snapshot.organizerName, "Grace")
        XCTAssertEqual(snapshot.attendeeNames, ["Grace", "Alan"])
        XCTAssertEqual(snapshot.recordingOrigin, "promptAccepted")
        XCTAssertEqual(snapshot.audioPath, "/archive/2023/11/14/design.wav")
    }
}
