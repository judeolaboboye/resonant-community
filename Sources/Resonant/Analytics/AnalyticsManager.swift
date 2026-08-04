import Foundation
import Defaults
import PostHog

enum AnalyticsModelFamily: String, CaseIterable {
    case parakeet
    case qwen3
    case cohere
    case other

    static func classify(modelID: String?) -> String {
        let normalized = modelID?.lowercased() ?? ""
        if normalized.contains("parakeet") || normalized.contains("fluid") {
            return Self.parakeet.rawValue
        }
        if normalized.contains("qwen") {
            return Self.qwen3.rawValue
        }
        if normalized.contains("cohere") {
            return Self.cohere.rawValue
        }
        return Self.other.rawValue
    }
}

struct AnalyticsRuntimeConfiguration: Equatable {
    static let apiKeyInfoKey = "ResonantPostHogAPIKey"
    static let hostInfoKey = "ResonantPostHogHost"
    static let defaultHost = "https://eu.i.posthog.com"

    let apiKey: String
    let host: String

    static func from(infoDictionary: [String: Any]?) -> AnalyticsRuntimeConfiguration? {
        guard let rawAPIKey = infoDictionary?[apiKeyInfoKey] as? String else {
            return nil
        }

        let apiKey = rawAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            return nil
        }

        let host = (infoDictionary?[hostInfoKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedHost = host?.isEmpty == false ? host! : Self.defaultHost

        return AnalyticsRuntimeConfiguration(apiKey: apiKey, host: normalizedHost)
    }
}

@MainActor
final class AnalyticsManager {

    struct LaunchSessionContext {
        let isFirstLaunch: Bool
        let isNewDay: Bool
        let daysSinceInstall: Int?
        let launchNumber: Int
    }

    static let shared = AnalyticsManager()
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private let settings = SettingsManager.shared
    private let captureQueue = DispatchQueue(label: "com.resonance.resonant.analytics-capture", qos: .utility)
    private var isConfigured = false
    private var hasLoggedMissingConfiguration = false
    private var sessionStartedAt: Date?
    private var sessionDictationCount = 0
    private let standardUTMQueryMap: [(query: String, initialStorage: Defaults.Key<String?>, latestStorage: Defaults.Key<String?>)] = [
        ("utm_source", .marketingInitialUTMSource, .marketingLatestUTMSource),
        ("utm_medium", .marketingInitialUTMMedium, .marketingLatestUTMMedium),
        ("utm_campaign", .marketingInitialUTMCampaign, .marketingLatestUTMCampaign),
        ("utm_content", .marketingInitialUTMContent, .marketingLatestUTMContent),
        ("utm_term", .marketingInitialUTMTerm, .marketingLatestUTMTerm),
        ("utm_id", .marketingInitialUTMId, .marketingLatestUTMId),
    ]
    private let attributionQueryMap: [(query: String, storage: Defaults.Key<String?>, property: String)] = [
        ("initial_utm_source", .marketingInitialUTMSource, "initial_utm_source"),
        ("initial_utm_medium", .marketingInitialUTMMedium, "initial_utm_medium"),
        ("initial_utm_campaign", .marketingInitialUTMCampaign, "initial_utm_campaign"),
        ("initial_utm_content", .marketingInitialUTMContent, "initial_utm_content"),
        ("initial_utm_term", .marketingInitialUTMTerm, "initial_utm_term"),
        ("initial_utm_id", .marketingInitialUTMId, "initial_utm_id"),
        ("initial_source_link", .marketingInitialSourceLink, "initial_source_link"),
        ("initial_landing_path", .marketingInitialLandingPath, "initial_landing_path"),
        ("initial_referrer", .marketingInitialReferrer, "initial_referrer"),
        ("latest_utm_source", .marketingLatestUTMSource, "latest_utm_source"),
        ("latest_utm_medium", .marketingLatestUTMMedium, "latest_utm_medium"),
        ("latest_utm_campaign", .marketingLatestUTMCampaign, "latest_utm_campaign"),
        ("latest_utm_content", .marketingLatestUTMContent, "latest_utm_content"),
        ("latest_utm_term", .marketingLatestUTMTerm, "latest_utm_term"),
        ("latest_utm_id", .marketingLatestUTMId, "latest_utm_id"),
        ("latest_source_link", .marketingLatestSourceLink, "latest_source_link"),
        ("latest_landing_path", .marketingLatestLandingPath, "latest_landing_path"),
        ("latest_referrer", .marketingLatestReferrer, "latest_referrer"),
    ]

    private init() {}

    var distinctId: String? {
        guard isConfigured, settings.analyticsEnabled else { return nil }
        let value = PostHogSDK.shared.getDistinctId()
        return value.isEmpty ? nil : value
    }

    var anonymousId: String? {
        guard isConfigured, settings.analyticsEnabled else { return nil }
        let value = PostHogSDK.shared.getAnonymousId()
        return value.isEmpty ? nil : value
    }

    var isIdentifiedUser: Bool {
        guard let distinctId, let anonymousId else { return false }
        return distinctId != anonymousId
    }

    var currentSessionDictationCount: Int {
        sessionDictationCount
    }

    func setup() {
        // Do not initialize the SDK before consent: initialization itself can
        // preload feature flags and emit lifecycle requests.
        guard settings.analyticsEnabled else { return }
        guard !isConfigured else {
            ensureStableAnalyticsProperties()
            syncOptState()
            return
        }

        guard let configuration = AnalyticsRuntimeConfiguration.from(infoDictionary: Bundle.main.infoDictionary) else {
            if !hasLoggedMissingConfiguration {
                NSLog("%@ is missing from the app bundle. Skipping PostHog analytics setup.", AnalyticsRuntimeConfiguration.apiKeyInfoKey)
                hasLoggedMissingConfiguration = true
            }
            return
        }

        let config = PostHogConfig(apiKey: configuration.apiKey, host: configuration.host)
        config.captureApplicationLifecycleEvents = true
        config.captureScreenViews = false
        config.enableSwizzling = false
        config.reuseAnonymousId = true
        config.flushAt = 5
        config.flushIntervalSeconds = 30
        config.optOut = false
        config.setBeforeSend { event in
            AnalyticsEventSanitizer.process(event)
        }
        // Feature flags are used to gate beta features. The "Beta Testers" cohort
        // in PostHog (ID 95985) matches users with the `beta_tester` person property.
        // To gate a feature: create a flag in PostHog targeting that cohort, then
        // check it with `AnalyticsManager.shared.isFeatureEnabled("flag-name")`.
        config.preloadFeatureFlags = true
        PostHogSDK.shared.setup(config)
        isConfigured = true
        ensureStableAnalyticsProperties()
        syncMarketingAttributionProperties()

        // Ensure the beta_tester person property is synced on every launch so
        // PostHog can evaluate feature flags correctly from the first request.
        syncBetaTesterProperty()
    }

    func beginLaunchSession(now: Date = Date()) -> LaunchSessionContext {
        let dayString = Self.dayFormatter.string(from: now)

        if Defaults[.analyticsInstallDate] == nil {
            Defaults[.analyticsInstallDate] = dayString
        }

        let launchNumber = Defaults[.analyticsLaunchCount] + 1
        Defaults[.analyticsLaunchCount] = launchNumber

        let isNewDay = Defaults[.analyticsLastActiveDate] != dayString
        if isNewDay {
            Defaults[.analyticsLastActiveDate] = dayString
        }

        sessionStartedAt = now
        sessionDictationCount = 0

        return LaunchSessionContext(
            isFirstLaunch: launchNumber == 1,
            isNewDay: isNewDay,
            daysSinceInstall: Self.daysSinceInstall(now: now),
            launchNumber: launchNumber
        )
    }

    func currentSessionDurationMs(now: Date = Date()) -> Int? {
        guard let sessionStartedAt else { return nil }
        return max(0, Int(now.timeIntervalSince(sessionStartedAt) * 1000))
    }

    func incrementSessionDictationCount() {
        sessionDictationCount += 1
    }

    func capture(_ event: String, properties: [String: Any] = [:], allowWhenDisabled: Bool = false) {
        guard isConfigured, settings.analyticsEnabled else { return }
        let eventProperties = AnalyticsEventSanitizer.sanitizedProperties(
            enriched(properties),
            eventName: event
        )
        guard !AnalyticsEventSanitizer.shouldDropCapturedEvent(eventName: event, properties: eventProperties) else {
            return
        }
        captureQueue.async {
            PostHogSDK.shared.capture(event, properties: eventProperties)
        }
    }

    func identify(userId: String, email: String?) {
        guard isConfigured, settings.analyticsEnabled else { return }

        var userProperties: [String: Any] = [:]
        if let email, !email.isEmpty {
            userProperties["email"] = email
        }
        userProperties.merge(marketingAttributionProperties()) { _, newValue in newValue }

        drainCaptureQueue()
        PostHogSDK.shared.identify(userId, userProperties: userProperties)
    }

    func resetIdentity() {
        guard isConfigured, settings.analyticsEnabled else { return }
        drainCaptureQueue()
        PostHogSDK.shared.reset()
    }

    func setAnalyticsEnabled(_ enabled: Bool) {
        let previous = settings.analyticsEnabled
        settings.analyticsEnabled = enabled
        if enabled, !isConfigured {
            setup()
        }
        guard isConfigured else { return }
        guard enabled != previous else {
            syncOptState()
            return
        }

        if enabled {
            PostHogSDK.shared.optIn()
            capture("analytics_preference_changed", properties: ["enabled": true])
        } else {
            drainCaptureQueue()
            PostHogSDK.shared.optOut()
        }
    }

    func flush() {
        guard isConfigured, settings.analyticsEnabled else { return }
        drainCaptureQueue()
        PostHogSDK.shared.flush()
    }

    @discardableResult
    func captureMarketingAttribution(from url: URL, source: String) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems,
              !queryItems.isEmpty
        else {
            return false
        }

        var didPersist = false
        var hasStandardUTMParams = false
        for item in standardUTMQueryMap {
            guard let value = queryValue(item.query, in: queryItems) else { continue }
            Defaults[item.latestStorage] = value
            if normalized(Defaults[item.initialStorage]) == nil {
                Defaults[item.initialStorage] = value
            }
            didPersist = true
            hasStandardUTMParams = true
        }

        if hasStandardUTMParams {
            let landingPath = url.path.isEmpty ? "/" : url.path
            Defaults[.marketingLatestLandingPath] = landingPath
            if normalized(Defaults[.marketingInitialLandingPath]) == nil {
                Defaults[.marketingInitialLandingPath] = landingPath
            }
        }

        if let attributionId = queryValue("marketing_attribution_id", in: queryItems) {
            Defaults[.marketingAttributionId] = attributionId
            didPersist = true
        }

        for item in attributionQueryMap {
            if let value = queryValue(item.query, in: queryItems) {
                Defaults[item.storage] = value
                didPersist = true
            }
        }

        guard didPersist else { return false }
        syncMarketingAttributionProperties()
        capture("marketing_attribution_received", properties: [
            "source": source,
            "url_host": url.host ?? "unknown",
            "url_path": url.path,
            "has_marketing_attribution_id": Defaults[.marketingAttributionId] != nil,
            "has_standard_utm_params": hasStandardUTMParams,
        ])
        return true
    }

    func marketingAttributionQueryItems() -> [URLQueryItem] {
        marketingAttributionProperties().map { key, value in
            URLQueryItem(name: key, value: String(describing: value))
        }
    }

    // MARK: - Feature Flags
    //
    // Feature flags are evaluated client-side by the PostHog SDK. Flags are
    // defined in PostHog and can target the "Beta Testers" cohort (person
    // property `beta_tester == true`) or any other condition.
    //
    // Flow: user toggles "Join the beta program" in Account settings
    //   → setBetaTesterEnabled() persists the preference and sets the
    //     `beta_tester` person property via register()
    //   → reloadFeatureFlags() fetches updated flag evaluations
    //   → call sites use isFeatureEnabled("flag-name") to gate behavior

    /// Check whether a feature flag is enabled for the current user.
    func isFeatureEnabled(_ flag: String) -> Bool {
        guard isConfigured, settings.analyticsEnabled else { return false }
        return PostHogSDK.shared.isFeatureEnabled(flag)
    }

    /// Get the raw value of a feature flag (useful for multivariate flags).
    func getFeatureFlag(_ flag: String) -> Any? {
        guard isConfigured, settings.analyticsEnabled else { return nil }
        return PostHogSDK.shared.getFeatureFlag(flag)
    }

    /// Force a fresh fetch of all feature flag values from PostHog.
    func reloadFeatureFlags() {
        guard isConfigured, settings.analyticsEnabled else { return }
        PostHogSDK.shared.reloadFeatureFlags {
            Task { @MainActor in
                PerformanceExperiments.shared.invalidateCachedAssignments()
            }
        }
    }

    /// Called from AppState when the user toggles the beta program setting.
    /// Persists locally, syncs the person property to PostHog, and reloads flags.
    func setBetaTesterEnabled(_ enabled: Bool) {
        settings.betaTesterEnabled = enabled
        syncBetaTesterProperty()
        capture("beta_tester_toggled", properties: ["enabled": enabled])
    }

    /// Registers `beta_tester` as a super property so it's attached to every
    /// event and visible to PostHog for cohort/flag evaluation, then reloads flags.
    private func syncBetaTesterProperty() {
        guard isConfigured, settings.analyticsEnabled else { return }
        PostHogSDK.shared.register(["beta_tester": settings.betaTesterEnabled])
        reloadFeatureFlags()
    }

    private func syncOptState() {
        if settings.analyticsEnabled {
            PostHogSDK.shared.optIn()
        } else {
            PostHogSDK.shared.optOut()
        }
    }

    private func ensureStableAnalyticsProperties() {
        _ = AnalyticsIdentity.installID()
        _ = AnalyticsIdentity.firstSeenAppVersion(currentAppVersion: currentAppVersion)
    }

    private func syncMarketingAttributionProperties() {
        guard isConfigured, settings.analyticsEnabled else { return }
        let properties = marketingAttributionProperties()
        guard !properties.isEmpty else { return }
        PostHogSDK.shared.register(properties)
    }

    private func drainCaptureQueue() {
        captureQueue.sync {}
    }

    private func enriched(_ properties: [String: Any]) -> [String: Any] {
        baseProperties.merging(properties) { _, newValue in newValue }
    }

    private var currentAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    private var currentAuthState: String {
        let normalizedUserId = settings.userId?.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedUserId?.isEmpty == false ? "identified" : "anonymous"
    }

    private var baseProperties: [String: Any] {
        var properties: [String: Any] = [
            "analytics_source": "resonant_swift",
            "app_version": currentAppVersion,
            "build_number": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            "platform": "macOS",
            "install_id": AnalyticsIdentity.installID(),
            "auth_state": currentAuthState,
            "is_logged_in": currentAuthState == "identified",
            "first_seen_app_version": AnalyticsIdentity.firstSeenAppVersion(currentAppVersion: currentAppVersion),
            "total_words": Defaults[.statsTotalWords],
            "total_dictations": Defaults[.statsTotalDictations],
            "streak_days": Defaults[.statsStreakDays],
            "launch_number": Defaults[.analyticsLaunchCount]
        ]

        if let daysSinceInstall = Self.daysSinceInstall() {
            properties["days_since_install"] = daysSinceInstall
        }
        properties.merge(marketingAttributionProperties()) { _, newValue in newValue }

        return properties
    }

    private func marketingAttributionProperties() -> [String: Any] {
        var properties: [String: Any] = [:]

        if let attributionId = normalized(Defaults[.marketingAttributionId]) {
            properties["marketing_attribution_id"] = attributionId
        }

        for item in attributionQueryMap {
            if let value = normalized(Defaults[item.storage]) {
                properties[item.property] = value
            }
        }

        return properties
    }

    private func queryValue(_ name: String, in queryItems: [URLQueryItem]) -> String? {
        normalized(queryItems.first(where: { $0.name == name })?.value)
    }

    private func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func daysSinceInstall(now: Date = Date()) -> Int? {
        guard let installDate = Defaults[.analyticsInstallDate],
              let installedAt = dayFormatter.date(from: installDate)
        else {
            return nil
        }

        return max(0, Int(floor(now.timeIntervalSince(installedAt) / 86_400)))
    }
}

enum AnalyticsEventSanitizer {
    static let redactedPlaceholder = "[Redacted]"

    private static let maxProperties = 80
    private static let maxDictationQualityProperties = 128
    private static let maxArrayItems = 80
    private static let maxDepth = 5
    private static let defaultStringLimit = 512
    private static let exceptionStringLimit = 2_000
    private static let isoFormatter = ISO8601DateFormatter()

    private static let preservedPropertyKeys = [
        "analytics_source",
        "platform",
        "install_id",
        "auth_state",
        "is_logged_in",
        "first_seen_app_version",
        "app_version",
        "build_number",
        "launch_number",
        "schema_version",
        "pipeline_name",
        "measurement_point",
        "delivery_status",
        "dictation_id",
        "mode",
        "model",
        "model_family",
        "target_profile",
        "surface_kind",
        "paste_delivery_mode",
        "auto_paste_enabled",
        "auto_send_enabled",
        "copy_to_clipboard_enabled",
        "cloud_processing_enabled",
        "low_latency_mode",
        "selection_transform_used",
        "cleanup_status",
        "cleanup_attempted",
        "cleanup_profile",
        "cleanup_path",
        "transform_status",
        "transform_attempted",
        "confidence_schema_version",
        "confidence_overall_bucket",
        "confidence_recognition_bucket",
        "confidence_rewrite_bucket",
        "confidence_delivery_bucket",
        "confidence_reason_count",
        "confidence_reasons",
        "learning_eligible",
        "auto_send_eligible",
        "voiced_ratio_bucket",
        "words_per_second_bucket",
        "segment_recovery_attempted",
        "segment_recovery_used",
        "segmenter_source",
        "postproc_changed",
        "postproc_changed_stage_count",
        "readback_status",
        "quality_evaluable",
        "readback_evaluable",
        "accepted_readback",
        "corrected_readback",
        "zero_edit_proxy",
        "boost_applied_count",
        "boost_vetoed_count",
        "boost_dropped_with_veto_count",
        "boost_guarded_veto_count",
        "context_personalization_policy",
        "context_personalization_policy_version",
        "context_personalization_holdout_rate",
        "context_personalization_assigned_variant",
        "context_personalization_opportunity",
        "context_personalization_withheld_by_holdout",
        "context_personalization_packet_entity_offered_count",
        "context_personalization_packet_style_offered",
        "context_personalization_local_entity_considered_count",
        "context_personalization_local_entity_matched_count",
        "context_personalization_local_entity_applied_count",
        "context_personalization_local_style_applied",
        "context_personalization_cloud_entity_submitted_count",
        "context_personalization_cloud_style_submitted",
        "context_personalization_applied",
        "correction_count",
        "normalized_edit_distance",
        "normalized_edit_distance_bucket",
        "pasted_length_bucket",
        "edited_length_bucket",
        "observation_age_ms",
    ]
    private static let preservedPropertyKeySet = Set(preservedPropertyKeys)

    /// Vocabulary decisions are especially sensitive because callers have
    /// local access to the candidate term and replaced transcript span. Keep
    /// this event on an explicit metric-only schema rather than relying on the
    /// general redaction blocklist to anticipate every possible text key.
    private static let vocabularyBoostDecisionPropertyKeys: Set<String> = [
        "analytics_source",
        "platform",
        "install_id",
        "auth_state",
        "is_logged_in",
        "first_seen_app_version",
        "app_version",
        "build_number",
        "launch_number",
        "days_since_install",
        "total_words",
        "total_dictations",
        "streak_days",
        "outcome",
        "guarded_term",
        "term_source",
        "original_was_real_word",
        "original_score",
        "replacement_score",
        "mode",
    ]

    /// Enrichment keys permitted on the two privacy-critical aggregate events.
    /// `install_id` and marketing attribution are deliberately excluded: the
    /// event payload must not contain an additional raw identifier.
    private static let aggregateEventBasePropertyKeys: Set<String> = [
        "analytics_source",
        "platform",
        "auth_state",
        "is_logged_in",
        "first_seen_app_version",
        "app_version",
        "build_number",
        "launch_number",
        "days_since_install",
        "total_words",
        "total_dictations",
        "streak_days",
    ]

    /// Closed schema for post-paste quality. Every key is a coarse enum,
    /// boolean, bounded count/bucket, or latency metric created by the typed
    /// quality builder. Unknown future fields fail closed until reviewed.
    private static let dictationQualityPropertyKeys: Set<String> =
        aggregateEventBasePropertyKeys.union([
            "schema_version",
            "pipeline_name",
            "measurement_point",
            "delivery_status",
            "mode",
            "model_family",
            "target_profile",
            "surface_kind",
            "paste_delivery_mode",
            "auto_paste_enabled",
            "auto_send_enabled",
            "copy_to_clipboard_enabled",
            "cloud_processing_enabled",
            "low_latency_mode",
            "selection_transform_used",
            "cleanup_status",
            "cleanup_attempted",
            "cleanup_profile",
            "cleanup_list_intent",
            "cleanup_path",
            "cleanup_fallback_reason",
            "cleanup_sanitizer_reject_reason",
            "cleanup_accepted",
            "cleanup_client_duration_ms",
            "cleanup_server_duration_ms",
            "quality_policy",
            "quality_lint_issues",
            "quality_lint_issues_after_local_repair",
            "quality_local_repair_applied",
            "quality_lint_issues_after_repair",
            "quality_repair_attempted",
            "quality_repair_accepted",
            "quality_repair_reject_reason",
            "quality_repair_client_duration_ms",
            "quality_repair_server_duration_ms",
            "transform_status",
            "transform_attempted",
            "transform_succeeded",
            "transform_failure_reason",
            "transform_client_duration_ms",
            "confidence_schema_version",
            "confidence_overall_bucket",
            "confidence_recognition_bucket",
            "confidence_rewrite_bucket",
            "confidence_delivery_bucket",
            "confidence_reason_count",
            "confidence_reasons",
            "learning_eligible",
            "auto_send_eligible",
            "voiced_ratio_bucket",
            "words_per_second_bucket",
            "segment_recovery_attempted",
            "segment_recovery_used",
            "segmenter_source",
            "postproc_changed",
            "postproc_changed_stage_count",
            "postproc_changed_stages",
            "readback_status",
            "quality_evaluable",
            "readback_evaluable",
            "accepted_readback",
            "corrected_readback",
            "zero_edit_proxy",
            "boost_applied_count",
            "boost_vetoed_count",
            "boost_dropped_with_veto_count",
            "boost_guarded_veto_count",
            "context_personalization_policy",
            "context_personalization_policy_version",
            "context_personalization_holdout_rate",
            "context_personalization_assigned_variant",
            "context_personalization_opportunity",
            "context_personalization_withheld_by_holdout",
            "context_personalization_packet_entity_offered_count",
            "context_personalization_packet_style_offered",
            "context_personalization_local_entity_considered_count",
            "context_personalization_local_entity_matched_count",
            "context_personalization_local_entity_applied_count",
            "context_personalization_local_style_applied",
            "context_personalization_cloud_entity_submitted_count",
            "context_personalization_cloud_style_submitted",
            "context_personalization_applied",
            "correction_count",
            "normalized_edit_distance",
            "normalized_edit_distance_bucket",
            "pasted_length_bucket",
            "edited_length_bucket",
            "observation_age_ms",
            "total_ms",
            "transcription_ms",
            "post_process_ms",
            "resolve_delivery_ms",
            "cloud_cleanup_ms",
            "transform_ms",
            "paste_setup_ms",
            "paste_ms",
            "experiment_paste_verification_delay",
            "experiment_segment_recovery_policy",
            "experiment_capture_backend",
            "experiment_cloud_cleanup_timeout",
        ])

    private static let sensitiveKeys: Set<String> = [
        "description",
        "error_description",
        "message",
        "prompt",
        "raw_transcript",
        "selected_text",
        "selectedtext",
        "text",
        "transcript",
        "transcript_excerpt",
        "transcription",
        "user_email",
    ]

    private static let sensitiveKeyFragments = [
        "raw_transcript",
        "selected_text",
    ]

    private static let ignoredExceptionPatterns = [
        "NSURLErrorDomain Code=-999",
        "cancelled",
        "EPIPE",
        "ECONNRESET",
        "ETIMEDOUT",
        "network connection was lost",
        "internet connection appears to be offline",
        "network connection was changed",
        "AudioRecorderError.finishFailed",
        "Cannot Record",
        "recording never started",
        "recording stopped before finalization",
        "recording file contained no audio",
        "recording file could not be read",
        "FluidAudio.ASRError",
        "invalidAudioData",
        "com.apple.coreaudio.avfaudio",
        "Code: -50",
    ]

    static func process(_ event: PostHogEvent) -> PostHogEvent? {
        let eventText = flattenedText(event.properties)
        if shouldDrop(eventName: event.event, eventText: eventText) {
            return nil
        }

        event.properties = sanitizedProperties(event.properties, eventName: event.event)
        return event
    }

    static func sanitizedProperties(_ properties: [String: Any], eventName: String? = nil) -> [String: Any] {
        let isException = eventName == "$exception"
        let selectedProperties: [String: Any]
        switch eventName {
        case "dictation_quality_v1":
            selectedProperties = properties.filter {
                dictationQualityPropertyKeys.contains($0.key)
            }
        case let eventName? where OnboardingAnalytics.Event.analyticsNames.contains(eventName):
            selectedProperties = properties.filter {
                OnboardingAnalytics.allowedPropertyKeys.contains($0.key)
            }
        case let eventName? where ModelPreparationTelemetry.Event.analyticsNames.contains(eventName):
            selectedProperties = properties.filter {
                ModelPreparationTelemetry.allowedPropertyKeys.contains($0.key)
            }
        case VocabularyBoostAttemptTelemetry.eventName:
            let allowed = aggregateEventBasePropertyKeys.union(
                VocabularyBoostAttemptTelemetry.metricPropertyKeys
            )
            selectedProperties = properties.filter { allowed.contains($0.key) }
        case "vocabulary_boost_decision":
            selectedProperties = properties.filter {
                vocabularyBoostDecisionPropertyKeys.contains($0.key)
            }
        default:
            selectedProperties = properties
        }
        return sanitizedDictionary(
            selectedProperties,
            depth: 0,
            stringLimit: isException ? exceptionStringLimit : defaultStringLimit,
            propertyLimit: propertyLimit(for: eventName)
        )
    }

    static func allowedPropertyKeys(for eventName: String) -> Set<String>? {
        switch eventName {
        case "dictation_quality_v1":
            return dictationQualityPropertyKeys
        case let name where OnboardingAnalytics.Event.analyticsNames.contains(name):
            return OnboardingAnalytics.allowedPropertyKeys
        case let name where ModelPreparationTelemetry.Event.analyticsNames.contains(name):
            return ModelPreparationTelemetry.allowedPropertyKeys
        case VocabularyBoostAttemptTelemetry.eventName:
            return aggregateEventBasePropertyKeys.union(
                VocabularyBoostAttemptTelemetry.metricPropertyKeys
            )
        case "vocabulary_boost_decision":
            return vocabularyBoostDecisionPropertyKeys
        default:
            return nil
        }
    }

    static func propertyLimit(for eventName: String?) -> Int {
        eventName == "dictation_quality_v1" ? maxDictationQualityProperties : maxProperties
    }

    static func shouldDropCapturedEvent(eventName: String, properties: [String: Any]) -> Bool {
        eventName == "cloud_processing_failed"
            && properties["error_kind"] as? String == "cancelled"
    }

    static func errorProperties(for error: Error) -> [String: Any] {
        let nsError = error as NSError
        var properties: [String: Any] = [
            "error_type": String(reflecting: type(of: error)),
            "error_kind": errorKind(for: error),
            "error_domain": nsError.domain,
            "error_code": nsError.code,
        ]

        if case ConvexError.serverError(_) = error {
            properties["error_domain"] = "ConvexError"
            properties["error_type"] = "ConvexError.serverError"
        } else if case ConvexError.httpError(_) = error {
            properties["error_domain"] = "ConvexError"
            properties["error_type"] = "ConvexError.httpError"
        } else if case ConvexError.sessionExpired(_) = error {
            properties["error_domain"] = "ConvexError"
            properties["error_type"] = "ConvexError.sessionExpired"
        }

        return properties
    }

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain,
           nsError.code == NSURLErrorCancelled {
            return true
        }

        if let urlError = error as? URLError,
           urlError.code == .cancelled {
            return true
        }

        return false
    }

    static func errorKind(for error: Error) -> String {
        if isCancellation(error) { return "cancelled" }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return "timed_out"
            case .notConnectedToInternet:
                return "offline"
            case .networkConnectionLost:
                return "network_lost"
            default:
                return "url_error"
            }
        }

        switch error {
        case ConvexError.httpError(_):
            return "http_error"
        case ConvexError.serverError(_):
            return "server_error"
        case ConvexError.sessionExpired(_):
            return "session_expired"
        default:
            return "unknown"
        }
    }

    private static func shouldDrop(eventName: String, eventText: String) -> Bool {
        guard eventName == "$exception" else { return false }
        let normalized = eventText.lowercased()
        return ignoredExceptionPatterns.contains { normalized.contains($0.lowercased()) }
    }

    private static func sanitizedDictionary(
        _ dictionary: [String: Any],
        depth: Int,
        stringLimit: Int,
        propertyLimit: Int = maxProperties
    ) -> [String: Any] {
        guard depth <= maxDepth else { return [:] }

        var sanitized: [String: Any] = [:]
        for key in selectedKeys(from: dictionary, propertyLimit: propertyLimit) {
            guard let value = dictionary[key] else { continue }
            sanitized[key] = sanitizedValue(
                value,
                key: key,
                depth: depth + 1,
                stringLimit: stringLimit
            )
        }
        return sanitized
    }

    private static func selectedKeys(
        from dictionary: [String: Any],
        propertyLimit: Int
    ) -> [String] {
        let preservedKeys = Array(
            preservedPropertyKeys
                .filter { dictionary[$0] != nil }
                .prefix(propertyLimit)
        )
        let remainingLimit = max(0, propertyLimit - preservedKeys.count)
        let remainingKeys = dictionary.keys
            .sorted()
            .filter { !preservedPropertyKeySet.contains($0) }
            .prefix(remainingLimit)

        return preservedKeys + remainingKeys
    }

    private static func sanitizedValue(
        _ value: Any,
        key: String,
        depth: Int,
        stringLimit: Int
    ) -> Any {
        if isSensitiveKey(key) {
            return redactedPlaceholder
        }

        switch value {
        case let string as String:
            return capped(string.trimmingCharacters(in: .whitespacesAndNewlines), limit: stringLimit)
        case let url as URL:
            return capped(url.absoluteString, limit: stringLimit)
        case let date as Date:
            return isoFormatter.string(from: date)
        case let bool as Bool:
            return bool
        case let number as NSNumber:
            return number
        case let array as [Any]:
            guard depth <= maxDepth else { return [] }
            return array.prefix(maxArrayItems).map {
                sanitizedValue($0, key: key, depth: depth + 1, stringLimit: stringLimit)
            }
        case let dictionary as [String: Any]:
            return sanitizedDictionary(
                dictionary,
                depth: depth + 1,
                stringLimit: stringLimit
            )
        case _ as NSNull:
            return NSNull()
        default:
            return capped(String(describing: value), limit: stringLimit)
        }
    }

    private static func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key
            .replacingOccurrences(of: "-", with: "_")
            .lowercased()

        if sensitiveKeys.contains(normalized) {
            return true
        }

        return sensitiveKeyFragments.contains { normalized.contains($0) }
    }

    private static func capped(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 12)) + " [truncated]"
    }

    private static func flattenedText(_ value: Any, depth: Int = 0) -> String {
        guard depth <= maxDepth else { return "" }

        switch value {
        case let string as String:
            return string
        case let array as [Any]:
            return array.prefix(maxArrayItems)
                .map { flattenedText($0, depth: depth + 1) }
                .joined(separator: " ")
        case let dictionary as [String: Any]:
            return dictionary.values
                .map { flattenedText($0, depth: depth + 1) }
                .joined(separator: " ")
        default:
            return String(describing: value)
        }
    }
}
