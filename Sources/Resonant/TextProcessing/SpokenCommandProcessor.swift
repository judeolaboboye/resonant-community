import Foundation

/// Converts explicitly spoken structural commands into literal layout:
///
///   "new line" / "next line" / "newline"   → \n
///   "new paragraph" / "next paragraph"     → \n\n
///   "bullet point" / "new bullet" / "next bullet" → \n-
///
/// A command preceded by a determiner or possessive is prose, not a command
/// ("add a bullet point system", "our new line of clothing"), and is left
/// alone. Same when followed by "of" ("new line of products").
enum SpokenCommandProcessor {

    static func process(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = commandPattern.matches(in: text, range: fullRange)
        guard !matches.isEmpty else { return text }

        var result = text
        var replacedAny = false
        for match in matches.reversed() {
            guard isCommandUsage(matchRange: match.range, in: nsText),
                  let range = Range(match.range, in: result) else { continue }
            let phrase = nsText.substring(with: match.range).lowercased()
            let replacement: String
            if phrase.contains("paragraph") {
                replacement = "\n\n"
            } else if phrase.contains("bullet") {
                replacement = "\n- "
            } else {
                replacement = "\n"
            }
            result.replaceSubrange(range, with: replacement)
            replacedAny = true
        }

        guard replacedAny else { return text }
        return cleanedUp(result)
    }

    // MARK: - Command detection

    private static let commandPattern = try! NSRegularExpression(
        pattern: #"\b(?:(?:new|next)\s+paragraph|new\s*line|next\s+line|(?:new|next)\s+bullet(?:\s+point)?|bullet\s+point)\b"#,
        options: [.caseInsensitive]
    )

    /// Determiners/modifiers that mark the phrase as prose about a line,
    /// paragraph, or bullet point rather than a dictation command.
    private static let blockedPrecedingWords: Set<String> = [
        "a", "an", "the", "this", "that", "these", "those",
        "each", "every", "any", "some", "no", "one", "single",
        "my", "your", "his", "her", "its", "our", "their",
        "whole", "entire", "another", "first", "second", "third",
        "last", "final", "previous", "extra", "per", "blank", "empty",
    ]

    private static let blockedFollowingWords: Set<String> = ["of"]

    private static func isCommandUsage(matchRange: NSRange, in text: NSString) -> Bool {
        if let before = word(endingAt: matchRange.location, in: text),
           blockedPrecedingWords.contains(before) {
            return false
        }
        if let after = word(startingAt: matchRange.location + matchRange.length, in: text),
           blockedFollowingWords.contains(after) {
            return false
        }
        return true
    }

    /// The letter-run immediately before `location`, skipping spaces/tabs.
    /// Returns nil when the command sits at a punctuation or line boundary.
    private static func word(endingAt location: Int, in text: NSString) -> String? {
        var end = location
        while end > 0, isSpace(text.character(at: end - 1)) { end -= 1 }
        var start = end
        while start > 0, isLetter(text.character(at: start - 1)) { start -= 1 }
        guard start < end else { return nil }
        return text.substring(with: NSRange(location: start, length: end - start)).lowercased()
    }

    private static func word(startingAt location: Int, in text: NSString) -> String? {
        var start = location
        while start < text.length, isSpace(text.character(at: start)) { start += 1 }
        var end = start
        while end < text.length, isLetter(text.character(at: end)) { end += 1 }
        guard start < end else { return nil }
        return text.substring(with: NSRange(location: start, length: end - start)).lowercased()
    }

    private static func isSpace(_ c: unichar) -> Bool {
        c == 0x20 || c == 0x09
    }

    private static func isLetter(_ c: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(c) else { return false }
        return CharacterSet.letters.contains(scalar)
    }

    // MARK: - Cleanup

    /// Removes auto-punctuation artifacts stranded around the inserted breaks
    /// ("buy milk, new line, buy eggs" leaves "buy milk, \n, buy eggs").
    private static func cleanedUp(_ text: String) -> String {
        var result = text
        let rules: [(pattern: String, replacement: String)] = [
            // Trailing comma/semicolon before a break is an auto-punct artifact;
            // sentence punctuation (. ! ? :) before a break is kept.
            (#"[ \t]*[,;][ \t]*\n"#, "\n"),
            // Stray punctuation right after a bullet marker or a bare break.
            (#"\n- [ \t]*[,.;:]+[ \t]*"#, "\n- "),
            (#"\n[ \t]*[,.;:]+[ \t]*"#, "\n"),
            // Spacing around breaks and after bullet markers.
            (#"[ \t]+\n"#, "\n"),
            (#"\n[ \t]+"#, "\n"),
            (#"\n- [ \t]+"#, "\n- "),
            (#"\n{3,}"#, "\n\n"),
        ]
        for rule in rules {
            result = result.replacingOccurrences(
                of: rule.pattern,
                with: rule.replacement,
                options: .regularExpression
            )
        }
        // Commands at the edges leave empty lines or an empty bullet behind.
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        result = result.replacingOccurrences(
            of: #"(?:\n-|^-)[ \t]*$"#,
            with: "",
            options: .regularExpression
        )
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
