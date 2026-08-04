import Foundation

/// Replaces trigger phrases with Markdown links.
/// E.g. "open github" → "[github](https://github.com)" if configured.
struct SmartLinkProcessor {

    func process(_ text: String, links: [SmartLink]) -> (result: String, matchCount: Int) {
        let prioritizedLinks = links.sorted {
            if $0.trigger.count != $1.trigger.count {
                return $0.trigger.count > $1.trigger.count
            }

            return $0.trigger.localizedCaseInsensitiveCompare($1.trigger) == .orderedAscending
        }

        var replacements: [(range: NSRange, replacement: String)] = []
        let fullRange = NSRange(text.startIndex..., in: text)

        for link in prioritizedLinks where link.isEnabled {
            let escaped = NSRegularExpression.escapedPattern(for: link.trigger)
            let pattern = #"(?i)\b"# + escaped + #"\b"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }

            let label = link.label ?? link.trigger
            let replacement = "[\(label)](\(link.url))"

            for match in regex.matches(in: text, range: fullRange) {
                guard match.range.location != NSNotFound else { continue }
                guard replacements.allSatisfy({ NSIntersectionRange($0.range, match.range).length == 0 }) else {
                    continue
                }

                replacements.append((match.range, replacement))
            }
        }

        guard !replacements.isEmpty else { return (text, 0) }

        replacements.sort { $0.range.location < $1.range.location }

        var result = ""
        var currentIndex = text.startIndex

        for replacement in replacements {
            guard let range = Range(replacement.range, in: text) else { continue }
            result += text[currentIndex..<range.lowerBound]
            result += replacement.replacement
            currentIndex = range.upperBound
        }

        result += text[currentIndex...]
        return (result, replacements.count)
    }
}
