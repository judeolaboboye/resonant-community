import Foundation

/// Where a recognition-bias term came from. This is deliberately a small,
/// text-free enum so it is safe to aggregate in analytics while the term and
/// replaced span remain local-only diagnostics.
enum VocabularyBoostTermSource: String, Codable, Sendable, Equatable {
    case screen
    case autoLearned = "auto_learned"
    case manual
    case contact

    /// Higher-trust duplicates inherit the strongest source even when that
    /// duplicate appears after the vocabulary cap.
    var privilegeRank: Int {
        switch self {
        case .screen: 0
        case .autoLearned: 1
        case .contact: 2
        case .manual: 3
        }
    }

    /// Inferred sources that face the real-word overwrite guard.
    var isGuarded: Bool { self == .screen || self == .autoLearned }
}

/// Decode-time vocabulary-boost outcome for one transcription, threaded from
/// the rescoring engine through `DetailedTranscription` to the delivery and
/// correction paths. Raw terms and original spans may be retained in local
/// history for diagnosis and downstream gating (sighting exclusion, correction
/// linkage); only counts, outcomes, and scores ever reach analytics.
struct VocabularyBoostAudit: Sendable, Equatable {
    enum Outcome: String, Codable, Sendable {
        /// The term replaced decoded text and shipped in the result.
        case applied
        /// The real-word veto rejected this replacement: it would have
        /// overwritten a span of real words, and the term was either
        /// screen-inferred or not an orthographic near-neighbor of the span.
        case vetoed
        /// This replacement cleared its own gates, but a veto elsewhere in
        /// the same rescore discarded the whole rebuilt text (the rescorer
        /// exposes no span positions, so surviving replacements cannot be
        /// re-applied selectively).
        case droppedWithVeto
    }

    struct Decision: Sendable, Equatable {
        let outcome: Outcome
        let term: String
        /// The decoded word/span that the rescorer proposed replacing. Local
        /// diagnostics need this to explain incidents such as Codex over
        /// "model"; it must never be attached to analytics.
        let originalText: String
        /// Legacy aggregate projection: true for inferred sources that face
        /// the real-word veto (screen and auto-learned).
        let guarded: Bool
        /// Text-free provenance used to apply the appropriate overwrite rule
        /// and to measure decisions without ever emitting the term itself.
        let source: VocabularyBoostTermSource
        /// Whether every word of the replaced span spell-checked in the
        /// dictation locale.
        let originalWasRealWord: Bool
        let originalScore: Float
        let replacementScore: Float?
        /// Orthographic similarity used by Resonant's real-word overwrite
        /// guard. FluidAudio does not expose its internal candidate similarity
        /// on the public replacement result, so this equivalent local value is
        /// retained for sidecar diagnosis.
        let similarity: Float

        init(
            outcome: Outcome,
            term: String,
            originalText: String,
            guarded: Bool,
            source: VocabularyBoostTermSource? = nil,
            originalWasRealWord: Bool,
            originalScore: Float,
            replacementScore: Float?,
            similarity: Float
        ) {
            self.outcome = outcome
            self.term = term
            self.originalText = originalText
            self.source = source ?? (guarded ? .screen : .manual)
            self.guarded = self.source.isGuarded
            self.originalWasRealWord = originalWasRealWord
            self.originalScore = originalScore
            self.replacementScore = replacementScore
            self.similarity = similarity
        }
    }

    let decisions: [Decision]

    var appliedTerms: [String] { decisions.filter { $0.outcome == .applied }.map(\.term) }
    var vetoedTerms: [String] { decisions.filter { $0.outcome == .vetoed }.map(\.term) }

    /// Term-free aggregate safe to carry across the analytics boundary.
    struct Counts: Sendable, Equatable {
        let applied: Int
        let vetoed: Int
        let droppedWithVeto: Int
        let guardedVeto: Int

        static let zero = Counts(
            applied: 0,
            vetoed: 0,
            droppedWithVeto: 0,
            guardedVeto: 0
        )
    }

    var counts: Counts {
        Counts(
            applied: decisions.lazy.filter { $0.outcome == .applied }.count,
            vetoed: decisions.lazy.filter { $0.outcome == .vetoed }.count,
            droppedWithVeto: decisions.lazy.filter { $0.outcome == .droppedWithVeto }.count,
            guardedVeto: decisions.lazy.filter { $0.outcome == .vetoed && $0.guarded }.count
        )
    }

    /// Ground-truth signals mined from a post-paste edit: an applied term the
    /// user removed is evidence of a false apply; a vetoed term the user
    /// typed in is evidence of a false veto.
    struct CorrectionSignals: Equatable {
        let removedAppliedTermCount: Int
        let insertedVetoedTermCount: Int

        var isEmpty: Bool { removedAppliedTermCount == 0 && insertedVetoedTermCount == 0 }
    }

    func correctionSignals(pastedText: String, editedText: String) -> CorrectionSignals {
        let pasted = Self.wordTokens(of: pastedText)
        let edited = Self.wordTokens(of: editedText)
        let removed = appliedTerms.filter {
            Self.containsTermTokens($0, in: pasted) && !Self.containsTermTokens($0, in: edited)
        }
        let inserted = vetoedTerms.filter {
            !Self.containsTermTokens($0, in: pasted) && Self.containsTermTokens($0, in: edited)
        }
        return CorrectionSignals(
            removedAppliedTermCount: removed.count,
            insertedVetoedTermCount: inserted.count
        )
    }

    /// Whole-word containment: the term's token sequence must appear intact
    /// in the text's token stream, so "Devin" never matches inside
    /// "Devinshire" and multi-word terms match across exactly their words.
    private static func containsTermTokens(_ term: String, in tokens: [String]) -> Bool {
        let termTokens = wordTokens(of: term)
        guard !termTokens.isEmpty, termTokens.count <= tokens.count else { return false }
        return tokens.indices.dropLast(termTokens.count - 1).contains { start in
            Array(tokens[start..<(start + termTokens.count)]) == termTokens
        }
    }

    private static func wordTokens(of text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }
}

/// Codable, local-only representation of a vocabulary-boost audit. This is a
/// separate type from the runtime audit so feedback metadata can evolve without
/// turning the decode contract into the SwiftData storage schema.
struct VocabularyBoostAuditSummary: Codable, Sendable, Equatable {
    enum FalseApplyReason: String, Codable, Sendable {
        case dictionaryRemoved = "dictionary_removed"
        case dictionarySuppressed = "dictionary_suppressed"
        case dictionaryReplaced = "dictionary_replaced"
    }

    struct FalseApplyFeedback: Codable, Sendable, Equatable {
        let reason: FalseApplyReason
        let recordedAt: Date
    }

    struct Decision: Codable, Sendable, Equatable {
        let outcome: VocabularyBoostAudit.Outcome
        let term: String
        let originalText: String
        let guarded: Bool
        let source: VocabularyBoostTermSource
        let originalWasRealWord: Bool
        let originalScore: Float
        let replacementScore: Float?
        let similarity: Float
        var falseApplyFeedback: FalseApplyFeedback?

        init(_ decision: VocabularyBoostAudit.Decision) {
            outcome = decision.outcome
            term = decision.term
            originalText = decision.originalText
            guarded = decision.guarded
            source = decision.source
            originalWasRealWord = decision.originalWasRealWord
            originalScore = decision.originalScore
            replacementScore = decision.replacementScore
            similarity = decision.similarity
            falseApplyFeedback = nil
        }

        private enum CodingKeys: String, CodingKey {
            case outcome
            case term
            case originalText
            case guarded
            case source
            case originalWasRealWord
            case originalScore
            case replacementScore
            case similarity
            case falseApplyFeedback
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            outcome = try container.decode(VocabularyBoostAudit.Outcome.self, forKey: .outcome)
            term = try container.decode(String.self, forKey: .term)
            originalText = try container.decode(String.self, forKey: .originalText)
            guarded = try container.decode(Bool.self, forKey: .guarded)
            source = try container.decodeIfPresent(VocabularyBoostTermSource.self, forKey: .source)
                ?? (guarded ? .screen : .manual)
            originalWasRealWord = try container.decode(Bool.self, forKey: .originalWasRealWord)
            originalScore = try container.decode(Float.self, forKey: .originalScore)
            replacementScore = try container.decodeIfPresent(Float.self, forKey: .replacementScore)
            similarity = try container.decode(Float.self, forKey: .similarity)
            falseApplyFeedback = try container.decodeIfPresent(
                FalseApplyFeedback.self,
                forKey: .falseApplyFeedback
            )
        }

        var diagnosticLine: String {
            let outcomeLabel = switch outcome {
            case .applied: "applied"
            case .vetoed: "vetoed"
            case .droppedWithVeto: "dropped-with-veto"
            }
            let replacement = replacementScore.map(Self.format) ?? "nil"
            var suffix = "source=\(source.rawValue), guarded=\(guarded), realWord=\(originalWasRealWord), "
                + "originalScore=\(Self.format(originalScore)), "
                + "replacementScore=\(replacement), sim=\(Self.format(similarity))"
            if let feedback = falseApplyFeedback {
                suffix += ", falseApply=\(feedback.reason.rawValue)"
            }
            return "boost: \(outcomeLabel) \(Self.singleLine(term)) over "
                + "\"\(Self.quoted(originalText))\" (\(suffix))"
        }

        private static func format(_ value: Float) -> String {
            guard value.isFinite else {
                if value.isNaN { return "nan" }
                return value.sign == .minus ? "-infinity" : "infinity"
            }
            return String(format: "%.2f", value)
        }

        private static func singleLine(_ value: String) -> String {
            value.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }

        private static func quoted(_ value: String) -> String {
            singleLine(value).replacingOccurrences(of: "\"", with: "\\\"")
        }
    }

    var decisions: [Decision]

    init(audit: VocabularyBoostAudit) {
        decisions = audit.decisions.map(Decision.init)
    }

    /// Marks only previously-unflagged applied decisions whose written term
    /// matches the invalidated dictionary form. Returns the new signal count,
    /// making repeated suppression/removal idempotent.
    @discardableResult
    mutating func flagFalseApplies(
        matchingWrittenForm writtenForm: String,
        reason: FalseApplyReason,
        recordedAt: Date
    ) -> Int {
        let writtenKey = Self.normalizedTermKey(writtenForm)
        guard !writtenKey.isEmpty else { return 0 }

        var count = 0
        for index in decisions.indices {
            guard decisions[index].outcome == .applied,
                  decisions[index].falseApplyFeedback == nil,
                  Self.normalizedTermKey(decisions[index].term) == writtenKey
            else { continue }
            decisions[index].falseApplyFeedback = FalseApplyFeedback(
                reason: reason,
                recordedAt: recordedAt
            )
            count += 1
        }
        return count
    }

    static func normalizedTermKey(_ value: String) -> String {
        value.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    func encodedData() -> Data? {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "infinity",
            negativeInfinity: "-infinity",
            nan: "nan"
        )
        return try? encoder.encode(self)
    }

    static func decode(from data: Data?) -> VocabularyBoostAuditSummary? {
        guard let data else { return nil }
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "infinity",
            negativeInfinity: "-infinity",
            nan: "nan"
        )
        return try? decoder.decode(Self.self, from: data)
    }
}
