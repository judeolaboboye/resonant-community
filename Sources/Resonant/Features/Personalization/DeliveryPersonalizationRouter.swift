import AppKit
import Foundation

/// The single delivery-time boundary for local personalization accounting.
///
/// Callers provide requested route facts alongside the resolved physical
/// `DeliveryOutcome`. The router persists that outcome before starting any
/// readback or learning side effect, so duplicate routing cannot observe or
/// learn twice.
@MainActor
final class DeliveryPersonalizationRouter {
    struct Dependencies {
        var registerOutcome: (PersonalizationOutcomeRegistration) async
            -> PersonalizationOutcomeRegistrationResult
        var observeReceipt: (DeliveryReceiptObservationRequest) async -> Void
        var observeSnapshot: (DeliverySnapshotObservationRequest) async -> Bool
        var recordRawTranscriptHabit: (RawTranscriptHabitFeedbackRequest) async -> Void
        var recordTerminalQuality: (
            DictationQualityTrace,
            DictationQualityReadbackStatus
        ) -> Void
        var cancelObserverAndWait: () async -> Void
        var quiesceOutcomeStore: () async -> Void
        var completeOutcomeStoreClear: () async -> Void
        var resumeOutcomeStoreAfterClear: () async -> Void
    }

    private let dependencies: Dependencies
    private var isRouteAdmissionSuspended = false
    private var activeRouteCount = 0
    private var routeDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private var routeSuspensionWaitersForTesting: [CheckedContinuation<Void, Never>] = []

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    convenience init(
        outcomeStore: PersonalizationOutcomeStore,
        correctionObserver: CorrectionObserver,
        personalizationMemoryStore: PersonalizationMemoryStore
    ) {
        self.init(dependencies: Dependencies(
            registerOutcome: { registration in
                await outcomeStore.register(registration)
            },
            observeReceipt: { request in
                await correctionObserver.observe(
                    deliveryReceipt: request.deliveryReceipt,
                    deliveryAttribution: request.deliveryAttribution,
                    deliveryAttemptID: request.deliveryAttemptID,
                    capabilities: request.capabilities,
                    effectiveInsertedText: request.effectiveInsertedText,
                    windowTitle: request.windowTitle,
                    browserURL: request.browserURL,
                    rawTranscript: request.rawTranscript,
                    contextPacket: request.contextPacket,
                    qualityTrace: request.qualityTrace,
                    boostAudit: request.boostAudit,
                    appliedStylePolicy: request.appliedStylePolicy
                )
            },
            observeSnapshot: { request in
                await correctionObserver.observe(
                    deliveryOutcome: request.deliveryOutcome,
                    targetApp: request.targetApplication,
                    windowTitle: request.windowTitle,
                    browserURL: request.browserURL,
                    rawTranscript: request.rawTranscript,
                    contextPacket: request.contextPacket,
                    qualityTrace: request.qualityTrace,
                    boostAudit: request.boostAudit,
                    capabilities: request.capabilities,
                    appliedStylePolicy: request.appliedStylePolicy
                )
            },
            recordRawTranscriptHabit: { request in
                await personalizationMemoryStore.recordAutoSentDelivery(request)
            },
            recordTerminalQuality: { trace, status in
                DictationQualityPipeline.recordReadback(
                    trace: trace,
                    status: status,
                    pastedText: nil,
                    editedText: nil,
                    correctionCount: nil,
                    observationAgeMs: nil
                )
            },
            cancelObserverAndWait: {
                await correctionObserver.cancelAndWait()
            },
            quiesceOutcomeStore: {
                await outcomeStore.quiesceForWorkspaceClear()
            },
            completeOutcomeStoreClear: {
                await outcomeStore.completeWorkspaceClear()
            },
            resumeOutcomeStoreAfterClear: {
                await outcomeStore.resumeAfterWorkspaceClear()
            }
        ))
    }

    @discardableResult
    func route(
        _ request: DeliveryPersonalizationRequest
    ) async -> DeliveryPersonalizationRoutingResult {
        let routeFacts = request.routeFacts
        let classification = PersonalizationOutcomeClassifier.classify(routeFacts)
        let capabilities = request.resolvedCapabilities
        guard beginRoute() else {
            return DeliveryPersonalizationRoutingResult(
                registrationResult: .suspended,
                classification: classification,
                capabilities: capabilities
            )
        }
        defer { endRoute() }

        let readbackMethod: PersonalizationOutcomeReadbackMethod =
            request.deliveryOutcome.receipt == nil
                ? .attributedSnapshot
                : .retainedReceipt
        let surface = request.contextPacket?.surface ?? request.surface
        let bundleIdentifier = request.deliveryOutcome.targetBundleIdentifier
            ?? request.targetApplication?.bundleIdentifier
            ?? surface?.bundleId
        let exposure = request.personalizationExposure?.outcomeExposure
            ?? .none

        let registration = PersonalizationOutcomeRegistration(
            deliveryAttemptID: request.deliveryOutcome.deliveryAttemptID,
            routeFacts: routeFacts,
            readbackMethod: readbackMethod,
            surface: PersonalizationOutcomeSurface(surfaceKind: surface?.kind),
            targetProfile: PersonalizationOutcomeTargetProfile.classify(
                bundleIdentifier: bundleIdentifier
            ),
            exposure: exposure
        )
        let registrationResult = await dependencies.registerOutcome(registration)
        let result = DeliveryPersonalizationRoutingResult(
            registrationResult: registrationResult,
            classification: classification,
            capabilities: capabilities
        )

        var qualityTrace = request.qualityTrace
        if qualityTrace != nil {
            qualityTrace?.contextPersonalization = request.personalizationExposure
        }

        // A pre-existing ID or a workspace-clear barrier must never replay
        // observation, quality, or learning effects.
        switch registrationResult {
        case .insertedPending, .insertedTerminal:
            break
        case .alreadyRegistered, .suspended:
            return result
        case .persistenceUnavailable:
            // The outcome actor is the acknowledgment authority for learning,
            // so learning stays closed. Quality telemetry is a separate
            // channel and must NOT go silent here — otherwise a broken store
            // suppresses the only signal that would reveal it.
            if let qualityTrace {
                dependencies.recordTerminalQuality(qualityTrace, .personalizationUnavailable)
            }
            return result
        }

        switch classification {
        case .pendingEligible:
            if let receipt = request.deliveryOutcome.receipt {
                await dependencies.observeReceipt(DeliveryReceiptObservationRequest(
                    deliveryReceipt: receipt,
                    deliveryAttribution: request.deliveryOutcome.deliveryAttribution,
                    deliveryAttemptID: request.deliveryOutcome.deliveryAttemptID,
                    capabilities: capabilities,
                    effectiveInsertedText: request.deliveryOutcome.effectiveInsertedText,
                    windowTitle: request.windowTitle,
                    browserURL: request.browserURL,
                    rawTranscript: request.rawTranscript,
                    contextPacket: request.contextPacket,
                    qualityTrace: qualityTrace,
                    boostAudit: request.boostAudit,
                    appliedStylePolicy: request.appliedStylePolicy
                ))
            } else {
                _ = await dependencies.observeSnapshot(DeliverySnapshotObservationRequest(
                    deliveryOutcome: request.deliveryOutcome,
                    targetApplication: request.targetApplication,
                    windowTitle: request.windowTitle,
                    browserURL: request.browserURL,
                    rawTranscript: request.rawTranscript,
                    contextPacket: request.contextPacket,
                    qualityTrace: qualityTrace,
                    boostAudit: request.boostAudit,
                    capabilities: capabilities,
                    appliedStylePolicy: request.appliedStylePolicy
                ))
            }

        case .terminalExcluded(let status):
            if let qualityTrace {
                let qualityStatus: DictationQualityReadbackStatus = status == .excludedAutoSent
                    ? .autoSent
                    : .bypassed
                dependencies.recordTerminalQuality(qualityTrace, qualityStatus)
            }

            if status == .excludedAutoSent,
               capabilities.allowsRawTranscriptHabits,
               let rawTranscript = request.rawTranscript,
               !rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await dependencies.recordRawTranscriptHabit(
                    RawTranscriptHabitFeedbackRequest(
                        rawTranscript: rawTranscript,
                        context: request.correctionContext,
                        capabilities: capabilities
                    )
                )
            }
        }

        return result
    }

    /// Establishes the destructive-clear boundary in the required order: an
    /// admitted route finishes before observer callbacks are drained and the
    /// actor suspends writes. Routes that arrive after suspension fail closed.
    func quiesceForWorkspaceClear() async {
        isRouteAdmissionSuspended = true
        let suspensionWaiters = routeSuspensionWaitersForTesting
        routeSuspensionWaitersForTesting.removeAll()
        suspensionWaiters.forEach { $0.resume() }
        await waitForActiveRoutes()
        await dependencies.cancelObserverAndWait()
        await dependencies.quiesceOutcomeStore()
    }

    func completeWorkspaceClear() async {
        // The central store is empty, but the wider AppState clear is still in
        // progress. Admission reopens only from the final runtime-resume step.
        await dependencies.completeOutcomeStoreClear()
    }

    func resumeAfterWorkspaceClear() async {
        await dependencies.resumeOutcomeStoreAfterClear()
        isRouteAdmissionSuspended = false
    }

    var isRouteAdmissionSuspendedForTesting: Bool {
        isRouteAdmissionSuspended
    }

    func waitUntilRouteAdmissionSuspendedForTesting() async {
        guard !isRouteAdmissionSuspended else { return }
        await withCheckedContinuation { continuation in
            routeSuspensionWaitersForTesting.append(continuation)
        }
    }

    private func beginRoute() -> Bool {
        guard !isRouteAdmissionSuspended else { return false }
        activeRouteCount += 1
        return true
    }

    private func endRoute() {
        precondition(activeRouteCount > 0)
        activeRouteCount -= 1
        guard activeRouteCount == 0 else { return }
        let waiters = routeDrainWaiters
        routeDrainWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func waitForActiveRoutes() async {
        guard activeRouteCount > 0 else { return }
        await withCheckedContinuation { continuation in
            routeDrainWaiters.append(continuation)
        }
    }

    /// Exhaustive translation from observer vocabulary into the persisted
    /// local outcome vocabulary. No observer status may silently disappear.
    nonisolated static func finalization(
        for outcome: CorrectionObservationOutcome
    ) -> PersonalizationOutcomeFinalization {
        let readbackMethod: PersonalizationOutcomeReadbackMethod
        switch outcome.readbackMethod {
        case .none:
            readbackMethod = .unavailable
        case .receipt:
            readbackMethod = .retainedReceipt
        case .correctionHotSnapshot:
            readbackMethod = .attributedSnapshot
        }

        switch outcome.status {
        case .accepted:
            return .accepted(readbackMethod: readbackMethod)
        case .corrected:
            return .corrected(
                readbackMethod: readbackMethod,
                editDistanceBucket: outcome.editDistanceBucket,
                correctionCount: outcome.correctionCount
            )
        case .stale:
            return .unobservable(.stale, readbackMethod: readbackMethod)
        case .noFieldContent:
            return .unobservable(.noFieldContent, readbackMethod: readbackMethod)
        case .baselineUnavailable:
            return .unobservable(.baselineUnavailable, readbackMethod: readbackMethod)
        case .processMismatch:
            return .unobservable(.processMismatch, readbackMethod: readbackMethod)
        case .targetMismatch:
            return .unobservable(.targetMismatch, readbackMethod: readbackMethod)
        case .sensitiveTarget:
            return .unobservable(.sensitiveTarget, readbackMethod: readbackMethod)
        case .insufficientIdentity:
            return .unobservable(.insufficientIdentity, readbackMethod: readbackMethod)
        case .regionUnattributable:
            return .unobservable(.regionUnattributable, readbackMethod: readbackMethod)
        case .targetNormalizedOrUnattributable:
            return .unobservable(
                .targetNormalizedOrUnattributable,
                readbackMethod: readbackMethod
            )
        case .observationReplaced:
            return .unobservable(.observationReplaced, readbackMethod: readbackMethod)
        case .observationCancelled:
            return .unobservable(.observationCancelled, readbackMethod: readbackMethod)
        }
    }
}

struct DeliveryPersonalizationRequest {
    let deliveryOutcome: PasteManager.DeliveryOutcome
    let autoPasteRequested: Bool
    let autoSendRequested: Bool
    let copiedToClipboard: Bool
    let selectionTransformUsed: Bool
    let targetApplication: NSRunningApplication?
    let surface: SurfaceDescriptor?
    let windowTitle: String?
    let browserURL: String?
    let rawTranscript: String?
    let contextPacket: ContextPacket?
    /// Final consumer-resolved exposure. The router must never reconstruct
    /// application from packet membership.
    let personalizationExposure: ContextPersonalizationExposure?
    let qualityTrace: DictationQualityTrace?
    let boostAudit: VocabularyBoostAudit?
    let confidence: DictationConfidenceSnapshot?
    let appliedStylePolicy: AppliedStylePolicy

    var routeFacts: PersonalizationDeliveryRouteFacts {
        PersonalizationDeliveryRouteFacts(
            delivered: deliveryOutcome.delivered,
            partiallyDelivered: deliveryOutcome.partiallyDelivered,
            autoPasted: autoPasteRequested && deliveryOutcome.delivered,
            autoSent: autoSendRequested,
            copiedToClipboard: copiedToClipboard,
            selectionTransformUsed: selectionTransformUsed
        )
    }

    var resolvedCapabilities: LearningCapabilities {
        guard let confidence else { return .none }
        return LearningCapabilities.resolving(
            correctionDerivedEligible: confidence.learningEligible,
            rawTranscriptHabitEligible: confidence.rawTranscriptHabitEligible,
            autoSent: autoSendRequested,
            selectionTransformUsed: selectionTransformUsed
        )
    }

    var correctionContext: CorrectionObservationContext {
        CorrectionObservationContext(
            appName: surface?.appName ?? targetApplication?.localizedName,
            bundleId: deliveryOutcome.targetBundleIdentifier
                ?? surface?.bundleId
                ?? targetApplication?.bundleIdentifier,
            windowTitle: windowTitle,
            browserURL: browserURL,
            contextPacket: contextPacket
        )
    }
}

struct DeliveryReceiptObservationRequest {
    let deliveryReceipt: PasteManager.DeliveryReceipt
    let deliveryAttribution: PasteManager.DeliveryAttribution?
    let deliveryAttemptID: UUID
    let capabilities: LearningCapabilities
    let effectiveInsertedText: String?
    let windowTitle: String?
    let browserURL: String?
    let rawTranscript: String?
    let contextPacket: ContextPacket?
    let qualityTrace: DictationQualityTrace?
    let boostAudit: VocabularyBoostAudit?
    let appliedStylePolicy: AppliedStylePolicy
}

struct DeliverySnapshotObservationRequest {
    let deliveryOutcome: PasteManager.DeliveryOutcome
    let targetApplication: NSRunningApplication?
    let windowTitle: String?
    let browserURL: String?
    let rawTranscript: String?
    let contextPacket: ContextPacket?
    let qualityTrace: DictationQualityTrace?
    let boostAudit: VocabularyBoostAudit?
    let capabilities: LearningCapabilities
    let appliedStylePolicy: AppliedStylePolicy
}

struct DeliveryPersonalizationRoutingResult: Equatable {
    let registrationResult: PersonalizationOutcomeRegistrationResult
    let classification: PersonalizationOutcomeRouteClassification
    let capabilities: LearningCapabilities
}
