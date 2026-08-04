import AppKit
import Foundation

enum ContextEntityExtractor {
    private struct Candidate: Hashable {
        let type: ContextEntityType
        let value: String
        let source: EvidenceSource
        let confidence: Double
        let proximity: Double
        let evidence: String
    }

    static func extract(
        surface: SurfaceDescriptor,
        hot: ContextExtractor.HotContext,
        cold: ContextExtractor.ColdContext? = nil,
        transcript: String? = nil,
        recentTerms: [String] = []
    ) -> [ContextEntity] {
        var candidates: [Candidate] = []

        addCandidates(from: hot.windowTitle, source: .windowTitle, confidence: 0.72, proximity: 0.7, evidence: "window title", surface: surface, into: &candidates)
        addCandidates(from: hot.browserURL, source: .browserURL, confidence: 0.80, proximity: 0.75, evidence: "browser URL", surface: surface, into: &candidates)
        addCandidates(from: hot.selectedText, source: .selectedText, confidence: 0.88, proximity: 0.95, evidence: "selected text", surface: surface, into: &candidates)
        addCandidates(from: hot.focusedFieldContent, source: .focusedField, confidence: 0.64, proximity: 0.9, evidence: "focused field", surface: surface, into: &candidates)
        if let recipient = hot.activeRecipient {
            appendCandidate(
                value: recipient.fullName,
                type: .personName,
                source: .visibleSnippet,
                confidence: recipient.confidence,
                proximity: 0.98,
                evidence: "active conversation recipient",
                into: &candidates
            )
        }

        if let cold {
            for fileName in cold.codeFiles {
                appendCandidate(
                    value: fileName,
                    type: fileName.contains("/") ? .filePath : .fileName,
                    source: .openFile,
                    confidence: 0.92,
                    proximity: 0.86,
                    evidence: "open editor file",
                    into: &candidates
                )
            }

            for member in cold.slackMembers {
                appendCandidate(
                    value: member,
                    type: .personName,
                    source: .visibleSnippet,
                    confidence: 0.78,
                    proximity: 0.72,
                    evidence: "visible chat participant",
                    into: &candidates
                )
            }

            for snippet in cold.visibleTextSnippets.prefix(50) {
                addCandidates(
                    from: snippet,
                    source: .visibleSnippet,
                    confidence: 0.62,
                    proximity: 0.52,
                    evidence: "visible snippet",
                    surface: surface,
                    into: &candidates
                )
            }
        }

        for term in recentTerms.prefix(20) {
            addCandidates(
                from: term,
                source: .recentSameSurface,
                confidence: 0.48,
                proximity: 0.3,
                evidence: "recent same-surface term",
                surface: surface,
                into: &candidates
            )
        }

        if let siteHost = surface.siteHost {
            appendCandidate(
                value: siteHost,
                type: .siteDomain,
                source: .browserURL,
                confidence: 0.88,
                proximity: 0.8,
                evidence: "current browser host",
                into: &candidates
            )
            if let brand = brandCasingCandidate(host: siteHost, windowTitle: hot.windowTitle) {
                appendCandidate(
                    value: brand.value,
                    type: .customTerm,
                    source: .browserURL,
                    confidence: 0.84,
                    proximity: 0.8,
                    evidence: "site brand name",
                    into: &candidates
                )
            }
        }
        if let appName = surface.appName {
            appendCandidate(
                value: appName,
                type: .appName,
                source: .appMetadata,
                confidence: 0.76,
                proximity: 0.75,
                evidence: "frontmost app",
                into: &candidates
            )
        }

        return rankedEntities(from: candidates, surface: surface, transcript: transcript)
    }

    static func biasTerms(from entities: [ContextEntity], limit: Int = 20) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for entity in entities.sorted(by: { $0.rankingScore > $1.rankingScore }) {
            guard result.count < limit else { break }
            guard entity.trustTier == .biasTerm || entity.trustTier == .grounding else { continue }
            guard !entity.isSensitive else { continue }
            let value = entity.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.count >= 2, value.count <= 80 else { continue }
            let key = value.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(value)
        }

        return result
    }

    private static func addCandidates(
        from text: String?,
        source: EvidenceSource,
        confidence: Double,
        proximity: Double,
        evidence: String,
        surface: SurfaceDescriptor,
        into candidates: inout [Candidate]
    ) {
        guard let text = normalize(text), !looksSensitive(text) else { return }

        for email in matches(emailPattern, in: text) {
            appendCandidate(value: email, type: .emailAddress, source: source, confidence: min(confidence + 0.1, 0.98), proximity: proximity, evidence: evidence, into: &candidates)
        }
        for handle in matches(handlePattern, in: text) {
            let type: ContextEntityType = handle.hasPrefix("#") ? .chatChannel : .personHandle
            appendCandidate(value: handle, type: type, source: source, confidence: min(confidence + 0.08, 0.96), proximity: proximity, evidence: evidence, into: &candidates)
        }
        for community in matches(redditCommunityPattern, in: text) {
            appendCandidate(value: community, type: .chatChannel, source: source, confidence: min(confidence + 0.08, 0.96), proximity: proximity, evidence: evidence, into: &candidates)
        }
        for ticket in matches(ticketPattern, in: text) {
            appendCandidate(value: ticket, type: .ticketID, source: source, confidence: min(confidence + 0.12, 0.98), proximity: proximity, evidence: evidence, into: &candidates)
        }
        for path in matches(pathPattern, in: text) {
            appendCandidate(value: path, type: .filePath, source: source, confidence: min(confidence + 0.12, 0.96), proximity: proximity, evidence: evidence, into: &candidates)
        }
        for file in matches(filePattern, in: text) {
            appendCandidate(value: file, type: .fileName, source: source, confidence: min(confidence + 0.10, 0.96), proximity: proximity, evidence: evidence, into: &candidates)
        }
        for domain in matches(domainPattern, in: text) {
            guard !domain.contains("@") else { continue }
            appendCandidate(value: domain, type: .siteDomain, source: source, confidence: min(confidence + 0.05, 0.92), proximity: proximity, evidence: evidence, into: &candidates)
        }

        if surface.kind == .code || source == .openFile {
            for symbol in matches(codeSymbolPattern, in: text).prefix(12) {
                guard !isLikelySentenceWord(symbol) else { continue }
                appendCandidate(value: symbol, type: .codeSymbol, source: source, confidence: min(confidence + 0.04, 0.88), proximity: proximity, evidence: evidence, into: &candidates)
            }
        }

        for name in personNameCandidates(from: text, surface: surface).prefix(10) {
            appendCandidate(value: name, type: .personName, source: source, confidence: confidenceForName(sourceConfidence: confidence, source: source, surface: surface), proximity: proximity, evidence: evidence, into: &candidates)
        }
    }

    private static func rankedEntities(
        from candidates: [Candidate],
        surface: SurfaceDescriptor,
        transcript: String?
    ) -> [ContextEntity] {
        var merged: [String: ContextEntity] = [:]

        for candidate in candidates {
            let normalizedValue = normalizedKey(candidate.value)
            guard !normalizedValue.isEmpty else { continue }
            let sensitive = looksSensitive(candidate.value)
            let trustTier = trustTier(for: candidate, surface: surface, sensitive: sensitive)
            let spokenForms = spokenForms(for: candidate.value, type: candidate.type)
            let entity = ContextEntity(
                type: candidate.type,
                value: candidate.value,
                normalizedValue: normalizedValue,
                spokenForms: spokenForms,
                source: candidate.source,
                confidence: clamp(candidate.confidence),
                recencyScore: recencyScore(for: candidate.source),
                proximityScore: clamp(candidate.proximity),
                trustTier: trustTier,
                isSensitive: sensitive,
                evidence: candidate.evidence,
                surfaceScope: surface.kind.rawValue,
                appScope: surface.bundleId,
                siteScope: surface.siteHost,
                projectScope: surface.projectLabel
            )

            let key = "\(candidate.type.rawValue):\(normalizedValue)"
            if let existing = merged[key] {
                merged[key] = existing.rankingScore >= entity.rankingScore ? existing : entity
            } else {
                merged[key] = entity
            }
        }

        let transcriptKey = normalizedKey(transcript ?? "")
        return merged.values
            .filter { entity in
                guard entity.trustTier != .blocked else { return false }
                if transcriptKey.contains(entity.normalizedValue) { return true }
                return entity.rankingScore >= minimumRankingScore(for: entity.type)
            }
            .sorted { lhs, rhs in
                if lhs.rankingScore == rhs.rankingScore {
                    return lhs.value < rhs.value
                }
                return lhs.rankingScore > rhs.rankingScore
            }
            .prefix(40)
            .map { $0 }
    }

    private static func trustTier(for candidate: Candidate, surface: SurfaceDescriptor, sensitive: Bool) -> ContextTrustTier {
        if sensitive { return .blocked }
        switch candidate.type {
        case .personName, .personHandle, .emailAddress, .fileName, .filePath, .repoName, .codeSymbol, .ticketID, .siteDomain, .url, .chatChannel, .customTerm:
            return .biasTerm
        case .appName, .documentTitle, .taskTitle, .chatThread, .organization:
            return surface.kind == .search ? .metadataOnly : .biasTerm
        case .styleSignal:
            return .styleHint
        }
    }

    private static func recencyScore(for source: EvidenceSource) -> Double {
        switch source {
        case .selectedText: 0.16
        case .focusedField: 0.14
        case .windowTitle, .browserURL, .appMetadata: 0.12
        case .openFile: 0.13
        case .visibleSnippet: 0.08
        case .recentSameSurface: 0.05
        default: 0.03
        }
    }

    private static func minimumRankingScore(for type: ContextEntityType) -> Double {
        switch type {
        case .personName: 1.18
        case .codeSymbol: 1.10
        default: 0.95
        }
    }

    private static func appendCandidate(
        value: String,
        type: ContextEntityType,
        source: EvidenceSource,
        confidence: Double,
        proximity: Double,
        evidence: String,
        into candidates: inout [Candidate]
    ) {
        guard let value = normalize(value), value.count <= 160 else { return }
        candidates.append(Candidate(
            type: type,
            value: value,
            source: source,
            confidence: confidence,
            proximity: proximity,
            evidence: evidence
        ))
    }

    static func spokenForms(for value: String, type: ContextEntityType) -> [String] {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return [] }

        if type == .siteDomain {
            return siteDomainSpokenForms(for: value)
        }

        var forms = Set<String>()
        let withoutAt = value.trimmingCharacters(in: CharacterSet(charactersIn: "@#"))
        let basename = (withoutAt as NSString).lastPathComponent
        let noExtension = (basename as NSString).deletingPathExtension
        let extensionPart = (basename as NSString).pathExtension
        let tokenized = spokenTokenize(noExtension)

        forms.insert(normalizedKey(value))
        forms.insert(spokenTokenize(value))
        forms.insert(tokenized)

        switch type {
        case .personHandle:
            forms.insert("at \(spokenTokenize(withoutAt))")
        case .chatChannel:
            forms.insert("channel \(spokenTokenize(withoutAt))")
        case .fileName, .filePath:
            if !extensionPart.isEmpty {
                forms.insert("\(tokenized) \(extensionPart.lowercased())")
                forms.insert("\(tokenized) dot \(extensionPart.lowercased())")
            }
        case .ticketID:
            forms.insert(value.replacingOccurrences(of: "-", with: " ").lowercased())
        default:
            break
        }

        return forms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 3 }
            .sorted { $0.count > $1.count }
    }

    /// Domain-shaped spoken forms only. Never emits the bare brand label on its
    /// own, so dictating "Substack" on substack.com stays "Substack" and only
    /// "substack dot com" / "substack com" repair to the domain.
    private static func siteDomainSpokenForms(for value: String) -> [String] {
        let lowered = value.lowercased()
        // Drop any scheme/path; keep just the host portion for spoken forms.
        let hostOnly = lowered
            .replacingOccurrences(of: #"^[a-z]+://"#, with: "", options: .regularExpression)
            .split(separator: "/").first.map(String.init) ?? lowered
        var labels = hostOnly.split(separator: ".").map(String.init)
        if labels.first == "www" { labels.removeFirst() }
        guard labels.count >= 2 else { return [] }

        let dotted = labels.joined(separator: ".")
        let spaced = labels.joined(separator: " ")
        let spelledDot = labels.joined(separator: " dot ")

        var forms = Set<String>([dotted, spaced, spelledDot])
        return forms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 3 }
            .sorted { $0.count > $1.count }
    }

    /// Bare brand label for a site host, properly cased, so casing-only repair
    /// can turn "substack" into "Substack". Returns nil for common sentence
    /// words (e.g. "medium") to avoid mangling ordinary prose.
    static func brandCasingCandidate(host: String, windowTitle: String?) -> (token: String, value: String)? {
        let lowered = host.lowercased()
        var labels = lowered.split(separator: ".").map(String.init)
        if labels.first == "www" { labels.removeFirst() }
        guard let label = labels.first, label.count >= 3 else { return nil }
        guard label.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        if isLikelySentenceWord(label) || isCommonDictionaryWord(label) { return nil }

        let cased = brandCasing(for: label, windowTitle: windowTitle)
        // Nothing to fix if the derived casing is just the lowercase label.
        guard cased != label else { return nil }
        return (label, cased)
    }

    private static func brandCasing(for label: String, windowTitle: String?) -> String {
        if let title = normalize(windowTitle) {
            for token in title.split(whereSeparator: { !($0.isLetter || $0.isNumber) }) {
                if token.lowercased() == label, String(token) != label {
                    return String(token)
                }
            }
        }
        if let known = knownBrandCasing[label] {
            return known
        }
        return label.prefix(1).uppercased() + label.dropFirst()
    }

    private static let knownBrandCasing: [String: String] = [
        "github": "GitHub",
        "youtube": "YouTube",
        "linkedin": "LinkedIn",
        "tiktok": "TikTok",
        "paypal": "PayPal",
        "icloud": "iCloud",
        "ebay": "eBay",
        "openai": "OpenAI",
        "posthog": "PostHog",
        "substack": "Substack",
        "wordpress": "WordPress",
        "dropbox": "Dropbox",
        "figjam": "FigJam",
        "deviantart": "DeviantArt",
        "stackoverflow": "StackOverflow",
        "typeform": "Typeform",
    ]

    private static func personNameCandidates(from text: String, surface: SurfaceDescriptor) -> [String] {
        let clean = text
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[@#][A-Za-z0-9_./-]+"#, with: " ", options: .regularExpression)
        let candidates = matches(personNamePattern, in: clean)
        return candidates.filter { candidate in
            let words = candidate.split(separator: " ")
            guard words.count >= 2, words.count <= 4 else { return false }
            guard !candidate.contains(".") else { return false }
            let lower = candidate.lowercased()
            guard !personNameStopPhrases.contains(lower) else { return false }
            guard !surfaceStopWords.contains(lower) else { return false }
            return true
        }
    }

    private static func confidenceForName(sourceConfidence: Double, source: EvidenceSource, surface: SurfaceDescriptor) -> Double {
        var confidence = sourceConfidence
        if [.email, .chat, .social].contains(surface.kind) {
            confidence += 0.08
        }
        if source == .visibleSnippet || source == .windowTitle {
            confidence += 0.03
        }
        return min(confidence, 0.91)
    }

    private static func matches(_ pattern: NSRegularExpression, in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: range).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return String(text[range]).trimmingCharacters(in: trimmingSet)
        }
    }

    private static func normalize(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedKey(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9@#._/\-]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func spokenTokenize(_ value: String) -> String {
        let separatedCamel = value.replacingOccurrences(
            of: #"([a-z0-9])([A-Z])"#,
            with: "$1 $2",
            options: .regularExpression
        )
        return separatedCamel
            .replacingOccurrences(of: #"[^A-Za-z0-9]+"#, with: " ", options: .regularExpression)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func looksSensitive(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > 28, !trimmed.contains(" "), trimmed.range(of: #"[A-Za-z0-9_\-]{28,}"#, options: .regularExpression) != nil {
            return true
        }
        let lower = trimmed.lowercased()
        return lower.contains("password")
            || lower.contains("api_key")
            || lower.contains("api key")
            || lower.contains("secret")
            || lower.contains("token=")
            || lower.contains("bearer ")
    }

    private static func isLikelySentenceWord(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.count < 4 || commonWords.contains(lower)
    }

    /// True when the token is an ordinary English dictionary word (e.g. "medium",
    /// "apple"). Used to suppress brand-casing on common-word site hosts so
    /// "a medium coffee" is never rewritten to "a Medium coffee", and by the
    /// personalization store to keep everyday words out of screen-sighting
    /// promotion. NSSpellChecker-backed — call from the main thread.
    static func isCommonDictionaryWord(_ value: String) -> Bool {
        let lower = value.lowercased()
        let misspelled = NSSpellChecker.shared.checkSpelling(
            of: lower,
            startingAt: 0,
            language: "en",
            wrap: false,
            inSpellDocumentWithTag: 0,
            wordCount: nil
        )
        // A recognized dictionary word yields no misspelled range.
        return misspelled.location == NSNotFound
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private static let trimmingSet = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters.subtracting(CharacterSet(charactersIn: "@#._/-")))

    private static let emailPattern = try! NSRegularExpression(pattern: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, options: [.caseInsensitive])
    private static let handlePattern = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9._/-])[@#][A-Za-z0-9_][A-Za-z0-9_.-]{1,39}"#)
    private static let redditCommunityPattern = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_/])(u|r)/[A-Za-z0-9_][A-Za-z0-9_-]{1,30}"#)
    private static let ticketPattern = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9])(?:[A-Z][A-Z0-9]{1,10}-\d+|#\d{2,7})(?![A-Za-z0-9])"#)
    private static let filePattern = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9._/-])[\w.-]+\.(?:swift|ts|tsx|js|jsx|py|go|rs|java|kt|cpp|c|h|cs|vue|rb|json|md|yml|yaml|toml|sql|html|css)(?![A-Za-z0-9_/.-])"#, options: [.caseInsensitive])
    private static let pathPattern = try! NSRegularExpression(pattern: #"(?:[\w.-]+/){1,}[\w.-]+\.(?:swift|ts|tsx|js|jsx|py|go|rs|java|kt|cpp|c|h|cs|vue|rb|json|md|yml|yaml|toml|sql|html|css)"#, options: [.caseInsensitive])
    private static let domainPattern = try! NSRegularExpression(pattern: #"(?<!@)\b(?:[a-z0-9-]+\.)+(?:com|ai|app|dev|io|net|org|co|me)\b(?:/[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]*)?"#, options: [.caseInsensitive])
    private static let codeSymbolPattern = try! NSRegularExpression(pattern: #"\b(?:[a-z]+[A-Z][A-Za-z0-9]*|[A-Z][A-Za-z0-9]+(?:[A-Z][a-z0-9]+)+|[a-z][a-z0-9]+_[a-z0-9_]+)\b"#)
    private static let personNamePattern = try! NSRegularExpression(pattern: #"\b[A-Z][a-z]+(?:\s+[A-Z][a-z]+){1,3}\b"#)

    private static let personNameStopPhrases: Set<String> = [
        "google docs", "apple mail", "microsoft teams", "visual studio code",
        "pull request", "new message", "inbox zero", "sent mail"
    ]
    private static let surfaceStopWords: Set<String> = [
        "gmail", "outlook", "slack", "teams", "telegram", "whatsapp", "reddit",
        "twitter", "github", "linear", "notion"
    ]
    private static let commonWords: Set<String> = [
        "this", "that", "with", "from", "have", "will", "when", "then", "than",
        "they", "them", "your", "about", "there", "their", "would", "could",
        "should", "please", "thanks", "hello"
    ]
}
