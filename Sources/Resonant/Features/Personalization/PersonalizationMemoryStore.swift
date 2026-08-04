import Foundation
import SwiftData
import os

struct PersonalizationMemorySnapshot: Sendable, Equatable {
    var entities: [ContextEntity]
    var biasTerms: [String]
    var styleHint: String?
    var editExemplars: [DictationEditExemplar] = []

    static let empty = PersonalizationMemorySnapshot(
        entities: [],
        biasTerms: [],
        styleHint: nil
    )
}

struct CorrectionObservationContext: Sendable, Equatable {
    var appName: String?
    var bundleId: String?
    var windowTitle: String?
    var browserURL: String?
    var contextPacket: ContextPacket?

    var surface: SurfaceDescriptor {
        if let contextPacket {
            return contextPacket.surface
        }
        return SurfaceClassifier.classify(
            appName: appName,
            bundleId: bundleId,
            windowTitle: windowTitle,
            browserURL: browserURL
        )
    }
}

@MainActor
final class PersonalizationMemoryStore {
    typealias RecognitionBiasTermsObserver = @MainActor () -> Void
    private struct EntityRecord: Sendable, Equatable {
        var id: UUID
        var type: ContextEntityType
        var value: String
        var normalizedValue: String
        var aliases: [String]
        var spokenForms: [String]
        var appScope: String?
        var siteScope: String?
        var surfaceKind: String?
        var projectScope: String?
        var confidence: Double
        var positiveCount: Int
        var negativeCount: Int
        var source: EvidenceSource
        var isUserPinned: Bool
        var isSuppressed: Bool
        var createdAt: Date
        var lastSeenAt: Date
        var lastUsedAt: Date?
    }

    private struct StyleRecord: Sendable, Equatable {
        var id: UUID
        var scopeKey: String
        var surfaceKind: SurfaceKind
        var appScope: String?
        var siteScope: String?
        var projectScope: String?
        var sampleCount: Int
        var acceptedCount: Int
        var correctedCount: Int
        var lowercaseOpeningCount: Int
        var sentenceCaseOpeningCount: Int
        var greetingCount: Int
        var signoffCount: Int
        var shortMessageCount: Int
        var paragraphBreakCount: Int
        var finalPunctuationCount: Int
        var totalWords: Int
        var listMarkersStrippedCount: Int
        var listMarkersKeptCount: Int
        var trailingPunctuationStrippedCount: Int
        // Auto-sent deliveries never see a user edit, so they only feed the
        // content-driven counters (greeting/signoff/length/paragraphs). The
        // casing and punctuation counters stay edit-sample-only — sampling our
        // own output there would just teach the pipeline its own defaults.
        var autoSentSampleCount: Int = 0
        var autoSentGreetingCount: Int = 0
        var autoSentSignoffCount: Int = 0
        var autoSentShortMessageCount: Int = 0
        var autoSentParagraphBreakCount: Int = 0
        // Only attributable direct transitions may originate these policies.
        var directLowercaseOpeningCount: Int = 0
        var directSentenceCaseOpeningCount: Int = 0
        var directListOmissionCount: Int = 0
        var directListRequirementCount: Int = 0
        var directTrailingPeriodOmissionCount: Int = 0
        var directTrailingPeriodRequirementCount: Int = 0
        var appliedPolicyConfirmationCount: Int = 0
        // Content habits use provenance-safe denominators rather than legacy
        // style samples that may contain formatter-authored output.
        var authoredHabitSampleCount: Int = 0
        var authoredGreetingCount: Int = 0
        var authoredSignoffCount: Int = 0
        var authoredShortMessageCount: Int = 0
        var authoredParagraphBreakCount: Int = 0
        var rawTranscriptHabitSampleCount: Int = 0
        var rawTranscriptGreetingCount: Int = 0
        var rawTranscriptSignoffCount: Int = 0
        var rawTranscriptShortMessageCount: Int = 0
        var rawTranscriptParagraphBreakCount: Int = 0
        var createdAt: Date
        var lastSeenAt: Date
    }

    private struct FormatPreferenceRecord: Sendable, Equatable {
        var id: UUID
        var category: FormatCorrectionCategory
        var scopeKey: String
        var preferredValue: String
        var positiveCount: Int
        var negativeCount: Int
        var confidence: Double
        var isSuppressed: Bool
        var suppressionReconciliationVersion: Int
        var createdAt: Date
        var lastSeenAt: Date
        // In-memory monotonic touch order; breaks prune ties when wall-clock
        // timestamps collide. Not persisted (recency survives via lastSeenAt).
        var touchSequence: UInt64 = 0
    }

    /// Exemplar-eligible correction event held in memory so `snapshot(for:)`
    /// can stay synchronous instead of fetching SwiftData per dictation.
    private struct EditExemplarRecord: Sendable, Equatable {
        var surfaceKind: String?
        var appScope: String?
        var exemplar: DictationEditExemplar
        var recordedAt: Date
    }

    private let log = Logger.resonant("PersonalizationMemory")

    private let profileAssignmentSeed: String
    private var outcomeSummaryProvider: PersonalizationOutcomeSummaryProvider?
    private var consumerRuntimeContextProvider:
        PersonalizationConsumerRuntimeContextProvider?
    /// Defaults to the current schema marker; injectable only so migration
    /// behavior can be exercised without constructing an old SwiftData store.
    private let newFormatPreferenceReconciliationVersion: Int
    /// AppState wires this to the dictionary store so a casing rule learned
    /// after its dictionary counterpart was suppressed starts suppressed too.
    /// Existing records are deliberately left alone here: restoring one in
    /// settings is an explicit override until another suppression event fires.
    var dictionaryCasingSuppressionProvider: ((_ preferredValue: String) -> Bool)?
    var onRecognitionBiasTermsChanged: RecognitionBiasTermsObserver?
    private var dataStore: DataStore?
    private var entitiesByKey: [String: EntityRecord] = [:] {
        didSet { onRecognitionBiasTermsChanged?() }
    }
    private var stylesByKey: [String: StyleRecord] = [:]
    private var formatPreferencesByKey: [String: FormatPreferenceRecord] = [:]
    /// Newest-first ring of exemplar-eligible edits, seeded from the persisted
    /// correction-event log at setup.
    private var recentEditExemplars: [EditExemplarRecord] = []
    private var formatPreferenceTouchCounter: UInt64 = 0
    private var dirtyEntityIDs: Set<UUID> = []
    private var dirtyStyleIDs: Set<UUID> = []
    private var dirtyFormatPreferenceIDs: Set<UUID> = []

    private static let maxSnapshotEntities = 24
    private static let maxSnapshotBiasTerms = 20
    private static let maxSnapshotEditExemplars = 3
    private static let maxEditExemplarBufferCount = 60
    private static let maxFormatPreferences = 200
    private static let formatPreferenceReward = 0.14
    private static let formatPreferencePenalty = 0.22
    nonisolated private static let formatPreferenceMinConfidence = 0.05
    nonisolated private static let formatPreferenceMaxConfidence = 0.98
    private static let formatPreferenceInitialConfidence = 0.5
    /// Increment only when the one-time reconciliation semantics change.
    private static let wordCasingSuppressionReconciliationVersion = 1
    /// Distinguishes a deliberate Settings restore from an unsuppressed row
    /// whose dictionary cascade was lost to an abrupt process exit. A later
    /// dictionary suppression event replaces this sentinel with the current
    /// reconciliation version and suppresses the row again.
    private static let explicitWordCasingRestoreVersion = Int.max
    /// Evidence sources that count as "the user saw this on screen" for
    /// sighting promotion. Deliberately excludes app metadata and URLs.
    private static let screenSightingSources: Set<EvidenceSource> = [
        .selectedText, .focusedField, .windowTitle, .visibleSnippet, .openFile,
    ]
    private static let maxScreenSightingsPerEvent = 4
    private static let screenSightingConfidenceStep = 0.08
    private static let screenSightingMaxConfidence = 0.9
    private static let screenSightingDecayStep = 0.18
    private static let screenSightingMinConfidence = 0.10
    /// The decode itself can insert an on-screen term (vocabulary boost), so
    /// two rapid unreviewed pastes must not read as two confirmations: repeat
    /// sightings of a record only count after this much wall-clock spacing.
    private static let screenSightingMinimumSpacing: TimeInterval = 600
    /// Sightings mint records automatically (corrections are user-initiated
    /// and stay uncapped), so cap their share of the store.
    private static let maxScreenSightingRecords = 300
    private static let entitySaveDebounce: Duration = .milliseconds(500)
    private var saveTask: Task<Void, Never>?
    private var pendingDeletionTasks: [UUID: Task<Void, Never>] = [:]
    private var isWorkspaceWriteSuspended = false
    private var activeMutationCount = 0
    private var mutationDrainWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        profileAssignmentSeed: String = PersonalizationProfileIdentity.seed(),
        formatPreferenceReconciliationVersionForNewRecords: Int? = nil
    ) {
        self.profileAssignmentSeed = profileAssignmentSeed
        newFormatPreferenceReconciliationVersion =
            formatPreferenceReconciliationVersionForNewRecords
            ?? Self.wordCasingSuppressionReconciliationVersion
    }

    func setup(store: DataStore) {
        dataStore = store
        let entityModels = store.fetch(FetchDescriptor<LearnedContextEntity>())
        let styleModels = store.fetch(FetchDescriptor<LearnedStyleProfile>())
        let formatModels = store.fetch(FetchDescriptor<LearnedFormatPreference>())

        entitiesByKey = entityModels.reduce(into: [String: EntityRecord]()) { partialResult, model in
            let record = Self.record(from: model)
            let key = Self.entityKey(for: record)
            if let existing = partialResult[key] {
                partialResult[key] = existing.confidence >= record.confidence ? existing : record
            } else {
                partialResult[key] = record
            }
        }
        stylesByKey = styleModels.reduce(into: [String: StyleRecord]()) { partialResult, model in
            let record = Self.record(from: model)
            if let existing = partialResult[record.scopeKey] {
                partialResult[record.scopeKey] = existing.sampleCount >= record.sampleCount ? existing : record
            } else {
                partialResult[record.scopeKey] = record
            }
        }
        formatPreferencesByKey = formatModels.reduce(into: [String: FormatPreferenceRecord]()) { partialResult, model in
            guard let record = Self.record(from: model) else { return }
            // Kept decodable only for retry after a failed retirement. The
            // obsolete global row is never surfaced as a runtime preference.
            guard record.category != .punctuation else { return }
            let key = Self.formatPreferenceKey(for: record)
            if let existing = partialResult[key] {
                partialResult[key] = existing.confidence >= record.confidence ? existing : record
            } else {
                partialResult[key] = record
            }
        }
        // Seed monotonic touch order from persisted recency so prune ties resolve
        // deterministically after a reload.
        formatPreferenceTouchCounter = 0
        for key in formatPreferencesByKey.keys.sorted(by: { lhs, rhs in
            formatPreferencesByKey[lhs]!.lastSeenAt < formatPreferencesByKey[rhs]!.lastSeenAt
        }) {
            formatPreferenceTouchCounter += 1
            formatPreferencesByKey[key]?.touchSequence = formatPreferenceTouchCounter
        }
        var eventDescriptor = FetchDescriptor<DictationCorrectionEvent>(
            predicate: #Predicate { $0.hadCorrection == true },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        eventDescriptor.fetchLimit = Self.maxEditExemplarBufferCount * 4
        recentEditExemplars = Array(
            store.fetch(eventDescriptor)
                .compactMap { event -> EditExemplarRecord? in
                    guard let exemplar = DictationEditExemplarFilter.candidate(
                        original: event.pastedTextPreview,
                        edited: event.editedTextPreview
                    ) else { return nil }
                    return EditExemplarRecord(
                        surfaceKind: event.surfaceKind,
                        appScope: Self.normalizedOptional(event.bundleId),
                        exemplar: exemplar,
                        recordedAt: event.timestamp
                    )
                }
                .prefix(Self.maxEditExemplarBufferCount)
        )
        dirtyEntityIDs.removeAll()
        dirtyStyleIDs.removeAll()
        dirtyFormatPreferenceIDs.removeAll()
    }

    func snapshot(for surface: SurfaceDescriptor) -> PersonalizationMemorySnapshot {
        let rankedEntities = entitiesByKey.values
            .filter { isEligible($0, for: surface) }
            .sorted { lhs, rhs in
                score(lhs, for: surface) > score(rhs, for: surface)
            }
            .prefix(Self.maxSnapshotEntities)
            .map { contextEntity(from: $0, surface: surface) }

        let biasTerms = ContextEntityExtractor
            .biasTerms(from: Array(rankedEntities), limit: Self.maxSnapshotBiasTerms)

        return PersonalizationMemorySnapshot(
            entities: Array(rankedEntities),
            biasTerms: biasTerms,
            styleHint: styleHint(for: surface),
            editExemplars: editExemplars(for: surface)
        )
    }

    /// Recent same-surface edit exemplars, same-app first. These ride the
    /// personalization profile, so holdout users automatically get none.
    private func editExemplars(for surface: SurfaceDescriptor) -> [DictationEditExemplar] {
        let kind = surface.kind.rawValue
        let bundleId = Self.normalizedOptional(surface.bundleId)
        return recentEditExemplars
            .filter { $0.surfaceKind == kind }
            .sorted { lhs, rhs in
                let lhsSameApp = lhs.appScope != nil && lhs.appScope == bundleId
                let rhsSameApp = rhs.appScope != nil && rhs.appScope == bundleId
                if lhsSameApp != rhsSameApp { return lhsSameApp }
                return lhs.recordedAt > rhs.recordedAt
            }
            .prefix(Self.maxSnapshotEditExemplars)
            .map(\.exemplar)
    }

    func profile(for surface: SurfaceDescriptor) -> VersionedPersonalizationProfile {
        PersonalizationProfileBuilder.build(
            surface: surface,
            snapshot: snapshot(for: surface),
            styleSampleCount: stylesByKey[Self.styleKey(for: surface)].map {
                $0.authoredHabitSampleCount + $0.rawTranscriptHabitSampleCount
            } ?? 0,
            seed: profileAssignmentSeed
        )
    }

    func dashboardSnapshot() async -> PersonalizationDashboardSnapshot {
        let entityRecords = entitiesByKey.values
            .sorted { lhs, rhs in
                if lhs.isSuppressed != rhs.isSuppressed {
                    return !lhs.isSuppressed
                }
                if lhs.confidence == rhs.confidence {
                    return lhs.lastSeenAt > rhs.lastSeenAt
                }
                return lhs.confidence > rhs.confidence
            }
        let styleRecords = stylesByKey.values
            .sorted { lhs, rhs in
                if Self.styleEvidenceCount(from: lhs) == Self.styleEvidenceCount(from: rhs) {
                    return lhs.lastSeenAt > rhs.lastSeenAt
                }
                return Self.styleEvidenceCount(from: lhs) > Self.styleEvidenceCount(from: rhs)
            }
        let formatRecords = formatPreferencesByKey.values
            .sorted { lhs, rhs in
                if lhs.isSuppressed != rhs.isSuppressed {
                    return !lhs.isSuppressed
                }
                if lhs.confidence == rhs.confidence {
                    return lhs.lastSeenAt > rhs.lastSeenAt
                }
                return lhs.confidence > rhs.confidence
            }

        let recentEvents: [PersonalizationCorrectionEventSummary]
        let correctionEventCount: Int
        if let dataStore {
            var descriptor = FetchDescriptor<DictationCorrectionEvent>(
                sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
            )
            descriptor.fetchLimit = 20
            recentEvents = await dataStore.fetchMappedInBackground(descriptor) {
                Self.correctionEventSummary(from: $0)
            }
            correctionEventCount = await dataStore.countInBackground(FetchDescriptor<DictationCorrectionEvent>())
        } else {
            recentEvents = []
            correctionEventCount = 0
        }

        let outcomes = await outcomeSummaryState()
        // Capture current runtime facts only after every suspension so this
        // snapshot cannot publish a stale launch/settings/helper state.
        let runtimeContext = currentConsumerRuntimeContext()
        let entitySummaries = entityRecords.map {
            Self.entitySummary(from: $0, runtime: runtimeContext)
        }
        let styleSummaries = styleRecords.map {
            Self.styleSummary(from: $0, runtime: runtimeContext)
        }
        let formatSummaries = formatRecords.map(Self.formatPreferenceSummary(from:))

        return PersonalizationDashboardSnapshot(
            capturedAt: Date(),
            runtimeContext: runtimeContext,
            entityConsumers: Self.entityConsumerCounts(from: entitySummaries),
            formatConsumers: Self.formatConsumerCounts(from: formatSummaries),
            styleConsumers: Self.styleConsumerCounts(from: styleSummaries),
            correctionLogEventCount: correctionEventCount,
            outcomes: outcomes,
            topEntities: Array(entitySummaries.prefix(24)),
            topStyles: Array(styleSummaries.prefix(12)),
            recentEvents: recentEvents,
            auditWarnings: auditWarnings(
                entityCount: entityRecords.count,
                correctionEventCount: correctionEventCount
            )
        )
    }

    func controlsSnapshot() async -> PersonalizationControlsSnapshot {
        let entityRecords = entitiesByKey.values
            .sorted { lhs, rhs in
                if lhs.isSuppressed != rhs.isSuppressed {
                    return !lhs.isSuppressed
                }
                if lhs.isUserPinned != rhs.isUserPinned {
                    return lhs.isUserPinned
                }
                if lhs.confidence == rhs.confidence {
                    return lhs.lastSeenAt > rhs.lastSeenAt
                }
                return lhs.confidence > rhs.confidence
            }
        let styleRecords = stylesByKey.values
            .sorted { lhs, rhs in
                if Self.styleEvidenceCount(from: lhs) == Self.styleEvidenceCount(from: rhs) {
                    return lhs.lastSeenAt > rhs.lastSeenAt
                }
                return Self.styleEvidenceCount(from: lhs) > Self.styleEvidenceCount(from: rhs)
            }
        let formatRecords = formatPreferencesByKey.values
            .sorted { lhs, rhs in
                if lhs.isSuppressed != rhs.isSuppressed {
                    return !lhs.isSuppressed
                }
                if lhs.confidence == rhs.confidence {
                    return lhs.lastSeenAt > rhs.lastSeenAt
                }
                return lhs.confidence > rhs.confidence
            }

        let evaluation = await evaluationSnapshot(limit: 500)
        // Capture current runtime facts only after every suspension so rows,
        // summaries, and the context stamp are one atomic MainActor view.
        let runtimeContext = currentConsumerRuntimeContext()
        let entitySummaries = entityRecords.map {
            Self.entitySummary(from: $0, runtime: runtimeContext)
        }
        let styleSummaries = styleRecords.map {
            Self.styleSummary(from: $0, runtime: runtimeContext)
        }
        let formatSummaries = formatRecords.map(Self.formatPreferenceSummary(from:))

        return PersonalizationControlsSnapshot(
            capturedAt: Date(),
            runtimeContext: runtimeContext,
            entityConsumers: Self.entityConsumerCounts(from: entitySummaries),
            formatConsumers: Self.formatConsumerCounts(from: formatSummaries),
            styleConsumers: Self.styleConsumerCounts(from: styleSummaries),
            entities: Array(entitySummaries.prefix(80)),
            styles: Array(styleSummaries.prefix(16)),
            // The store itself is capped at 200. Return every row so a
            // suppressed preference never falls behind the eligible rows and
            // becomes impossible to restore from the only controls surface.
            formatPreferences: formatSummaries,
            evaluation: evaluation
        )
    }

    func evaluationSnapshot(limit: Int = 500) async -> PersonalizationEvaluationSnapshot {
        let outcomes = await outcomeSummaryState()
        guard let dataStore else {
            return PersonalizationEvaluationEngine.evaluate([], outcomes: outcomes)
        }
        var descriptor = FetchDescriptor<DictationCorrectionEvent>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = max(1, min(limit, 2_000))
        let inputs = await dataStore.fetchMappedInBackground(descriptor) {
            Self.evaluationInput(from: $0)
        }
        return PersonalizationEvaluationEngine.evaluate(inputs, outcomes: outcomes)
    }

    func attachOutcomeSummaryProvider(
        _ provider: @escaping PersonalizationOutcomeSummaryProvider
    ) {
        outcomeSummaryProvider = provider
    }

    func attachConsumerRuntimeContextProvider(
        _ provider: @escaping PersonalizationConsumerRuntimeContextProvider
    ) {
        consumerRuntimeContextProvider = provider
    }

    func detachConsumerRuntimeContextProvider() {
        consumerRuntimeContextProvider = nil
    }

    func detachOutcomeSummaryProvider() {
        outcomeSummaryProvider = nil
    }

    private func currentConsumerRuntimeContext() -> PersonalizationConsumerRuntimeContext {
        consumerRuntimeContextProvider?() ?? .unavailable
    }

    private func outcomeSummaryState() async -> PersonalizationOutcomeSummaryState {
        guard let outcomeSummaryProvider else { return .unavailable }
        return .available(await outcomeSummaryProvider())
    }

    func setEntityPinned(id: UUID, isPinned: Bool) async {
        guard beginMutation() else { return }
        defer { endMutation() }
        updateEntity(id: id) { record in
            record.isUserPinned = isPinned
            if isPinned {
                record.isSuppressed = false
                record.negativeCount = max(0, min(record.negativeCount, record.positiveCount - 1))
            }
            record.lastSeenAt = Date()
        }
        await saveChanges()
    }

    func setEntitySuppressed(id: UUID, isSuppressed: Bool) async {
        guard beginMutation() else { return }
        defer { endMutation() }
        updateEntity(id: id) { record in
            record.isSuppressed = isSuppressed
            if isSuppressed {
                record.isUserPinned = false
                record.negativeCount = max(record.negativeCount, record.positiveCount)
                record.confidence = min(record.confidence, 0.25)
            } else {
                record.negativeCount = max(0, min(record.negativeCount, record.positiveCount - 1))
                record.confidence = Self.updatedConfidence(
                    current: record.confidence,
                    positiveCount: record.positiveCount,
                    negativeCount: record.negativeCount,
                    type: record.type
                )
            }
            record.lastSeenAt = Date()
        }
        await saveChanges()
    }

    func setFormatPreferenceSuppressed(id: UUID, isSuppressed: Bool) async {
        guard beginMutation() else { return }
        defer { endMutation() }
        guard let key = formatPreferencesByKey.first(where: { $0.value.id == id })?.key,
              var record = formatPreferencesByKey[key]
        else { return }
        record.isSuppressed = isSuppressed
        record.suppressionReconciliationVersion = !isSuppressed && record.category == .wordCasing
            ? Self.explicitWordCasingRestoreVersion
            : Self.wordCasingSuppressionReconciliationVersion
        record.lastSeenAt = Date()
        formatPreferenceTouchCounter += 1
        record.touchSequence = formatPreferenceTouchCounter
        formatPreferencesByKey[key] = record
        dirtyFormatPreferenceIDs.insert(record.id)
        await saveChanges()
    }

    func clearCorrectionEvents() async {
        guard beginMutation() else { return }
        defer { endMutation() }
        recentEditExemplars.removeAll()
        guard let dataStore else { return }
        _ = await dataStore.performBackgroundWrite { context in
            for event in (try? context.fetch(FetchDescriptor<DictationCorrectionEvent>())) ?? [] {
                context.delete(event)
            }
            return true
        }
    }

    func clearPersonalizationMemory() async {
        await quiesceForWorkspaceClear()
        entitiesByKey.removeAll()
        stylesByKey.removeAll()
        formatPreferencesByKey.removeAll()
        recentEditExemplars.removeAll()
        dirtyEntityIDs.removeAll()
        dirtyStyleIDs.removeAll()
        dirtyFormatPreferenceIDs.removeAll()

        if let dataStore {
            _ = await dataStore.performBackgroundWrite { context in
                for entity in (try? context.fetch(FetchDescriptor<LearnedContextEntity>())) ?? [] {
                    context.delete(entity)
                }
                for profile in (try? context.fetch(FetchDescriptor<LearnedStyleProfile>())) ?? [] {
                    context.delete(profile)
                }
                for preference in (try? context.fetch(FetchDescriptor<LearnedFormatPreference>())) ?? [] {
                    context.delete(preference)
                }
                for event in (try? context.fetch(FetchDescriptor<DictationCorrectionEvent>())) ?? [] {
                    context.delete(event)
                }
                return true
            }
        }
        isWorkspaceWriteSuspended = false
    }

    /// Cancels and joins every deferred persistence operation without mutating
    /// the in-memory model. Call before the database clear transaction.
    func quiesceForWorkspaceClear() async {
        isWorkspaceWriteSuspended = true
        let deferredSave = saveTask
        let deletions = Array(pendingDeletionTasks.values)
        deferredSave?.cancel()
        deletions.forEach { $0.cancel() }
        saveTask = nil
        pendingDeletionTasks.removeAll()
        await deferredSave?.value
        for deletion in deletions {
            await deletion.value
        }
        await waitForActiveMutations()
    }

    /// Re-enables persistence if a multi-store clear aborts before memory is
    /// deleted. Any mutations left dirty before the barrier are retried.
    func resumeAfterWorkspaceClear() {
        isWorkspaceWriteSuspended = false
        if !dirtyEntityIDs.isEmpty
            || !dirtyStyleIDs.isEmpty
            || !dirtyFormatPreferenceIDs.isEmpty {
            scheduleSave()
        }
    }

    func recordCorrection(
        spoken: String,
        written: String,
        spokenIsRealWord: Bool,
        context: CorrectionObservationContext,
        capabilities: LearningCapabilities
    ) async {
        guard capabilities.allowsCorrectionDerivedMutations else { return }
        guard beginMutation() else { return }
        defer { endMutation() }
        let trimmedSpoken = Self.trimCorrectionTerm(spoken)
        let trimmedWritten = Self.trimCorrectionTerm(written)
        guard !trimmedSpoken.isEmpty, !trimmedWritten.isEmpty else { return }
        guard trimmedSpoken.caseInsensitiveCompare(trimmedWritten) != .orderedSame || trimmedSpoken != trimmedWritten else { return }

        let surface = context.surface
        let spokenKey = Self.normalizedKey(trimmedSpoken)
        let writtenKey = Self.normalizedKey(trimmedWritten)
        guard !spokenKey.isEmpty, !writtenKey.isEmpty else { return }

        if suppressReversedCorrection(spokenKey: spokenKey, writtenKey: writtenKey) {
            scheduleSave()
            return
        }
        demoteConflictingOutput(spokenKey: spokenKey, writtenKey: writtenKey, surface: surface)

        let type = Self.entityType(for: trimmedWritten, surface: surface)
        let scope = Self.scope(for: surface)
        let spokenForms = Self.spokenForms(for: trimmedWritten, type: type, aliases: [trimmedSpoken])
        var record = EntityRecord(
            id: UUID(),
            type: type,
            value: trimmedWritten,
            normalizedValue: writtenKey,
            aliases: [trimmedSpoken],
            spokenForms: spokenForms,
            appScope: scope.app,
            siteScope: scope.site,
            surfaceKind: surface.kind.rawValue,
            projectScope: surface.projectLabel,
            confidence: Self.initialConfidence(type: type, spokenIsRealWord: spokenIsRealWord),
            positiveCount: 1,
            negativeCount: 0,
            source: .correctionMemory,
            isUserPinned: false,
            isSuppressed: false,
            createdAt: Date(),
            lastSeenAt: Date(),
            lastUsedAt: nil
        )

        let key = Self.entityKey(for: record)
        if var existing = entitiesByKey[key] {
            existing.value = trimmedWritten
            existing.aliases = Self.merged(existing.aliases, with: [trimmedSpoken], limit: 8)
            existing.spokenForms = Self.spokenForms(for: trimmedWritten, type: existing.type, aliases: existing.aliases)
            existing.positiveCount += 1
            existing.lastSeenAt = Date()
            existing.confidence = Self.updatedConfidence(
                current: existing.confidence,
                positiveCount: existing.positiveCount,
                negativeCount: existing.negativeCount,
                type: existing.type
            )
            existing.isSuppressed = false
            record = existing
        }

        entitiesByKey[key] = record
        dirtyEntityIDs.insert(record.id)
        scheduleSave()
        log.debug("Recorded personalization correction spokenLen=\(trimmedSpoken.count) writtenLen=\(trimmedWritten.count)")
    }

    /// Source-compatible fail-closed adapter. Callers must carry the typed
    /// delivery capability to authorize correction-derived memory.
    func recordCorrection(
        spoken: String,
        written: String,
        spokenIsRealWord: Bool,
        context: CorrectionObservationContext
    ) async {
        await recordCorrection(
            spoken: spoken,
            written: written,
            spokenIsRealWord: spokenIsRealWord,
            context: context,
            capabilities: .none
        )
    }

    /// Learns on-screen names the user actually dictated. A screen-sourced
    /// packet entity that appears intact in the delivered text is a confirmed
    /// sighting: repeated confirmations promote it into recognition/prompt
    /// bias like a learned correction, so the spelling keeps working once the
    /// name is no longer on screen. Sightings start below correction
    /// confidence and climb slowly — and only when spaced apart, so the
    /// pipeline echoing a term it inserted itself cannot self-promote —
    /// while deleting the term in a post-paste edit decays the record.
    /// `corrections` are this event's explicit edits: values the correction
    /// path already recorded are skipped here so one user action never counts
    /// as two confirmations.
    func recordScreenEntityUsage(
        pastedText: String,
        editedText: String,
        corrections: [StoredCorrectionPair] = [],
        context: CorrectionObservationContext,
        boostInsertedTerms: Set<String> = [],
        capabilities: LearningCapabilities,
        now: Date = Date()
    ) async {
        guard capabilities.allowsCorrectionDerivedMutations else { return }
        guard beginMutation() else { return }
        defer { endMutation() }
        guard let packet = context.contextPacket else { return }

        let surface = context.surface
        let correctionWrittenForms = Set(corrections.map {
            Self.trimCorrectionTerm($0.written).lowercased()
        })
        let textWasEdited = pastedText != editedText
        var sightings = 0
        var decays = 0

        for entity in packet.entities {
            // Once the sighting cap is hit, an unedited paste has nothing
            // left to learn — the decay branch needs an edit to fire.
            if sightings >= Self.maxScreenSightingsPerEvent, !textWasEdited { break }
            guard Self.screenSightingSources.contains(entity.source) else { continue }
            guard let value = ScreenContextBiasTerms.decodeSafeValue(entity) else { continue }
            guard !correctionWrittenForms.contains(value.lowercased()) else { continue }

            if Self.containsWholeTerm(value, in: editedText) {
                // A term the decode-time boost itself inserted is the boost
                // echoing back, not the user keeping a name — it must never
                // count as a sighting. Deleting one still decays below: that
                // is a genuine rejection.
                guard !boostInsertedTerms.contains(value.lowercased()) else { continue }
                guard sightings < Self.maxScreenSightingsPerEvent else { continue }
                guard Self.isPlausibleSightingTerm(value) else { continue }
                if recordScreenSighting(of: entity, value: value, surface: surface, now: now) {
                    sightings += 1
                }
            } else if textWasEdited, Self.containsWholeTerm(value, in: pastedText) {
                if decayScreenSighting(of: entity, value: value, surface: surface, now: now) {
                    decays += 1
                }
            }
        }

        if sightings > 0 || decays > 0 {
            scheduleSave()
            log.debug("Screen-context sightings=\(sightings) decays=\(decays)")
        }
    }

    /// Source-compatible fail-closed adapter for legacy sighting callers.
    func recordScreenEntityUsage(
        pastedText: String,
        editedText: String,
        corrections: [StoredCorrectionPair] = [],
        context: CorrectionObservationContext,
        boostInsertedTerms: Set<String> = [],
        now: Date = Date()
    ) async {
        await recordScreenEntityUsage(
            pastedText: pastedText,
            editedText: editedText,
            corrections: corrections,
            context: context,
            boostInsertedTerms: boostInsertedTerms,
            capabilities: .none,
            now: now
        )
    }

    /// Dictionary words show up on every screen, so they never qualify as
    /// sighting-learnable: single tokens must be non-dictionary, and
    /// multi-word values need at least one non-dictionary token ("Meeting
    /// Notes" fails, "Priya Nadkarni" passes).
    private static func isPlausibleSightingTerm(_ value: String) -> Bool {
        let tokens = value.split(separator: " ")
        guard tokens.count > 1 else {
            return !ContextEntityExtractor.isCommonDictionaryWord(value)
        }
        return tokens.contains { !ContextEntityExtractor.isCommonDictionaryWord(String($0)) }
    }

    /// Returns true when the sighting was recorded. Reinforces an existing
    /// record of any source; only creates screen-sourced ones.
    private func recordScreenSighting(
        of entity: ContextEntity,
        value: String,
        surface: SurfaceDescriptor,
        now: Date
    ) -> Bool {
        let normalized = Self.normalizedKey(value)
        guard !normalized.isEmpty else { return false }
        var key = Self.entityKey(type: entity.type, normalizedValue: normalized, surface: surface)
        if entitiesByKey[key] == nil {
            // The correction path types values via entityType(for:), which
            // can disagree with the packet's NER type (a single-token surname
            // lands as .customTerm there). Reinforce that record rather than
            // minting a parallel one for the same name.
            let correctionTypedKey = Self.entityKey(
                type: Self.entityType(for: value, surface: surface),
                normalizedValue: normalized,
                surface: surface
            )
            if entitiesByKey[correctionTypedKey] != nil { key = correctionTypedKey }
        }

        if var existing = entitiesByKey[key] {
            // A sighting is weaker evidence than an explicit correction: it
            // reinforces but never resurrects a suppressed record, and repeat
            // confirmations must be spaced — back-to-back pastes are one
            // session, not independent evidence. The gate reads lastUsedAt
            // because only counted sightings set it: a correction leaves it
            // nil, so a genuine cross-event confirmation right after an
            // explicit correction still counts.
            guard !existing.isSuppressed else { return false }
            if let lastCounted = existing.lastUsedAt,
               now.timeIntervalSince(lastCounted) < Self.screenSightingMinimumSpacing {
                return false
            }
            existing.positiveCount += 1
            existing.lastSeenAt = now
            existing.lastUsedAt = now
            if Self.screenSightingSources.contains(existing.source) {
                existing.confidence = min(
                    existing.confidence + Self.screenSightingConfidenceStep,
                    Self.screenSightingMaxConfidence
                )
            } else {
                // Correction-learned record confirmed in the wild — use the
                // correction path's own confidence climb.
                existing.confidence = Self.updatedConfidence(
                    current: existing.confidence,
                    positiveCount: existing.positiveCount,
                    negativeCount: existing.negativeCount,
                    type: existing.type
                )
            }
            entitiesByKey[key] = existing
            dirtyEntityIDs.insert(existing.id)
            return true
        }

        let scope = Self.scope(for: surface)
        let record = EntityRecord(
            id: UUID(),
            type: entity.type,
            value: value,
            normalizedValue: normalized,
            aliases: [],
            spokenForms: Self.spokenForms(for: value, type: entity.type, aliases: []),
            appScope: scope.app,
            siteScope: scope.site,
            surfaceKind: surface.kind.rawValue,
            projectScope: surface.projectLabel,
            confidence: Self.initialScreenSightingConfidence(type: entity.type),
            positiveCount: 1,
            negativeCount: 0,
            source: entity.source,
            isUserPinned: false,
            isSuppressed: false,
            createdAt: now,
            lastSeenAt: now,
            lastUsedAt: now
        )
        entitiesByKey[key] = record
        dirtyEntityIDs.insert(record.id)
        pruneScreenSightingRecordsIfNeeded()
        return true
    }

    /// The user removed an on-screen term from the pasted text — negative
    /// evidence, applied to screen-sourced records only (correction records
    /// have their own demotion paths). Returns true when a record decayed.
    private func decayScreenSighting(
        of entity: ContextEntity,
        value: String,
        surface: SurfaceDescriptor,
        now: Date
    ) -> Bool {
        let normalized = Self.normalizedKey(value)
        let key = Self.entityKey(
            type: entity.type,
            normalizedValue: normalized,
            surface: surface
        )
        guard var existing = entitiesByKey[key],
              Self.screenSightingSources.contains(existing.source) else { return false }

        existing.negativeCount += 1
        existing.confidence = max(
            Self.screenSightingMinConfidence,
            existing.confidence - Self.screenSightingDecayStep
        )
        // One incidental deletion (a rephrase, a privacy trim) must not kill
        // a name forever — the confidence drop alone already demotes it out
        // of recognition bias. Repeated deletions are a real rejection.
        existing.isSuppressed = existing.negativeCount >= max(2, existing.positiveCount)
        existing.lastSeenAt = now
        entitiesByKey[key] = existing
        dirtyEntityIDs.insert(existing.id)
        return true
    }

    /// Evicts the least-defensible screen-sourced records (suppressed first,
    /// then lowest confidence, then stalest) once their population exceeds
    /// the cap. Pinned records are never evicted.
    private func pruneScreenSightingRecordsIfNeeded() {
        let screenRecords = entitiesByKey.filter {
            Self.screenSightingSources.contains($0.value.source) && !$0.value.isUserPinned
        }
        let overflow = screenRecords.count - Self.maxScreenSightingRecords
        guard overflow > 0 else { return }

        let victims = screenRecords
            .sorted { lhs, rhs in
                if lhs.value.isSuppressed != rhs.value.isSuppressed { return lhs.value.isSuppressed }
                if lhs.value.confidence != rhs.value.confidence {
                    return lhs.value.confidence < rhs.value.confidence
                }
                return lhs.value.lastSeenAt < rhs.value.lastSeenAt
            }
            .prefix(overflow)
        for (key, record) in victims {
            entitiesByKey.removeValue(forKey: key)
            dirtyEntityIDs.remove(record.id)
            enqueueEntityDeletion(id: record.id)
        }
    }

    private func enqueueEntityDeletion(id: UUID) {
        guard !isWorkspaceWriteSuspended else { return }
        guard let dataStore else { return }
        let operationID = UUID()
        let pendingSave = saveTask
        let task = Task { [weak self, dataStore] in
            // Sequence behind any in-flight debounced save: its snapshot may
            // still hold this record, and an unordered upsert after this
            // delete would resurrect the row at next launch.
            _ = await pendingSave?.value
            guard !Task.isCancelled else { return }
            _ = await dataStore.performBackgroundWrite { context in
                var descriptor = FetchDescriptor<LearnedContextEntity>(
                    predicate: #Predicate { $0.id == id }
                )
                descriptor.fetchLimit = 1
                if let model = try? context.fetch(descriptor).first {
                    context.delete(model)
                }
                return true
            }
            self?.pendingDeletionTasks.removeValue(forKey: operationID)
        }
        pendingDeletionTasks[operationID] = task
    }

    /// Records attributable transition evidence. A changed pair may originate
    /// directional policy; an unchanged pair can only confirm an already-active
    /// rule explicitly listed in this delivery's applied metadata.
    func recordStyleTransition(_ request: StyleTransitionFeedbackRequest) async {
        guard request.capabilities.allowsCorrectionDerivedMutations else { return }
        guard beginMutation() else { return }
        defer { endMutation() }

        let pasted = request.pastedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let edited = request.editedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pasted.isEmpty, !edited.isEmpty else { return }

        let surface = request.context.surface
        guard Self.styleLearnableSurfaceKinds.contains(surface.kind) else { return }
        let key = Self.styleKey(for: surface)

        if pasted == edited {
            guard var record = stylesByKey[key],
                  request.appliedStylePolicy.confirms(Self.stylePolicy(from: record))
            else { return }
            record.acceptedCount += 1
            record.appliedPolicyConfirmationCount += 1
            record.lastSeenAt = Date()
            stylesByKey[key] = record
            dirtyStyleIDs.insert(record.id)
            scheduleSave()
            return
        }

        let signals = FormattingEditAnalyzer.signals(pasted: pasted, edited: edited)
        let features = Self.styleFeatures(in: edited)
        var record = stylesByKey[key] ?? Self.blankStyleRecord(key: key, surface: surface)

        // Legacy counters stay available for dashboard continuity, but runtime
        // policy/hints below read only the new provenance-safe counters.
        record.sampleCount += 1
        record.correctedCount += 1
        if features.lowercaseOpening { record.lowercaseOpeningCount += 1 }
        if features.sentenceCaseOpening { record.sentenceCaseOpeningCount += 1 }
        if features.hasGreeting { record.greetingCount += 1 }
        if features.hasSignoff { record.signoffCount += 1 }
        if features.isShortMessage { record.shortMessageCount += 1 }
        if features.hasParagraphBreak { record.paragraphBreakCount += 1 }
        if features.hasFinalPunctuation { record.finalPunctuationCount += 1 }
        record.totalWords += features.wordCount

        record.authoredHabitSampleCount += 1
        if features.hasGreeting { record.authoredGreetingCount += 1 }
        if features.hasSignoff { record.authoredSignoffCount += 1 }
        if features.isShortMessage { record.authoredShortMessageCount += 1 }
        if features.hasParagraphBreak { record.authoredParagraphBreakCount += 1 }

        if signals.lowercasedOpening {
            record.directLowercaseOpeningCount += 1
        }
        if signals.capitalizedOpening {
            record.directSentenceCaseOpeningCount += 1
        }
        if signals.strippedListMarkers {
            record.listMarkersStrippedCount += 1
            record.directListOmissionCount += 1
        }
        if signals.addedListMarkers {
            record.listMarkersKeptCount += 1
            record.directListRequirementCount += 1
        }
        if signals.strippedTrailingPeriod {
            record.trailingPunctuationStrippedCount += 1
            record.directTrailingPeriodOmissionCount += 1
        }
        if signals.addedTrailingPeriod {
            record.directTrailingPeriodRequirementCount += 1
        }
        record.lastSeenAt = Date()

        stylesByKey[key] = record
        dirtyStyleIDs.insert(record.id)
        scheduleSave()
    }

    /// Legacy style samples have no pasted baseline or typed permission and
    /// therefore cannot mutate state.
    func recordStyleSample(
        finalText: String,
        hadCorrection: Bool,
        context: CorrectionObservationContext
    ) async {
        _ = (finalText, hadCorrection, context)
    }

    /// Learns auto-send content habits from raw ASR text only. The request
    /// cannot affect casing, lists, or punctuation policy.
    func recordAutoSentDelivery(_ request: RawTranscriptHabitFeedbackRequest) async {
        guard request.capabilities.allowsRawTranscriptHabits else { return }
        guard beginMutation() else { return }
        defer { endMutation() }
        let text = request.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let surface = request.context.surface
        guard Self.styleLearnableSurfaceKinds.contains(surface.kind) else { return }

        let key = Self.styleKey(for: surface)
        var record = stylesByKey[key] ?? Self.blankStyleRecord(key: key, surface: surface)
        let features = Self.styleFeatures(in: text)

        // Preserve legacy dashboard totals while keeping runtime decisions on
        // the explicit raw-transcript counters.
        record.autoSentSampleCount += 1
        if features.hasGreeting { record.autoSentGreetingCount += 1 }
        if features.hasSignoff { record.autoSentSignoffCount += 1 }
        if features.isShortMessage { record.autoSentShortMessageCount += 1 }
        if features.hasParagraphBreak { record.autoSentParagraphBreakCount += 1 }

        record.rawTranscriptHabitSampleCount += 1
        if features.hasGreeting { record.rawTranscriptGreetingCount += 1 }
        if features.hasSignoff { record.rawTranscriptSignoffCount += 1 }
        if features.isShortMessage { record.rawTranscriptShortMessageCount += 1 }
        if features.hasParagraphBreak { record.rawTranscriptParagraphBreakCount += 1 }
        record.lastSeenAt = Date()

        stylesByKey[key] = record
        dirtyStyleIDs.insert(record.id)
        scheduleSave()
    }

    /// Source-compatible fail-closed adapter. `finalText` may contain formatter
    /// output, so it can never stand in for the raw transcript.
    func recordAutoSentDelivery(
        finalText: String,
        context: CorrectionObservationContext
    ) async {
        _ = (finalText, context)
    }

    /// Surfaces whose users qualify for style learning.
    private static let styleLearnableSurfaceKinds: [SurfaceKind] = [
        .email, .chat, .social, .docs, .task, .browser, .form,
    ]

    private nonisolated static func blankStyleRecord(
        key: String,
        surface: SurfaceDescriptor
    ) -> StyleRecord {
        let scope = Self.scope(for: surface)
        return StyleRecord(
            id: UUID(),
            scopeKey: key,
            surfaceKind: surface.kind,
            appScope: scope.app,
            siteScope: scope.site,
            projectScope: surface.projectLabel,
            sampleCount: 0,
            acceptedCount: 0,
            correctedCount: 0,
            lowercaseOpeningCount: 0,
            sentenceCaseOpeningCount: 0,
            greetingCount: 0,
            signoffCount: 0,
            shortMessageCount: 0,
            paragraphBreakCount: 0,
            finalPunctuationCount: 0,
            totalWords: 0,
            listMarkersStrippedCount: 0,
            listMarkersKeptCount: 0,
            trailingPunctuationStrippedCount: 0,
            createdAt: Date(),
            lastSeenAt: Date()
        )
    }

    /// Explicit capability-bearing adapter retained for direct callers.
    func recordFormattingEditSignals(
        pastedText: String,
        editedText: String,
        context: CorrectionObservationContext,
        capabilities: LearningCapabilities,
        appliedStylePolicy: AppliedStylePolicy = .none
    ) async {
        await recordStyleTransition(StyleTransitionFeedbackRequest(
            pastedText: pastedText,
            editedText: editedText,
            context: context,
            capabilities: capabilities,
            appliedStylePolicy: appliedStylePolicy
        ))
    }

    /// Source-compatible fail-closed adapter for callers missing permissions.
    func recordFormattingEditSignals(
        pastedText: String,
        editedText: String,
        context: CorrectionObservationContext
    ) async {
        await recordFormattingEditSignals(
            pastedText: pastedText,
            editedText: editedText,
            context: context,
            capabilities: .none
        )
    }

    func stylePolicy(for surface: SurfaceDescriptor) -> StylePolicy {
        guard let record = stylesByKey[Self.styleKey(for: surface)] else {
            return .inherit
        }
        return Self.stylePolicy(from: record)
    }

    func stylePolicyEvidence(for surface: SurfaceDescriptor) -> StylePolicyEvidence {
        guard let record = stylesByKey[Self.styleKey(for: surface)] else {
            return StylePolicyEvidence()
        }
        return Self.stylePolicyEvidence(from: record)
    }

    /// Local formatting consumes the exact policy used to compose cloud hints.
    func formattingPreferences(for surface: SurfaceDescriptor) -> DictationFormattingPreferences {
        var preferences = DictationFormattingPreferences()
        let policy = stylePolicy(for: surface)
        let localPolicy = policy
        preferences.stylePolicy = localPolicy
        preferences.suppressAutoLists = localPolicy.listMarkers == .omit
        preferences.omitTrailingPeriod = localPolicy.trailingPeriod == .omit
        preferences.preferLowercaseOpening = localPolicy.openingCase == .lowercase
        preferences.suppressedDomainExpansionHosts = Set(
            activeFormatPreferences(category: .urlExpansionRevert).map(\.scopeKey)
        )
        preferences.preferredPhoneStyle = preferredPhoneStyle()
        preferences.learnedWordCasings = learnedWordCasings()
        return preferences
    }

    /// High-confidence learned names/terms for recognition-level vocabulary
    /// biasing. Stricter than the snapshot's prompt-bias eligibility: a wrong
    /// term here rewrites the *decode*, so only repeatedly-confirmed person
    /// names and custom terms qualify.
    func recognitionBiasTerms(limit: Int = 20) -> [String] {
        var seen = Set<String>()
        return entitiesByKey.values
            .filter { record in
                Self.entityEligibility(from: record, scopeMatches: true)
                    .isRecognitionEligible
            }
            .sorted { lhs, rhs in
                if lhs.confidence == rhs.confidence {
                    return lhs.lastSeenAt > rhs.lastSeenAt
                }
                return lhs.confidence > rhs.confidence
            }
            .compactMap { record in
                let normalized = record.value.lowercased()
                guard seen.insert(normalized).inserted else { return nil }
                return record.value
            }
            .prefix(limit)
            .map { $0 }
    }

    /// Lowercased token → preferred casing, covering learned word casings and
    /// the learned email casing. Capped so the pipeline never scans an
    /// unbounded map per dictation.
    private func learnedWordCasings(limit: Int = 24) -> [String: String] {
        var casings: [String: String] = [:]
        let ranked = activeFormatPreferences(category: .wordCasing)
            .sorted { $0.confidence > $1.confidence }
            .prefix(limit)
        for record in ranked {
            casings[record.preferredValue.lowercased()] = record.preferredValue
        }
        if let email = preferredEmailCasing() {
            casings[email.lowercased()] = email
        }
        return casings
    }

    // MARK: - Learned format preferences

    /// Cascades a dictionary casing veto into the parallel learned-format
    /// representation so the same casing cannot reappear later in the text
    /// pipeline. Only exact case-only pairs match; semantic replacements stay
    /// independent.
    func suppressMatchingWordCasingPreference(spoken: String, written: String) {
        guard !isWorkspaceWriteSuspended else { return }
        var changed = false
        for (key, var record) in formatPreferencesByKey {
            guard Self.matchesDictionaryCasing(
                record: record,
                spoken: spoken,
                written: written
            ) else { continue }
            guard !record.isSuppressed
                    || record.suppressionReconciliationVersion
                        < Self.wordCasingSuppressionReconciliationVersion
            else { continue }
            record.isSuppressed = true
            record.suppressionReconciliationVersion = Self.wordCasingSuppressionReconciliationVersion
            record.lastSeenAt = Date()
            formatPreferenceTouchCounter += 1
            record.touchSequence = formatPreferenceTouchCounter
            formatPreferencesByKey[key] = record
            dirtyFormatPreferenceIDs.insert(record.id)
            changed = true
        }
        if changed { scheduleSave() }
    }

    /// Startup repair for users who already had both a suppressed dictionary
    /// casing and an active learned casing before suppression became shared.
    /// Legacy rows are marked reconciled. Matching current rows are also
    /// reasserted so an abrupt exit between the dictionary and debounced format
    /// saves cannot resurrect the casing; an explicit restore uses a sentinel
    /// and remains untouched until a new dictionary suppression event.
    func reconcileSuppressedDictionaryCasings(_ words: [DictionaryWord]) async {
        guard beginMutation() else { return }
        defer { endMutation() }
        let suppressedPairs = words.compactMap { word -> (spoken: String, written: String)? in
            guard word.isSuppressed,
                  Self.isCaseOnlyPair(spoken: word.spoken, written: word.written)
            else { return nil }
            return (word.spoken, word.written)
        }

        var changed = false
        for (key, var record) in formatPreferencesByKey {
            guard record.suppressionReconciliationVersion
                    != Self.explicitWordCasingRestoreVersion
            else { continue }
            let matchesSuppressedDictionary = suppressedPairs.contains(where: {
                Self.matchesDictionaryCasing(
                    record: record,
                    spoken: $0.spoken,
                    written: $0.written
                )
            })
            var recordChanged = false
            if matchesSuppressedDictionary, !record.isSuppressed {
                record.isSuppressed = true
                recordChanged = true
            }
            if record.suppressionReconciliationVersion
                < Self.wordCasingSuppressionReconciliationVersion {
                record.suppressionReconciliationVersion = Self.wordCasingSuppressionReconciliationVersion
                recordChanged = true
            }
            guard recordChanged else { continue }
            formatPreferencesByKey[key] = record
            dirtyFormatPreferenceIDs.insert(record.id)
            changed = true
        }
        if changed { await saveChanges() }
    }

    private nonisolated static func isCaseOnlyPair(spoken: String, written: String) -> Bool {
        let spoken = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        let written = written.trimmingCharacters(in: .whitespacesAndNewlines)
        return !spoken.isEmpty
            && !written.isEmpty
            && spoken != written
            && spoken.lowercased() == written.lowercased()
    }

    private nonisolated static func matchesDictionaryCasing(
        record: FormatPreferenceRecord,
        spoken: String,
        written: String
    ) -> Bool {
        let trimmedWritten = written.trimmingCharacters(in: .whitespacesAndNewlines)
        return isCaseOnlyPair(spoken: spoken, written: written)
            && record.category == .wordCasing
            && record.scopeKey == FormatCorrectionClassifier.globalScope
            && record.preferredValue == trimmedWritten
            && record.preferredValue.lowercased()
                == spoken.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Learns the user's formatting preferences from a post-paste edit — the
    /// case-only / symbol-only diffs the correction pipeline discards (reverting
    /// an auto-expanded domain, reformatting a phone number, lowercasing an
    /// email). Reinforces the matching preference and decays a directly
    /// contradicting one using the repo's +0.14 / -0.22 reward convention.
    func recordFormatCorrections(
        pasted: String,
        edited: String,
        context: CorrectionObservationContext,
        capabilities: LearningCapabilities
    ) {
        guard capabilities.allowsCorrectionDerivedMutations else { return }
        guard beginMutation() else { return }
        defer { endMutation() }
        let surface = context.surface
        let signals = FormatCorrectionClassifier.classify(pasted: pasted, edited: edited)
        guard !signals.isEmpty else { return }

        var changed = false
        for signal in signals {
            let scopeKey = Self.formatScopeKey(for: signal, surface: surface)
            reinforceFormatPreference(signal: signal, scopeKey: scopeKey)
            decayConflictingFormatPreferences(signal: signal, scopeKey: scopeKey)
            changed = true
        }

        guard changed else { return }
        pruneFormatPreferencesIfNeeded()
        scheduleSave()
        log.debug("Recorded \(signals.count) format preference signal(s)")
    }

    /// Source-compatible fail-closed adapter for callers missing permissions.
    func recordFormatCorrections(
        pasted: String,
        edited: String,
        context: CorrectionObservationContext
    ) {
        recordFormatCorrections(
            pasted: pasted,
            edited: edited,
            context: context,
            capabilities: .none
        )
    }

    private func reinforceFormatPreference(signal: FormatCorrectionSignal, scopeKey: String) {
        let category = signal.category
        let key = Self.formatPreferenceKey(category: category, scopeKey: scopeKey, preferredValue: signal.observedValue)
        formatPreferenceTouchCounter += 1
        if var record = formatPreferencesByKey[key] {
            record.positiveCount += 1
            record.confidence = Self.clampFormatConfidence(record.confidence + Self.formatPreferenceReward)
            record.preferredValue = signal.observedValue
            record.lastSeenAt = Date()
            record.touchSequence = formatPreferenceTouchCounter
            formatPreferencesByKey[key] = record
            dirtyFormatPreferenceIDs.insert(record.id)
        } else {
            let startsSuppressed = category == .wordCasing
                && scopeKey == FormatCorrectionClassifier.globalScope
                && (dictionaryCasingSuppressionProvider?(signal.observedValue) ?? false)
            let record = FormatPreferenceRecord(
                id: UUID(),
                category: category,
                scopeKey: scopeKey,
                preferredValue: signal.observedValue,
                positiveCount: 1,
                negativeCount: 0,
                confidence: Self.formatPreferenceInitialConfidence,
                isSuppressed: startsSuppressed,
                suppressionReconciliationVersion: newFormatPreferenceReconciliationVersion,
                createdAt: Date(),
                lastSeenAt: Date(),
                touchSequence: formatPreferenceTouchCounter
            )
            formatPreferencesByKey[key] = record
            dirtyFormatPreferenceIDs.insert(record.id)
        }
    }

    /// A signal contradicts a sibling preference in the same (category, scope)
    /// that expressed a *different* preferred value — decay it.
    private func decayConflictingFormatPreferences(signal: FormatCorrectionSignal, scopeKey: String) {
        for (key, var record) in formatPreferencesByKey {
            guard record.category == signal.category, record.scopeKey == scopeKey else { continue }
            guard record.preferredValue.caseInsensitiveCompare(signal.observedValue) != .orderedSame else { continue }
            record.negativeCount += 1
            record.confidence = Self.clampFormatConfidence(record.confidence - Self.formatPreferencePenalty)
            record.lastSeenAt = Date()
            formatPreferenceTouchCounter += 1
            record.touchSequence = formatPreferenceTouchCounter
            formatPreferencesByKey[key] = record
            dirtyFormatPreferenceIDs.insert(record.id)
        }
    }

    private func pruneFormatPreferencesIfNeeded() {
        guard formatPreferencesByKey.count > Self.maxFormatPreferences else { return }
        // Preserve explicit suppression vetoes while any active row can be
        // evicted. Within each group, evict least-recently-touched first;
        // confidence-first eviction would fossilize the store by dropping
        // every brand-new record at the cap.
        let ordered = formatPreferencesByKey.sorted { lhs, rhs in
            if lhs.value.isSuppressed != rhs.value.isSuppressed {
                return !lhs.value.isSuppressed
            }
            if lhs.value.touchSequence != rhs.value.touchSequence {
                return lhs.value.touchSequence < rhs.value.touchSequence
            }
            return lhs.value.confidence < rhs.value.confidence
        }
        let dropCount = formatPreferencesByKey.count - Self.maxFormatPreferences
        for (key, record) in ordered.prefix(dropCount) {
            formatPreferencesByKey.removeValue(forKey: key)
            dirtyFormatPreferenceIDs.remove(record.id)
            enqueueFormatPreferenceDeletion(id: record.id)
        }
    }

    /// True when the user has consistently reverted an auto-expanded domain for
    /// this host back to the bare brand word.
    func shouldSuppressSiteDomainExpansion(host: String) -> Bool {
        let scopeKey = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !scopeKey.isEmpty else { return false }
        return activeFormatPreferences(category: .urlExpansionRevert)
            .contains { $0.scopeKey == scopeKey }
    }

    func preferredPhoneStyle() -> String? {
        bestActiveFormatPreference(category: .phoneStyle)?.preferredValue
    }

    func preferredEmailCasing() -> String? {
        bestActiveFormatPreference(category: .emailCasing)?.preferredValue
    }

    func preferredWordCasing(for word: String) -> String? {
        let normalized = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        return activeFormatPreferences(category: .wordCasing)
            .first { $0.preferredValue.lowercased() == normalized }?
            .preferredValue
    }

    private func activeFormatPreferences(category: FormatCorrectionCategory) -> [FormatPreferenceRecord] {
        formatPreferencesByKey.values.filter {
            $0.category == category
                && Self.formatEligibility(from: $0).isFormatterEligible
        }
    }

    private func bestActiveFormatPreference(category: FormatCorrectionCategory) -> FormatPreferenceRecord? {
        activeFormatPreferences(category: category).max { lhs, rhs in
            if lhs.confidence == rhs.confidence {
                return lhs.lastSeenAt < rhs.lastSeenAt
            }
            return lhs.confidence < rhs.confidence
        }
    }

    private nonisolated static func clampFormatConfidence(_ value: Double) -> Double {
        min(max(value, formatPreferenceMinConfidence), formatPreferenceMaxConfidence)
    }

    private nonisolated static func formatScopeKey(
        for signal: FormatCorrectionSignal,
        surface: SurfaceDescriptor
    ) -> String {
        switch signal.category {
        case .urlExpansionRevert:
            let hint = signal.scopeHint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !hint.isEmpty, hint != FormatCorrectionClassifier.globalScope { return hint }
            return normalizedOptional(surface.siteHost) ?? FormatCorrectionClassifier.globalScope
        case .phoneStyle, .emailCasing, .wordCasing, .punctuation:
            return FormatCorrectionClassifier.globalScope
        }
    }

    private nonisolated static func formatPreferenceKey(
        category: FormatCorrectionCategory,
        scopeKey: String,
        preferredValue: String
    ) -> String {
        let keyValue: String
        switch category {
        case .urlExpansionRevert, .wordCasing, .emailCasing, .phoneStyle:
            keyValue = preferredValue.lowercased()
        case .punctuation:
            // Punctuation is a binary add/remove — key by category+scope only so
            // opposing verbs contend on one row-pair via decay.
            keyValue = preferredValue.lowercased()
        }
        return [category.rawValue, scopeKey, keyValue].joined(separator: "|").lowercased()
    }

    private nonisolated static func formatPreferenceKey(for record: FormatPreferenceRecord) -> String {
        formatPreferenceKey(
            category: record.category,
            scopeKey: record.scopeKey,
            preferredValue: record.preferredValue
        )
    }

    private func enqueueFormatPreferenceDeletion(id: UUID) {
        guard !isWorkspaceWriteSuspended else { return }
        guard let dataStore else { return }
        let operationID = UUID()
        let task = Task { [weak self, dataStore] in
            guard !Task.isCancelled else { return }
            _ = await dataStore.performBackgroundWrite { context in
                var descriptor = FetchDescriptor<LearnedFormatPreference>(
                    predicate: #Predicate { $0.id == id }
                )
                descriptor.fetchLimit = 1
                if let model = try? context.fetch(descriptor).first {
                    context.delete(model)
                }
                return true
            }
            self?.pendingDeletionTasks.removeValue(forKey: operationID)
        }
        pendingDeletionTasks[operationID] = task
    }

    func recordCorrectionEvent(
        pastedText: String,
        editedText: String,
        rawTranscript: String?,
        corrections: [StoredCorrectionPair],
        context: CorrectionObservationContext,
        wasEdited: Bool,
        capabilities: LearningCapabilities
    ) async {
        guard capabilities.allowsCorrectionDerivedMutations else { return }
        guard beginMutation() else { return }
        defer { endMutation() }

        let surface = context.surface
        let event = DictationCorrectionEventSnapshot(
            id: UUID(),
            timestamp: Date(),
            appName: surface.appName,
            bundleId: surface.bundleId,
            windowTitle: surface.windowTitle,
            browserURL: surface.browserURL,
            surfaceKind: surface.kind.rawValue,
            rawTranscriptPreview: Self.preview(rawTranscript),
            pastedTextPreview: Self.preview(pastedText) ?? "",
            editedTextPreview: Self.preview(editedText) ?? "",
            corrections: corrections,
            hadCorrection: wasEdited
        )

        if wasEdited,
           let exemplar = DictationEditExemplarFilter.candidate(
               original: event.pastedTextPreview,
               edited: event.editedTextPreview
           ) {
            recentEditExemplars.insert(
                EditExemplarRecord(
                    surfaceKind: event.surfaceKind,
                    appScope: Self.normalizedOptional(surface.bundleId),
                    exemplar: exemplar,
                    recordedAt: event.timestamp
                ),
                at: 0
            )
            if recentEditExemplars.count > Self.maxEditExemplarBufferCount {
                recentEditExemplars.removeLast(recentEditExemplars.count - Self.maxEditExemplarBufferCount)
            }
        }

        guard let dataStore else { return }
        _ = await dataStore.performBackgroundWrite { modelContext in
            modelContext.insert(Self.model(from: event))
            return true
        }
    }

    /// Source-compatible fail-closed adapter for callers missing permissions.
    func recordCorrectionEvent(
        pastedText: String,
        editedText: String,
        rawTranscript: String?,
        corrections: [StoredCorrectionPair],
        context: CorrectionObservationContext,
        wasEdited: Bool
    ) async {
        await recordCorrectionEvent(
            pastedText: pastedText,
            editedText: editedText,
            rawTranscript: rawTranscript,
            corrections: corrections,
            context: context,
            wasEdited: wasEdited,
            capabilities: .none
        )
    }

    func saveChanges() async {
        guard beginMutation() else { return }
        defer { endMutation() }
        let deferredSave = saveTask
        deferredSave?.cancel()
        saveTask = nil
        await deferredSave?.value
        guard !isWorkspaceWriteSuspended else { return }
        await persistDirtyRecords()
    }

    private func updateEntity(id: UUID, mutate: (inout EntityRecord) -> Void) {
        guard let key = entitiesByKey.first(where: { $0.value.id == id })?.key,
              var record = entitiesByKey[key]
        else { return }
        mutate(&record)
        entitiesByKey[key] = record
        dirtyEntityIDs.insert(record.id)
    }

    // MARK: - Snapshot scoring

    private func isEligible(_ record: EntityRecord, for surface: SurfaceDescriptor) -> Bool {
        Self.entityEligibility(
            from: record,
            scopeMatches: matchesScope(record, surface: surface)
        ).isPromptEligible
    }

    private func score(_ record: EntityRecord, for surface: SurfaceDescriptor) -> Double {
        var score = record.confidence
        score += min(Double(record.positiveCount) * 0.06, 0.24)
        score -= min(Double(record.negativeCount) * 0.10, 0.4)

        if record.isUserPinned { score += 0.35 }
        if record.surfaceKind == surface.kind.rawValue { score += 0.12 }
        if record.appScope?.lowercased() == surface.bundleId?.lowercased() { score += 0.14 }
        if record.siteScope?.lowercased() == surface.siteHost?.lowercased() { score += 0.14 }
        if record.projectScope?.lowercased() == surface.projectLabel?.lowercased() { score += 0.12 }

        let ageDays = max(0, Date().timeIntervalSince(record.lastSeenAt) / 86_400)
        score -= min(ageDays * 0.01, 0.18)
        return score
    }

    private func contextEntity(from record: EntityRecord, surface: SurfaceDescriptor) -> ContextEntity {
        ContextEntity(
            type: record.type,
            value: record.value,
            normalizedValue: record.normalizedValue,
            spokenForms: record.spokenForms,
            source: record.source,
            confidence: min(max(record.confidence, 0), 0.98),
            recencyScore: 0.06,
            proximityScore: scopeProximity(for: record, surface: surface),
            trustTier: .biasTerm,
            isSensitive: false,
            evidence: "learned correction memory",
            surfaceScope: record.surfaceKind,
            appScope: record.appScope,
            siteScope: record.siteScope,
            projectScope: record.projectScope
        )
    }

    private func scopeProximity(for record: EntityRecord, surface: SurfaceDescriptor) -> Double {
        var proximity = 0.35
        if record.surfaceKind == surface.kind.rawValue { proximity += 0.12 }
        if record.appScope?.lowercased() == surface.bundleId?.lowercased() { proximity += 0.16 }
        if record.siteScope?.lowercased() == surface.siteHost?.lowercased() { proximity += 0.16 }
        return min(proximity, 0.88)
    }

    // MARK: - Style

    private func styleHint(for surface: SurfaceDescriptor) -> String? {
        guard let record = stylesByKey[Self.styleKey(for: surface)] else { return nil }
        let hint = Self.styleHint(from: record, surfaceKind: surface.kind)
        return hint?.isEmpty == false ? hint : nil
    }

    private nonisolated static func stylePolicyEvidence(
        from record: StyleRecord
    ) -> StylePolicyEvidence {
        StylePolicyEvidence(
            lowercaseOpening: record.directLowercaseOpeningCount,
            sentenceCaseOpening: record.directSentenceCaseOpeningCount,
            listOmission: record.directListOmissionCount,
            listRequirement: record.directListRequirementCount,
            trailingPeriodOmission: record.directTrailingPeriodOmissionCount,
            trailingPeriodRequirement: record.directTrailingPeriodRequirementCount,
            appliedPolicyConfirmations: record.appliedPolicyConfirmationCount
        )
    }

    private nonisolated static func stylePolicy(from record: StyleRecord) -> StylePolicy {
        StylePolicy.resolve(evidence: stylePolicyEvidence(from: record))
    }

    private nonisolated static func styleHint(from record: StyleRecord, surfaceKind: SurfaceKind) -> String? {
        let policy = stylePolicy(from: record)
        var hints: [String] = []

        switch policy.openingCase {
        case .lowercase:
            hints.append("start messages with a lowercase opening")
        case .sentenceCase:
            hints.append("use sentence-case openings")
        case .inherit:
            break
        }
        switch policy.listMarkers {
        case .omit:
            hints.append("omit automatic list markers")
        case .require:
            hints.append("preserve list formatting when content is list-shaped")
        case .inherit:
            break
        }
        switch policy.trailingPeriod {
        case .omit:
            hints.append("omit the trailing period")
        case .require:
            hints.append("include a trailing period")
        case .inherit:
            break
        }

        let habitSamples = record.authoredHabitSampleCount
            + record.rawTranscriptHabitSampleCount
        if habitSamples >= 3 {
            func habitRate(_ authored: Int, _ rawTranscript: Int) -> Double {
                Double(authored + rawTranscript) / Double(habitSamples)
            }
            let shortRate = habitRate(
                record.authoredShortMessageCount,
                record.rawTranscriptShortMessageCount
            )
            let paragraphRate = habitRate(
                record.authoredParagraphBreakCount,
                record.rawTranscriptParagraphBreakCount
            )
            let greetingRate = habitRate(
                record.authoredGreetingCount,
                record.rawTranscriptGreetingCount
            )
            let signoffRate = habitRate(
                record.authoredSignoffCount,
                record.rawTranscriptSignoffCount
            )

            if [.chat, .social].contains(surfaceKind), shortRate >= 0.70 {
                hints.append("keep messages concise")
            }
            if surfaceKind == .email, paragraphRate >= 0.45 {
                hints.append("use paragraph breaks for email body text")
            } else if ![.chat, .social].contains(surfaceKind), paragraphRate >= 0.40 {
                hints.append("use paragraph breaks for longer text")
            }
            if greetingRate <= (surfaceKind == .email ? 0.15 : 0.10) {
                hints.append("do not add greetings unless dictated")
            }
            if surfaceKind == .email, signoffRate <= 0.15 {
                hints.append("do not add signoffs unless dictated")
            }
        }

        guard !hints.isEmpty else { return nil }
        return "Learned user style for this app: \(hints.joined(separator: "; "))."
    }

    /*
     Legacy rate-derived style inference intentionally ended here. Those rows
     remain readable for history/dashboard compatibility, but only the direct
     transition policy and provenance-safe habit counters above affect output.
     */

    // MARK: - Persistence

    private func scheduleSave() {
        guard !isWorkspaceWriteSuspended else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.entitySaveDebounce)
            guard !Task.isCancelled else { return }
            await self?.persistDirtyRecords()
        }
    }

    private func persistDirtyRecords() async {
        guard !isWorkspaceWriteSuspended else { return }
        guard let dataStore else { return }
        let entityIDs = dirtyEntityIDs
        let styleIDs = dirtyStyleIDs
        let formatIDs = dirtyFormatPreferenceIDs
        guard !entityIDs.isEmpty || !styleIDs.isEmpty || !formatIDs.isEmpty else { return }

        let entitySnapshots = entitiesByKey.values.filter { entityIDs.contains($0.id) }
        let styleSnapshots = stylesByKey.values.filter { styleIDs.contains($0.id) }
        let formatSnapshots = formatPreferencesByKey.values.filter { formatIDs.contains($0.id) }
        dirtyEntityIDs.subtract(entityIDs)
        dirtyStyleIDs.subtract(styleIDs)
        dirtyFormatPreferenceIDs.subtract(formatIDs)

        let saved = await dataStore.performBackgroundWrite { context in
            for snapshot in entitySnapshots {
                let id = snapshot.id
                var descriptor = FetchDescriptor<LearnedContextEntity>(
                    predicate: #Predicate { $0.id == id }
                )
                descriptor.fetchLimit = 1
                if let model = try? context.fetch(descriptor).first {
                    Self.apply(snapshot, to: model)
                } else {
                    context.insert(Self.model(from: snapshot))
                }
            }

            for snapshot in styleSnapshots {
                let id = snapshot.id
                var descriptor = FetchDescriptor<LearnedStyleProfile>(
                    predicate: #Predicate { $0.id == id }
                )
                descriptor.fetchLimit = 1
                if let model = try? context.fetch(descriptor).first {
                    Self.apply(snapshot, to: model)
                } else {
                    context.insert(Self.model(from: snapshot))
                }
            }

            for snapshot in formatSnapshots {
                let id = snapshot.id
                var descriptor = FetchDescriptor<LearnedFormatPreference>(
                    predicate: #Predicate { $0.id == id }
                )
                descriptor.fetchLimit = 1
                if let model = try? context.fetch(descriptor).first {
                    Self.apply(snapshot, to: model)
                } else {
                    context.insert(Self.model(from: snapshot))
                }
            }
            return true
        } ?? false

        if !saved {
            dirtyEntityIDs.formUnion(entityIDs)
            dirtyStyleIDs.formUnion(styleIDs)
            dirtyFormatPreferenceIDs.formUnion(formatIDs)
        }
    }

    private func beginMutation() -> Bool {
        guard !isWorkspaceWriteSuspended else { return false }
        activeMutationCount += 1
        return true
    }

    private func endMutation() {
        precondition(activeMutationCount > 0)
        activeMutationCount -= 1
        guard activeMutationCount == 0 else { return }
        let waiters = mutationDrainWaiters
        mutationDrainWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func waitForActiveMutations() async {
        guard activeMutationCount > 0 else { return }
        await withCheckedContinuation { continuation in
            mutationDrainWaiters.append(continuation)
        }
    }

    private struct DictationCorrectionEventSnapshot: Sendable {
        var id: UUID
        var timestamp: Date
        var appName: String?
        var bundleId: String?
        var windowTitle: String?
        var browserURL: String?
        var surfaceKind: String?
        var rawTranscriptPreview: String?
        var pastedTextPreview: String
        var editedTextPreview: String
        var corrections: [StoredCorrectionPair]
        var hadCorrection: Bool
    }

    // MARK: - Record conversion

    private nonisolated static func record(from model: LearnedContextEntity) -> EntityRecord {
        EntityRecord(
            id: model.id,
            type: ContextEntityType(rawValue: model.type) ?? .customTerm,
            value: model.value,
            normalizedValue: model.normalizedValue,
            aliases: decodeJSONStringArray(model.aliasesJSON),
            spokenForms: decodeJSONStringArray(model.spokenFormsJSON),
            appScope: model.appScope,
            siteScope: model.siteScope,
            surfaceKind: model.surfaceKind,
            projectScope: model.projectScope,
            confidence: model.confidence,
            positiveCount: model.positiveCount,
            negativeCount: model.negativeCount,
            source: EvidenceSource(rawValue: model.source) ?? .correctionMemory,
            isUserPinned: model.isUserPinned,
            isSuppressed: model.isSuppressed,
            createdAt: model.createdAt,
            lastSeenAt: model.lastSeenAt,
            lastUsedAt: model.lastUsedAt
        )
    }

    private nonisolated static func model(from record: EntityRecord) -> LearnedContextEntity {
        LearnedContextEntity(
            id: record.id,
            type: record.type.rawValue,
            value: record.value,
            normalizedValue: record.normalizedValue,
            aliasesJSON: encodeJSONStringArray(record.aliases),
            spokenFormsJSON: encodeJSONStringArray(record.spokenForms),
            appScope: record.appScope,
            siteScope: record.siteScope,
            surfaceKind: record.surfaceKind,
            projectScope: record.projectScope,
            confidence: record.confidence,
            positiveCount: record.positiveCount,
            negativeCount: record.negativeCount,
            source: record.source.rawValue,
            isUserPinned: record.isUserPinned,
            isSuppressed: record.isSuppressed,
            createdAt: record.createdAt,
            lastSeenAt: record.lastSeenAt,
            lastUsedAt: record.lastUsedAt
        )
    }

    private nonisolated static func apply(_ record: EntityRecord, to model: LearnedContextEntity) {
        model.type = record.type.rawValue
        model.value = record.value
        model.normalizedValue = record.normalizedValue
        model.aliasesJSON = encodeJSONStringArray(record.aliases)
        model.spokenFormsJSON = encodeJSONStringArray(record.spokenForms)
        model.appScope = record.appScope
        model.siteScope = record.siteScope
        model.surfaceKind = record.surfaceKind
        model.projectScope = record.projectScope
        model.confidence = record.confidence
        model.positiveCount = record.positiveCount
        model.negativeCount = record.negativeCount
        model.source = record.source.rawValue
        model.isUserPinned = record.isUserPinned
        model.isSuppressed = record.isSuppressed
        model.createdAt = record.createdAt
        model.lastSeenAt = record.lastSeenAt
        model.lastUsedAt = record.lastUsedAt
    }

    private nonisolated static func record(from model: LearnedStyleProfile) -> StyleRecord {
        StyleRecord(
            id: model.id,
            scopeKey: model.scopeKey,
            surfaceKind: SurfaceKind(rawValue: model.surfaceKind) ?? .other,
            appScope: model.appScope,
            siteScope: model.siteScope,
            projectScope: model.projectScope,
            sampleCount: model.sampleCount,
            acceptedCount: model.acceptedCount,
            correctedCount: model.correctedCount,
            lowercaseOpeningCount: model.lowercaseOpeningCount,
            sentenceCaseOpeningCount: model.sentenceCaseOpeningCount,
            greetingCount: model.greetingCount,
            signoffCount: model.signoffCount,
            shortMessageCount: model.shortMessageCount,
            paragraphBreakCount: model.paragraphBreakCount,
            finalPunctuationCount: model.finalPunctuationCount,
            totalWords: model.totalWords,
            listMarkersStrippedCount: model.listMarkersStrippedCount,
            listMarkersKeptCount: model.listMarkersKeptCount,
            trailingPunctuationStrippedCount: model.trailingPunctuationStrippedCount,
            autoSentSampleCount: model.autoSentSampleCount,
            autoSentGreetingCount: model.autoSentGreetingCount,
            autoSentSignoffCount: model.autoSentSignoffCount,
            autoSentShortMessageCount: model.autoSentShortMessageCount,
            autoSentParagraphBreakCount: model.autoSentParagraphBreakCount,
            directLowercaseOpeningCount: model.directLowercaseOpeningCount,
            directSentenceCaseOpeningCount: model.directSentenceCaseOpeningCount,
            directListOmissionCount: model.directListOmissionCount,
            directListRequirementCount: model.directListRequirementCount,
            directTrailingPeriodOmissionCount: model.directTrailingPeriodOmissionCount,
            directTrailingPeriodRequirementCount: model.directTrailingPeriodRequirementCount,
            appliedPolicyConfirmationCount: model.appliedPolicyConfirmationCount,
            authoredHabitSampleCount: model.authoredHabitSampleCount,
            authoredGreetingCount: model.authoredGreetingCount,
            authoredSignoffCount: model.authoredSignoffCount,
            authoredShortMessageCount: model.authoredShortMessageCount,
            authoredParagraphBreakCount: model.authoredParagraphBreakCount,
            rawTranscriptHabitSampleCount: model.rawTranscriptHabitSampleCount,
            rawTranscriptGreetingCount: model.rawTranscriptGreetingCount,
            rawTranscriptSignoffCount: model.rawTranscriptSignoffCount,
            rawTranscriptShortMessageCount: model.rawTranscriptShortMessageCount,
            rawTranscriptParagraphBreakCount: model.rawTranscriptParagraphBreakCount,
            createdAt: model.createdAt,
            lastSeenAt: model.lastSeenAt
        )
    }

    private nonisolated static func model(from record: StyleRecord) -> LearnedStyleProfile {
        LearnedStyleProfile(
            id: record.id,
            scopeKey: record.scopeKey,
            surfaceKind: record.surfaceKind.rawValue,
            appScope: record.appScope,
            siteScope: record.siteScope,
            projectScope: record.projectScope,
            sampleCount: record.sampleCount,
            acceptedCount: record.acceptedCount,
            correctedCount: record.correctedCount,
            lowercaseOpeningCount: record.lowercaseOpeningCount,
            sentenceCaseOpeningCount: record.sentenceCaseOpeningCount,
            greetingCount: record.greetingCount,
            signoffCount: record.signoffCount,
            shortMessageCount: record.shortMessageCount,
            paragraphBreakCount: record.paragraphBreakCount,
            finalPunctuationCount: record.finalPunctuationCount,
            totalWords: record.totalWords,
            listMarkersStrippedCount: record.listMarkersStrippedCount,
            listMarkersKeptCount: record.listMarkersKeptCount,
            trailingPunctuationStrippedCount: record.trailingPunctuationStrippedCount,
            autoSentSampleCount: record.autoSentSampleCount,
            autoSentGreetingCount: record.autoSentGreetingCount,
            autoSentSignoffCount: record.autoSentSignoffCount,
            autoSentShortMessageCount: record.autoSentShortMessageCount,
            autoSentParagraphBreakCount: record.autoSentParagraphBreakCount,
            directLowercaseOpeningCount: record.directLowercaseOpeningCount,
            directSentenceCaseOpeningCount: record.directSentenceCaseOpeningCount,
            directListOmissionCount: record.directListOmissionCount,
            directListRequirementCount: record.directListRequirementCount,
            directTrailingPeriodOmissionCount: record.directTrailingPeriodOmissionCount,
            directTrailingPeriodRequirementCount: record.directTrailingPeriodRequirementCount,
            appliedPolicyConfirmationCount: record.appliedPolicyConfirmationCount,
            authoredHabitSampleCount: record.authoredHabitSampleCount,
            authoredGreetingCount: record.authoredGreetingCount,
            authoredSignoffCount: record.authoredSignoffCount,
            authoredShortMessageCount: record.authoredShortMessageCount,
            authoredParagraphBreakCount: record.authoredParagraphBreakCount,
            rawTranscriptHabitSampleCount: record.rawTranscriptHabitSampleCount,
            rawTranscriptGreetingCount: record.rawTranscriptGreetingCount,
            rawTranscriptSignoffCount: record.rawTranscriptSignoffCount,
            rawTranscriptShortMessageCount: record.rawTranscriptShortMessageCount,
            rawTranscriptParagraphBreakCount: record.rawTranscriptParagraphBreakCount,
            createdAt: record.createdAt,
            lastSeenAt: record.lastSeenAt
        )
    }

    private nonisolated static func apply(_ record: StyleRecord, to model: LearnedStyleProfile) {
        model.scopeKey = record.scopeKey
        model.surfaceKind = record.surfaceKind.rawValue
        model.appScope = record.appScope
        model.siteScope = record.siteScope
        model.projectScope = record.projectScope
        model.sampleCount = record.sampleCount
        model.acceptedCount = record.acceptedCount
        model.correctedCount = record.correctedCount
        model.lowercaseOpeningCount = record.lowercaseOpeningCount
        model.sentenceCaseOpeningCount = record.sentenceCaseOpeningCount
        model.greetingCount = record.greetingCount
        model.signoffCount = record.signoffCount
        model.shortMessageCount = record.shortMessageCount
        model.paragraphBreakCount = record.paragraphBreakCount
        model.finalPunctuationCount = record.finalPunctuationCount
        model.totalWords = record.totalWords
        model.listMarkersStrippedCount = record.listMarkersStrippedCount
        model.listMarkersKeptCount = record.listMarkersKeptCount
        model.trailingPunctuationStrippedCount = record.trailingPunctuationStrippedCount
        model.autoSentSampleCount = record.autoSentSampleCount
        model.autoSentGreetingCount = record.autoSentGreetingCount
        model.autoSentSignoffCount = record.autoSentSignoffCount
        model.autoSentShortMessageCount = record.autoSentShortMessageCount
        model.autoSentParagraphBreakCount = record.autoSentParagraphBreakCount
        model.directLowercaseOpeningCount = record.directLowercaseOpeningCount
        model.directSentenceCaseOpeningCount = record.directSentenceCaseOpeningCount
        model.directListOmissionCount = record.directListOmissionCount
        model.directListRequirementCount = record.directListRequirementCount
        model.directTrailingPeriodOmissionCount = record.directTrailingPeriodOmissionCount
        model.directTrailingPeriodRequirementCount = record.directTrailingPeriodRequirementCount
        model.appliedPolicyConfirmationCount = record.appliedPolicyConfirmationCount
        model.authoredHabitSampleCount = record.authoredHabitSampleCount
        model.authoredGreetingCount = record.authoredGreetingCount
        model.authoredSignoffCount = record.authoredSignoffCount
        model.authoredShortMessageCount = record.authoredShortMessageCount
        model.authoredParagraphBreakCount = record.authoredParagraphBreakCount
        model.rawTranscriptHabitSampleCount = record.rawTranscriptHabitSampleCount
        model.rawTranscriptGreetingCount = record.rawTranscriptGreetingCount
        model.rawTranscriptSignoffCount = record.rawTranscriptSignoffCount
        model.rawTranscriptShortMessageCount = record.rawTranscriptShortMessageCount
        model.rawTranscriptParagraphBreakCount = record.rawTranscriptParagraphBreakCount
        model.createdAt = record.createdAt
        model.lastSeenAt = record.lastSeenAt
    }

    private nonisolated static func record(from model: LearnedFormatPreference) -> FormatPreferenceRecord? {
        guard let category = FormatCorrectionCategory(rawValue: model.categoryRaw) else { return nil }
        return FormatPreferenceRecord(
            id: model.id,
            category: category,
            scopeKey: model.scopeKey,
            preferredValue: model.preferredValue,
            positiveCount: model.positiveCount,
            negativeCount: model.negativeCount,
            confidence: model.confidence,
            isSuppressed: model.isSuppressed,
            suppressionReconciliationVersion: model.suppressionReconciliationVersion,
            createdAt: model.createdAt,
            lastSeenAt: model.lastSeenAt
        )
    }

    private nonisolated static func model(from record: FormatPreferenceRecord) -> LearnedFormatPreference {
        LearnedFormatPreference(
            id: record.id,
            categoryRaw: record.category.rawValue,
            scopeKey: record.scopeKey,
            preferredValue: record.preferredValue,
            positiveCount: record.positiveCount,
            negativeCount: record.negativeCount,
            confidence: record.confidence,
            isSuppressed: record.isSuppressed,
            suppressionReconciliationVersion: record.suppressionReconciliationVersion,
            createdAt: record.createdAt,
            lastSeenAt: record.lastSeenAt
        )
    }

    private nonisolated static func apply(_ record: FormatPreferenceRecord, to model: LearnedFormatPreference) {
        model.categoryRaw = record.category.rawValue
        model.scopeKey = record.scopeKey
        model.preferredValue = record.preferredValue
        model.positiveCount = record.positiveCount
        model.negativeCount = record.negativeCount
        model.confidence = record.confidence
        model.isSuppressed = record.isSuppressed
        model.suppressionReconciliationVersion = record.suppressionReconciliationVersion
        model.createdAt = record.createdAt
        model.lastSeenAt = record.lastSeenAt
    }

    private nonisolated static func model(from event: DictationCorrectionEventSnapshot) -> DictationCorrectionEvent {
        let correctionsJSON: String?
        if event.corrections.isEmpty {
            correctionsJSON = nil
        } else if let data = try? JSONEncoder().encode(event.corrections) {
            correctionsJSON = String(data: data, encoding: .utf8)
        } else {
            correctionsJSON = nil
        }

        return DictationCorrectionEvent(
            id: event.id,
            timestamp: event.timestamp,
            appName: event.appName,
            bundleId: event.bundleId,
            windowTitle: event.windowTitle,
            browserURL: event.browserURL,
            surfaceKind: event.surfaceKind,
            rawTranscriptPreview: event.rawTranscriptPreview,
            pastedTextPreview: event.pastedTextPreview,
            editedTextPreview: event.editedTextPreview,
            correctionsJSON: correctionsJSON,
            hadCorrection: event.hadCorrection
        )
    }

    private nonisolated static func correctionEventSummary(
        from model: DictationCorrectionEvent
    ) -> PersonalizationCorrectionEventSummary {
        PersonalizationCorrectionEventSummary(
            id: model.id,
            timestamp: model.timestamp,
            appName: model.appName,
            surfaceKind: model.surfaceKind,
            hadCorrection: model.hadCorrection,
            correctionCount: model.corrections.count,
            rawTranscriptPreview: preview(model.rawTranscriptPreview, limit: 240),
            pastedTextPreview: preview(model.pastedTextPreview, limit: 240) ?? "",
            editedTextPreview: preview(model.editedTextPreview, limit: 240) ?? ""
        )
    }

    private nonisolated static func evaluationInput(
        from model: DictationCorrectionEvent
    ) -> PersonalizationEvaluationInput {
        PersonalizationEvaluationInput(
            id: model.id,
            timestamp: model.timestamp,
            appName: model.appName,
            surfaceKind: model.surfaceKind,
            pastedText: model.pastedTextPreview,
            editedText: model.editedTextPreview,
            corrections: model.corrections,
            hadCorrection: model.hadCorrection
        )
    }

    private nonisolated static func entityEligibility(
        from record: EntityRecord,
        scopeMatches: Bool
    ) -> PersonalizationEntityEligibilityState {
        PersonalizationConsumerStateResolver.entityEligibility(
            type: record.type,
            value: record.value,
            confidence: record.confidence,
            positiveCount: record.positiveCount,
            isUserPinned: record.isUserPinned,
            isSuppressed: record.isSuppressed,
            scopeMatches: scopeMatches
        )
    }

    private nonisolated static func formatEligibility(
        from record: FormatPreferenceRecord
    ) -> PersonalizationFormatEligibilityState {
        PersonalizationConsumerStateResolver.formatEligibility(
            confidence: record.confidence,
            positiveCount: record.positiveCount,
            isSuppressed: record.isSuppressed
        )
    }

    private nonisolated static func entityConsumerCounts(
        from summaries: [PersonalizationEntitySummary]
    ) -> PersonalizationEntityConsumerCounts {
        var counts = PersonalizationEntityConsumerCounts.zero
        for summary in summaries {
            switch summary.eligibility {
            case .learning: counts.learningCandidates += 1
            case .promptEligible: counts.promptEligible += 1
            case .recognitionEligible:
                counts.recognitionEligible += 1
                if counts.recognizerAvailability == .notEligible {
                    counts.recognizerAvailability = summary.recognizerAvailability
                } else if counts.recognizerAvailability != summary.recognizerAvailability {
                    assertionFailure("Recognition rows were resolved from different runtime facts")
                }
            case .suppressed: counts.suppressed += 1
            }
        }
        return counts
    }

    private nonisolated static func formatConsumerCounts(
        from summaries: [PersonalizationFormatPreferenceSummary]
    ) -> PersonalizationFormatConsumerCounts {
        var counts = PersonalizationFormatConsumerCounts.zero
        for summary in summaries {
            switch summary.eligibility {
            case .learning: counts.learningCandidates += 1
            case .formatterEligible: counts.formatterEligible += 1
            case .suppressed: counts.suppressed += 1
            }
        }
        return counts
    }

    private nonisolated static func styleConsumerCounts(
        from summaries: [PersonalizationStyleSummary]
    ) -> PersonalizationStyleConsumerCounts {
        var counts = PersonalizationStyleConsumerCounts.zero
        for summary in summaries {
            let state = summary.consumerState
            if state.isLearning {
                counts.learningCandidates += 1
            } else {
                counts.eligibleWritingHabits += 1
            }
            if state.isLocalPolicyAvailable || state.isCloudStyleAvailable {
                counts.availableWritingHabits += 1
            }
            if state.isLocalPolicyEligible {
                counts.localPolicyEligible += 1
            }
            if state.isLocalPolicyAvailable {
                counts.localPolicyAvailable += 1
            }
            counts.localPolicyVetoedFamilies += state.localPolicyVetoedFamilyCount
            counts.localPolicyUnknownFamilies += state.localPolicyUnknownFamilyCount
            if state.isCloudStyleEligible {
                counts.cloudStyleEligible += 1
                if state.isCloudStyleAvailable {
                    counts.cloudStyleAvailable += 1
                } else {
                    counts.cloudStyleUnavailable += 1
                }
            }
        }
        return counts
    }

    private nonisolated static func styleEvidenceCount(from record: StyleRecord) -> Int {
        record.authoredHabitSampleCount + record.rawTranscriptHabitSampleCount
    }

    private nonisolated static func entitySummary(
        from record: EntityRecord,
        runtime: PersonalizationConsumerRuntimeContext
    ) -> PersonalizationEntitySummary {
        let eligibility = entityEligibility(from: record, scopeMatches: true)
        return PersonalizationEntitySummary(
            id: record.id,
            value: record.value,
            type: record.type.rawValue,
            scope: scopeLabel(
                surfaceKind: record.surfaceKind,
                appScope: record.appScope,
                siteScope: record.siteScope,
                projectScope: record.projectScope
            ),
            confidence: record.confidence,
            positiveCount: record.positiveCount,
            negativeCount: record.negativeCount,
            isUserPinned: record.isUserPinned,
            isSuppressed: record.isSuppressed,
            eligibility: eligibility,
            recognizerAvailability: PersonalizationConsumerStateResolver
                .recognizerAvailability(
                    eligibility: eligibility,
                    runtime: runtime.vocabularyBoost
                ),
            source: record.source.rawValue,
            lastSeenAt: record.lastSeenAt
        )
    }

    private nonisolated static func styleSummary(
        from record: StyleRecord,
        runtime: PersonalizationConsumerRuntimeContext
    ) -> PersonalizationStyleSummary {
        let hint = styleHint(from: record, surfaceKind: record.surfaceKind)
        return PersonalizationStyleSummary(
            id: record.id,
            scope: scopeLabel(
                surfaceKind: record.surfaceKind.rawValue,
                appScope: record.appScope,
                siteScope: record.siteScope,
                projectScope: record.projectScope
            ),
            evidenceCount: styleEvidenceCount(from: record),
            consumerState: PersonalizationConsumerStateResolver.styleState(
                policy: stylePolicy(from: record),
                cloudStyleHint: hint,
                runtime: runtime
            ),
            summary: hint ?? "Collecting writing-habit evidence.",
            lastSeenAt: record.lastSeenAt
        )
    }

    private nonisolated static func formatPreferenceSummary(
        from record: FormatPreferenceRecord
    ) -> PersonalizationFormatPreferenceSummary {
        PersonalizationFormatPreferenceSummary(
            id: record.id,
            category: record.category.rawValue,
            scope: record.scopeKey,
            preferredValue: record.preferredValue,
            confidence: record.confidence,
            positiveCount: record.positiveCount,
            negativeCount: record.negativeCount,
            isSuppressed: record.isSuppressed,
            eligibility: formatEligibility(from: record),
            lastSeenAt: record.lastSeenAt
        )
    }

    private nonisolated static func scopeLabel(
        surfaceKind: String?,
        appScope: String?,
        siteScope: String?,
        projectScope: String?
    ) -> String {
        [
            surfaceKind,
            siteScope.map { "site:\($0)" },
            appScope.map { "app:\($0)" },
            projectScope.map { "project:\($0)" },
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: " / ")
    }

    // MARK: - Helpers

    private func auditWarnings(entityCount: Int, correctionEventCount: Int) -> [String] {
        var warnings: [String] = []
        if dataStore == nil {
            warnings.append("Persistent store is not attached.")
        }
        if entityCount > 2_000 {
            warnings.append("Learned entity count is high; pruning should run before shipping this broadly.")
        }
        if correctionEventCount > 5_000 {
            warnings.append("Correction event history is large; verify retention is working.")
        }
        return warnings
    }

    private func suppressReversedCorrection(spokenKey: String, writtenKey: String) -> Bool {
        for (key, var record) in entitiesByKey {
            let aliasKeys = Set(record.aliases.map(Self.normalizedKey))
            guard record.normalizedValue == spokenKey, aliasKeys.contains(writtenKey) else { continue }
            record.negativeCount += 1
            record.confidence = max(0.10, record.confidence - 0.22)
            record.isSuppressed = record.negativeCount >= record.positiveCount
            record.lastSeenAt = Date()
            entitiesByKey[key] = record
            dirtyEntityIDs.insert(record.id)
            return true
        }
        return false
    }

    private func demoteConflictingOutput(
        spokenKey: String,
        writtenKey: String,
        surface: SurfaceDescriptor
    ) {
        guard spokenKey != writtenKey else { return }

        for (key, var record) in entitiesByKey {
            guard record.normalizedValue == spokenKey else { continue }
            guard matchesScope(record, surface: surface) else { continue }

            record.negativeCount += 1
            record.confidence = max(0.10, record.confidence - 0.18)
            record.isSuppressed = record.negativeCount >= record.positiveCount
            record.lastSeenAt = Date()
            entitiesByKey[key] = record
            dirtyEntityIDs.insert(record.id)
        }
    }

    private func matchesScope(_ record: EntityRecord, surface: SurfaceDescriptor) -> Bool {
        if let surfaceKind = record.surfaceKind, !surfaceKind.isEmpty, surfaceKind != surface.kind.rawValue {
            return false
        }
        if let appScope = record.appScope, !appScope.isEmpty {
            guard let bundleId = surface.bundleId?.lowercased(),
                  appScope.lowercased() == bundleId
            else { return false }
        }
        if let siteScope = record.siteScope, !siteScope.isEmpty {
            guard let siteHost = surface.siteHost?.lowercased(),
                  siteScope.lowercased() == siteHost
            else { return false }
        }
        if let projectScope = record.projectScope, !projectScope.isEmpty {
            guard let surfaceProject = surface.projectLabel?.lowercased(),
                  projectScope.lowercased() == surfaceProject
            else { return false }
        }
        return true
    }

    private nonisolated static func entityKey(for record: EntityRecord) -> String {
        entityKey(
            type: record.type,
            normalizedValue: record.normalizedValue,
            surfaceKind: record.surfaceKind,
            appScope: record.appScope,
            siteScope: record.siteScope,
            projectScope: record.projectScope
        )
    }

    private nonisolated static func styleKey(for surface: SurfaceDescriptor) -> String {
        let scope = scope(for: surface)
        return [
            surface.kind.rawValue,
            scope.app ?? "",
            scope.site ?? "",
            surface.projectLabel ?? "",
        ].joined(separator: "|").lowercased()
    }

    private nonisolated static func scope(for surface: SurfaceDescriptor) -> (app: String?, site: String?) {
        let site = normalizedOptional(surface.siteHost)
        return (
            site == nil ? normalizedOptional(surface.bundleId) : nil,
            site
        )
    }

    private nonisolated static func normalizedOptional(_ value: String?) -> String? {
        let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let normalized, !normalized.isEmpty else { return nil }
        return normalized
    }

    private nonisolated static func entityType(for value: String, surface: SurfaceDescriptor) -> ContextEntityType {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(of: #"^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return .emailAddress
        }
        if trimmed.hasPrefix("@") { return .personHandle }
        if trimmed.hasPrefix("#") { return .chatChannel }
        if trimmed.range(of: #"^[A-Z][A-Z0-9]+-\d+$"#, options: .regularExpression) != nil {
            return .ticketID
        }
        if trimmed.range(of: #"[\w.-]+\.(swift|ts|tsx|js|jsx|py|go|rs|java|kt|cpp|c|h|cs|vue|rb|json|md|yml|yaml|toml|sql|html|css)$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return trimmed.contains("/") ? .filePath : .fileName
        }
        if surface.kind == .code,
           trimmed.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil {
            return .codeSymbol
        }
        if trimmed.range(of: #"^[A-Z][a-z]+(?:\s+[A-Z][a-z]+){1,3}$"#, options: .regularExpression) != nil {
            return .personName
        }
        return .customTerm
    }

    private nonisolated static func initialConfidence(type: ContextEntityType, spokenIsRealWord: Bool) -> Double {
        var confidence: Double = switch type {
        case .personName, .personHandle, .emailAddress, .fileName, .filePath, .ticketID:
            0.76
        case .codeSymbol, .repoName, .customTerm:
            0.64
        default:
            0.68
        }
        if spokenIsRealWord { confidence -= 0.08 }
        return confidence
    }

    /// Screen sightings start below correction-learned confidence: two
    /// confirmed uses take a person name across the recognition-bias
    /// threshold (0.7 / positiveCount 2), custom terms take three.
    private nonisolated static func initialScreenSightingConfidence(type: ContextEntityType) -> Double {
        type == .personName ? 0.64 : 0.56
    }

    /// Same key shape as `entityKey(for:)` (both call the shared core), built
    /// from a surface instead of a full record — used to probe for an
    /// existing record without creating one.
    private nonisolated static func entityKey(
        type: ContextEntityType,
        normalizedValue: String,
        surface: SurfaceDescriptor
    ) -> String {
        let scope = scope(for: surface)
        return entityKey(
            type: type,
            normalizedValue: normalizedValue,
            surfaceKind: surface.kind.rawValue,
            appScope: scope.app,
            siteScope: scope.site,
            projectScope: surface.projectLabel
        )
    }

    private nonisolated static func entityKey(
        type: ContextEntityType,
        normalizedValue: String,
        surfaceKind: String?,
        appScope: String?,
        siteScope: String?,
        projectScope: String?
    ) -> String {
        [
            type.rawValue,
            normalizedValue,
            surfaceKind ?? "",
            appScope ?? "",
            siteScope ?? "",
            projectScope ?? "",
        ].joined(separator: "|").lowercased()
    }

    /// Case-sensitive whole-word containment — the exact written form must
    /// survive with no letter or digit running into it on either side.
    nonisolated static func containsWholeTerm(_ term: String, in text: String) -> Bool {
        guard !term.isEmpty, !text.isEmpty else { return false }
        let pattern = "(?<![A-Za-z0-9])"
            + NSRegularExpression.escapedPattern(for: term)
            + "(?![A-Za-z0-9])"
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    private nonisolated static func updatedConfidence(
        current: Double,
        positiveCount: Int,
        negativeCount: Int,
        type: ContextEntityType
    ) -> Double {
        let base = max(current, initialConfidence(type: type, spokenIsRealWord: false))
        let positiveBoost = min(Double(positiveCount - 1) * 0.05, 0.22)
        let negativePenalty = min(Double(negativeCount) * 0.10, 0.35)
        return min(max(base + positiveBoost - negativePenalty, 0.10), 0.96)
    }

    private nonisolated static func spokenForms(
        for value: String,
        type: ContextEntityType,
        aliases: [String]
    ) -> [String] {
        var forms = ContextEntityExtractor.spokenForms(for: value, type: type)
        for alias in aliases {
            forms.append(Self.normalizedKey(alias))
        }
        return Array(Set(forms))
            .filter { $0.count >= 3 }
            .sorted { $0.count > $1.count }
    }

    private nonisolated static func trimCorrectionTerm(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let leadingTrimSet = CharacterSet.punctuationCharacters
            .subtracting(CharacterSet(charactersIn: "@#._/"))
        let trailingTrimSet = CharacterSet.punctuationCharacters
            .subtracting(CharacterSet(charactersIn: "_-"))

        while let scalar = trimmed.unicodeScalars.first,
              leadingTrimSet.contains(scalar) {
            trimmed.removeFirst()
        }
        while let scalar = trimmed.unicodeScalars.last,
              trailingTrimSet.contains(scalar) {
            trimmed.removeLast()
        }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func normalizedKey(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9@#._/\-]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func merged(_ existing: [String], with newValues: [String], limit: Int) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in existing + newValues {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard seen.insert(trimmed.lowercased()).inserted else { continue }
            result.append(trimmed)
            if result.count >= limit { break }
        }
        return result
    }

    private nonisolated static func styleFeatures(in text: String) -> (
        wordCount: Int,
        lowercaseOpening: Bool,
        sentenceCaseOpening: Bool,
        hasGreeting: Bool,
        hasSignoff: Bool,
        isShortMessage: Bool,
        hasParagraphBreak: Bool,
        hasFinalPunctuation: Bool
    ) {
        let words = text.split { $0.isWhitespace || $0.isNewline }
        let firstLetter = text.first(where: { $0.isLetter })
        let lower = text.lowercased()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastLine = trimmed
            .split(whereSeparator: \.isNewline)
            .last
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? ""

        return (
            wordCount: words.count,
            lowercaseOpening: firstLetter?.isLowercase == true,
            sentenceCaseOpening: firstLetter?.isUppercase == true,
            hasGreeting: lower.range(of: #"^(hi|hey|hello|dear)\b"#, options: .regularExpression) != nil,
            hasSignoff: ["thanks", "thank you", "best", "best regards", "regards", "cheers"].contains(lastLine.trimmingCharacters(in: .punctuationCharacters)),
            isShortMessage: words.count <= 12,
            hasParagraphBreak: text.contains("\n\n") || text.contains("\r\n\r\n"),
            hasFinalPunctuation: trimmed.last.map { ".!?".contains($0) } == true
        )
    }

    private nonisolated static func preview(_ value: String?, limit: Int = 2_000) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(limit))
    }
}
