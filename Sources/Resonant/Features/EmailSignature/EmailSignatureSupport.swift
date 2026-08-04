import Foundation

enum EmailSignatureSupport {
    static let footerURLString = "https://www.onresonant.com/?utm_source=resonant_email_signature&utm_medium=email&utm_campaign=sent_with_resonant&utm_content=footer_link"
    static let footerMarkdown = "Sent with [Resonant](\(footerURLString))"

    struct FooterDecision: Equatable {
        enum Outcome: String {
            case applied
            case skipped
        }

        enum Reason: String {
            case applied
            case disabled
            case disallowedForTransform
            case emailModeDoesNotAppend
            case emptyText
            case nonBodyField
            case nonEmailContext
            case textAlreadyHasFooter
            case fieldAlreadyHasFooter
        }

        let outcome: Outcome
        let reason: Reason
        let enabled: Bool
        let allowSignature: Bool
        let emailMode: CloudProcessingSupport.EmailDictationMode?
        let isEmailContext: Bool
        let isLikelyEmailBodyField: Bool
        let trimmedTextIsEmpty: Bool
        let textAlreadyHasFooter: Bool
        let fieldAlreadyHasFooter: Bool
        let fieldRole: String?
        let fieldSubrole: String?

        var shouldAppendFooter: Bool {
            outcome == .applied
        }
    }

    private struct ClosingComponents {
        let phrase: String?
        let name: String?
    }

    private static let existingSignaturePattern = #"sent with\s+resonant|\[resonant\]\(https?://(?:www\.)?onresonant\.com(?:/[^\s)]*)?(?:\?[^\s)]*)?\)|https?://(?:www\.)?onresonant\.com(?:/[^\s)]*)?(?:\?[^\s)]*)?"#

    // Recognized greeting salutations. Multi-word forms ("good morning") use
    // \s+ internally so dictated whitespace is normalized.
    static let primaryGreetingWords =
        #"hi|hello|hey|dear|howdy|yo|greetings|aloha|hola|bonjour|namaste|shalom|sup|good\s+morning|good\s+afternoon|good\s+evening|good\s+day"#

    private static let leadingGreetingPattern: String = {
        let words = primaryGreetingWords
        // Three branches:
        //   1. greeting + (optional comma) + space + name + [,.] terminator
        //   2. greeting alone + [,.] terminator
        //   3. greeting + Title-case name(s) + sentence-start lookahead (STT-dropped commas)
        let withName = #"^\s*(?:"# + words + #")(?:,\s+|\s+)[^\n,]{1,80}?[,.](?:\s*\n\s*|\s+)"#
        let alone = #"^\s*(?:"# + words + #")[,.](?:\s*\n\s*|\s+)"#
        let relaxed = #"^\s*(?:"# + words + #")\s+[\p{Lu}][\p{L}'-]{1,30}(?:\s+[\p{Lu}][\p{L}'-]{1,30}){0,2}\s+(?=[\p{Ll}]|I\b)"#
        return "(?is)(?:" + withName + "|" + alone + "|" + relaxed + ")"
    }()

    // Common discourse markers, pronouns, salutations, and closings that
    // start a sentence with a comma but are NOT a recipient name. Without
    // this guard, "Sorry, I was late." would be detected as a greeting block.
    static let recipientGreetingExcludedWords =
        "yes|no|oh|yeah|nope|yep|yup|well|so|ok|okay|right|sure|look|listen|sorry|honestly|frankly|actually|truly|really|basically|literally|maybe|perhaps|anyway|anyhow|however|indeed|otherwise|first|firstly|second|secondly|third|thirdly|last|lastly|finally|also|again|additionally|furthermore|moreover|therefore|now|today|yesterday|tomorrow|unfortunately|fortunately|luckily|surprisingly|apparently|obviously|clearly|generally|specifically|personally|wait|stop|hold|hmm|hi|hello|hey|dear|thanks|thank|regards|sincerely|love|best|cheers|yours|warmly|aloha|greetings|howdy|yo|hola|bonjour|namaste|shalom|sup|good|morning|afternoon|evening|i|we|you|he|she|they|it|my|your|his|her|their|our|me|us|him|them"

    // 1-2 Title-case tokens followed by a comma at the start, when not in the
    // discourse-marker stoplist. Catches "John, please review..." style.
    private static let recipientGreetingPattern =
        #"(?is)^\s*(?!(?:"# + recipientGreetingExcludedWords + #")\b)([\p{Lu}][\p{L}'-]{1,29}(?:\s+[\p{Lu}][\p{L}'-]{1,29})?),(?:\s*\n\s*|\s+)"#

    // Multi-word and formal phrases. "best" / "love" etc. are too ambiguous in
    // body context (e.g. "I love Sarah.") and live in `strictClosingPhrases`,
    // which only matches when followed by a comma.
    private static let looseClosingPhrases =
        "all the best|all my best|best regards|kind regards|best wishes|many thanks|thanks again|yours truly|yours sincerely|thank you|take care|talk soon|speak soon|appreciate it|with love|lots of love|until next time|until soon|catch you later|bye for now|regards|sincerely|thanks|cheers"

    // Formal multi-word closings safe to detect mid-paragraph. We deliberately
    // exclude phrases that overlap with body usage ("thank you", "take care",
    // "thanks again", "with love", etc.) — those are common openers or
    // sentence-internal expressions and would mis-fire when followed by a
    // capitalized first name.
    private static let midTextLooseClosingPhrases =
        "all the best|all my best|best regards|kind regards|best wishes|yours truly|yours sincerely"

    // Single-word or short phrases that overlap with body usage; require a comma
    // after the phrase in inline detection to avoid false positives.
    private static let strictClosingPhrases =
        "aloha|love|best|yours|warmly|hugs|ciao|peace|bye|goodbye|xoxo|xo"

    private static let allClosingPhrases =
        looseClosingPhrases + "|" + strictClosingPhrases

    // 1-3 Title-case tokens, letters / apostrophe / hyphen only. Avoids matching
    // arbitrary 60-char tails like "Alex. P.S. Don't forget dinner." as a name.
    private static let inlineClosingNamePattern =
        #"[\p{Lu}][\p{L}'-]{1,30}(?:\s+[\p{Lu}][\p{L}'-]{0,30}){0,2}"#

    private static let trailingClosingPattern: String = {
        let phrases = allClosingPhrases
        return #"(?is)(?:\n\s*\n|\A)\s*(?:(?:"# + phrases + #"),?(?:\s*\n\s*|\s+)[\p{L}][\p{L}\s.'-]{0,60}[.!?]?|(?:"# + phrases + #"),?[.!?]?)\s*$"#
    }()

    static func applyingIfNeeded(
        to text: String,
        enabled: Bool,
        appName: String?,
        bundleId: String?,
        windowTitle: String?,
        browserURL: String?,
        allowSignature: Bool = true,
        emailMode: CloudProcessingSupport.EmailDictationMode? = nil,
        existingFieldContent: String? = nil,
        focusedFieldContext: EmailFocusedFieldContext? = nil,
        decisionHandler: ((FooterDecision) -> Void)? = nil
    ) -> String {
        let decision = footerDecision(
            to: text,
            enabled: enabled,
            appName: appName,
            bundleId: bundleId,
            windowTitle: windowTitle,
            browserURL: browserURL,
            allowSignature: allowSignature,
            emailMode: emailMode,
            existingFieldContent: existingFieldContent,
            focusedFieldContext: focusedFieldContext
        )
        decisionHandler?(decision)
        guard decision.shouldAppendFooter else {
            return text
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(trimmed)\n\n\(footerMarkdown)"
    }

    static func footerDecision(
        to text: String,
        enabled: Bool,
        appName: String?,
        bundleId: String?,
        windowTitle: String?,
        browserURL: String?,
        allowSignature: Bool = true,
        emailMode: CloudProcessingSupport.EmailDictationMode? = nil,
        existingFieldContent: String? = nil,
        focusedFieldContext: EmailFocusedFieldContext? = nil
    ) -> FooterDecision {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let modeAllowsFooter = emailMode.map(shouldAppendFooter(for:)) ?? true
        let likelyBodyField = EmailContextSupport.isLikelyEmailBodyField(focusedFieldContext)
        let emailContext = isEmailContext(
            appName: appName,
            bundleId: bundleId,
            windowTitle: windowTitle,
            browserURL: browserURL
        )
        let textAlreadyHasFooter = trimmed.matchesPattern(existingSignaturePattern)
        let fieldAlreadyHasFooter = existingFieldContent?.matchesPattern(existingSignaturePattern) ?? false
        let reason: FooterDecision.Reason

        if !enabled {
            reason = .disabled
        } else if !allowSignature {
            reason = .disallowedForTransform
        } else if !modeAllowsFooter {
            reason = .emailModeDoesNotAppend
        } else if trimmed.isEmpty {
            reason = .emptyText
        } else if !likelyBodyField {
            reason = .nonBodyField
        } else if !emailContext {
            reason = .nonEmailContext
        } else if textAlreadyHasFooter {
            reason = .textAlreadyHasFooter
        } else if fieldAlreadyHasFooter {
            reason = .fieldAlreadyHasFooter
        } else {
            reason = .applied
        }

        return FooterDecision(
            outcome: reason == .applied ? .applied : .skipped,
            reason: reason,
            enabled: enabled,
            allowSignature: allowSignature,
            emailMode: emailMode,
            isEmailContext: emailContext,
            isLikelyEmailBodyField: likelyBodyField,
            trimmedTextIsEmpty: trimmed.isEmpty,
            textAlreadyHasFooter: textAlreadyHasFooter,
            fieldAlreadyHasFooter: fieldAlreadyHasFooter,
            fieldRole: focusedFieldContext?.role,
            fieldSubrole: focusedFieldContext?.subrole
        )
    }

    static func shouldAppendFooter(for emailMode: CloudProcessingSupport.EmailDictationMode) -> Bool {
        switch emailMode {
        case .fullEmail, .signoffOnly:
            return true
        case .nonEmail, .fragment:
            return false
        }
    }

    static func removingDuplicateClosingIfNeeded(
        from text: String,
        appName: String?,
        bundleId: String?,
        windowTitle: String?,
        browserURL: String?,
        existingFieldContent: String? = nil
    ) -> String {
        guard isEmailContext(
            appName: appName,
            bundleId: bundleId,
            windowTitle: windowTitle,
            browserURL: browserURL
        ),
        let existingFieldContent,
        hasTrailingClosing(existingFieldContent),
        hasTrailingClosing(text)
        else {
            return text
        }

        let stripped = text.replacingOccurrences(
            of: trailingClosingPattern,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        return stripped.isEmpty ? text : stripped
    }

    static func normalizeDictatedEmailText(
        _ text: String,
        mode: CloudProcessingSupport.EmailDictationMode,
        fallbackSenderName: String?,
        existingFieldContent: String? = nil
    ) -> String {
        switch mode {
        case .nonEmail:
            return text
        case .fragment:
            return removingEmailEnvelope(from: text)
        case .fullEmail:
            return normalizingFullEmail(text, fallbackSenderName: fallbackSenderName)
        case .signoffOnly:
            return localSignoff(
                from: text,
                fallbackSenderName: fallbackSenderName,
                existingFieldContent: existingFieldContent
            )
        }
    }

    static func isEmailContext(
        appName: String?,
        bundleId: String?,
        windowTitle: String?,
        browserURL: String?
    ) -> Bool {
        EmailContextSupport.isEmailContext(
            appName: appName,
            bundleId: bundleId,
            windowTitle: windowTitle,
            browserURL: browserURL
        )
    }

    static func hasTrailingClosing(_ text: String) -> Bool {
        extractTrailingClosing(from: text) != nil
    }

    static func existingClosingNeedsName(_ text: String?) -> Bool {
        guard let closing = text.flatMap(extractTrailingClosing) else { return false }
        return closing.name == nil
    }

    private static func removingEmailEnvelope(from text: String) -> String {
        var working = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !working.isEmpty else { return working }

        let beforeGreeting = working
        working = working.replacingOccurrences(
            of: leadingGreetingPattern,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        if working == beforeGreeting {
            working = working.replacingOccurrences(
                of: recipientGreetingPattern,
                with: "",
                options: [.regularExpression]
            ).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let closingRange = trailingClosingRange(in: working) {
            let nsText = working as NSString
            working = nsText.replacingCharacters(in: closingRange, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return working
    }

    private static func normalizingFullEmail(_ text: String, fallbackSenderName: String?) -> String {
        let trimmed = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        return EmailDraftDocument
            .parse(trimmed, fallbackSenderName: fallbackSenderName)
            .rendered()
    }

    private struct EmailDraftDocument: Equatable {
        enum BodyBlock: Equatable {
            case paragraph(String)
            case bulletList([String])

            var rendered: String {
                switch self {
                case .paragraph(let text):
                    return text
                case .bulletList(let items):
                    return items.map { "- \($0)" }.joined(separator: "\n")
                }
            }
        }

        var greeting: String?
        var bodyBlocks: [BodyBlock]
        var closingBlock: String?

        static func parse(_ text: String, fallbackSenderName: String?) -> EmailDraftDocument {
            var body = text
            var closingBlock: String?

            if let closing = EmailSignatureSupport.extractTrailingClosing(from: body) {
                let resolvedName = closing.name ?? fallbackSenderName
                closingBlock = EmailSignatureSupport.renderClosing(phrase: closing.phrase, name: resolvedName)
                let bodyWithoutClosing = EmailSignatureSupport.replacingTrailingClosing(in: body, with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                body = EmailSignatureSupport.closingBodyWithoutTrailingSeparator(
                    from: bodyWithoutClosing,
                    closingPhrase: closing.phrase,
                    name: resolvedName
                )
            } else if let split = EmailSignatureSupport.extractInlineClosingFollowedByBody(
                from: body,
                fallbackSenderName: fallbackSenderName
            ) {
                body = EmailSignatureSupport.joinedBodyAroundMovedTrailingText(
                    prefix: split.prefix,
                    trailing: split.trailing
                )
                closingBlock = EmailSignatureSupport.renderClosing(
                    phrase: split.closing.phrase,
                    name: split.closing.name ?? fallbackSenderName
                )
            } else if let closing = EmailSignatureSupport.extractInlineClosing(from: body, fallbackSenderName: fallbackSenderName) {
                body = EmailSignatureSupport.closingBodyWithoutTrailingSeparator(
                    from: body,
                    closingPhrase: closing.phrase,
                    name: closing.name
                )
                closingBlock = EmailSignatureSupport.renderClosing(
                    phrase: closing.phrase,
                    name: closing.name ?? fallbackSenderName
                )
            }

            var remainingBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
            let greeting = EmailSignatureSupport.extractingLeadingGreeting(from: &remainingBody)
            return EmailDraftDocument(
                greeting: greeting,
                bodyBlocks: EmailSignatureSupport.emailBodyBlocks(from: remainingBody),
                closingBlock: closingBlock
            )
        }

        func rendered() -> String {
            var sections: [String] = []
            if let greeting, !greeting.isEmpty {
                sections.append(greeting)
            }
            sections.append(contentsOf: bodyBlocks.map(\.rendered).filter { !$0.isEmpty })
            if let closingBlock, !closingBlock.isEmpty {
                sections.append(closingBlock)
            }
            return sections.joined(separator: "\n\n")
        }
    }

    private static func joinedBodyAroundMovedTrailingText(prefix: String, trailing: String) -> String {
        let prefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let trailing = trailing.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else { return trailing }
        guard !trailing.isEmpty else { return prefix }

        if trailingContainsBlockStructure(trailing) {
            return "\(prefix)\n\n\(trailing)"
        }
        return "\(prefix) \(trailing)"
    }

    private static func trailingContainsBlockStructure(_ text: String) -> Bool {
        text.contains("\n") || text.matchesPattern(#"(?m)^\s*(?:[-*]|•)\s+\S"#)
    }

    private static func emailBodyBlocks(from text: String) -> [EmailDraftDocument.BodyBlock] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: #"\n\s*\n+"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        let blocks = normalized
            .components(separatedBy: "\n\n")
            .flatMap(emailBodyBlocks(fromChunk:))

        if blocks.count == 1,
           case .paragraph(let paragraph) = blocks[0],
           let splitParagraphs = splitSingleEmailParagraph(paragraph) {
            return splitParagraphs.map { .paragraph($0) }
        }

        return blocks
    }

    private static func emailBodyBlocks(fromChunk chunk: String) -> [EmailDraftDocument.BodyBlock] {
        let lines = chunk
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard lines.contains(where: { markdownBulletItem(from: $0) != nil }) else {
            let paragraph = normalizedEmailParagraph(chunk)
            guard !paragraph.isEmpty else { return [] }
            if let splitParagraphs = splitSingleEmailParagraph(paragraph) {
                return splitParagraphs.map { .paragraph($0) }
            }
            return [.paragraph(paragraph)]
        }

        var blocks: [EmailDraftDocument.BodyBlock] = []
        var paragraphLines: [String] = []
        var bulletItems: [String] = []

        func flushParagraph() {
            let paragraph = normalizedEmailParagraph(paragraphLines.joined(separator: " "))
            paragraphLines.removeAll()
            guard !paragraph.isEmpty else { return }
            if let splitParagraphs = splitSingleEmailParagraph(paragraph) {
                blocks.append(contentsOf: splitParagraphs.map { .paragraph($0) })
            } else {
                blocks.append(.paragraph(paragraph))
            }
        }

        func flushBullets() {
            let normalizedItems = bulletItems
                .map(normalizedEmailBulletItem(_:))
                .filter { !$0.isEmpty }
            bulletItems.removeAll()
            guard !normalizedItems.isEmpty else { return }
            blocks.append(.bulletList(normalizedItems))
        }

        for line in lines {
            if let bulletItem = markdownBulletItem(from: line) {
                flushParagraph()
                bulletItems.append(bulletItem)
            } else {
                flushBullets()
                paragraphLines.append(line)
            }
        }

        flushParagraph()
        flushBullets()

        return blocks
    }

    private static func markdownBulletItem(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["- ", "* ", "• "] {
            guard trimmed.hasPrefix(prefix) else { continue }
            let item = String(trimmed.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return item.isEmpty ? nil : item
        }
        return nil
    }

    private static func normalizedEmailBulletItem(_ text: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !collapsed.isEmpty else { return "" }
        return TextFormatter.finalize(
            collapsed,
            bulletPointsEnabled: false,
            ensureTrailingPunctuation: false
        )
    }

    private static func localSignoff(
        from text: String,
        fallbackSenderName: String?,
        existingFieldContent: String?
    ) -> String {
        let normalized = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "" }

        let existingClosing = existingFieldContent.flatMap(extractTrailingClosing)
        let dictatedClosing = extractExplicitSignoff(from: normalized, fallbackSenderName: fallbackSenderName)

        if let dictatedClosing {
            if let existingClosing, existingClosing.name != nil {
                return ""
            }

            let resolvedName = dictatedClosing.name ?? fallbackSenderName?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let existingClosing, existingClosing.name == nil {
                return resolvedName ?? ""
            }

            return renderClosing(phrase: dictatedClosing.phrase, name: resolvedName)
        }

        if let fallbackSenderName = fallbackSenderName?.trimmingCharacters(in: .whitespacesAndNewlines),
           normalized.compare(fallbackSenderName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            if let existingClosing, existingClosing.name != nil {
                return ""
            }
            return fallbackSenderName
        }

        return normalized
    }

    private static func extractTrailingClosing(from text: String) -> ClosingComponents? {
        let pattern = #"(?is)(?:\n\s*\n|\A)\s*((?:"# + allClosingPhrases + #")),?(?:\s*\n\s*([^\n]{1,60}))?\s*$"#
        guard let match = firstMatch(of: pattern, in: text) else { return nil }
        let phrase = canonicalClosingPhrase(match.capture(in: text, at: 1))
        let name = sanitizedSenderName(match.capture(in: text, at: 2))
        return ClosingComponents(phrase: phrase, name: name)
    }

    private static func trailingClosingRange(in text: String) -> NSRange? {
        firstMatch(of: trailingClosingPattern, in: text)?.range
    }

    private static func extractInlineClosing(from text: String, fallbackSenderName: String?) -> ClosingComponents? {
        // Loose phrases allow optional comma. Strict phrases (single-word
        // adverbs/pronouns that overlap with body language) require the comma
        // to disambiguate from "I love Sarah." / "this is best." style body.
        let pattern = #"(?is)\b(?:("# + looseClosingPhrases + #"),?|("# + strictClosingPhrases + #"),)\s+(?:to\s+)?("# + inlineClosingNamePattern + #")[.!?]?\s*$"#
        guard let match = firstMatch(of: pattern, in: text) else {
            let phraseOnlyPattern = #"(?is)\b(?:("# + looseClosingPhrases + #"),?|("# + strictClosingPhrases + #"),)\s*$"#
            if let phraseMatch = firstMatch(of: phraseOnlyPattern, in: text) {
                let rawPhrase = phraseMatch.capture(in: text, at: 1) ?? phraseMatch.capture(in: text, at: 2)
                return ClosingComponents(
                    phrase: canonicalClosingPhrase(rawPhrase),
                    name: nil
                )
            }
            return nil
        }

        let rawPhrase = match.capture(in: text, at: 1) ?? match.capture(in: text, at: 2)
        let phrase = canonicalClosingPhrase(rawPhrase)
        let candidateName = sanitizedSenderName(match.capture(in: text, at: 3))
        guard let phrase else { return nil }

        if let candidateName,
           isLikelySenderName(candidateName, fallbackSenderName: fallbackSenderName) {
            return ClosingComponents(phrase: phrase, name: normalizedSenderName(candidateName, fallbackSenderName: fallbackSenderName))
        }

        if let fallbackSenderName,
           let candidateName,
           candidateName.compare(fallbackSenderName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            return ClosingComponents(phrase: phrase, name: fallbackSenderName)
        }

        return nil
    }

    // Detects an inline closing+name pattern followed by additional body text,
    // e.g. "...go for 230 ET. Best regards, Alex. That way I can start filming."
    // Captures the prefix body, the closing components, and the trailing body so
    // the caller can splice the trailing thought back into the body before the
    // closing. Skips P.S. tails since those traditionally sit after the closing.
    //
    // To avoid false positives in body prose, the match requires:
    //   - a sentence boundary (start-of-text or `.!?`) immediately before the
    //     closing phrase, so "Send my best regards, Sarah. ..." cannot match
    //   - the candidate name to equal the user's known sender name, so
    //     intermediate references like "Thanks again, Bob. ..." are skipped
    //     in favor of the actual sign-off ("Best regards, Alex. ...") later
    //     in the same text
    private static func extractInlineClosingFollowedByBody(
        from text: String,
        fallbackSenderName: String?
    ) -> (closing: ClosingComponents, prefix: String, trailing: String)? {
        guard let resolvedSenderName = fallbackSenderName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !resolvedSenderName.isEmpty
        else {
            return nil
        }

        let phrases = midTextLooseClosingPhrases + "|" + strictClosingPhrases
        // Scan all sentence-boundary candidates and keep the LAST one whose
        // name matches the known sender. A single greedy `firstMatch` can still
        // lock onto a later body sentence like "Best regards, Bob." and then
        // discard the real earlier sender-matching closing.
        let pattern = #"(?is)(?:\A|(?<=[.!?]))\s*\b("# + phrases + #"),\s+("# + inlineClosingNamePattern + #")[.!?]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        var bestMatch: (closing: ClosingComponents, prefix: String, trailing: String)?

        regex.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
            guard let match,
                  let phrase = canonicalClosingPhrase(match.capture(in: text, at: 1)),
                  let candidateName = sanitizedSenderName(match.capture(in: text, at: 2))
            else {
                return
            }

            guard candidateName.compare(
                resolvedSenderName,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) == .orderedSame else {
                return
            }

            let trailingRange = NSRange(
                location: NSMaxRange(match.range),
                length: nsText.length - NSMaxRange(match.range)
            )
            let trailing = nsText.substring(with: trailingRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trailing.isEmpty else { return }

            // P.S. / PPS belong below the closing by convention, so leave them alone.
            if trailing.range(
                of: #"^p\.?\s*p?\.?\s*s\.?[\s.:,]"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil {
                return
            }

            let prefix = nsText.substring(to: match.range.location)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            bestMatch = (
                closing: ClosingComponents(phrase: phrase, name: resolvedSenderName),
                prefix: prefix,
                trailing: trailing
            )
        }

        return bestMatch
    }

    private static func extractExplicitSignoff(from text: String, fallbackSenderName: String?) -> ClosingComponents? {
        let pattern = #"(?is)^((?:"# + allClosingPhrases + #")),?(?:\s+([^\n]{1,60}))?$"#
        guard let match = firstMatch(of: pattern, in: text),
              let phrase = canonicalClosingPhrase(match.capture(in: text, at: 1))
        else {
            return nil
        }

        let candidateName = sanitizedSenderName(match.capture(in: text, at: 2))
        return ClosingComponents(
            phrase: phrase,
            name: normalizedSenderName(candidateName, fallbackSenderName: fallbackSenderName)
        )
    }

    private static func replacingTrailingClosing(in text: String, with closingBlock: String) -> String {
        guard let range = trailingClosingRange(in: text) else { return text }
        let nsText = text as NSString
        let body = nsText.replacingCharacters(in: range, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty {
            return closingBlock
        }
        return "\(body)\n\n\(closingBlock)"
    }

    private static func closingBodyWithoutTrailingSeparator(
        from text: String,
        closingPhrase: String?,
        name: String?
    ) -> String {
        guard let closingPhrase else { return text }

        let escapedPhrase = NSRegularExpression.escapedPattern(for: closingPhrase)
        let escapedName = name.map(NSRegularExpression.escapedPattern(for:)) ?? #"[^\n]{1,60}"#
        let pattern = #"(?is)\s*\b\#(escapedPhrase),?(?:\s+(?:to\s+)?\#(escapedName))?[.!?]?\s*$"#
        return text.replacingOccurrences(
            of: pattern,
            with: "",
            options: [.regularExpression]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractingLeadingGreeting(from body: inout String) -> String? {
        let words = primaryGreetingWords

        // 1. Greeting + name + terminator
        let greetingWithName = #"(?is)^\s*("# + words + #")(?:,\s+|\s+)([^\n,]{1,80}?)[,.](?:\s*\n\s*|\s+)"#
        if let match = firstMatch(of: greetingWithName, in: body) {
            let salutation = match.capture(in: body, at: 1)
            let name = match.capture(in: body, at: 2)
            let nsBody = body as NSString
            body = nsBody.replacingCharacters(in: match.range, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return formatGreeting(salutation: salutation, name: name)
        }

        // 2. Greeting alone + terminator (no name)
        let greetingAlone = #"(?is)^\s*("# + words + #")[,.](?:\s*\n\s*|\s+)"#
        if let match = firstMatch(of: greetingAlone, in: body) {
            let salutation = match.capture(in: body, at: 1)
            let nsBody = body as NSString
            body = nsBody.replacingCharacters(in: match.range, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return formatGreeting(salutation: salutation, name: nil)
        }

        // 3. Relaxed terminator: greeting + Title-case name + sentence boundary
        let relaxedGreeting = #"(?is)^\s*("# + words + #")\s+([\p{Lu}][\p{L}'-]{1,30}(?:\s+[\p{Lu}][\p{L}'-]{1,30}){0,2})\s+(?=[\p{Ll}]|I\b)"#
        if let match = firstMatch(of: relaxedGreeting, in: body) {
            let salutation = match.capture(in: body, at: 1)
            let name = match.capture(in: body, at: 2)
            let nsBody = body as NSString
            body = nsBody.replacingCharacters(in: match.range, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return formatGreeting(salutation: salutation, name: name)
        }

        // 4. Recipient-only "John,"
        if let match = firstMatch(of: recipientGreetingPattern, in: body) {
            let rawName = match.capture(in: body, at: 1)
            let nsBody = body as NSString
            body = nsBody.replacingCharacters(in: match.range, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return renderRecipientGreeting(rawName)
        }

        return nil
    }

    private static func formatGreeting(salutation: String?, name: String?) -> String? {
        guard let salutation = salutation?.trimmingCharacters(in: .whitespacesAndNewlines),
              !salutation.isEmpty else {
            return nil
        }

        let canonicalSalutation = canonicalGreetingSalutation(salutation)
        let trimmedName = name?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"[,:;.!?]+$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let trimmedName, !trimmedName.isEmpty {
            return "\(canonicalSalutation) \(trimmedName),"
        }
        return "\(canonicalSalutation),"
    }

    private static func renderRecipientGreeting(_ name: String?) -> String? {
        guard let cleaned = name?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"[,:;.!?]+$"#, with: "", options: .regularExpression),
            !cleaned.isEmpty else {
            return nil
        }
        return "\(cleaned),"
    }

    private static func normalizedEmailParagraph(_ text: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: #"\s*\n\s*"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !collapsed.isEmpty else { return "" }
        return TextFormatter.finalize(
            collapsed,
            bulletPointsEnabled: false,
            ensureTrailingPunctuation: false
        )
    }

    private static func splitSingleEmailParagraph(_ paragraph: String) -> [String]? {
        let sentences = sentenceSegments(in: paragraph)
        guard sentences.count >= 2 else { return nil }

        guard let splitIndex = paragraphBreakIndex(for: sentences) else {
            return nil
        }

        let first = sentences[..<splitIndex].joined(separator: " ")
        let second = sentences[splitIndex...].joined(separator: " ")
        let paragraphs = [first, second]
            .map(normalizedEmailParagraph(_:))
            .filter { !$0.isEmpty }

        return paragraphs.count >= 2 ? paragraphs : nil
    }

    private static func sentenceSegments(in text: String) -> [String] {
        var segments: [String] = []
        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.bySentences, .substringNotRequired]
        ) { _, range, _, _ in
            let sentence = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                segments.append(sentence)
            }
        }

        if segments.isEmpty {
            return [text]
        }

        return segments
    }

    private static func paragraphBreakIndex(for sentences: [String]) -> Int? {
        guard sentences.count >= 2 else { return nil }

        let prefixWordCount = sentences.dropLast()
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .count
        guard prefixWordCount >= 5 else { return nil }

        let lastSentence = sentences[sentences.count - 1]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard lastSentence.range(
            of: #"^(?:please\b|let me know\b|feel free\b|happy to\b|i(?:'d| would)? be happy\b|looking forward\b|can you\b|could you\b)"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil else {
            return nil
        }

        return sentences.count - 1
    }

    private static func canonicalGreetingSalutation(_ salutation: String) -> String {
        let normalized = salutation
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .lowercased()
        switch normalized {
        case "hi": return "Hi"
        case "hello": return "Hello"
        case "hey": return "Hey"
        case "dear": return "Dear"
        case "howdy": return "Howdy"
        case "yo": return "Yo"
        case "greetings": return "Greetings"
        case "aloha": return "Aloha"
        case "hola": return "Hola"
        case "bonjour": return "Bonjour"
        case "namaste": return "Namaste"
        case "shalom": return "Shalom"
        case "sup": return "Sup"
        case "good morning": return "Good morning"
        case "good afternoon": return "Good afternoon"
        case "good evening": return "Good evening"
        case "good day": return "Good day"
        default:
            let trimmed = salutation.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let first = trimmed.first else { return trimmed }
            return first.uppercased() + trimmed.dropFirst()
        }
    }

    private static func renderClosing(phrase: String?, name: String?) -> String {
        guard let phrase else { return name ?? "" }
        let normalizedPhrase = canonicalClosingPhrase(phrase) ?? phrase
        if let name = sanitizedSenderName(name), !name.isEmpty {
            return "\(normalizedPhrase),\n\(name)"
        }
        return "\(normalizedPhrase),"
    }

    private static func canonicalClosingPhrase(_ phrase: String?) -> String? {
        guard let normalized = phrase?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !normalized.isEmpty else {
            return nil
        }

        switch normalized {
        case "best regards":
            return "Best regards"
        case "kind regards":
            return "Kind regards"
        case "best wishes":
            return "Best wishes"
        case "all the best":
            return "All the best"
        case "all my best":
            return "All my best"
        case "many thanks":
            return "Many thanks"
        case "thanks again":
            return "Thanks again"
        case "yours truly":
            return "Yours truly"
        case "yours sincerely":
            return "Yours sincerely"
        case "thank you":
            return "Thank you"
        case "take care":
            return "Take care"
        case "talk soon":
            return "Talk soon"
        case "speak soon":
            return "Speak soon"
        case "appreciate it":
            return "Appreciate it"
        case "regards":
            return "Regards"
        case "sincerely":
            return "Sincerely"
        case "thanks":
            return "Thanks"
        case "cheers":
            return "Cheers"
        case "with love":
            return "With love"
        case "lots of love":
            return "Lots of love"
        case "until next time":
            return "Until next time"
        case "until soon":
            return "Until soon"
        case "catch you later":
            return "Catch you later"
        case "bye for now":
            return "Bye for now"
        case "aloha":
            return "Aloha"
        case "love":
            return "Love"
        case "best":
            return "Best"
        case "yours":
            return "Yours"
        case "warmly":
            return "Warmly"
        case "hugs":
            return "Hugs"
        case "ciao":
            return "Ciao"
        case "peace":
            return "Peace"
        case "bye":
            return "Bye"
        case "goodbye":
            return "Goodbye"
        case "xoxo":
            return "XOXO"
        case "xo":
            return "XO"
        default:
            return phrase?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func normalizedSenderName(_ name: String?, fallbackSenderName: String?) -> String? {
        if let name = sanitizedSenderName(name) {
            return name
        }
        return fallbackSenderName?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sanitizedSenderName(_ name: String?) -> String? {
        guard let normalized = name?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"[.!?]+$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !normalized.isEmpty else {
            return nil
        }

        return normalized
    }

    private static func isLikelySenderName(_ name: String, fallbackSenderName: String?) -> Bool {
        if let fallbackSenderName,
           name.compare(fallbackSenderName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            return true
        }

        let tokens = name.split(whereSeparator: \.isWhitespace)
        guard !tokens.isEmpty, tokens.count <= 3 else { return false }

        return tokens.allSatisfy { token in
            token.range(of: #"^[A-Z][\p{L}'-]*$"#, options: .regularExpression) != nil
        }
    }

    private static func firstMatch(of pattern: String, in text: String) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        return regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }
}

private extension String {
    func matchesPattern(_ pattern: String) -> Bool {
        range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

private extension NSTextCheckingResult {
    func capture(in text: String, at index: Int) -> String? {
        guard numberOfRanges > index else { return nil }
        let range = range(at: index)
        guard range.location != NSNotFound else { return nil }
        return (text as NSString).substring(with: range)
    }
}
