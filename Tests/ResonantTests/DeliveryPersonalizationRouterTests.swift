import AppKit
import ApplicationServices
import Foundation
import XCTest
@testable import Resonant

@MainActor
final class DeliveryPersonalizationRouterTests: XCTestCase {
    func testRequestedSendFailureAfterPasteIsExcludedAndUsesOnlyRawHabitCapability() async {
        let spy = RouterSpy()
        spy.registrationResult = .insertedTerminal(.excludedAutoSent)
        let router = makeRouter(spy: spy)
        let outcome = deliveryOutcome(delivered: true, sent: false)

        let result = await router.route(request(
            outcome: outcome,
            autoPasteRequested: true,
            autoSendRequested: true,
            rawTranscript: "  raw words  ",
            confidence: highConfidence(),
            qualityTrace: qualityTrace()
        ))

        XCTAssertEqual(result.classification, .terminalExcluded(.excludedAutoSent))
        XCTAssertFalse(result.capabilities.allowsCorrectionDerivedMutations)
        XCTAssertTrue(result.capabilities.allowsRawTranscriptHabits)
        XCTAssertEqual(spy.receiptObservations.count, 0)
        XCTAssertEqual(spy.snapshotObservations.count, 0)
        XCTAssertEqual(spy.rawHabitRequests.map(\.rawTranscript), ["  raw words  "])
        XCTAssertEqual(spy.qualityStatuses, [.autoSent])
        XCTAssertEqual(spy.registrations.first?.routeFacts.autoSent, true)
        XCTAssertEqual(spy.registrations.first?.routeFacts.autoPasted, true)
    }

    func testEveryExcludedBranchAndTwoCapabilityLessPastePathsProduceOneTerminalRowEach() async throws {
        try await withOutcomeStore { outcomeStore in
            var snapshotRequests: [DeliverySnapshotObservationRequest] = []
            let router = DeliveryPersonalizationRouter(dependencies: .init(
                registerOutcome: { await outcomeStore.register($0) },
                observeReceipt: { _ in XCTFail("No receipt path expected") },
                observeSnapshot: { request in
                    snapshotRequests.append(request)
                    let status: PersonalizationOutcomeStatus =
                        request.deliveryOutcome.deliveryAttribution == nil
                            ? .insufficientIdentity
                            : .accepted
                    _ = await outcomeStore.finalize(
                        attemptID: request.deliveryOutcome.deliveryAttemptID,
                        with: status == .accepted
                            ? .accepted(readbackMethod: .attributedSnapshot)
                            : .unobservable(status, readbackMethod: .attributedSnapshot)
                    )
                    return status == .accepted
                },
                recordRawTranscriptHabit: { _ in },
                recordTerminalQuality: { _, _ in },
                cancelObserverAndWait: {},
                quiesceOutcomeStore: { await outcomeStore.quiesceForWorkspaceClear() },
                completeOutcomeStoreClear: { await outcomeStore.completeWorkspaceClear() },
                resumeOutcomeStoreAfterClear: { await outcomeStore.resumeAfterWorkspaceClear() }
            ))

            let routes = [
                request(
                    outcome: deliveryOutcome(delivered: false),
                    autoPasteRequested: true
                ),
                request(
                    outcome: deliveryOutcome(delivered: false, partiallyDelivered: true),
                    autoPasteRequested: true
                ),
                request(
                    outcome: deliveryOutcome(delivered: true),
                    autoPasteRequested: false,
                    copiedToClipboard: true
                ),
                request(
                    outcome: deliveryOutcome(delivered: true, sent: false),
                    autoPasteRequested: true,
                    autoSendRequested: true
                ),
                request(
                    outcome: deliveryOutcome(delivered: true),
                    autoPasteRequested: true,
                    selectionTransformUsed: true,
                    confidence: highConfidence()
                ),
                // Hot mic and feed retry currently have no retained confidence
                // proof. They still enter the local population and readback,
                // but must carry `.none` into every mutation sink.
                request(
                    outcome: deliveryOutcome(delivered: true),
                    autoPasteRequested: true,
                    confidence: nil
                ),
                request(
                    outcome: deliveryOutcome(delivered: true),
                    autoPasteRequested: true,
                    confidence: nil
                ),
            ]

            var routeResults: [DeliveryPersonalizationRoutingResult] = []
            for route in routes {
                routeResults.append(await router.route(route))
            }

            let records = await outcomeStore.records()
            XCTAssertEqual(records.count, routes.count)
            XCTAssertTrue(records.allSatisfy { $0.status != .pending })
            XCTAssertEqual(
                Set(records.map(\.status)),
                Set([
                    .excludedDeliveryFailed,
                    .excludedPartialDelivery,
                    .excludedCopyOnly,
                    .excludedAutoSent,
                    .excludedSelectionTransform,
                    .insufficientIdentity,
                ])
            )
            XCTAssertEqual(snapshotRequests.count, 2)
            XCTAssertTrue(snapshotRequests.allSatisfy { $0.capabilities == .none })

            let duplicateResult = await router.route(routes.last!)
            XCTAssertEqual(duplicateResult.registrationResult, .alreadyRegistered)
            let recordsAfterDuplicate = await outcomeStore.records()
            XCTAssertEqual(recordsAfterDuplicate.count, routes.count)
            XCTAssertEqual(snapshotRequests.count, 2, "duplicate IDs must not restart readback")
            XCTAssertEqual(routeResults.count, routes.count)
        }
    }

    func testReceiptRouteCarriesPolicyCapabilitiesFinalExposureAndOriginalAttemptID() async {
        let spy = RouterSpy()
        spy.registrationResult = .insertedPending
        let router = makeRouter(spy: spy)
        let attemptID = UUID()
        let receipt = makeReceipt()
        let exposure = ContextPersonalizationExposure(
            policyVersion: 2,
            configuredHoldoutRate: 0,
            assignedVariant: .personalized,
            personalizationOpportunity: true,
            packetEntityOfferedCount: 2,
            packetStyleOffered: true,
            localLearnedEntityConsideredCount: 2,
            localLearnedEntityMatchedCount: 1,
            localLearnedEntityAppliedCount: 1,
            cloudLearnedEntitySubmittedCount: 1,
            cloudLearnedStyleSubmitted: true
        )
        let packet = contextPacket(exposure: exposure)
        let policy = AppliedStylePolicy(
            openingCase: .lowercase,
            trailingPeriod: .omit
        )
        let outcome = deliveryOutcome(
            delivered: true,
            receipt: receipt,
            attemptID: attemptID
        )

        let result = await router.route(request(
            outcome: outcome,
            autoPasteRequested: true,
            contextPacket: packet,
            personalizationExposure: exposure,
            rawTranscript: "raw source",
            confidence: highConfidence(),
            qualityTrace: qualityTrace(),
            appliedStylePolicy: policy
        ))

        XCTAssertEqual(result.registrationResult, .insertedPending)
        XCTAssertEqual(spy.registrations.map(\.deliveryAttemptID), [attemptID])
        XCTAssertEqual(spy.registrations.first?.readbackMethod, .retainedReceipt)
        XCTAssertEqual(spy.registrations.first?.exposure.packetEntityOfferedCount, 2)
        XCTAssertEqual(spy.registrations.first?.exposure.localLearnedEntityAppliedCount, 1)
        XCTAssertEqual(spy.registrations.first?.exposure.cloudLearnedEntitySubmittedCount, 1)
        XCTAssertTrue(spy.registrations.first?.exposure.personalizationApplied == true)
        XCTAssertEqual(spy.receiptObservations.count, 1)
        XCTAssertEqual(spy.receiptObservations.first?.deliveryAttemptID, attemptID)
        XCTAssertEqual(
            spy.receiptObservations.first?.deliveryAttribution,
            outcome.deliveryAttribution
        )
        XCTAssertEqual(spy.receiptObservations.first?.appliedStylePolicy, policy)
        XCTAssertTrue(
            spy.receiptObservations.first?.capabilities.allowsCorrectionDerivedMutations == true
        )
        XCTAssertEqual(
            spy.receiptObservations.first?.qualityTrace?.contextPersonalization,
            exposure
        )
        XCTAssertTrue(spy.snapshotObservations.isEmpty)
    }

    func testRouterNeverInfersExposureFromPacketMembership() async {
        let spy = RouterSpy()
        spy.registrationResult = .insertedPending
        let router = makeRouter(spy: spy)
        let packetExposure = ContextPersonalizationExposure(
            assignedVariant: .personalized,
            personalizationOpportunity: true,
            packetEntityOfferedCount: 40,
            packetStyleOffered: true
        )

        _ = await router.route(request(
            outcome: deliveryOutcome(delivered: true, receipt: makeReceipt()),
            autoPasteRequested: true,
            contextPacket: contextPacket(exposure: packetExposure),
            personalizationExposure: nil,
            qualityTrace: qualityTrace()
        ))

        XCTAssertEqual(
            spy.registrations.first?.exposure,
            PersonalizationOutcomeExposure.none
        )
        XCTAssertNil(spy.receiptObservations.first?.qualityTrace?.contextPersonalization)
    }

    func testFortyOfferedNoMatchCloudOffPersistsAndEmitsExactFinalRecord() async throws {
        let spy = RouterSpy()
        spy.registrationResult = .insertedPending
        let router = makeRouter(spy: spy)
        let packetExposure = ContextPersonalizationExposure(
            assignedVariant: .personalized,
            personalizationOpportunity: true,
            packetEntityOfferedCount: 40
        )
        let finalExposure = packetExposure.recordingConsumers(
            localRepair: ContextualEntityRepairProvenance(
                learnedEntityConsideredCount: 16,
                learnedEntityMatchedCount: 0,
                learnedEntityAppliedCount: 0
            ),
            cloudSubmission: .none
        )

        _ = await router.route(request(
            outcome: deliveryOutcome(delivered: true, receipt: makeReceipt()),
            autoPasteRequested: true,
            contextPacket: contextPacket(exposure: packetExposure),
            personalizationExposure: finalExposure,
            qualityTrace: qualityTrace()
        ))

        let persisted = try XCTUnwrap(spy.registrations.first?.exposure)
        let emitted = try XCTUnwrap(
            spy.receiptObservations.first?.qualityTrace?.contextPersonalization
        )
        XCTAssertEqual(persisted.packetEntityOfferedCount, 40)
        XCTAssertEqual(persisted.localLearnedEntityAppliedCount, 0)
        XCTAssertEqual(persisted.cloudLearnedEntitySubmittedCount, 0)
        XCTAssertFalse(persisted.personalizationApplied)
        XCTAssertEqual(emitted, finalExposure)
        let properties = DictationQualityPipeline.contextPersonalizationProperties(
            exposure: emitted
        )
        XCTAssertEqual(properties["context_personalization_packet_entity_offered_count"] as? Int, 40)
        XCTAssertEqual(properties["context_personalization_local_entity_applied_count"] as? Int, 0)
        XCTAssertEqual(properties["context_personalization_cloud_entity_submitted_count"] as? Int, 0)
        XCTAssertEqual(properties["context_personalization_applied"] as? Bool, false)
    }

    func testMissingEvidenceStillStartsNoReceiptReadbackWithNoCapabilities() async {
        let spy = RouterSpy()
        spy.registrationResult = .insertedPending
        let router = makeRouter(spy: spy)
        let outcome = deliveryOutcome(delivered: true)

        let result = await router.route(request(
            outcome: outcome,
            autoPasteRequested: true,
            confidence: nil
        ))

        XCTAssertEqual(result.classification, .pendingEligible)
        XCTAssertEqual(result.capabilities, .none)
        XCTAssertEqual(spy.snapshotObservations.count, 1)
        XCTAssertNil(spy.snapshotObservations.first?.deliveryOutcome.deliveryAttribution)
        XCTAssertEqual(
            spy.snapshotObservations.first?.capabilities,
            LearningCapabilities.none
        )
    }

    func testObserverOutcomeMappingIsExhaustiveAndPreservesBoundedCorrectionData() {
        let cases: [(CorrectionObservationStatus, PersonalizationOutcomeStatus)] = [
            (.accepted, .accepted),
            (.corrected, .corrected),
            (.stale, .stale),
            (.noFieldContent, .noFieldContent),
            (.baselineUnavailable, .baselineUnavailable),
            (.processMismatch, .processMismatch),
            (.targetMismatch, .targetMismatch),
            (.sensitiveTarget, .sensitiveTarget),
            (.insufficientIdentity, .insufficientIdentity),
            (.regionUnattributable, .regionUnattributable),
            (.targetNormalizedOrUnattributable, .targetNormalizedOrUnattributable),
            (.observationReplaced, .observationReplaced),
            (.observationCancelled, .observationCancelled),
        ]

        for (status, expected) in cases {
            let finalization = DeliveryPersonalizationRouter.finalization(for:
                CorrectionObservationOutcome(
                    deliveryAttemptID: UUID(),
                    status: status,
                    readbackMethod: .correctionHotSnapshot,
                    capabilities: .none,
                    editDistanceBucket: .upToTwentyPercent,
                    correctionCount: 3
                )
            )
            XCTAssertEqual(finalization.status, expected, "status: \(status)")
            XCTAssertEqual(finalization.readbackMethod, .attributedSnapshot)
            if status == .corrected {
                XCTAssertEqual(finalization.editDistanceBucket, .upToTwentyPercent)
                XCTAssertEqual(finalization.correctionCount, 3)
            }
        }

        let receipt = CorrectionObservationOutcome(
            deliveryAttemptID: UUID(),
            status: .accepted,
            readbackMethod: .receipt,
            capabilities: .none,
            editDistanceBucket: .none,
            correctionCount: 0
        )
        let unavailable = CorrectionObservationOutcome(
            deliveryAttemptID: UUID(),
            status: .baselineUnavailable,
            readbackMethod: .none,
            capabilities: .none,
            editDistanceBucket: .unavailable,
            correctionCount: nil
        )
        XCTAssertEqual(
            DeliveryPersonalizationRouter.finalization(for: receipt).readbackMethod,
            .retainedReceipt
        )
        XCTAssertEqual(
            DeliveryPersonalizationRouter.finalization(for: unavailable).readbackMethod,
            .unavailable
        )
    }

    func testWorkspaceClearLifecycleOrdersObserverBeforeStoreAndResumesEveryAbort() async {
        let spy = RouterSpy()
        let router = makeRouter(spy: spy)

        await router.quiesceForWorkspaceClear()
        XCTAssertTrue(router.isRouteAdmissionSuspendedForTesting)
        await router.resumeAfterWorkspaceClear()
        XCTAssertFalse(router.isRouteAdmissionSuspendedForTesting)
        XCTAssertEqual(spy.lifecycleEvents, ["observer_cancel", "store_quiesce", "store_resume"])

        spy.lifecycleEvents.removeAll()
        await router.quiesceForWorkspaceClear()
        XCTAssertTrue(router.isRouteAdmissionSuspendedForTesting)
        await router.completeWorkspaceClear()
        XCTAssertTrue(router.isRouteAdmissionSuspendedForTesting)
        let postClearBeforeRuntimeResume = await router.route(request(
            outcome: deliveryOutcome(delivered: true),
            autoPasteRequested: true
        ))
        XCTAssertEqual(postClearBeforeRuntimeResume.registrationResult, .suspended)
        XCTAssertTrue(spy.registrations.isEmpty)
        await router.resumeAfterWorkspaceClear()
        XCTAssertFalse(router.isRouteAdmissionSuspendedForTesting)
        XCTAssertEqual(
            spy.lifecycleEvents,
            ["observer_cancel", "store_quiesce", "store_complete", "store_resume"]
        )
    }

    func testWorkspaceClearSuspendsAdmissionAndDrainsAnActiveRouteBeforeObserver() async {
        let blocker = BlockingRegistration()
        let spy = RouterSpy()
        let router = DeliveryPersonalizationRouter(dependencies: .init(
            registerOutcome: { registration in
                await blocker.register(registration)
            },
            observeReceipt: { spy.receiptObservations.append($0) },
            observeSnapshot: {
                spy.snapshotObservations.append($0)
                return true
            },
            recordRawTranscriptHabit: { spy.rawHabitRequests.append($0) },
            recordTerminalQuality: { _, status in spy.qualityStatuses.append(status) },
            cancelObserverAndWait: { spy.lifecycleEvents.append("observer_cancel") },
            quiesceOutcomeStore: { spy.lifecycleEvents.append("store_quiesce") },
            completeOutcomeStoreClear: { spy.lifecycleEvents.append("store_complete") },
            resumeOutcomeStoreAfterClear: { spy.lifecycleEvents.append("store_resume") }
        ))
        let admittedRequest = request(
            outcome: deliveryOutcome(delivered: true),
            autoPasteRequested: true,
            confidence: nil
        )
        let admittedRoute = Task { @MainActor in
            await router.route(admittedRequest)
        }
        await blocker.waitUntilEntered()

        let quiescence = Task { @MainActor in
            await router.quiesceForWorkspaceClear()
        }
        await router.waitUntilRouteAdmissionSuspendedForTesting()
        XCTAssertTrue(router.isRouteAdmissionSuspendedForTesting)

        let rejected = await router.route(request(
            outcome: deliveryOutcome(delivered: true),
            autoPasteRequested: true,
            confidence: nil
        ))
        XCTAssertEqual(rejected.registrationResult, .suspended)
        XCTAssertEqual(blocker.registrations.count, 1)
        XCTAssertTrue(spy.receiptObservations.isEmpty)
        XCTAssertTrue(spy.snapshotObservations.isEmpty)
        XCTAssertTrue(spy.rawHabitRequests.isEmpty)
        XCTAssertTrue(spy.qualityStatuses.isEmpty)
        XCTAssertTrue(spy.lifecycleEvents.isEmpty)

        blocker.release()
        let admitted = await admittedRoute.value
        await quiescence.value

        XCTAssertEqual(admitted.registrationResult, .insertedPending)
        XCTAssertEqual(spy.snapshotObservations.count, 1)
        XCTAssertEqual(spy.lifecycleEvents, ["observer_cancel", "store_quiesce"])
    }

    func testTwoVocabularyOutcomesEmitTwoUnitEventsInAwaitedOrder() async {
        let collector = VocabularyOutcomeCollector()
        let recorder = VocabularyBoostAttemptRecorder(onOutcome: { outcome in
            await collector.record(outcome)
        })
        let outcomes: [VocabularyBoostAttemptOutcome] = [
            .skipped(.unsupportedAdapter),
            .attempted(result: .applied, language: .explicitEnglish),
        ]

        for outcome in outcomes {
            await recorder.record(outcome)
        }

        let captured = await collector.values
        XCTAssertEqual(captured, outcomes)
        let properties = captured.map {
            VocabularyBoostAttemptTelemetry.properties(for: $0)
        }
        XCTAssertEqual(properties.compactMap { $0["attempt_total_count"] as? Int }, [1, 1])
        XCTAssertEqual(
            properties.reduce(0) { $0 + ($1["attempt_total_count"] as? Int ?? 0) },
            2
        )
    }

    func testAppStateRoutesAllThreeDirectDeliveriesBeforeEarlyReturnsAndOwnsClearLifecycle() throws {
        let sourceURL = repositoryRoot()
            .appendingPathComponent("Sources/Resonant/App/AppState.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let setupCoordinatorURL = repositoryRoot()
            .appendingPathComponent(
                "Sources/Resonant/Features/Personalization/PersonalizationOutcomeSetupCoordinator.swift"
            )
        let setupCoordinatorSource = try String(
            contentsOf: setupCoordinatorURL,
            encoding: .utf8
        )

        XCTAssertEqual(occurrenceCount("deliverWithOutcome(", in: source), 3)
        XCTAssertEqual(
            occurrenceCount("deliveryPersonalizationRouter.route(", in: source),
            3
        )

        let hotMic = try methodSlice(
            source,
            from: "private func handleHotMicPaste",
            to: "// MARK: - Dispatch"
        )
        assertRouteAfterDelivery(hotMic, before: "let delivered =")

        let retry = try methodSlice(
            source,
            from: "func retryLastDictation() async",
            to: "func saveFeedItemAsMemo"
        )
        assertRouteAfterDelivery(retry, before: "let delivered =")

        let normal = try methodSlice(
            source,
            from: "private func handleResult(",
            to: "private func dictationQualityTrace("
        )
        assertRouteAfterDelivery(normal, before: "let textWasDelivered =")

        let clear = try methodSlice(
            source,
            from: "func clearWorkspace() async",
            to: "private func quiesceCaptureForWorkspaceClear"
        )
        let quiesce = try XCTUnwrap(clear.range(
            of: "deliveryPersonalizationRouter.quiesceForWorkspaceClear()"
        ))
        let setupQuiesce = try XCTUnwrap(clear.range(
            of: "personalizationOutcomeSetupCoordinator.quiesceForWorkspaceClear()"
        ))
        let centralDelete = try XCTUnwrap(clear.range(of: "dataStore.clearWorkspaceData()"))
        let complete = try XCTUnwrap(clear.range(
            of: "deliveryPersonalizationRouter.completeWorkspaceClear()"
        ))
        let resume = try XCTUnwrap(clear.range(
            of: "deliveryPersonalizationRouter.resumeAfterWorkspaceClear()"
        ))
        let setupResume = try XCTUnwrap(clear.range(
            of: "personalizationOutcomeSetupCoordinator.resumeAfterWorkspaceClear()"
        ))
        let abortBranch = try XCTUnwrap(clear.range(of: "if abortWorkspaceBoundary"))
        XCTAssertLessThan(setupQuiesce.lowerBound, quiesce.lowerBound)
        XCTAssertLessThan(quiesce.lowerBound, centralDelete.lowerBound)
        XCTAssertLessThan(centralDelete.lowerBound, complete.lowerBound)
        XCTAssertLessThan(complete.lowerBound, resume.lowerBound)
        XCTAssertLessThan(resume.lowerBound, setupResume.lowerBound)
        XCTAssertLessThan(setupResume.lowerBound, abortBranch.lowerBound)
        XCTAssertEqual(
            occurrenceCount("let personalizationOutcomeStore =", in: source),
            1
        )
        XCTAssertTrue(source.contains(
            "personalizationOutcomeSetupCoordinator = PersonalizationOutcomeSetupCoordinator("
        ))
        XCTAssertTrue(source.contains(
            "await personalizationOutcomeSetupCoordinator.setupOrRetry()"
        ))
        let dataStoreSetup = try XCTUnwrap(source.range(
            of: "await dataStore.setup()"
        ))
        let memoryStoreSetup = try XCTUnwrap(source.range(
            of: "personalizationMemoryStore.setup(store: dataStore)"
        ))
        let outcomeCoordinatorSetup = try XCTUnwrap(source.range(
            of: "await personalizationOutcomeSetupCoordinator.setupOrRetry()"
        ))
        XCTAssertLessThan(dataStoreSetup.lowerBound, memoryStoreSetup.lowerBound)
        XCTAssertLessThan(memoryStoreSetup.lowerBound, outcomeCoordinatorSetup.lowerBound)
        XCTAssertTrue(setupCoordinatorSource.contains(
            "await outcomeStore.setup(dataStore: dataStore)"
        ))
        XCTAssertTrue(setupCoordinatorSource.contains(
            "controlDataSource.attachOutcomeSummaryProvider { [outcomeStore] in"
        ))
        XCTAssertTrue(setupCoordinatorSource.contains(
            "await outcomeStore.summary()"
        ))
    }

    // MARK: - Fixtures

    private func makeRouter(spy: RouterSpy) -> DeliveryPersonalizationRouter {
        DeliveryPersonalizationRouter(dependencies: .init(
            registerOutcome: { registration in
                spy.registrations.append(registration)
                return spy.registrationResult
            },
            observeReceipt: { spy.receiptObservations.append($0) },
            observeSnapshot: {
                spy.snapshotObservations.append($0)
                return spy.snapshotResult
            },
            recordRawTranscriptHabit: { spy.rawHabitRequests.append($0) },
            recordTerminalQuality: { _, status in spy.qualityStatuses.append(status) },
            cancelObserverAndWait: { spy.lifecycleEvents.append("observer_cancel") },
            quiesceOutcomeStore: { spy.lifecycleEvents.append("store_quiesce") },
            completeOutcomeStoreClear: { spy.lifecycleEvents.append("store_complete") },
            resumeOutcomeStoreAfterClear: { spy.lifecycleEvents.append("store_resume") }
        ))
    }

    private func request(
        outcome: PasteManager.DeliveryOutcome,
        autoPasteRequested: Bool,
        autoSendRequested: Bool = false,
        copiedToClipboard: Bool = false,
        selectionTransformUsed: Bool = false,
        contextPacket: ContextPacket? = nil,
        personalizationExposure: ContextPersonalizationExposure? = nil,
        rawTranscript: String? = nil,
        confidence: DictationConfidenceSnapshot? = nil,
        qualityTrace: DictationQualityTrace? = nil,
        appliedStylePolicy: AppliedStylePolicy = .none
    ) -> DeliveryPersonalizationRequest {
        DeliveryPersonalizationRequest(
            deliveryOutcome: outcome,
            autoPasteRequested: autoPasteRequested,
            autoSendRequested: autoSendRequested,
            copiedToClipboard: copiedToClipboard,
            selectionTransformUsed: selectionTransformUsed,
            targetApplication: nil,
            surface: contextPacket?.surface ?? surface(),
            windowTitle: "General",
            browserURL: nil,
            rawTranscript: rawTranscript,
            contextPacket: contextPacket,
            personalizationExposure: personalizationExposure,
            qualityTrace: qualityTrace,
            boostAudit: nil,
            confidence: confidence,
            appliedStylePolicy: appliedStylePolicy
        )
    }

    private func deliveryOutcome(
        delivered: Bool,
        sent: Bool = false,
        partiallyDelivered: Bool = false,
        receipt: PasteManager.DeliveryReceipt? = nil,
        attemptID: UUID = UUID()
    ) -> PasteManager.DeliveryOutcome {
        let attribution = receipt.flatMap { receipt in
            PasteManager.makeDeliveryAttribution(
                targetProcessIdentifier: receipt.targetProcessIdentifier,
                targetBundleIdentifier: receipt.targetBundleIdentifier,
                targetFingerprint: ContextTargetFingerprint(
                    role: "AXTextArea",
                    subrole: "AXStandardTextArea",
                    isSensitiveInput: false,
                    identifierToken: "composer",
                    titleToken: "message",
                    descriptionToken: "message composer",
                    placeholderToken: nil,
                    helpToken: "compose",
                    frameBucket: "1:2:3:4",
                    selectedRangeBucket: "0:0"
                ),
                anchor: receipt.anchor,
                preDeliveryFieldUTF16Length: 0
            )
        }
        return PasteManager.DeliveryOutcome(
            delivered: delivered,
            sent: sent,
            partiallyDelivered: partiallyDelivered,
            receipt: receipt,
            targetProcessIdentifier: 42,
            targetBundleIdentifier: "com.tinyspeck.slackmacgap",
            deliveryAttemptID: attemptID,
            requestedText: "hello",
            effectiveInsertedText: delivered ? "hello" : nil,
            targetObservedSettledText: receipt?.targetObservedInsertedText,
            deliveryAttribution: attribution
        )
    }

    private func makeReceipt() -> PasteManager.DeliveryReceipt {
        PasteManager.DeliveryReceipt(
            targetProcessIdentifier: 42,
            targetBundleIdentifier: "com.tinyspeck.slackmacgap",
            targetObservedInsertedText: "hello",
            anchor: PasteManager.UTF16InsertionAnchor(
                replacedRange: SelectionRange(location: 0, length: 0),
                prefix: "",
                suffix: ""
            ),
            element: AXUIElementCreateSystemWide(),
            windowTitle: "General",
            browserURL: nil
        )
    }

    private func highConfidence() -> DictationConfidenceSnapshot {
        DictationConfidenceSnapshot(
            schemaVersion: DictationConfidenceSnapshot.schemaVersion,
            overall: DictationConfidenceScore(0.99),
            recognition: DictationConfidenceScore(0.99),
            rewrite: DictationConfidenceScore(0.99),
            delivery: DictationConfidenceScore(0.99),
            learningEligible: true,
            rawTranscriptHabitEligible: true,
            learningCapabilities: [
                .correctionDerivedMutations,
                .rawTranscriptHabits,
            ],
            autoSendEligible: true,
            reasons: [],
            voicedRatioBucket: nil,
            wordsPerSecondBucket: nil,
            segmentRecoveryAttempted: nil,
            segmentRecoveryUsed: nil,
            segmenterSource: nil,
            postProcessingChanged: nil,
            postProcessingChangedStageCount: nil,
            postProcessingChangedStages: nil
        )
    }

    private func surface() -> SurfaceDescriptor {
        SurfaceDescriptor(
            kind: .chat,
            appName: "Slack",
            bundleId: "com.tinyspeck.slackmacgap",
            windowTitle: "General",
            browserURL: nil,
            siteHost: nil,
            siteName: nil,
            fieldKind: .compose,
            conversationLabel: nil,
            documentLabel: nil,
            projectLabel: nil
        )
    }

    private func contextPacket(
        exposure: ContextPersonalizationExposure
    ) -> ContextPacket {
        ContextPacket(
            id: UUID(),
            capturedAt: Date(),
            surface: surface(),
            intent: DictationIntent(
                kind: .plainDictation,
                confidence: 1,
                allowsBiasTerms: true,
                allowsStyleHint: true,
                allowsSelectedTextGrounding: true,
                allowsVisibleContextGrounding: true,
                allowsMemoryGrounding: true,
                evidence: []
            ),
            entities: [],
            styleHint: nil,
            personalizationExposure: exposure,
            selectedTextPreview: nil,
            focusedFieldPreview: nil,
            visibleGroundingSnippets: [],
            safetyFlags: [],
            latency: .empty
        )
    }

    private func qualityTrace() -> DictationQualityTrace {
        DictationQualityTrace(
            dictationID: nil,
            mode: "dictation",
            model: nil,
            targetBundleId: "com.tinyspeck.slackmacgap",
            surfaceKind: SurfaceKind.chat.rawValue,
            pasteDeliveryMode: "automatic",
            autoPaste: true,
            autoSend: false,
            copyToClipboard: false,
            cloudProcessingEnabled: false,
            lowLatencyMode: false,
            selectionTransformUsed: false,
            cleanup: .notApplicable,
            transform: .notApplicable,
            confidence: nil,
            boostCounts: .zero,
            latencies: .init(event: nil)
        )
    }

    private func withOutcomeStore(
        _ body: (PersonalizationOutcomeStore) async throws -> Void
    ) async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeliveryRouter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let dataStore = Resonant.DataStore(
            storeURLOverride: directoryURL.appendingPathComponent("Resonant.store")
        )
        await dataStore.setup()
        XCTAssertTrue(dataStore.isReady)
        let outcomeStore = PersonalizationOutcomeStore()
        let setup = await outcomeStore.setup(dataStore: dataStore)
        XCTAssertTrue(setup.succeeded)

        do {
            try await body(outcomeStore)
            await outcomeStore.quiesceForWorkspaceClear()
            try? FileManager.default.removeItem(at: directoryURL)
        } catch {
            await outcomeStore.quiesceForWorkspaceClear()
            try? FileManager.default.removeItem(at: directoryURL)
            throw error
        }
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func occurrenceCount(_ needle: String, in value: String) -> Int {
        value.components(separatedBy: needle).count - 1
    }

    private func methodSlice(
        _ source: String,
        from startMarker: String,
        to endMarker: String
    ) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker))
        let end = try XCTUnwrap(source.range(
            of: endMarker,
            range: start.upperBound..<source.endIndex
        ))
        return String(source[start.lowerBound..<end.lowerBound])
    }

    private func assertRouteAfterDelivery(
        _ source: String,
        before earlyBoundary: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let delivery = source.range(of: "deliverWithOutcome(")
        let route = source.range(of: "deliveryPersonalizationRouter.route(")
        let boundary = source.range(of: earlyBoundary)
        XCTAssertNotNil(delivery, file: file, line: line)
        XCTAssertNotNil(route, file: file, line: line)
        XCTAssertNotNil(boundary, file: file, line: line)
        if let delivery, let route, let boundary {
            XCTAssertLessThan(delivery.lowerBound, route.lowerBound, file: file, line: line)
            XCTAssertLessThan(route.lowerBound, boundary.lowerBound, file: file, line: line)
        }
    }
}

@MainActor
private final class RouterSpy {
    var registrationResult: PersonalizationOutcomeRegistrationResult = .insertedPending
    var snapshotResult = true
    var registrations: [PersonalizationOutcomeRegistration] = []
    var receiptObservations: [DeliveryReceiptObservationRequest] = []
    var snapshotObservations: [DeliverySnapshotObservationRequest] = []
    var rawHabitRequests: [RawTranscriptHabitFeedbackRequest] = []
    var qualityStatuses: [DictationQualityReadbackStatus] = []
    var lifecycleEvents: [String] = []
}

@MainActor
private final class BlockingRegistration {
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private(set) var registrations: [PersonalizationOutcomeRegistration] = []

    func register(
        _ registration: PersonalizationOutcomeRegistration
    ) async -> PersonalizationOutcomeRegistrationResult {
        registrations.append(registration)
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if registrations.count == 1 {
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }
        return .insertedPending
    }

    func waitUntilEntered() async {
        guard registrations.isEmpty else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor VocabularyOutcomeCollector {
    private(set) var values: [VocabularyBoostAttemptOutcome] = []

    func record(_ outcome: VocabularyBoostAttemptOutcome) {
        values.append(outcome)
    }
}
