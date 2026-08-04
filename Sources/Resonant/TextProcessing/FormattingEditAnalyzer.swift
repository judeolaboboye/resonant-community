import Foundation

/// Formatting-level signals extracted from a post-paste edit. Word-level
/// substitutions feed the dictionary; these capture what the user did to the
/// *shape* of the text (list markers, trailing punctuation, opening case) —
/// signals that previously died inside diffs classified as rewrites.
struct FormattingEditSignals: Sendable, Equatable {
    var strippedListMarkers = false
    var addedListMarkers = false
    var strippedTrailingPeriod = false
    var addedTrailingPeriod = false
    var lowercasedOpening = false
    var capitalizedOpening = false

    var isEmpty: Bool {
        !(strippedListMarkers
            || addedListMarkers
            || strippedTrailingPeriod
            || addedTrailingPeriod
            || lowercasedOpening
            || capitalizedOpening)
    }
}

enum FormattingEditAnalyzer {

    private static let listMarkerLinePattern = try! NSRegularExpression(
        pattern: #"^\s*(?:[-*•]\s+|\d+[.)]\s+)"#
    )

    static func signals(pasted: String, edited: String) -> FormattingEditSignals {
        var signals = FormattingEditSignals()
        let pastedTrimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        let editedTrimmed = edited.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pastedTrimmed.isEmpty, !editedTrimmed.isEmpty,
              pastedTrimmed != editedTrimmed else {
            return signals
        }

        let pastedMarkers = markerLineCount(in: pastedTrimmed)
        let editedMarkers = markerLineCount(in: editedTrimmed)
        if pastedMarkers >= 2, editedMarkers == 0,
           normalizedContent(strippingMarkers(from: pastedTrimmed))
            == normalizedContent(editedTrimmed) {
            signals.strippedListMarkers = true
        } else if pastedMarkers == 0, editedMarkers >= 2,
                  normalizedContent(pastedTrimmed)
                    == normalizedContent(strippingMarkers(from: editedTrimmed)) {
            signals.addedListMarkers = true
        }

        if hasOrdinaryTrailingPeriod(pastedTrimmed),
           String(pastedTrimmed.dropLast()) == editedTrimmed {
            signals.strippedTrailingPeriod = true
        } else if hasOrdinaryTrailingPeriod(editedTrimmed),
                  String(editedTrimmed.dropLast()) == pastedTrimmed {
            signals.addedTrailingPeriod = true
        }

        switch openingCaseTransition(from: pastedTrimmed, to: editedTrimmed) {
        case .lowercased:
            signals.lowercasedOpening = true
        case .capitalized:
            signals.capitalizedOpening = true
        case nil:
            break
        }

        return signals
    }

    private enum OpeningCaseTransition {
        case lowercased
        case capitalized
    }

    private static func openingCaseTransition(
        from pasted: String,
        to edited: String
    ) -> OpeningCaseTransition? {
        guard let pastedIndex = pasted.firstIndex(where: \.isLetter),
              let editedIndex = edited.firstIndex(where: \.isLetter),
              pasted.distance(from: pasted.startIndex, to: pastedIndex)
                == edited.distance(from: edited.startIndex, to: editedIndex)
        else { return nil }

        let pastedLetter = pasted[pastedIndex]
        let editedLetter = edited[editedIndex]
        guard pastedLetter != editedLetter,
              pastedLetter.lowercased() == editedLetter.lowercased()
        else { return nil }

        var normalizedEdited = edited
        normalizedEdited.replaceSubrange(editedIndex...editedIndex, with: String(pastedLetter))
        guard normalizedEdited == pasted else { return nil }

        if pastedLetter.isUppercase, editedLetter.isLowercase {
            return .lowercased
        }
        if pastedLetter.isLowercase, editedLetter.isUppercase {
            return .capitalized
        }
        return nil
    }

    private static func normalizedContent(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func hasOrdinaryTrailingPeriod(_ text: String) -> Bool {
        text.hasSuffix(".") && !text.hasSuffix("..")
    }

    private static func markerLineCount(in text: String) -> Int {
        text.split(separator: "\n").reduce(0) { count, line in
            let string = String(line)
            let range = NSRange(string.startIndex..., in: string)
            let matched = listMarkerLinePattern.firstMatch(in: string, range: range) != nil
            return count + (matched ? 1 : 0)
        }
    }

    private static func strippingMarkers(from text: String) -> String {
        text.split(separator: "\n").map { line -> String in
            let string = String(line)
            let range = NSRange(string.startIndex..., in: string)
            return listMarkerLinePattern.stringByReplacingMatches(
                in: string, range: range, withTemplate: ""
            )
        }
        .joined(separator: "\n")
    }
}
