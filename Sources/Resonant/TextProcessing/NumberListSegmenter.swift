import Foundation

/// Turns the speaker's real pauses between dictated numbers into list commas
/// while token timings still align with the raw transcript. "seven <pause>
/// eleven <pause> seventeen" is a list; without the commas the ITN protection
/// passes read the same words as a time ("7:11") or a year ("1719") and fuse
/// separate items.
///
/// Conservative by construction: only runs of three or more number words are
/// touched, a comma needs a gap in the list band (shorter gaps are fluent
/// compounds like "twenty three", longer ones are sentence breaks owned by
/// `PauseSegmenter`), and a pair of single digits never splits — digit-by-digit
/// codes and phone numbers are dictated with exactly those pauses.
enum NumberListSegmenter {

    /// Gap between two number words that separates list items.
    static let listGapSeconds = 0.3
    /// Gaps at or above the paragraph threshold belong to `PauseSegmenter`.
    static let maxListGapSeconds = PauseSegmenter.paragraphGapSeconds

    static func delimit(_ text: String, timings: [TranscriptTokenTiming]) -> String {
        guard timings.count >= 2 else { return text }
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard words.count >= 3,
              let wordTimings = PauseSegmenter.align(words: words, timings: timings) else { return text }

        let values = words.map(numberValue)
        var delimited = words
        var changed = false
        var index = 0

        while index < words.count {
            guard values[index] != nil else {
                index += 1
                continue
            }
            var end = index
            while end + 1 < words.count, values[end + 1] != nil {
                end += 1
            }
            if end - index >= 2 {
                for pair in index..<end {
                    guard let lead = values[pair], let trail = values[pair + 1],
                          max(lead, trail) >= 10 else { continue }
                    let gap = wordTimings[pair + 1].start - wordTimings[pair].end
                    guard gap >= listGapSeconds, gap < maxListGapSeconds else { continue }
                    delimited[pair] += ","
                    changed = true
                }
            }
            index = end + 1
        }

        return changed ? delimited.joined(separator: " ") : text
    }

    /// Value of a standalone spoken or digit number token, or nil for anything
    /// that can't be a bare list item. "oh"/"o" are excluded — they are
    /// interjections far more often than zeros — and any attached punctuation
    /// disqualifies the token, which keeps the pass idempotent.
    private static func numberValue(_ word: String) -> Int? {
        let lowered = word.lowercased()
        if lowered == "zero" { return 0 }
        if let value = NumberWords.cardinals[lowered] { return value }
        guard word.count <= 4, !word.isEmpty, word.allSatisfy(\.isNumber) else { return nil }
        return Int(word)
    }
}
