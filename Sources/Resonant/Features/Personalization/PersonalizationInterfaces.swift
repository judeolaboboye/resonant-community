import Foundation

struct DictationFeedbackEvent: Sendable, Equatable {
    var pastedText: String
    var editedText: String
    var rawTranscript: String?
    var corrections: [StoredCorrectionPair]
    var context: CorrectionObservationContext
    var capabilities: LearningCapabilities
    /// Learned rules the formatter recorded as selected for this delivery.
    /// Unchanged output can confirm only these rules and can never originate a
    /// policy from the delivered text itself.
    var appliedStylePolicy: AppliedStylePolicy
    var wasEdited: Bool
    /// Terms the decode-time vocabulary boost inserted into the pasted text.
    /// Their presence in delivered text is the boost echoing itself, not the
    /// user confirming a name — sighting promotion must ignore them.
    var ctcAppliedTerms: [String]

    init(
        pastedText: String,
        editedText: String,
        rawTranscript: String?,
        corrections: [StoredCorrectionPair],
        context: CorrectionObservationContext,
        capabilities: LearningCapabilities,
        appliedStylePolicy: AppliedStylePolicy = .none,
        wasEdited: Bool? = nil,
        ctcAppliedTerms: [String] = []
    ) {
        self.pastedText = pastedText
        self.editedText = editedText
        self.rawTranscript = rawTranscript
        self.corrections = corrections
        self.context = context
        self.capabilities = capabilities
        self.appliedStylePolicy = appliedStylePolicy
        self.wasEdited = wasEdited ?? (pastedText != editedText)
        self.ctcAppliedTerms = ctcAppliedTerms
    }

    /// Source-compatible construction for callers that have not carried the
    /// typed permissions yet. It is intentionally fail-closed.
    init(
        pastedText: String,
        editedText: String,
        rawTranscript: String?,
        corrections: [StoredCorrectionPair],
        context: CorrectionObservationContext,
        wasEdited: Bool? = nil,
        ctcAppliedTerms: [String] = []
    ) {
        self.init(
            pastedText: pastedText,
            editedText: editedText,
            rawTranscript: rawTranscript,
            corrections: corrections,
            context: context,
            capabilities: .none,
            appliedStylePolicy: .none,
            wasEdited: wasEdited,
            ctcAppliedTerms: ctcAppliedTerms
        )
    }

    var hadCorrection: Bool {
        wasEdited
    }
}

/// Mandatory request for attributable pasted-to-edited style evidence.
struct StyleTransitionFeedbackRequest: Sendable, Equatable {
    var pastedText: String
    var editedText: String
    var context: CorrectionObservationContext
    var capabilities: LearningCapabilities
    var appliedStylePolicy: AppliedStylePolicy

    init(
        pastedText: String,
        editedText: String,
        context: CorrectionObservationContext,
        capabilities: LearningCapabilities,
        appliedStylePolicy: AppliedStylePolicy = .none
    ) {
        self.pastedText = pastedText
        self.editedText = editedText
        self.context = context
        self.capabilities = capabilities
        self.appliedStylePolicy = appliedStylePolicy
    }
}

/// Auto-send can contribute content habits only from the raw transcript and
/// only through its independent typed capability.
struct RawTranscriptHabitFeedbackRequest: Sendable, Equatable {
    var rawTranscript: String
    var context: CorrectionObservationContext
    var capabilities: LearningCapabilities

    init(
        rawTranscript: String,
        context: CorrectionObservationContext,
        capabilities: LearningCapabilities
    ) {
        self.rawTranscript = rawTranscript
        self.context = context
        self.capabilities = capabilities
    }
}

@MainActor
protocol PersonalizationLearningEngine: AnyObject {
    func snapshot(for surface: SurfaceDescriptor) -> PersonalizationMemorySnapshot
    func profile(for surface: SurfaceDescriptor) -> VersionedPersonalizationProfile
    func recordFeedback(_ event: DictationFeedbackEvent) async
}

/// Learned formatting preferences for a surface — consumed by the
/// post-processing pipeline to stop applying formatting a user keeps undoing.
struct DictationFormattingPreferences: Sendable, Equatable {
    var suppressAutoLists = false
    var omitTrailingPeriod = false
    /// Hosts whose auto-expanded domain the user keeps reverting to the bare
    /// brand word (e.g. "substack.com" → "Substack").
    var suppressedDomainExpansionHosts: Set<String> = []
    /// Phone grouping style the user keeps reformatting to
    /// ("parenthesized", "hyphenated", "dotted", "spaced", "plain").
    var preferredPhoneStyle: String? = nil
    /// Lowercased token → the casing the user keeps correcting it to. Covers
    /// both plain words ("figma" → "Figma") and full email addresses.
    var learnedWordCasings: [String: String] = [:]
    /// The user keeps lowercasing our capitalized message openings on this
    /// chat/social surface — skip leading auto-capitalization locally.
    var preferLowercaseOpening = false
    /// Structured source of truth. Legacy booleans above remain explicit
    /// source-compatible adapters for callers that have not adopted it yet.
    var stylePolicy: StylePolicy = .inherit

    var resolvedStylePolicy: StylePolicy {
        var resolved = stylePolicy
        if resolved.listMarkers == .inherit, suppressAutoLists {
            resolved.listMarkers = .omit
        }
        if resolved.trailingPeriod == .inherit, omitTrailingPeriod {
            resolved.trailingPeriod = .omit
        }
        if resolved.openingCase == .inherit, preferLowercaseOpening {
            resolved.openingCase = .lowercase
        }
        return resolved
    }

    static let neutral = DictationFormattingPreferences()
}

@MainActor
protocol FormattingPreferenceProviding: AnyObject {
    func formattingPreferences(for surface: SurfaceDescriptor) -> DictationFormattingPreferences
}

@MainActor
protocol PersonalizationDashboardDataSource: AnyObject {
    func dashboardSnapshot() async -> PersonalizationDashboardSnapshot
    func clearCorrectionEvents() async
    func clearPersonalizationMemory() async
}

typealias PersonalizationOutcomeSummaryProvider = @Sendable () async -> PersonalizationOutcomeSummary
typealias PersonalizationConsumerRuntimeContextProvider =
    @MainActor @Sendable () -> PersonalizationConsumerRuntimeContext

@MainActor
protocol PersonalizationControlDataSource: AnyObject {
    func controlsSnapshot() async -> PersonalizationControlsSnapshot
    /// AppState supplies current, text-free consumer facts. The provider is
    /// invoked once per snapshot so Settings never retains a launch-time copy.
    func attachConsumerRuntimeContextProvider(
        _ provider: @escaping PersonalizationConsumerRuntimeContextProvider
    )
    func detachConsumerRuntimeContextProvider()
    /// AppState attaches the single actor-owned outcome store here after its
    /// persistence setup completes. The memory store never fetches outcome
    /// rows independently or substitutes correction-log rows.
    func attachOutcomeSummaryProvider(
        _ provider: @escaping PersonalizationOutcomeSummaryProvider
    )
    func detachOutcomeSummaryProvider()
    func setEntityPinned(id: UUID, isPinned: Bool) async
    func setEntitySuppressed(id: UUID, isSuppressed: Bool) async
    func setFormatPreferenceSuppressed(id: UUID, isSuppressed: Bool) async
    func clearPersonalizationMemory() async
}

@MainActor
protocol PersonalizationEvaluationDataSource: AnyObject {
    func evaluationSnapshot(limit: Int) async -> PersonalizationEvaluationSnapshot
}

extension PersonalizationMemoryStore:
    PersonalizationLearningEngine,
    PersonalizationDashboardDataSource,
    PersonalizationControlDataSource,
    PersonalizationEvaluationDataSource,
    FormattingPreferenceProviding {
    func recordFeedback(_ event: DictationFeedbackEvent) async {
        guard event.capabilities.allowsCorrectionDerivedMutations else {
            return
        }
        for correction in event.corrections {
            await recordCorrection(
                spoken: correction.spoken,
                written: correction.written,
                spokenIsRealWord: correction.spokenIsRealWord,
                context: event.context,
                capabilities: event.capabilities
            )
        }

        await recordCorrectionEvent(
            pastedText: event.pastedText,
            editedText: event.editedText,
            rawTranscript: event.rawTranscript,
            corrections: event.corrections,
            context: event.context,
            wasEdited: event.wasEdited,
            capabilities: event.capabilities
        )
        await recordStyleTransition(StyleTransitionFeedbackRequest(
            pastedText: event.pastedText,
            editedText: event.editedText,
            context: event.context,
            capabilities: event.capabilities,
            appliedStylePolicy: event.appliedStylePolicy
        ))
        recordFormatCorrections(
            pasted: event.pastedText,
            edited: event.editedText,
            context: event.context,
            capabilities: event.capabilities
        )
        await recordScreenEntityUsage(
            pastedText: event.pastedText,
            editedText: event.editedText,
            corrections: event.corrections,
            context: event.context,
            boostInsertedTerms: Set(event.ctcAppliedTerms.map { $0.lowercased() }),
            capabilities: event.capabilities
        )
        await saveChanges()
    }
}
