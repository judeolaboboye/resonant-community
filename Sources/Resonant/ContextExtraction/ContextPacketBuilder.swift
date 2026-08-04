import Foundation

enum DictationIntentClassifier {
    static func classify(
        transcript: String,
        surface: SurfaceDescriptor,
        selectedText: String?,
        focusedFieldContent: String?
    ) -> DictationIntent {
        let normalizedTranscript = transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let hasSelection = selectedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        var evidence: [String] = []

        if hasSelection, containsAny(normalizedTranscript, rewriteCues) {
            evidence.append("selected text with rewrite cue")
            return intent(
                .rewriteSelection,
                confidence: 0.88,
                selectedGrounding: true,
                visibleGrounding: false,
                evidence: evidence
            )
        }

        if surface.fieldKind == .search || surface.kind == .search || startsWithAny(normalizedTranscript, searchCues) {
            evidence.append("search surface or cue")
            return intent(.search, confidence: 0.86, style: false, evidence: evidence)
        }

        if surface.kind == .code || surface.fieldKind == .code || containsAny(normalizedTranscript, codeCues) {
            evidence.append("code surface or cue")
            return intent(.codeText, confidence: surface.kind == .code ? 0.86 : 0.68, evidence: evidence)
        }

        if startsWithAny(normalizedTranscript, replyCues)
            || (surface.kind == .email && containsAny(normalizedTranscript, replySoftCues))
            || (surface.kind == .chat && containsAny(normalizedTranscript, replySoftCues)) {
            evidence.append("reply cue")
            return intent(
                .reply,
                confidence: 0.82,
                selectedGrounding: hasSelection,
                visibleGrounding: true,
                evidence: evidence
            )
        }

        if surface.kind == .social {
            evidence.append("social surface")
            return intent(.socialComment, confidence: 0.78, evidence: evidence)
        }

        if surface.fieldKind == .subject || surface.fieldKind == .title || normalizedTranscript.split(separator: " ").count <= 6 {
            evidence.append("short form-like dictation")
            return intent(.formFill, confidence: 0.58, evidence: evidence)
        }

        if surface.kind == .email || surface.kind == .chat || surface.fieldKind == .compose {
            evidence.append("compose surface")
            return intent(.compose, confidence: 0.72, evidence: evidence)
        }

        return intent(.plainDictation, confidence: 0.66, evidence: ["default"])
    }

    private static func intent(
        _ kind: DictationIntentKind,
        confidence: Double,
        bias: Bool = true,
        style: Bool = true,
        selectedGrounding: Bool = false,
        visibleGrounding: Bool = false,
        memoryGrounding: Bool = false,
        evidence: [String]
    ) -> DictationIntent {
        DictationIntent(
            kind: kind,
            confidence: confidence,
            allowsBiasTerms: bias,
            allowsStyleHint: style,
            allowsSelectedTextGrounding: selectedGrounding,
            allowsVisibleContextGrounding: visibleGrounding,
            allowsMemoryGrounding: memoryGrounding,
            evidence: evidence
        )
    }

    private static func containsAny(_ text: String, _ needles: Set<String>) -> Bool {
        needles.contains(where: { text.contains($0) })
    }

    private static func startsWithAny(_ text: String, _ needles: Set<String>) -> Bool {
        needles.contains(where: { text.hasPrefix($0) })
    }

    private static let replyCues: Set<String> = [
        "reply", "respond", "answer", "tell them", "tell her", "tell him",
        "let them know", "say that", "say ", "send back"
    ]
    private static let replySoftCues: Set<String> = [
        "tell them", "tell her", "tell him", "let them know", "say that"
    ]
    private static let rewriteCues: Set<String> = [
        "rewrite", "make this", "shorten", "clean this", "improve this",
        "make it", "turn this", "summarize this"
    ]
    private static let searchCues: Set<String> = [
        "search for", "look up", "google", "find "
    ]
    private static let codeCues: Set<String> = [
        "function", "variable", "class", "struct", "import", "commit",
        "pull request", "pr ", "branch", "file", "run ", "terminal"
    ]
}

enum ContextPacketBuilder {
    static let focusedPreviewLimit = 240
    static let selectedPreviewLimit = 240
    static let groundingSnippetLimit = 3
    static let groundingSnippetCharacters = 180

    static func build(
        transcript: String,
        hot: ContextExtractor.HotContext,
        cold: ContextExtractor.ColdContext? = nil,
        selectedTextOverride: String? = nil,
        recentTerms: [String] = [],
        personalizationSnapshot: PersonalizationMemorySnapshot? = nil,
        personalizationProfile: VersionedPersonalizationProfile? = nil
    ) -> ContextPacket {
        let started = DispatchTime.now()
        let surfaceStarted = DispatchTime.now()
        let surface = SurfaceClassifier.classify(hot: hot)
        let surfaceMs = elapsedMs(since: surfaceStarted)
        let availablePersonalizationSnapshot = personalizationProfile?.availableSnapshot
            ?? personalizationSnapshot
        let appliesLearnedPersonalization: Bool = if let personalizationProfile {
            personalizationProfile.metadata.variant == .personalized
        } else {
            availablePersonalizationSnapshot != nil
        }

        let entityStarted = DispatchTime.now()
        let extractedEntities = ContextEntityExtractor.extract(
            surface: surface,
            hot: hot,
            cold: cold,
            transcript: transcript,
            recentTerms: recentTerms
        ).map { marked($0, provenance: $0.source == .dictionary ? .manual : .base) }
        let personalizedEntities = (availablePersonalizationSnapshot?.entities ?? []).map {
            marked($0, provenance: $0.source == .dictionary ? .manual : .learned)
        }
        let manualEntities = personalizedEntities.filter { $0.personalizationOrigin == .manual }
        let learnedEntities = personalizedEntities.filter { $0.personalizationOrigin == .learned }
        let baselineEntities = mergeEntities(extractedEntities + manualEntities)
        let candidateEntities = annotatedCandidateEntities(
            mergeEntities(extractedEntities + manualEntities + learnedEntities),
            baseline: baselineEntities
        )
        let entities = appliesLearnedPersonalization ? candidateEntities : baselineEntities
        let entityMs = elapsedMs(since: entityStarted)

        let selectedText = selectedTextOverride ?? hot.selectedText
        let intentStarted = DispatchTime.now()
        let intent = DictationIntentClassifier.classify(
            transcript: transcript,
            surface: surface,
            selectedText: selectedText,
            focusedFieldContent: hot.focusedFieldContent
        )
        let intentMs = elapsedMs(since: intentStarted)

        let baseStyleHint = intent.allowsStyleHint ? styleHint(surface: surface) : nil
        let learnedStyleHint = intent.allowsStyleHint
            ? normalizedStyleHint(availablePersonalizationSnapshot?.styleHint)
            : nil
        let candidateStyleHint = combinedStyleHint(
            base: baseStyleHint,
            learned: learnedStyleHint
        )
        let styleOpportunity = learnedStyleHint != nil
            && candidateStyleHint != baseStyleHint
        let actualStyleHint = appliesLearnedPersonalization
            ? candidateStyleHint
            : baseStyleHint
        let entityOpportunityCount = candidateEntities.filter {
            $0.personalizationOrigin == .learned
                && $0.personalizationChangedEntityPayload == true
        }.count
        let personalizationOpportunity = entityOpportunityCount > 0
            || styleOpportunity
        let packetEntityOfferedCount = appliesLearnedPersonalization
            ? entityOpportunityCount
            : 0
        let packetStyleOffered = appliesLearnedPersonalization && styleOpportunity
        let assignedVariant = ContextPersonalizationAssignedVariant(
            personalizationProfile?.metadata.variant
        )
        let exposure = ContextPersonalizationExposure(
            policyVersion: personalizationProfile?.metadata.assignmentPolicyVersion
                ?? ContextPersonalizationPolicy.version,
            configuredHoldoutRate: personalizationProfile?.metadata.holdoutRate
                ?? ContextPersonalizationPolicy.defaultHoldoutRate,
            assignedVariant: assignedVariant,
            personalizationOpportunity: personalizationOpportunity,
            withheldByHoldout: assignedVariant == .holdout && personalizationOpportunity,
            packetEntityOfferedCount: packetEntityOfferedCount,
            packetStyleOffered: packetStyleOffered
        )
        let safetyFlags = safetyFlags(
            surface: surface,
            entities: entities,
            hot: hot,
            cold: cold,
            intent: intent
        )
        let groundingSnippets = groundingSnippets(
            cold: cold,
            intent: intent,
            surface: surface
        )

        return ContextPacket(
            id: UUID(),
            capturedAt: Date(),
            surface: surface,
            intent: intent,
            entities: entities,
            styleHint: actualStyleHint,
            editExemplars: appliesLearnedPersonalization
                ? availablePersonalizationSnapshot?.editExemplars
                : [],
            personalizationProfile: personalizationProfile?.metadata,
            personalizationExposure: exposure,
            selectedTextPreview: preview(selectedText, limit: selectedPreviewLimit),
            focusedFieldPreview: preview(hot.focusedFieldContent, limit: focusedPreviewLimit),
            targetFingerprint: hot.targetFingerprint,
            activeRecipient: hot.activeRecipient,
            visibleGroundingSnippets: groundingSnippets,
            safetyFlags: safetyFlags,
            latency: ContextLatencyMetrics(
                hotCaptureMs: 0,
                surfaceClassifyMs: surfaceMs,
                entityExtractMs: entityMs,
                intentClassifyMs: intentMs,
                packetBuildMs: elapsedMs(since: started)
            )
        )
    }

    static func build(
        transcript: String,
        context: ContextExtractor.Context,
        recentTerms: [String] = [],
        personalizationSnapshot: PersonalizationMemorySnapshot? = nil,
        personalizationProfile: VersionedPersonalizationProfile? = nil
    ) -> ContextPacket {
        let hot = ContextExtractor.HotContext(
            appName: context.appName,
            bundleId: context.bundleId,
            windowTitle: context.windowTitle,
            browserURL: context.browserURL,
            selectedText: context.selectedText,
            selectedRange: context.selectedRange,
            focusedFieldContent: context.focusedFieldContent,
            targetFingerprint: context.targetFingerprint
        )
        let cold = ContextExtractor.ColdContext(
            codeFiles: context.codeFiles,
            slackMembers: context.slackMembers,
            visibleTextSnippets: context.visibleTextSnippets
        )
        return build(
            transcript: transcript,
            hot: hot,
            cold: cold,
            selectedTextOverride: context.selectedText,
            recentTerms: recentTerms,
            personalizationSnapshot: personalizationSnapshot,
            personalizationProfile: personalizationProfile
        )
    }

    private struct BiasEntry {
        let value: String
    }

    private static func mergeEntities(_ entities: [ContextEntity]) -> [ContextEntity] {
        var merged: [String: ContextEntity] = [:]

        for entity in entities {
            let key = "\(entity.type.rawValue):\(entity.normalizedValue)"
            if let existing = merged[key] {
                merged[key] = existing.rankingScore >= entity.rankingScore ? existing : entity
            } else {
                merged[key] = entity
            }
        }

        return merged.values
            .sorted { lhs, rhs in
                if lhs.rankingScore == rhs.rankingScore {
                    return lhs.value < rhs.value
                }
                return lhs.rankingScore > rhs.rankingScore
            }
            .prefix(40)
            .map { $0 }
    }

    private static func marked(
        _ entity: ContextEntity,
        provenance: ContextValueProvenance
    ) -> ContextEntity {
        var marked = entity
        marked.personalizationOrigin = provenance
        marked.personalizationChangedEntityPayload = false
        marked.personalizationChangedBiasPayload = false
        return marked
    }

    private static func annotatedCandidateEntities(
        _ candidates: [ContextEntity],
        baseline: [ContextEntity]
    ) -> [ContextEntity] {
        let baselineBiasValues = Dictionary(
            uniqueKeysWithValues: biasEntries(from: baseline, limit: 40).map {
                (normalizedBiasValue($0.value), $0.value.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        )
        var annotated = candidates
        for index in annotated.indices where annotated[index].personalizationOrigin == .learned {
            let candidate = annotated[index]
            annotated[index].personalizationChangedEntityPayload = !baseline.contains {
                entityPayloadEqual($0, candidate)
            }
            let candidateValue = candidate.value.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedValue = normalizedBiasValue(candidateValue)
            let baselineValue = baselineBiasValues[normalizedValue]
            annotated[index].personalizationChangedBiasPayload = !normalizedValue.isEmpty
                && baselineValue != candidateValue
        }
        return annotated
    }

    private static func entityPayloadEqual(
        _ lhs: ContextEntity,
        _ rhs: ContextEntity
    ) -> Bool {
        var lhs = lhs
        var rhs = rhs
        lhs.personalizationOrigin = nil
        lhs.personalizationChangedEntityPayload = nil
        lhs.personalizationChangedBiasPayload = nil
        rhs.personalizationOrigin = nil
        rhs.personalizationChangedEntityPayload = nil
        rhs.personalizationChangedBiasPayload = nil
        return lhs == rhs
    }

    private static func biasEntries(
        from entities: [ContextEntity],
        limit: Int
    ) -> [BiasEntry] {
        var seen = Set<String>()
        var entries: [BiasEntry] = []

        for entity in entities.sorted(by: entityRanksBefore) {
            guard entries.count < limit else { break }
            guard entity.trustTier == .biasTerm || entity.trustTier == .grounding else { continue }
            guard !entity.isSensitive else { continue }
            let value = entity.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.count >= 2, value.count <= 80 else { continue }
            let key = normalizedBiasValue(value)
            guard seen.insert(key).inserted else { continue }
            entries.append(BiasEntry(value: value))
        }
        return entries
    }

    private static func entityRanksBefore(_ lhs: ContextEntity, _ rhs: ContextEntity) -> Bool {
        if lhs.rankingScore == rhs.rankingScore {
            return lhs.value < rhs.value
        }
        return lhs.rankingScore > rhs.rankingScore
    }

    private static func normalizedBiasValue(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func safetyFlags(
        surface: SurfaceDescriptor,
        entities: [ContextEntity],
        hot: ContextExtractor.HotContext,
        cold: ContextExtractor.ColdContext?,
        intent: DictationIntent
    ) -> [ContextSafetyFlag] {
        var flags = Set<ContextSafetyFlag>()
        if cold?.visibleTextSnippets.isEmpty == false {
            flags.insert(.containsUntrustedVisibleText)
        }
        if surface.kind == .email {
            flags.insert(.containsEmailLikeText)
        }
        if surface.kind == .chat {
            flags.insert(.containsChatLikeText)
        }
        if surface.browserURL?.isEmpty == false || entities.contains(where: { $0.type == .url || $0.type == .siteDomain }) {
            flags.insert(.containsURL)
        }
        if entities.contains(where: \.isSensitive) {
            flags.insert(.containsSensitiveCandidate)
        }
        if !intent.allowsVisibleContextGrounding {
            flags.insert(.groundingDisabled)
        }
        flags.insert(.cloudContextReduced)
        return flags.sorted { $0.rawValue < $1.rawValue }
    }

    private static func groundingSnippets(
        cold: ContextExtractor.ColdContext?,
        intent: DictationIntent,
        surface: SurfaceDescriptor
    ) -> [String] {
        guard intent.allowsVisibleContextGrounding else { return [] }
        guard [.email, .chat, .social, .task].contains(surface.kind) else { return [] }
        return (cold?.visibleTextSnippets ?? [])
            .compactMap { preview($0, limit: groundingSnippetCharacters) }
            .prefix(groundingSnippetLimit)
            .map { $0 }
    }

    private static func styleHint(surface: SurfaceDescriptor) -> String? {
        switch surface.kind {
        case .email:
            return "Use clear email prose. Do not add a greeting or signoff unless dictated."
        case .chat:
            return "Use concise chat phrasing. Do not add email-style greetings or signoffs unless dictated."
        case .social:
            return "Use concise social comment phrasing and preserve handles exactly."
        case .code, .terminal:
            return "Preserve filenames, identifiers, commands, casing, and punctuation."
        case .search:
            return "Return a concise search query."
        default:
            return nil
        }
    }

    private static func combinedStyleHint(base: String?, learned: String?) -> String? {
        let parts = [base, learned]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " ")
    }

    private static func normalizedStyleHint(_ value: String?) -> String? {
        let normalized = value?
            .replacingOccurrences(
                of: #"[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized, !normalized.isEmpty else { return nil }
        return normalized
    }

    private static func preview(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(limit))
    }

    private static func elapsedMs(since start: DispatchTime) -> Int {
        let nanos = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        return Int((Double(nanos) / 1_000_000).rounded())
    }
}
