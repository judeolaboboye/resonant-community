import Foundation

/// Text-free provenance for learned values in a final sanitized cloud payload.
/// This becomes a submission fact only when the pipeline records it after an
/// actual request attempt. Counts cannot carry terms or identifiers.
struct CloudContextPersonalizationSubmission: Sendable, Equatable {
    static let maximumSubmittedCount = ContextPersonalizationExposure.maximumCount

    let learnedEntitySubmittedCount: Int
    let learnedStyleSubmitted: Bool

    static let none = CloudContextPersonalizationSubmission()

    init(
        learnedEntitySubmittedCount: Int = 0,
        learnedStyleSubmitted: Bool = false
    ) {
        self.learnedEntitySubmittedCount = min(
            max(learnedEntitySubmittedCount, 0),
            Self.maximumSubmittedCount
        )
        self.learnedStyleSubmitted = learnedStyleSubmitted
    }
}

struct CloudDictionaryTermsPayload: Sendable, Equatable {
    let terms: [String]
    /// Candidate submission provenance. The sanitizer does not assert that a
    /// request was attempted.
    let personalizationSubmission: CloudContextPersonalizationSubmission
}

struct CloudCleanupContextPayload: Sendable, Equatable {
    let biasTerms: [String]
    let styleHint: String?
    /// Candidate submission provenance. The cleanup pipeline promotes it only
    /// after the request boundary reports `attempted == true`.
    let personalizationSubmission: CloudContextPersonalizationSubmission
}

enum CloudContextSanitizer {
    static func dictionaryPayload(from packet: ContextPacket?) -> CloudDictionaryTermsPayload {
        guard let packet else {
            return CloudDictionaryTermsPayload(terms: [], personalizationSubmission: .none)
        }

        let result = sanitizedTerms(
            from: packet.entities,
            limit: 20,
            predicate: isCloudAllowedDictionaryEntity
        )
        return CloudDictionaryTermsPayload(
            terms: result.terms,
            personalizationSubmission: CloudContextPersonalizationSubmission(
                learnedEntitySubmittedCount: result.learnedRetainedCount
            )
        )
    }

    static func cleanupPayload(from packet: ContextPacket?) -> CloudCleanupContextPayload {
        guard let packet else {
            return CloudCleanupContextPayload(
                biasTerms: [],
                styleHint: nil,
                personalizationSubmission: .none
            )
        }

        let result = sanitizedTerms(
            from: packet.entities,
            limit: 32,
            predicate: isCloudAllowedCleanupBiasEntity
        )
        let styleHint = sanitizedStyleHint(packet.styleHint)
        let learnedStyleSubmitted = styleHint != nil
            && packet.personalizationExposure?.packetStyleOffered == true
        return CloudCleanupContextPayload(
            biasTerms: result.terms,
            styleHint: styleHint,
            personalizationSubmission: CloudContextPersonalizationSubmission(
                learnedEntitySubmittedCount: result.learnedRetainedCount,
                learnedStyleSubmitted: learnedStyleSubmitted
            )
        )
    }

    /// Compatibility wrappers for call sites that need only the payload.
    static func dictionaryTerms(from packet: ContextPacket?) -> [String] {
        dictionaryPayload(from: packet).terms
    }

    static func cleanupBiasTerms(from packet: ContextPacket?) -> [String] {
        cleanupPayload(from: packet).biasTerms
    }

    private static func sanitizedTerms(
        from entities: [ContextEntity],
        limit: Int,
        predicate: (ContextEntity) -> Bool
    ) -> (terms: [String], learnedRetainedCount: Int) {
        var seen = Set<String>()
        var terms: [String] = []
        var learnedRetainedCount = 0

        let ranked = entities.sorted { lhs, rhs in
            if lhs.rankingScore == rhs.rankingScore {
                return lhs.value < rhs.value
            }
            return lhs.rankingScore > rhs.rankingScore
        }
        for entity in ranked {
            guard terms.count < limit else { break }
            guard predicate(entity) else { continue }
            let value = entity.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.count >= 2, value.count <= 80 else { continue }
            let normalized = value.lowercased()
            guard seen.insert(normalized).inserted else { continue }
            terms.append(value)
            if entity.personalizationOrigin == .learned,
               entity.personalizationChangedBiasPayload == true {
                learnedRetainedCount += 1
            }
        }
        return (terms, learnedRetainedCount)
    }

    private static func sanitizedStyleHint(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .replacingOccurrences(
                of: #"[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count <= 2_000 else { return nil }
        return normalized
    }

    private static func isCloudAllowedDictionaryEntity(_ entity: ContextEntity) -> Bool {
        guard !entity.isSensitive else { return false }
        guard entity.source == .dictionary else { return false }
        guard entity.trustTier == .biasTerm || entity.trustTier == .grounding else { return false }
        return true
    }

    private static func isCloudAllowedCleanupBiasEntity(_ entity: ContextEntity) -> Bool {
        guard !entity.isSensitive else { return false }
        guard entity.trustTier == .biasTerm || entity.trustTier == .grounding else { return false }
        guard entity.value.count >= 2, entity.value.count <= 80 else { return false }

        switch entity.source {
        case .dictionary, .correctionMemory, .focusedField, .selectedText,
             .windowTitle, .browserURL, .appMetadata, .openFile, .visibleSnippet:
            break
        default:
            return false
        }

        switch entity.type {
        case .personName, .personHandle, .organization, .siteDomain,
             .chatChannel, .fileName, .filePath, .repoName, .codeSymbol,
             .ticketID, .documentTitle, .taskTitle, .url, .customTerm:
            return true
        case .emailAddress, .appName, .chatThread, .styleSignal:
            return false
        }
    }
}
