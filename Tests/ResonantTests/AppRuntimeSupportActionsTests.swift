import AppKit
import XCTest
@testable import Resonant

@MainActor
final class AppRuntimeSupportActionsTests: XCTestCase {
    func testPostHogSettingsURLNormalization() {
        XCTAssertNil(AppRuntimeSupportActions.normalizedWebURL(from: nil))
        XCTAssertNil(AppRuntimeSupportActions.normalizedWebURL(from: "   "))
        XCTAssertEqual(
            AppRuntimeSupportActions.normalizedWebURL(from: " posthog.com/project/123/settings ")?.absoluteString,
            "https://posthog.com/project/123/settings"
        )
        XCTAssertEqual(
            AppRuntimeSupportActions.normalizedWebURL(from: "https://eu.posthog.com/settings")?.absoluteString,
            "https://eu.posthog.com/settings"
        )
    }

    func testPostHogSettingsOpenCapturesAnalyticsAndOpensNormalizedURL() {
        var openedURLs: [URL] = []
        var capturedEvents: [String] = []
        let actions = makeActions(
            openURL: { openedURLs.append($0) },
            postHogSettingsURLString: { "posthog.com/settings" },
            captureAnalytics: { event, _ in capturedEvents.append(event) }
        )

        XCTAssertTrue(actions.openPostHogSettings())
        XCTAssertEqual(openedURLs.map(\.absoluteString), ["https://posthog.com/settings"])
        XCTAssertEqual(capturedEvents, ["support_posthog_settings_opened"])
        XCTAssertTrue(actions.canOpenPostHogSettings)
    }

    func testPostHogSettingsOpenReturnsFalseWhenURLIsMissing() {
        var openedURLs: [URL] = []
        var capturedEvents: [String] = []
        let actions = makeActions(
            openURL: { openedURLs.append($0) },
            postHogSettingsURLString: { " " },
            captureAnalytics: { event, _ in capturedEvents.append(event) }
        )

        XCTAssertFalse(actions.openPostHogSettings())
        XCTAssertFalse(actions.canOpenPostHogSettings)
        XCTAssertTrue(openedURLs.isEmpty)
        XCTAssertTrue(capturedEvents.isEmpty)
    }

    func testRuntimePermissionActionsPreservePromptSemantics() {
        var activationRequests: [Bool] = []
        var promptRequests: [Bool] = []
        let actions = makeActions(
            activateApplication: { activationRequests.append($0) },
            refreshHotkeyRegistration: { promptRequests.append($0) }
        )

        actions.refreshRuntimePermissions()
        actions.requestRuntimePermissions()

        XCTAssertEqual(promptRequests, [false, true])
        XCTAssertEqual(activationRequests, [true])
    }

    func testSystemSettingsActionsOpenExpectedURLs() {
        var openedURLs: [String] = []
        let actions = makeActions(openURL: { openedURLs.append($0.absoluteString) })

        actions.openAccessibilitySettings()
        actions.openInputMonitoringSettings()

        XCTAssertEqual(openedURLs, [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        ])
    }

    func testPasteDiagnosticReportComposesSnapshotDeliveryAndFailure() async {
        var deliveredText: String?
        var deliveredMode: PasteDeliveryMode?
        let snapshot = PasteManager.DiagnosticSnapshot(
            accessibilityTrusted: true,
            secureInputActive: true,
            blockingModifierFlagsRawValue: 42,
            frontmostApplicationName: "Focused App",
            frontmostBundleID: "com.example.focused"
        )
        let actions = makeActions(
            pasteDeliveryMode: { .directTyping },
            pasteDiagnosticSnapshot: { snapshot },
            deliverPasteDiagnosticText: { text, _, mode in
                deliveredText = text
                deliveredMode = mode
                return false
            },
            lastPasteDeliveryFailure: { .secureInputActive }
        )

        let report = await actions.runPasteDiagnosticTest(text: "diagnostic marker")

        XCTAssertEqual(deliveredText, "diagnostic marker")
        XCTAssertEqual(deliveredMode, .directTyping)
        XCTAssertEqual(report.deliveryMode, .directTyping)
        XCTAssertEqual(report.targetApplicationName, "Focused App")
        XCTAssertEqual(report.targetBundleID, "com.example.focused")
        XCTAssertTrue(report.accessibilityTrusted)
        XCTAssertTrue(report.secureInputActive)
        XCTAssertEqual(report.blockingModifierFlagsRawValue, 42)
        XCTAssertFalse(report.deliverySucceeded)
        XCTAssertEqual(report.failure, .secureInputActive)
    }

    func testSupportURLAndSettingsTabAnalytics() {
        var openedURLs: [String] = []
        var capturedEvents: [(name: String, kind: String?)] = []
        let actions = makeActions(
            openURL: { openedURLs.append($0.absoluteString) },
            captureAnalytics: { event, properties in
                capturedEvents.append((event, properties["kind"] as? String ?? properties["tab"] as? String))
            }
        )

        actions.openSupportURL(kind: "docs", value: "https://example.com/help")
        actions.trackSettingsTabViewed(.support)

        XCTAssertEqual(openedURLs, ["https://example.com/help"])
        XCTAssertEqual(capturedEvents.map(\.name), ["support_link_opened", "settings_tab_viewed"])
        XCTAssertEqual(capturedEvents.map(\.kind), ["docs", SettingsTab.support.rawValue])
    }

    private func makeActions(
        activateApplication: @escaping (_ ignoringOtherApps: Bool) -> Void = { _ in },
        openURL: @escaping (URL) -> Void = { _ in },
        currentApplication: @escaping () -> NSRunningApplication = { NSRunningApplication.current },
        refreshHotkeyRegistration: @escaping (_ promptIfNeeded: Bool) -> Void = { _ in },
        postHogSettingsURLString: @escaping () -> String? = { nil },
        pasteDeliveryMode: @escaping () -> PasteDeliveryMode = { .automatic },
        pasteDiagnosticSnapshot: @escaping () -> PasteManager.DiagnosticSnapshot = {
            PasteManager.DiagnosticSnapshot(
                accessibilityTrusted: false,
                secureInputActive: false,
                blockingModifierFlagsRawValue: 0,
                frontmostApplicationName: nil,
                frontmostBundleID: nil
            )
        },
        deliverPasteDiagnosticText: @escaping (
            _ text: String,
            _ targetApplication: NSRunningApplication,
            _ deliveryMode: PasteDeliveryMode
        ) async -> Bool = { _, _, _ in true },
        lastPasteDeliveryFailure: @escaping () -> PasteManager.DeliveryFailure? = { nil },
        captureAnalytics: @escaping (_ event: String, _ properties: [String: Any]) -> Void = { _, _ in }
    ) -> AppRuntimeSupportActions {
        AppRuntimeSupportActions(dependencies: AppRuntimeSupportActions.Dependencies(
            activateApplication: activateApplication,
            openURL: openURL,
            currentApplication: currentApplication,
            refreshHotkeyRegistration: refreshHotkeyRegistration,
            postHogSettingsURLString: postHogSettingsURLString,
            pasteDeliveryMode: pasteDeliveryMode,
            pasteDiagnosticSnapshot: pasteDiagnosticSnapshot,
            deliverPasteDiagnosticText: deliverPasteDiagnosticText,
            lastPasteDeliveryFailure: lastPasteDeliveryFailure,
            captureAnalytics: captureAnalytics
        ))
    }
}
