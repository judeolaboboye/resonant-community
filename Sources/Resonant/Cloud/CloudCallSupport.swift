import Foundation

/// Single source of truth for every Convex cloud call timeout.
/// Add new endpoints here instead of hard-coding milliseconds at call sites.
enum CloudTimeouts {
    // Cleanup blocks the paste; past ~8s a local fallback beats waiting.
    static let dictationCleanupMs = 8_000
    static let qualityRepairMs = 8_000

    static let selectionTransformQuickMs = 12_000
    static let selectionTransformAdvancedMs = 30_000

    static let memoMs = 12_000
    static let memoSelectionTransformAdvancedMs = 30_000
    static let memoMeetingSummaryMs = 45_000

    static let meetingSummaryMs = 60_000
    static let meetingSummaryLegacyMs = 45_000
    static let meetingCompletionEmailMs = 30_000

    static let workspaceSyncBatchMs = 20_000
    static let workspaceDeleteMs = 20_000

    static let chatStreamSeconds: TimeInterval = 60
    static let commandStreamSeconds: TimeInterval = 30

    static func selectionTransform(for route: CloudProcessingSupport.SelectionTransformRouting.Route) -> Int {
        switch route {
        case .quick: selectionTransformQuickMs
        case .advanced: selectionTransformAdvancedMs
        }
    }

    static func memo(for route: ConvexClient.CloudTextModelRoute?) -> Int {
        switch route {
        case .meetingSummary: memoMeetingSummaryMs
        case .selectionTransformAdvanced: memoSelectionTransformAdvancedMs
        case nil: memoMs
        }
    }
}

/// Local-day key (local time zone) for grouping cloud usage by calendar day.
enum CloudUsageDay {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func key(for date: Date = Date()) -> String {
        formatter.string(from: date)
    }
}

/// Classifies Convex error payloads (which surface as opaque strings) into the
/// handful of conditions the client reacts to. All fallback/retry decisions go
/// through here so the string matching lives in one place.
enum CloudErrorClassifier {
    static func isDailyLimit(_ errorText: String) -> Bool {
        errorText.contains("DAILY_LIMIT_REACHED")
    }

    static func isFunctionNotFound(_ errorText: String, path: String) -> Bool {
        let normalized = errorText.lowercased()
        let normalizedPath = path.lowercased()
        guard normalized.contains(normalizedPath) else { return false }
        return normalized.contains("could not find")
            || normalized.contains("no public function")
            || normalized.contains("function not found")
            || normalized.contains("not found")
    }

    static func hasExtraFieldValidationError(_ errorText: String, fields: [String]) -> Bool {
        let normalized = errorText.lowercased()
        guard normalized.contains("argumentvalidationerror") else { return false }
        return fields.contains { field in
            let normalizedField = field.lowercased()
            return normalized.contains("extra field `\(normalizedField)`")
                || normalized.contains("extra field '\(normalizedField)'")
                || normalized.contains("extra field \"\(normalizedField)\"")
                || normalized.contains("extra field \(normalizedField)")
        }
    }

    /// The dedicated cleanup endpoint can be missing (old backend) or reject
    /// newer context fields; both mean the legacy endpoint should be tried.
    static func canFallbackFromDedicatedCleanup(_ errorText: String) -> Bool {
        isFunctionNotFound(errorText, path: "cloudProcessing:processDictationCleanup")
            || hasExtraFieldValidationError(errorText, fields: [
                "windowTitle", "dictionaryTerms", "appKey", "recentTexts", "instruction"
            ])
    }

    static func canFallbackFromDedicatedQualityRepair(_ errorText: String) -> Bool {
        isFunctionNotFound(errorText, path: "cloudProcessing:processQualityRepair")
            || hasExtraFieldValidationError(errorText, fields: [
                "windowTitle", "dictionaryTerms", "appKey", "recentTexts", "styleHint",
                "instruction", "qualityIssues"
            ])
    }
}

/// Typed outcome for cloud text processing so callers can distinguish quota,
/// auth, and transport failures instead of collapsing everything to `nil`.
enum CloudProcessingFailure: Error, Equatable {
    case cloudUnavailable
    case signInRequired
    case dailyLimitReached
    case sessionExpired
    case outputRejected(reason: String)
    case serverError(String)

    static func classify(_ error: Error) -> CloudProcessingFailure {
        if let failure = error as? CloudProcessingFailure {
            return failure
        }
        if case ConvexError.sessionExpired = error {
            return .sessionExpired
        }
        let errorText = String(describing: error)
        if CloudErrorClassifier.isDailyLimit(errorText) {
            return .dailyLimitReached
        }
        return .serverError(error.localizedDescription)
    }
}

/// One attempt against a Convex cloud-text action: where to send it, what to
/// send, how long to wait, and how to label it in Sentry breadcrumbs.
struct CloudTextAttempt {
    let path: String
    var sentryLabel: String?
    let args: [String: Any]
    let timeoutMs: Int

    init(path: String, sentryLabel: String? = nil, args: [String: Any], timeoutMs: Int) {
        self.path = path
        self.sentryLabel = sentryLabel
        self.args = args
        self.timeoutMs = timeoutMs
    }

    var resolvedSentryLabel: String { sentryLabel ?? path }
}
