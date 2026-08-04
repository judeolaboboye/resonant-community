import Foundation

/// Persistence evidence and live consumer availability are deliberately
/// separate. A row can qualify for recognition while the live recognizer is
/// off, unsupported, paused, conditional, or waiting for its helper.
enum PersonalizationEntityEligibilityState: String, CaseIterable, Sendable, Equatable {
    case learning
    case promptEligible = "prompt_eligible"
    case recognitionEligible = "recognition_eligible"
    case suppressed

    var isPromptEligible: Bool {
        self == .promptEligible || self == .recognitionEligible
    }

    var isRecognitionEligible: Bool {
        self == .recognitionEligible
    }
}

/// Current whole-app availability for a recognition-eligible learned term.
/// `available` is capability, not proof that a particular dictation used the
/// term. Auto remains conditional until an attempt observes confident English.
enum PersonalizationRecognizerAvailability: Sendable, Equatable {
    case notEligible
    case runtimeUnavailable
    case featureOff
    case unsupportedAdapter
    case lowLatencyPaused
    case unsupportedLanguage
    case noEligibleTerms
    case helperAbsent
    case helperDownloading
    case helperFailed(VocabularyBoostHelperFailureCategory)
    case automaticLanguageConditional
    case available

    var isAvailable: Bool {
        self == .available
    }

    var isConditional: Bool {
        self == .automaticLanguageConditional
    }

    var isUnavailable: Bool {
        switch self {
        case .notEligible, .automaticLanguageConditional, .available:
            false
        default:
            true
        }
    }
}

enum PersonalizationFormatEligibilityState: String, CaseIterable, Sendable, Equatable {
    case learning
    case formatterEligible = "formatter_eligible"
    case suppressed

    var isFormatterEligible: Bool {
        self == .formatterEligible
    }
}

enum PersonalizationCloudCleanupAvailability: Sendable, Equatable {
    case unknown
    case polishVerbatim
    case lowLatencyPaused
    case disabled
    case signedOut
    case eligible

    /// Mirrors only the gates `DictationCleanupPipeline` can decide without a
    /// transcript. The pipeline additionally skips cloud cleanup per dictation
    /// for an email signoff-only edit, a surface whose own polish level is
    /// verbatim, and a short dictation. Those need the utterance, so the best
    /// this can honestly report is eligibility, never a guarantee that the
    /// next dictation reaches the cloud — see `.eligible`.
    static func resolve(
        cloudProcessingEnabled: Bool,
        lowLatencyMode: Bool,
        isLoggedIn: Bool,
        polishSettings: DictationPolishSettings
    ) -> Self {
        // Same order as the pipeline's global gates.
        guard !polishSettings.isVerbatimEverywhere else { return .polishVerbatim }
        guard !lowLatencyMode else { return .lowLatencyPaused }
        guard cloudProcessingEnabled else { return .disabled }
        guard isLoggedIn else { return .signedOut }
        return .eligible
    }
}

enum PersonalizationRuntimeGateState: Sendable, Equatable {
    case unknown
    case enabled
    case disabled

    init(_ isEnabled: Bool) {
        self = isEnabled ? .enabled : .disabled
    }
}

struct PersonalizationFormatterRuntimeGates: Sendable, Equatable {
    var punctuation: PersonalizationRuntimeGateState
    var listFormatting: PersonalizationRuntimeGateState

    static let unknown = PersonalizationFormatterRuntimeGates(
        punctuation: .unknown,
        listFormatting: .unknown
    )

    init(
        punctuation: PersonalizationRuntimeGateState,
        listFormatting: PersonalizationRuntimeGateState
    ) {
        self.punctuation = punctuation
        self.listFormatting = listFormatting
    }

    init(autoPunctuationEnabled: Bool, bulletPointsEnabled: Bool) {
        punctuation = PersonalizationRuntimeGateState(autoPunctuationEnabled)
        listFormatting = PersonalizationRuntimeGateState(bulletPointsEnabled)
    }
}

/// Text-free, current runtime facts used by Settings snapshots. No transcript,
/// term, profile, target, or identifier crosses this boundary.
struct PersonalizationConsumerRuntimeContext: Sendable, Equatable {
    var vocabularyBoost: VocabularyBoostRuntimeState?
    var cloudCleanup: PersonalizationCloudCleanupAvailability
    var formatterGates: PersonalizationFormatterRuntimeGates

    static let unavailable = PersonalizationConsumerRuntimeContext(
        vocabularyBoost: nil,
        cloudCleanup: .unknown,
        formatterGates: .unknown
    )

    init(
        vocabularyBoost: VocabularyBoostRuntimeState?,
        cloudCleanup: PersonalizationCloudCleanupAvailability,
        formatterGates: PersonalizationFormatterRuntimeGates
    ) {
        self.vocabularyBoost = vocabularyBoost
        self.cloudCleanup = cloudCleanup
        self.formatterGates = formatterGates
    }
}

/// Style eligibility can feed two independent consumers. Local availability
/// is family-specific because punctuation and list settings are hard vetoes.
/// Cloud availability is the cleanup pipeline's current global capability;
/// neither means that a target or request actually exercised the rule.
struct PersonalizationStyleConsumerState: Sendable, Equatable {
    var localPolicyEligibleFamilyCount: Int
    var localPolicyAvailableFamilyCount: Int
    var localPolicyVetoedFamilyCount: Int
    var localPolicyUnknownFamilyCount: Int
    var isCloudStyleEligible: Bool
    var cloudAvailability: PersonalizationCloudCleanupAvailability

    var isLearning: Bool {
        localPolicyEligibleFamilyCount == 0 && !isCloudStyleEligible
    }

    var isLocalPolicyEligible: Bool {
        localPolicyEligibleFamilyCount > 0
    }

    var isLocalPolicyAvailable: Bool {
        localPolicyAvailableFamilyCount > 0
    }

    var isCloudStyleAvailable: Bool {
        isCloudStyleEligible && cloudAvailability == .eligible
    }

    static let learning = PersonalizationStyleConsumerState(
        localPolicyEligibleFamilyCount: 0,
        localPolicyAvailableFamilyCount: 0,
        localPolicyVetoedFamilyCount: 0,
        localPolicyUnknownFamilyCount: 0,
        isCloudStyleEligible: false,
        cloudAvailability: .unknown
    )
}

/// Pure evidence thresholds and live-availability mapping shared by dashboard
/// rows and aggregate counts. Runtime consumers continue to use the evidence
/// predicates, then apply their own per-attempt/target gates.
enum PersonalizationConsumerStateResolver {
    static let formatEligibleConfidence = 0.6
    static let formatEligiblePositiveCount = 2

    static func entityEligibility(
        type: ContextEntityType,
        value: String,
        confidence: Double,
        positiveCount: Int,
        isUserPinned: Bool,
        isSuppressed: Bool,
        scopeMatches: Bool
    ) -> PersonalizationEntityEligibilityState {
        guard !isSuppressed else { return .suppressed }
        guard scopeMatches,
              (2...80).contains(value.count),
              positiveCount >= minimumPromptPositiveCount(for: type) || isUserPinned
        else { return .learning }

        let recognitionEligible = (isUserPinned || (confidence >= 0.7 && positiveCount >= 2))
            && [.personName, .customTerm].contains(type)
            && value.count >= ParakeetVocabularyBoostEngine.minimumTermLength
        return recognitionEligible ? .recognitionEligible : .promptEligible
    }

    static func recognizerAvailability(
        eligibility: PersonalizationEntityEligibilityState,
        runtime: VocabularyBoostRuntimeState?
    ) -> PersonalizationRecognizerAvailability {
        guard eligibility.isRecognitionEligible else { return .notEligible }
        guard let runtime else { return .runtimeUnavailable }

        switch runtime.applicability {
        case .off:
            return .featureOff
        case .unsupportedModel:
            return .unsupportedAdapter
        case .lowLatencyPaused:
            return .lowLatencyPaused
        case .unsupportedLanguage:
            return .unsupportedLanguage
        case .noEligibleTerms:
            return .noEligibleTerms
        case .automaticConditional, .eligible:
            break
        }

        switch runtime.helper {
        case .absent:
            return .helperAbsent
        case .downloading:
            return .helperDownloading
        case .failed(let category):
            return .helperFailed(category)
        case .ready:
            break
        }

        return runtime.applicability == .automaticConditional
            ? .automaticLanguageConditional
            : .available
    }

    static func formatEligibility(
        confidence: Double,
        positiveCount: Int,
        isSuppressed: Bool
    ) -> PersonalizationFormatEligibilityState {
        guard !isSuppressed else { return .suppressed }
        guard confidence >= formatEligibleConfidence,
              positiveCount >= formatEligiblePositiveCount
        else { return .learning }
        return .formatterEligible
    }

    static func styleState(
        policy: StylePolicy,
        cloudStyleHint: String?,
        runtime: PersonalizationConsumerRuntimeContext
    ) -> PersonalizationStyleConsumerState {
        var eligibleFamilies = 0
        var availableFamilies = 0
        var vetoedFamilies = 0
        var unknownFamilies = 0

        if policy.openingCase != .inherit {
            eligibleFamilies += 1
            availableFamilies += 1
        }
        if policy.listMarkers != .inherit {
            eligibleFamilies += 1
            switch runtime.formatterGates.listFormatting {
            case .enabled: availableFamilies += 1
            case .disabled: vetoedFamilies += 1
            case .unknown: unknownFamilies += 1
            }
        }
        if policy.trailingPeriod != .inherit {
            eligibleFamilies += 1
            switch runtime.formatterGates.punctuation {
            case .enabled: availableFamilies += 1
            case .disabled: vetoedFamilies += 1
            case .unknown: unknownFamilies += 1
            }
        }

        return PersonalizationStyleConsumerState(
            localPolicyEligibleFamilyCount: eligibleFamilies,
            localPolicyAvailableFamilyCount: availableFamilies,
            localPolicyVetoedFamilyCount: vetoedFamilies,
            localPolicyUnknownFamilyCount: unknownFamilies,
            isCloudStyleEligible: cloudStyleHint?.isEmpty == false,
            cloudAvailability: runtime.cloudCleanup
        )
    }

    static func minimumPromptPositiveCount(for type: ContextEntityType) -> Int {
        switch type {
        case .personName, .personHandle, .emailAddress, .fileName, .filePath,
                .ticketID, .chatChannel:
            return 1
        default:
            return 2
        }
    }
}
