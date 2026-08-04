import CoreGraphics
import Foundation

/// A high-confidence person shown as the active target of the focused
/// conversation composer. The first name is structured metadata rather than a
/// general bias term so it can only participate in the guarded greeting repair.
struct ActiveRecipientContext: Codable, Sendable, Hashable {
    let fullName: String
    let firstName: String
    let confidence: Double
}

enum ActiveRecipientEvidenceKind: String, Sendable {
    case heading
    case link
    case titledElement
    case staticText
    case button

    var isPrimaryHeaderEvidence: Bool {
        switch self {
        case .heading, .link, .titledElement:
            true
        case .staticText, .button:
            false
        }
    }
}

struct ActiveRecipientEvidence: Sendable, Equatable {
    let text: String
    let kind: ActiveRecipientEvidenceKind
    let frame: CGRect
}

struct ActiveRecipientEvidenceBatch: Sendable, Equatable {
    let evidence: [ActiveRecipientEvidence]
    let descendantPrimaryKind: ActiveRecipientEvidenceKind?
}

/// Converts an AX element's labeled attributes into evidence without losing
/// provenance. Descriptions/help can mention a person but are never themselves
/// proof that the element is the active header.
enum ActiveRecipientEvidenceFactory {
    static func make(
        role: String,
        title: String?,
        value: String?,
        description: String?,
        help: String?,
        frame: CGRect,
        inheritedPrimaryKind: ActiveRecipientEvidenceKind?
    ) -> ActiveRecipientEvidenceBatch {
        let ownPrimaryKind: ActiveRecipientEvidenceKind? = switch role {
        case "AXHeading": .heading
        case "AXLink": .link
        default: nil
        }
        let directKind: ActiveRecipientEvidenceKind? = if let ownPrimaryKind {
            ownPrimaryKind
        } else if role == "AXButton" {
            .button
        } else if role == "AXStaticText" {
            inheritedPrimaryKind ?? .staticText
        } else if let inheritedPrimaryKind {
            inheritedPrimaryKind
        } else if title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            .titledElement
        } else {
            nil
        }

        var evidence: [ActiveRecipientEvidence] = []
        var seen = Set<String>()
        func append(_ rawText: String?, kind: ActiveRecipientEvidenceKind?) {
            guard let kind, let rawText else { return }
            let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (3...160).contains(text.count) else { return }
            let key = "\(kind.rawValue):\(text)"
            guard seen.insert(key).inserted else { return }
            evidence.append(ActiveRecipientEvidence(text: text, kind: kind, frame: frame))
        }

        append(title, kind: directKind)
        if ownPrimaryKind != nil
            || inheritedPrimaryKind != nil
            || role == "AXStaticText"
            || role == "AXButton" {
            append(value, kind: directKind)
        }
        append(description, kind: .staticText)
        append(help, kind: .staticText)

        let descendantPrimaryKind: ActiveRecipientEvidenceKind?
        if let ownPrimaryKind {
            descendantPrimaryKind = ownPrimaryKind
        } else if role == "AXButton" {
            descendantPrimaryKind = nil
        } else {
            descendantPrimaryKind = inheritedPrimaryKind
        }
        return ActiveRecipientEvidenceBatch(
            evidence: evidence,
            descendantPrimaryKind: descendantPrimaryKind
        )
    }
}

/// Cheap gates that run before any focused-ancestor traversal.
enum ActiveRecipientEligibility {
    private static let textInputRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox",
    ]

    static func allows(hot: ContextExtractor.HotContext) -> Bool {
        guard BrowserCatalog.isBrowser(hot.bundleId) else { return false }
        guard SurfaceClassifier.hostName(from: hot.browserURL) != nil else { return false }
        guard let fingerprint = hot.targetFingerprint,
              fingerprint.isSensitiveInput != true,
              let role = fingerprint.role,
              textInputRoles.contains(role) else {
            return false
        }

        let surface = SurfaceClassifier.classify(hot: hot)
        guard [.email, .chat, .social].contains(surface.kind) else { return false }
        return [.compose, .reply, .comment].contains(surface.fieldKind)
    }

    /// Accessibility labels are the second gate. LinkedIn classifies every
    /// focused field on `/feed/` as social/comment, so the focused element must
    /// positively look like a conversation composer and must not look like the
    /// global search box, a post comment, or a profile form.
    static func focusedElementLooksLikeConversationComposer(
        attributes: [String]
    ) -> Bool {
        let normalized = attributes
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(
                of: #"[^a-z0-9]+"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }

        if rejectedComposerPhrases.contains(where: { containsPhrase($0, in: normalized) }) {
            return false
        }
        return acceptedComposerPhrases.contains(where: { containsPhrase($0, in: normalized) })
    }

    private static func containsPhrase(_ phrase: String, in value: String) -> Bool {
        (" " + value + " ").contains(" " + phrase + " ")
    }

    private static let acceptedComposerPhrases = [
        "message", "write a message", "send a message", "message body",
        "compose", "compose message", "reply message", "email body",
        "mail body", "chat message",
    ]

    private static let rejectedComposerPhrases = [
        "search", "search messages", "global search", "query", "filter",
        "comment", "add a comment", "write a comment", "reply to comment",
        "create a post", "post an update", "share a post", "post your reply",
        "write a reply", "reply to post", "reply to this post",
        "first name", "last name", "email address", "phone number",
        "username", "password",
    ]
}

/// Pure role/geometry resolver. AX collection is intentionally separate so the
/// ambiguous cases are deterministic and unit-testable.
enum ActiveRecipientResolver {
    private static let minimumScopeWidth: CGFloat = 220
    private static let minimumScopeHeight: CGFloat = 180
    private static let headerBandFraction: CGFloat = 0.32

    static func resolve(
        scopeFrame: CGRect,
        composerFrame: CGRect,
        evidence: [ActiveRecipientEvidence]
    ) -> ActiveRecipientContext? {
        guard scopeFrame.width >= minimumScopeWidth,
              scopeFrame.height >= minimumScopeHeight,
              scopeFrame.contains(CGPoint(x: composerFrame.midX, y: composerFrame.midY))
        else {
            return nil
        }

        let distanceToMinY = abs(composerFrame.midY - scopeFrame.minY)
        let distanceToMaxY = abs(scopeFrame.maxY - composerFrame.midY)
        let composerIsNearMinY = distanceToMinY <= distanceToMaxY
        let nearestEdgeDistance = min(distanceToMinY, distanceToMaxY)
        guard nearestEdgeDistance <= scopeFrame.height * 0.42 else { return nil }

        let primaryNames = evidence
            .filter { item in
                let clippedFrame = item.frame.intersection(scopeFrame)
                return item.kind.isPrimaryHeaderEvidence
                    && !clippedFrame.isNull
                    && !clippedFrame.isEmpty
                    && isInComposerColumn(clippedFrame, composerFrame: composerFrame)
                    && isInHeaderBand(
                        clippedFrame,
                        scopeFrame: scopeFrame,
                        composerIsNearMinY: composerIsNearMinY
                    )
            }
            .flatMap { personNameCandidates(from: $0.text) }

        var canonicalToDisplay: [String: String] = [:]
        for name in primaryNames {
            canonicalToDisplay[canonicalName(name)] = name
        }
        guard canonicalToDisplay.count == 1,
              let fullName = canonicalToDisplay.values.first else {
            return nil
        }

        let parts = fullName.split(whereSeparator: \.isWhitespace)
        guard (2...4).contains(parts.count), let first = parts.first else { return nil }
        let firstName = String(first)
        let corroborated = evidence.contains { item in
            guard !item.kind.isPrimaryHeaderEvidence else { return false }
            let normalized = canonicalName(item.text)
            return normalized.contains(canonicalName(fullName))
                || containsWholeWord(canonicalName(firstName), in: normalized)
        }

        return ActiveRecipientContext(
            fullName: fullName,
            firstName: firstName,
            confidence: corroborated ? 0.96 : 0.92
        )
    }

    private static func isInComposerColumn(
        _ frame: CGRect,
        composerFrame: CGRect
    ) -> Bool {
        let padding = max(48, composerFrame.width * 0.25)
        return frame.midX >= composerFrame.minX - padding
            && frame.midX <= composerFrame.maxX + padding
    }

    private static func isInHeaderBand(
        _ frame: CGRect,
        scopeFrame: CGRect,
        composerIsNearMinY: Bool
    ) -> Bool {
        if composerIsNearMinY {
            return frame.midY >= scopeFrame.maxY - (scopeFrame.height * headerBandFraction)
        }
        return frame.midY <= scopeFrame.minY + (scopeFrame.height * headerBandFraction)
    }

    private static func personNameCandidates(from text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let pattern = #"\p{Lu}[\p{L}\p{M}'’\-]{1,39}(?:\s+(?:\p{Lu}[\p{L}\p{M}'’\-]{1,39}|del|den|der|van|von|de|da|la|le)){1,3}(?![\p{L}\p{M}'’\-])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            return normalizedCandidate(String(text[matchRange]))
        }
    }

    private static func normalizedCandidate(_ candidate: String) -> String? {
        var parts = candidate
            .split(whereSeparator: \.isWhitespace)
            .map { part in
                String(part)
                    .replacingOccurrences(
                        of: #"(?:'s|’s)$"#,
                        with: "",
                        options: [.regularExpression, .caseInsensitive]
                    )
            }
        while let first = parts.first,
              ignoredEdgeWords.contains(canonicalName(first)) {
            parts.removeFirst()
        }
        while let last = parts.last,
              ignoredEdgeWords.contains(canonicalName(last)) {
            parts.removeLast()
        }
        guard (2...4).contains(parts.count) else { return nil }
        let result = parts.joined(separator: " ")
        let canonical = canonicalName(result)
        guard !rejectedNames.contains(canonical) else { return nil }
        guard parts.allSatisfy(isNamePart) else { return nil }
        return result
    }

    private static func isNamePart(_ part: String) -> Bool {
        let canonical = canonicalName(part)
        if nameParticles.contains(canonical) { return true }
        return part.first?.isUppercase == true
            && part.unicodeScalars.allSatisfy {
                CharacterSet.letters.contains($0)
                    || CharacterSet.nonBaseCharacters.contains($0)
                    || $0 == "'" || $0 == "’" || $0 == "-"
            }
    }

    private static func containsWholeWord(_ word: String, in value: String) -> Bool {
        value
            .split(whereSeparator: { !$0.isLetter })
            .contains { String($0) == word }
    }

    private static func canonicalName(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let nameParticles: Set<String> = [
        "da", "de", "del", "den", "der", "la", "le", "van", "von",
    ]

    private static let ignoredEdgeWords: Set<String> = [
        "active", "available", "away", "linkedin", "message", "messaging",
        "new", "online", "open", "profile", "reply", "send", "view",
    ]

    private static let rejectedNames: Set<String> = [
        "new message", "send message", "reply message", "search messages",
        "linkedin messaging", "show more", "view profile", "active now",
    ]
}
