import Foundation

/// One stored dictation to re-run through the pipeline. `pastedText` is what
/// the pipeline produced when the dictation originally happened; `editedText`
/// is what the user turned it into in the target app. Together they let a
/// replay score pipeline changes against real user intent.
struct DictationReplayCase: Codable, Sendable, Equatable {
    let id: String
    let rawTranscript: String
    let pastedText: String?
    let editedText: String?
    let appName: String?
    let surfaceKind: String?

    init(
        id: String,
        rawTranscript: String,
        pastedText: String? = nil,
        editedText: String? = nil,
        appName: String? = nil,
        surfaceKind: String? = nil
    ) {
        self.id = id
        self.rawTranscript = rawTranscript
        self.pastedText = pastedText
        self.editedText = editedText
        self.appName = appName
        self.surfaceKind = surfaceKind
    }
}

struct DictationReplayOutcome: Sendable, Equatable {
    enum Verdict: String, Sendable {
        /// Output now equals what the user edited the text into.
        case matchesEdited
        /// Output moved closer to the user's edit than the original paste was.
        case improved
        /// Output moved further from the user's edit than the original paste.
        case regressed
        /// Same distance to the user's edit as the original paste.
        case unchanged
        /// No edited text stored — only stability vs the original paste is known.
        case unscored
    }

    let caseID: String
    let output: String
    /// Pipeline reproduces the originally pasted text (stability signal).
    let reproducedPaste: Bool?
    let distanceBefore: Double?
    let distanceAfter: Double?
    let verdict: Verdict
}

struct DictationReplayReport: Sendable {
    let outcomes: [DictationReplayOutcome]

    var totalCases: Int { outcomes.count }
    var scoredCases: Int { outcomes.filter { $0.verdict != .unscored }.count }
    var matchesEdited: Int { count(.matchesEdited) }
    var improved: Int { count(.improved) }
    var regressed: Int { count(.regressed) }
    var unchanged: Int { count(.unchanged) }
    var reproducedPastes: Int { outcomes.filter { $0.reproducedPaste == true }.count }
    var pasteComparableCases: Int { outcomes.filter { $0.reproducedPaste != nil }.count }

    var averageDistanceBefore: Double { average(outcomes.compactMap(\.distanceBefore)) }
    var averageDistanceAfter: Double { average(outcomes.compactMap(\.distanceAfter)) }

    var regressions: [DictationReplayOutcome] {
        outcomes.filter { $0.verdict == .regressed }
    }

    func summaryText() -> String {
        var lines: [String] = []
        lines.append("Replay: \(totalCases) cases, \(scoredCases) scored against user edits")
        if pasteComparableCases > 0 {
            lines.append("Stability: \(reproducedPastes)/\(pasteComparableCases) reproduce the original paste")
        }
        if scoredCases > 0 {
            lines.append("Matches user edit: \(matchesEdited)  Improved: \(improved)  Unchanged: \(unchanged)  Regressed: \(regressed)")
            lines.append(String(
                format: "Avg normalized distance to user edit: %.4f -> %.4f",
                averageDistanceBefore,
                averageDistanceAfter
            ))
        }
        for regression in regressions.prefix(10) {
            lines.append("REGRESSED \(regression.caseID): \(regression.output.prefix(80))")
        }
        return lines.joined(separator: "\n")
    }

    private func count(_ verdict: DictationReplayOutcome.Verdict) -> Int {
        outcomes.filter { $0.verdict == verdict }.count
    }

    private func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }
}

/// Re-runs stored dictations through the production post-processing pipeline
/// and scores the output against what users actually edited the text into.
/// Turns regex changes from guesswork into a measurable diff over real data.
enum DictationReplayHarness {

    static let defaultConfiguration = PostProcessingConfiguration(
        removeFillersEnabled: true,
        removeFalseStartsEnabled: true,
        itnEnabled: true,
        autoPunctuationEnabled: true,
        bulletPointsEnabled: true
    )

    /// Distances within this tolerance count as unchanged rather than
    /// improved/regressed — keeps one-character noise out of the verdicts.
    private static let distanceTolerance = 1e-9

    static func replay(
        _ cases: [DictationReplayCase],
        configuration: PostProcessingConfiguration = defaultConfiguration,
        corrections: [DictionaryCorrectionSnapshot] = []
    ) -> DictationReplayReport {
        let outcomes = cases.map { replayCase -> DictationReplayOutcome in
            let output = PostProcessingPipeline.run(
                replayCase.rawTranscript,
                configuration: configuration,
                corrections: corrections
            ).text

            let reproducedPaste = replayCase.pastedText.map { $0 == output }

            guard let edited = replayCase.editedText else {
                return DictationReplayOutcome(
                    caseID: replayCase.id,
                    output: output,
                    reproducedPaste: reproducedPaste,
                    distanceBefore: nil,
                    distanceAfter: nil,
                    verdict: .unscored
                )
            }

            let after = PersonalizationEvaluationEngine.normalizedEditDistance(
                from: output, to: edited
            )
            let before = replayCase.pastedText.map {
                PersonalizationEvaluationEngine.normalizedEditDistance(from: $0, to: edited)
            }

            let verdict: DictationReplayOutcome.Verdict
            if after <= distanceTolerance {
                verdict = .matchesEdited
            } else if let before {
                if after < before - distanceTolerance {
                    verdict = .improved
                } else if after > before + distanceTolerance {
                    verdict = .regressed
                } else {
                    verdict = .unchanged
                }
            } else {
                verdict = .unchanged
            }

            return DictationReplayOutcome(
                caseID: replayCase.id,
                output: output,
                reproducedPaste: reproducedPaste,
                distanceBefore: before,
                distanceAfter: after,
                verdict: verdict
            )
        }

        return DictationReplayReport(outcomes: outcomes)
    }

    // MARK: - JSONL corpus

    static func replay(
        contentsOfJSONL url: URL,
        configuration: PostProcessingConfiguration = defaultConfiguration
    ) throws -> DictationReplayReport {
        let text = try String(contentsOf: url, encoding: .utf8)
        return replay(try cases(fromJSONL: text), configuration: configuration)
    }

    static func cases(fromJSONL text: String) throws -> [DictationReplayCase] {
        let decoder = JSONDecoder()
        return try text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { line in
                try decoder.decode(DictationReplayCase.self, from: Data(line.utf8))
            }
    }

    static func jsonl(from cases: [DictationReplayCase]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try cases
            .map { String(decoding: try encoder.encode($0), as: UTF8.self) }
            .joined(separator: "\n")
    }

    // MARK: - Export from stored history

    /// Correction events carry the strongest signal: raw transcript, what was
    /// pasted, and what the user edited it into.
    static func cases(from events: [DictationCorrectionEvent]) -> [DictationReplayCase] {
        events.compactMap { event in
            guard let raw = event.rawTranscriptPreview, !raw.isEmpty else { return nil }
            return DictationReplayCase(
                id: event.id.uuidString,
                rawTranscript: raw,
                pastedText: event.pastedTextPreview,
                editedText: event.editedTextPreview,
                appName: event.appName,
                surfaceKind: event.surfaceKind
            )
        }
    }

    /// History entries lack the user-edited text but still provide
    /// stability coverage (raw transcript -> delivered text).
    static func cases(from entries: [DictationEntry]) -> [DictationReplayCase] {
        entries.compactMap { entry in
            guard let raw = entry.rawTranscript, !raw.isEmpty else { return nil }
            return DictationReplayCase(
                id: entry.id.uuidString,
                rawTranscript: raw,
                pastedText: entry.deliveredText ?? entry.text,
                editedText: nil,
                appName: entry.appName
            )
        }
    }
}
