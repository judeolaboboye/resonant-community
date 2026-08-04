import Darwin
import Foundation

/// The learning channels authorized for one dictation outcome.
///
/// Callers must carry an explicit value. An absent value is represented by
/// `none`, never by a permissive default.
struct LearningCapabilities: OptionSet, Sendable, Hashable {
    let rawValue: UInt8

    init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    static let none: LearningCapabilities = []
    static let correctionDerivedMutations = LearningCapabilities(rawValue: 1 << 0)
    static let rawTranscriptHabits = LearningCapabilities(rawValue: 1 << 1)

    var allowsCorrectionDerivedMutations: Bool {
        contains(.correctionDerivedMutations)
    }

    var allowsRawTranscriptHabits: Bool {
        contains(.rawTranscriptHabits)
    }

    /// Resolves delivery-time permissions. Auto-send can never authorize a
    /// correction-derived mutation, and selection transforms veto both
    /// channels even when their confidence predicates otherwise pass.
    static func resolving(
        correctionDerivedEligible: Bool,
        rawTranscriptHabitEligible: Bool,
        autoSent: Bool,
        selectionTransformUsed: Bool
    ) -> LearningCapabilities {
        guard !selectionTransformUsed else { return .none }

        var capabilities: LearningCapabilities = .none
        if correctionDerivedEligible, !autoSent {
            capabilities.insert(.correctionDerivedMutations)
        }
        if rawTranscriptHabitEligible {
            capabilities.insert(.rawTranscriptHabits)
        }
        return capabilities
    }
}

/// One atomic, correction-only read of the currently focused target.
///
/// This value is intentionally ephemeral: callers use the full field content
/// to prove insertion-region ownership and retain only the settled inserted
/// region in a pending observation.
struct CorrectionHotSnapshot: Sendable, Equatable {
    let fullFieldContent: String
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let isSensitiveInput: Bool?
    let targetFingerprint: ContextTargetFingerprint?

    var targetIdentity: CorrectionTargetIdentity {
        CorrectionTargetIdentity(
            processIdentifier: processIdentifier,
            bundleIdentifier: bundleIdentifier,
            isSensitiveInput: isSensitiveInput,
            fingerprint: targetFingerprint
        )
    }
}

/// One atomic read from the exact AX element retained by a delivery receipt.
///
/// This is deliberately a distinct type from `CorrectionHotSnapshot`: receipt
/// readback must never be satisfied by whichever field happens to be focused.
/// The fingerprint and sensitivity are recomputed from the retained element on
/// every read before its content can become correction evidence.
struct CorrectionReceiptSnapshot: Sendable, Equatable {
    let fullFieldContent: String
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let isSensitiveInput: Bool?
    let targetFingerprint: ContextTargetFingerprint?

    var targetIdentity: CorrectionTargetIdentity {
        CorrectionTargetIdentity(
            processIdentifier: processIdentifier,
            bundleIdentifier: bundleIdentifier,
            isSensitiveInput: isSensitiveInput,
            fingerprint: targetFingerprint
        )
    }
}

/// Text-free method attached to correction-observation outcomes.
enum CorrectionReadbackMethod: String, Sendable, Equatable {
    case none
    case receipt
    case correctionHotSnapshot = "correction_hot_snapshot"
}

/// Closed set of terminal correction-observation outcomes. These cases are
/// deliberately more precise than the legacy quality event while remaining
/// text-free and safe for the local outcome store.
enum CorrectionObservationStatus: String, Sendable, Equatable {
    case accepted
    case corrected
    case stale
    case noFieldContent = "no_field_content"
    case baselineUnavailable = "baseline_unavailable"
    case processMismatch = "process_mismatch"
    case targetMismatch = "target_mismatch"
    case sensitiveTarget = "sensitive_target"
    case insufficientIdentity = "insufficient_identity"
    case regionUnattributable = "region_unattributable"
    case targetNormalizedOrUnattributable = "target_normalized_or_unattributable"
    case observationReplaced = "observation_replaced"
    case observationCancelled = "observation_cancelled"
}

/// Text-free observer result exposed for later PersonalizationOutcomeStore
/// integration. The correction count is capped before construction.
struct CorrectionObservationOutcome: Sendable, Equatable {
    let deliveryAttemptID: UUID
    let status: CorrectionObservationStatus
    let readbackMethod: CorrectionReadbackMethod
    let capabilities: LearningCapabilities
    let editDistanceBucket: PersonalizationEditDistanceBucket
    let correctionCount: Int?
}

/// Text-free target identity used by the pure correction-attribution matcher.
struct CorrectionTargetIdentity: Sendable, Equatable {
    let processIdentifier: pid_t?
    let bundleIdentifier: String?
    let isSensitiveInput: Bool?
    let fingerprint: ContextTargetFingerprint?

    init(
        processIdentifier: pid_t?,
        bundleIdentifier: String?,
        isSensitiveInput: Bool?,
        fingerprint: ContextTargetFingerprint?
    ) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.isSensitiveInput = isSensitiveInput
        self.fingerprint = fingerprint
    }
}

enum CorrectionTargetMatchResult: Sendable, Equatable {
    case match
    case mismatch
    case insufficientEvidence
}

/// Exhaustive, fail-closed target matching for correction readback.
enum CorrectionTargetMatcher {
    static func match(
        delivery: CorrectionTargetIdentity,
        observed: CorrectionTargetIdentity
    ) -> CorrectionTargetMatchResult {
        if conflicts(delivery.processIdentifier, observed.processIdentifier)
            || conflicts(delivery.bundleIdentifier, observed.bundleIdentifier) {
            return .mismatch
        }

        let deliverySensitivity = resolvedSensitivity(delivery)
        let observedSensitivity = resolvedSensitivity(observed)
        if deliverySensitivity == true || observedSensitivity == true {
            return .mismatch
        }

        guard delivery.processIdentifier != nil,
              observed.processIdentifier != nil,
              delivery.bundleIdentifier != nil,
              observed.bundleIdentifier != nil,
              deliverySensitivity != nil,
              observedSensitivity != nil else {
            return .insufficientEvidence
        }

        guard let deliveryFingerprint = delivery.fingerprint,
              let observedFingerprint = observed.fingerprint else {
            return .insufficientEvidence
        }

        switch (deliveryFingerprint.identifierToken, observedFingerprint.identifierToken) {
        case let (deliveryIdentifier?, observedIdentifier?):
            guard deliveryIdentifier == observedIdentifier else {
                return .mismatch
            }
            return strongIdentifierMatch(
                delivery: deliveryFingerprint,
                observed: observedFingerprint
            )

        case (nil, nil):
            return fallbackMatch(
                delivery: deliveryFingerprint,
                observed: observedFingerprint
            )

        case (_?, nil), (nil, _?):
            return .insufficientEvidence
        }
    }

    private static func strongIdentifierMatch(
        delivery: ContextTargetFingerprint,
        observed: ContextTargetFingerprint
    ) -> CorrectionTargetMatchResult {
        let stableFields: [(String?, String?)] = [
            (delivery.role, observed.role),
            (delivery.subrole, observed.subrole),
            (delivery.titleToken, observed.titleToken),
            (delivery.descriptionToken, observed.descriptionToken),
            (delivery.helpToken, observed.helpToken),
        ]
        guard !stableFields.contains(where: { conflicts($0.0, $0.1) }) else {
            return .mismatch
        }

        // A placeholder may disappear after insertion. Two different, still
        // present placeholders identify conflicting targets.
        if conflicts(delivery.placeholderToken, observed.placeholderToken) {
            return .mismatch
        }

        // Frame movement and selection changes are intentionally ignored once
        // the strong identifier is equal.
        return .match
    }

    private static func fallbackMatch(
        delivery: ContextTargetFingerprint,
        observed: ContextTargetFingerprint
    ) -> CorrectionTargetMatchResult {
        let comparedFields: [(String?, String?)] = [
            (delivery.role, observed.role),
            (delivery.subrole, observed.subrole),
            (delivery.frameBucket, observed.frameBucket),
            (delivery.titleToken, observed.titleToken),
            (delivery.descriptionToken, observed.descriptionToken),
            (delivery.placeholderToken, observed.placeholderToken),
            (delivery.helpToken, observed.helpToken),
        ]
        guard !comparedFields.contains(where: { conflicts($0.0, $0.1) }) else {
            return .mismatch
        }

        let requiredGeometryAndRole: [(String?, String?)] = [
            (delivery.role, observed.role),
            (delivery.subrole, observed.subrole),
            (delivery.frameBucket, observed.frameBucket),
        ]
        guard requiredGeometryAndRole.allSatisfy({ equalNonNil($0.0, $0.1) }) else {
            return .insufficientEvidence
        }

        let labelFields: [(String?, String?)] = [
            (delivery.titleToken, observed.titleToken),
            (delivery.descriptionToken, observed.descriptionToken),
            (delivery.placeholderToken, observed.placeholderToken),
            (delivery.helpToken, observed.helpToken),
        ]
        let matchingLabelCount = labelFields.reduce(into: 0) { count, pair in
            if equalNonNil(pair.0, pair.1) {
                count += 1
            }
        }
        return matchingLabelCount >= 2 ? .match : .insufficientEvidence
    }

    private static func resolvedSensitivity(_ identity: CorrectionTargetIdentity) -> Bool? {
        let values = [identity.isSensitiveInput, identity.fingerprint?.isSensitiveInput]
            .compactMap { $0 }
        if values.contains(true) {
            return true
        }
        return values.contains(false) ? false : nil
    }

    private static func conflicts<T: Equatable>(_ lhs: T?, _ rhs: T?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs != rhs
    }

    private static func equalNonNil<T: Equatable>(_ lhs: T?, _ rhs: T?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs == rhs
    }
}

enum CorrectionRegionAttributionResult: Sendable, Equatable {
    case attributed(String)
    case regionUnattributable
}

/// Reconstructs exactly the region owned by a delivery anchor. It never scans
/// for text or falls back to fuzzy whole-field/suffix matching.
enum CorrectionRegionAttributor {
    static func region(
        in fullFieldContent: String,
        attribution: PasteManager.DeliveryAttribution
    ) -> CorrectionRegionAttributionResult {
        let anchor = attribution.anchor
        let expectedPreDeliveryLength = anchor.prefixUTF16Length
            + anchor.replacedRange.length
            + anchor.suffixUTF16Length
        guard expectedPreDeliveryLength == attribution.preDeliveryFieldUTF16Length,
              anchor.prefixUTF16Length == anchor.replacedRange.location else {
            return .regionUnattributable
        }

        let ownsWholeField = anchor.replacedRange.location == 0
            && anchor.replacedRange.length == attribution.preDeliveryFieldUTF16Length
            && anchor.prefixUTF16Length == 0
            && anchor.suffixUTF16Length == 0
        guard attribution.wholeFieldOwned == ownsWholeField else {
            return .regionUnattributable
        }
        guard ownsWholeField || anchor.hasClosedBoundaries else {
            return .regionUnattributable
        }
        guard let region = PasteManager.anchoredInsertedRegion(
            in: fullFieldContent,
            anchor: anchor
        ) else {
            return .regionUnattributable
        }
        return .attributed(region)
    }
}

enum CorrectionBaselineValidationResult: Sendable, Equatable {
    case settled(String)
    case baselineUnavailable
    case regionUnattributable
    case targetNormalizedOrUnattributable
}

/// Confirms the effective delivery against target-observed evidence before a
/// no-receipt observation is allowed to enter its edit window.
enum CorrectionBaselineValidator {
    static func validate(
        effectiveInsertedText: String?,
        targetObservedSettledText: String?,
        snapshot: CorrectionHotSnapshot,
        attribution: PasteManager.DeliveryAttribution
    ) -> CorrectionBaselineValidationResult {
        guard let effectiveInsertedText, !effectiveInsertedText.isEmpty else {
            return .baselineUnavailable
        }
        if let targetObservedSettledText,
           targetObservedSettledText != effectiveInsertedText {
            return .targetNormalizedOrUnattributable
        }

        switch CorrectionRegionAttributor.region(
            in: snapshot.fullFieldContent,
            attribution: attribution
        ) {
        case .regionUnattributable:
            return .regionUnattributable
        case .attributed(let observedRegion):
            guard observedRegion == effectiveInsertedText,
                  targetObservedSettledText == nil
                    || targetObservedSettledText == observedRegion else {
                return .targetNormalizedOrUnattributable
            }
            return .settled(observedRegion)
        }
    }
}

extension PasteManager {
    /// Privacy-safe delivery-time evidence for later no-receipt readback. The
    /// anchor retains only UTF-16 lengths and digests, never surrounding text.
    struct DeliveryAttribution: Sendable, Equatable {
        let targetProcessIdentifier: pid_t
        let targetBundleIdentifier: String
        let isSensitiveInput: Bool?
        let targetFingerprint: ContextTargetFingerprint?
        let anchor: UTF16InsertionAnchor
        let preDeliveryFieldUTF16Length: Int
        let wholeFieldOwned: Bool

        var targetIdentity: CorrectionTargetIdentity {
            CorrectionTargetIdentity(
                processIdentifier: targetProcessIdentifier,
                bundleIdentifier: targetBundleIdentifier,
                isSensitiveInput: isSensitiveInput,
                fingerprint: targetFingerprint
            )
        }
    }
}
