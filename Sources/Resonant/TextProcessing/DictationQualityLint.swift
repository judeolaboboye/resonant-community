import Foundation

enum DictationQualityIssue: String, CaseIterable, Sendable, Equatable {
    case collapsedWordRun = "collapsed_word_run"
    case malformedEmailClosing = "malformed_email_closing"
    case numericIdiom = "numeric_idiom"
    case unformattedEmailEnvelope = "unformatted_email_envelope"
    case longUnstructuredText = "long_unstructured_text"
    case assistantArtifact = "assistant_artifact"
    case parallelClauseContentDeletion = "parallel_clause_content_deletion"
}

/// Conservative acceptance gate for cloud cleanup. Repeated clause frames
/// often describe parallel facts ("I don't see X, I don't see Y"); deleting
/// either distinctive slot is data loss, not cleanup. The detector exempts
/// dash-marked interruptions/restarts.
enum DictationCleanupCandidateGate {
    struct Decision: Sendable, Equatable {
        let text: String
        let issue: DictationQualityIssue?

        var accepted: Bool { issue == nil }

        func applying(to cleanup: DictationQualityTrace.Cleanup) -> DictationQualityTrace.Cleanup {
            guard let issue else { return cleanup }
            var cleanup = cleanup
            cleanup.status = .fallbackLocal
            cleanup.accepted = false
            cleanup.fallbackReason = issue.rawValue
            if !cleanup.qualityIssues.contains(issue.rawValue) {
                cleanup.qualityIssues.append(issue.rawValue)
            }
            return cleanup
        }
    }

    private struct Clause {
        let text: String
        let separatorAfter: String
    }

    private static let clauseSeparator = try! NSRegularExpression(
        pattern: #"(?:[,;.!?…\n]+|[—–]|--+)"#
    )
    private static let discourseOpeners: Set<String> = [
        "so", "and", "but", "also", "then", "plus", "well",
    ]
    private static let stopwords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "so", "i", "we", "you", "he", "she",
        "it", "they", "me", "my", "our", "your", "his", "her", "their", "is", "am",
        "are", "was", "were", "be", "been", "being", "to", "of", "for", "in", "on",
        "at", "by", "with", "from", "as", "that", "this", "these", "those", "do",
        "does", "did", "don", "t", "not", "have", "has", "had", "will", "would",
        "can", "could", "should", "may", "might", "must",
    ]

    static func resolve(original: String, candidate: String) -> Decision {
        guard deletesDistinctiveParallelClauseContent(
            original: original,
            candidate: candidate
        ) else {
            return Decision(text: candidate, issue: nil)
        }
        return Decision(text: original, issue: .parallelClauseContentDeletion)
    }

    private static func deletesDistinctiveParallelClauseContent(
        original: String,
        candidate: String
    ) -> Bool {
        let clauses = splitClauses(original)
        guard clauses.count >= 2 else { return false }
        let candidateTokens = Set(contentTokens(candidate))

        for index in 0..<(clauses.count - 1) {
            let first = clauses[index]
            let second = clauses[index + 1]
            guard !isInterruptionSeparator(first.separatorAfter) else { continue }

            let firstTokens = frameTokens(first.text)
            let secondTokens = frameTokens(second.text)

            let prefixCount = commonPrefixCount(firstTokens, secondTokens)
            // Subject+verb frames ("we need X, we need Y") are already a
            // strong parallel-clause signal. One shared token is too broad,
            // but requiring three leaves this common enumeration shape open.
            guard prefixCount >= 2 else { continue }

            let firstSlot = Set(contentTokens(Array(firstTokens.dropFirst(prefixCount))))
            let secondSlot = Set(contentTokens(Array(secondTokens.dropFirst(prefixCount))))
            let firstDistinctive = firstSlot.subtracting(secondSlot)
            let secondDistinctive = secondSlot.subtracting(firstSlot)
            guard !firstDistinctive.isEmpty, !secondDistinctive.isEmpty else { continue }

            let firstDropped = firstDistinctive.isDisjoint(with: candidateTokens)
            let secondDropped = secondDistinctive.isDisjoint(with: candidateTokens)
            if firstDropped || secondDropped {
                return true
            }
        }
        return false
    }

    private static func splitClauses(_ text: String) -> [Clause] {
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = clauseSeparator.matches(in: text, range: fullRange)
        var clauses: [Clause] = []
        var start = text.startIndex

        for match in matches {
            guard let separatorRange = Range(match.range, in: text) else { continue }
            let clauseText = String(text[start..<separatorRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !clauseText.isEmpty {
                clauses.append(Clause(
                    text: clauseText,
                    separatorAfter: String(text[separatorRange])
                ))
            }
            start = separatorRange.upperBound
        }

        let tail = String(text[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            clauses.append(Clause(text: tail, separatorAfter: ""))
        }
        return clauses
    }

    private static func frameTokens(_ text: String) -> [String] {
        var tokens = tokens(text)
        while let first = tokens.first, discourseOpeners.contains(first) {
            tokens.removeFirst()
        }
        return tokens
    }

    private static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    private static func contentTokens(_ text: String) -> [String] {
        contentTokens(tokens(text))
    }

    private static func contentTokens(_ tokens: [String]) -> [String] {
        tokens.filter { !stopwords.contains($0) }
    }

    private static func commonPrefixCount(_ lhs: [String], _ rhs: [String]) -> Int {
        var count = 0
        while count < lhs.count, count < rhs.count, lhs[count] == rhs[count] {
            count += 1
        }
        return count
    }

    private static func isInterruptionSeparator(_ separator: String) -> Bool {
        separator.contains("—") || separator.contains("–") || separator.contains("--")
    }
}

enum DictationQualityMode: String, Sendable, Equatable {
    case verbatim
    case clean
    case polished
    case structured
}

struct DictationQualityPolicy: Sendable, Equatable {
    let mode: DictationQualityMode

    var allowsLocalRepairs: Bool {
        mode != .verbatim
    }

    var allowsCloudRepair: Bool {
        switch mode {
        case .polished, .structured:
            return true
        case .verbatim, .clean:
            return false
        }
    }
}

struct DictationQualityLintResult: Sendable, Equatable {
    let issues: [DictationQualityIssue]
    let policy: DictationQualityPolicy

    var issueCodes: [String] {
        issues.map(\.rawValue)
    }

    var requiresRepair: Bool {
        !issues.isEmpty
    }
}

enum DictationQualityLint {
    private static let emailClosingPhrases =
        "all the best|all my best|best regards|kind regards|best wishes|many thanks|thanks again|yours truly|yours sincerely|thank you|take care|talk soon|speak soon|appreciate it|with love|lots of love|until next time|until soon|catch you later|bye for now|regards|sincerely|thanks|cheers|best|warmly"

    static func evaluate(
        originalTranscript: String,
        candidateText: String,
        profile: CloudProcessingSupport.CleanupPromptProfile,
        appKey: String?,
        surfaceKind: String?
    ) -> DictationQualityLintResult {
        let original = originalTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = candidateText.trimmingCharacters(in: .whitespacesAndNewlines)
        let policy = qualityPolicy(
            text: candidate,
            profile: profile,
            appKey: appKey,
            surfaceKind: surfaceKind
        )
        guard !candidate.isEmpty else {
            return DictationQualityLintResult(issues: [], policy: policy)
        }

        var issues: [DictationQualityIssue] = []

        if policy.allowsLocalRepairs,
           CollapsedRunRepair.repair(candidate) != candidate {
            issues.append(.collapsedWordRun)
        }
        if containsAssistantArtifact(candidate, original: original) {
            issues.append(.assistantArtifact)
        }
        if containsNumericIdiom(candidate) {
            issues.append(.numericIdiom)
        }
        if let issue = DictationCleanupCandidateGate.resolve(
            original: original,
            candidate: candidate
        ).issue {
            issues.append(issue)
        }
        if profile == .emailFull || appKey == "email" || surfaceKind == "email" {
            if containsMalformedEmailClosing(candidate) {
                issues.append(.malformedEmailClosing)
            }
            if containsUnformattedEmailEnvelope(candidate) {
                issues.append(.unformattedEmailEnvelope)
            }
        }
        if policy.mode == .structured,
           shouldStructureLongText(candidate, profile: profile, appKey: appKey, surfaceKind: surfaceKind) {
            issues.append(.longUnstructuredText)
        }

        var unique: [DictationQualityIssue] = []
        for issue in issues where !unique.contains(issue) {
            unique.append(issue)
        }
        return DictationQualityLintResult(issues: unique, policy: policy)
    }

    static func applyLocalRepairs(
        to text: String,
        policy: DictationQualityPolicy
    ) -> String {
        guard policy.allowsLocalRepairs else { return text }

        var repaired = text
        repaired = CollapsedRunRepair.repair(repaired)
        repaired = FragmentedWordRepair.repair(repaired)
        repaired = repairNumericIdioms(repaired)
        repaired = stripAssistantArtifactLabels(repaired)
        return repaired
    }

    private static func qualityPolicy(
        text: String,
        profile: CloudProcessingSupport.CleanupPromptProfile,
        appKey: String?,
        surfaceKind: String?
    ) -> DictationQualityPolicy {
        let kind = surfaceKind ?? appKey
        if isVerbatimContext(appKey: appKey, surfaceKind: kind) {
            return DictationQualityPolicy(mode: .verbatim)
        }
        if profile == .message || appKey == "chat" || kind == "chat" || kind == "social" {
            return DictationQualityPolicy(mode: .clean)
        }
        if profile == .emailFull || appKey == "email" || kind == "email" {
            return DictationQualityPolicy(mode: .polished)
        }
        if shouldStructureLongText(text, profile: profile, appKey: appKey, surfaceKind: kind) {
            return DictationQualityPolicy(mode: .structured)
        }
        if kind == "docs" || kind == "task" || kind == "form" || kind == "browser" {
            return DictationQualityPolicy(mode: .polished)
        }
        return DictationQualityPolicy(mode: .clean)
    }

    private static func isVerbatimContext(appKey: String?, surfaceKind: String?) -> Bool {
        let verbatimKinds: Set<String> = ["code", "terminal", "search"]
        if let appKey, verbatimKinds.contains(appKey) {
            return true
        }
        if let surfaceKind, verbatimKinds.contains(surfaceKind) {
            return true
        }
        return false
    }

    private static func repairNumericIdioms(_ text: String) -> String {
        var repaired = text
        let replacements: [(String, String)] = [
            (#"\b1\s+last\s+time\b"#, "one last time"),
            (#"\b1\s+more\s+time\b"#, "one more time"),
            (#"\b1\s+more\s+thing\b"#, "one more thing"),
            (#"\b1\s+final\s+(thing|question|point|note|ask|thought|idea|favor|detail|pass|look|review)\b"#, "one final $1"),
            (#"\b1\s+quick\s+(thing|question|point|note|ask|thought|idea|favor|detail|pass|look|review)\b"#, "one quick $1"),
            (#"\b1\s+small\s+(thing|question|point|note|ask|thought|idea|favor|detail|pass|look|review)\b"#, "one small $1"),
            (#"\b1\s+other\s+(thing|question|point|note|ask|thought|idea|favor|detail|pass|look|review)\b"#, "one other $1"),
            (#"\b1\s+last\s+(thing|question|point|note|ask|thought|idea|favor|detail|pass|look|review)\b"#, "one last $1")
        ]

        for (pattern, replacement) in replacements {
            repaired = repaired.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return repaired
    }

    private static func stripAssistantArtifactLabels(_ text: String) -> String {
        let stripped = text.replacingOccurrences(
            of: #"(?is)^\s*(?:here(?:'s| is)\s+(?:the|a|your)\s+(?:cleaned|corrected|edited|revised|final)\s+(?:message|text|email|version)|cleaned text|cleaned message|final version)\s*[:\n]\s*"#,
            with: "",
            options: [.regularExpression]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? text : stripped
    }

    private static func containsMalformedEmailClosing(_ text: String) -> Bool {
        text.matches(
            #"(?is)\b(?:"# + emailClosingPhrases + #")\s+to\s+[\p{Lu}][\p{L}'-]{1,30}(?:\s+[\p{Lu}][\p{L}'-]{1,30}){0,2}[.!?]?\s*$"#
        )
    }

    private static func containsUnformattedEmailEnvelope(_ text: String) -> Bool {
        guard !text.contains("\n\n") else { return false }
        let hasGreeting = text.matches(
            #"(?is)^\s*(?:hi|hello|hey|dear|good\s+morning|good\s+afternoon|good\s+evening)\b[^\n]{0,100}[,.]"#
        )
        let hasClosing = text.matches(
            #"(?is)\b(?:"# + emailClosingPhrases + #"),?\s+[\p{Lu}][\p{L}'-]{1,30}(?:\s+[\p{Lu}][\p{L}'-]{1,30}){0,2}[.!?]?\s*$"#
        )
        return hasGreeting && hasClosing
    }

    private static func containsNumericIdiom(_ text: String) -> Bool {
        text.matches(
            #"(?is)\b1\s+(?:(?:last|more)\s+time|(?:more|final|quick|small|other|last)\s+(?:thing|question|point|note|ask|thought|idea|favor|detail|pass|look|review))\b"#
        )
    }

    private static func containsAssistantArtifact(_ text: String, original: String) -> Bool {
        let artifactPattern = #"(?is)^\s*(?:here(?:'s| is)\s+(?:the|a|your)\s+(?:cleaned|corrected|edited|revised|final)\s+(?:message|text|email|version)|cleaned text:|cleaned message:|final version:)"#
        return text.matches(artifactPattern) && !original.matches(artifactPattern)
    }

    private static func shouldStructureLongText(
        _ text: String,
        profile: CloudProcessingSupport.CleanupPromptProfile,
        appKey: String?,
        surfaceKind: String?
    ) -> Bool {
        if profile == .message || profile == .emailFragment {
            return false
        }

        let blockedKinds: Set<String> = ["chat", "social", "code", "terminal", "search"]
        if let appKey, blockedKinds.contains(appKey) {
            return false
        }
        if let surfaceKind, blockedKinds.contains(surfaceKind) {
            return false
        }

        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count >= 70 || text.count >= 420 else {
            return false
        }
        guard !text.contains("\n\n"),
              !text.matches(#"(?m)^\s*(?:[-*]|•)\s+\S"#)
        else {
            return false
        }

        let sentenceCount = sentenceCount(in: text)
        return sentenceCount >= 4
    }

    private static func sentenceCount(in text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.bySentences, .substringNotRequired]
        ) { _, range, _, _ in
            if !String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                count += 1
            }
        }
        return count
    }
}

private extension String {
    func matches(_ pattern: String) -> Bool {
        range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
