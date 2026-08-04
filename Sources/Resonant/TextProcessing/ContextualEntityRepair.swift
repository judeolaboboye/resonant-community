import Foundation

/// Bounded, text-free proof of what the local learned-entity consumer did.
/// Counts represent distinct learned entities, never transcript spans or
/// entity values. Manual dictionary and base context values are excluded.
struct ContextualEntityRepairProvenance: Sendable, Equatable, Hashable {
    static let maximumCount = ContextPersonalizationExposure.maximumCount

    let learnedEntityConsideredCount: Int
    let learnedEntityMatchedCount: Int
    let learnedEntityAppliedCount: Int

    static let none = ContextualEntityRepairProvenance()

    init(
        learnedEntityConsideredCount: Int = 0,
        learnedEntityMatchedCount: Int = 0,
        learnedEntityAppliedCount: Int = 0
    ) {
        self.learnedEntityConsideredCount = Self.bounded(learnedEntityConsideredCount)
        self.learnedEntityMatchedCount = min(
            Self.bounded(learnedEntityMatchedCount),
            self.learnedEntityConsideredCount
        )
        self.learnedEntityAppliedCount = min(
            Self.bounded(learnedEntityAppliedCount),
            self.learnedEntityMatchedCount
        )
    }

    private static func bounded(_ count: Int) -> Int {
        min(max(count, 0), maximumCount)
    }
}

struct ContextualEntityRepairResult: Sendable, Equatable {
    let text: String
    let personalization: ContextualEntityRepairProvenance
}

enum ContextualEntityRepair {
    private static let maxEntities = 16
    private static let maxReplacements = 12

    static func repair(
        _ text: String,
        using packet: ContextPacket?,
        suppressedDomainHosts: Set<String> = []
    ) -> ContextualEntityRepairResult {
        guard let packet, !text.isEmpty, packet.intent.allowsBiasTerms else {
            return ContextualEntityRepairResult(text: text, personalization: .none)
        }

        var result = repairActiveRecipientDirectAddress(text, using: packet)
        var replacementCount = 0
        var learnedMatchedCount = 0
        var learnedAppliedCount = 0
        let entities = Array(packet.entities
            .filter { entity in
                guard entity.trustTier == .biasTerm || entity.trustTier == .grounding else { return false }
                guard !entity.isSensitive else { return false }
                guard entity.value.count >= 3, entity.value.count <= 80 else { return false }
                if entity.type == .siteDomain,
                   isSuppressedDomain(entity.value, hosts: suppressedDomainHosts) {
                    return false
                }
                return repairableTypes.contains(entity.type)
            }
            .sorted { $0.rankingScore > $1.rankingScore }
            .prefix(maxEntities))
        let learnedConsideredCount = entities.filter {
            $0.personalizationOrigin == .learned
                && $0.personalizationChangedEntityPayload == true
        }.count

        for entity in entities {
            let isLearnedExperimentValue = entity.personalizationOrigin == .learned
                && entity.personalizationChangedEntityPayload == true
            guard replacementCount < maxReplacements else { break }
            guard !containsExactValue(result, entity.value) else { continue }

            for spokenForm in entity.spokenForms {
                guard replacementCount < maxReplacements else { break }
                guard shouldAttempt(spokenForm: spokenForm, entity: entity) else { continue }
                let (updated, count) = replacePhrase(
                    spokenForm,
                    with: entity.value,
                    in: result,
                    entityType: entity.type
                )
                if count > 0 {
                    if isLearnedExperimentValue {
                        learnedMatchedCount += 1
                    }
                    let changed = updated != result
                    result = updated
                    replacementCount += count
                    if isLearnedExperimentValue, changed {
                        learnedAppliedCount += 1
                    }
                    break
                }
            }
        }

        return ContextualEntityRepairResult(
            text: result,
            personalization: ContextualEntityRepairProvenance(
                learnedEntityConsideredCount: learnedConsideredCount,
                learnedEntityMatchedCount: learnedMatchedCount,
                learnedEntityAppliedCount: learnedAppliedCount
            )
        )
    }

    private static func repairActiveRecipientDirectAddress(
        _ text: String,
        using packet: ContextPacket
    ) -> String {
        guard let recipient = packet.activeRecipient,
              recipient.confidence >= 0.9,
              isEligibleRecipientSurface(packet),
              recipient.firstName.count >= 3 else {
            return text
        }

        let normalizedRecipient = recipient.firstName
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        let acceptedRanges = directAddressCandidateRanges(in: text).filter { candidateRange in
            guard let range = Range(candidateRange, in: text) else { return false }
            let normalizedSpoken = String(text[range])
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .lowercased()
            guard !commonDirectAddressVocatives.contains(normalizedSpoken) else {
                return false
            }
            if normalizedSpoken == normalizedRecipient {
                return true
            }
            return CorrectionDiffEngine.levenshtein(
                normalizedSpoken,
                normalizedRecipient
            ) == 1 && CorrectionDiffEngine.phoneticallySimilar(
                normalizedSpoken,
                normalizedRecipient
            )
        }
        guard !acceptedRanges.isEmpty else { return text }

        var result = text
        for candidateRange in acceptedRanges.sorted(by: {
            $0.location > $1.location
        }) {
            guard let range = Range(candidateRange, in: result) else { continue }
            result.replaceSubrange(range, with: recipient.firstName)
        }
        return result
    }

    private static func directAddressCandidateRanges(in text: String) -> [NSRange] {
        let fullRange = NSRange(text.startIndex..., in: text)
        var ranges: [NSRange] = []
        for regex in directAddressCandidateRegexes {
            for match in regex.matches(in: text, range: fullRange).prefix(4) {
                let range = match.range(at: 1)
                guard range.location != NSNotFound, range.length > 0 else { continue }
                ranges.append(range)
            }
        }

        // Prefer the longest token at a shared start and keep only
        // non-overlapping source ranges. This removes duplicate name ranges
        // matched by more than one pattern without allowing one replacement to
        // mutate the range of another.
        let ordered = ranges.sorted {
            if $0.location == $1.location {
                return $0.length > $1.length
            }
            return $0.location < $1.location
        }
        var unique: [NSRange] = []
        for range in ordered {
            guard !unique.contains(where: {
                NSIntersectionRange($0, range).length > 0
            }) else {
                continue
            }
            unique.append(range)
        }
        return unique
    }

    private static func isEligibleRecipientSurface(_ packet: ContextPacket) -> Bool {
        guard BrowserCatalog.isBrowser(packet.surface.bundleId),
              SurfaceClassifier.hostName(from: packet.surface.browserURL) != nil,
              packet.targetFingerprint?.isSensitiveInput != true,
              [.email, .chat, .social].contains(packet.surface.kind),
              [.compose, .reply, .comment].contains(packet.surface.fieldKind) else {
            return false
        }
        return true
    }

    private static func shouldAttempt(spokenForm: String, entity: ContextEntity) -> Bool {
        let trimmed = spokenForm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return false }
        if entity.type == .siteDomain {
            // A bare single token must never be rewritten into a domain; only
            // domain-shaped forms ("substack dot com", "substack.com") qualify.
            guard trimmed.contains(" ") || trimmed.contains(".") else { return false }
        }
        if trimmed == entity.normalizedValue, entity.type == .personName {
            return trimmed.contains(" ")
        }
        if commonUnsafeSpokenForms.contains(trimmed) {
            return false
        }
        return true
    }

    private static func replacePhrase(
        _ phrase: String,
        with replacement: String,
        in text: String,
        entityType: ContextEntityType
    ) -> (String, Int) {
        let escaped = NSRegularExpression.escapedPattern(for: phrase)
        let pattern: String
        switch entityType {
        case .personHandle, .chatChannel:
            pattern = #"(?i)(?<![A-Za-z0-9_@#])"# + escaped + #"(?![A-Za-z0-9_])"#
        case .fileName, .filePath, .codeSymbol, .ticketID:
            pattern = #"(?i)(?<![A-Za-z0-9_./-])"# + escaped + #"(?![A-Za-z0-9_./-])"#
        default:
            // Negative lookahead prevents re-casing a token that is the leading
            // label of a domain (e.g. brand "Substack" must not turn the
            // "substack" in "substack.com" into "Substack.com").
            pattern = #"(?i)\b"# + escaped + #"\b(?!\.[A-Za-z]{2,})"#
        }

        guard let regex = try? NSRegularExpression(pattern: pattern) else { return (text, 0) }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)
        guard !matches.isEmpty else { return (text, 0) }

        let limitedMatches = Array(matches.prefix(maxReplacements))
        var result = text
        for match in limitedMatches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: replacement)
        }
        return (result, limitedMatches.count)
    }

    private static func containsExactValue(_ text: String, _ value: String) -> Bool {
        text.range(of: value) != nil
    }

    /// True when the entity's host matches a learned "stop expanding this
    /// domain" preference. Hosts compare lowercased with any "www." stripped.
    private static func isSuppressedDomain(_ value: String, hosts: Set<String>) -> Bool {
        guard !hosts.isEmpty else { return false }
        var host = value.lowercased()
            .replacingOccurrences(of: #"^[a-z]+://"#, with: "", options: .regularExpression)
        if let slash = host.firstIndex(of: "/") {
            host = String(host[..<slash])
        }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return hosts.contains(host) || hosts.contains("www." + host)
    }

    private static let repairableTypes: Set<ContextEntityType> = [
        .personName,
        .personHandle,
        .chatChannel,
        .fileName,
        .filePath,
        .repoName,
        .codeSymbol,
        .ticketID,
        .siteDomain,
        .appName,
        .customTerm,
    ]

    private static let commonUnsafeSpokenForms: Set<String> = [
        "mail", "email", "message", "chat", "reply", "search", "file", "code",
        "app", "docs", "team", "teams"
    ]

    private static let commonDirectAddressVocatives: Set<String> = [
        "all", "everyone", "everybody", "folks", "friend", "friends", "guys",
        "people", "team", "teams", "there",
    ]

    private static let directAddressContinuationPattern =
        #"(?:please\b|(?:can|could|would|will|do|did|are|were|have|had|may|might|should)\s+(?:you|we|i)\b|(?:you|your|yours|yourself|yourselves)\b|(?:i(?:['’](?:m|d|ve|ll))?|we(?:['’](?:re|d|ve|ll))?)\b|let(?:['’]s|\s+us)\b|(?:what|when|where|why|how)\b[^,\n]{0,48}\b(?:you|your)\b)"#

    private static let directAddressCandidatePatterns: [String] = [
        // Leading closed-class salutation or acknowledgement.
        #"^\s*(?:hey|hi|hello|dear|thanks|thank\s+you|sorry|okay|ok|morning|good\s+(?:morning|afternoon|evening))[\s,]+([\p{L}\p{M}'’\-]+)(?=$|[\s,!.?;:—–-])"#,
        // A leading comma is vocative only when the following clause has
        // explicit conversational evidence. This rejects appositives such as
        // "Henry, the account manager, will join." A later comma may only
        // close with the same addressed token or "please"; otherwise it could
        // be a conversational-looking parenthetical.
        #"^\s*([\p{L}\p{M}'’\-]+)\s*,\s*(?="#
            + directAddressContinuationPattern
            + #")(?:[^,\n]*|[^,\n]*,\s+(?:\1|please)\s*[.!?]?)\s*$"#,
        // A dash is a delimiter only with whitespace on both sides, never the
        // intra-word hyphen in a name such as Anne-Marie. Like a comma, it
        // requires conversational evidence after it and cannot enclose a
        // later parenthetical.
        #"^\s*([\p{L}\p{M}'’\-]+)\s+[—–-]\s+(?="#
            + directAddressContinuationPattern
            + #")(?:(?!\s+[—–-]\s+)[\s\S])*$"#,
        // A closing comma-separated name needs second-person evidence
        // in its final comma-free clause. This rejects list-like text such as
        // "We shortlisted Alice, Henry."
        #"\b(?:you|your|yours|yourself|yourselves)\b[^,\n]*,\s+([\p{L}\p{M}'’\-]+)\s*[.!?]?\s*$"#,
        // Name-only utterance, with optional terminal punctuation.
        #"^\s*([\p{L}\p{M}'’\-]+)\s*[.!?]?\s*$"#,
    ]

    private static let directAddressCandidateRegexes: [NSRegularExpression] =
        directAddressCandidatePatterns.compactMap {
            try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
        }
}
