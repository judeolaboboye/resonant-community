import AppKit
import Foundation

@MainActor
struct AppRuntimeSupportActions {
    struct Dependencies {
        var activateApplication: (_ ignoringOtherApps: Bool) -> Void
        var openURL: (URL) -> Void = { url in
            DispatchQueue.global(qos: .userInitiated).async {
                _ = NSWorkspace.shared.open(url)
            }
        }
        var currentApplication: () -> NSRunningApplication = {
            NSRunningApplication.current
        }
        var refreshHotkeyRegistration: (_ promptIfNeeded: Bool) -> Void
        var postHogSettingsURLString: () -> String?
        var pasteDeliveryMode: () -> PasteDeliveryMode
        var pasteDiagnosticSnapshot: () -> PasteManager.DiagnosticSnapshot
        var deliverPasteDiagnosticText: (
            _ text: String,
            _ targetApplication: NSRunningApplication,
            _ deliveryMode: PasteDeliveryMode
        ) async -> Bool
        var lastPasteDeliveryFailure: () -> PasteManager.DeliveryFailure?
        var captureAnalytics: (_ event: String, _ properties: [String: Any]) -> Void
    }

    private enum SystemSettingsURL {
        static let accessibility = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        static let inputMonitoring = "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
    }

    private let dependencies: Dependencies

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    init(
        settingsManager: SettingsManager,
        hotkeyManager: HotkeyManager,
        pasteManager: PasteManager,
        analyticsManager: AnalyticsManager
    ) {
        self.init(dependencies: Dependencies(
            activateApplication: { ignoringOtherApps in
                NSApp.activate(ignoringOtherApps: ignoringOtherApps)
            },
            refreshHotkeyRegistration: { promptIfNeeded in
                _ = hotkeyManager.refreshRegistration(promptIfNeeded: promptIfNeeded)
            },
            postHogSettingsURLString: {
                settingsManager.postHogSettingsURL
            },
            pasteDeliveryMode: {
                settingsManager.pasteDeliveryMode
            },
            pasteDiagnosticSnapshot: {
                pasteManager.diagnosticSnapshot()
            },
            deliverPasteDiagnosticText: { text, targetApplication, deliveryMode in
                await pasteManager.deliver(
                    text: text,
                    copyToClipboard: false,
                    autoPaste: true,
                    autoSend: false,
                    targetApplication: targetApplication,
                    windowTitle: "Paste Diagnostics",
                    browserURL: nil,
                    deliveryMode: deliveryMode
                )
            },
            lastPasteDeliveryFailure: {
                pasteManager.lastDeliveryFailure
            },
            captureAnalytics: { event, properties in
                analyticsManager.capture(event, properties: properties)
            }
        ))
    }

    var canOpenPostHogSettings: Bool {
        normalizedPostHogSettingsURL != nil
    }

    func refreshRuntimePermissions() {
        dependencies.refreshHotkeyRegistration(false)
    }

    func requestRuntimePermissions() {
        dependencies.activateApplication(true)
        dependencies.refreshHotkeyRegistration(true)
    }

    func openPostHogSettings() -> Bool {
        guard let url = normalizedPostHogSettingsURL else {
            return false
        }

        dependencies.captureAnalytics("support_posthog_settings_opened", [:])
        dependencies.openURL(url)
        return true
    }

    func openAccessibilitySettings() {
        openSystemSettingsURL(SystemSettingsURL.accessibility)
    }

    func openInputMonitoringSettings() {
        openSystemSettingsURL(SystemSettingsURL.inputMonitoring)
    }

    func runPasteDiagnosticTest(text: String) async -> PasteDiagnosticReport {
        let targetApplication = dependencies.currentApplication()
        let snapshot = dependencies.pasteDiagnosticSnapshot()
        let deliveryMode = dependencies.pasteDeliveryMode()
        let delivered = await dependencies.deliverPasteDiagnosticText(
            text,
            targetApplication,
            deliveryMode
        )

        return PasteDiagnosticReport(
            ranAt: Date(),
            deliveryMode: deliveryMode,
            targetApplicationName: snapshot.frontmostApplicationName ?? targetApplication.localizedName,
            targetBundleID: snapshot.frontmostBundleID ?? targetApplication.bundleIdentifier,
            accessibilityTrusted: snapshot.accessibilityTrusted,
            secureInputActive: snapshot.secureInputActive,
            blockingModifierFlagsRawValue: snapshot.blockingModifierFlagsRawValue,
            deliverySucceeded: delivered,
            insertedIntoTestField: nil,
            failure: dependencies.lastPasteDeliveryFailure()
        )
    }

    func recordPasteDiagnosticResult(_ report: PasteDiagnosticReport) {
        dependencies.captureAnalytics(
            "paste_diagnostic_test_completed",
            report.analyticsProperties
        )
    }

    func openSupportURL(kind: String, value: String) {
        guard let url = URL(string: value) else { return }
        dependencies.captureAnalytics("support_link_opened", ["kind": kind])
        dependencies.openURL(url)
    }

    func trackSettingsTabViewed(_ tab: SettingsTab) {
        dependencies.captureAnalytics("settings_tab_viewed", ["tab": tab.rawValue])
    }

    static func normalizedWebURL(from rawValue: String?) -> URL? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }

        if let url = validatedWebURL(from: rawValue) {
            return url
        }

        return validatedWebURL(from: "https://\(rawValue)")
    }

    private var normalizedPostHogSettingsURL: URL? {
        Self.normalizedWebURL(from: dependencies.postHogSettingsURLString())
    }

    private func openSystemSettingsURL(_ rawValue: String) {
        guard let url = URL(string: rawValue) else { return }
        dependencies.openURL(url)
    }

    private static func validatedWebURL(from rawValue: String) -> URL? {
        guard let url = URL(string: rawValue),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }
}
