import Foundation

/// Privacy-preserving experiment layer for app performance work.
///
/// This module intentionally records only timings, coarse buckets, and coarse
/// target categories. It must never receive transcripts, audio, selected text,
/// window titles, URLs, or exact app names.
@MainActor
protocol PerformanceExperimentAnalytics: AnyObject {
    func getFeatureFlag(_ flag: String) -> Any?
    func capture(_ event: String, properties: [String: Any], allowWhenDisabled: Bool)
}

extension PerformanceExperimentAnalytics {
    func capture(_ event: String, properties: [String: Any]) {
        capture(event, properties: properties, allowWhenDisabled: false)
    }
}

extension AnalyticsManager: PerformanceExperimentAnalytics {}

@MainActor
final class PerformanceExperiments {

    enum Experiment: String, CaseIterable {
        case pasteVerificationDelay = "paste_verification_delay"
        case segmentRecoveryPolicy = "segment_recovery_policy"
        case captureBackend = "capture_backend"
        case cloudCleanupTimeout = "cloud_cleanup_timeout"

        var flagKey: String {
            "perf_\(rawValue)"
        }
    }

    struct Assignment: Equatable {
        let experiment: Experiment
        let variant: String
    }

    struct DictationLatencyEvent: Equatable, Sendable {
        var outcome: String?
        var targetBundleId: String?
        var stopToTranscriptionStartMs: Int?
        var captureStopMs: Int?
        var captureDiagnosticsMs: Int?
        var preTranscriptionMs: Int?
        var modelWaitMs: Int?
        var transcriptionMs: Int?
        var emptyRetryMs: Int?
        var segmentRecoveryMs: Int?
        var contextAwaitMs: Int?
        var postProcessMs: Int?
        var resolveDeliveryMs: Int?
        var cloudCleanupMs: Int?
        var transformMs: Int?
        var pasteSetupMs: Int?
        var pasteMs: Int?
        var totalMs: Int?
    }

    static let shared = PerformanceExperiments(analytics: AnalyticsManager.shared)

    private let analytics: any PerformanceExperimentAnalytics
    private var exposedAssignments = Set<String>()
    private var cachedVariants: [Experiment: String] = [:]

    init(analytics: any PerformanceExperimentAnalytics) {
        self.analytics = analytics
    }

    func activeAssignments() -> [Assignment] {
        Experiment.allCases.map { assignment(for: $0) }
    }

    func assignment(for experiment: Experiment, source: String) -> Assignment {
        let assignment = assignment(for: experiment)
        recordExposureIfNeeded(assignment, source: source)
        return assignment
    }

    func assignment(for experiment: Experiment) -> Assignment {
        Assignment(
            experiment: experiment,
            variant: variant(for: experiment)
        )
    }

    func recordDictationLatency(_ event: DictationLatencyEvent) {
        var properties: [String: Any] = [
            "schema_version": 3,
            "outcome": Self.sanitizedOutcome(event.outcome),
            "target_profile": Self.targetProfile(bundleId: event.targetBundleId)
        ]

        properties.merge(Self.metrics(from: event)) { _, newValue in newValue }

        if let totalMs = event.totalMs {
            properties["total_latency_bucket"] = Self.latencyBucket(totalMs)
        }
        if let transcriptionMs = event.transcriptionMs {
            properties["transcription_latency_bucket"] = Self.latencyBucket(transcriptionMs)
        }
        if let pasteMs = event.pasteMs {
            properties["paste_latency_bucket"] = Self.latencyBucket(pasteMs)
        }

        for assignment in activeAssignments() {
            properties["experiment_\(assignment.experiment.rawValue)"] = assignment.variant
        }

        analytics.capture("dictation_latency_v2", properties: properties)
    }

    func invalidateCachedAssignments() {
        cachedVariants.removeAll()
    }

    private func variant(for experiment: Experiment) -> String {
        if let cached = cachedVariants[experiment] {
            return cached
        }

        let rawValue = analytics.getFeatureFlag(experiment.flagKey)
        let variant: String
        switch rawValue {
        case let rawVariant as String:
            variant = Self.sanitizedVariant(rawVariant)
        case let enabled as Bool:
            variant = enabled ? "enabled" : "control"
        default:
            variant = "control"
        }
        cachedVariants[experiment] = variant
        return variant
    }

    private func recordExposureIfNeeded(_ assignment: Assignment, source: String) {
        let key = "\(assignment.experiment.rawValue):\(assignment.variant)"
        guard exposedAssignments.insert(key).inserted else { return }

        analytics.capture("performance_experiment_exposure", properties: [
            "experiment": assignment.experiment.rawValue,
            "variant": assignment.variant,
            "source": source
        ])
    }

    private static func sanitizedVariant(_ variant: String) -> String {
        let normalized = variant
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9_\-]"#, with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
        return normalized.isEmpty ? "control" : String(normalized.prefix(64))
    }

    nonisolated static func latencyBucket(_ milliseconds: Int) -> String {
        switch milliseconds {
        case ..<0:
            return "unknown"
        case 0..<250:
            return "0-250ms"
        case 250..<500:
            return "250-500ms"
        case 500..<1_000:
            return "500-1000ms"
        case 1_000..<2_000:
            return "1000-2000ms"
        case 2_000..<5_000:
            return "2000-5000ms"
        default:
            return "5000ms+"
        }
    }

    nonisolated static func sanitizedOutcome(_ outcome: String?) -> String {
        switch outcome?.lowercased() {
        case "success", "cancelled", "failure", "aborted":
            return outcome!.lowercased()
        default:
            return "unknown"
        }
    }

    nonisolated static func targetProfile(bundleId: String?) -> String {
        guard let bundleId = bundleId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bundleId.isEmpty else {
            return "unknown"
        }

        let normalized = bundleId.lowercased()
        if normalized == "com.openai.codex" || normalized == "com.conductor.app" {
            return "ai_coding_app"
        }
        if normalized.contains("terminal")
            || normalized.contains("iterm")
            || normalized.contains("ghostty")
            || normalized.contains("warp") {
            return "terminal"
        }
        if normalized.contains("vscode")
            || normalized.contains("cursor")
            || normalized.contains("zed")
            || normalized.contains("xcode") {
            return "code_editor"
        }
        if normalized.contains("discord")
            || normalized.contains("slack")
            || normalized.contains("telegram") {
            return "chat"
        }
        if normalized.contains("mail")
            || normalized.contains("outlook")
            || normalized.contains("superhuman") {
            return "email"
        }
        if BrowserCatalog.isBrowser(normalized) {
            return "browser"
        }
        return "native_app"
    }

    private nonisolated static func metrics(from event: DictationLatencyEvent) -> [String: Any] {
        var properties: [String: Any] = [:]
        func add(_ key: String, _ value: Int?) {
            guard let value else { return }
            properties[key] = value
        }
        add("stop_to_transcription_start_ms", event.stopToTranscriptionStartMs)
        add("capture_stop_ms", event.captureStopMs)
        add("capture_diagnostics_ms", event.captureDiagnosticsMs)
        add("pre_transcription_ms", event.preTranscriptionMs)
        add("model_wait_ms", event.modelWaitMs)
        add("transcription_ms", event.transcriptionMs)
        add("empty_retry_ms", event.emptyRetryMs)
        add("segment_recovery_ms", event.segmentRecoveryMs)
        add("context_await_ms", event.contextAwaitMs)
        add("post_process_ms", event.postProcessMs)
        add("resolve_delivery_ms", event.resolveDeliveryMs)
        add("cloud_cleanup_ms", event.cloudCleanupMs)
        add("transform_ms", event.transformMs)
        add("paste_setup_ms", event.pasteSetupMs)
        add("paste_ms", event.pasteMs)
        add("total_ms", event.totalMs)
        return properties
    }
}
