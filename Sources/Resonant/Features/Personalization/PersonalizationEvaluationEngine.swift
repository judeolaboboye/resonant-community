import Foundation

enum PersonalizationEvaluationEngine {
    static func evaluate(
        _ events: [PersonalizationEvaluationInput],
        outcomes: PersonalizationOutcomeSummaryState,
        capturedAt: Date = Date()
    ) -> PersonalizationEvaluationSnapshot {
        let editDistances = events.map {
            normalizedEditDistance(from: $0.pastedText, to: $0.editedText)
        }
        let correctionCount = events.reduce(0) { $0 + $1.corrections.count }

        return PersonalizationEvaluationSnapshot(
            capturedAt: capturedAt,
            outcomes: outcomes,
            correctionLogEventCount: events.count,
            editedCorrectionLogEventCount: events.filter(\.hadCorrection).count,
            averageNormalizedEditDistance: average(editDistances),
            averageCorrectionPairsPerLogEvent: events.isEmpty
                ? 0
                : Double(correctionCount) / Double(events.count),
            topCorrections: topCorrections(from: events)
        )
    }

    static func normalizedEditDistance(from lhs: String, to rhs: String) -> Double {
        let left = Array(lhs.trimmingCharacters(in: .whitespacesAndNewlines))
        let right = Array(rhs.trimmingCharacters(in: .whitespacesAndNewlines))
        let denominator = max(left.count, right.count)
        guard denominator > 0 else { return 0 }
        return Double(levenshteinDistance(left, right)) / Double(denominator)
    }

    private static func topCorrections(
        from events: [PersonalizationEvaluationInput]
    ) -> [PersonalizationCorrectionTermSummary] {
        var counts: [String: (spoken: String, written: String, count: Int)] = [:]
        for correction in events.flatMap(\.corrections) {
            let spoken = correction.spoken.trimmingCharacters(in: .whitespacesAndNewlines)
            let written = correction.written.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !spoken.isEmpty, !written.isEmpty else { continue }
            let key = "\(spoken.lowercased())|\(written.lowercased())"
            var value = counts[key] ?? (spoken, written, 0)
            value.count += 1
            counts[key] = value
        }

        return counts
            .map { key, value in
                PersonalizationCorrectionTermSummary(
                    id: key,
                    spoken: value.spoken,
                    written: value.written,
                    count: value.count
                )
            }
            .sorted { lhs, rhs in
                if lhs.count == rhs.count {
                    return lhs.written < rhs.written
                }
                return lhs.count > rhs.count
            }
            .prefix(12)
            .map { $0 }
    }

    private static func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func levenshteinDistance(_ lhs: [Character], _ rhs: [Character]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }

        let short: [Character]
        let long: [Character]
        if lhs.count <= rhs.count {
            short = lhs
            long = rhs
        } else {
            short = rhs
            long = lhs
        }

        var previous = Array(0...short.count)
        var current = Array(repeating: 0, count: short.count + 1)

        for (longIndex, longChar) in long.enumerated() {
            current[0] = longIndex + 1
            for (shortIndex, shortChar) in short.enumerated() {
                let insertion = current[shortIndex] + 1
                let deletion = previous[shortIndex + 1] + 1
                let substitution = previous[shortIndex] + (longChar == shortChar ? 0 : 1)
                current[shortIndex + 1] = min(insertion, deletion, substitution)
            }
            swap(&previous, &current)
        }

        return previous[short.count]
    }
}
