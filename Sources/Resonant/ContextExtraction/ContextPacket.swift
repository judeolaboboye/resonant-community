import Foundation

enum SurfaceKind: String, Codable, Sendable, CaseIterable {
    case email
    case chat
    case social
    case code
    case docs
    case task
    case browser
    case search
    case terminal
    case finder
    case form
    case other
}

enum FieldKind: String, Codable, Sendable, CaseIterable {
    case compose
    case reply
    case comment
    case search
    case title
    case subject
    case address
    case code
    case terminal
    case richText
    case plainText
    case unknown
}

enum ContextEntityType: String, Codable, Sendable, CaseIterable {
    case personName
    case personHandle
    case emailAddress
    case organization
    case appName
    case siteDomain
    case chatChannel
    case chatThread
    case fileName
    case filePath
    case repoName
    case codeSymbol
    case ticketID
    case documentTitle
    case taskTitle
    case url
    case customTerm
    case styleSignal
}

enum EvidenceSource: String, Codable, Sendable, CaseIterable {
    case focusedField
    case selectedText
    case windowTitle
    case browserURL
    case visibleSnippet
    case appMetadata
    case openFile
    case browserTab
    case recentSameSurface
    case dictionary
    case correctionMemory
    case ambientMemory
    case contacts
    case calendar
    case browserExtension
    case editorExtension
    case cloudConnector
    case ocr
    case clipboard
}

enum ContextTrustTier: String, Codable, Sendable, CaseIterable {
    case metadataOnly
    case biasTerm
    case styleHint
    case grounding
    case blocked
}

enum ContextSafetyFlag: String, Codable, Sendable, CaseIterable {
    case containsUntrustedVisibleText
    case containsEmailLikeText
    case containsChatLikeText
    case containsURL
    case containsSensitiveCandidate
    case groundingDisabled
    case cloudContextReduced
}

/// Provenance retained until the final consumer filter. This value is local
/// packet metadata; analytics receives only the bounded aggregate exposure
/// below, never entity values or provenance-bearing payloads.
enum ContextValueProvenance: String, Codable, Sendable, CaseIterable {
    case base
    case manual
    case learned
}

enum ContextPersonalizationAssignedVariant: String, Codable, Sendable, CaseIterable {
    case personalized
    case holdout
    case unassigned

    init(_ variant: PersonalizationProfileVariant?) {
        switch variant {
        case .personalized:
            self = .personalized
        case .holdout:
            self = .holdout
        case nil:
            self = .unassigned
        }
    }
}

/// Text-free, per-consumer audit for context personalization.
///
/// Packet values are merely offered. Local application requires a
/// deterministic consumer-side text change, while cloud values are only
/// submitted because a model's causal use cannot be observed. Counts are
/// capped at construction so this type can cross persistence and analytics
/// boundaries without carrying content, fingerprints, hashes, or identifiers.
struct ContextPersonalizationExposure: Codable, Sendable, Hashable {
    static let maximumCount = 100
    static let maximumPolicyVersion = 10_000

    let policyName: String
    let policyVersion: Int
    let configuredHoldoutRate: Int
    let assignedVariant: ContextPersonalizationAssignedVariant
    let personalizationOpportunity: Bool
    let withheldByHoldout: Bool
    let packetEntityOfferedCount: Int
    let packetStyleOffered: Bool
    let localLearnedEntityConsideredCount: Int
    let localLearnedEntityMatchedCount: Int
    let localLearnedEntityAppliedCount: Int
    /// Reserved for a future packet-gated local style consumer. The current
    /// formatter reads memory independently of this experiment, so delivery
    /// integration must leave this false.
    let localStyleApplied: Bool
    let cloudLearnedEntitySubmittedCount: Int
    let cloudLearnedStyleSubmitted: Bool

    static let none = ContextPersonalizationExposure()

    init(
        policyName: String = ContextPersonalizationPolicy.name,
        policyVersion: Int = ContextPersonalizationPolicy.version,
        configuredHoldoutRate: Int = ContextPersonalizationPolicy.defaultHoldoutRate,
        assignedVariant: ContextPersonalizationAssignedVariant = .unassigned,
        personalizationOpportunity: Bool = false,
        withheldByHoldout: Bool = false,
        packetEntityOfferedCount: Int = 0,
        packetStyleOffered: Bool = false,
        localLearnedEntityConsideredCount: Int = 0,
        localLearnedEntityMatchedCount: Int = 0,
        localLearnedEntityAppliedCount: Int = 0,
        localStyleApplied: Bool = false,
        cloudLearnedEntitySubmittedCount: Int = 0,
        cloudLearnedStyleSubmitted: Bool = false
    ) {
        // Do not accept an arbitrary/free-form experiment name at this seam.
        _ = policyName
        self.policyName = ContextPersonalizationPolicy.name
        self.policyVersion = min(max(policyVersion, 0), Self.maximumPolicyVersion)
        self.configuredHoldoutRate = min(max(configuredHoldoutRate, 0), 100)
        self.assignedVariant = assignedVariant
        self.packetEntityOfferedCount = Self.bounded(packetEntityOfferedCount)
        self.packetStyleOffered = packetStyleOffered
        self.localLearnedEntityConsideredCount = Self.bounded(
            localLearnedEntityConsideredCount
        )
        self.localLearnedEntityMatchedCount = min(
            Self.bounded(localLearnedEntityMatchedCount),
            self.localLearnedEntityConsideredCount
        )
        self.localLearnedEntityAppliedCount = min(
            Self.bounded(localLearnedEntityAppliedCount),
            self.localLearnedEntityMatchedCount
        )
        self.localStyleApplied = localStyleApplied
        self.cloudLearnedEntitySubmittedCount = Self.bounded(
            cloudLearnedEntitySubmittedCount
        )
        self.cloudLearnedStyleSubmitted = cloudLearnedStyleSubmitted
        let anyOfferedOrConsumed = self.packetEntityOfferedCount > 0
            || packetStyleOffered
            || self.localLearnedEntityConsideredCount > 0
            || self.cloudLearnedEntitySubmittedCount > 0
            || cloudLearnedStyleSubmitted
        let anyLocallyApplied = self.localLearnedEntityAppliedCount > 0
            || localStyleApplied
        self.personalizationOpportunity = personalizationOpportunity || anyOfferedOrConsumed
        self.withheldByHoldout = withheldByHoldout
            && assignedVariant == .holdout
            && self.personalizationOpportunity
            && self.packetEntityOfferedCount == 0
            && !packetStyleOffered
            && !anyLocallyApplied
            && self.cloudLearnedEntitySubmittedCount == 0
            && !cloudLearnedStyleSubmitted
    }

    var personalizationApplied: Bool {
        localLearnedEntityAppliedCount > 0 || localStyleApplied
    }

    func recordingConsumers(
        localRepair: ContextualEntityRepairProvenance,
        cloudSubmission: CloudContextPersonalizationSubmission,
        localStyleApplied: Bool = false
    ) -> ContextPersonalizationExposure {
        ContextPersonalizationExposure(
            policyVersion: policyVersion,
            configuredHoldoutRate: configuredHoldoutRate,
            assignedVariant: assignedVariant,
            personalizationOpportunity: personalizationOpportunity,
            withheldByHoldout: withheldByHoldout,
            packetEntityOfferedCount: packetEntityOfferedCount,
            packetStyleOffered: packetStyleOffered,
            localLearnedEntityConsideredCount: localRepair.learnedEntityConsideredCount,
            localLearnedEntityMatchedCount: localRepair.learnedEntityMatchedCount,
            localLearnedEntityAppliedCount: localRepair.learnedEntityAppliedCount,
            localStyleApplied: localStyleApplied,
            cloudLearnedEntitySubmittedCount: cloudSubmission.learnedEntitySubmittedCount,
            cloudLearnedStyleSubmitted: cloudSubmission.learnedStyleSubmitted
        )
    }

    var outcomeExposure: PersonalizationOutcomeExposure {
        let outcomeVariant: PersonalizationOutcomeAssignmentVariant
        switch assignedVariant {
        case .personalized:
            outcomeVariant = .personalized
        case .holdout:
            outcomeVariant = .holdout
        case .unassigned:
            outcomeVariant = .unknown
        }
        return PersonalizationOutcomeExposure(
            assignmentVariant: outcomeVariant,
            assignmentPolicyVersion: policyVersion,
            personalizationOpportunity: personalizationOpportunity,
            withheldByHoldout: withheldByHoldout,
            packetEntityOfferedCount: packetEntityOfferedCount,
            packetStyleOffered: packetStyleOffered,
            localLearnedEntityConsideredCount: localLearnedEntityConsideredCount,
            localLearnedEntityMatchedCount: localLearnedEntityMatchedCount,
            localLearnedEntityAppliedCount: localLearnedEntityAppliedCount,
            localStyleApplied: localStyleApplied,
            cloudLearnedEntitySubmittedCount: cloudLearnedEntitySubmittedCount,
            cloudLearnedStyleSubmitted: cloudLearnedStyleSubmitted
        )
    }

    private static func bounded(_ count: Int) -> Int {
        min(max(count, 0), maximumCount)
    }

    private enum CodingKeys: String, CodingKey {
        case policyName
        case policyVersion
        case configuredHoldoutRate
        case assignedVariant
        case personalizationOpportunity
        case withheldByHoldout
        case packetEntityOfferedCount
        case packetStyleOffered
        case localLearnedEntityConsideredCount
        case localLearnedEntityMatchedCount
        case localLearnedEntityAppliedCount
        case localStyleApplied
        case cloudLearnedEntitySubmittedCount
        case cloudLearnedStyleSubmitted
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            policyName: try values.decodeIfPresent(String.self, forKey: .policyName)
                ?? ContextPersonalizationPolicy.name,
            policyVersion: try values.decodeIfPresent(Int.self, forKey: .policyVersion) ?? 0,
            configuredHoldoutRate: try values.decodeIfPresent(Int.self, forKey: .configuredHoldoutRate) ?? 0,
            assignedVariant: try values.decodeIfPresent(
                ContextPersonalizationAssignedVariant.self,
                forKey: .assignedVariant
            ) ?? .unassigned,
            personalizationOpportunity: try values.decodeIfPresent(
                Bool.self,
                forKey: .personalizationOpportunity
            ) ?? false,
            withheldByHoldout: try values.decodeIfPresent(Bool.self, forKey: .withheldByHoldout) ?? false,
            packetEntityOfferedCount: try values.decodeIfPresent(
                Int.self,
                forKey: .packetEntityOfferedCount
            ) ?? 0,
            packetStyleOffered: try values.decodeIfPresent(Bool.self, forKey: .packetStyleOffered) ?? false,
            localLearnedEntityConsideredCount: try values.decodeIfPresent(
                Int.self,
                forKey: .localLearnedEntityConsideredCount
            ) ?? 0,
            localLearnedEntityMatchedCount: try values.decodeIfPresent(
                Int.self,
                forKey: .localLearnedEntityMatchedCount
            ) ?? 0,
            localLearnedEntityAppliedCount: try values.decodeIfPresent(
                Int.self,
                forKey: .localLearnedEntityAppliedCount
            ) ?? 0,
            localStyleApplied: try values.decodeIfPresent(Bool.self, forKey: .localStyleApplied) ?? false,
            cloudLearnedEntitySubmittedCount: try values.decodeIfPresent(
                Int.self,
                forKey: .cloudLearnedEntitySubmittedCount
            ) ?? 0,
            cloudLearnedStyleSubmitted: try values.decodeIfPresent(
                Bool.self,
                forKey: .cloudLearnedStyleSubmitted
            ) ?? false
        )
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(ContextPersonalizationPolicy.name, forKey: .policyName)
        try values.encode(policyVersion, forKey: .policyVersion)
        try values.encode(configuredHoldoutRate, forKey: .configuredHoldoutRate)
        try values.encode(assignedVariant, forKey: .assignedVariant)
        try values.encode(personalizationOpportunity, forKey: .personalizationOpportunity)
        try values.encode(withheldByHoldout, forKey: .withheldByHoldout)
        try values.encode(packetEntityOfferedCount, forKey: .packetEntityOfferedCount)
        try values.encode(packetStyleOffered, forKey: .packetStyleOffered)
        try values.encode(
            localLearnedEntityConsideredCount,
            forKey: .localLearnedEntityConsideredCount
        )
        try values.encode(localLearnedEntityMatchedCount, forKey: .localLearnedEntityMatchedCount)
        try values.encode(localLearnedEntityAppliedCount, forKey: .localLearnedEntityAppliedCount)
        try values.encode(localStyleApplied, forKey: .localStyleApplied)
        try values.encode(
            cloudLearnedEntitySubmittedCount,
            forKey: .cloudLearnedEntitySubmittedCount
        )
        try values.encode(cloudLearnedStyleSubmitted, forKey: .cloudLearnedStyleSubmitted)
    }
}

enum DictationIntentKind: String, Codable, Sendable, CaseIterable {
    case plainDictation
    case compose
    case reply
    case rewriteSelection
    case insertReference
    case search
    case command
    case codeText
    case formFill
    case socialComment
}

struct SurfaceDescriptor: Codable, Sendable, Hashable {
    var kind: SurfaceKind
    var appName: String?
    var bundleId: String?
    var windowTitle: String?
    var browserURL: String?
    var siteHost: String?
    var siteName: String?
    var fieldKind: FieldKind
    var conversationLabel: String?
    var documentLabel: String?
    var projectLabel: String?
}

struct ContextTargetFingerprint: Codable, Sendable, Hashable {
    var role: String?
    var subrole: String?
    var isSensitiveInput: Bool? = nil
    var identifierToken: String?
    var titleToken: String?
    var descriptionToken: String?
    var placeholderToken: String?
    var helpToken: String?
    var frameBucket: String?
    var selectedRangeBucket: String?
}

struct ContextEntity: Codable, Sendable, Hashable {
    var type: ContextEntityType
    var value: String
    var normalizedValue: String
    var spokenForms: [String]
    var source: EvidenceSource
    var confidence: Double
    var recencyScore: Double
    var proximityScore: Double
    var trustTier: ContextTrustTier
    var isSensitive: Bool
    var evidence: String
    var surfaceScope: String?
    var appScope: String?
    var siteScope: String?
    var projectScope: String?
    /// Explicit origin after profile/base merging. Nil represents legacy or
    /// externally constructed entities whose provenance is uncertain.
    var personalizationOrigin: ContextValueProvenance? = nil
    /// True only when this learned winner changed the final entity payload.
    var personalizationChangedEntityPayload: Bool? = nil
    /// True only when this learned value added a term absent from the
    /// counterfactual non-learned bias payload.
    var personalizationChangedBiasPayload: Bool? = nil

    var rankingScore: Double {
        let trustBonus: Double = switch trustTier {
        case .grounding: 0.18
        case .biasTerm: 0.12
        case .styleHint: 0.06
        case .metadataOnly: 0.02
        case .blocked: -0.4
        }
        let sensitivePenalty = isSensitive ? 0.4 : 0
        return confidence + recencyScore + proximityScore + trustBonus - sensitivePenalty
    }
}

struct DictationIntent: Codable, Sendable, Hashable {
    var kind: DictationIntentKind
    var confidence: Double
    var allowsBiasTerms: Bool
    var allowsStyleHint: Bool
    var allowsSelectedTextGrounding: Bool
    var allowsVisibleContextGrounding: Bool
    var allowsMemoryGrounding: Bool
    var evidence: [String]
}

struct ContextLatencyMetrics: Codable, Sendable, Hashable {
    var hotCaptureMs: Int
    var surfaceClassifyMs: Int
    var entityExtractMs: Int
    var intentClassifyMs: Int
    var packetBuildMs: Int

    static let empty = ContextLatencyMetrics(
        hotCaptureMs: 0,
        surfaceClassifyMs: 0,
        entityExtractMs: 0,
        intentClassifyMs: 0,
        packetBuildMs: 0
    )
}

struct ContextPacket: Codable, Sendable, Hashable {
    var id: UUID
    var capturedAt: Date
    var surface: SurfaceDescriptor
    var intent: DictationIntent
    var entities: [ContextEntity]
    var styleHint: String?
    /// Few-shot pasted→edited pairs for the cloud cleanup prompt. Optional so
    /// packets persisted before this field decode unchanged.
    var editExemplars: [DictationEditExemplar]? = nil
    var personalizationProfile: PersonalizationProfileMetadata? = nil
    var personalizationExposure: ContextPersonalizationExposure? = nil
    var selectedTextPreview: String?
    var focusedFieldPreview: String?
    var targetFingerprint: ContextTargetFingerprint? = nil
    /// High-confidence focused-conversation metadata. Optional for packet
    /// compatibility; the first-name alias is consumed only by local greeting
    /// repair and is never emitted as a general decode-bias entity.
    var activeRecipient: ActiveRecipientContext? = nil
    var visibleGroundingSnippets: [String]
    var safetyFlags: [ContextSafetyFlag]
    var latency: ContextLatencyMetrics
}
