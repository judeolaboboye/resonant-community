import XCTest
@testable import Resonant

final class MeetingWebhookOutboxTests: XCTestCase {

    private var tempFileURL: URL!

    override func setUp() {
        super.setUp()
        tempFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("outbox-tests-\(UUID().uuidString).json")
    }

    override func tearDown() {
        if let url = tempFileURL { try? FileManager.default.removeItem(at: url) }
        super.tearDown()
    }

    // MARK: - Persistence roundtrip

    func testEnqueuePersistsToDisk() async throws {
        let outbox = MeetingWebhookOutbox(fileURL: tempFileURL)
        let envelope = Self.makeEnvelope(event: "meeting.started")
        _ = await outbox.enqueue(envelope)

        // New outbox instance loads from disk and finds the entry.
        let reloaded = MeetingWebhookOutbox(fileURL: tempFileURL)
        let recent = await reloaded.recent(limit: 10)
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent.first?.id, envelope.id)
        XCTAssertEqual(recent.first?.state, .pending)
    }

    func testUpdatePersistsStateTransitions() async throws {
        let outbox = MeetingWebhookOutbox(fileURL: tempFileURL)
        var envelope = Self.makeEnvelope()
        envelope = await outbox.enqueue(envelope)

        envelope.state = .delivered
        envelope.attempts = 1
        envelope.lastStatusCode = 200
        await outbox.update(envelope)

        let reloaded = MeetingWebhookOutbox(fileURL: tempFileURL)
        let recent = await reloaded.recent(limit: 5)
        XCTAssertEqual(recent.first?.state, .delivered)
        XCTAssertEqual(recent.first?.lastStatusCode, 200)
        XCTAssertEqual(recent.first?.attempts, 1)
    }

    // MARK: - Due envelopes / scheduling

    func testDueEnvelopesIncludesOnlyReadyOnes() async throws {
        let outbox = MeetingWebhookOutbox(fileURL: tempFileURL)
        let future = Date().addingTimeInterval(120)
        let past = Date().addingTimeInterval(-5)

        let readyEnvelope = Self.makeEnvelope(nextAttemptAt: past)
        let waitingEnvelope = Self.makeEnvelope(nextAttemptAt: future)

        _ = await outbox.enqueue(readyEnvelope)
        _ = await outbox.enqueue(waitingEnvelope)

        let due = await outbox.dueEnvelopes()
        XCTAssertEqual(due.count, 1)
        XCTAssertEqual(due.first?.id, readyEnvelope.id)

        let next = await outbox.nextScheduledAttempt()
        XCTAssertEqual(next, past)
    }

    // MARK: - Destination reconciliation

    func testDropMismatchedDestinationsMarksOldURLs() async throws {
        let outbox = MeetingWebhookOutbox(fileURL: tempFileURL)
        let oldEnvelope = Self.makeEnvelope(url: "https://old.example.com/hook")
        let newEnvelope = Self.makeEnvelope(url: "https://new.example.com/hook")

        _ = await outbox.enqueue(oldEnvelope)
        _ = await outbox.enqueue(newEnvelope)

        let dropped = await outbox.dropMismatchedDestinations(currentURL: "https://new.example.com/hook")
        XCTAssertEqual(dropped, 1)

        let recent = await outbox.recent(limit: 10)
        let droppedEntry = recent.first { $0.id == oldEnvelope.id }
        XCTAssertEqual(droppedEntry?.state, .dropped)
        let stillPending = recent.first { $0.id == newEnvelope.id }
        XCTAssertEqual(stillPending?.state, .pending)
    }

    func testDropAllPendingHonorsReason() async throws {
        let outbox = MeetingWebhookOutbox(fileURL: tempFileURL)
        _ = await outbox.enqueue(Self.makeEnvelope())
        _ = await outbox.enqueue(Self.makeEnvelope())

        let dropped = await outbox.dropAllPending(reason: "feature disabled")
        XCTAssertEqual(dropped, 2)

        let pending = await outbox.pendingEnvelopes()
        XCTAssertTrue(pending.isEmpty)

        let recent = await outbox.recent(limit: 10)
        XCTAssertTrue(recent.allSatisfy { $0.state == .dropped && $0.lastError == "feature disabled" })
    }

    // MARK: - Retry

    func testRetryRequeuesFailedEnvelopeForCurrentURL() async throws {
        let outbox = MeetingWebhookOutbox(fileURL: tempFileURL)
        var envelope = Self.makeEnvelope()
        envelope = await outbox.enqueue(envelope)

        envelope.state = .failed
        envelope.lastError = "Network down"
        await outbox.update(envelope)

        let requeued = await outbox.retry(id: envelope.id, currentURL: envelope.webhookURL)
        XCTAssertEqual(requeued?.state, .pending)
        XCTAssertNil(requeued?.lastError)
        XCTAssertNotNil(requeued?.nextAttemptAt)

        let pending = await outbox.pendingEnvelopes()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.id, envelope.id)
    }

    func testRetryIgnoresDroppedOrStaleDestinationEnvelope() async throws {
        let outbox = MeetingWebhookOutbox(fileURL: tempFileURL)
        var dropped = Self.makeEnvelope(url: "https://old.example.com/hook")
        dropped = await outbox.enqueue(dropped)
        dropped.state = .dropped
        dropped.lastError = "Webhook URL changed before delivery."
        await outbox.update(dropped)

        let droppedRetry = await outbox.retry(id: dropped.id, currentURL: dropped.webhookURL)
        XCTAssertNil(droppedRetry)

        var failed = Self.makeEnvelope(url: "https://old.example.com/hook")
        failed = await outbox.enqueue(failed)
        failed.state = .failed
        failed.lastError = "Network down"
        await outbox.update(failed)

        let staleRetry = await outbox.retry(id: failed.id, currentURL: "https://new.example.com/hook")
        XCTAssertNil(staleRetry)

        let pending = await outbox.pendingEnvelopes()
        XCTAssertTrue(pending.isEmpty)
    }

    // MARK: - History trim

    func testTrimHistoryKeepsPendingEvenWhenOverCap() async throws {
        let cap = 3
        let outbox = MeetingWebhookOutbox(fileURL: tempFileURL, maxHistory: cap)

        // 4 delivered + 1 pending
        for i in 0..<4 {
            var env = Self.makeEnvelope(event: "delivered.\(i)")
            env = await outbox.enqueue(env)
            env.state = .delivered
            await outbox.update(env)
        }
        let stillPending = await outbox.enqueue(Self.makeEnvelope(event: "stays.pending"))

        let recent = await outbox.recent(limit: 10)
        // Pending always preserved
        XCTAssertTrue(recent.contains { $0.id == stillPending.id })
        // Total trimmed to cap
        XCTAssertLessThanOrEqual(recent.count, cap)
    }

    func testRemoveMeetingsDeletesPendingAndHistoricalPayloads() async throws {
        let outbox = MeetingWebhookOutbox(fileURL: tempFileURL)
        let removedMeetingID = UUID()
        var removed = Self.makeEnvelope(meetingID: removedMeetingID)
        removed = await outbox.enqueue(removed)
        removed.state = .delivered
        await outbox.update(removed)
        _ = await outbox.enqueue(Self.makeEnvelope(meetingID: removedMeetingID))
        let retained = await outbox.enqueue(Self.makeEnvelope(meetingID: UUID()))

        let removedCount = await outbox.removeMeetings(ids: [removedMeetingID])
        XCTAssertEqual(removedCount, 2)
        let recent = await outbox.recent(limit: 10)
        XCTAssertEqual(recent.map(\.id), [retained.id])
    }

    func testPersistenceRestrictsOutboxPermissions() async throws {
        let outbox = MeetingWebhookOutbox(fileURL: tempFileURL)
        _ = await outbox.enqueue(Self.makeEnvelope())
        let attributes = try FileManager.default.attributesOfItem(atPath: tempFileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    // MARK: - Helpers

    private static func makeEnvelope(
        event: String = "meeting.completed",
        url: String = "https://hook.example.com/in",
        nextAttemptAt: Date? = Date(),
        meetingID: UUID = UUID()
    ) -> MeetingWebhookOutbox.Envelope {
        let payload = MeetingWebhookSender.MeetingPayload(
            event: event,
            deliveryId: UUID().uuidString,
            generatedAt: "2026-05-21T00:00:00Z",
            meeting: .init(
                meetingId: meetingID.uuidString,
                title: "Test Meeting",
                startedAt: "2026-05-21T00:00:00Z",
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
        return MeetingWebhookOutbox.Envelope(
            id: UUID(),
            event: event,
            webhookURL: url,
            payload: payload,
            createdAt: Date(),
            state: .pending,
            attempts: 0,
            lastError: nil,
            lastStatusCode: nil,
            lastAttemptAt: nil,
            nextAttemptAt: nextAttemptAt
        )
    }
}
