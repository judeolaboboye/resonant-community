import Darwin
import XCTest
@testable import Resonant

@MainActor
final class CorrectionReadbackAttributionTests: XCTestCase {
    private final class SnapshotProvider: AmbientFieldContentProviding {
        var snapshot: CorrectionHotSnapshot?
        private(set) var requestCount = 0

        init(snapshot: CorrectionHotSnapshot?) {
            self.snapshot = snapshot
        }

        func correctionHotSnapshot(
            for app: NSRunningApplication?
        ) async -> CorrectionHotSnapshot? {
            requestCount += 1
            return snapshot
        }
    }

    private final class RecordingLearningEngine: PersonalizationLearningEngine {
        private(set) var events: [DictationFeedbackEvent] = []

        func snapshot(for surface: SurfaceDescriptor) -> PersonalizationMemorySnapshot {
            .empty
        }

        func profile(for surface: SurfaceDescriptor) -> VersionedPersonalizationProfile {
            PersonalizationProfileBuilder.build(
                surface: surface,
                snapshot: .empty,
                styleSampleCount: 0,
                seed: "correction-readback-attribution",
                holdoutRate: 0
            )
        }

        func recordFeedback(_ event: DictationFeedbackEvent) async {
            events.append(event)
        }
    }

    private struct DeliveryFixture {
        let outcome: PasteManager.DeliveryOutcome
        let attribution: PasteManager.DeliveryAttribution
        let postDeliveryField: String
    }

    private struct ReceiptFixture {
        let receipt: PasteManager.DeliveryReceipt
        let attribution: PasteManager.DeliveryAttribution
        let postDeliveryField: String
    }

    func testMatchingNoReceiptSnapshotsLearnAndCarryOutcomeMetadata() async throws {
        let fixture = try makeSelectionDelivery(
            baseline: "prefix old suffix",
            selectedText: "old",
            effectiveText: "ask jon smythe"
        )
        let provider = SnapshotProvider(snapshot: snapshot(
            content: fixture.postDeliveryField,
            fingerprint: fingerprint(selectedRange: "4:0")
        ))
        let learning = RecordingLearningEngine()
        var qualityStatuses: [DictationQualityReadbackStatus] = []
        var outcomes: [CorrectionObservationOutcome] = []
        let observer = CorrectionObserver(
            dictionaryStore: DictionaryStore(),
            pasteManager: PasteManager(),
            personalizationLearningEngine: learning,
            qualityRecorder: { _, status, _, _, _, _ in qualityStatuses.append(status) },
            outcomeRecorder: { outcome in
                outcomes.append(outcome)
                return .finalized
            }
        )
        observer.ambientFieldContentProvider = provider

        let started = await observer.observe(
            deliveryOutcome: fixture.outcome,
            targetApp: nil,
            rawTranscript: "ask jon smythe",
            capabilities: .correctionDerivedMutations,
            appliedStylePolicy: AppliedStylePolicy(openingCase: .lowercase)
        )
        XCTAssertTrue(started)
        provider.snapshot = snapshot(
            content: "prefix ask John Smythe suffix",
            fingerprint: fingerprint(selectedRange: "8:0")
        )
        await observer.flushBeforeDictation()

        XCTAssertEqual(qualityStatuses, [.corrected])
        XCTAssertEqual(outcomes.map(\.status), [.corrected])
        XCTAssertEqual(outcomes.first?.deliveryAttemptID, fixture.outcome.deliveryAttemptID)
        XCTAssertEqual(outcomes.first?.readbackMethod, .correctionHotSnapshot)
        XCTAssertEqual(outcomes.first?.capabilities, .correctionDerivedMutations)
        XCTAssertEqual(
            outcomes.first?.editDistanceBucket,
            PersonalizationEditDistanceBucket.classify(
                PersonalizationEvaluationEngine.normalizedEditDistance(
                    from: "ask jon smythe",
                    to: "ask John Smythe"
                )
            )
        )
        XCTAssertEqual(learning.events.first?.editedText, "ask John Smythe")
        XCTAssertEqual(learning.events.first?.capabilities, .correctionDerivedMutations)
        XCTAssertEqual(
            learning.events.first?.appliedStylePolicy,
            AppliedStylePolicy(openingCase: .lowercase)
        )
        XCTAssertEqual(provider.requestCount, 2)
    }

    func testNoReceiptRejectsProcessMismatchBeforeObservationStarts() async throws {
        let fixture = try makeWholeFieldDelivery(effectiveText: "hello")
        let provider = SnapshotProvider(snapshot: snapshot(
            content: "hello",
            processIdentifier: 99
        ))
        var outcomes: [CorrectionObservationOutcome] = []
        let observer = makeObserver { outcome in
            outcomes.append(outcome)
            return .finalized
        }
        observer.ambientFieldContentProvider = provider

        let started = await observer.observe(
            deliveryOutcome: fixture.outcome,
            targetApp: nil,
            capabilities: .correctionDerivedMutations,
            appliedStylePolicy: .none
        )
        XCTAssertFalse(started)
        XCTAssertEqual(outcomes.map(\.status), [.processMismatch])
    }

    func testNoReceiptRejectsDifferentFocusedTarget() async throws {
        let fixture = try makeWholeFieldDelivery(effectiveText: "hello")
        let provider = SnapshotProvider(snapshot: snapshot(
            content: "hello",
            fingerprint: fingerprint(identifier: "other-field")
        ))
        var outcomes: [CorrectionObservationOutcome] = []
        let observer = makeObserver { outcome in
            outcomes.append(outcome)
            return .finalized
        }
        observer.ambientFieldContentProvider = provider

        let started = await observer.observe(
            deliveryOutcome: fixture.outcome,
            targetApp: nil,
            capabilities: .correctionDerivedMutations,
            appliedStylePolicy: .none
        )
        XCTAssertFalse(started)
        XCTAssertEqual(outcomes.map(\.status), [.targetMismatch])
    }

    func testNoReceiptRejectsSensitiveAndWeakIdentitySnapshots() async throws {
        for (observedFingerprint, expected) in [
            (fingerprint(sensitive: true), CorrectionObservationStatus.sensitiveTarget),
            (fingerprint(identifier: nil), CorrectionObservationStatus.insufficientIdentity),
        ] {
            let fixture = try makeWholeFieldDelivery(effectiveText: "hello")
            let provider = SnapshotProvider(snapshot: snapshot(
                content: "hello",
                isSensitiveInput: observedFingerprint.isSensitiveInput,
                fingerprint: observedFingerprint
            ))
            var outcomes: [CorrectionObservationOutcome] = []
            let observer = makeObserver { outcome in
                outcomes.append(outcome)
                return .finalized
            }
            observer.ambientFieldContentProvider = provider

            let started = await observer.observe(
                deliveryOutcome: fixture.outcome,
                targetApp: nil,
                capabilities: .correctionDerivedMutations,
                appliedStylePolicy: .none
            )
            XCTAssertFalse(started)
            XCTAssertEqual(outcomes.map(\.status), [expected])
        }
    }

    func testReceiptKnownSensitiveAtDeliveryFinalizesBeforePollingAndBlocksEveryMutation() async throws {
        let fixture = try makeReceiptDelivery(
            effectiveText: "ask Codex and teece",
            deliveryFingerprint: fingerprint(sensitive: true)
        )
        let dictionary = DictionaryStore()
        let learning = RecordingLearningEngine()
        var readbackCount = 0
        var qualityStatuses: [DictationQualityReadbackStatus] = []
        var outcomes: [CorrectionObservationOutcome] = []
        var formatCount = 0
        var suggestionCount = 0
        var boostCount = 0
        let observer = CorrectionObserver(
            dictionaryStore: dictionary,
            pasteManager: PasteManager(),
            personalizationLearningEngine: learning,
            receiptReadback: { _ in
                readbackCount += 1
                return self.receiptSnapshot(
                    content: "prefix ask model and Thijs suffix"
                )
            },
            qualityRecorder: { _, status, _, _, _, _ in qualityStatuses.append(status) },
            boostCorrelationRecorder: { _ in boostCount += 1 },
            outcomeRecorder: { outcome in
                outcomes.append(outcome)
                return .finalized
            }
        )
        observer.formatCorrectionSink = { _, _, _ in formatCount += 1 }
        observer.learnSuggestionSink = { _ in suggestionCount += 1 }

        await observer.observe(
            deliveryReceipt: fixture.receipt,
            deliveryAttribution: fixture.attribution,
            deliveryAttemptID: UUID(),
            capabilities: .correctionDerivedMutations,
            boostAudit: appliedCodexAudit(),
            appliedStylePolicy: AppliedStylePolicy(openingCase: .lowercase)
        )
        await observer.flushBeforeDictation()

        XCTAssertEqual(outcomes.map(\.status), [.sensitiveTarget])
        XCTAssertEqual(outcomes.map(\.capabilities), [LearningCapabilities.none])
        XCTAssertEqual(qualityStatuses, [.bypassed])
        XCTAssertEqual(readbackCount, 0, "known-sensitive delivery must not poll its receipt")
        XCTAssertEqual(formatCount, 0)
        XCTAssertEqual(suggestionCount, 0)
        XCTAssertEqual(boostCount, 0)
        XCTAssertTrue(learning.events.isEmpty)
        XCTAssertTrue(dictionary.correctionSnapshot().isEmpty)
    }

    func testReceiptThatBecomesSensitiveAtTerminalReadbackBlocksEveryMutation() async throws {
        let fixture = try makeReceiptDelivery(
            effectiveText: "ask Codex and teece",
            deliveryFingerprint: fingerprint()
        )
        let dictionary = DictionaryStore()
        let learning = RecordingLearningEngine()
        var readbackCount = 0
        var qualityStatuses: [DictationQualityReadbackStatus] = []
        var outcomes: [CorrectionObservationOutcome] = []
        var formatCount = 0
        var suggestionCount = 0
        var boostCount = 0
        let observer = CorrectionObserver(
            dictionaryStore: dictionary,
            pasteManager: PasteManager(),
            personalizationLearningEngine: learning,
            receiptReadback: { _ in
                readbackCount += 1
                return self.receiptSnapshot(
                    content: "prefix ask model and Thijs suffix",
                    sensitive: true
                )
            },
            qualityRecorder: { _, status, _, _, _, _ in qualityStatuses.append(status) },
            boostCorrelationRecorder: { _ in boostCount += 1 },
            outcomeRecorder: { outcome in
                outcomes.append(outcome)
                return .finalized
            }
        )
        observer.formatCorrectionSink = { _, _, _ in formatCount += 1 }
        observer.learnSuggestionSink = { _ in suggestionCount += 1 }

        await observer.observe(
            deliveryReceipt: fixture.receipt,
            deliveryAttribution: fixture.attribution,
            deliveryAttemptID: UUID(),
            capabilities: .correctionDerivedMutations,
            boostAudit: appliedCodexAudit(),
            appliedStylePolicy: AppliedStylePolicy(openingCase: .lowercase)
        )
        await observer.flushBeforeDictation()

        XCTAssertEqual(outcomes.map(\.status), [.sensitiveTarget])
        XCTAssertEqual(qualityStatuses, [.bypassed])
        XCTAssertEqual(readbackCount, 1)
        XCTAssertEqual(formatCount, 0)
        XCTAssertEqual(suggestionCount, 0)
        XCTAssertEqual(boostCount, 0)
        XCTAssertTrue(learning.events.isEmpty)
        XCTAssertTrue(dictionary.correctionSnapshot().isEmpty)
    }

    func testReceiptTerminalReadbackRejectsMissingAndMismatchedCurrentIdentity() async throws {
        let fixture = try makeReceiptDelivery(
            effectiveText: "ask jon smythe",
            deliveryFingerprint: fingerprint()
        )
        let content = "prefix ask John Smythe suffix"
        let cases: [(CorrectionReceiptSnapshot, CorrectionObservationStatus)] = [
            (
                CorrectionReceiptSnapshot(
                    fullFieldContent: content,
                    processIdentifier: 42,
                    bundleIdentifier: "com.example.editor",
                    isSensitiveInput: false,
                    targetFingerprint: nil
                ),
                .insufficientIdentity
            ),
            (
                CorrectionReceiptSnapshot(
                    fullFieldContent: content,
                    processIdentifier: 42,
                    bundleIdentifier: "com.example.editor",
                    isSensitiveInput: nil,
                    targetFingerprint: fingerprint(sensitive: nil)
                ),
                .insufficientIdentity
            ),
            (
                CorrectionReceiptSnapshot(
                    fullFieldContent: content,
                    processIdentifier: 42,
                    bundleIdentifier: "com.example.editor",
                    isSensitiveInput: false,
                    targetFingerprint: fingerprint(identifier: "other-field")
                ),
                .targetMismatch
            ),
            (
                CorrectionReceiptSnapshot(
                    fullFieldContent: content,
                    processIdentifier: 99,
                    bundleIdentifier: "com.example.editor",
                    isSensitiveInput: false,
                    targetFingerprint: fingerprint()
                ),
                .processMismatch
            ),
        ]

        for (snapshot, expectedStatus) in cases {
            var outcomes: [CorrectionObservationOutcome] = []
            var readbackCount = 0
            let learning = RecordingLearningEngine()
            let observer = CorrectionObserver(
                dictionaryStore: DictionaryStore(),
                pasteManager: PasteManager(),
                personalizationLearningEngine: learning,
                receiptReadback: { _ in
                    readbackCount += 1
                    return snapshot
                },
                outcomeRecorder: { outcome in
                    outcomes.append(outcome)
                    return .finalized
                }
            )

            await observer.observe(
                deliveryReceipt: fixture.receipt,
                deliveryAttribution: fixture.attribution,
                deliveryAttemptID: UUID(),
                capabilities: .correctionDerivedMutations,
                appliedStylePolicy: .none
            )
            await observer.flushBeforeDictation()

            XCTAssertEqual(outcomes.map(\.status), [expectedStatus])
            XCTAssertEqual(readbackCount, 1)
            XCTAssertTrue(learning.events.isEmpty)
        }
    }

    func testReceiptMissingIdentityOrSensitivityProofFailsClosedBeforePolling() async throws {
        let safeFixture = try makeReceiptDelivery(
            effectiveText: "hello",
            deliveryFingerprint: fingerprint()
        )
        let missingFingerprint = try makeReceiptDelivery(
            effectiveText: "hello",
            deliveryFingerprint: nil
        )
        let missingSensitivity = try makeReceiptDelivery(
            effectiveText: "hello",
            deliveryFingerprint: fingerprint(sensitive: nil)
        )
        let missingBundle = try makeReceiptDelivery(
            effectiveText: "hello",
            deliveryFingerprint: fingerprint(),
            receiptBundleIdentifier: nil
        )
        let missingProcess = try makeReceiptDelivery(
            effectiveText: "hello",
            deliveryFingerprint: fingerprint(),
            receiptProcessIdentifier: 0
        )
        let cases: [(ReceiptFixture, PasteManager.DeliveryAttribution?)] = [
            (safeFixture, nil),
            (missingFingerprint, missingFingerprint.attribution),
            (missingSensitivity, missingSensitivity.attribution),
            (missingBundle, missingBundle.attribution),
            (missingProcess, missingProcess.attribution),
        ]

        for (fixture, attribution) in cases {
            var readbackCount = 0
            var outcomes: [CorrectionObservationOutcome] = []
            var formatCount = 0
            var suggestionCount = 0
            var boostCount = 0
            let dictionary = DictionaryStore()
            let learning = RecordingLearningEngine()
            let observer = CorrectionObserver(
                dictionaryStore: dictionary,
                pasteManager: PasteManager(),
                personalizationLearningEngine: learning,
                receiptReadback: { _ in
                    readbackCount += 1
                    return self.receiptSnapshot(content: fixture.postDeliveryField)
                },
                boostCorrelationRecorder: { _ in boostCount += 1 },
                outcomeRecorder: { outcome in
                    outcomes.append(outcome)
                    return .finalized
                }
            )
            observer.formatCorrectionSink = { _, _, _ in formatCount += 1 }
            observer.learnSuggestionSink = { _ in suggestionCount += 1 }

            await observer.observe(
                deliveryReceipt: fixture.receipt,
                deliveryAttribution: attribution,
                deliveryAttemptID: UUID(),
                capabilities: .correctionDerivedMutations,
                appliedStylePolicy: .none
            )
            await observer.flushBeforeDictation()

            XCTAssertEqual(outcomes.map(\.status), [.insufficientIdentity])
            XCTAssertEqual(outcomes.map(\.capabilities), [LearningCapabilities.none])
            XCTAssertEqual(readbackCount, 0)
            XCTAssertEqual(formatCount, 0)
            XCTAssertEqual(suggestionCount, 0)
            XCTAssertEqual(boostCount, 0)
            XCTAssertTrue(learning.events.isEmpty)
            XCTAssertTrue(dictionary.correctionSnapshot().isEmpty)
        }
    }

    func testKnownSafeReceiptRevalidatesRetainedTargetAndLearnsCorrection() async throws {
        let fixture = try makeReceiptDelivery(
            effectiveText: "Codex uses grafanna daily",
            deliveryFingerprint: fingerprint()
        )
        let dictionary = DictionaryStore()
        let learning = RecordingLearningEngine()
        var readbackCount = 0
        var outcomes: [CorrectionObservationOutcome] = []
        var formatCount = 0
        var boostCount = 0
        let observer = CorrectionObserver(
            dictionaryStore: dictionary,
            pasteManager: PasteManager(),
            personalizationLearningEngine: learning,
            receiptReadback: { _ in
                readbackCount += 1
                return self.receiptSnapshot(
                    content: "prefix Model uses Grafana daily suffix"
                )
            },
            boostCorrelationRecorder: { _ in boostCount += 1 },
            outcomeRecorder: { outcome in
                outcomes.append(outcome)
                return .finalized
            }
        )
        observer.formatCorrectionSink = { _, _, _ in formatCount += 1 }

        await observer.observe(
            deliveryReceipt: fixture.receipt,
            deliveryAttribution: fixture.attribution,
            deliveryAttemptID: UUID(),
            capabilities: .correctionDerivedMutations,
            boostAudit: appliedCodexAudit(),
            appliedStylePolicy: .none
        )
        await observer.flushBeforeDictation()

        XCTAssertEqual(outcomes.map(\.status), [.corrected])
        XCTAssertEqual(readbackCount, 1)
        XCTAssertEqual(formatCount, 1)
        XCTAssertEqual(boostCount, 1)
        XCTAssertEqual(learning.events.map(\.editedText), ["Model uses Grafana daily"])
        XCTAssertTrue(dictionary.correctionSnapshot().contains { correction in
            correction.spoken == "grafanna" && correction.written == "Grafana"
        })
    }

    func testStablePrefixOnlyReceiptEditFailsClosedOnNextDictation() async throws {
        let fixture = try makeOpenBoundaryReceiptDelivery(
            baseline: "prefix ",
            selectedRange: nil,
            effectiveText: "Codex"
        )
        XCTAssertGreaterThan(fixture.receipt.anchor.prefixUTF16Length, 0)
        XCTAssertEqual(fixture.receipt.anchor.suffixUTF16Length, 0)
        XCTAssertFalse(fixture.attribution.wholeFieldOwned)

        let dictionary = DictionaryStore()
        let learning = RecordingLearningEngine()
        var readbackCount = 0
        var outcomes: [CorrectionObservationOutcome] = []
        var qualityStatuses: [DictationQualityReadbackStatus] = []
        var formatCount = 0
        var suggestionCount = 0
        var boostCount = 0
        let observer = CorrectionObserver(
            dictionaryStore: dictionary,
            pasteManager: PasteManager(),
            personalizationLearningEngine: learning,
            readbackDelay: .milliseconds(10),
            maximumObservationAge: 1,
            receiptReadback: { _ in
                readbackCount += 1
                // The appended "s" is adjacent typing at the unbounded suffix,
                // but looks like a plausible one-token correction to the old path.
                return self.receiptSnapshot(content: "prefix Codexs")
            },
            qualityRecorder: { _, status, _, _, _, _ in
                qualityStatuses.append(status)
            },
            boostCorrelationRecorder: { _ in boostCount += 1 },
            outcomeRecorder: { outcome in
                outcomes.append(outcome)
                return .finalized
            }
        )
        observer.formatCorrectionSink = { _, _, _ in formatCount += 1 }
        observer.learnSuggestionSink = { _ in suggestionCount += 1 }

        await observer.observe(
            deliveryReceipt: fixture.receipt,
            deliveryAttribution: fixture.attribution,
            deliveryAttemptID: UUID(),
            capabilities: .correctionDerivedMutations,
            boostAudit: appliedCodexAudit(),
            appliedStylePolicy: AppliedStylePolicy(openingCase: .lowercase)
        )
        for _ in 0..<100 where readbackCount == 0 {
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(readbackCount, 1, "a provisional digest must precede the flush")
        XCTAssertTrue(outcomes.isEmpty)

        await observer.flushBeforeDictation()

        XCTAssertEqual(outcomes.map(\.status), [.regionUnattributable])
        XCTAssertEqual(qualityStatuses, [.regionNotFound])
        XCTAssertFalse(qualityStatuses.contains(.corrected))
        XCTAssertEqual(readbackCount, 2)
        XCTAssertEqual(formatCount, 0)
        XCTAssertEqual(suggestionCount, 0)
        XCTAssertEqual(boostCount, 0)
        XCTAssertTrue(learning.events.isEmpty)
        XCTAssertFalse(dictionary.hasEntry(spoken: "Codex"))
        XCTAssertTrue(dictionary.correctionSnapshot().isEmpty)
    }

    func testStableSuffixOnlyReceiptEditFailsClosedDuringTimedTerminalRead() async throws {
        let fixture = try makeOpenBoundaryReceiptDelivery(
            baseline: " suffix",
            selectedRange: SelectionRange(location: 0, length: 0),
            effectiveText: "Codex"
        )
        XCTAssertEqual(fixture.receipt.anchor.prefixUTF16Length, 0)
        XCTAssertGreaterThan(fixture.receipt.anchor.suffixUTF16Length, 0)
        XCTAssertFalse(fixture.attribution.wholeFieldOwned)

        let dictionary = DictionaryStore()
        let learning = RecordingLearningEngine()
        var readbackCount = 0
        var outcomes: [CorrectionObservationOutcome] = []
        var qualityStatuses: [DictationQualityReadbackStatus] = []
        var formatCount = 0
        var suggestionCount = 0
        var boostCount = 0
        let observer = CorrectionObserver(
            dictionaryStore: dictionary,
            pasteManager: PasteManager(),
            personalizationLearningEngine: learning,
            readbackDelay: .milliseconds(10),
            maximumObservationAge: 0.08,
            receiptReadback: { _ in
                readbackCount += 1
                // The prepended "s" is adjacent typing at the unbounded prefix.
                return self.receiptSnapshot(content: "sCodex suffix")
            },
            qualityRecorder: { _, status, _, _, _, _ in
                qualityStatuses.append(status)
            },
            boostCorrelationRecorder: { _ in boostCount += 1 },
            outcomeRecorder: { outcome in
                outcomes.append(outcome)
                return .finalized
            }
        )
        observer.formatCorrectionSink = { _, _, _ in formatCount += 1 }
        observer.learnSuggestionSink = { _ in suggestionCount += 1 }

        await observer.observe(
            deliveryReceipt: fixture.receipt,
            deliveryAttribution: fixture.attribution,
            deliveryAttemptID: UUID(),
            capabilities: .correctionDerivedMutations,
            boostAudit: appliedCodexAudit(),
            appliedStylePolicy: AppliedStylePolicy(openingCase: .lowercase)
        )
        for _ in 0..<200 where outcomes.isEmpty {
            try? await Task.sleep(for: .milliseconds(2))
        }

        XCTAssertEqual(outcomes.map(\.status), [.regionUnattributable])
        XCTAssertEqual(qualityStatuses, [.regionNotFound])
        XCTAssertFalse(qualityStatuses.contains(.corrected))
        XCTAssertGreaterThanOrEqual(
            readbackCount,
            3,
            "two matching digest samples and a terminal verification must remain non-authoritative"
        )
        XCTAssertEqual(formatCount, 0)
        XCTAssertEqual(suggestionCount, 0)
        XCTAssertEqual(boostCount, 0)
        XCTAssertTrue(learning.events.isEmpty)
        XCTAssertFalse(dictionary.hasEntry(spoken: "Codex"))
        XCTAssertTrue(dictionary.correctionSnapshot().isEmpty)
    }

    func testNoReceiptAllowsSelectionOnlyFingerprintChange() async throws {
        let fixture = try makeWholeFieldDelivery(effectiveText: "hello")
        let provider = SnapshotProvider(snapshot: snapshot(
            content: "hello",
            fingerprint: fingerprint(selectedRange: "99:1")
        ))
        var outcomes: [CorrectionObservationOutcome] = []
        let observer = makeObserver { outcome in
            outcomes.append(outcome)
            return .finalized
        }
        observer.ambientFieldContentProvider = provider

        let started = await observer.observe(
            deliveryOutcome: fixture.outcome,
            targetApp: nil,
            capabilities: .none,
            appliedStylePolicy: .none
        )
        XCTAssertTrue(started)
        await observer.flushBeforeDictation()

        XCTAssertEqual(outcomes.map(\.status), [.accepted])
        XCTAssertEqual(outcomes.map(\.editDistanceBucket), [.none])
    }

    func testNoReceiptRejectsOpenAnchorThatDoesNotOwnWholeField() async throws {
        let baseline = "prefix "
        let inserted = try XCTUnwrap(PasteManager.makeUTF16InsertionAnchor(
            baselineValue: baseline,
            selectedRange: nil,
            postDeliveryValue: "prefix hello"
        ))
        let attribution = try XCTUnwrap(PasteManager.makeDeliveryAttribution(
            targetProcessIdentifier: 42,
            targetBundleIdentifier: "com.example.editor",
            targetFingerprint: fingerprint(),
            anchor: inserted.anchor,
            preDeliveryFieldUTF16Length: (baseline as NSString).length
        ))
        let outcome = PasteManager.DeliveryOutcome(
            delivered: true,
            receipt: nil,
            targetProcessIdentifier: 42,
            targetBundleIdentifier: "com.example.editor",
            effectiveInsertedText: "hello",
            targetObservedSettledText: "hello",
            deliveryAttribution: attribution
        )
        let provider = SnapshotProvider(snapshot: snapshot(content: "prefix hello"))
        var outcomes: [CorrectionObservationOutcome] = []
        let observer = makeObserver { outcome in
            outcomes.append(outcome)
            return .finalized
        }
        observer.ambientFieldContentProvider = provider

        let started = await observer.observe(
            deliveryOutcome: outcome,
            targetApp: nil,
            capabilities: .correctionDerivedMutations,
            appliedStylePolicy: .none
        )
        XCTAssertFalse(started)
        XCTAssertEqual(outcomes.map(\.status), [.regionUnattributable])
    }

    func testWholeFieldOwnedNoReceiptCanLearnCorrection() async throws {
        let fixture = try makeWholeFieldDelivery(effectiveText: "hello world")
        let provider = SnapshotProvider(snapshot: snapshot(content: "hello world"))
        let learning = RecordingLearningEngine()
        var outcomes: [CorrectionObservationOutcome] = []
        let observer = CorrectionObserver(
            dictionaryStore: DictionaryStore(),
            pasteManager: PasteManager(),
            personalizationLearningEngine: learning,
            outcomeRecorder: { outcome in
                outcomes.append(outcome)
                return .finalized
            }
        )
        observer.ambientFieldContentProvider = provider

        let started = await observer.observe(
            deliveryOutcome: fixture.outcome,
            targetApp: nil,
            capabilities: .correctionDerivedMutations,
            appliedStylePolicy: .none
        )
        XCTAssertTrue(started)
        provider.snapshot = snapshot(content: "hello World")
        await observer.flushBeforeDictation()

        XCTAssertEqual(outcomes.map(\.status), [.corrected])
        XCTAssertEqual(learning.events.first?.editedText, "hello World")
    }

    func testNoReceiptRejectsTargetNormalizationAtBaseline() async throws {
        let fixture = try makeWholeFieldDelivery(
            effectiveText: "hello",
            targetObservedSettledText: nil
        )
        let provider = SnapshotProvider(snapshot: snapshot(content: "Hello"))
        var outcomes: [CorrectionObservationOutcome] = []
        let observer = makeObserver { outcome in
            outcomes.append(outcome)
            return .finalized
        }
        observer.ambientFieldContentProvider = provider

        let started = await observer.observe(
            deliveryOutcome: fixture.outcome,
            targetApp: nil,
            capabilities: .correctionDerivedMutations,
            appliedStylePolicy: .none
        )
        XCTAssertFalse(started)
        XCTAssertEqual(outcomes.map(\.status), [.targetNormalizedOrUnattributable])
    }

    func testUnrelatedBoundaryEditAndDuplicateInsertedTextDoNotBecomeCorrections() async throws {
        let fixture = try makeSelectionDelivery(
            baseline: "prefix old suffix ask jon smythe",
            selectedText: "old",
            effectiveText: "ask jon smythe"
        )
        let provider = SnapshotProvider(snapshot: snapshot(content: fixture.postDeliveryField))
        let learning = RecordingLearningEngine()
        var outcomes: [CorrectionObservationOutcome] = []
        let observer = CorrectionObserver(
            dictionaryStore: DictionaryStore(),
            pasteManager: PasteManager(),
            personalizationLearningEngine: learning,
            outcomeRecorder: { outcome in
                outcomes.append(outcome)
                return .finalized
            }
        )
        observer.ambientFieldContentProvider = provider

        let started = await observer.observe(
            deliveryOutcome: fixture.outcome,
            targetApp: nil,
            capabilities: .correctionDerivedMutations,
            appliedStylePolicy: .none
        )
        XCTAssertTrue(started)
        // Only the unrelated duplicate after the anchor is edited. Because the
        // suffix digest changes, the observer must reject the whole readback.
        provider.snapshot = snapshot(
            content: "prefix ask jon smythe suffix ask John Smythe"
        )
        await observer.flushBeforeDictation()

        XCTAssertEqual(outcomes.map(\.status), [.regionUnattributable])
        XCTAssertTrue(learning.events.isEmpty)
    }

    func testCapabilitiesBlockEveryMutationSinkButPreserveQualityAndOutcome() async throws {
        let fixture = try makeWholeFieldDelivery(effectiveText: "ask Codex and teece")
        let provider = SnapshotProvider(snapshot: snapshot(content: "ask Codex and teece"))
        let dictionary = DictionaryStore()
        let learning = RecordingLearningEngine()
        var qualityStatuses: [DictationQualityReadbackStatus] = []
        var outcomes: [CorrectionObservationOutcome] = []
        var formatCount = 0
        var suggestionCount = 0
        var boostCount = 0
        let observer = CorrectionObserver(
            dictionaryStore: dictionary,
            pasteManager: PasteManager(),
            personalizationLearningEngine: learning,
            qualityRecorder: { _, status, _, _, _, _ in qualityStatuses.append(status) },
            boostCorrelationRecorder: { _ in boostCount += 1 },
            outcomeRecorder: { outcome in
                outcomes.append(outcome)
                return .finalized
            }
        )
        observer.formatCorrectionSink = { _, _, _ in formatCount += 1 }
        observer.learnSuggestionSink = { _ in suggestionCount += 1 }
        observer.ambientFieldContentProvider = provider
        let audit = VocabularyBoostAudit(decisions: [
            VocabularyBoostAudit.Decision(
                outcome: .applied,
                term: "Codex",
                originalText: "code ex",
                guarded: false,
                originalWasRealWord: false,
                originalScore: 0,
                replacementScore: 1,
                similarity: 1
            )
        ])

        let started = await observer.observe(
            deliveryOutcome: fixture.outcome,
            targetApp: nil,
            boostAudit: audit,
            capabilities: .none,
            appliedStylePolicy: .none
        )
        XCTAssertTrue(started)
        provider.snapshot = snapshot(content: "ask model and Thijs")
        await observer.flushBeforeDictation()

        XCTAssertEqual(qualityStatuses, [.corrected])
        XCTAssertEqual(outcomes.map(\.status), [.corrected])
        XCTAssertEqual(formatCount, 0)
        XCTAssertEqual(suggestionCount, 0)
        XCTAssertEqual(boostCount, 0)
        XCTAssertTrue(learning.events.isEmpty)
        XCTAssertTrue(dictionary.correctionSnapshot().isEmpty)
    }

    func testEditDistanceBucketBoundariesAreBoundedAndTextFree() {
        XCTAssertEqual(PersonalizationEditDistanceBucket.classify(nil), .unavailable)
        XCTAssertEqual(PersonalizationEditDistanceBucket.classify(.infinity), .unavailable)
        XCTAssertEqual(PersonalizationEditDistanceBucket.classify(0), .none)
        XCTAssertEqual(PersonalizationEditDistanceBucket.classify(0.05), .upToFivePercent)
        XCTAssertEqual(PersonalizationEditDistanceBucket.classify(0.050_001), .upToTwentyPercent)
        XCTAssertEqual(PersonalizationEditDistanceBucket.classify(0.20), .upToTwentyPercent)
        XCTAssertEqual(PersonalizationEditDistanceBucket.classify(0.200_001), .upToHalf)
        XCTAssertEqual(PersonalizationEditDistanceBucket.classify(0.50), .upToHalf)
        XCTAssertEqual(PersonalizationEditDistanceBucket.classify(0.500_001), .overHalf)
    }

    private func makeObserver(
        outcomeRecorder: @escaping CorrectionObserver.OutcomeRecorder
    ) -> CorrectionObserver {
        CorrectionObserver(
            dictionaryStore: DictionaryStore(),
            pasteManager: PasteManager(),
            outcomeRecorder: outcomeRecorder
        )
    }

    private func makeSelectionDelivery(
        baseline: String,
        selectedText: String,
        effectiveText: String,
        targetObservedSettledText: String? = nil
    ) throws -> DeliveryFixture {
        let baselineValue = baseline as NSString
        let range = baselineValue.range(of: selectedText)
        XCTAssertNotEqual(range.location, NSNotFound)
        let postDeliveryField = baselineValue.replacingCharacters(
            in: range,
            with: effectiveText
        )
        return try makeDelivery(
            baseline: baseline,
            selectedRange: SelectionRange(location: range.location, length: range.length),
            effectiveText: effectiveText,
            postDeliveryField: postDeliveryField,
            targetObservedSettledText: targetObservedSettledText ?? effectiveText
        )
    }

    private func makeWholeFieldDelivery(
        effectiveText: String,
        targetObservedSettledText: String? = nil
    ) throws -> DeliveryFixture {
        try makeDelivery(
            baseline: "",
            selectedRange: nil,
            effectiveText: effectiveText,
            postDeliveryField: effectiveText,
            targetObservedSettledText: targetObservedSettledText
        )
    }

    private func makeReceiptDelivery(
        effectiveText: String,
        deliveryFingerprint: ContextTargetFingerprint?,
        receiptBundleIdentifier: String? = "com.example.editor",
        receiptProcessIdentifier: pid_t = 42
    ) throws -> ReceiptFixture {
        let baseline = "prefix old suffix"
        let range = (baseline as NSString).range(of: "old")
        let postDeliveryField = (baseline as NSString).replacingCharacters(
            in: range,
            with: effectiveText
        )
        let insertion = try XCTUnwrap(PasteManager.makeUTF16InsertionAnchor(
            baselineValue: baseline,
            selectedRange: SelectionRange(location: range.location, length: range.length),
            postDeliveryValue: postDeliveryField
        ))
        let attribution = try XCTUnwrap(PasteManager.makeDeliveryAttribution(
            targetProcessIdentifier: 42,
            targetBundleIdentifier: "com.example.editor",
            targetFingerprint: deliveryFingerprint,
            anchor: insertion.anchor,
            preDeliveryFieldUTF16Length: (baseline as NSString).length
        ))
        let receipt = PasteManager.DeliveryReceipt(
            targetProcessIdentifier: receiptProcessIdentifier,
            targetBundleIdentifier: receiptBundleIdentifier,
            targetObservedInsertedText: effectiveText,
            anchor: insertion.anchor,
            element: AXUIElementCreateSystemWide(),
            windowTitle: nil,
            browserURL: nil
        )
        return ReceiptFixture(
            receipt: receipt,
            attribution: attribution,
            postDeliveryField: postDeliveryField
        )
    }

    private func makeOpenBoundaryReceiptDelivery(
        baseline: String,
        selectedRange: SelectionRange?,
        effectiveText: String
    ) throws -> ReceiptFixture {
        let insertion = try XCTUnwrap(PasteManager.makeUTF16InsertionAnchor(
            baselineValue: baseline,
            selectedRange: selectedRange,
            postDeliveryValue: (baseline as NSString).replacingCharacters(
                in: NSRange(
                    location: selectedRange?.location ?? (baseline as NSString).length,
                    length: selectedRange?.length ?? 0
                ),
                with: effectiveText
            )
        ))
        let attribution = try XCTUnwrap(PasteManager.makeDeliveryAttribution(
            targetProcessIdentifier: 42,
            targetBundleIdentifier: "com.example.editor",
            targetFingerprint: fingerprint(),
            anchor: insertion.anchor,
            preDeliveryFieldUTF16Length: (baseline as NSString).length
        ))
        let receipt = PasteManager.DeliveryReceipt(
            targetProcessIdentifier: 42,
            targetBundleIdentifier: "com.example.editor",
            targetObservedInsertedText: effectiveText,
            anchor: insertion.anchor,
            element: AXUIElementCreateSystemWide(),
            windowTitle: nil,
            browserURL: nil
        )
        return ReceiptFixture(
            receipt: receipt,
            attribution: attribution,
            postDeliveryField: (baseline as NSString).replacingCharacters(
                in: NSRange(
                    location: selectedRange?.location ?? (baseline as NSString).length,
                    length: selectedRange?.length ?? 0
                ),
                with: effectiveText
            )
        )
    }

    private func receiptSnapshot(
        content: String,
        sensitive: Bool? = false
    ) -> CorrectionReceiptSnapshot {
        CorrectionReceiptSnapshot(
            fullFieldContent: content,
            processIdentifier: 42,
            bundleIdentifier: "com.example.editor",
            isSensitiveInput: sensitive,
            targetFingerprint: fingerprint(sensitive: sensitive)
        )
    }

    private func appliedCodexAudit() -> VocabularyBoostAudit {
        VocabularyBoostAudit(decisions: [
            VocabularyBoostAudit.Decision(
                outcome: .applied,
                term: "Codex",
                originalText: "code ex",
                guarded: false,
                originalWasRealWord: false,
                originalScore: 0,
                replacementScore: 1,
                similarity: 1
            )
        ])
    }

    private func makeDelivery(
        baseline: String,
        selectedRange: SelectionRange?,
        effectiveText: String,
        postDeliveryField: String,
        targetObservedSettledText: String?
    ) throws -> DeliveryFixture {
        let insertion = try XCTUnwrap(PasteManager.makeUTF16InsertionAnchor(
            baselineValue: baseline,
            selectedRange: selectedRange,
            postDeliveryValue: postDeliveryField
        ))
        let attribution = try XCTUnwrap(PasteManager.makeDeliveryAttribution(
            targetProcessIdentifier: 42,
            targetBundleIdentifier: "com.example.editor",
            targetFingerprint: fingerprint(),
            anchor: insertion.anchor,
            preDeliveryFieldUTF16Length: (baseline as NSString).length
        ))
        let outcome = PasteManager.DeliveryOutcome(
            delivered: true,
            receipt: nil,
            targetProcessIdentifier: 42,
            targetBundleIdentifier: "com.example.editor",
            effectiveInsertedText: effectiveText,
            targetObservedSettledText: targetObservedSettledText,
            deliveryAttribution: attribution
        )
        return DeliveryFixture(
            outcome: outcome,
            attribution: attribution,
            postDeliveryField: postDeliveryField
        )
    }

    private func snapshot(
        content: String,
        processIdentifier: pid_t = 42,
        bundleIdentifier: String? = "com.example.editor",
        isSensitiveInput: Bool? = false,
        fingerprint: ContextTargetFingerprint? = nil
    ) -> CorrectionHotSnapshot {
        CorrectionHotSnapshot(
            fullFieldContent: content,
            processIdentifier: processIdentifier,
            bundleIdentifier: bundleIdentifier,
            isSensitiveInput: isSensitiveInput,
            targetFingerprint: fingerprint ?? self.fingerprint()
        )
    }

    private func fingerprint(
        identifier: String? = "field-id",
        sensitive: Bool? = false,
        selectedRange: String? = "0:0"
    ) -> ContextTargetFingerprint {
        ContextTargetFingerprint(
            role: "AXTextArea",
            subrole: "AXStandardTextArea",
            isSensitiveInput: sensitive,
            identifierToken: identifier,
            titleToken: "title-token",
            descriptionToken: "description-token",
            placeholderToken: "placeholder-token",
            helpToken: "help-token",
            frameBucket: "1:2:3:4",
            selectedRangeBucket: selectedRange
        )
    }
}
