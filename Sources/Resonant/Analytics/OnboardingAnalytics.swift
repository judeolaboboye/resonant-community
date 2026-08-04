import Foundation

enum OnboardingAnalytics {
    static let schemaVersion = 2

    enum Event: String, CaseIterable {
        case started = "onboarding_started"
        case stepViewed = "onboarding_step_viewed"
        case stepCompleted = "onboarding_step_completed"
        case abandoned = "onboarding_abandoned"
        case permissionState = "onboarding_permission_state"
        case permissionGranted = "onboarding_permission_granted"
        case practiceResolved = "onboarding_practice_resolved"
        case accessibilitySettingsOpened = "onboarding_accessibility_settings_opened"
        case completed = "onboarding_completed"
        case deepLinkOpened = "onboarding_deep_link_opened"

        static let analyticsNames = Set(allCases.map(\.rawValue))
    }

    enum SessionType: String, Equatable {
        case firstRun = "first_run"
        case resume
        case reopen
        case preSession = "pre_session"
    }

    enum Permission: String, CaseIterable {
        case microphone
        case accessibility
        case inputMonitoring = "input_monitoring"
    }

    struct SessionContext: Equatable {
        let sessionType: SessionType
        let initialStep: String

        static func resolve(
            onboardingCompleted: Bool,
            hadStarted: Bool,
            initialStep: String
        ) -> Self {
            let sessionType: SessionType
            if onboardingCompleted {
                sessionType = .reopen
            } else if hadStarted || initialStep != "welcome" {
                sessionType = .resume
            } else {
                sessionType = .firstRun
            }
            return Self(sessionType: sessionType, initialStep: initialStep)
        }

        static func preSession(initialStep: String = "unknown") -> Self {
            Self(sessionType: .preSession, initialStep: initialStep)
        }

        var properties: [String: Any] {
            [
                "schema_version": OnboardingAnalytics.schemaVersion,
                "session_type": sessionType.rawValue,
                "initial_step": initialStep,
            ]
        }
    }

    struct PermissionSnapshot: Equatable {
        var microphone: Bool
        var accessibility: Bool
        var inputMonitoring: Bool

        func newlyGranted(comparedTo previous: Self) -> [Permission] {
            var permissions: [Permission] = []
            if microphone && !previous.microphone {
                permissions.append(.microphone)
            }
            if accessibility && !previous.accessibility {
                permissions.append(.accessibility)
            }
            if inputMonitoring && !previous.inputMonitoring {
                permissions.append(.inputMonitoring)
            }
            return permissions
        }

        var properties: [String: Any] {
            [
                "microphone_granted": microphone,
                "accessibility_granted": accessibility,
                "input_monitoring_granted": inputMonitoring,
            ]
        }
    }

    static let allowedPropertyKeys: Set<String> = [
        "analytics_source",
        "platform",
        "auth_state",
        "is_logged_in",
        "first_seen_app_version",
        "app_version",
        "build_number",
        "launch_number",
        "days_since_install",
        "schema_version",
        "session_type",
        "initial_step",
        "step",
        "step_id",
        "last_step_id",
        "duration_ms",
        "total_duration_ms",
        "permission",
        "step_elapsed_ms",
        "microphone_granted",
        "accessibility_granted",
        "input_monitoring_granted",
        "outcome",
        "total_dictations",
        "has_preview",
        "landed_target_profile",
        "landed_in_external_app",
        "trigger_key",
        "mcp_auto_enabled",
        "mcp_opted_out",
        "mcp_detected_clients",
        "entry_point",
        "network_path",
    ]

    static func properties(
        context: SessionContext,
        additional: [String: Any] = [:]
    ) -> [String: Any] {
        context.properties.merging(additional) { _, newValue in newValue }
    }
}
