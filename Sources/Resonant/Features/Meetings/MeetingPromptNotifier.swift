import Foundation
import UserNotifications

@MainActor
final class MeetingPromptNotifier {

    nonisolated static let categoryIdentifier = "meeting_detected_prompt"
    nonisolated static let requestIdentifier = "meeting_detected_prompt_request"
    nonisolated static let startRecordingActionIdentifier = "meeting_detected_start_recording"
    nonisolated static let skipPromptActionIdentifier = "meeting_detected_skip"
    nonisolated static let calendarPromptCategoryIdentifier = "meeting_calendar_prompt"
    nonisolated static let calendarPromptRequestPrefix = "meeting_calendar_prompt_request_"
    nonisolated static let calendarPromptOpenCallAndStartActionIdentifier = "meeting_calendar_open_call_start_notes"
    nonisolated static let calendarPromptOpenCallOnlyActionIdentifier = "meeting_calendar_open_call_only"
    nonisolated static let calendarPromptSkipActionIdentifier = "meeting_calendar_skip"
    nonisolated static let userInfoBundleIDKey = "meeting_bundle_id"
    nonisolated static let userInfoAppNameKey = "meeting_app_name"
    nonisolated static let userInfoWindowTitleKey = "meeting_window_title"
    nonisolated static let userInfoBrowserURLKey = "meeting_browser_url"
    nonisolated static let userInfoCalendarTitleKey = "meeting_calendar_title"
    nonisolated static let userInfoCalendarIDKey = "meeting_calendar_id"
    nonisolated static let userInfoCalendarStartDateKey = "meeting_calendar_start_date"
    nonisolated static let userInfoCalendarEndDateKey = "meeting_calendar_end_date"
    nonisolated static let userInfoCalendarURLKey = "meeting_calendar_url"
    nonisolated static let userInfoCalendarNameKey = "meeting_calendar_name"
    nonisolated static let userInfoOrganizerNameKey = "meeting_organizer_name"
    nonisolated static let userInfoAttendeeNamesKey = "meeting_attendee_names"
    nonisolated static let userInfoAttendeeEmailsKey = "meeting_attendee_emails"
    nonisolated static let calendarPromptLeadTime: TimeInterval = 90

    nonisolated private static let calendarPromptMinimumDelay: TimeInterval = 5
    nonisolated private static let maxScheduledCalendarPrompts = 24

    func configure() {
        guard AppRuntime.supportsUserNotifications else { return }

        let startAction = UNNotificationAction(
            identifier: Self.startRecordingActionIdentifier,
            title: "Start recording"
        )
        let skipAction = UNNotificationAction(
            identifier: Self.skipPromptActionIdentifier,
            title: "Not now"
        )
        let detectedCategory = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [startAction, skipAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        let openCallAndStartAction = UNNotificationAction(
            identifier: Self.calendarPromptOpenCallAndStartActionIdentifier,
            title: "Open call & notes",
            options: [.foreground]
        )
        let openCallOnlyAction = UNNotificationAction(
            identifier: Self.calendarPromptOpenCallOnlyActionIdentifier,
            title: "Open call",
            options: [.foreground]
        )
        let skipCalendarPromptAction = UNNotificationAction(
            identifier: Self.calendarPromptSkipActionIdentifier,
            title: "Not now"
        )
        let calendarCategory = UNNotificationCategory(
            identifier: Self.calendarPromptCategoryIdentifier,
            actions: [openCallAndStartAction, openCallOnlyAction, skipCalendarPromptAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        // Single registration point: setNotificationCategories replaces the
        // whole set, so every category the app uses must be included here.
        UNUserNotificationCenter.current().setNotificationCategories([
            detectedCategory,
            calendarCategory,
            WordLearnPromptNotifier.category,
        ])
    }

    func requestAuthorizationIfNeeded() async -> Bool {
        guard AppRuntime.supportsUserNotifications else { return false }

        let center = UNUserNotificationCenter.current()
        let settings = await notificationSettings(for: center)

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    func deliverPrompt(for meeting: MeetingContextDetector.DetectedMeeting) async {
        guard AppRuntime.supportsUserNotifications else { return }
        guard await requestAuthorizationIfNeeded() else { return }

        let content = UNMutableNotificationContent()
        content.title = "Record this meeting?"
        if let calendarTitle = meeting.calendarHint?.title.trimmingCharacters(in: .whitespacesAndNewlines),
           !calendarTitle.isEmpty {
            content.body = "\"\(calendarTitle)\" looks active. Start recording to capture notes and transcript."
        } else {
            content.body = "\(meeting.app.name) looks active. Start recording to capture notes and transcript."
        }
        content.categoryIdentifier = Self.categoryIdentifier
        content.userInfo = Self.notificationUserInfo(for: meeting)

        let request = UNNotificationRequest(
            identifier: Self.requestIdentifier,
            content: content,
            trigger: nil
        )

        let center = UNUserNotificationCenter.current()
        Self.removePromptNotifications(from: center)
        try? await center.add(request)
    }

    func scheduleCalendarPrompts(for events: [MeetingCalendarEvent], now: Date = Date()) async {
        guard AppRuntime.supportsUserNotifications else { return }
        guard await requestAuthorizationIfNeeded() else { return }

        let requests = events
            .sorted { lhs, rhs in
                if lhs.startDate != rhs.startDate {
                    return lhs.startDate < rhs.startDate
                }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            .compactMap { Self.calendarPromptRequest(for: $0, now: now) }
            .prefix(Self.maxScheduledCalendarPrompts)

        let desiredIdentifiers = Set(requests.map(\.identifier))
        let center = UNUserNotificationCenter.current()
        let pendingRequests = await pendingNotificationRequests(from: center)
        let deliveredNotifications = await deliveredNotifications(from: center)
        let staleCalendarPromptIdentifiers = pendingRequests
            .map(\.identifier)
            + deliveredNotifications.map(\.request.identifier)
        let staleIdentifiers = staleCalendarPromptIdentifiers
            .filter(Self.isCalendarPromptIdentifier)
            .filter { !desiredIdentifiers.contains($0) }

        if !staleIdentifiers.isEmpty {
            Self.removeCalendarPromptNotifications(withIdentifiers: staleIdentifiers, from: center)
        }

        guard !requests.isEmpty else { return }

        for request in requests {
            try? await center.add(request)
        }
    }

    func clearPrompt() {
        guard AppRuntime.supportsUserNotifications else { return }

        let center = UNUserNotificationCenter.current()
        Self.removePromptNotifications(from: center)
    }

    func clearCalendarPrompt(for meeting: MeetingContextDetector.DetectedMeeting) {
        guard AppRuntime.supportsUserNotifications,
              let hint = meeting.calendarHint else { return }

        let identifier = Self.calendarPromptRequestIdentifier(
            calendarEventID: hint.id,
            startDate: hint.startDate
        )
        Self.removeCalendarPromptNotifications(withIdentifiers: [identifier], from: UNUserNotificationCenter.current())
    }

    func clearCalendarPrompts() {
        guard AppRuntime.supportsUserNotifications else { return }

        Task { [weak self] in
            guard let self else { return }
            let center = UNUserNotificationCenter.current()
            let requests = await self.pendingNotificationRequests(from: center)
            let delivered = await self.deliveredNotifications(from: center)
            let identifiers = (requests.map(\.identifier) + delivered.map(\.request.identifier))
                .filter(Self.isCalendarPromptIdentifier)
            Self.removeCalendarPromptNotifications(withIdentifiers: identifiers, from: center)
        }
    }

    nonisolated static func isCalendarPromptIdentifier(_ identifier: String) -> Bool {
        identifier.hasPrefix(calendarPromptRequestPrefix)
    }

    nonisolated static func calendarPromptRequestIdentifier(for event: MeetingCalendarEvent) -> String {
        calendarPromptRequestIdentifier(calendarEventID: event.id, startDate: event.startDate)
    }

    nonisolated static func calendarPromptTriggerDate(
        for event: MeetingCalendarEvent,
        now: Date = Date()
    ) -> Date? {
        guard event.conferencingURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }
        guard event.startDate > now else { return nil }

        let desiredTriggerDate = event.startDate.addingTimeInterval(-calendarPromptLeadTime)
        let minimumTriggerDate = now.addingTimeInterval(calendarPromptMinimumDelay)
        return max(desiredTriggerDate, minimumTriggerDate)
    }

    private nonisolated static func removePromptNotifications(from center: UNUserNotificationCenter) {
        center.removePendingNotificationRequests(withIdentifiers: [requestIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [requestIdentifier])
    }

    private nonisolated static func removeCalendarPromptNotifications(
        withIdentifiers identifiers: [String],
        from center: UNUserNotificationCenter
    ) {
        guard !identifiers.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    private nonisolated static func calendarPromptRequestIdentifier(
        calendarEventID: String,
        startDate: Date
    ) -> String {
        let occurrenceKey = "\(calendarEventID)#\(Int(startDate.timeIntervalSince1970))"
        return calendarPromptRequestPrefix + sanitizedIdentifierComponent(occurrenceKey)
    }

    private nonisolated static func sanitizedIdentifierComponent(_ value: String) -> String {
        value.unicodeScalars
            .map { scalar in
                CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : "_"
            }
            .joined()
    }

    private nonisolated static func notificationUserInfo(
        for meeting: MeetingContextDetector.DetectedMeeting
    ) -> [AnyHashable: Any] {
        [
            userInfoBundleIDKey: meeting.app.bundleID,
            userInfoAppNameKey: meeting.app.name,
            userInfoWindowTitleKey: meeting.windowTitle ?? "",
            userInfoBrowserURLKey: meeting.browserURL ?? "",
            userInfoCalendarTitleKey: meeting.calendarHint?.title ?? "",
            userInfoCalendarIDKey: meeting.calendarHint?.id ?? "",
            userInfoCalendarStartDateKey: meeting.calendarHint?.startDate.timeIntervalSince1970 ?? 0,
            userInfoCalendarEndDateKey: meeting.calendarHint?.endDate.timeIntervalSince1970 ?? 0,
            userInfoCalendarURLKey: meeting.calendarHint?.conferencingURL ?? "",
            userInfoCalendarNameKey: meeting.calendarHint?.calendarName ?? "",
            userInfoOrganizerNameKey: meeting.calendarHint?.organizerName ?? "",
            userInfoAttendeeNamesKey: meeting.calendarHint?.attendeeNames ?? [],
            userInfoAttendeeEmailsKey: meeting.calendarHint?.attendeeEmails ?? [],
        ]
    }

    private nonisolated static func calendarPromptRequest(
        for event: MeetingCalendarEvent,
        now: Date
    ) -> UNNotificationRequest? {
        guard let triggerDate = calendarPromptTriggerDate(for: event, now: now) else {
            return nil
        }

        let meeting = MeetingContextDetector.DetectedMeeting(
            app: MeetingApp(
                bundleID: MeetingContextDetector.calendarOnlyBundleID,
                name: "Scheduled meeting"
            ),
            windowTitle: event.title,
            browserURL: event.conferencingURL,
            calendarHint: event.hint,
            autoStartEligible: false
        )

        let content = UNMutableNotificationContent()
        content.title = "\(event.title) starts soon"
        content.body = "Open the call and start live notes with transcript."
        content.categoryIdentifier = calendarPromptCategoryIdentifier
        content.userInfo = notificationUserInfo(for: meeting)

        let delay = max(calendarPromptMinimumDelay, triggerDate.timeIntervalSince(now))
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        return UNNotificationRequest(
            identifier: calendarPromptRequestIdentifier(for: event),
            content: content,
            trigger: trigger
        )
    }

    private func pendingNotificationRequests(from center: UNUserNotificationCenter) async -> [UNNotificationRequest] {
        await withCheckedContinuation { continuation in
            center.getPendingNotificationRequests { requests in
                continuation.resume(returning: requests)
            }
        }
    }

    private func deliveredNotifications(from center: UNUserNotificationCenter) async -> [UNNotification] {
        await withCheckedContinuation { continuation in
            center.getDeliveredNotifications { notifications in
                continuation.resume(returning: notifications)
            }
        }
    }

    private func notificationSettings(for center: UNUserNotificationCenter) async -> UNNotificationSettings {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings)
            }
        }
    }
}
