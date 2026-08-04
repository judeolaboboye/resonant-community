import Foundation

/// A bounded local failure category. No downloader-provided message crosses
/// this boundary into UI, logging, persistence, or analytics.
enum VocabularyBoostHelperFailureCategory: String, Sendable, Equatable, CaseIterable {
    case network
    case storage
    case incomplete
    case unknown

    nonisolated var detail: String {
        switch self {
        case .network:
            return "The 98 MB helper could not be downloaded because the network request failed. Check your connection, then retry."
        case .storage:
            return "The 98 MB helper could not be saved locally. Check available storage and file access, then retry."
        case .incomplete:
            return "The download finished, but required helper files are missing. Retry to repair the local copy."
        case .unknown:
            return "The 98 MB helper could not be downloaded for an unknown local reason. Dictation still works without it; retry when ready."
        }
    }
}

/// Observable lifecycle for the English-only CTC helper assets. This remains
/// independent of applicability: an inapplicable feature can still have a
/// deliberate prefetch in progress or a failed transfer that needs recovery.
enum VocabularyBoostHelperDownloadState: Sendable, Equatable {
    case absent
    case downloading
    case ready
    case failed(VocabularyBoostHelperFailureCategory)

    nonisolated var title: String {
        switch self {
        case .absent: "Helper absent"
        case .downloading: "Downloading 98 MB"
        case .ready: "Helper ready"
        case .failed: "Download failed"
        }
    }

    nonisolated var detail: String {
        switch self {
        case .absent:
            return "The optional 98 MB local helper is not downloaded. Choose Download to fetch it; dictation works without it."
        case .downloading:
            return "Downloading the 98 MB local helper now. Dictation continues without vocabulary boosting until it is ready."
        case .ready:
            return "The 98 MB helper is stored locally and ready when the current recognition conditions allow it."
        case .failed(let category):
            return category.detail
        }
    }

    nonisolated var recoveryAction: VocabularyBoostHelperRecoveryAction? {
        switch self {
        case .absent: .download
        case .failed: .retry
        case .downloading, .ready: nil
        }
    }
}

enum VocabularyBoostHelperRecoveryAction: Sendable, Equatable {
    case download
    case retry
}

/// Whether the current live runtime could use the helper if it were ready.
/// This says nothing about whether a helper transfer is running or failed.
enum VocabularyBoostApplicabilityState: Sendable, Equatable {
    case off
    case unsupportedModel
    case lowLatencyPaused
    case automaticConditional
    case unsupportedLanguage
    case noEligibleTerms
    case eligible

    nonisolated var allowsAutomaticHelperDownload: Bool {
        self == .automaticConditional || self == .eligible
    }

    /// Whether losing this state should abort an in-flight automatic helper
    /// download. Term counts flap with every screen capture (`begin()` clears
    /// screen terms, `updateBase` repopulates them), so they only block new
    /// starts; deliberate user choices — including selecting a non-English
    /// transcription language — abort immediately.
    nonisolated var cancelsInFlightAutomaticDownload: Bool {
        switch self {
        case .off, .unsupportedModel, .lowLatencyPaused, .unsupportedLanguage:
            true
        case .automaticConditional, .noEligibleTerms, .eligible:
            false
        }
    }

    nonisolated var title: String {
        switch self {
        case .off: "Off"
        case .unsupportedModel: "Unsupported"
        case .lowLatencyPaused: "Paused"
        case .automaticConditional: "Auto conditional"
        case .unsupportedLanguage: "English only"
        case .noEligibleTerms: "Needs words"
        case .eligible: "Eligible"
        }
    }

    /// User-facing explanation derived from the same typed state that gates
    /// automatic helper acquisition and attempt routing.
    nonisolated func detail(eligibleTermCount: Int) -> String {
        switch self {
        case .off:
            return "Vocabulary recognition is off. A manually requested helper download can still finish as a visible local prefetch."
        case .unsupportedModel:
            return "The live transcription model cannot use vocabulary recognition. Switch to Parakeet to make it applicable."
        case .lowLatencyPaused:
            return "Paused while Instant-on microphone is enabled because vocabulary recognition adds another recognition pass."
        case .automaticConditional:
            return "Auto may use the English-only helper only after a local check confidently identifies the first-pass transcript as English. Non-English, uncertain, and long recordings skip it."
        case .unsupportedLanguage:
            return "Vocabulary recognition will not be used for the selected language. The helper supports English only."
        case .noEligibleTerms:
            return "On, but no eligible words are available yet. Add a correction or import names from Contacts."
        case .eligible:
            let count = max(0, eligibleTermCount)
            let word = count == 1 ? "word" : "words"
            return "Eligible for \(count) \(word) in supported English dictations. Long recordings skip this pass, and acoustic evidence decides each use."
        }
    }

    nonisolated static func resolve(
        enabled: Bool,
        liveAdapterSupportsBoosting: Bool,
        lowLatencyMode: Bool,
        selectedLanguage: String?,
        eligibleTermCount: Int
    ) -> Self {
        guard enabled else { return .off }
        guard liveAdapterSupportsBoosting else { return .unsupportedModel }
        guard !lowLatencyMode else { return .lowLatencyPaused }
        guard let languageMode = VocabularyBoostAttemptRouter.languageMode(
            for: selectedLanguage
        ) else {
            return .unsupportedLanguage
        }
        guard eligibleTermCount > 0 else { return .noEligibleTerms }
        return languageMode == .automaticConditional ? .automaticConditional : .eligible
    }
}

/// User-facing, whole-app vocabulary truth. Applicability and helper lifecycle
/// are deliberately orthogonal so one can never mask the other.
struct VocabularyBoostRuntimeState: Sendable, Equatable {
    let applicability: VocabularyBoostApplicabilityState
    let helper: VocabularyBoostHelperDownloadState

    nonisolated func detail(eligibleTermCount: Int) -> String {
        "\(applicability.detail(eligibleTermCount: eligibleTermCount)) \(helper.detail)"
    }

    nonisolated static func resolve(
        enabled: Bool,
        liveAdapterSupportsBoosting: Bool,
        lowLatencyMode: Bool,
        selectedLanguage: String?,
        eligibleTermCount: Int,
        helperDownloadState: VocabularyBoostHelperDownloadState
    ) -> Self {
        Self(
            applicability: .resolve(
                enabled: enabled,
                liveAdapterSupportsBoosting: liveAdapterSupportsBoosting,
                lowLatencyMode: lowLatencyMode,
                selectedLanguage: selectedLanguage,
                eligibleTermCount: eligibleTermCount
            ),
            helper: helperDownloadState
        )
    }
}

/// The language condition attached to an actual CTC attempt. Auto-detect is
/// not represented as fully supported because the helper itself is English-only.
enum VocabularyBoostAttemptLanguageMode: String, Sendable, Equatable, Hashable, CaseIterable {
    case explicitEnglish = "explicit_english"
    case automaticConditional = "automatic_conditional"
}

/// Bounded reasons why an eligible transcription did not reach CTC rescoring.
/// No case carries an error string, term, transcript, model path, or identifier.
enum VocabularyBoostAttemptSkipReason: String, Sendable, Equatable, Hashable, CaseIterable {
    case disabled
    case unsupportedAdapter = "unsupported_adapter"
    case diskBackedLongForm = "disk_backed_long_form"
    case lowLatencyMode = "low_latency_mode"
    case unsupportedLanguage = "unsupported_language"
    case languageDetectionUncertain = "language_detection_uncertain"
    case missingTokenTimings = "missing_token_timings"
    case emptyTranscript = "empty_transcript"
    case noEligibleTerms = "no_eligible_terms"
    case modelUnavailable = "model_unavailable"
    case cancelled
}

/// Bounded terminal result after the CTC processing path was entered.
enum VocabularyBoostAttemptResult: String, Sendable, Equatable, Hashable, CaseIterable {
    case noChange = "no_change"
    case applied
    case vetoed
    case processingFailure = "processing_failure"
}

/// Per-dictation vocabulary-boost outcome. This is intentionally distinct
/// from global readiness: a globally ready feature can still be bypassed for a
/// disk-backed long-form decode, and Auto language remains conditional.
enum VocabularyBoostAttemptOutcome: Sendable, Equatable, Hashable {
    case skipped(VocabularyBoostAttemptSkipReason)
    case attempted(
        result: VocabularyBoostAttemptResult,
        language: VocabularyBoostAttemptLanguageMode
    )
}

/// Typed count key used by the recorder's local diagnostic snapshot.
/// Associated values remain closed enums, so this key cannot retain text.
enum VocabularyBoostAttemptCountKey: Sendable, Equatable, Hashable {
    case skipped(VocabularyBoostAttemptSkipReason)
    case attempted(
        result: VocabularyBoostAttemptResult,
        language: VocabularyBoostAttemptLanguageMode
    )
}

struct VocabularyBoostAttemptCounts: Sendable, Equatable {
    nonisolated static let maximumCountPerOutcome = 999

    private(set) var values: [VocabularyBoostAttemptCountKey: Int] = [:]

    nonisolated var total: Int {
        values.values.reduce(0, +)
    }

    nonisolated func count(for key: VocabularyBoostAttemptCountKey) -> Int {
        values[key, default: 0]
    }

    fileprivate mutating func record(_ outcome: VocabularyBoostAttemptOutcome) {
        let key: VocabularyBoostAttemptCountKey
        switch outcome {
        case .skipped(let reason):
            key = .skipped(reason)
        case .attempted(let result, let language):
            key = .attempted(result: result, language: language)
        }
        values[key] = min(
            Self.maximumCountPerOutcome,
            values[key, default: 0] + 1
        )
    }
}

/// Actor-isolated, count-only attempt sink shared by AppState, the FluidAudio
/// adapter, and the boost engine.
///
/// `onOutcome` is the documented attachment point for later analytics work. It
/// receives exactly the current closed outcome once per `record(_:)` call, so
/// the integration can emit one unit attempt event without double-counting
/// cumulative history. `snapshot()` remains local diagnostics only.
actor VocabularyBoostAttemptRecorder {
    typealias OutcomeHook = @Sendable (VocabularyBoostAttemptOutcome) async -> Void

    private var counts = VocabularyBoostAttemptCounts()
    private let onOutcome: OutcomeHook?

    init(onOutcome: OutcomeHook? = nil) {
        self.onOutcome = onOutcome
    }

    func record(_ outcome: VocabularyBoostAttemptOutcome) async {
        counts.record(outcome)
        await onOutcome?(outcome)
    }

    func snapshot() -> VocabularyBoostAttemptCounts {
        counts
    }
}

struct VocabularyBoostEngineRuntimeConfiguration: Sendable, Equatable {
    let enabled: Bool
    let lowLatencyMode: Bool
}

enum VocabularyBoostEnginePreflightDecision: Sendable, Equatable {
    case skip(VocabularyBoostAttemptSkipReason)
    case proceed(VocabularyBoostAttemptLanguageMode)
}

/// Pure attempt routing shared by runtime tests and the production boundaries.
enum VocabularyBoostAttemptRouter {
    nonisolated static func languageMode(
        for selectedLanguage: String?
    ) -> VocabularyBoostAttemptLanguageMode? {
        let normalized = selectedLanguage?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? "auto"
        guard !normalized.isEmpty, normalized != "auto" else {
            return .automaticConditional
        }
        guard normalized == "en"
                || normalized.hasPrefix("en-")
                || normalized.hasPrefix("en_") else {
            return nil
        }
        return .explicitEnglish
    }

    nonisolated static func enginePreflight(
        configuration: VocabularyBoostEngineRuntimeConfiguration,
        selectedLanguage: String?,
        hasTokenTimings: Bool,
        transcriptIsEmpty: Bool,
        eligibleTermCount: Int,
        automaticLanguageDetection: () -> VocabularyBoostLanguageDetection,
        helperModelDownloaded: () -> Bool
    ) -> VocabularyBoostEnginePreflightDecision {
        guard configuration.enabled else { return .skip(.disabled) }
        guard !configuration.lowLatencyMode else { return .skip(.lowLatencyMode) }
        guard let language = languageMode(for: selectedLanguage) else {
            return .skip(.unsupportedLanguage)
        }
        guard hasTokenTimings else { return .skip(.missingTokenTimings) }
        guard !transcriptIsEmpty else { return .skip(.emptyTranscript) }
        guard eligibleTermCount > 0 else { return .skip(.noEligibleTerms) }

        if language == .automaticConditional {
            switch automaticLanguageDetection().classification {
            case .confidentlyEnglish:
                break
            case .confidentlyNonEnglish:
                return .skip(.unsupportedLanguage)
            case .uncertain:
                return .skip(.languageDetectionUncertain)
            }
        }

        guard helperModelDownloaded() else { return .skip(.modelUnavailable) }
        return .proceed(language)
    }

    /// Convenience overload for deterministic truth-table callers. Auto is
    /// deliberately uncertain unless a detection is supplied explicitly.
    nonisolated static func enginePreflight(
        configuration: VocabularyBoostEngineRuntimeConfiguration,
        selectedLanguage: String?,
        hasTokenTimings: Bool,
        transcriptIsEmpty: Bool,
        eligibleTermCount: Int,
        automaticLanguageDetection: VocabularyBoostLanguageDetection? = nil,
        helperModelDownloaded: Bool
    ) -> VocabularyBoostEnginePreflightDecision {
        enginePreflight(
            configuration: configuration,
            selectedLanguage: selectedLanguage,
            hasTokenTimings: hasTokenTimings,
            transcriptIsEmpty: transcriptIsEmpty,
            eligibleTermCount: eligibleTermCount,
            automaticLanguageDetection: {
                automaticLanguageDetection ?? VocabularyBoostLanguageDetection(
                    classification: .uncertain,
                    confidence: 0
                )
            },
            helperModelDownloaded: { helperModelDownloaded }
        )
    }

    nonisolated static func unsupportedAdapterOutcome(
        enabled: Bool
    ) -> VocabularyBoostAttemptOutcome {
        .skipped(enabled ? .unsupportedAdapter : .disabled)
    }

    nonisolated static func diskBackedOutcome(
        configuration: VocabularyBoostEngineRuntimeConfiguration,
        selectedLanguage: String?,
        eligibleTermCount: Int,
        helperModelDownloaded: Bool
    ) -> VocabularyBoostAttemptOutcome {
        guard configuration.enabled else { return .skipped(.disabled) }
        guard !configuration.lowLatencyMode else { return .skipped(.lowLatencyMode) }
        guard languageMode(for: selectedLanguage) != nil else {
            return .skipped(.unsupportedLanguage)
        }
        guard eligibleTermCount > 0 else { return .skipped(.noEligibleTerms) }
        guard helperModelDownloaded else { return .skipped(.modelUnavailable) }
        return .skipped(.diskBackedLongForm)
    }
}
