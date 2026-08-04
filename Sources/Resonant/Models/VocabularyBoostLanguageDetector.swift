import Foundation
import NaturalLanguage

/// A text-free, bounded decision produced from the first-pass transcript.
///
/// The transcript is passed only to the injected detector operation. Neither
/// the transcript, the winning language tag, nor these confidence values are
/// retained or attached to analytics.
struct VocabularyBoostLanguageDetection: Sendable, Equatable {
    enum Classification: Sendable, Equatable {
        case confidentlyEnglish
        case confidentlyNonEnglish
        case uncertain
    }

    let classification: Classification
    let confidence: Double

    init(classification: Classification, confidence: Double) {
        self.classification = classification
        self.confidence = confidence.isFinite
            ? min(max(confidence, 0), 1)
            : 0
    }
}

/// Injectable local language-identification boundary for Auto-language
/// vocabulary boosting.
///
/// Apple's recognizer warns that short inputs are unreliable. The production
/// policy therefore requires all three signals before calling the English-only
/// CTC helper: at least 30 non-whitespace characters, an 80% leading
/// hypothesis, and a 20-point margin over the runner-up. Anything weaker is an
/// uncertainty skip, preserving the first-pass decode unchanged.
struct VocabularyBoostLanguageDetector: Sendable {
    typealias Operation = @Sendable (String) -> VocabularyBoostLanguageDetection

    nonisolated static let minimumSignalCharacterCount = 30
    nonisolated static let maximumSignalCharacterCount = 2_000
    nonisolated static let minimumConfidence = 0.8
    nonisolated static let minimumConfidenceMargin = 0.2

    private let operation: Operation

    init(operation: @escaping Operation) {
        self.operation = operation
    }

    nonisolated func detect(_ firstPassTranscript: String) -> VocabularyBoostLanguageDetection {
        operation(firstPassTranscript)
    }

    nonisolated static var localNaturalLanguage: Self {
        Self { transcript in
            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            let signal = String(trimmed.prefix(maximumSignalCharacterCount))
            guard signal.filter({ !$0.isWhitespace }).count >= minimumSignalCharacterCount else {
                return VocabularyBoostLanguageDetection(
                    classification: .uncertain,
                    confidence: 0
                )
            }

            // A fresh recognizer keeps Apple's explicitly non-thread-safe
            // instance entirely inside this synchronous, device-local call.
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(signal)
            let hypotheses = recognizer.languageHypotheses(withMaximum: 2)
                .sorted { lhs, rhs in lhs.value > rhs.value }
            guard let leading = hypotheses.first else {
                return VocabularyBoostLanguageDetection(
                    classification: .uncertain,
                    confidence: 0
                )
            }

            let confidence = leading.value
            let runnerUpConfidence = hypotheses.dropFirst().first?.value ?? 0
            let margin = confidence - runnerUpConfidence
            guard confidence >= minimumConfidence,
                  margin >= minimumConfidenceMargin,
                  leading.key != .undetermined else {
                return VocabularyBoostLanguageDetection(
                    classification: .uncertain,
                    confidence: confidence
                )
            }

            return VocabularyBoostLanguageDetection(
                classification: leading.key == .english
                    ? .confidentlyEnglish
                    : .confidentlyNonEnglish,
                confidence: confidence
            )
        }
    }
}
