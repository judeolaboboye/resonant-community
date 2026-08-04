import Foundation
import UserNotifications

/// Posts "Learn this word?" notifications for correction pairs that are
/// plausible but too uncertain to auto-apply (e.g. a name misheard beyond the
/// silent-learn edit-distance cap). The user's response either adds a manual
/// dictionary entry or records a suppressed one so the pair is never re-asked.
@MainActor
final class WordLearnPromptNotifier {

    nonisolated static let categoryIdentifier = "dictionary_learn_prompt"
    nonisolated static let requestIdentifierPrefix = "dictionary_learn_prompt_"
    nonisolated static let learnActionIdentifier = "dictionary_learn_accept"
    nonisolated static let skipActionIdentifier = "dictionary_learn_skip"
    nonisolated static let userInfoSpokenKey = "dictionary_learn_spoken"
    nonisolated static let userInfoWrittenKey = "dictionary_learn_written"

    /// Why a prompt did or did not reach the user. The caller uses this to keep
    /// analytics honest — a suppressed prompt is not a shown prompt.
    enum PromptOutcome: Equatable {
        case delivered
        /// Cooldown or burst spacing held the prompt back.
        case suppressedByCooldown
        /// Notifications are unavailable in this runtime (e.g. no app bundle).
        case unsupported
        /// The user has never been asked for notification permission. We refuse
        /// to make a word edit the moment that system dialog first appears.
        case authorizationNotDetermined
        case authorizationDenied
    }

    /// Re-asking about the same pair within this window is nagging, not helping.
    static let promptCooldown: TimeInterval = 60 * 60 * 24

    /// Global cap between any two prompts, so a heavy editing session can't
    /// produce a burst of notifications.
    static let minimumPromptSpacing: TimeInterval = 60 * 10

    private var lastPromptedAt: [String: Date] = [:]
    private var lastAnyPromptAt: Date?

    nonisolated static var category: UNNotificationCategory {
        UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [
                UNNotificationAction(identifier: learnActionIdentifier, title: "Learn"),
                UNNotificationAction(identifier: skipActionIdentifier, title: "Not now"),
            ],
            intentIdentifiers: [],
            options: []
        )
    }

    nonisolated static func isLearnPromptIdentifier(_ identifier: String) -> Bool {
        identifier.hasPrefix(requestIdentifierPrefix)
    }

    nonisolated static func pair(
        from userInfo: [AnyHashable: Any]
    ) -> (spoken: String, written: String)? {
        guard let spoken = userInfo[userInfoSpokenKey] as? String,
              let written = userInfo[userInfoWrittenKey] as? String,
              !spoken.isEmpty, !written.isEmpty else {
            return nil
        }
        return (spoken, written)
    }

    /// Cooldown gate — callable without touching notification state so the
    /// caller can skip analytics for suppressed prompts.
    func shouldPrompt(spoken: String, now: Date = Date()) -> Bool {
        if let lastAny = lastAnyPromptAt,
           now.timeIntervalSince(lastAny) < Self.minimumPromptSpacing {
            return false
        }
        guard let last = lastPromptedAt[Self.pairKey(spoken: spoken)] else { return true }
        return now.timeIntervalSince(last) >= Self.promptCooldown
    }

    /// Records that a prompt for this pair went out, starting its cooldowns.
    func markPrompted(spoken: String, now: Date = Date()) {
        lastPromptedAt[Self.pairKey(spoken: spoken)] = now
        lastAnyPromptAt = now
    }

    @discardableResult
    func deliverPrompt(spoken: String, written: String, now: Date = Date()) async -> PromptOutcome {
        guard shouldPrompt(spoken: spoken, now: now) else { return .suppressedByCooldown }
        guard AppRuntime.supportsUserNotifications else { return .unsupported }

        if let blocked = await authorizationBlocker() { return blocked }

        markPrompted(spoken: spoken, now: now)

        let content = UNMutableNotificationContent()
        content.title = "Learn “\(written)”?"
        content.body = "You corrected “\(spoken)” to “\(written)”. Apply it automatically from now on?"
        content.categoryIdentifier = Self.categoryIdentifier
        content.userInfo = [
            Self.userInfoSpokenKey: spoken,
            Self.userInfoWrittenKey: written,
        ]

        // Same-pair prompts share an identifier so a repeat replaces the
        // previous notification instead of stacking.
        let request = UNNotificationRequest(
            identifier: Self.requestIdentifierPrefix + Self.pairKey(spoken: spoken),
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
        return .delivered
    }

    private nonisolated static func pairKey(spoken: String) -> String {
        spoken.lowercased()
    }

    /// Returns `nil` when a notification can go out, otherwise the reason it
    /// cannot. Deliberately never calls `requestAuthorization`: correcting a
    /// word is the wrong moment to spring the system notification dialog on a
    /// user who has never seen it, and it was the first such dialog a new user
    /// hit. Permission is asked for in contexts that explain themselves
    /// (onboarding, meeting setup); until then this prompt stays silent.
    nonisolated static func authorizationBlocker(
        for status: UNAuthorizationStatus
    ) -> PromptOutcome? {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return nil
        case .denied:
            return .authorizationDenied
        case .notDetermined:
            return .authorizationNotDetermined
        @unknown default:
            return .authorizationDenied
        }
    }

    private func authorizationBlocker() async -> PromptOutcome? {
        let center = UNUserNotificationCenter.current()
        let settings = await withCheckedContinuation { continuation in
            center.getNotificationSettings { continuation.resume(returning: $0) }
        }
        return Self.authorizationBlocker(for: settings.authorizationStatus)
    }
}
