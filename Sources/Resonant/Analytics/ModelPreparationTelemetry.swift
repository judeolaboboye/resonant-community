import Foundation

enum ModelPreparationSource: String, CaseIterable {
    case appLaunch = "app_launch"
    case onboardingDownload = "onboarding_download"
    case hotkeyRecovery = "hotkey_recovery"
    case dictationStart = "dictation_start"
    case settings
    case unknown

    /// Only a visible Download/Retry action may authorize network acquisition.
    /// Background preparation paths may load an existing local cache, but must
    /// never turn into an implicit model download.
    var permitsModelDownload: Bool {
        switch self {
        case .onboardingDownload, .settings:
            return true
        case .appLaunch, .hotkeyRecovery, .dictationStart, .unknown:
            return false
        }
    }
}

enum ModelPreparationTelemetry {
    static let schemaVersion = 1

    enum Event: String, CaseIterable {
        case started = "model_prepare_started"
        case succeeded = "model_prepare_succeeded"
        case failed = "model_prepare_failed"

        static let analyticsNames = Set(allCases.map(\.rawValue))
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
        "model_family",
        "source",
        "phase",
        "download_required",
        "download_performed",
        "duration_ms",
        "download_retry_count",
        "recovery_used",
        "error_kind",
    ]

    static func properties(
        modelID: String,
        source: ModelPreparationSource,
        phase: String,
        downloadRequired: Bool,
        additional: [String: Any] = [:]
    ) -> [String: Any] {
        let base: [String: Any] = [
            "schema_version": schemaVersion,
            "model_family": AnalyticsModelFamily.classify(modelID: modelID),
            "source": source.rawValue,
            "phase": phase,
            "download_required": downloadRequired,
        ]
        return base.merging(additional) { _, newValue in newValue }
    }

    static func failureKind(for error: Error) -> String {
        if AnalyticsEventSanitizer.isCancellation(error) {
            return "cancelled"
        }
        switch error {
        case is ModelDownloadStallError:
            return "download_stalled"
        case is ModelLoadTimeoutError:
            return "load_timed_out"
        case is ModelDiskCapacityError:
            return "insufficient_disk"
        case is ModelIncompleteDownloadError:
            return "incomplete_download"
        case is ModelDownloadConsentRequiredError:
            return "download_consent_required"
        case let urlError as URLError:
            switch urlError.code {
            case .timedOut:
                return "network_timed_out"
            case .notConnectedToInternet:
                return "offline"
            case .networkConnectionLost:
                return "network_lost"
            default:
                return "network_error"
            }
        case TranscriberError.notLoaded:
            return "not_loaded"
        case TranscriberError.notDownloaded:
            return "not_downloaded"
        case TranscriberError.transcriptionFailed:
            return "load_failed"
        case TranscriberError.downloadFailed:
            return "download_failed"
        default:
            return "unknown"
        }
    }
}
