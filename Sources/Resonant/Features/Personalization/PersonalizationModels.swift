import Foundation
import SwiftData

/// Surface-scoped opening-case behavior learned from attributable edits.
enum OpeningCasePolicy: String, Codable, Sendable, CaseIterable {
    case inherit
    case lowercase
    case sentenceCase = "sentence_case"
}

/// Surface-scoped list-marker behavior learned from attributable edits.
enum ListMarkerPolicy: String, Codable, Sendable, CaseIterable {
    case inherit
    case omit
    case require
}

/// Canonical trailing-period behavior shared by local and cloud formatting.
enum TrailingPeriodPolicy: String, Codable, Sendable, CaseIterable {
    case inherit
    case omit
    case require
}

/// The directional evidence that may originate a style policy. Every count is
/// a direct, attributable pasted-to-edited transition; accepted/unchanged
/// output and raw-transcript habits never enter these counters.
struct StylePolicyEvidence: Sendable, Equatable {
    var lowercaseOpening: Int = 0
    var sentenceCaseOpening: Int = 0
    var listOmission: Int = 0
    var listRequirement: Int = 0
    var trailingPeriodOmission: Int = 0
    var trailingPeriodRequirement: Int = 0
    /// Observational confirmations never participate in policy resolution.
    var appliedPolicyConfirmations: Int = 0
}

/// One structured policy is the source of truth for both local formatting and
/// learned cloud style instructions.
struct StylePolicy: Sendable, Equatable {
    var openingCase: OpeningCasePolicy = .inherit
    var listMarkers: ListMarkerPolicy = .inherit
    var trailingPeriod: TrailingPeriodPolicy = .inherit

    static let inherit = StylePolicy()

    /// A direction activates after three direct signals and only while it has
    /// at least a 2:1 lead. Accumulating opposite evidence therefore returns a
    /// rule to inherit before enough later evidence can reverse it.
    static func resolve(evidence: StylePolicyEvidence) -> StylePolicy {
        let openingCase: OpeningCasePolicy
        switch direction(
            first: evidence.lowercaseOpening,
            second: evidence.sentenceCaseOpening
        ) {
        case .first: openingCase = .lowercase
        case .second: openingCase = .sentenceCase
        case .neither: openingCase = .inherit
        }

        let listMarkers: ListMarkerPolicy
        switch direction(
            first: evidence.listOmission,
            second: evidence.listRequirement
        ) {
        case .first: listMarkers = .omit
        case .second: listMarkers = .require
        case .neither: listMarkers = .inherit
        }

        let trailingPeriod: TrailingPeriodPolicy
        switch direction(
            first: evidence.trailingPeriodOmission,
            second: evidence.trailingPeriodRequirement
        ) {
        case .first: trailingPeriod = .omit
        case .second: trailingPeriod = .require
        case .neither: trailingPeriod = .inherit
        }

        return StylePolicy(
            openingCase: openingCase,
            listMarkers: listMarkers,
            trailingPeriod: trailingPeriod
        )
    }

    private enum Direction {
        case first
        case second
        case neither
    }

    private static func direction(first: Int, second: Int) -> Direction {
        let first = max(0, first)
        let second = max(0, second)
        if first >= 3, Double(first) >= Double(second) * 2 {
            return .first
        }
        if second >= 3, Double(second) >= Double(first) * 2 {
            return .second
        }
        return .neither
    }
}

/// Text-free explanation of what happened when an active learned rule family
/// was evaluated by the local post-processor. Only `changed` and
/// `alreadyConformed` are eligible for final-delivery confirmation; the
/// delivery boundary must still prove that the rule manifests in the actual
/// inserted baseline.
enum StyleRuleApplicationDisposition: String, Sendable, Equatable {
    case inapplicable
    case vetoed
    case changed
    case alreadyConformed = "already_conformed"
    case notManifested = "not_manifested"

    var isConfirmableCandidate: Bool {
        self == .changed || self == .alreadyConformed
    }
}

struct StyleRuleApplication<Policy: Sendable & Equatable>: Sendable, Equatable {
    let policy: Policy
    let disposition: StyleRuleApplicationDisposition

    init(_ policy: Policy, disposition: StyleRuleApplicationDisposition) {
        self.policy = policy
        self.disposition = disposition
    }
}

/// Per-family local-stage provenance. This deliberately carries no transcript
/// text. Active policies remain visible even when they were inapplicable or
/// vetoed, preventing "missing marker" from conflating those states with an
/// inherited policy.
struct StyleApplicationProvenance: Sendable, Equatable {
    var openingCase: StyleRuleApplication<OpeningCasePolicy>?
    var listMarkers: StyleRuleApplication<ListMarkerPolicy>?
    var trailingPeriod: StyleRuleApplication<TrailingPeriodPolicy>?

    init(
        openingCase: StyleRuleApplication<OpeningCasePolicy>? = nil,
        listMarkers: StyleRuleApplication<ListMarkerPolicy>? = nil,
        trailingPeriod: StyleRuleApplication<TrailingPeriodPolicy>? = nil
    ) {
        self.openingCase = openingCase
        self.listMarkers = listMarkers
        self.trailingPeriod = trailingPeriod
    }

    static let none = StyleApplicationProvenance()
}

/// Final delivery metadata recording only active learned rules that had a
/// real local opportunity and still manifest in the target-observed insertion
/// baseline. `nil` means that rule family was not confirmable; an `inherit`
/// value is never emitted as applied metadata.
struct AppliedStylePolicy: Sendable, Equatable {
    var openingCase: OpeningCasePolicy?
    var listMarkers: ListMarkerPolicy?
    var trailingPeriod: TrailingPeriodPolicy?

    init(
        openingCase: OpeningCasePolicy? = nil,
        listMarkers: ListMarkerPolicy? = nil,
        trailingPeriod: TrailingPeriodPolicy? = nil
    ) {
        self.openingCase = openingCase == .inherit ? nil : openingCase
        self.listMarkers = listMarkers == .inherit ? nil : listMarkers
        self.trailingPeriod = trailingPeriod == .inherit ? nil : trailingPeriod
    }

    static let none = AppliedStylePolicy()

    func confirms(_ policy: StylePolicy) -> Bool {
        (openingCase != nil && openingCase == policy.openingCase)
            || (listMarkers != nil && listMarkers == policy.listMarkers)
            || (trailingPeriod != nil && trailingPeriod == policy.trailingPeriod)
    }
}

@Model
final class LearnedContextEntity {
    var id: UUID
    var type: String
    var value: String
    var normalizedValue: String
    var aliasesJSON: String?
    var spokenFormsJSON: String?
    var appScope: String?
    var siteScope: String?
    var surfaceKind: String?
    var projectScope: String?
    var confidence: Double
    var positiveCount: Int
    var negativeCount: Int
    var source: String
    var isUserPinned: Bool
    var isSuppressed: Bool
    var createdAt: Date
    var lastSeenAt: Date
    var lastUsedAt: Date?

    init(
        id: UUID = UUID(),
        type: String,
        value: String,
        normalizedValue: String,
        aliasesJSON: String? = nil,
        spokenFormsJSON: String? = nil,
        appScope: String? = nil,
        siteScope: String? = nil,
        surfaceKind: String? = nil,
        projectScope: String? = nil,
        confidence: Double,
        positiveCount: Int,
        negativeCount: Int = 0,
        source: String,
        isUserPinned: Bool = false,
        isSuppressed: Bool = false,
        createdAt: Date = Date(),
        lastSeenAt: Date = Date(),
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.type = type
        self.value = value
        self.normalizedValue = normalizedValue
        self.aliasesJSON = aliasesJSON
        self.spokenFormsJSON = spokenFormsJSON
        self.appScope = appScope
        self.siteScope = siteScope
        self.surfaceKind = surfaceKind
        self.projectScope = projectScope
        self.confidence = confidence
        self.positiveCount = positiveCount
        self.negativeCount = negativeCount
        self.source = source
        self.isUserPinned = isUserPinned
        self.isSuppressed = isSuppressed
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.lastUsedAt = lastUsedAt
    }
}

@Model
final class LearnedStyleProfile {
    var id: UUID
    var scopeKey: String
    var surfaceKind: String
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
    // Formatting-edit signals (defaults keep SwiftData lightweight migration happy)
    var listMarkersStrippedCount: Int = 0
    var listMarkersKeptCount: Int = 0
    var trailingPunctuationStrippedCount: Int = 0
    // Auto-sent delivery counters — content-driven style only (defaults keep
    // SwiftData lightweight migration happy)
    var autoSentSampleCount: Int = 0
    var autoSentGreetingCount: Int = 0
    var autoSentSignoffCount: Int = 0
    var autoSentShortMessageCount: Int = 0
    var autoSentParagraphBreakCount: Int = 0
    // Attribution-safe style-policy evidence. These additive fields do not
    // reinterpret legacy samples, which may include formatter-authored output.
    var directLowercaseOpeningCount: Int = 0
    var directSentenceCaseOpeningCount: Int = 0
    var directListOmissionCount: Int = 0
    var directListRequirementCount: Int = 0
    var directTrailingPeriodOmissionCount: Int = 0
    var directTrailingPeriodRequirementCount: Int = 0
    var appliedPolicyConfirmationCount: Int = 0
    // Content habits have their own provenance-safe denominators. Direct edit
    // samples use the edited text; auto-send samples use only raw transcripts.
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

    init(
        id: UUID = UUID(),
        scopeKey: String,
        surfaceKind: String,
        appScope: String? = nil,
        siteScope: String? = nil,
        projectScope: String? = nil,
        sampleCount: Int = 0,
        acceptedCount: Int = 0,
        correctedCount: Int = 0,
        lowercaseOpeningCount: Int = 0,
        sentenceCaseOpeningCount: Int = 0,
        greetingCount: Int = 0,
        signoffCount: Int = 0,
        shortMessageCount: Int = 0,
        paragraphBreakCount: Int = 0,
        finalPunctuationCount: Int = 0,
        totalWords: Int = 0,
        listMarkersStrippedCount: Int = 0,
        listMarkersKeptCount: Int = 0,
        trailingPunctuationStrippedCount: Int = 0,
        autoSentSampleCount: Int = 0,
        autoSentGreetingCount: Int = 0,
        autoSentSignoffCount: Int = 0,
        autoSentShortMessageCount: Int = 0,
        autoSentParagraphBreakCount: Int = 0,
        directLowercaseOpeningCount: Int = 0,
        directSentenceCaseOpeningCount: Int = 0,
        directListOmissionCount: Int = 0,
        directListRequirementCount: Int = 0,
        directTrailingPeriodOmissionCount: Int = 0,
        directTrailingPeriodRequirementCount: Int = 0,
        appliedPolicyConfirmationCount: Int = 0,
        authoredHabitSampleCount: Int = 0,
        authoredGreetingCount: Int = 0,
        authoredSignoffCount: Int = 0,
        authoredShortMessageCount: Int = 0,
        authoredParagraphBreakCount: Int = 0,
        rawTranscriptHabitSampleCount: Int = 0,
        rawTranscriptGreetingCount: Int = 0,
        rawTranscriptSignoffCount: Int = 0,
        rawTranscriptShortMessageCount: Int = 0,
        rawTranscriptParagraphBreakCount: Int = 0,
        createdAt: Date = Date(),
        lastSeenAt: Date = Date()
    ) {
        self.id = id
        self.scopeKey = scopeKey
        self.surfaceKind = surfaceKind
        self.appScope = appScope
        self.siteScope = siteScope
        self.projectScope = projectScope
        self.sampleCount = sampleCount
        self.acceptedCount = acceptedCount
        self.correctedCount = correctedCount
        self.lowercaseOpeningCount = lowercaseOpeningCount
        self.sentenceCaseOpeningCount = sentenceCaseOpeningCount
        self.greetingCount = greetingCount
        self.signoffCount = signoffCount
        self.shortMessageCount = shortMessageCount
        self.paragraphBreakCount = paragraphBreakCount
        self.finalPunctuationCount = finalPunctuationCount
        self.totalWords = totalWords
        self.listMarkersStrippedCount = listMarkersStrippedCount
        self.listMarkersKeptCount = listMarkersKeptCount
        self.trailingPunctuationStrippedCount = trailingPunctuationStrippedCount
        self.autoSentSampleCount = autoSentSampleCount
        self.autoSentGreetingCount = autoSentGreetingCount
        self.autoSentSignoffCount = autoSentSignoffCount
        self.autoSentShortMessageCount = autoSentShortMessageCount
        self.autoSentParagraphBreakCount = autoSentParagraphBreakCount
        self.directLowercaseOpeningCount = directLowercaseOpeningCount
        self.directSentenceCaseOpeningCount = directSentenceCaseOpeningCount
        self.directListOmissionCount = directListOmissionCount
        self.directListRequirementCount = directListRequirementCount
        self.directTrailingPeriodOmissionCount = directTrailingPeriodOmissionCount
        self.directTrailingPeriodRequirementCount = directTrailingPeriodRequirementCount
        self.appliedPolicyConfirmationCount = appliedPolicyConfirmationCount
        self.authoredHabitSampleCount = authoredHabitSampleCount
        self.authoredGreetingCount = authoredGreetingCount
        self.authoredSignoffCount = authoredSignoffCount
        self.authoredShortMessageCount = authoredShortMessageCount
        self.authoredParagraphBreakCount = authoredParagraphBreakCount
        self.rawTranscriptHabitSampleCount = rawTranscriptHabitSampleCount
        self.rawTranscriptGreetingCount = rawTranscriptGreetingCount
        self.rawTranscriptSignoffCount = rawTranscriptSignoffCount
        self.rawTranscriptShortMessageCount = rawTranscriptShortMessageCount
        self.rawTranscriptParagraphBreakCount = rawTranscriptParagraphBreakCount
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
    }
}

@Model
final class LearnedFormatPreference {
    var id: UUID
    var categoryRaw: String
    var scopeKey: String
    var preferredValue: String
    var positiveCount: Int
    var negativeCount: Int
    var confidence: Double
    /// User-visible veto for a learned formatting rule. Declaration defaults
    /// keep lightweight SwiftData migration safe for existing rows.
    var isSuppressed: Bool = false
    /// Per-row migration marker for the dictionary-casing reconciliation.
    /// Co-locating it with suppression means an explicit restore survives
    /// future launches instead of being re-suppressed by a global flag reset.
    var suppressionReconciliationVersion: Int = 0
    var createdAt: Date
    var lastSeenAt: Date

    init(
        id: UUID = UUID(),
        categoryRaw: String,
        scopeKey: String,
        preferredValue: String,
        positiveCount: Int,
        negativeCount: Int = 0,
        confidence: Double,
        isSuppressed: Bool = false,
        suppressionReconciliationVersion: Int = 0,
        createdAt: Date = Date(),
        lastSeenAt: Date = Date()
    ) {
        self.id = id
        self.categoryRaw = categoryRaw
        self.scopeKey = scopeKey
        self.preferredValue = preferredValue
        self.positiveCount = positiveCount
        self.negativeCount = negativeCount
        self.confidence = confidence
        self.isSuppressed = isSuppressed
        self.suppressionReconciliationVersion = suppressionReconciliationVersion
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
    }
}

struct StoredCorrectionPair: Codable, Sendable, Equatable {
    var spoken: String
    var written: String
    var spokenIsRealWord: Bool
}

@Model
final class DictationCorrectionEvent {
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
    var correctionsJSON: String?
    var hadCorrection: Bool

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        appName: String? = nil,
        bundleId: String? = nil,
        windowTitle: String? = nil,
        browserURL: String? = nil,
        surfaceKind: String? = nil,
        rawTranscriptPreview: String? = nil,
        pastedTextPreview: String,
        editedTextPreview: String,
        correctionsJSON: String? = nil,
        hadCorrection: Bool
    ) {
        self.id = id
        self.timestamp = timestamp
        self.appName = appName
        self.bundleId = bundleId
        self.windowTitle = windowTitle
        self.browserURL = browserURL
        self.surfaceKind = surfaceKind
        self.rawTranscriptPreview = rawTranscriptPreview
        self.pastedTextPreview = pastedTextPreview
        self.editedTextPreview = editedTextPreview
        self.correctionsJSON = correctionsJSON
        self.hadCorrection = hadCorrection
    }

    var corrections: [StoredCorrectionPair] {
        guard let correctionsJSON,
              let data = correctionsJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([StoredCorrectionPair].self, from: data)
        else { return [] }
        return decoded
    }
}
