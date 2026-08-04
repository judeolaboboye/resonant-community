import Foundation

struct PostProcessingConfiguration: Sendable, Equatable {
    let removeFillersEnabled: Bool
    let removeFalseStartsEnabled: Bool
    let itnEnabled: Bool
    let autoPunctuationEnabled: Bool
    let bulletPointsEnabled: Bool
    let suppressTrailingPunctuation: Bool
    let flattenLineBreaks: Bool
    let chatShortMessageDefaults: Bool
    let suppressedDomainExpansionHosts: Set<String>
    let preferredPhoneStyle: String?
    let learnedWordCasings: [String: String]
    /// Learned habit: the user keeps lowercasing our capitalized openings on
    /// this surface, so final formatting skips leading capitalization.
    let suppressLeadingCapitalization: Bool
    /// Structured learned policy retained separately from surface defaults so
    /// require/omit can override a default without losing global vetoes.
    let learnedStylePolicy: StylePolicy

    init(
        removeFillersEnabled: Bool,
        removeFalseStartsEnabled: Bool,
        itnEnabled: Bool,
        autoPunctuationEnabled: Bool,
        bulletPointsEnabled: Bool,
        suppressTrailingPunctuation: Bool = false,
        flattenLineBreaks: Bool = false,
        chatShortMessageDefaults: Bool = false,
        suppressedDomainExpansionHosts: Set<String> = [],
        preferredPhoneStyle: String? = nil,
        learnedWordCasings: [String: String] = [:],
        suppressLeadingCapitalization: Bool = false,
        learnedStylePolicy: StylePolicy = .inherit
    ) {
        self.removeFillersEnabled = removeFillersEnabled
        self.removeFalseStartsEnabled = removeFalseStartsEnabled
        self.itnEnabled = itnEnabled
        self.autoPunctuationEnabled = autoPunctuationEnabled
        self.bulletPointsEnabled = bulletPointsEnabled
        self.suppressTrailingPunctuation = suppressTrailingPunctuation
        self.flattenLineBreaks = flattenLineBreaks
        self.chatShortMessageDefaults = chatShortMessageDefaults
        self.suppressedDomainExpansionHosts = suppressedDomainExpansionHosts
        self.preferredPhoneStyle = preferredPhoneStyle
        self.learnedWordCasings = learnedWordCasings
        self.suppressLeadingCapitalization = suppressLeadingCapitalization
        self.learnedStylePolicy = learnedStylePolicy
    }

    @MainActor
    static func snapshot() -> Self {
        let settings = SettingsManager.shared
        return Self(
            removeFillersEnabled: settings.removeFillersEnabled,
            removeFalseStartsEnabled: settings.removeFalseStartsEnabled,
            itnEnabled: settings.itnEnabled,
            autoPunctuationEnabled: settings.autoPunctuationEnabled,
            bulletPointsEnabled: settings.bulletPointsEnabled
        )
    }

    /// Settings express what the user wants globally; learned preferences
    /// resolve surface-scoped style choices while preserving hard global
    /// vetoes such as disabled punctuation.
    func applying(_ preferences: DictationFormattingPreferences) -> Self {
        let requestedPolicy = preferences.resolvedStylePolicy
        var policy = learnedStylePolicy
        if requestedPolicy.openingCase != .inherit {
            policy.openingCase = requestedPolicy.openingCase
        }
        if requestedPolicy.listMarkers != .inherit {
            policy.listMarkers = requestedPolicy.listMarkers
        }
        if requestedPolicy.trailingPeriod != .inherit {
            policy.trailingPeriod = requestedPolicy.trailingPeriod
        }
        let suppressOpening = switch policy.openingCase {
        case .lowercase: true
        case .sentenceCase: false
        case .inherit: suppressLeadingCapitalization
        }
        return Self(
            removeFillersEnabled: removeFillersEnabled,
            removeFalseStartsEnabled: removeFalseStartsEnabled,
            itnEnabled: itnEnabled,
            autoPunctuationEnabled: autoPunctuationEnabled,
            // Preserve the global/surface list-formatting permission as its
            // own hard-veto signal. The learned omit rule is applied by the
            // formatting stage and recorded separately in provenance.
            bulletPointsEnabled: bulletPointsEnabled,
            suppressTrailingPunctuation: suppressTrailingPunctuation,
            flattenLineBreaks: flattenLineBreaks,
            chatShortMessageDefaults: chatShortMessageDefaults,
            suppressedDomainExpansionHosts: suppressedDomainExpansionHosts
                .union(preferences.suppressedDomainExpansionHosts),
            preferredPhoneStyle: preferences.preferredPhoneStyle ?? preferredPhoneStyle,
            learnedWordCasings: learnedWordCasings.merging(preferences.learnedWordCasings) { _, new in new },
            suppressLeadingCapitalization: suppressOpening,
            learnedStylePolicy: policy
        )
    }

    /// Surface defaults inferred from the target field — single-line fields
    /// flatten breaks (and never auto-list), subject/search lines drop the
    /// trailing period, chat gets short-message norms.
    func applying(_ defaults: SurfaceFormattingDefaults) -> Self {
        Self(
            removeFillersEnabled: removeFillersEnabled,
            removeFalseStartsEnabled: removeFalseStartsEnabled,
            itnEnabled: itnEnabled,
            autoPunctuationEnabled: autoPunctuationEnabled,
            bulletPointsEnabled: bulletPointsEnabled && !defaults.flattenLineBreaks,
            suppressTrailingPunctuation: suppressTrailingPunctuation || defaults.suppressTrailingPunctuation,
            flattenLineBreaks: flattenLineBreaks || defaults.flattenLineBreaks,
            chatShortMessageDefaults: chatShortMessageDefaults || defaults.chatShortMessageDefaults,
            suppressedDomainExpansionHosts: suppressedDomainExpansionHosts,
            preferredPhoneStyle: preferredPhoneStyle,
            learnedWordCasings: learnedWordCasings,
            suppressLeadingCapitalization: suppressLeadingCapitalization,
            learnedStylePolicy: learnedStylePolicy
        )
    }
}

struct PostProcessingResult: Sendable, Equatable {
    let text: String
    let trace: PostProcessingTrace
    let contextEntityRepairProvenance: ContextualEntityRepairProvenance
    let styleApplicationProvenance: StyleApplicationProvenance

    init(
        text: String,
        trace: PostProcessingTrace,
        contextEntityRepairProvenance: ContextualEntityRepairProvenance = .none,
        styleApplicationProvenance: StyleApplicationProvenance = .none
    ) {
        self.text = text
        self.trace = trace
        self.contextEntityRepairProvenance = contextEntityRepairProvenance
        self.styleApplicationProvenance = styleApplicationProvenance
    }
}

struct PostProcessingTrace: Sendable, Equatable {
    struct StageChange: Sendable, Equatable {
        let stage: String
        let changed: Bool
        let beforeLengthBucket: String
        let afterLengthBucket: String
    }

    let rawCharacterCount: Int
    let finalCharacterCount: Int
    let rawLengthBucket: String
    let finalLengthBucket: String
    let changed: Bool
    let stageChanges: [StageChange]

    var changedStageCount: Int {
        stageChanges.filter(\.changed).count
    }

    var changedStageNames: [String] {
        stageChanges.filter(\.changed).map(\.stage)
    }

    static func lengthBucket(_ count: Int) -> String {
        switch count {
        case ..<0:
            return "unknown"
        case 0:
            return "0"
        case 1...24:
            return "1-24"
        case 25...79:
            return "25-79"
        case 80...199:
            return "80-199"
        case 200...499:
            return "200-499"
        default:
            return "500+"
        }
    }
}

/// Runs the full post-processing pipeline on raw ASR text.
/// Stage order (mirrors Almond's 15-stage pipeline, simplified for v1):
///   1. Filler + false-start removal
///   2. ITN (numbers, currency, ordinals, times)
///   3. Dictionary correction (user learned words)
///   4. Formatting cleanup
/// Delivery-only enrichments such as smart links run later so cloud cleanup
/// cannot rewrite or strip them.
@MainActor
final class PostProcessor {

    private let dictionaryStore: DictionaryStore
    private let worker = PostProcessingWorker()

    /// Learned per-surface formatting preferences (set at app wiring time).
    weak var formattingPreferenceProvider: (any FormattingPreferenceProviding)?

    init(dictionaryStore: DictionaryStore) {
        self.dictionaryStore = dictionaryStore
    }

    func process(_ raw: String, contextPacket: ContextPacket? = nil) async -> String {
        await processDetailed(raw, contextPacket: contextPacket).text
    }

    func processDetailed(
        _ raw: String,
        contextPacket: ContextPacket? = nil,
        tokenTimings: [TranscriptTokenTiming] = [],
        language: String? = nil
    ) async -> PostProcessingResult {
        guard !raw.isEmpty else {
            return PostProcessingResult(
                text: raw,
                trace: PostProcessingTrace(
                    rawCharacterCount: raw.count,
                    finalCharacterCount: raw.count,
                    rawLengthBucket: PostProcessingTrace.lengthBucket(raw.count),
                    finalLengthBucket: PostProcessingTrace.lengthBucket(raw.count),
                    changed: false,
                    stageChanges: []
                )
            )
        }
        var configuration = PostProcessingConfiguration.snapshot()
        configuration = configuration.applying(SurfaceFormattingDefaults.infer(from: contextPacket))
        if let surface = contextPacket?.surface,
           let preferences = formattingPreferenceProvider?.formattingPreferences(for: surface) {
            configuration = configuration.applying(preferences)
        }
        let corrections = dictionaryStore.correctionSnapshot()
        return await worker.processDetailed(
            raw,
            configuration: configuration,
            corrections: corrections,
            contextPacket: contextPacket,
            tokenTimings: tokenTimings,
            language: language
        )
    }
}

private actor PostProcessingWorker {
    func process(
        _ raw: String,
        configuration: PostProcessingConfiguration,
        corrections: [DictionaryCorrectionSnapshot],
        contextPacket: ContextPacket?
    ) -> String {
        processDetailed(
            raw,
            configuration: configuration,
            corrections: corrections,
            contextPacket: contextPacket
        ).text
    }

    func processDetailed(
        _ raw: String,
        configuration: PostProcessingConfiguration,
        corrections: [DictionaryCorrectionSnapshot],
        contextPacket: ContextPacket?,
        tokenTimings: [TranscriptTokenTiming] = [],
        language: String? = nil
    ) -> PostProcessingResult {
        PostProcessingPipeline.run(
            raw,
            configuration: configuration,
            corrections: corrections,
            contextPacket: contextPacket,
            tokenTimings: tokenTimings,
            language: language
        )
    }
}

/// The synchronous, side-effect-free stage runner. Lives outside the worker
/// actor so the replay harness can re-run stored transcripts through the
/// exact production pipeline.
enum PostProcessingPipeline {
    private static let fillerRemover = FillerRemover()
    private static let itnProcessor = ITNProcessor()

    /// Strips leaked model control tokens (e.g. `<|ps|>`, `<|en|>`) that the
    /// v3 vocabulary can emit when the TDT decoder mispredicts a special token.
    private static let specialTokenPattern = try! NSRegularExpression(
        pattern: #"<\|[^|]+\|>"#
    )

    static func run(
        _ raw: String,
        configuration: PostProcessingConfiguration,
        corrections: [DictionaryCorrectionSnapshot],
        contextPacket: ContextPacket? = nil,
        tokenTimings: [TranscriptTokenTiming] = [],
        language: String? = nil
    ) -> PostProcessingResult {
        guard !raw.isEmpty else {
            return PostProcessingResult(
                text: raw,
                trace: PostProcessingTrace(
                    rawCharacterCount: raw.count,
                    finalCharacterCount: raw.count,
                    rawLengthBucket: PostProcessingTrace.lengthBucket(raw.count),
                    finalLengthBucket: PostProcessingTrace.lengthBucket(raw.count),
                    changed: false,
                    stageChanges: []
                )
            )
        }
        var text = raw
        var stageChanges: [PostProcessingTrace.StageChange] = []

        // 0. Strip leaked special tokens before any other processing
        applyStage("special_tokens", to: &text, stageChanges: &stageChanges) { input in
            Self.specialTokenPattern.stringByReplacingMatches(
                in: input,
                range: NSRange(input.startIndex..., in: input),
                withTemplate: ""
            )
        }

        // 0.15. Pause-delimited number lists: real gaps between spoken numbers
        // become list commas while token timings still align with the raw
        // text, so ITN can't fuse separate items into times or years.
        if configuration.itnEnabled, !tokenTimings.isEmpty {
            applyStage("number_list_delimiting", to: &text, stageChanges: &stageChanges) {
                NumberListSegmenter.delimit($0, timings: tokenTimings)
            }
        } else {
            recordUnchangedStage("number_list_delimiting", text: text, stageChanges: &stageChanges)
        }

        // 0.2. Pause-driven sentence/paragraph segmentation from token
        // timings — runs on the rawest text where tokens still align, and
        // bails entirely on any alignment mismatch.
        if configuration.autoPunctuationEnabled, !tokenTimings.isEmpty {
            applyStage("pause_segmentation", to: &text, stageChanges: &stageChanges) {
                PauseSegmenter.segment($0, timings: tokenTimings)
            }
        } else {
            recordUnchangedStage("pause_segmentation", text: text, stageChanges: &stageChanges)
        }

        // 0.5. Repair lost SentencePiece boundaries before downstream cleanup.
        applyStage("collapsed_run_repair", to: &text, stageChanges: &stageChanges) {
            CollapsedRunRepair.repair($0)
        }

        // 0.6. Repair suspicious intra-word spacing like
        // `t rans format i on` -> `transformation`. Token timings gate
        // two-fragment joins: a real pause between the halves blocks the join.
        applyStage("fragmented_word_repair", to: &text, stageChanges: &stageChanges) {
            FragmentedWordRepair.repair(
                $0,
                timings: tokenTimings,
                language: language,
                removeFalseStarts: configuration.removeFalseStartsEnabled
            )
        }

        // 1. Fillers / false starts (settings-gated)
        applyStage("filler_removal", to: &text, stageChanges: &stageChanges) { input in
            fillerRemover.process(
                input,
                removeFillersEnabled: configuration.removeFillersEnabled,
                removeFalseStartsEnabled: configuration.removeFalseStartsEnabled
            )
        }

        // 2. ITN
        if configuration.itnEnabled {
            applyStage("itn", to: &text, stageChanges: &stageChanges) { input in
                itnProcessor.process(
                    input,
                    autoPunctuationEnabled: configuration.autoPunctuationEnabled,
                    phoneStyle: PhoneNumberRecomposer.style(named: configuration.preferredPhoneStyle)
                )
            }
        } else {
            recordUnchangedStage("itn", text: text, stageChanges: &stageChanges)
        }

        // 2.5. Spoken structural commands ("new line", "new paragraph",
        // "bullet point") become literal layout. Gated with auto-punctuation:
        // a user who wants "period" kept literal wants "new line" literal too.
        if configuration.autoPunctuationEnabled {
            applyStage("spoken_commands", to: &text, stageChanges: &stageChanges) {
                SpokenCommandProcessor.process($0)
            }
        } else {
            recordUnchangedStage("spoken_commands", text: text, stageChanges: &stageChanges)
        }

        // 3. Dictionary corrections
        applyStage("dictionary_correction", to: &text, stageChanges: &stageChanges) {
            DictionaryCorrectionApplier.apply(corrections, to: $0)
        }

        // 3.5. Learned casing — the case-only corrections the user keeps
        // making that the word-level dictionary diff discards.
        applyStage("learned_casing", to: &text, stageChanges: &stageChanges) {
            LearnedCasingApplier.apply(configuration.learnedWordCasings, to: $0)
        }

        // 4. Contextual entity repair: exact visible names, handles, files,
        // tickets, and identifiers only when the transcript plausibly said them.
        var contextEntityRepairProvenance = ContextualEntityRepairProvenance.none
        applyStage("contextual_entity_repair", to: &text, stageChanges: &stageChanges) {
            let repair = ContextualEntityRepair.repair(
                $0,
                using: contextPacket,
                suppressedDomainHosts: configuration.suppressedDomainExpansionHosts
            )
            contextEntityRepairProvenance = repair.personalization
            return repair.text
        }

        // 5. Final formatting. Keep the pre-family input only long enough to
        // derive text-free opportunity/application provenance after all later
        // local stages have run.
        let inputBeforeFinalFormatting = text
        applyStage("final_formatting", to: &text, stageChanges: &stageChanges) { input in
            let chatShortMessage = configuration.chatShortMessageDefaults
                && Self.isShortChatMessage(input)
            let capitalizeLeadingLetters = switch configuration.learnedStylePolicy.openingCase {
            case .lowercase:
                false
            case .sentenceCase:
                true
            case .inherit:
                !configuration.suppressLeadingCapitalization
            }
            let ensureTrailingPunctuation = switch configuration.learnedStylePolicy.trailingPeriod {
            case .omit:
                false
            case .require:
                configuration.autoPunctuationEnabled
            case .inherit:
                configuration.autoPunctuationEnabled
                    && !configuration.suppressTrailingPunctuation
                    && !chatShortMessage
            }
            var styledInput = input
            if configuration.learnedStylePolicy.openingCase == .lowercase {
                styledInput = Self.lowercasedOpening(in: styledInput)
            }
            if configuration.autoPunctuationEnabled,
               configuration.learnedStylePolicy.trailingPeriod == .omit {
                styledInput = Self.removingTrailingPeriod(from: styledInput)
            }
            return TextFormatter.finalize(
                styledInput,
                bulletPointsEnabled: configuration.bulletPointsEnabled
                    && configuration.learnedStylePolicy.listMarkers != .omit,
                ensureTrailingPunctuation: ensureTrailingPunctuation,
                capitalizeLeadingLetters: capitalizeLeadingLetters
            )
        }

        // 6. Question inference — runs after trailing punctuation exists so
        // the period it flips is already in place. Chat short messages and a
        // learned declarative-period omission can intentionally leave the
        // final sentence unterminated, but neither may suppress a semantic
        // question mark.
        if configuration.autoPunctuationEnabled {
            applyStage("question_inference", to: &text, stageChanges: &stageChanges) {
                QuestionInference.apply(
                    to: $0,
                    appendWhenUnterminated: configuration.chatShortMessageDefaults
                        || configuration.learnedStylePolicy.trailingPeriod == .omit
                )
            }
        } else {
            recordUnchangedStage("question_inference", text: text, stageChanges: &stageChanges)
        }

        // 7. Single-line targets can't render line breaks — flatten to "; ".
        if configuration.flattenLineBreaks {
            applyStage("line_break_flattening", to: &text, stageChanges: &stageChanges) {
                TextFormatter.flattenedLineBreaks($0)
            }
        } else {
            recordUnchangedStage("line_break_flattening", text: text, stageChanges: &stageChanges)
        }

        let styleApplicationProvenance = StyleDeliveryProvenanceResolver
            .postProcessingProvenance(
                policy: configuration.learnedStylePolicy,
                autoPunctuationEnabled: configuration.autoPunctuationEnabled,
                listFormattingEnabled: configuration.bulletPointsEnabled,
                inputBeforeFinalFormatting: inputBeforeFinalFormatting,
                finalLocalText: text
            )

        return PostProcessingResult(
            text: text,
            trace: PostProcessingTrace(
                rawCharacterCount: raw.count,
                finalCharacterCount: text.count,
                rawLengthBucket: PostProcessingTrace.lengthBucket(raw.count),
                finalLengthBucket: PostProcessingTrace.lengthBucket(text.count),
                changed: text != raw,
                stageChanges: stageChanges
            ),
            contextEntityRepairProvenance: contextEntityRepairProvenance,
            styleApplicationProvenance: styleApplicationProvenance
        )
    }

    private static func applyStage(
        _ stage: String,
        to text: inout String,
        stageChanges: inout [PostProcessingTrace.StageChange],
        transform: (String) -> String
    ) {
        let before = text
        let after = transform(before)
        stageChanges.append(PostProcessingTrace.StageChange(
            stage: stage,
            changed: after != before,
            beforeLengthBucket: PostProcessingTrace.lengthBucket(before.count),
            afterLengthBucket: PostProcessingTrace.lengthBucket(after.count)
        ))
        text = after
    }

    /// Chat norm applies to one short line — anything longer reads as prose.
    private static func isShortChatMessage(_ text: String) -> Bool {
        guard !text.contains("\n") else { return false }
        return text.split(whereSeparator: \.isWhitespace).count <= 12
    }

    /// Lowercase is an active directional policy, not merely permission to
    /// skip capitalization. ASR or cloud output can already be sentence case.
    private static func lowercasedOpening(in text: String) -> String {
        guard let index = text.firstIndex(where: \.isLetter) else { return text }
        let letter = text[index]
        guard letter.isUppercase else { return text }
        var result = text
        result.replaceSubrange(index...index, with: letter.lowercased())
        return result
    }

    /// Learned omission actively removes one ordinary terminal period. It
    /// leaves questions, exclamations, and ellipses intact.
    private static func removingTrailingPeriod(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix("."), !trimmed.hasSuffix("..") else { return text }
        return String(trimmed.dropLast())
    }

    private static func recordUnchangedStage(
        _ stage: String,
        text: String,
        stageChanges: inout [PostProcessingTrace.StageChange]
    ) {
        let bucket = PostProcessingTrace.lengthBucket(text.count)
        stageChanges.append(PostProcessingTrace.StageChange(
            stage: stage,
            changed: false,
            beforeLengthBucket: bucket,
            afterLengthBucket: bucket
        ))
    }
}
