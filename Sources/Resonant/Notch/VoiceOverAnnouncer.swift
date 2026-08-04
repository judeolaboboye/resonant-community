import AppKit
import Foundation

/// Speaks short status updates to VoiceOver users.
///
/// The notch conveys recording/transcribing/delivery state visually, and the audio
/// cues are undifferentiated tones — neither reaches a VoiceOver user. This posts
/// `.announcementRequested` so the screen reader speaks the transition.
///
/// No-ops entirely when VoiceOver is off, and swallows a repeat of the same
/// message inside `debounceInterval` so rapid state flapping cannot spam speech.
@MainActor
final class VoiceOverAnnouncer {

    typealias Poster = (String, NSAccessibilityPriorityLevel) -> Void

    static let shared = VoiceOverAnnouncer()

    private let isEnabled: () -> Bool
    private let now: () -> Date
    private let poster: Poster
    private let debounceInterval: TimeInterval

    private var lastMessage: String?
    private var lastPostedAt: Date?

    init(
        debounceInterval: TimeInterval = 2,
        isEnabled: @escaping () -> Bool = { NSWorkspace.shared.isVoiceOverEnabled },
        now: @escaping () -> Date = Date.init,
        poster: @escaping Poster = VoiceOverAnnouncer.postToSystem
    ) {
        self.debounceInterval = debounceInterval
        self.isEnabled = isEnabled
        self.now = now
        self.poster = poster
    }

    /// Speaks `message` unless VoiceOver is off or the same message was just spoken.
    func announce(_ message: String, priority: NSAccessibilityPriorityLevel = .medium) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isEnabled() else { return }

        let timestamp = now()
        if trimmed == lastMessage,
           let lastPostedAt,
           timestamp.timeIntervalSince(lastPostedAt) < debounceInterval {
            return
        }

        lastMessage = trimmed
        lastPostedAt = timestamp
        poster(trimmed, priority)
    }

    private static func postToSystem(_ message: String, priority: NSAccessibilityPriorityLevel) {
        guard let app = NSApp else { return }
        NSAccessibility.post(
            element: app,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: priority.rawValue
            ]
        )
    }
}
