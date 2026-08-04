import Foundation
import os

/// Disk-backed queue for meeting webhook deliveries.
///
/// Envelopes survive app relaunch so a crash or quit mid-delivery does not lose
/// transcripts. Secrets are intentionally never persisted — the signing secret
/// lives in the keychain and is resolved per attempt by the sender.
actor MeetingWebhookOutbox {

    static let shared = MeetingWebhookOutbox()

    nonisolated private static let logger = Logger(
        subsystem: "com.resonance.resonant",
        category: "MeetingWebhookOutbox"
    )

    enum State: String, Codable, Sendable {
        case pending
        case delivered
        case failed
        case dropped
    }

    struct Envelope: Codable, Identifiable, Sendable {
        let id: UUID
        let event: String
        let webhookURL: String
        let payload: MeetingWebhookSender.MeetingPayload
        let createdAt: Date
        var state: State
        var attempts: Int
        var lastError: String?
        var lastStatusCode: Int?
        var lastAttemptAt: Date?
        var nextAttemptAt: Date?
    }

    private let fileURL: URL
    private let maxHistory: Int
    private var envelopes: [Envelope]

    init(
        fileURL: URL = MeetingWebhookOutbox.defaultFileURL(),
        maxHistory: Int = 200
    ) {
        self.fileURL = fileURL
        self.maxHistory = maxHistory
        self.envelopes = Self.load(from: fileURL)
    }

    @discardableResult
    func enqueue(_ envelope: Envelope) -> Envelope {
        var updated = envelope
        if updated.state == .pending && updated.nextAttemptAt == nil {
            updated.nextAttemptAt = Date()
        }
        envelopes.append(updated)
        trimHistory()
        persist()
        return updated
    }

    func update(_ envelope: Envelope) {
        guard let idx = envelopes.firstIndex(where: { $0.id == envelope.id }) else { return }
        envelopes[idx] = envelope
        trimHistory()
        persist()
    }

    /// Envelopes due for delivery now (state == pending, nextAttemptAt <= now).
    func dueEnvelopes(now: Date = Date()) -> [Envelope] {
        envelopes.filter { env in
            env.state == .pending && (env.nextAttemptAt ?? .distantPast) <= now
        }
    }

    /// All pending envelopes, regardless of nextAttemptAt.
    func pendingEnvelopes() -> [Envelope] {
        envelopes.filter { $0.state == .pending }
    }

    /// Soonest pending attempt time across the queue (nil if none pending).
    func nextScheduledAttempt() -> Date? {
        envelopes
            .filter { $0.state == .pending }
            .compactMap { $0.nextAttemptAt }
            .min()
    }

    /// Recent envelopes (newest first) for UI surface.
    func recent(limit: Int = 50) -> [Envelope] {
        Array(envelopes.suffix(limit).reversed())
    }

    /// Mark any pending envelope whose destination no longer matches as dropped.
    /// Returns the count dropped.
    @discardableResult
    func dropMismatchedDestinations(currentURL: String) -> Int {
        var dropped = 0
        for idx in envelopes.indices where envelopes[idx].state == .pending {
            if envelopes[idx].webhookURL != currentURL {
                envelopes[idx].state = .dropped
                envelopes[idx].lastError = "Webhook URL changed before delivery."
                dropped += 1
            }
        }
        if dropped > 0 { persist() }
        return dropped
    }

    /// Drop every pending envelope (used when the user disables the feature).
    @discardableResult
    func dropAllPending(reason: String) -> Int {
        var dropped = 0
        for idx in envelopes.indices where envelopes[idx].state == .pending {
            envelopes[idx].state = .dropped
            envelopes[idx].lastError = reason
            dropped += 1
        }
        if dropped > 0 { persist() }
        return dropped
    }

    /// Manually re-queue a failed envelope for another delivery attempt.
    func retry(id: UUID, currentURL: String) -> Envelope? {
        guard let idx = envelopes.firstIndex(where: { $0.id == id }) else { return nil }
        let trimmedURL = currentURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard envelopes[idx].state == .failed,
              !trimmedURL.isEmpty,
              envelopes[idx].webhookURL == trimmedURL
        else {
            return nil
        }
        envelopes[idx].state = .pending
        envelopes[idx].lastError = nil
        envelopes[idx].nextAttemptAt = Date()
        persist()
        return envelopes[idx]
    }

    /// Drop completed/failed history but keep pending in flight.
    func clearHistory() {
        envelopes.removeAll { $0.state != .pending }
        persist()
    }

    /// Permanently remove every persisted payload for selected meetings.
    @discardableResult
    func removeMeetings(ids: Set<UUID>) -> Int {
        guard !ids.isEmpty else { return 0 }
        let originalCount = envelopes.count
        envelopes.removeAll { envelope in
            guard let meetingID = UUID(uuidString: envelope.payload.meeting.meetingId) else {
                return false
            }
            return ids.contains(meetingID)
        }
        let removed = originalCount - envelopes.count
        if removed > 0 { persist() }
        return removed
    }

    /// Clear pending and historical payloads, including transcript bodies.
    func removeAll() {
        envelopes.removeAll()
        persist()
    }

    private func trimHistory() {
        guard envelopes.count > maxHistory else { return }
        let pending = envelopes.filter { $0.state == .pending }
        let finished = envelopes.filter { $0.state != .pending }
        let keepFinished = max(0, maxHistory - pending.count)
        let trimmedFinished = Array(finished.suffix(keepFinished))
        envelopes = (trimmedFinished + pending).sorted { $0.createdAt < $1.createdAt }
    }

    private func persist() {
        let snapshot = envelopes
        let url = fileURL
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let tempURL = url.appendingPathExtension("tmp")
            defer { try? FileManager.default.removeItem(at: tempURL) }
            try data.write(to: tempURL, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
            } else {
                try FileManager.default.moveItem(at: tempURL, to: url)
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            Self.logger.error("Outbox persist failed: \(error.localizedDescription)")
        }
    }

    nonisolated private static func load(from url: URL) -> [Envelope] {
        if FileManager.default.fileExists(atPath: url.path) {
            guard (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeRegular,
                  (try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)) != nil else {
                logger.error("Refusing an insecure webhook outbox file")
                return []
            }
        }
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([Envelope].self, from: data)
        } catch {
            logger.warning("Outbox load failed: \(error.localizedDescription)")
            return []
        }
    }

    nonisolated static func defaultFileURL() -> URL {
        AppSupportPaths.resonantRoot()
            .appendingPathComponent("meeting_webhook_outbox.json")
    }
}
