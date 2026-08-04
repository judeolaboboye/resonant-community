import Foundation

/// Text-free record of the stages between local post-processing and physical
/// insertion. It lets the final resolver invalidate provenance when a stage
/// replaced its source and apply family-specific caution to suffix rewrites.
struct StyleDeliveryStageTrace: Sendable, Equatable {
    let cloudOrSelectionReplacedPostProcessing: Bool
    let smartLinksChangedText: Bool
    let duplicateClosingChangedText: Bool
    let signatureChangedText: Bool

    init(
        cloudOrSelectionReplacedPostProcessing: Bool = false,
        smartLinksChangedText: Bool = false,
        duplicateClosingChangedText: Bool = false,
        signatureChangedText: Bool = false
    ) {
        self.cloudOrSelectionReplacedPostProcessing = cloudOrSelectionReplacedPostProcessing
        self.smartLinksChangedText = smartLinksChangedText
        self.duplicateClosingChangedText = duplicateClosingChangedText
        self.signatureChangedText = signatureChangedText
    }

    static let localOnly = StyleDeliveryStageTrace()
}

/// Resolves style evidence at its two truth boundaries:
///
/// 1. The post-processor records whether each active family had an opportunity
///    and changed/already matched the final local output.
/// 2. The delivery boundary narrows those candidates against the best actual
///    insertion baseline. Only then is `AppliedStylePolicy` created.
enum StyleDeliveryProvenanceResolver {
    static func postProcessingProvenance(
        policy: StylePolicy,
        autoPunctuationEnabled: Bool,
        listFormattingEnabled: Bool,
        inputBeforeFinalFormatting: String,
        finalLocalText: String
    ) -> StyleApplicationProvenance {
        StyleApplicationProvenance(
            openingCase: openingCaseApplication(
                policy: policy.openingCase,
                input: inputBeforeFinalFormatting,
                finalText: finalLocalText
            ),
            listMarkers: listMarkerApplication(
                policy: policy.listMarkers,
                listFormattingEnabled: listFormattingEnabled,
                input: inputBeforeFinalFormatting,
                finalText: finalLocalText
            ),
            trailingPeriod: trailingPeriodApplication(
                policy: policy.trailingPeriod,
                autoPunctuationEnabled: autoPunctuationEnabled,
                input: inputBeforeFinalFormatting,
                finalText: finalLocalText
            )
        )
    }

    /// Converts local candidates into the only marker correction learning may
    /// consume. `targetObservedSettledText` is authoritative when available;
    /// `effectiveInsertedText` is the fallback. Requested/local text is never
    /// treated as proof that insertion preserved a rule.
    static func appliedPolicyAtDelivery(
        provenance: StyleApplicationProvenance,
        localPostProcessedText: String,
        resolvedText: String,
        requestedDeliveryText: String,
        stageTrace: StyleDeliveryStageTrace,
        deliveryOutcome: PasteManager.DeliveryOutcome
    ) -> AppliedStylePolicy {
        guard deliveryOutcome.delivered,
              !stageTrace.cloudOrSelectionReplacedPostProcessing,
              resolvedText == localPostProcessedText,
              deliveryOutcome.requestedText == requestedDeliveryText,
              let baseline = deliveryOutcome.targetObservedSettledText
                ?? deliveryOutcome.effectiveInsertedText,
              !baseline.isEmpty else {
            return .none
        }

        let openingCase: OpeningCasePolicy? = {
            guard let application = provenance.openingCase,
                  application.disposition.isConfirmableCandidate,
                  openingPolicyManifests(application.policy, in: baseline) else {
                return nil
            }
            return application.policy
        }()

        let listMarkers: ListMarkerPolicy? = {
            guard let application = provenance.listMarkers,
                  application.disposition.isConfirmableCandidate,
                  listPolicyManifests(application.policy, in: baseline) else {
                return nil
            }
            return application.policy
        }()

        let trailingPeriod: TrailingPeriodPolicy? = {
            // An appended signature changes which semantic body owns terminal
            // punctuation. Its footer must never masquerade as confirmation of
            // the dictated body's period policy.
            guard !stageTrace.signatureChangedText,
                  let application = provenance.trailingPeriod,
                  application.disposition.isConfirmableCandidate,
                  trailingPeriodPolicyManifests(application.policy, in: baseline) else {
                return nil
            }
            return application.policy
        }()

        return AppliedStylePolicy(
            openingCase: openingCase,
            listMarkers: listMarkers,
            trailingPeriod: trailingPeriod
        )
    }

    private static func openingCaseApplication(
        policy: OpeningCasePolicy,
        input: String,
        finalText: String
    ) -> StyleRuleApplication<OpeningCasePolicy>? {
        guard policy != .inherit else { return nil }
        guard let inputLetter = firstCasedLetter(in: input) else {
            return StyleRuleApplication(policy, disposition: .inapplicable)
        }
        guard openingPolicyManifests(policy, in: finalText) else {
            return StyleRuleApplication(policy, disposition: .notManifested)
        }
        let alreadyConformed = switch policy {
        case .lowercase: inputLetter.isLowercase
        case .sentenceCase: inputLetter.isUppercase
        case .inherit: false
        }
        return StyleRuleApplication(
            policy,
            disposition: alreadyConformed ? .alreadyConformed : .changed
        )
    }

    private static func listMarkerApplication(
        policy: ListMarkerPolicy,
        listFormattingEnabled: Bool,
        input: String,
        finalText: String
    ) -> StyleRuleApplication<ListMarkerPolicy>? {
        guard policy != .inherit else { return nil }
        guard listFormattingEnabled else {
            return StyleRuleApplication(policy, disposition: .vetoed)
        }
        guard TextFormatter.hasListMarkerOpportunity(in: input) else {
            return StyleRuleApplication(policy, disposition: .inapplicable)
        }

        let inputHasMarkers = TextFormatter.hasListMarkers(in: input)
        let finalHasMarkers = TextFormatter.hasListMarkers(in: finalText)
        switch policy {
        case .require:
            guard finalHasMarkers else {
                return StyleRuleApplication(policy, disposition: .notManifested)
            }
            return StyleRuleApplication(
                policy,
                disposition: inputHasMarkers ? .alreadyConformed : .changed
            )
        case .omit:
            guard !finalHasMarkers else {
                return StyleRuleApplication(policy, disposition: .notManifested)
            }
            return StyleRuleApplication(
                policy,
                disposition: inputHasMarkers ? .changed : .alreadyConformed
            )
        case .inherit:
            return nil
        }
    }

    private static func trailingPeriodApplication(
        policy: TrailingPeriodPolicy,
        autoPunctuationEnabled: Bool,
        input: String,
        finalText: String
    ) -> StyleRuleApplication<TrailingPeriodPolicy>? {
        guard policy != .inherit else { return nil }
        guard autoPunctuationEnabled else {
            return StyleRuleApplication(policy, disposition: .vetoed)
        }

        let inputState = TextFormatter.ordinaryTrailingPeriodState(in: input)
        let finalState = TextFormatter.ordinaryTrailingPeriodState(in: finalText)
        guard inputState != .inapplicable, finalState != .inapplicable else {
            return StyleRuleApplication(policy, disposition: .inapplicable)
        }

        let finalConforms = switch policy {
        case .require: finalState == .present
        case .omit: finalState == .absent
        case .inherit: false
        }
        guard finalConforms else {
            return StyleRuleApplication(policy, disposition: .notManifested)
        }

        let inputConformed = switch policy {
        case .require: inputState == .present
        case .omit: inputState == .absent
        case .inherit: false
        }
        return StyleRuleApplication(
            policy,
            disposition: inputConformed ? .alreadyConformed : .changed
        )
    }

    private static func openingPolicyManifests(
        _ policy: OpeningCasePolicy,
        in text: String
    ) -> Bool {
        guard let letter = firstCasedLetter(in: text) else { return false }
        switch policy {
        case .lowercase: return letter.isLowercase
        case .sentenceCase: return letter.isUppercase
        case .inherit: return false
        }
    }

    private static func listPolicyManifests(
        _ policy: ListMarkerPolicy,
        in text: String
    ) -> Bool {
        switch policy {
        case .require:
            return TextFormatter.hasListMarkers(in: text)
        case .omit:
            return TextFormatter.hasAutomaticListOpportunity(in: text)
                && !TextFormatter.hasListMarkers(in: text)
        case .inherit:
            return false
        }
    }

    private static func trailingPeriodPolicyManifests(
        _ policy: TrailingPeriodPolicy,
        in text: String
    ) -> Bool {
        let state = TextFormatter.ordinaryTrailingPeriodState(in: text)
        switch policy {
        case .require: return state == .present
        case .omit: return state == .absent
        case .inherit: return false
        }
    }

    private static func firstCasedLetter(in text: String) -> Character? {
        text.first { character in
            character.isLetter && (character.isLowercase || character.isUppercase)
        }
    }
}
