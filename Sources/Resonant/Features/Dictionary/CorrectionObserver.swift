import AppKit
import CryptoKit
import Foundation
import os

/// Background-extracted correction snapshot. The legacy content-only method
/// remains solely so older callers compile; safe correction readback uses only
/// `correctionHotSnapshot(for:)` and fails closed when it is unavailable.
@MainActor
protocol AmbientFieldContentProviding: AnyObject {
    func correctionHotSnapshot(for app: NSRunningApplication?) async -> CorrectionHotSnapshot?
    func currentFieldContent(for app: NSRunningApplication?) async -> String?
}

extension AmbientFieldContentProviding {
    func correctionHotSnapshot(for app: NSRunningApplication?) async -> CorrectionHotSnapshot? {
        nil
    }

    func currentFieldContent(for app: NSRunningApplication?) async -> String? {
        await correctionHotSnapshot(for: app)?.fullFieldContent
    }
}

/// Observes text fields after a paste to detect user corrections and feed them
/// into the auto-learn dictionary.
///
/// Flow: paste → wait for user edits → read back field content → diff → learn.
@MainActor
final class CorrectionObserver {

    private let log = Logger.resonant("CorrectionObserver")

    typealias QualityRecorder = @MainActor (
        DictationQualityTrace?,
        DictationQualityReadbackStatus,
        String?,
        String?,
        Int?,
        Int?
    ) -> Void
    typealias ReceiptReadback = @MainActor (
        PasteManager.DeliveryReceipt
    ) -> CorrectionReceiptSnapshot?
    /// Receives ground-truth signals mined from a post-paste edit against the
    /// dictation's vocabulary-boost audit (counts only — never terms).
    typealias BoostCorrelationRecorder = @MainActor (VocabularyBoostAudit.CorrectionSignals) -> Void
    /// Persists the terminal outcome and returns whether this exact attempt won
    /// the authoritative transition. Correction-derived quality and learning
    /// are admitted only by `.finalized`.
    typealias OutcomeRecorder = @MainActor (
        CorrectionObservationOutcome
    ) async -> PersonalizationOutcomeFinalizationResult

    private let dictionaryStore: DictionaryStore
    private let pasteManager: PasteManager
    private let personalizationLearningEngine: PersonalizationLearningEngine?
    private let qualityRecorder: QualityRecorder
    private let receiptReadback: ReceiptReadback
    private let boostCorrelationRecorder: BoostCorrelationRecorder
    private let outcomeRecorder: OutcomeRecorder

    /// Readback fallback for Electron/web targets (set at app wiring time).
    weak var ambientFieldContentProvider: (any AmbientFieldContentProviding)?

    /// Seam for a format-correction consumer (wired by the orchestrator). Invoked
    /// once per completed observation where the edited text differs from the pasted
    /// text, BEFORE any word-level diff filtering, with (pastedText, editedText, context).
    var formatCorrectionSink: ((String, String, CorrectionObservationContext) -> Void)?

    /// Seam for near-miss learn candidates that are too uncertain to auto-apply
    /// (wired by the orchestrator to the "Learn this word?" prompt).
    var learnSuggestionSink: ((CorrectionDiffEngine.Candidate) -> Void)?

    /// Digest-only samples spread across the observation window. Frequent full
    /// AX reads can stall large web editors, so the budget stays small.
    private static let provisionalSampleBudget = 4

    private struct ProvisionalSampleState {
        let observationID: UUID
        var latestDigest: Data
        var editObserved: Bool
    }

    /// Ownership proof for evaluating a changed region isolated by a receipt.
    /// Temporal stability is deliberately absent: a digest can prove that a
    /// field stopped changing, but never that text at an open edge belongs to
    /// the delivered region.
    enum ReceiptRegionOwnership: Equatable {
        case closedBoundaries
        case explicitlyOwnedWholeField
        case weakOpenBoundary

        var authorizesChangedRegion: Bool {
            self != .weakOpenBoundary
        }
    }

    nonisolated static let defaultMaximumObservationAge: TimeInterval = 120

    private let readbackDelay: Duration
    private let maximumObservationAge: TimeInterval
    private var pendingObservation: PendingObservation?
    private var readbackTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var provisionalSample: ProvisionalSampleState?
    /// Main-actor isolation prevents memory races, but async observation entry
    /// points are still reentrant. This generation makes arrival order explicit:
    /// only the newest admission may install timer/task ownership.
    private var observationAdmissionGeneration: UInt64 = 0
    private var activeObservationAdmissionCount = 0
    private var observationAdmissionDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private var observationAdmissionDrainRegistrationWaitersForTesting: [
        CheckedContinuation<Void, Never>
    ] = []
    /// A next-dictation flush relinquishes timer ownership before its terminal
    /// read. Track the whole coroutine so cancellation of an external task
    /// handle cannot make that pre-terminal work invisible to workspace clear.
    private var activeObservationFlushCount = 0
    private var observationFlushDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private var observationFlushDrainRegistrationWaitersForTesting: [
        CheckedContinuation<Void, Never>
    ] = []
    private var activeTerminalProcessingCount = 0
    private var terminalProcessingDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private var terminalDrainRegistrationWaitersForTesting: [CheckedContinuation<Void, Never>] = []

    struct PendingObservation {
        let id: UUID
        let deliveryAttemptID: UUID
        let effectiveInsertedText: String?
        let targetObservedSettledText: String?
        let settledBaseline: String
        let deliveryAttribution: PasteManager.DeliveryAttribution?
        let targetApp: NSRunningApplication?
        let windowTitle: String?
        let browserURL: String?
        let rawTranscript: String?
        let contextPacket: ContextPacket?
        let qualityTrace: DictationQualityTrace?
        let deliveryReceipt: PasteManager.DeliveryReceipt?
        let boostAudit: VocabularyBoostAudit?
        let capabilities: LearningCapabilities
        let appliedStylePolicy: AppliedStylePolicy
        let readbackMethod: CorrectionReadbackMethod
        /// Legacy synchronous observations have no registered persisted attempt
        /// and are quality-only. Every delivery-backed async observation must
        /// receive an authoritative persisted-outcome acknowledgement.
        let requiresPersistedOutcomeFinalization: Bool
        let timestamp: Date

        var pastedText: String { settledBaseline }

        init(
            id: UUID = UUID(),
            deliveryAttemptID: UUID,
            effectiveInsertedText: String?,
            targetObservedSettledText: String?,
            settledBaseline: String,
            deliveryAttribution: PasteManager.DeliveryAttribution?,
            targetApp: NSRunningApplication?,
            windowTitle: String?,
            browserURL: String?,
            rawTranscript: String?,
            contextPacket: ContextPacket?,
            qualityTrace: DictationQualityTrace?,
            deliveryReceipt: PasteManager.DeliveryReceipt? = nil,
            boostAudit: VocabularyBoostAudit? = nil,
            capabilities: LearningCapabilities,
            appliedStylePolicy: AppliedStylePolicy,
            readbackMethod: CorrectionReadbackMethod,
            requiresPersistedOutcomeFinalization: Bool = true,
            timestamp: Date
        ) {
            self.id = id
            self.deliveryAttemptID = deliveryAttemptID
            self.effectiveInsertedText = effectiveInsertedText
            self.targetObservedSettledText = targetObservedSettledText
            self.settledBaseline = settledBaseline
            self.deliveryAttribution = deliveryAttribution
            self.targetApp = targetApp
            self.windowTitle = windowTitle
            self.browserURL = browserURL
            self.rawTranscript = rawTranscript
            self.contextPacket = contextPacket
            self.qualityTrace = qualityTrace
            self.deliveryReceipt = deliveryReceipt
            self.boostAudit = boostAudit
            self.capabilities = capabilities
            self.appliedStylePolicy = appliedStylePolicy
            self.readbackMethod = readbackMethod
            self.requiresPersistedOutcomeFinalization = requiresPersistedOutcomeFinalization
            self.timestamp = timestamp
        }

        /// Source-compatible construction for older tests/callers. Missing
        /// attribution and capability data explicitly means no mutation.
        init(
            id: UUID = UUID(),
            pastedText: String,
            targetApp: NSRunningApplication?,
            windowTitle: String?,
            browserURL: String?,
            rawTranscript: String?,
            contextPacket: ContextPacket?,
            qualityTrace: DictationQualityTrace?,
            deliveryReceipt: PasteManager.DeliveryReceipt? = nil,
            boostAudit: VocabularyBoostAudit? = nil,
            timestamp: Date
        ) {
            self.init(
                id: id,
                deliveryAttemptID: UUID(),
                effectiveInsertedText: pastedText,
                targetObservedSettledText: deliveryReceipt?.targetObservedInsertedText,
                settledBaseline: deliveryReceipt?.targetObservedInsertedText ?? pastedText,
                deliveryAttribution: nil,
                targetApp: targetApp,
                windowTitle: windowTitle,
                browserURL: browserURL,
                rawTranscript: rawTranscript,
                contextPacket: contextPacket,
                qualityTrace: qualityTrace,
                deliveryReceipt: deliveryReceipt,
                boostAudit: boostAudit,
                capabilities: .none,
                appliedStylePolicy: .none,
                readbackMethod: deliveryReceipt == nil ? .none : .receipt,
                requiresPersistedOutcomeFinalization: false,
                timestamp: timestamp
            )
        }
    }

    init(
        dictionaryStore: DictionaryStore,
        pasteManager: PasteManager,
        personalizationLearningEngine: PersonalizationLearningEngine? = nil,
        readbackDelay: Duration = .seconds(5),
        maximumObservationAge: TimeInterval = defaultMaximumObservationAge,
        receiptReadback: ReceiptReadback? = nil,
        qualityRecorder: @escaping QualityRecorder = { trace, status, pastedText, editedText, correctionCount, observationAgeMs in
            DictationQualityPipeline.recordReadback(
                trace: trace,
                status: status,
                pastedText: pastedText,
                editedText: editedText,
                correctionCount: correctionCount,
                observationAgeMs: observationAgeMs
            )
        },
        boostCorrelationRecorder: @escaping BoostCorrelationRecorder = {
            VocabularyBoostCorrelationRecorder.record($0)
        },
        outcomeRecorder: @escaping OutcomeRecorder = { _ in .persistenceUnavailable }
    ) {
        self.dictionaryStore = dictionaryStore
        self.pasteManager = pasteManager
        self.personalizationLearningEngine = personalizationLearningEngine
        self.readbackDelay = readbackDelay
        self.maximumObservationAge = maximumObservationAge
        self.receiptReadback = receiptReadback ?? { receipt in
            pasteManager.exactReceiptSnapshot(for: receipt)
        }
        self.qualityRecorder = qualityRecorder
        self.boostCorrelationRecorder = boostCorrelationRecorder
        self.outcomeRecorder = outcomeRecorder
    }

    /// Call after a successful paste to begin observing for user corrections.
    /// Only observes when text was actually pasted (not just copied or auto-sent).
    func observe(
        pastedText: String,
        targetApp: NSRunningApplication?,
        windowTitle: String? = nil,
        browserURL: String? = nil,
        rawTranscript: String? = nil,
        contextPacket: ContextPacket? = nil,
        qualityTrace: DictationQualityTrace? = nil
    ) {
        let admissionGeneration = advanceObservationAdmissionGeneration()
        beginCompatibilityObservation(PendingObservation(
            deliveryAttemptID: UUID(),
            effectiveInsertedText: pastedText,
            targetObservedSettledText: nil,
            settledBaseline: pastedText,
            deliveryAttribution: nil,
            targetApp: targetApp,
            windowTitle: windowTitle,
            browserURL: browserURL,
            rawTranscript: rawTranscript,
            contextPacket: contextPacket,
            qualityTrace: qualityTrace,
            capabilities: .none,
            appliedStylePolicy: .none,
            readbackMethod: .none,
            requiresPersistedOutcomeFinalization: false,
            timestamp: Date()
        ), admissionGeneration: admissionGeneration)
    }

    /// Starts an observation from delivery evidence captured on one retained
    /// AX element. The target-observed text, not the pre-delivery source string,
    /// becomes the learning baseline.
    func observe(
        deliveryReceipt: PasteManager.DeliveryReceipt,
        deliveryAttribution: PasteManager.DeliveryAttribution?,
        deliveryAttemptID: UUID,
        capabilities: LearningCapabilities,
        effectiveInsertedText: String? = nil,
        windowTitle: String? = nil,
        browserURL: String? = nil,
        rawTranscript: String? = nil,
        contextPacket: ContextPacket? = nil,
        qualityTrace: DictationQualityTrace? = nil,
        boostAudit: VocabularyBoostAudit? = nil,
        appliedStylePolicy: AppliedStylePolicy
    ) async {
        let admissionGeneration = beginTrackedObservationAdmission()
        defer { endTrackedObservationAdmission() }

        let admissionFailure = Self.receiptAdmissionFailure(
            receipt: deliveryReceipt,
            attribution: deliveryAttribution
        )
        let candidate = PendingObservation(
            deliveryAttemptID: deliveryAttemptID,
            effectiveInsertedText: effectiveInsertedText,
            targetObservedSettledText: deliveryReceipt.targetObservedInsertedText,
            settledBaseline: deliveryReceipt.targetObservedInsertedText,
            deliveryAttribution: deliveryAttribution,
            targetApp: NSRunningApplication(
                processIdentifier: deliveryReceipt.targetProcessIdentifier
            ),
            windowTitle: windowTitle,
            browserURL: browserURL,
            rawTranscript: rawTranscript,
            contextPacket: contextPacket,
            qualityTrace: qualityTrace,
            deliveryReceipt: deliveryReceipt,
            boostAudit: boostAudit,
            capabilities: admissionFailure == nil ? capabilities : .none,
            appliedStylePolicy: appliedStylePolicy,
            readbackMethod: .receipt,
            timestamp: Date()
        )

        // Replace any prior attempt before this newly admitted delivery reaches
        // a terminal decision. Identity validation still happens before the
        // first receipt poll, so sensitive/weak targets cannot enter timers.
        await finishPendingObservation(status: .observationReplaced)
        guard isCurrentObservationAdmission(admissionGeneration) else {
            await recordSupersededAdmission(candidate)
            return
        }
        if let admissionFailure {
            await recordObservation(
                candidate,
                status: admissionFailure,
                pastedText: nil,
                editedText: nil,
                correctionCount: nil
            )
            return
        }
        guard installObservation(
            candidate,
            admissionGeneration: admissionGeneration
        ) else {
            await recordSupersededAdmission(candidate)
            return
        }
    }

    /// Source-compatible receipt overload. It preserves readback/quality but
    /// deliberately authorizes no learning mutation.
    func observe(
        deliveryReceipt: PasteManager.DeliveryReceipt,
        deliveryAttribution: PasteManager.DeliveryAttribution? = nil,
        windowTitle: String? = nil,
        browserURL: String? = nil,
        rawTranscript: String? = nil,
        contextPacket: ContextPacket? = nil,
        qualityTrace: DictationQualityTrace? = nil,
        boostAudit: VocabularyBoostAudit? = nil
    ) {
        let admissionGeneration = advanceObservationAdmissionGeneration()
        beginCompatibilityObservation(PendingObservation(
            deliveryAttemptID: UUID(),
            effectiveInsertedText: nil,
            targetObservedSettledText: deliveryReceipt.targetObservedInsertedText,
            settledBaseline: deliveryReceipt.targetObservedInsertedText,
            deliveryAttribution: deliveryAttribution,
            targetApp: NSRunningApplication(
                processIdentifier: deliveryReceipt.targetProcessIdentifier
            ),
            windowTitle: windowTitle,
            browserURL: browserURL,
            rawTranscript: rawTranscript,
            contextPacket: contextPacket,
            qualityTrace: qualityTrace,
            deliveryReceipt: deliveryReceipt,
            boostAudit: boostAudit,
            capabilities: .none,
            appliedStylePolicy: .none,
            readbackMethod: .receipt,
            requiresPersistedOutcomeFinalization: false,
            timestamp: Date()
        ), admissionGeneration: admissionGeneration)
    }

    /// Starts the safe no-receipt path. The first correction snapshot must
    /// prove both target identity and the exact effective inserted region. Only
    /// then does the settled region enter the normal observation window.
    @discardableResult
    func observe(
        deliveryOutcome: PasteManager.DeliveryOutcome,
        targetApp: NSRunningApplication?,
        windowTitle: String? = nil,
        browserURL: String? = nil,
        rawTranscript: String? = nil,
        contextPacket: ContextPacket? = nil,
        qualityTrace: DictationQualityTrace? = nil,
        boostAudit: VocabularyBoostAudit? = nil,
        capabilities: LearningCapabilities,
        appliedStylePolicy: AppliedStylePolicy
    ) async -> Bool {
        let admissionGeneration = beginTrackedObservationAdmission()
        defer { endTrackedObservationAdmission() }
        let initialBaseline = deliveryOutcome.targetObservedSettledText
            ?? deliveryOutcome.effectiveInsertedText
            ?? ""
        let targetApp = targetApp ?? deliveryOutcome.targetProcessIdentifier.flatMap {
            NSRunningApplication(processIdentifier: $0)
        }
        let candidate = PendingObservation(
            deliveryAttemptID: deliveryOutcome.deliveryAttemptID,
            effectiveInsertedText: deliveryOutcome.effectiveInsertedText,
            targetObservedSettledText: deliveryOutcome.targetObservedSettledText,
            settledBaseline: initialBaseline,
            deliveryAttribution: deliveryOutcome.deliveryAttribution,
            targetApp: targetApp,
            windowTitle: windowTitle,
            browserURL: browserURL,
            rawTranscript: rawTranscript,
            contextPacket: contextPacket,
            qualityTrace: qualityTrace,
            boostAudit: boostAudit,
            capabilities: capabilities,
            appliedStylePolicy: appliedStylePolicy,
            readbackMethod: .correctionHotSnapshot,
            timestamp: Date()
        )

        await finishPendingObservation(status: .observationReplaced)
        guard isCurrentObservationAdmission(admissionGeneration) else {
            await recordSupersededAdmission(candidate)
            return false
        }

        guard deliveryOutcome.delivered,
              !deliveryOutcome.partiallyDelivered,
              deliveryOutcome.receipt == nil else {
            await recordObservation(
                candidate,
                status: .baselineUnavailable,
                pastedText: nil,
                editedText: nil,
                correctionCount: nil
            )
            return false
        }
        guard let attribution = deliveryOutcome.deliveryAttribution else {
            await recordObservation(
                candidate,
                status: .insufficientIdentity,
                pastedText: nil,
                editedText: nil,
                correctionCount: nil
            )
            return false
        }

        if let contextFingerprint = contextPacket?.targetFingerprint,
           let contextFailure = Self.contextTargetFailure(
                attribution: attribution,
                contextFingerprint: contextFingerprint
           ) {
            await recordObservation(
                candidate,
                status: contextFailure,
                pastedText: nil,
                editedText: nil,
                correctionCount: nil
            )
            return false
        }

        guard let snapshot = await ambientFieldContentProvider?.correctionHotSnapshot(
            for: targetApp
        ) else {
            guard isCurrentObservationAdmission(admissionGeneration) else {
                await recordSupersededAdmission(candidate)
                return false
            }
            await recordObservation(
                candidate,
                status: .baselineUnavailable,
                pastedText: nil,
                editedText: nil,
                correctionCount: nil
            )
            return false
        }
        guard isCurrentObservationAdmission(admissionGeneration) else {
            await recordSupersededAdmission(candidate)
            return false
        }
        if let targetFailure = Self.targetFailure(
            delivery: attribution.targetIdentity,
            observed: snapshot.targetIdentity
        ) {
            await recordObservation(
                candidate,
                status: targetFailure,
                pastedText: nil,
                editedText: nil,
                correctionCount: nil
            )
            return false
        }

        let settledBaseline: String
        switch CorrectionBaselineValidator.validate(
            effectiveInsertedText: deliveryOutcome.effectiveInsertedText,
            targetObservedSettledText: deliveryOutcome.targetObservedSettledText,
            snapshot: snapshot,
            attribution: attribution
        ) {
        case .settled(let value):
            settledBaseline = value
        case .baselineUnavailable:
            await recordObservation(
                candidate,
                status: .baselineUnavailable,
                pastedText: nil,
                editedText: nil,
                correctionCount: nil
            )
            return false
        case .regionUnattributable:
            await recordObservation(
                candidate,
                status: .regionUnattributable,
                pastedText: nil,
                editedText: nil,
                correctionCount: nil
            )
            return false
        case .targetNormalizedOrUnattributable:
            await recordObservation(
                candidate,
                status: .targetNormalizedOrUnattributable,
                pastedText: nil,
                editedText: nil,
                correctionCount: nil
            )
            return false
        }

        let settledCandidate = PendingObservation(
            id: candidate.id,
            deliveryAttemptID: candidate.deliveryAttemptID,
            effectiveInsertedText: candidate.effectiveInsertedText,
            targetObservedSettledText: candidate.targetObservedSettledText,
            settledBaseline: settledBaseline,
            deliveryAttribution: attribution,
            targetApp: candidate.targetApp,
            windowTitle: candidate.windowTitle,
            browserURL: candidate.browserURL,
            rawTranscript: candidate.rawTranscript,
            contextPacket: candidate.contextPacket,
            qualityTrace: candidate.qualityTrace,
            boostAudit: candidate.boostAudit,
            capabilities: candidate.capabilities,
            appliedStylePolicy: candidate.appliedStylePolicy,
            readbackMethod: .correctionHotSnapshot,
            timestamp: candidate.timestamp
        )
        guard installObservation(
            settledCandidate,
            admissionGeneration: admissionGeneration
        ) else {
            await recordSupersededAdmission(candidate)
            return false
        }
        return true
    }

    /// The source-compatible observe overloads cannot await an actor-backed
    /// outcome sink. They remain quality-only and fail closed for mutation;
    /// AppState integration must use the explicit async overloads.
    private func beginCompatibilityObservation(
        _ observation: PendingObservation,
        admissionGeneration: UInt64
    ) {
        finishCompatibilityObservation(status: .observationReplaced)
        _ = installObservation(
            observation,
            admissionGeneration: admissionGeneration
        )
    }

    @discardableResult
    private func installObservation(
        _ observation: PendingObservation,
        admissionGeneration: UInt64
    ) -> Bool {
        guard isCurrentObservationAdmission(admissionGeneration),
              pendingObservation == nil,
              readbackTask == nil,
              expiryTask == nil else {
            return false
        }
        pendingObservation = observation
        provisionalSample = nil
        readbackTask = Task { [weak self] in
            guard let self else { return }
            // Sparse digest-only samples across the window. Once an edit is
            // evident and the field has stayed stable for a full interval, the
            // observation finalizes early instead of waiting out the horizon,
            // so leisurely corrections still learn promptly.
            let firstDelaySeconds = Self.timeInterval(for: self.readbackDelay)
            let horizonSeconds = max(0, self.maximumObservationAge)
            let intervalSeconds = max(
                firstDelaySeconds,
                (horizonSeconds - firstDelaySeconds) / Double(Self.provisionalSampleBudget)
            )

            var elapsedSeconds = 0.0
            var nextDelaySeconds = firstDelaySeconds
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: Self.nanoseconds(nextDelaySeconds))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                elapsedSeconds += nextDelaySeconds
                let outcome = await self.recordProvisionalSample(observationID: observation.id)
                guard outcome == .continueSampling else { return }
                nextDelaySeconds = intervalSeconds
                // Leave the final stretch to the expiry task's verifying read.
                guard elapsedSeconds + nextDelaySeconds < horizonSeconds else { return }
            }
        }
        let expiryNanoseconds = Self.nanoseconds(maximumObservationAge)
        expiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: expiryNanoseconds)
            guard !Task.isCancelled else { return }
            await self?.expireObservation(id: observation.id)
        }
        return true
    }

    /// Called when a new dictation starts — triggers an immediate readback of any
    /// pending observation (the user is done editing the previous text).
    func flushBeforeDictation() async {
        beginTrackedObservationFlush()
        defer { endTrackedObservationFlush() }

        // A delivery still validating when a later dictation starts must not
        // install itself after this flush has already returned.
        _ = advanceObservationAdmissionGeneration()
        guard let observation = pendingObservation else { return }
        let hadProvisionalSample = provisionalSample?.observationID == observation.id
        readbackTask?.cancel()
        readbackTask = nil
        expiryTask?.cancel()
        expiryTask = nil
        pendingObservation = nil
        provisionalSample = nil
        guard hadProvisionalSample else {
            await processObservation(observation)
            return
        }

        let terminalRead = await readback(for: observation)
        guard let fieldContent = terminalRead.fieldContent, !fieldContent.isEmpty else {
            if Self.isTerminalAttributionFailure(terminalRead.failureStatus) {
                await recordObservation(
                    observation,
                    status: terminalRead.failureStatus,
                    pastedText: nil,
                    editedText: nil,
                    correctionCount: nil
                )
                return
            }
            await processObservation(observation)
            return
        }
        await processObservation(
            observation,
            verifiedFieldContent: fieldContent
        )
    }

    /// Cancel observation (e.g. app resigned active).
    func cancel() async {
        _ = advanceObservationAdmissionGeneration()
        await finishPendingObservation(status: .observationCancelled)
    }

    /// Cancels and joins every owned readback before destructive workspace
    /// operations proceed. A readback already inside personalization/dictionary
    /// persistence is allowed to finish, then the clear transaction removes it.
    func cancelAndWait() async {
        _ = advanceObservationAdmissionGeneration()
        let readback = readbackTask
        let expiry = expiryTask
        await finishPendingObservation(status: .observationCancelled)
        readback?.cancel()
        expiry?.cancel()
        await readback?.value
        await expiry?.value
        // Flushes and admissions are producers of terminal processing. Drain
        // those lifecycles first so neither can enter terminal work after the
        // terminal drain below has already returned.
        await waitForObservationFlushesToDrain()
        // In-flight async admissions may own neither timer yet (for example,
        // while awaiting a hot snapshot). Join them before the destructive clear
        // boundary so their fail-closed replacement finalization cannot escape.
        await waitForObservationAdmissionsToDrain()
        await waitForTerminalProcessingToDrain()
    }

    var pendingObservationIDForTesting: UUID? {
        pendingObservation?.id
    }

    var pendingDeliveryAttemptIDForTesting: UUID? {
        pendingObservation?.deliveryAttemptID
    }

    var hasOwnedObservationTasksForTesting: Bool {
        readbackTask != nil || expiryTask != nil
    }

    func captureProvisionalSampleForTesting() async {
        guard let observationID = pendingObservation?.id else { return }
        _ = await recordProvisionalSample(observationID: observationID)
    }

    var activeObservationAdmissionCountForTesting: Int {
        activeObservationAdmissionCount
    }

    var activeObservationFlushCountForTesting: Int {
        activeObservationFlushCount
    }

    var observationFlushDrainWaiterCountForTesting: Int {
        observationFlushDrainWaiters.count
    }

    func waitUntilObservationFlushDrainHasWaiterForTesting() async {
        guard observationFlushDrainWaiters.isEmpty else { return }
        await withCheckedContinuation { continuation in
            observationFlushDrainRegistrationWaitersForTesting.append(continuation)
        }
    }

    var observationAdmissionDrainWaiterCountForTesting: Int {
        observationAdmissionDrainWaiters.count
    }

    func waitUntilObservationAdmissionDrainHasWaiterForTesting() async {
        guard observationAdmissionDrainWaiters.isEmpty else { return }
        await withCheckedContinuation { continuation in
            observationAdmissionDrainRegistrationWaitersForTesting.append(continuation)
        }
    }

    var terminalProcessingDrainWaiterCountForTesting: Int {
        terminalProcessingDrainWaiters.count
    }

    var activeTerminalProcessingCountForTesting: Int {
        activeTerminalProcessingCount
    }

    func waitUntilTerminalProcessingDrainHasWaiterForTesting() async {
        guard terminalProcessingDrainWaiters.isEmpty else { return }
        await withCheckedContinuation { continuation in
            terminalDrainRegistrationWaitersForTesting.append(continuation)
        }
    }

    private func advanceObservationAdmissionGeneration() -> UInt64 {
        precondition(
            observationAdmissionGeneration < UInt64.max,
            "CorrectionObserver observation-admission generation exhausted"
        )
        observationAdmissionGeneration += 1
        return observationAdmissionGeneration
    }

    private func beginTrackedObservationAdmission() -> UInt64 {
        let generation = advanceObservationAdmissionGeneration()
        activeObservationAdmissionCount += 1
        return generation
    }

    private func endTrackedObservationAdmission() {
        // Assert in debug, clamp in release: this runs after every paste, and
        // a counter-balance bug must degrade to a stuck waiter, not a crash.
        assert(activeObservationAdmissionCount > 0)
        activeObservationAdmissionCount = max(0, activeObservationAdmissionCount - 1)
        guard activeObservationAdmissionCount == 0 else { return }
        let waiters = observationAdmissionDrainWaiters
        observationAdmissionDrainWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func isCurrentObservationAdmission(_ generation: UInt64) -> Bool {
        generation == observationAdmissionGeneration
    }

    private func waitForObservationAdmissionsToDrain() async {
        guard activeObservationAdmissionCount > 0 else { return }
        await withCheckedContinuation { continuation in
            observationAdmissionDrainWaiters.append(continuation)
            let registrationWaiters = observationAdmissionDrainRegistrationWaitersForTesting
            observationAdmissionDrainRegistrationWaitersForTesting.removeAll()
            registrationWaiters.forEach { $0.resume() }
        }
    }

    private func beginTrackedObservationFlush() {
        activeObservationFlushCount += 1
    }

    private func endTrackedObservationFlush() {
        assert(activeObservationFlushCount > 0)
        activeObservationFlushCount = max(0, activeObservationFlushCount - 1)
        guard activeObservationFlushCount == 0 else { return }
        let waiters = observationFlushDrainWaiters
        observationFlushDrainWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func waitForObservationFlushesToDrain() async {
        guard activeObservationFlushCount > 0 else { return }
        await withCheckedContinuation { continuation in
            observationFlushDrainWaiters.append(continuation)
            let registrationWaiters = observationFlushDrainRegistrationWaitersForTesting
            observationFlushDrainRegistrationWaitersForTesting.removeAll()
            registrationWaiters.forEach { $0.resume() }
        }
    }

    private func recordSupersededAdmission(
        _ observation: PendingObservation
    ) async {
        await recordObservation(
            observation,
            status: .observationReplaced,
            pastedText: nil,
            editedText: nil,
            correctionCount: nil
        )
    }

    private func finishPendingObservation(status: CorrectionObservationStatus) async {
        guard let observation = pendingObservation else {
            readbackTask?.cancel()
            readbackTask = nil
            expiryTask?.cancel()
            expiryTask = nil
            provisionalSample = nil
            return
        }
        readbackTask?.cancel()
        readbackTask = nil
        expiryTask?.cancel()
        expiryTask = nil
        pendingObservation = nil
        provisionalSample = nil
        await recordObservation(
            observation,
            status: status,
            pastedText: nil,
            editedText: nil,
            correctionCount: nil
        )
    }

    private func finishPendingObservation(
        id: UUID,
        status: CorrectionObservationStatus
    ) async {
        guard pendingObservation?.id == id else { return }
        await finishPendingObservation(status: status)
    }

    private func finishCompatibilityObservation(
        status: CorrectionObservationStatus
    ) {
        guard let observation = pendingObservation else {
            readbackTask?.cancel()
            readbackTask = nil
            expiryTask?.cancel()
            expiryTask = nil
            provisionalSample = nil
            return
        }
        readbackTask?.cancel()
        readbackTask = nil
        expiryTask?.cancel()
        expiryTask = nil
        pendingObservation = nil
        provisionalSample = nil
        qualityRecorder(
            observation.qualityTrace,
            Self.qualityStatus(for: status),
            nil,
            nil,
            nil,
            max(0, Int(Date().timeIntervalSince(observation.timestamp) * 1000))
        )
    }

    private func expireObservation(id: UUID) async {
        guard let observation = pendingObservation,
              observation.id == id else {
            return
        }
        guard let sample = provisionalSample,
              sample.observationID == id else {
            await finishPendingObservation(id: id, status: .stale)
            return
        }

        // Expiry is a terminal signal only when a fresh read matches the latest
        // digest-only sample. This learns standalone corrections without retaining
        // field contents or committing a still-changing edit.
        let terminalRead = await verifiedStableContent(
            for: observation,
            digest: sample.latestDigest
        )
        guard pendingObservation?.id == id else { return }
        guard let verified = terminalRead.fieldContent else {
            if Self.isTerminalAttributionFailure(terminalRead.failureStatus) {
                await finishPendingObservation(
                    id: id,
                    status: terminalRead.failureStatus
                )
                return
            }
            await finishPendingObservation(id: id, status: .stale)
            return
        }

        readbackTask?.cancel()
        readbackTask = nil
        pendingObservation = nil
        provisionalSample = nil
        await processObservation(
            observation,
            allowsExpiredObservation: true,
            verifiedFieldContent: verified
        )
        expiryTask = nil
    }

    /// Fresh terminal read for stability confirmation. Returns the field
    /// content only when it still matches the given digest-only sample.
    private func verifiedStableContent(
        for observation: PendingObservation,
        digest: Data
    ) async -> ReadbackResult {
        let terminalRead = await readback(for: observation)
        guard let fieldContent = terminalRead.fieldContent,
              !fieldContent.isEmpty,
              Self.readbackDigest(fieldContent) == digest else {
            return ReadbackResult(
                fieldContent: nil,
                failureStatus: terminalRead.failureStatus
            )
        }
        return terminalRead
    }

    // MARK: - Readback

    private struct ReadbackResult {
        let fieldContent: String?
        let failureStatus: CorrectionObservationStatus
    }

    private enum SampleOutcome {
        case continueSampling
        case stop
    }

    /// Timed reads retain only a digest. They never learn immediately; a fresh
    /// terminal read must match the latest sample before anything finalizes.
    /// Once an edit is evident and two consecutive samples agree, the
    /// observation finalizes early rather than waiting for expiry.
    private func recordProvisionalSample(observationID: UUID) async -> SampleOutcome {
        guard let observation = pendingObservation,
              observation.id == observationID else {
            return .stop
        }

        let result = await readback(for: observation)
        guard pendingObservation?.id == observationID else { return .stop }
        guard let fieldContent = result.fieldContent, !fieldContent.isEmpty else {
            provisionalSample = nil
            if Self.isTerminalAttributionFailure(result.failureStatus) {
                await finishPendingObservation(
                    id: observationID,
                    status: result.failureStatus
                )
                return .stop
            }
            log.debug("Provisional correction readback unavailable")
            return .continueSampling
        }

        let digest = Self.readbackDigest(fieldContent)
        guard var sample = provisionalSample,
              sample.observationID == observationID else {
            provisionalSample = ProvisionalSampleState(
                observationID: observationID,
                latestDigest: digest,
                editObserved: false
            )
            log.debug("Captured provisional correction readback")
            return .continueSampling
        }

        if digest != sample.latestDigest {
            sample.latestDigest = digest
            sample.editObserved = true
            provisionalSample = sample
            log.debug("Provisional correction readback changed; still editing")
            return .continueSampling
        }

        // Stable across a full interval. An edit is evident either from an
        // earlier digest change or because the pasted text no longer appears.
        guard sample.editObserved
            || Self.contentSuggestsEdit(fieldContent, observation: observation) else {
            return .continueSampling
        }

        let terminalRead = await verifiedStableContent(for: observation, digest: digest)
        guard pendingObservation?.id == observationID else { return .stop }
        guard let verified = terminalRead.fieldContent else {
            if Self.isTerminalAttributionFailure(terminalRead.failureStatus) {
                await finishPendingObservation(
                    id: observationID,
                    status: terminalRead.failureStatus
                )
                return .stop
            }
            sample.editObserved = true
            provisionalSample = sample
            return .continueSampling
        }

        expiryTask?.cancel()
        expiryTask = nil
        readbackTask = nil
        pendingObservation = nil
        provisionalSample = nil
        log.debug("Finalizing stable edited observation before expiry")
        await processObservation(
            observation,
            allowsExpiredObservation: true,
            verifiedFieldContent: verified
        )
        return .stop
    }

    /// Edit hint for digest samples. Both paths compare only their anchored
    /// region; substring presence is never attribution evidence.
    private static func contentSuggestsEdit(
        _ fieldContent: String,
        observation: PendingObservation
    ) -> Bool {
        if let receipt = observation.deliveryReceipt {
            guard let region = PasteManager.anchoredInsertedRegion(
                in: fieldContent,
                anchor: receipt.anchor
            ) else { return false }
            return region != receipt.targetObservedInsertedText
        }
        guard let attribution = observation.deliveryAttribution else {
            return false
        }
        guard case .attributed(let region) = CorrectionRegionAttributor.region(
            in: fieldContent,
            attribution: attribution
        ) else {
            return false
        }
        return region != observation.settledBaseline
    }

    private func processObservation(
        _ observation: PendingObservation,
        allowsExpiredObservation: Bool = false,
        verifiedFieldContent: String? = nil
    ) async {
        beginTerminalProcessing()
        defer { endTerminalProcessing() }

        await processObservationBody(
            observation,
            allowsExpiredObservation: allowsExpiredObservation,
            verifiedFieldContent: verifiedFieldContent
        )
    }

    private func processObservationBody(
        _ observation: PendingObservation,
        allowsExpiredObservation: Bool,
        verifiedFieldContent: String?
    ) async {
        guard allowsExpiredObservation
            || Date().timeIntervalSince(observation.timestamp) < maximumObservationAge else {
            await recordObservation(
                observation,
                status: .stale,
                pastedText: nil,
                editedText: nil,
                correctionCount: nil
            )
            log.debug("Discarded stale correction observation")
            return
        }

        // A normal terminal flush always performs a fresh read. Expiry may pass
        // the just-verified terminal value that matched the prior digest; reading
        // a third time would reopen a race after stability was established.
        let readbackResult: ReadbackResult
        if let verifiedFieldContent {
            readbackResult = ReadbackResult(
                fieldContent: verifiedFieldContent,
                failureStatus: .noFieldContent
            )
        } else {
            readbackResult = await readback(for: observation)
        }
        guard let fieldContent = readbackResult.fieldContent,
              !fieldContent.isEmpty else {
            await recordObservation(
                observation,
                status: readbackResult.failureStatus,
                pastedText: nil,
                editedText: nil,
                correctionCount: nil
            )
            log.debug("Correction readback: no terminal readback source available")
            return
        }

        if let receipt = observation.deliveryReceipt {
            guard let pastedRegion = Self.evaluableAnchoredRegion(
                original: receipt.targetObservedInsertedText,
                fieldContent: fieldContent,
                anchor: receipt.anchor,
                ownership: Self.receiptRegionOwnership(
                    anchor: receipt.anchor,
                    deliveryAttribution: observation.deliveryAttribution
                )
            ) else {
                await recordObservation(
                    observation,
                    status: .regionUnattributable,
                    pastedText: receipt.targetObservedInsertedText,
                    editedText: nil,
                    correctionCount: nil
                )
                log.debug("Correction readback: anchored region changed at an open boundary or was not found")
                return
            }
            await processPastedRegion(
                original: receipt.targetObservedInsertedText,
                pastedRegion: pastedRegion,
                observation: observation
            )
            return
        }

        guard let attribution = observation.deliveryAttribution else {
            await recordObservation(
                observation,
                status: .regionUnattributable,
                pastedText: observation.settledBaseline,
                editedText: nil,
                correctionCount: nil
            )
            return
        }
        guard let pastedRegion = Self.evaluableAttributedRegion(
            original: observation.settledBaseline,
            fieldContent: fieldContent,
            attribution: attribution
        ) else {
            await recordObservation(
                observation,
                status: .regionUnattributable,
                pastedText: observation.settledBaseline,
                editedText: nil,
                correctionCount: nil
            )
            log.debug("Correction readback: exact attributed region unavailable")
            return
        }
        await processPastedRegion(
            original: observation.settledBaseline,
            pastedRegion: pastedRegion,
            observation: observation
        )
    }

    private func beginTerminalProcessing() {
        activeTerminalProcessingCount += 1
    }

    private func endTerminalProcessing() {
        assert(activeTerminalProcessingCount > 0)
        activeTerminalProcessingCount = max(0, activeTerminalProcessingCount - 1)
        guard activeTerminalProcessingCount == 0 else { return }
        let waiters = terminalProcessingDrainWaiters
        terminalProcessingDrainWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func waitForTerminalProcessingToDrain() async {
        guard activeTerminalProcessingCount > 0 else { return }
        await withCheckedContinuation { continuation in
            terminalProcessingDrainWaiters.append(continuation)
            let registrationWaiters = terminalDrainRegistrationWaitersForTesting
            terminalDrainRegistrationWaitersForTesting.removeAll()
            registrationWaiters.forEach { $0.resume() }
        }
    }

    private static func readbackDigest(_ fieldContent: String) -> Data {
        Data(SHA256.hash(data: Data(fieldContent.utf8)))
    }

    private static func timeInterval(for duration: Duration) -> TimeInterval {
        let components = duration.components
        return Double(components.seconds)
            + (Double(components.attoseconds) / 1_000_000_000_000_000_000)
    }

    private static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        UInt64(max(0, seconds) * 1_000_000_000)
    }

    private func readback(for observation: PendingObservation) async -> ReadbackResult {
        if let receipt = observation.deliveryReceipt {
            guard let attribution = observation.deliveryAttribution else {
                return ReadbackResult(
                    fieldContent: nil,
                    failureStatus: .insufficientIdentity
                )
            }
            guard let snapshot = receiptReadback(receipt) else {
                return ReadbackResult(
                    fieldContent: nil,
                    failureStatus: .noFieldContent
                )
            }
            if let targetFailure = Self.targetFailure(
                delivery: attribution.targetIdentity,
                observed: snapshot.targetIdentity
            ) {
                return ReadbackResult(
                    fieldContent: nil,
                    failureStatus: targetFailure
                )
            }
            return ReadbackResult(
                fieldContent: snapshot.fullFieldContent,
                failureStatus: .noFieldContent
            )
        }

        guard let attribution = observation.deliveryAttribution else {
            return ReadbackResult(
                fieldContent: nil,
                failureStatus: .regionUnattributable
            )
        }
        guard let snapshot = await ambientFieldContentProvider?.correctionHotSnapshot(
            for: observation.targetApp
        ) else {
            return ReadbackResult(
                fieldContent: nil,
                failureStatus: .noFieldContent
            )
        }
        if let targetFailure = Self.targetFailure(
            delivery: attribution.targetIdentity,
            observed: snapshot.targetIdentity
        ) {
            return ReadbackResult(
                fieldContent: nil,
                failureStatus: targetFailure
            )
        }
        return ReadbackResult(
            fieldContent: snapshot.fullFieldContent,
            failureStatus: .noFieldContent
        )
    }

    /// Legacy test/caller seam. Content-only providers and observations without
    /// attribution now fail closed; no heuristic isolation or mutation occurs.
    func processWithAmbientFallback(
        _ observation: PendingObservation,
        fallbackStatus: DictationQualityReadbackStatus
    ) async {
        let result = await readback(for: observation)
        guard let content = result.fieldContent, !content.isEmpty else {
            let status: CorrectionObservationStatus
            if observation.deliveryAttribution == nil {
                status = .regionUnattributable
            } else if Self.isTerminalAttributionFailure(result.failureStatus) {
                status = result.failureStatus
            } else {
                status = Self.observationStatus(forLegacyFallback: fallbackStatus)
            }
            await recordObservation(
                observation,
                status: status,
                pastedText: nil,
                editedText: nil,
                correctionCount: nil
            )
            return
        }
        await processObservation(
            observation,
            verifiedFieldContent: content
        )
    }

    private func processPastedRegion(
        original: String,
        pastedRegion: String,
        observation: PendingObservation
    ) async {
        let wasEdited = pastedRegion != original

        let correctionContext = CorrectionObservationContext(
            appName: observation.targetApp?.localizedName,
            bundleId: observation.deliveryReceipt?.targetBundleIdentifier
                ?? observation.deliveryAttribution?.targetBundleIdentifier
                ?? observation.targetApp?.bundleIdentifier,
            windowTitle: observation.windowTitle,
            browserURL: observation.browserURL,
            contextPacket: observation.contextPacket
        )

        let extraction = CorrectionDiffEngine.extractWithSuggestions(
            original: original,
            edited: pastedRegion
        )
        let corrections = extraction.corrections
        let finalizationResult = await recordObservation(
            observation,
            status: wasEdited ? .corrected : .accepted,
            pastedText: original,
            editedText: pastedRegion,
            correctionCount: corrections.count
        )

        // The persisted terminal transition is the semantic commit boundary.
        // A recovery timeout, clear suspension, duplicate completion, or failed
        // write must never produce quality or learning that contradicts it.
        guard finalizationResult == .finalized else {
            log.debug("Correction readback mutation blocked by outcome finalization")
            return
        }

        // Readback quality remains observable, but every mutation sink below
        // also fails closed unless the explicit correction capability exists.
        guard observation.capabilities.allowsCorrectionDerivedMutations else {
            log.debug("Correction readback mutation blocked by capabilities")
            return
        }

        // Boost ground truth: an edit that removes an applied term or types
        // in a vetoed one is direct evidence about the replacement policy.
        if wasEdited, let audit = observation.boostAudit {
            let signals = audit.correctionSignals(
                pastedText: original, editedText: pastedRegion
            )
            if !signals.isEmpty {
                boostCorrelationRecorder(signals)
            }
        }

        // Format-correction seam: fire once per observation with real edits,
        // before any word-level diff filtering narrows things down.
        if wasEdited {
            formatCorrectionSink?(original, pastedRegion, correctionContext)
        }

        dispatchLearnSuggestions(extraction.suggestions)

        guard !corrections.isEmpty else {
            if !wasEdited {
                recordUncorrectedWords(in: original)
            }
            await personalizationLearningEngine?.recordFeedback(DictationFeedbackEvent(
                pastedText: original,
                editedText: pastedRegion,
                rawTranscript: observation.rawTranscript,
                corrections: [],
                context: correctionContext,
                capabilities: observation.capabilities,
                appliedStylePolicy: observation.appliedStylePolicy,
                wasEdited: wasEdited,
                ctcAppliedTerms: observation.boostAudit?.appliedTerms ?? []
            ))
            await dictionaryStore.saveChanges()
            return
        }

        log.info("Auto-learn: detected \(corrections.count) correction(s)")
        let storedCorrectionPairs = corrections.map {
            StoredCorrectionPair(
                spoken: $0.spoken,
                written: $0.written,
                spokenIsRealWord: $0.spokenIsRealWord
            )
        }

        for candidate in corrections {
            dictionaryStore.recordAutoCorrection(
                spoken: candidate.spoken,
                written: candidate.written,
                spokenIsRealWord: candidate.spokenIsRealWord,
                writtenIsProperNoun: candidate.writtenIsProperNoun
            )
        }
        await personalizationLearningEngine?.recordFeedback(DictationFeedbackEvent(
            pastedText: original,
            editedText: pastedRegion,
            rawTranscript: observation.rawTranscript,
            corrections: storedCorrectionPairs,
            context: correctionContext,
            capabilities: observation.capabilities,
            appliedStylePolicy: observation.appliedStylePolicy,
            wasEdited: true,
            ctcAppliedTerms: observation.boostAudit?.appliedTerms ?? []
        ))

        // Words not corrected get an uncorrected bump — batch save after the loop
        let correctedSpoken = Set(corrections.map { CorrectionDiffEngine.normalize($0.spoken).lowercased() })
        for word in CorrectionDiffEngine.tokenize(original) {
            let norm = CorrectionDiffEngine.normalize(word).lowercased()
            if !correctedSpoken.contains(norm) {
                dictionaryStore.recordUncorrected(spoken: word)
            }
        }
        await dictionaryStore.saveChanges()
    }

    /// Forwards near-miss candidates to the prompt seam, skipping pairs the
    /// dictionary already tracks (learning, applied, or declined).
    private func dispatchLearnSuggestions(_ suggestions: [CorrectionDiffEngine.Candidate]) {
        guard let learnSuggestionSink, !suggestions.isEmpty else { return }
        for suggestion in suggestions
        where !dictionaryStore.hasEntry(spoken: suggestion.spoken) {
            learnSuggestionSink(suggestion)
        }
    }

    /// Anchored changes are evaluable only when both surrounding boundaries
    /// remain present or delivery attribution explicitly proves ownership of
    /// the whole pre-delivery field. An unchanged terminal read is safe even at
    /// a field edge; a changed weak edge could include unrelated typing before
    /// or after the delivered region and is therefore deliberately rejected.
    static func evaluableAnchoredRegion(
        original: String,
        fieldContent: String,
        anchor: PasteManager.UTF16InsertionAnchor,
        ownership: ReceiptRegionOwnership
    ) -> String? {
        guard let region = PasteManager.anchoredInsertedRegion(
            in: fieldContent,
            anchor: anchor
        ) else {
            return nil
        }
        let originalTokens = CorrectionDiffEngine.tokenize(original)
        let regionTokens = CorrectionDiffEngine.tokenize(region)
        guard region == original || (
            ownership.authorizesChangedRegion
                && plausibleAnchoredRewrite(
                    originalTokens: originalTokens,
                    editedTokens: regionTokens,
                    allowsTokenMerge: ownership.authorizesChangedRegion
                )
        ) else {
            return nil
        }
        return region
    }

    /// Derives edit authority from delivery-time ownership evidence. A
    /// both-open anchor is whole-field-owned only when the routed attribution
    /// explicitly says so and its lengths prove that claim. Empty boundary
    /// digests by themselves are not ownership evidence.
    static func receiptRegionOwnership(
        anchor: PasteManager.UTF16InsertionAnchor,
        deliveryAttribution: PasteManager.DeliveryAttribution?
    ) -> ReceiptRegionOwnership {
        if anchor.hasClosedBoundaries {
            return .closedBoundaries
        }
        guard let deliveryAttribution,
              deliveryAttribution.anchor == anchor,
              deliveryAttribution.wholeFieldOwned,
              anchor.prefixUTF16Length == 0,
              anchor.suffixUTF16Length == 0,
              anchor.replacedRange.location == 0,
              anchor.replacedRange.length
                == deliveryAttribution.preDeliveryFieldUTF16Length else {
            return .weakOpenBoundary
        }
        return .explicitlyOwnedWholeField
    }

    /// No-receipt region evaluation. The attributor has already forbidden
    /// open-boundary anchors unless the delivery owned the whole field.
    static func evaluableAttributedRegion(
        original: String,
        fieldContent: String,
        attribution: PasteManager.DeliveryAttribution
    ) -> String? {
        guard case .attributed(let region) = CorrectionRegionAttributor.region(
            in: fieldContent,
            attribution: attribution
        ) else {
            return nil
        }
        guard region == original || plausibleAnchoredRewrite(
            originalTokens: CorrectionDiffEngine.tokenize(original),
            editedTokens: CorrectionDiffEngine.tokenize(region),
            allowsTokenMerge: attribution.anchor.hasClosedBoundaries
                || attribution.wholeFieldOwned
        ) else {
            return nil
        }
        return region
    }

    private static func plausibleAnchoredRewrite(
        originalTokens: [String],
        editedTokens: [String],
        allowsTokenMerge: Bool
    ) -> Bool {
        guard !originalTokens.isEmpty, !editedTokens.isEmpty,
              CorrectionDiffEngine.fuzzyOverlapRatio(originalTokens, editedTokens)
                >= CorrectionDiffEngine.minimumSimilarityRatio else {
            return false
        }

        if originalTokens.count != editedTokens.count {
            // Only a closed-boundary merge ("tie s" → "Thijs") is evaluable,
            // and only when the region shrank by one token — growth at any
            // boundary can be unrelated typing.
            guard allowsTokenMerge,
                  editedTokens.count == originalTokens.count - 1 else {
                return false
            }
            guard originalTokens.count > 3 else { return true }
            let normalizedOriginal = Set(
                originalTokens.map { CorrectionDiffEngine.normalize($0).lowercased() }
            )
            let normalizedEdited = Set(
                editedTokens.map { CorrectionDiffEngine.normalize($0).lowercased() }
            )
            return !normalizedOriginal.intersection(normalizedEdited).isEmpty
        }

        let normalizedPairs = zip(originalTokens, editedTokens).map { original, edited in
            (
                CorrectionDiffEngine.normalize(original).lowercased(),
                CorrectionDiffEngine.normalize(edited).lowercased()
            )
        }
        if normalizedPairs.count > 1 {
            // A multi-word replacement with no stable positional token is
            // indistinguishable from an intentional rewrite. Do not turn it
            // into personalization evidence merely because token counts match.
            return normalizedPairs.contains { $0.0 == $0.1 }
        }

        guard let pair = normalizedPairs.first else { return false }
        let longestLength = max(pair.0.count, pair.1.count)
        let relativeLimit = min(3, max(1, Int(ceil(Double(longestLength) * 0.4))))
        return CorrectionDiffEngine.levenshtein(pair.0, pair.1) <= relativeLimit
    }

    /// Validates that the retained receipt and its separately routed delivery
    /// evidence describe one sufficiently identified, known-safe target. This
    /// runs before timers are installed or the retained AX element is polled.
    private static func receiptAdmissionFailure(
        receipt: PasteManager.DeliveryReceipt,
        attribution: PasteManager.DeliveryAttribution?
    ) -> CorrectionObservationStatus? {
        guard let attribution else { return .insufficientIdentity }

        let sensitivityValues = [
            attribution.isSensitiveInput,
            attribution.targetFingerprint?.isSensitiveInput,
        ].compactMap { $0 }
        if sensitivityValues.contains(true) {
            return .sensitiveTarget
        }

        guard receipt.targetProcessIdentifier > 0,
              attribution.targetProcessIdentifier > 0,
              let receiptBundleIdentifier = receipt.targetBundleIdentifier,
              !receiptBundleIdentifier.isEmpty,
              let fingerprint = attribution.targetFingerprint,
              attribution.isSensitiveInput == false,
              fingerprint.isSensitiveInput == false,
              receipt.anchor == attribution.anchor else {
            return .insufficientIdentity
        }
        guard receipt.targetProcessIdentifier == attribution.targetProcessIdentifier else {
            return .processMismatch
        }
        guard receiptBundleIdentifier == attribution.targetBundleIdentifier else {
            return .targetMismatch
        }

        let receiptIdentity = CorrectionTargetIdentity(
            processIdentifier: receipt.targetProcessIdentifier,
            bundleIdentifier: receiptBundleIdentifier,
            isSensitiveInput: attribution.isSensitiveInput,
            fingerprint: fingerprint
        )
        switch CorrectionTargetMatcher.match(
            delivery: attribution.targetIdentity,
            observed: receiptIdentity
        ) {
        case .match:
            return nil
        case .mismatch:
            return .targetMismatch
        case .insufficientEvidence:
            return .insufficientIdentity
        }
    }

    private static func targetFailure(
        delivery: CorrectionTargetIdentity,
        observed: CorrectionTargetIdentity
    ) -> CorrectionObservationStatus? {
        // Sensitivity is an unconditional veto, even if other identity fields
        // also changed while the observation was pending.
        let sensitivityValues = [
            delivery.isSensitiveInput,
            delivery.fingerprint?.isSensitiveInput,
            observed.isSensitiveInput,
            observed.fingerprint?.isSensitiveInput,
        ].compactMap { $0 }
        if sensitivityValues.contains(true) {
            return .sensitiveTarget
        }
        if let deliveryPID = delivery.processIdentifier,
           let observedPID = observed.processIdentifier,
           deliveryPID != observedPID {
            return .processMismatch
        }
        if let deliveryBundle = delivery.bundleIdentifier,
           let observedBundle = observed.bundleIdentifier,
           deliveryBundle != observedBundle {
            return .targetMismatch
        }

        switch CorrectionTargetMatcher.match(
            delivery: delivery,
            observed: observed
        ) {
        case .match:
            return nil
        case .mismatch:
            return .targetMismatch
        case .insufficientEvidence:
            return .insufficientIdentity
        }
    }

    private static func contextTargetFailure(
        attribution: PasteManager.DeliveryAttribution,
        contextFingerprint: ContextTargetFingerprint
    ) -> CorrectionObservationStatus? {
        let contextIdentity = CorrectionTargetIdentity(
            processIdentifier: attribution.targetProcessIdentifier,
            bundleIdentifier: attribution.targetBundleIdentifier,
            isSensitiveInput: contextFingerprint.isSensitiveInput,
            fingerprint: contextFingerprint
        )
        switch CorrectionTargetMatcher.match(
            delivery: attribution.targetIdentity,
            observed: contextIdentity
        ) {
        case .match, .insufficientEvidence:
            return nil
        case .mismatch:
            return targetFailure(
                delivery: attribution.targetIdentity,
                observed: contextIdentity
            ) ?? .targetMismatch
        }
    }

    private static func isTerminalAttributionFailure(
        _ status: CorrectionObservationStatus
    ) -> Bool {
        switch status {
        case .processMismatch, .targetMismatch, .sensitiveTarget,
                .insufficientIdentity, .regionUnattributable,
                .targetNormalizedOrUnattributable:
            return true
        case .accepted, .corrected, .stale, .noFieldContent,
                .baselineUnavailable, .observationReplaced,
                .observationCancelled:
            return false
        }
    }

    private static func observationStatus(
        forLegacyFallback status: DictationQualityReadbackStatus
    ) -> CorrectionObservationStatus {
        switch status {
        case .accepted:
            return .accepted
        case .corrected:
            return .corrected
        case .stale:
            return .stale
        case .observationReplaced:
            return .observationReplaced
        case .observationCancelled:
            return .observationCancelled
        case .regionNotFound:
            return .regionUnattributable
        case .bypassed, .noFieldContent, .autoSent, .personalizationUnavailable:
            return .baselineUnavailable
        }
    }

    private static func qualityStatus(
        for status: CorrectionObservationStatus
    ) -> DictationQualityReadbackStatus {
        switch status {
        case .accepted:
            return .accepted
        case .corrected:
            return .corrected
        case .stale:
            return .stale
        case .noFieldContent, .baselineUnavailable:
            return .noFieldContent
        case .processMismatch, .targetMismatch, .sensitiveTarget,
                .insufficientIdentity:
            return .bypassed
        case .regionUnattributable, .targetNormalizedOrUnattributable:
            return .regionNotFound
        case .observationReplaced:
            return .observationReplaced
        case .observationCancelled:
            return .observationCancelled
        }
    }

    @discardableResult
    private func recordObservation(
        _ observation: PendingObservation,
        status: CorrectionObservationStatus,
        pastedText: String?,
        editedText: String?,
        correctionCount: Int?
    ) async -> PersonalizationOutcomeFinalizationResult {
        // Some terminal outcomes are emitted directly by validation/cancellation
        // paths rather than through `processObservation`. Count this awaited
        // actor callback too, so workspace clear cannot cross either shape.
        beginTerminalProcessing()
        defer { endTerminalProcessing() }

        let editDistanceBucket = PersonalizationEditDistanceBucket.classify(
            pastedText.flatMap { pastedText in
                editedText.map { editedText in
                    PersonalizationEvaluationEngine.normalizedEditDistance(
                        from: pastedText,
                        to: editedText
                    )
                }
            }
        )
        let outcome = CorrectionObservationOutcome(
            deliveryAttemptID: observation.deliveryAttemptID,
            status: status,
            readbackMethod: observation.readbackMethod,
            capabilities: observation.capabilities,
            editDistanceBucket: editDistanceBucket,
            correctionCount: correctionCount.map { min(20, max(0, $0)) }
        )

        let finalizationResult: PersonalizationOutcomeFinalizationResult
        if observation.requiresPersistedOutcomeFinalization {
            finalizationResult = await outcomeRecorder(outcome)
            guard finalizationResult == .finalized else {
                return finalizationResult
            }
        } else {
            // Compatibility observations are explicitly quality-only and carry
            // no mutation capability. They never impersonate a persisted row.
            finalizationResult = .finalized
        }

        qualityRecorder(
            observation.qualityTrace,
            Self.qualityStatus(for: status),
            pastedText,
            editedText,
            correctionCount,
            max(0, Int(Date().timeIntervalSince(observation.timestamp) * 1000))
        )
        return finalizationResult
    }

    private func recordUncorrectedWords(in text: String) {
        for word in CorrectionDiffEngine.tokenize(text) {
            dictionaryStore.recordUncorrected(spoken: word)
        }
        // Single save after batch — recordUncorrected is in-memory only
    }
}
