import Foundation
import UserNotifications

@MainActor
final class MicrophoneSwitchNotifier {

    nonisolated static let requestIdentifier = "microphone_switch_notice_request"

    nonisolated static func handlesNotification(identifier: String) -> Bool {
        identifier == requestIdentifier
    }

    func deliverSelectedMicrophoneUnavailableNotice(
        unavailableDeviceName: String?,
        fallbackDeviceName: String?
    ) async {
        let unavailableLabel = microphoneLabel(
            unavailableDeviceName,
            fallback: "the selected microphone"
        )
        let fallbackLabel = microphoneLabel(
            fallbackDeviceName,
            fallback: "the system default microphone"
        )
        await deliverNotice(
            title: "Microphone switched",
            body: "Resonant can't access \(unavailableLabel) anymore, so it switched to \(fallbackLabel)."
        )
    }

    func deliverClamshellSwitchNotice(
        from previousDeviceName: String,
        to newDeviceName: String
    ) async {
        let previousLabel = microphoneLabel(previousDeviceName, fallback: "the built-in microphone")
        let newLabel = microphoneLabel(newDeviceName, fallback: "an available microphone")
        await deliverNotice(
            title: "Microphone switched",
            body: "The lid is closed, so Resonant can't access \(previousLabel). It switched to \(newLabel)."
        )
    }

    private func deliverNotice(title: String, body: String) async {
        guard AppRuntime.supportsUserNotifications else { return }
        guard await requestAuthorizationIfNeeded() else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = ["kind": "microphone_switch"]

        let request = UNNotificationRequest(
            identifier: Self.requestIdentifier,
            content: content,
            trigger: nil
        )

        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.requestIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [Self.requestIdentifier])
        try? await center.add(request)
    }

    private func requestAuthorizationIfNeeded() async -> Bool {
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

    private func notificationSettings(for center: UNUserNotificationCenter) async -> UNNotificationSettings {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings)
            }
        }
    }

    private func microphoneLabel(_ name: String?, fallback: String) -> String {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return fallback
        }
        return "\"\(trimmed)\""
    }
}
