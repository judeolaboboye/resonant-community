import Foundation

/// Category of formatting preference inferred from a post-paste edit. These are
/// the case-only / symbol-only diffs the correction pipeline throws away —
/// exactly the signals that encode how a user *likes* text formatted.
enum FormatCorrectionCategory: String, Sendable, CaseIterable {
    case urlExpansionRevert
    case phoneStyle
    case emailCasing
    case wordCasing
    case punctuation
}

/// A single preference signal detected in one edit. `scopeHint` is the
/// category-appropriate scope key (a host for URL reverts, otherwise "global");
/// `observedValue` is the form the user preferred (brand word, phone style,
/// cased email/word). Trailing-period policy is intentionally absent: the
/// surface-scoped `FormattingEditAnalyzer` is its sole producer.
struct FormatCorrectionSignal: Sendable, Equatable {
    var category: FormatCorrectionCategory
    var scopeHint: String
    var observedValue: String
}

/// Pure, dependency-free classifier over a (pasted, edited) pair. Uses a simple
/// LCS-based token alignment so it can compare tokens that stayed in place while
/// ignoring insertions/deletions. Does not touch CorrectionDiffEngine.
enum FormatCorrectionClassifier {

    static let globalScope = "global"

    // A small, common TLD set is enough to recognise "substack.com"-style
    // expansions without pulling in a full public-suffix list.
    private static let knownTLDs: Set<String> = [
        "com", "org", "net", "io", "co", "app", "dev", "ai", "gov", "edu",
        "info", "me", "us", "uk", "ca", "de", "fr", "so", "xyz", "tv", "fm",
    ]

    static func classify(pasted: String, edited: String) -> [FormatCorrectionSignal] {
        let pastedTrimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        let editedTrimmed = edited.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pastedTrimmed.isEmpty, !editedTrimmed.isEmpty,
              pastedTrimmed != editedTrimmed else {
            return []
        }

        var signals: [FormatCorrectionSignal] = []

        let pastedTokens = tokenize(pastedTrimmed)
        let editedTokens = tokenize(editedTrimmed)
        let alignment = alignedPairs(pastedTokens, editedTokens)

        for (index, pair) in alignment.enumerated() {
            guard pair.pasted != pair.edited else { continue }
            let isSentenceInitial = index == 0

            if let signal = urlExpansionRevertSignal(pasted: pair.pasted, edited: pair.edited) {
                signals.append(signal)
                continue
            }
            if let signal = emailCasingSignal(pasted: pair.pasted, edited: pair.edited) {
                signals.append(signal)
                continue
            }
            if let signal = wordCasingSignal(
                pasted: pair.pasted,
                edited: pair.edited,
                isSentenceInitial: isSentenceInitial
            ) {
                signals.append(signal)
                continue
            }
        }

        if let signal = phoneStyleSignal(pasted: pastedTrimmed, edited: editedTrimmed) {
            signals.append(signal)
        }
        return dedupe(signals)
    }

    // MARK: - Per-category detection

    private static func urlExpansionRevertSignal(pasted: String, edited: String) -> FormatCorrectionSignal? {
        guard let host = domainHost(pasted) else { return nil }
        let label = mainLabel(ofHost: host)
        guard !label.isEmpty else { return nil }
        // The edited token must be the bare label (case-insensitive), i.e. the
        // user reverted an auto-expanded domain back to the brand word.
        guard domainHost(edited) == nil else { return nil }
        guard edited.caseInsensitiveCompare(label) == .orderedSame else { return nil }
        return FormatCorrectionSignal(
            category: .urlExpansionRevert,
            scopeHint: host.lowercased(),
            observedValue: edited
        )
    }

    private static func emailCasingSignal(pasted: String, edited: String) -> FormatCorrectionSignal? {
        guard isEmail(pasted), isEmail(edited) else { return nil }
        guard pasted != edited,
              pasted.caseInsensitiveCompare(edited) == .orderedSame else { return nil }
        return FormatCorrectionSignal(
            category: .emailCasing,
            scopeHint: globalScope,
            observedValue: edited
        )
    }

    private static func wordCasingSignal(
        pasted: String,
        edited: String,
        isSentenceInitial: Bool
    ) -> FormatCorrectionSignal? {
        guard !isSentenceInitial else { return nil }
        guard isPlainWord(pasted), isPlainWord(edited) else { return nil }
        guard pasted != edited,
              pasted.caseInsensitiveCompare(edited) == .orderedSame else { return nil }
        return FormatCorrectionSignal(
            category: .wordCasing,
            scopeHint: globalScope,
            observedValue: edited
        )
    }

    private static func phoneStyleSignal(pasted: String, edited: String) -> FormatCorrectionSignal? {
        guard let pastedPhone = firstPhoneSpan(in: pasted),
              let editedPhone = firstPhoneSpan(in: edited) else { return nil }
        guard pastedPhone.digits == editedPhone.digits,
              pastedPhone.digits.count >= 7 else { return nil }
        guard pastedPhone.style != editedPhone.style else { return nil }
        return FormatCorrectionSignal(
            category: .phoneStyle,
            scopeHint: globalScope,
            observedValue: editedPhone.style
        )
    }

    // MARK: - Token alignment (simple LCS walk)

    private struct AlignedPair {
        var pasted: String
        var edited: String
    }

    /// Aligns tokens that are equal (case-insensitively) via LCS, then walks the
    /// gaps between anchors and pairs up substitutions positionally. Only pairs
    /// where both sides exist are returned.
    private static func alignedPairs(_ lhs: [String], _ rhs: [String]) -> [AlignedPair] {
        let anchors = lcsAnchors(lhs, rhs)

        var pairs: [AlignedPair] = []
        var i = 0
        var j = 0
        for anchor in anchors {
            let lhsGap = Array(lhs[i..<anchor.lhs])
            let rhsGap = Array(rhs[j..<anchor.rhs])
            appendSubstitutions(lhsGap, rhsGap, into: &pairs)
            pairs.append(AlignedPair(pasted: lhs[anchor.lhs], edited: rhs[anchor.rhs]))
            i = anchor.lhs + 1
            j = anchor.rhs + 1
        }
        let lhsTail = Array(lhs[i...].map { $0 })
        let rhsTail = Array(rhs[j...].map { $0 })
        appendSubstitutions(lhsTail, rhsTail, into: &pairs)
        return pairs
    }

    private static func appendSubstitutions(
        _ lhs: [String],
        _ rhs: [String],
        into pairs: inout [AlignedPair]
    ) {
        let count = min(lhs.count, rhs.count)
        for index in 0..<count {
            pairs.append(AlignedPair(pasted: lhs[index], edited: rhs[index]))
        }
    }

    private struct Anchor { var lhs: Int; var rhs: Int }

    private static func lcsAnchors(_ lhs: [String], _ rhs: [String]) -> [Anchor] {
        let n = lhs.count
        let m = rhs.count
        guard n > 0, m > 0 else { return [] }

        let a = lhs.map { $0.lowercased() }
        let b = rhs.map { $0.lowercased() }
        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                if a[i] == b[j] {
                    table[i][j] = table[i + 1][j + 1] + 1
                } else {
                    table[i][j] = max(table[i + 1][j], table[i][j + 1])
                }
            }
        }

        var anchors: [Anchor] = []
        var i = 0
        var j = 0
        while i < n, j < m {
            if a[i] == b[j] {
                anchors.append(Anchor(lhs: i, rhs: j))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return anchors
    }

    // MARK: - Token / value helpers

    private static func tokenize(_ text: String) -> [String] {
        text.split { $0.isWhitespace || $0.isNewline }.map(String.init)
    }

    /// Returns the domain host if the token looks like `label.tld` (with an
    /// optional trailing path/punctuation stripped). Rejects emails.
    private static func domainHost(_ token: String) -> String? {
        let cleaned = token.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)("))
        guard !cleaned.contains("@") else { return nil }
        // Strip scheme and path — keep the host portion.
        var host = cleaned
        if let schemeRange = host.range(of: "://") {
            host = String(host[schemeRange.upperBound...])
        }
        if let slash = host.firstIndex(of: "/") {
            host = String(host[..<slash])
        }
        let parts = host.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return nil }
        guard let tld = parts.last?.lowercased(), knownTLDs.contains(tld) else { return nil }
        guard parts.dropLast().allSatisfy({ isLabelPart($0) }) else { return nil }
        return host
    }

    private static func isLabelPart(_ part: String) -> Bool {
        guard !part.isEmpty else { return false }
        return part.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    /// The main brand label of a host, e.g. "substack" for "substack.com" or
    /// "www.substack.com".
    private static func mainLabel(ofHost host: String) -> String {
        var parts = host.split(separator: ".").map(String.init)
        if parts.first?.lowercased() == "www" { parts.removeFirst() }
        guard parts.count >= 2 else { return "" }
        return parts[parts.count - 2]
    }

    private static func isEmail(_ token: String) -> Bool {
        token.range(
            of: #"^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func isPlainWord(_ token: String) -> Bool {
        guard token.count >= 2 else { return false }
        return token.allSatisfy { $0.isLetter }
    }

    // MARK: - Phone parsing

    private struct PhoneSpan { var digits: String; var style: String }

    private static func firstPhoneSpan(in text: String) -> PhoneSpan? {
        // Match a run of digits with common separators; require ≥7 digits after
        // stripping so short numbers don't register.
        let pattern = #"\(?\d[\d\s().-]{5,}\d"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        var best: PhoneSpan?
        regex.enumerateMatches(in: text, range: range) { match, _, stop in
            guard let match, let r = Range(match.range, in: text) else { return }
            let span = String(text[r])
            let digits = span.filter { $0.isNumber }
            guard digits.count >= 7 else { return }
            best = PhoneSpan(digits: digits, style: phoneStyle(for: span))
            stop.pointee = true
        }
        return best
    }

    private static func phoneStyle(for span: String) -> String {
        if span.contains("(") && span.contains(")") { return "parenthesized" }
        if span.contains(".") { return "dotted" }
        if span.contains("-") { return "hyphenated" }
        if span.contains(" ") { return "spaced" }
        return "plain"
    }

    // MARK: - Dedupe

    private static func dedupe(_ signals: [FormatCorrectionSignal]) -> [FormatCorrectionSignal] {
        var seen = Set<String>()
        var result: [FormatCorrectionSignal] = []
        for signal in signals {
            let key = [signal.category.rawValue, signal.scopeHint, signal.observedValue]
                .joined(separator: "|")
                .lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(signal)
        }
        return result
    }
}
