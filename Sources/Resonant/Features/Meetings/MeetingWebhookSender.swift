import CryptoKit
import Foundation
import os

/// Fires POST requests to the user-configured webhook URL for meeting lifecycle events.
///
/// Deliveries flow through `MeetingWebhookOutbox`: every event is persisted to disk
/// before the network call, then a drain loop attempts delivery with exponential
/// backoff. This means transient network failures, app quit, or even a crash mid-send
/// can be replayed on the next launch — the user does not lose transcripts because the
/// notes service was briefly down.
///
/// Payloads include meeting transcript content plus calendar-backed metadata so external
/// workflows can bind a transcript to the original meeting identity.
@MainActor
final class MeetingWebhookSender {

    nonisolated private static let logger = Logger(
        subsystem: "com.resonance.resonant",
        category: "MeetingWebhookSender"
    )

    /// Backoff schedule indexed by attempt count (0-based). Tail is reused for
    /// further retries until `maxAttempts` is exhausted.
    nonisolated private static let backoffSchedule: [TimeInterval] = [
        2,    // 2s
        10,   // 10s
        30,   // 30s
        120,  // 2m
        600,  // 10m
        3_600 // 1h
    ]
    nonisolated static let maxAttempts = 6

    enum DeliveryEvent: String {
        case started = "meeting.started"
        case completed = "meeting.completed"
        case summaryReady = "meeting.summary_ready"
    }

    struct MeetingPayload: Codable, Sendable {
        let event: String
        let deliveryId: String
        let generatedAt: String
        let meeting: MeetingDetails
        let transcript: [TranscriptLine]?
        let fullTranscript: String?

        struct MeetingDetails: Codable, Sendable {
            let meetingId: String
            let title: String
            let startedAt: String
            let endedAt: String?
            let scheduledStartAt: String?
            let scheduledEndAt: String?
            let durationSeconds: Double
            let wordCount: Int
            let detectedApp: String?
            let calendarEventId: String?
            let organizer: String?
            let attendees: [String]
            let conferencingURL: String?
            let calendarName: String?
            let recordingOrigin: String?
            let notes: String?
            let postMeetingNotes: String?
            let summary: String?
            let markdownPath: String?
            let audioPath: String?
        }

        struct TranscriptLine: Codable, Sendable {
            let speaker: String
            let text: String
            let timestamp: String
        }
    }

    /// Snapshot of entry properties read on the main actor so delivery can run off-actor.
    struct EntrySnapshot: Sendable {
        let displayTitle: String
        let userNotes: String?
        let postMeetingNotes: String?
        let summary: String?
        let calendarEventID: String?
        let scheduledStartAt: Date?
        let scheduledEndAt: Date?
        let organizerName: String?
        let attendeeNames: [String]
        let speakerAliases: MeetingSpeakerAliasMap
        let conferencingURL: String?
        let calendarName: String?
        let recordingOrigin: String?
        let markdownPath: String?
        let audioPath: String?
    }

    // MARK: - Configuration

    private let outbox: MeetingWebhookOutbox
    private let urlSession: URLSession
    private var secretProvider: @Sendable () async -> String = { "" }
    private var drainTask: Task<Void, Never>?
    private var drainSleepTask: Task<Void, Never>?

    init(
        outbox: MeetingWebhookOutbox = .shared,
        urlSession: URLSession = .shared
    ) {
        self.outbox = outbox
        self.urlSession = urlSession
    }

    /// Wires the secret-resolution callback. AppState calls this once during init.
    func configure(secretProvider: @escaping @Sendable () async -> String) {
        self.secretProvider = secretProvider
    }

    func snapshotEntry(_ entry: MeetingEntry) -> EntrySnapshot {
        EntrySnapshot(
            displayTitle: entry.displayTitle,
            userNotes: entry.userNotes,
            postMeetingNotes: entry.postMeetingNotes,
            summary: entry.summary,
            calendarEventID: entry.calendarEventID,
            scheduledStartAt: entry.scheduledStartAt,
            scheduledEndAt: entry.scheduledEndAt,
            organizerName: entry.organizerName,
            attendeeNames: entry.attendeeNames,
            speakerAliases: entry.speakerAliases,
            conferencingURL: entry.conferencingURL,
            calendarName: entry.calendarName,
            recordingOrigin: entry.recordingOrigin?.rawValue,
            markdownPath: entry.markdownPath,
            audioPath: entry.audioPath
        )
    }

    // MARK: - Public enqueue API

    func enqueueStarted(
        session: MeetingSessionInfo,
        entrySnapshot: EntrySnapshot,
        webhookURL: String
    ) async {
        await enqueue(
            event: .started,
            meetingId: session.id.uuidString,
            startedAt: session.startedAt,
            endedAt: nil,
            detectedApp: session.detectedApp?.name,
            durationSeconds: 0,
            wordCount: 0,
            transcriptUtterances: [],
            entrySnapshot: entrySnapshot,
            summaryOverride: nil,
            webhookURL: webhookURL
        )
    }

    func enqueueCompleted(
        session: CompletedMeetingSession,
        entrySnapshot: EntrySnapshot,
        webhookURL: String
    ) async {
        await enqueue(
            event: .completed,
            meetingId: session.id.uuidString,
            startedAt: session.startedAt,
            endedAt: session.endedAt,
            detectedApp: session.detectedApp?.name,
            durationSeconds: session.durationSeconds,
            wordCount: session.wordCount,
            transcriptUtterances: session.utterances,
            entrySnapshot: entrySnapshot,
            summaryOverride: nil,
            webhookURL: webhookURL
        )
    }

    func enqueueSummaryReady(
        session: CompletedMeetingSession,
        entrySnapshot: EntrySnapshot,
        webhookURL: String,
        summary: String
    ) async {
        await enqueue(
            event: .summaryReady,
            meetingId: session.id.uuidString,
            startedAt: session.startedAt,
            endedAt: session.endedAt,
            detectedApp: session.detectedApp?.name,
            durationSeconds: session.durationSeconds,
            wordCount: session.wordCount,
            transcriptUtterances: session.utterances,
            entrySnapshot: entrySnapshot,
            summaryOverride: summary,
            webhookURL: webhookURL
        )
    }

    /// Kick the drain loop. Safe to call repeatedly — only one loop runs at a time.
    func resumeDrain() {
        if drainTask != nil {
            drainSleepTask?.cancel()
            return
        }
        drainTask = Task.detached(priority: .utility) { [weak self] in
            await self?.drainLoop()
        }
    }

    /// Replay pending envelopes after a settings change. Drops any whose URL no
    /// longer matches the configured destination.
    func reconcileDestination(currentURL: String, isEnabled: Bool) async {
        if !isEnabled {
            await outbox.dropAllPending(reason: "Meeting webhooks disabled before delivery.")
            return
        }
        let trimmed = currentURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            await outbox.dropAllPending(reason: "Webhook URL cleared before delivery.")
            return
        }
        await outbox.dropMismatchedDestinations(currentURL: trimmed)
        resumeDrain()
    }

    /// User-initiated retry from the delivery log UI.
    func retryFromLog(id: UUID, currentURL: String) async {
        let trimmedURL = currentURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validate(webhookURL: trimmedURL) else { return }
        if await outbox.retry(id: id, currentURL: trimmedURL) != nil {
            resumeDrain()
        }
    }

    /// Establishes a cancellation boundary before deleting sensitive payloads.
    func removeMeetings(ids: Set<UUID>) async {
        guard !ids.isEmpty else { return }
        await stopDrainAndWait()
        await outbox.removeMeetings(ids: ids)
    }

    func clearPersistedPayloads() async {
        await stopDrainAndWait()
        await outbox.removeAll()
    }

    private func stopDrainAndWait() async {
        drainSleepTask?.cancel()
        drainTask?.cancel()
        let activeDrain = drainTask
        await activeDrain?.value
        drainSleepTask = nil
        drainTask = nil
    }

    // MARK: - Enqueue → Outbox

    private func enqueue(
        event: DeliveryEvent,
        meetingId: String,
        startedAt: Date,
        endedAt: Date?,
        detectedApp: String?,
        durationSeconds: Double,
        wordCount: Int,
        transcriptUtterances: [MeetingUtterance],
        entrySnapshot: EntrySnapshot,
        summaryOverride: String?,
        webhookURL: String
    ) async {
        guard validate(webhookURL: webhookURL) else { return }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let transcriptLines = transcriptUtterances.map { utterance in
            MeetingPayload.TranscriptLine(
                speaker: utterance.speaker.resolvedDisplayLabel(using: entrySnapshot.speakerAliases),
                text: utterance.text,
                timestamp: isoFormatter.string(from: utterance.timestamp)
            )
        }

        let fullTranscript = transcriptUtterances
            .map { "\($0.speaker.resolvedDisplayLabel(using: entrySnapshot.speakerAliases)): \($0.text)" }
            .joined(separator: "\n")

        let deliveryId = UUID()
        let payload = MeetingPayload(
            event: event.rawValue,
            deliveryId: deliveryId.uuidString,
            generatedAt: isoFormatter.string(from: Date()),
            meeting: .init(
                meetingId: meetingId,
                title: entrySnapshot.displayTitle,
                startedAt: isoFormatter.string(from: startedAt),
                endedAt: endedAt.map(isoFormatter.string(from:)),
                scheduledStartAt: entrySnapshot.scheduledStartAt.map(isoFormatter.string(from:)),
                scheduledEndAt: entrySnapshot.scheduledEndAt.map(isoFormatter.string(from:)),
                durationSeconds: durationSeconds,
                wordCount: wordCount,
                detectedApp: detectedApp,
                calendarEventId: entrySnapshot.calendarEventID,
                organizer: entrySnapshot.organizerName,
                attendees: entrySnapshot.attendeeNames,
                conferencingURL: entrySnapshot.conferencingURL,
                calendarName: entrySnapshot.calendarName,
                recordingOrigin: entrySnapshot.recordingOrigin,
                notes: entrySnapshot.userNotes,
                postMeetingNotes: entrySnapshot.postMeetingNotes,
                summary: summaryOverride ?? entrySnapshot.summary,
                markdownPath: entrySnapshot.markdownPath,
                audioPath: entrySnapshot.audioPath
            ),
            transcript: transcriptLines.isEmpty ? nil : transcriptLines,
            fullTranscript: fullTranscript.isEmpty ? nil : fullTranscript
        )

        let envelope = MeetingWebhookOutbox.Envelope(
            id: deliveryId,
            event: event.rawValue,
            webhookURL: webhookURL.trimmingCharacters(in: .whitespacesAndNewlines),
            payload: payload,
            createdAt: Date(),
            state: .pending,
            attempts: 0,
            lastError: nil,
            lastStatusCode: nil,
            lastAttemptAt: nil,
            nextAttemptAt: Date()
        )

        _ = await outbox.enqueue(envelope)
        resumeDrain()
    }

    private nonisolated func validate(webhookURL: String) -> Bool {
        let trimmed = webhookURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else {
            Self.logger.warning("Webhook URL invalid; skipping enqueue.")
            return false
        }
        guard url.scheme == "https" || (url.scheme == "http" && Self.isLocalhost(url)) else {
            Self.logger.warning("Webhook URL rejected (HTTPS required unless localhost).")
            return false
        }
        return true
    }

    // MARK: - Drain loop

    private func drainLoop() async {
        defer {
            drainSleepTask?.cancel()
            drainSleepTask = nil
            drainTask = nil
        }
        while !Task.isCancelled {
            let due = await outbox.dueEnvelopes()
            if due.isEmpty {
                guard let next = await outbox.nextScheduledAttempt() else { return }
                let delay = max(1, next.timeIntervalSinceNow)
                let nanos = UInt64(min(delay, 3_600) * 1_000_000_000)
                let sleepTask = Task {
                    _ = try? await Task.sleep(nanoseconds: nanos)
                }
                drainSleepTask = sleepTask
                await sleepTask.value
                drainSleepTask = nil
                continue
            }
            for envelope in due {
                await deliver(envelope)
                if Task.isCancelled { return }
            }
        }
    }

    private func deliver(_ envelope: MeetingWebhookOutbox.Envelope) async {
        guard let url = URL(string: envelope.webhookURL) else {
            var failed = envelope
            failed.state = .failed
            failed.lastError = "Invalid URL"
            failed.lastAttemptAt = Date()
            await outbox.update(failed)
            return
        }

        let secret = await secretProvider()
        let attempts = envelope.attempts + 1

        let outcome = await Self.performRequest(
            url: url,
            payload: envelope.payload,
            secret: secret,
            session: urlSession
        )

        var updated = envelope
        updated.attempts = attempts
        updated.lastAttemptAt = Date()
        updated.lastStatusCode = outcome.statusCode

        switch outcome.disposition {
        case .delivered:
            updated.state = .delivered
            updated.lastError = nil
            updated.nextAttemptAt = nil
            Self.logger.info("Webhook delivered (event=\(envelope.event, privacy: .public), attempts=\(attempts, privacy: .public))")
        case .retry(let reason):
            if attempts >= Self.maxAttempts {
                updated.state = .failed
                updated.lastError = "\(reason) — gave up after \(attempts) attempts."
                updated.nextAttemptAt = nil
                Self.logger.warning("Webhook failed permanently (event=\(envelope.event, privacy: .public), reason=\(reason, privacy: .public))")
            } else {
                let backoff = Self.backoffSchedule[min(attempts - 1, Self.backoffSchedule.count - 1)]
                updated.state = .pending
                updated.lastError = reason
                updated.nextAttemptAt = Date().addingTimeInterval(backoff)
                Self.logger.info("Webhook retry scheduled in \(backoff, privacy: .public)s (event=\(envelope.event, privacy: .public), attempts=\(attempts, privacy: .public))")
            }
        case .permanent(let reason):
            updated.state = .failed
            updated.lastError = reason
            updated.nextAttemptAt = nil
            Self.logger.warning("Webhook rejected by endpoint (event=\(envelope.event, privacy: .public), reason=\(reason, privacy: .public))")
        }

        await outbox.update(updated)
    }

    // MARK: - HTTP

    private enum Disposition {
        case delivered
        case retry(String)
        case permanent(String)
    }

    private struct Outcome {
        let disposition: Disposition
        let statusCode: Int?
    }

    nonisolated private static func performRequest(
        url: URL,
        payload: MeetingPayload,
        secret: String,
        session: URLSession
    ) async -> Outcome {
        let encoder = JSONEncoder()
        let body: Data
        do {
            body = try encoder.encode(payload)
        } catch {
            return Outcome(disposition: .permanent("Failed to encode payload: \(error.localizedDescription)"), statusCode: nil)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Resonant/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue(payload.event, forHTTPHeaderField: "X-Resonant-Event")
        request.setValue(payload.deliveryId, forHTTPHeaderField: "X-Resonant-Delivery")
        request.timeoutInterval = 30
        request.httpBody = body

        let trimmedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSecret.isEmpty {
            let timestamp = String(Int(Date().timeIntervalSince1970))
            let signed = signature(for: body, timestamp: timestamp, secret: trimmedSecret)
            request.setValue(timestamp, forHTTPHeaderField: "X-Resonant-Timestamp")
            request.setValue("sha256=\(signed)", forHTTPHeaderField: "X-Resonant-Signature")
        }

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return Outcome(disposition: .retry("Non-HTTP response."), statusCode: nil)
            }
            let status = http.statusCode
            if (200..<300).contains(status) {
                return Outcome(disposition: .delivered, statusCode: status)
            }
            if status == 408 || status == 425 || status == 429 || (500..<600).contains(status) {
                return Outcome(disposition: .retry("HTTP \(status)"), statusCode: status)
            }
            return Outcome(disposition: .permanent("HTTP \(status)"), statusCode: status)
        } catch let urlError as URLError {
            return Outcome(disposition: .retry("Network error: \(urlError.localizedDescription)"), statusCode: nil)
        } catch {
            return Outcome(disposition: .retry("Transport error: \(error.localizedDescription)"), statusCode: nil)
        }
    }

    nonisolated static func signature(for body: Data, timestamp: String, secret: String) -> String {
        var signedData = Data(timestamp.utf8)
        signedData.append(Data(".".utf8))
        signedData.append(body)
        let key = SymmetricKey(data: Data(secret.utf8))
        let digest = HMAC<SHA256>.authenticationCode(for: signedData, using: key)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func isLocalhost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }
}
