import Foundation

enum CloudProcessingSupport {
    private static let selfCorrectionCleanupInstruction = """
        Self-corrections: when the speaker abandons and replaces wording using cues like "no wait", "I mean", "I meant", "sorry", "actually", "scratch that", "strike that", "scrap that", or "never mind", you MUST delete BOTH the abandoned wording AND the correction cue itself. Keep only the final intended wording. Never preserve "no", "wait", "I mean", "sorry", "actually", or the abandoned phrase as literal content. Worked examples:
        - "meet at three no wait I mean four" → "Meet at 4."
        - "send it to John sorry I meant Sarah" → "Send it to Sarah."
        - "the deadline is Tuesday actually no Wednesday" → "The deadline is Wednesday."
        - "call Priya at noon scratch that call her at one" → "Call Priya at 1."
        - "update the readme actually scrap that update the changelog instead" → "Update the changelog."
        Repeated restarts: when the speaker starts a clause, says an abandoned word or phrase, then restarts the same clause with the intended wording, keep only the final restarted clause. Worked examples:
        - "we get a new recent mem we get a new recent session" → "We get a new recent session."
        - "add it to the left panel memo add it to the left panel session" → "Add it to the left panel session."
        False-start lead-ins: when the speaker begins with non-content scaffolding and then lands on a clear final clause, remove the abandoned setup and keep the final clause. Worked examples:
        - "and then we actually know for that we should ship the cleanup fix" → "We should ship the cleanup fix."
        - "like what I was trying to say is we should keep the final clause" → "We should keep the final clause."
        """

    private static let outputOnlyCleanupInstruction =
        "Output the cleaned text verbatim — nothing else. Do not describe, narrate, or compare the transformation. Never emit phrases like \"becomes\", \"changed to\", \"rewritten as\", \"X becomes Y\", \"No changes needed\", or any before/after explanation. If the input already needs no changes, return it unchanged."

    private static let conservativeListFormattingInstruction = """
        List formatting: use markdown bullets only when the dictated text clearly contains 3 or more distinct items, steps, options, requirements, reasons, todos, or action items, or when it is a pricing/package breakdown with 2 or more distinct line items or included/excluded terms. Prefer bullets for explicit list requests, clear list introductions such as "three things", "steps are", "action items", "options are", or "requirements are", and quote-like pricing summaries. Do NOT use bullets for ordinary prose with several nouns or clauses, for only 1-2 non-pricing items, for contrastive prose such as "I like the first line but not the second", or when bullets would make the message more formal than dictated.
        """

    private static let explicitListFormattingInstruction = """
        List formatting: the speaker appears to be asking for a list. If the content contains distinct items, return them as markdown bullets using "- ". Keep the original meaning and do not invent items. If there are fewer than 2 meaningful items, keep normal prose.
        """

    private static let likelyListFormattingInstruction = """
        List formatting: the dictation appears list-shaped. Use markdown bullets if there are 3 or more distinct, independently meaningful items, or if it is a pricing/package breakdown with 2 or more distinct line items or included/excluded terms. If the items are not clearly separable, keep normal prose.
        """

    private static let conversationalListFormattingInstruction = """
        List formatting: preserve normal message prose. Use markdown bullets only if the speaker explicitly asked for bullets, a list, todos, action items, steps, options, or pros and cons.
        """

    static let emailFullCleanupInstruction = [
        "Clean this dictated outbound email only.",
        "Fix all STT errors including dropped words (missing articles like 'a', 'the'), misheard words, run-on sentences missing end punctuation, fillers, spacing, and casing.",
        selfCorrectionCleanupInstruction,
        "Preserve the sender's meaning, tone, and all concrete content words.",
        "Do not guess ambiguous names, brands, products, services, or companies. If unsure, keep the closest literal transcript instead of inventing a correction.",
        "Preserve person names exactly unless the correction is obvious from the transcript itself.",
        "Keep it as the sender's outbound email body.",
        "Do not answer it.",
        "Do not add subject lines, greetings, sign-offs, sender names, templates, placeholders, or new facts unless they were already dictated.",
        "The sender's name at the end should have no trailing punctuation.",
        outputOnlyCleanupInstruction,
        "",
        "IMPORTANT — Email formatting (you MUST use newline characters):",
        "- You may only keep or block-format a greeting if the greeting was already dictated.",
        "- You may only keep or block-format a closing if the closing was already dictated.",
        "- Greeting on its own line, followed by a comma: \"Hi Priya,\"",
        "- One blank line before the body.",
        "- Paragraph break (blank line) between distinct thoughts.",
        "- One blank line before the closing (e.g. \"Kind regards,\").",
        "- Closing name on the line after the closing phrase.",
        "Return only the cleaned email body with these line breaks.",
    ].joined(separator: "\n")

    static let emailFragmentCleanupInstruction = [
        "Clean this dictated email fragment only.",
        "Fix STT errors, punctuation, spacing, casing, and obvious misspellings while preserving the sender's literal wording.",
        selfCorrectionCleanupInstruction,
        "Do not answer it.",
        "Do not add or rewrite greetings, sign-offs, sender names, recipient names, templates, placeholders, or new facts.",
        "Return only the cleaned fragment.",
        outputOnlyCleanupInstruction
    ].joined(separator: " ")

    static let messageCleanupInstruction = [
        "Clean this dictated outbound message only.",
        "Fix STT errors, fillers, punctuation, spacing, and casing while preserving meaning, speaker perspective, and concrete content words.",
        selfCorrectionCleanupInstruction,
        "Do not answer it.",
        "Do not add greetings, sign-offs, subject lines, templates, or new facts.",
        "Return only the cleaned message.",
        outputOnlyCleanupInstruction
    ].joined(separator: " ")

    static let defaultCleanupInstruction = [
        "Fix only grammar, spelling, punctuation, and obvious speech-to-text errors.",
        "Keep the original wording, tone, and sentence structure as-is.",
        "Do not rewrite, rephrase, or improve the text beyond correcting mistakes.",
        selfCorrectionCleanupInstruction,
        "Do not answer it.",
        "Return only the corrected text.",
        outputOnlyCleanupInstruction
    ].joined(separator: " ")

    /// Polished-tier replacement for `defaultCleanupInstruction` — grants
    /// rephrasing latitude while pinning meaning, tone, and concrete facts.
    static let polishedDefaultCleanupInstruction = [
        "Clean up this dictated text so it reads the way the speaker would have written it.",
        "Fix all STT errors, fillers, punctuation, spacing, and casing.",
        "You may tighten wording, split run-on sentences, and smooth awkward phrasing, but preserve the speaker's meaning, tone, perspective, and every concrete fact, name, number, and identifier.",
        "Do not add new facts, opinions, or content that was not dictated, and do not drop dictated details.",
        selfCorrectionCleanupInstruction,
        "Do not answer it.",
        "Return only the cleaned text.",
        outputOnlyCleanupInstruction
    ].joined(separator: " ")

    /// Appended to the message/email profiles at the polished tier. Phrased as
    /// added latitude so it composes with the base profile's guardrails.
    static let polishedRewriteAddendum = "Polish: you may also tighten wording, split run-on sentences, and smooth awkward phrasing so the result reads the way the sender would have typed it, as long as the meaning, tone, and every concrete fact, name, number, and identifier are preserved. Do not add content that was not dictated."

    private static let shortInputTokenMax = 8
    private static let shortCloudCleanupBypassTokenMax = 4
    private static let maxSelectionTransformCommandCharacters = 1_200
    private static let advancedSelectionTransformCommandCharacters = 160
    private static let advancedSelectionTransformTokenCount = 26
    private static let advancedSelectionTransformSelectedCharacters = 2_500
    private static let minShortCoverage = 0.67
    private static let minContentCoverage = 0.3
    private static let maxContentNovelRatio = 0.55
    private static let badPrefixes = [
        "sure", "here's", "here is", "let me", "i can", "i cannot", "i can't",
        "as an ai", "based on", "the answer", "in summary", "certainly", "absolutely", "of course",
        "that's", "that is", "it is", "it's",
        "i'd", "i would", "i suggest", "i recommend", "i think", "i believe",
        "you should", "you can", "you need", "you could", "you would", "you might",
        "to answer", "in response", "regarding your", "great question",
        "unfortunately", "thank you", "thanks for", "good question", "that depends", "it depends",
        "got it", "gotcha", "sounds good", "makes sense", "will do", "on it", "noted"
    ]
    private static let labelPrefixes = [
        "output:", "rewritten text:", "corrected text:", "answer:", "cleaned message:",
        "cleaned text:", "edited text:", "edited message:", "revised text:", "final text:",
        "final version:", "corrected to:", "transformed text:", "transformed selection:",
        "rewritten selection:", "restructured message:", "restructured text:"
    ]
    private static let explicitListRegexes: [NSRegularExpression] = [
        try! NSRegularExpression(
            pattern: #"\b(?:turn|make|format|reformat|convert|put)\s+(?:this|it|that|the text|the selection)?\s*(?:into|as|like|to)\s+(?:a\s+)?(?:bullet(?:ed)?\s+)?list\b"#,
            options: [.caseInsensitive]
        ),
        try! NSRegularExpression(
            pattern: #"\b(?:turn|make|format|reformat|convert|put)\s+(?:this|it|that|the text|the selection)?\s*(?:into|as|like|to)\s+bullets\b"#,
            options: [.caseInsensitive]
        ),
        try! NSRegularExpression(
            pattern: #"\b(?:bullet(?:ed)?\s+list|list\s+out|make\s+a\s+list|as\s+bullets|in\s+bullets|bullets\s+for)\b"#,
            options: [.caseInsensitive]
        ),
        try! NSRegularExpression(
            pattern: #"\b(?:action\s+items?|next\s+steps?|todo(?:s)?|to-do(?:s)?|pros\s+and\s+cons|requirements?|options?)\s+(?:are|is|include)\b"#,
            options: [.caseInsensitive]
        ),
        try! NSRegularExpression(
            pattern: #"(?:^|[.!?:]\s+)(?:(?:here\s+(?:are|is)|these\s+are)\s+(?:the\s+)?|the\s+)?(?:action\s+items?|next\s+steps?|todo(?:s)?|to-do(?:s)?|pros\s+and\s+cons|requirements?|options?)\s*:"#,
            options: [.caseInsensitive]
        ),
    ]
    private static let likelyListIntroRegexes: [NSRegularExpression] = [
        try! NSRegularExpression(
            pattern: #"\b(?:two|three|four|five|six|seven|eight|nine|ten|\d+)\s+(?:things|items|steps|reasons|options|requirements|todos|to-dos|action\s+items)\b"#,
            options: [.caseInsensitive]
        ),
        try! NSRegularExpression(
            pattern: #"\b(?:the\s+)?(?:main\s+)?(?:steps|options|requirements|reasons|items|things|todos|to-dos)\s+(?:are|include)\b"#,
            options: [.caseInsensitive]
        ),
        try! NSRegularExpression(
            pattern: #"\b(?:we|i)\s+need\s+to\s+[^.!?;]+(?:,\s*[^.!?;]+){2,}"#,
            options: [.caseInsensitive]
        ),
    ]
    private static let pricingBreakdownTermRegex = try! NSRegularExpression(
        pattern: #"\b(?:video|videos|package|packages|rate|rates|price|pricing|quote|cost|costs|include|includes|included|exclude|excludes|excluded|whitelisting|automation)\b"#,
        options: [.caseInsensitive]
    )
    private static let numericValueRegex = try! NSRegularExpression(
        pattern: #"(?:[$€£]\s*)?\b\d[\d,]*(?:\.\d+)?\b|\b(?:one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)\b"#,
        options: [.caseInsensitive]
    )
    private static let ordinalListMarkerRegex = try! NSRegularExpression(
        pattern: #"\b(first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|1st|2nd|3rd|\d+th)\b"#,
        options: [.caseInsensitive]
    )
    private static let markdownBulletLineRegex = try! NSRegularExpression(
        pattern: #"(?m)^[ \t]{0,3}[-*+][ \t]+\S"#,
        options: []
    )

    enum CleanupPromptProfile: Equatable {
        case `default`
        case message
        case emailFull
        case emailFragment
    }

    enum ListIntent: String, Equatable {
        case none
        case likely
        case explicit
    }

    enum EmailDictationMode: String, Equatable {
        case nonEmail
        case fullEmail
        case fragment
        case signoffOnly
    }

    /// Longest pause-annotated transcript worth embedding in the cleanup
    /// instruction. Beyond this the extra tokens cost latency and small
    /// models stop tracking the cross-reference.
    private static let maxPauseAnnotationCharacters = 3_000

    static func cleanupInstruction(
        for profile: CleanupPromptProfile,
        listIntent: ListIntent = .none,
        pauseAnnotatedTranscript: String? = nil,
        editExemplars: [DictationEditExemplar] = [],
        polishLevel: DictationPolishLevel = .clean
    ) -> String {
        let base: String
        switch profile {
        case .default:
            base = polishLevel == .polished
                ? polishedDefaultCleanupInstruction
                : defaultCleanupInstruction
        case .message:
            base = messageCleanupInstruction
        case .emailFull:
            base = emailFullCleanupInstruction
        case .emailFragment:
            base = emailFragmentCleanupInstruction
        }
        let polishAddendum = polishLevel == .polished && profile != .default
            ? polishedRewriteAddendum
            : ""

        return [
            base,
            polishAddendum,
            listFormattingInstruction(profile: profile, listIntent: listIntent),
            editExemplarInstruction(exemplars: editExemplars, profile: profile),
            pauseReferenceInstruction(pauseAnnotatedTranscript: pauseAnnotatedTranscript),
        ]
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }

    /// Few-shot pasted→edited pairs so the model can imitate how this user
    /// rewrites our output. Email profiles skip them for the same reason they
    /// skip recent texts: examples bias small models toward inventing message
    /// content that was never dictated.
    static func editExemplarInstruction(
        exemplars: [DictationEditExemplar],
        profile: CleanupPromptProfile
    ) -> String {
        guard profile == .default || profile == .message else { return "" }
        let usable = DictationEditExemplarSanitizer.sanitizedCandidates(exemplars)
        guard !usable.isEmpty else { return "" }

        func escapedPromptLiteral(_ value: String) -> String {
            value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
        }

        let pairs = usable
            .map {
                "- Draft: \"\(escapedPromptLiteral($0.original))\" → User's version: \"\(escapedPromptLiteral($0.edited))\""
            }
            .joined(separator: "\n")
        return """
            Personal style examples: below are recent examples of how this user edited earlier cleaned dictations on this kind of surface. Use them ONLY to match the user's preferred casing, punctuation, formatting, and phrasing tightness. Never copy words, names, topics, or facts from the examples into the output — they come from unrelated messages.
            \(pairs)
            """
    }

    /// Embeds the pause-annotated raw transcript as auxiliary evidence for
    /// disfluency decisions. The annotated text is the pre-cleanup decode —
    /// the model must keep cleaning the main transcript, so the framing is
    /// strictly "reference, never output".
    static func pauseReferenceInstruction(pauseAnnotatedTranscript: String?) -> String {
        guard let annotated = pauseAnnotatedTranscript?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !annotated.isEmpty,
            annotated.contains(PauseSegmenter.pauseMarker),
            annotated.count <= maxPauseAnnotationCharacters
        else { return "" }

        return """
            Pause reference: below is the raw decode of the same dictation with real speech pauses marked as \(PauseSegmenter.pauseMarker). Use it ONLY as evidence for the self-correction, restart, and false-start rules above: wording right after a pause that rephrases, contradicts, or restarts the wording before the pause is a self-correction — keep only the final wording. A pause by itself is never a reason to delete or reorder anything. The pause reference is unpunctuated raw output — do not clean it, quote it, or copy from it; clean only the main transcript, and never emit the marker \(PauseSegmenter.pauseMarker).
            Pause reference:
            \(annotated)
            """
    }

    static func qualityRepairInstruction(
        for profile: CleanupPromptProfile,
        issues: [String],
        listIntent: ListIntent = .none
    ) -> String {
        let issueList = issues.isEmpty ? "general_quality" : issues.joined(separator: ", ")
        var instructions: [String] = [
            "Repair this already-cleaned dictation output for a paid quality pass.",
            "Fix ONLY the listed quality issues: \(issueList).",
            "Preserve the sender's meaning, tone, concrete content, names, brands, URLs, identifiers, and numbers unless a listed issue explicitly requires a local formatting correction.",
            "Do not add new facts, answers, greetings, sign-offs, subject lines, templates, placeholders, or explanations.",
            outputOnlyCleanupInstruction,
        ]

        if issues.contains("numeric_idiom") {
            instructions.append("Numeric idioms: write natural idioms with words, e.g. \"1 last time\" -> \"one last time\" and \"1 more thing\" -> \"one more thing\". Do not change dates, times, money, measurements, counts, or identifiers.")
        }

        if issues.contains("malformed_email_closing") || issues.contains("unformatted_email_envelope") || profile == .emailFull {
            instructions.append("""
                Email formatting: if a greeting or closing is already present, format it as an email body with blank lines. A sign-off misheard as "Best regards to Alex" means "Best regards,\nAlex" only when the name is already present. Do not invent a greeting, sign-off, sender name, or recipient name.
                """)
        }

        if issues.contains("long_unstructured_text") {
            instructions.append("""
                Long-form structure: add paragraph breaks for distinct thoughts. Use markdown bullets only for clear lists, action items, requirements, options, or steps. Do not invent headings unless the dictated text clearly names the section.
                """)
        }

        instructions.append(listFormattingInstruction(profile: profile, listIntent: listIntent))
        return instructions
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
    }

    static func listIntent(
        transcript: String,
        profile: CleanupPromptProfile
    ) -> ListIntent {
        let normalized = transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard !normalized.isEmpty else { return .none }

        if explicitlyRequestsList(normalized) {
            return .explicit
        }

        // Keep conversational surfaces conservative unless the user explicitly
        // asks for list formatting. A prose-looking Slack/email message should
        // not turn formal just because it mentions several things.
        if profile == .message || profile == .emailFull || profile == .emailFragment {
            return .none
        }

        if likelyListShaped(normalized) {
            return .likely
        }

        return .none
    }

    static func shouldBypassCloudCleanupForShortDictation(
        transcript: String,
        profile: CleanupPromptProfile
    ) -> Bool {
        let normalized = transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard !normalized.isEmpty else { return false }

        let tokens = normalizeTokens(normalized)
        guard !tokens.isEmpty,
              tokens.count <= shortCloudCleanupBypassTokenMax
        else {
            return false
        }

        if hasSelfCorrectionCue(normalized) {
            return false
        }

        if listIntent(transcript: normalized, profile: profile) != .none {
            return false
        }

        return true
    }

    private static func listFormattingInstruction(
        profile: CleanupPromptProfile,
        listIntent: ListIntent
    ) -> String {
        switch profile {
        case .message, .emailFull, .emailFragment:
            return listIntent == .explicit
                ? explicitListFormattingInstruction
                : conversationalListFormattingInstruction
        case .default:
            switch listIntent {
            case .explicit:
                return explicitListFormattingInstruction
            case .likely:
                return likelyListFormattingInstruction
            case .none:
                return conservativeListFormattingInstruction
            }
        }
    }

    private static func explicitlyRequestsList(_ text: String) -> Bool {
        matchesAny(Self.explicitListRegexes, in: text)
    }

    private static func likelyListShaped(_ text: String) -> Bool {
        if matchesAny(Self.likelyListIntroRegexes, in: text) {
            return true
        }

        if pricingBreakdownListShaped(text) {
            return true
        }

        return ordinalListMarkerCount(in: text) >= 3
    }

    private static func pricingBreakdownListShaped(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        guard pricingBreakdownTermRegex.firstMatch(in: text, range: range) != nil else {
            return false
        }

        let numericCount = numericValueRegex.matches(in: text, range: range).count
        let hasIncludedExcludedTerms = text.matches(
            #"\b(?:does\s+not\s+include|doesn't\s+include|not\s+include|include|includes|included|exclude|excludes|excluded)\b"#,
            options: [.caseInsensitive]
        )
        let sentenceLikeBreaks = text.components(separatedBy: CharacterSet(charactersIn: ".;:\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .count

        return numericCount >= 2 && (hasIncludedExcludedTerms || sentenceLikeBreaks >= 2)
    }

    private static func ordinalListMarkerCount(in text: String) -> Int {
        let nsText = text as NSString
        let matches = ordinalListMarkerRegex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        let values = Set(matches.map { nsText.substring(with: $0.range).lowercased() })
        return values.count
    }

    private static func matchesAny(_ regexes: [NSRegularExpression], in text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return regexes.contains { regex in
            regex.firstMatch(in: text, range: range) != nil
        }
    }

    private static func markdownBulletLineCount(in text: String) -> Int {
        let nsText = text as NSString
        return markdownBulletLineRegex.matches(
            in: text,
            range: NSRange(location: 0, length: nsText.length)
        ).count
    }

    static func cleanupPromptProfile(
        appName: String?,
        bundleId: String?,
        windowTitle: String?,
        browserURL: String?,
        emailMode: EmailDictationMode? = nil
    ) -> CleanupPromptProfile {
        if EmailContextSupport.isEmailContext(
            appName: appName,
            bundleId: bundleId,
            windowTitle: windowTitle,
            browserURL: browserURL
        ) {
            switch emailMode ?? .fragment {
            case .fullEmail:
                return .emailFull
            case .nonEmail, .fragment, .signoffOnly:
                return .emailFragment
            }
        }
        if isChatLikeContext(
            appName: appName,
            bundleId: bundleId,
            windowTitle: windowTitle,
            browserURL: browserURL
        ) {
            return .message
        }
        return .default
    }

    static func emailDictationMode(
        transcript: String,
        focusedFieldContent: String?,
        focusedFieldContext: EmailFocusedFieldContext? = nil,
        appName: String?,
        bundleId: String?,
        windowTitle: String?,
        browserURL: String?,
        fallbackSenderName: String?
    ) -> EmailDictationMode {
        guard EmailContextSupport.isEmailContext(
            appName: appName,
            bundleId: bundleId,
            windowTitle: windowTitle,
            browserURL: browserURL
        ) else {
            return .nonEmail
        }

        let normalizedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTranscript.isEmpty else { return .fragment }

        if !EmailContextSupport.isLikelyEmailBodyField(focusedFieldContext) {
            return .fragment
        }

        if isEmailSignoffOnlyTranscript(
            normalizedTranscript,
            fallbackSenderName: fallbackSenderName
        ) {
            return .signoffOnly
        }

        // If the user explicitly dictates an email envelope, preserve it even
        // when AX reports existing compose content such as a signature or quote.
        if looksLikeFullEmailTranscript(normalizedTranscript) {
            return .fullEmail
        }

        if hasExistingEmailDraftContent(focusedFieldContent) {
            return .fragment
        }

        return .fullEmail
    }

    static func normalizeAppKey(
        appName: String?,
        bundleId: String?,
        windowTitle: String?,
        browserURL: String?
    ) -> String {
        if EmailContextSupport.isEmailContext(
            appName: appName,
            bundleId: bundleId,
            windowTitle: windowTitle,
            browserURL: browserURL
        ) {
            return "email"
        }

        let candidates = [appName, bundleId, windowTitle, browserURL]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if candidates.contains(where: {
            $0.matches(#"slack|discord|teams|messages|telegram|whatsapp|imessage"#, options: .caseInsensitive)
        }) {
            return "chat"
        }
        if candidates.contains(where: {
            $0.matches(#"linear|jira|github|notion|asana|clickup|trello|height"#, options: .caseInsensitive)
        }) {
            return "tasks"
        }
        if candidates.contains(where: {
            $0.matches(#"docs|word|pages|overleaf|confluence|quip"#, options: .caseInsensitive)
        }) {
            return "docs"
        }
        if candidates.contains(where: {
            $0.matches(#"xcode|vs\s*code|vscode|cursor|terminal|iterm|warp|zed"#, options: .caseInsensitive)
        }) {
            return "code"
        }
        return "other"
    }

    static func isChatLikeContext(
        appName: String?,
        bundleId: String?,
        windowTitle: String?,
        browserURL: String?
    ) -> Bool {
        let candidates = [appName, bundleId, windowTitle, browserURL]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return candidates.contains(where: {
            $0.matches(#"slack|discord|teams|messages|telegram|whatsapp|imessage"#, options: .caseInsensitive)
        })
    }

    static func buildSelectionTransformTranscript(command: String, selectedText: String) -> String {
        let instruction = command.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"[.!?;:,\s]+$"#, with: "", options: .regularExpression)
        let content = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty, !content.isEmpty else { return "" }
        return "\(instruction):\n\n\(content)"
    }

    static func looksLikeSelectionTransformCommand(_ command: String) -> Bool {
        let normalized = command
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard !normalized.isEmpty,
              normalized.count <= maxSelectionTransformCommandCharacters
        else {
            return false
        }

        if normalized.matches(
            #"^(?:quick|fast|detailed|advanced|careful|high[-\s]?quality)\s+(?:rewrite|edit|transform|change|shorten|summarize|format|reformat|revision|polish)\b"#,
            options: [.caseInsensitive]
        ) {
            return true
        }

        if normalized.matches(
            #"^(?:please\s+)?(?:rewrite|reword|rephrase|reformat|format|edit|polish|proofread|fix|improve|shorten|condense|summarize|expand|elaborate|simplify|clarify|translate|convert|clean\s+up|bullet(?:ize)?|capitalize|lowercase|uppercase|title[\s-]?case)\b"#,
            options: [.caseInsensitive]
        ) {
            return true
        }

        if normalized.matches(
            #"^(?:please\s+)?(?:make|turn|change)\s+(?:this|it|the selection|selected text)\s+(?:more|less|into|to|as)\b"#,
            options: [.caseInsensitive]
        ) {
            return true
        }

        return normalized.matches(
            #"^(?:please\s+)?put\s+(?:this|it|the selection|selected text)\s+(?:into|in)\b"#,
            options: [.caseInsensitive]
        )
    }

    struct SelectionTransformRouting: Equatable {
        enum Route: String {
            case quick
            case advanced
        }

        var route: Route
        var reason: String

        static let quickDefault = SelectionTransformRouting(route: .quick, reason: "default")
    }

    static func selectionTransformRouting(
        command: String,
        selectedText: String
    ) -> SelectionTransformRouting {
        let normalizedCommand = command
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let normalizedSelectedText = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedCommand.isEmpty else { return .quickDefault }

        if normalizedCommand.matches(
            #"^(?:quick|fast)\s+(?:rewrite|edit|transform|change|shorten|summarize|format|reformat)\b"#,
            options: [.caseInsensitive]
        ) {
            return SelectionTransformRouting(route: .quick, reason: "user_forced_quick")
        }

        if normalizedCommand.matches(
            #"^(?:detailed|advanced|careful|high[-\s]?quality)\s+(?:rewrite|edit|transform|change|revision|polish)\b"#,
            options: [.caseInsensitive]
        ) {
            return SelectionTransformRouting(route: .advanced, reason: "user_forced_advanced")
        }

        if normalizedCommand.count > advancedSelectionTransformCommandCharacters {
            return SelectionTransformRouting(route: .advanced, reason: "long_command")
        }

        if normalizeTokens(normalizedCommand).count > advancedSelectionTransformTokenCount {
            return SelectionTransformRouting(route: .advanced, reason: "many_instruction_tokens")
        }

        if normalizedSelectedText.count > advancedSelectionTransformSelectedCharacters {
            return SelectionTransformRouting(route: .advanced, reason: "long_selection")
        }

        if selectionTransformHasDetailedConstraints(normalizedCommand) {
            return SelectionTransformRouting(route: .advanced, reason: "detailed_constraints")
        }

        return .quickDefault
    }

    static func selectionTransformStage(
        command: String,
        route: SelectionTransformRouting.Route = .quick
    ) -> String {
        if route == .advanced {
            return "Applying detailed edit..."
        }

        let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.matches(#"^(?:please\s+)?translate\b"#, options: [.caseInsensitive]) {
            return "Translating selection..."
        }
        if normalized.matches(
            #"^(?:please\s+)?(?:reformat|format|bullet(?:ize)?|capitalize|lowercase|uppercase|title[\s-]?case|put\s+(?:this|it|the selection|selected text)\s+(?:into|in))\b"#,
            options: [.caseInsensitive]
        ) {
            return "Reformatting selection..."
        }
        if normalized.matches(
            #"^(?:please\s+)?(?:summarize|shorten|condense)\b"#,
            options: [.caseInsensitive]
        ) {
            return "Condensing selection..."
        }
        return "Rewriting selection..."
    }

    static func sanitizePostProcessingOutput(
        original: String,
        result: String?,
        allowNewContent: Bool = false,
        selectionCommand: String = "",
        profile: CleanupPromptProfile = .default,
        polishLevel: DictationPolishLevel = .clean
    ) -> (accepted: Bool, text: String, reason: String?) {
        let cleaned = cleanOutput(
            original: original,
            result: result,
            allowSubjectLine: allowNewContent
        )
        let validation = validateOutput(
            original: original,
            result: cleaned,
            allowNewContent: allowNewContent,
            selectionCommand: selectionCommand,
            profile: profile,
            polishLevel: polishLevel
        )
        return (
            validation.accepted,
            validation.accepted ? cleaned : original,
            validation.reason
        )
    }

    static func sanitizeSelectionTransformOutput(
        selectedText: String,
        result: String?,
        command: String,
        lengthPolicy: SelectionTransformLengthPolicy = .default
    ) -> (accepted: Bool, text: String, reason: String?) {
        let original = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw = result?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return (false, original, "empty-output")
        }

        var cleaned = cleanOutput(
            original: original,
            result: raw,
            allowSubjectLine: true,
            preserveOriginalTrailingPunctuation: false
        )
        cleaned = cleanSelectionTransformOutput(
            command: command,
            output: cleaned
        )
        guard !cleaned.isEmpty else {
            return (false, original, "empty-output")
        }

        let validation = validateOutput(
            original: original,
            result: cleaned,
            allowNewContent: true,
            selectionCommand: command,
            profile: .default
        )
        guard validation.accepted else {
            return (false, original, validation.reason)
        }
        if selectionTransformHasCommandEcho(command: command, output: cleaned) {
            return (false, original, "command-echo")
        }
        if looksLikeSelectionTransformExplanation(result: cleaned, original: original) {
            return (false, original, "transform-explanation")
        }
        if selectionTransformOutputTooLong(command: command, selectedText: original, result: cleaned, policy: lengthPolicy) {
            return (false, original, "too-long")
        }
        return (true, cleaned, nil)
    }

    struct SelectionTransformLengthPolicy: Equatable {
        enum Intent: String {
            case compressive
            case expansive
            case formatOnly
            case normal
        }

        var intent: Intent
        var inputLength: Int

        static let `default` = SelectionTransformLengthPolicy(
            intent: .normal,
            inputLength: 0
        )

        var maxOutputCharacters: Int {
            let baseLength = max(1, inputLength)
            let absoluteCap = 80_000
            let normalFloor = 12_000
            let normalMultiplier = 10

            let intentCap: Int
            switch intent {
            case .compressive:
                intentCap = max(1_500, baseLength * 2)
            case .formatOnly:
                intentCap = max(normalFloor, baseLength * normalMultiplier)
            case .normal:
                intentCap = max(normalFloor, baseLength * normalMultiplier)
            case .expansive:
                intentCap = max(24_000, baseLength * 20)
            }

            return min(absoluteCap, intentCap)
        }

        var approximateMaxOutputTokens: Int {
            max(512, min(20_000, Int((Double(maxOutputCharacters) / 3.5).rounded(.up))))
        }
    }

    static func selectionTransformLengthPolicy(
        command: String,
        selectedText: String
    ) -> SelectionTransformLengthPolicy {
        SelectionTransformLengthPolicy(
            intent: selectionTransformIntent(command),
            inputLength: selectedText.trimmingCharacters(in: .whitespacesAndNewlines).count
        )
    }

    private static func cleanOutput(
        original: String,
        result: String?,
        allowSubjectLine: Bool,
        preserveOriginalTrailingPunctuation: Bool = true
    ) -> String {
        guard var output = result?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty else {
            return original
        }

        output = output.replacingOccurrences(of: #"<think>[\s\S]*?<\/think>\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // The pause reference marker is prompt markup — if the model echoes
        // it, drop the marker but keep the surrounding words.
        if output.contains(PauseSegmenter.pauseMarker) {
            output = output
                .replacingOccurrences(
                    of: #"[ \t]*"# + NSRegularExpression.escapedPattern(for: PauseSegmenter.pauseMarker) + #"[ \t]*"#,
                    with: " ",
                    options: .regularExpression
                )
                .replacingOccurrences(of: #" +\n"#, with: "\n", options: .regularExpression)
                .replacingOccurrences(of: #"\n +"#, with: "\n", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        output = output.replacingOccurrences(
            of: #"^(?:certainly|sure|of course|great|absolutely|happy to help)[!,.]?\s*(?:here(?:'s| is)[^:\n]*[:\n]\s*)?"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        output = output.replacingOccurrences(
            of: #"^here(?:'s| is)\s+(?:the|a|your)\s+(?:cleaned|corrected|edited|revised|final)\s+(?:message|text|email|reply|version)[^:\n]*[:\n]\s*"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        output = output.replacingOccurrences(
            of: #"^here(?:'s| is)\s+(?:the|a|your)\s+[^:\n]*[:\n]\s*"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        output = output.replacingOccurrences(
            of: #"\(\s*i\s+(?:made changes|removed|corrected|cleaned|edited|rewrote)[^)]*\)\s*"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        output = output.replacingOccurrences(
            of: #"\(\s*no\s+change(?:s)?\s+(?:needed|required|made|were made)[^)]*\)\s*"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        output = output.replacingOccurrences(
            of: #"\bHowever(?:,)?\s+since\s+(?:this|the)\s+(?:request|text|input)[^\n]*\n+"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        output = stripPairedBeforeAfterBlock(output)
        output = extractLastEditorialSection(output, original: original)
        output = stripDuplicatedOriginalPrefix(original: original, output: output)

        for prefix in labelPrefixes where output.lowercased().hasPrefix(prefix) {
            output = String(output.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if output.count >= 2,
           (output.hasWrapped(with: "\"") || output.hasWrapped(with: "'")) {
            output = String(output.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if !allowSubjectLine,
           !original.matches(#"^\s*subject\s*:"# , options: [.caseInsensitive]) {
            output = output.replacingOccurrences(
                of: #"^\s*subject\s*:[^\n]*\n+(?:\s*\n+)*"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            ).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if preserveOriginalTrailingPunctuation {
            output = preserveTrailingPunctuation(original: original, output: output)
        }
        return output.isEmpty ? original : output
    }

    private static func cleanSelectionTransformOutput(command: String, output: String) -> String {
        var working = output.trimmingCharacters(in: .whitespacesAndNewlines)
        working = stripEchoedSelectionCommand(command: command, output: working)

        for prefix in labelPrefixes where working.lowercased().hasPrefix(prefix) {
            working = String(working.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return working
    }

    private static func stripEchoedSelectionCommand(command: String, output: String) -> String {
        let normalizedCommand = command
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"[.!?;:,\s]+$"#, with: "", options: .regularExpression)
        guard !normalizedCommand.isEmpty else { return output }

        let escapedCommand = NSRegularExpression.escapedPattern(for: normalizedCommand)
        let patterns = [
            #"(?is)^\s*(?:command|instruction|request)\s*[:\-–—]\s*\#(escapedCommand)\s*(?:\n+|$)"#,
            #"(?is)^\s*\#(escapedCommand)\s*[:\-–—]\s*"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsOutput = output as NSString
            let range = NSRange(location: 0, length: nsOutput.length)
            guard let match = regex.firstMatch(in: output, range: range),
                  match.range.location == 0 else {
                continue
            }
            let tail = nsOutput
                .substring(from: match.range.location + match.range.length)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty {
                return tail
            }
        }

        return output
    }

    private static func selectionTransformHasCommandEcho(command: String, output: String) -> Bool {
        let normalizedCommand = command
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"[.!?;:,\s]+$"#, with: "", options: .regularExpression)
            .lowercased()
        guard normalizedCommand.count >= 4 else { return false }

        let normalizedOutput = output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalizedOutput.hasPrefix(normalizedCommand)
    }

    private static func looksLikeSelectionTransformExplanation(result: String, original: String) -> Bool {
        let output = result.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = original.trimmingCharacters(in: .whitespacesAndNewlines)

        let explanatoryPatterns = [
            #"^(?:i(?:'ve| have)?\s+)?(?:rewrote|rewritten|restructured|transformed|changed|converted|formatted|polished|summarized|translated)\s+(?:the\s+)?(?:selected\s+)?(?:text|selection|message)\b"#,
            #"^(?:this|the)\s+(?:rewritten|restructured|transformed|revised|polished|summarized|translated)\s+(?:message|text|version|selection)\b"#,
            #"(?m)^\s*(?:changes made|notes?|explanation|why this works)\s*:"#,
            #"(?m)^\s*(?:original|before|input|source)\s*[:\-–—]"#
        ]

        return explanatoryPatterns.contains { pattern in
            output.matches(pattern, options: [.caseInsensitive])
                && !input.matches(pattern, options: [.caseInsensitive])
        }
    }

    private static func selectionTransformOutputTooLong(
        command: String,
        selectedText: String,
        result: String,
        policy: SelectionTransformLengthPolicy
    ) -> Bool {
        let outputLength = result.count
        guard outputLength > 1200 else { return false }
        return outputLength > policy.maxOutputCharacters
    }

    private static func selectionTransformHasDetailedConstraints(_ command: String) -> Bool {
        let constraintPatterns = [
            #"\b(?:keep|preserve|retain|maintain)\b.+\b(?:but|while|without|except)\b"#,
            #"\b(?:do not|don't|avoid|remove|exclude|include|ensure|make sure|must|must not|only)\b"#,
            #"\b(?:tone|audience|voice|style|structure|format|constraints?|requirements?|criteria)\b"#,
            #"\b(?:confident|concise|technical|executive|investor|customer|legal|salesy|formal|casual)\b"#,
            #"\b(?:end with|start with|preserve the|keep the|remove the|include a|without adding)\b"#,
            #"\b(?:example|examples|like this|as follows|rubric)\b"#
        ]
        let matches = constraintPatterns.reduce(0) { count, pattern in
            count + (command.matches(pattern, options: [.caseInsensitive]) ? 1 : 0)
        }
        return matches >= 2
    }

    private static func selectionTransformIntent(_ command: String) -> SelectionTransformLengthPolicy.Intent {
        if command.matches(#"\b(?:summarize|shorten|condense|make\s+(?:this|it|the selection|selected text)\s+shorter|make\s+(?:this|it)\s+concise)\b"#, options: [.caseInsensitive]) {
            return .compressive
        }

        if command.matches(#"\b(?:expand|elaborate|add\s+(?:detail|details|context)|make\s+(?:this|it|the selection|selected text)\s+(?:longer|more detailed|comprehensive)|turn\s+(?:this|it|the selection|selected text)\s+into\s+(?:a\s+)?(?:full|complete|detailed))\b"#, options: [.caseInsensitive])
            || selectionCommandAllowsTemplateExpansion(command) {
            return .expansive
        }

        if command.matches(#"\b(?:format|reformat|bullet(?:ize)?|number|capitalize|lowercase|uppercase|title[\s-]?case|convert\s+(?:this|it)\s+to\s+markdown)\b"#, options: [.caseInsensitive]) {
            return .formatOnly
        }

        return .normal
    }

    private static func validateOutput(
        original: String,
        result: String,
        allowNewContent: Bool,
        selectionCommand: String,
        profile: CleanupPromptProfile,
        polishLevel: DictationPolishLevel = .clean
    ) -> (accepted: Bool, reason: String?) {
        // Polished mode invites rephrasing, so the gates that assume the
        // output tracks the input word-for-word get proportionally wider. The
        // structural rejections (assistant response, invented greetings,
        // template scaffolding) stay at full strength.
        let polished = polishLevel == .polished
        let maxLengthRatio = polished ? 3.0 : 2.4
        let minLengthRatio = polished ? 0.22 : 0.35
        let shortCoverageFloor = polished ? 0.5 : minShortCoverage
        let shortNovelCeiling = polished ? 0.6 : 0.45
        let contentCoverageFloor = polished ? 0.25 : minContentCoverage
        let contentNovelCeiling = polished ? 0.68 : maxContentNovelRatio

        guard !result.isEmpty else { return (false, "empty-output") }
        if looksLikeAssistantResponse(result: result, original: original) {
            return (false, "assistant-response")
        }

        switch profile {
        case .emailFragment:
            if insertedEmailGreetingLine(original: original, result: result) {
                return (false, "inserted-email-greeting")
            }
            if insertedEmailClosingBlock(original: original, result: result) {
                return (false, "inserted-email-signoff")
            }
        case .emailFull:
            if insertedUndictatedEmailGreeting(original: original, result: result) {
                return (false, "inserted-email-greeting")
            }
            if insertedUndictatedEmailClosing(original: original, result: result) {
                return (false, "inserted-email-signoff")
            }
        case .default, .message:
            break
        }

        if allowNewContent,
           !selectionCommandAllowsTemplateExpansion(selectionCommand),
           !textHasTemplateScaffolding(original),
           textHasTemplateScaffolding(result) {
            return (false, "unexpected-template-expansion")
        }

        if !allowNewContent,
           insertedUnrequestedShortBulletList(original: original, result: result, profile: profile) {
            return (false, "unrequested-bullet-list")
        }

        if allowNewContent {
            return (true, nil)
        }

        if result.matches(#"\b(?:let me know if (?:there'?s anything else|you need (?:anything|any help|further assistance)|you have any questions)|if there'?s anything else i can assist|happy to help|further assistance)\b"#, options: .caseInsensitive),
           !original.matches(#"\b(?:let me know if (?:there'?s anything else|you need (?:anything|any help|further assistance)|you have any questions)|if there'?s anything else i can assist|happy to help|further assistance)\b"#, options: .caseInsensitive) {
            return (false, "help-offer-inserted")
        }

        if isQuestionLike(original), !isQuestionLike(result) {
            return (false, "question-intent-lost")
        }

        let inputLength = max(1, original.count)
        if result.count > max(1000, Int(Double(inputLength) * maxLengthRatio)) {
            return (false, "too-long")
        }

        // Self-correction cues ("no wait", "scratch that", "sorry I meant",
        // "actually") mean the cleaned version legitimately drops the
        // abandoned words — skip length/coverage gates that assume the
        // cleaned length tracks the input length. Repeated-restart corrections
        // carry no cue word, so they get the same latitude via the
        // structural restart check.
        let hasCorrection = hasSelfCorrectionCue(original)
            || isCuelessRestartCleanup(original: original, result: result)

        if !hasCorrection, result.count < Int(Double(inputLength) * minLengthRatio) {
            return (false, "too-short")
        }

        let inputTokens = uniqueTokenSet(normalizeTokens(original))
        let outputTokens = uniqueTokenSet(normalizeTokens(result))
        if inputTokens.isEmpty || outputTokens.isEmpty {
            return (true, nil)
        }

        if inputTokens.count <= shortInputTokenMax {
            if !hasCorrection,
               coverageRatio(source: inputTokens, target: outputTokens) < shortCoverageFloor {
                return (false, "low-short-coverage")
            }
            if !hasCorrection,
               novelRatio(source: inputTokens, target: outputTokens) > shortNovelCeiling {
                return (false, "too-many-short-novel-tokens")
            }
            return (true, nil)
        }

        let inputContentTokens = uniqueTokenSet(normalizeTokens(original).filter(isContentToken))
        let outputContentTokens = uniqueTokenSet(normalizeTokens(result).filter(isContentToken))
        let sourceTokens = inputContentTokens.isEmpty ? inputTokens : inputContentTokens
        let targetTokens = outputContentTokens.isEmpty ? outputTokens : outputContentTokens

        if !hasCorrection,
           coverageRatio(source: sourceTokens, target: targetTokens) < contentCoverageFloor {
            return (false, "low-content-coverage")
        }
        if !hasCorrection,
           targetTokens.count >= 4,
           novelRatio(source: sourceTokens, target: targetTokens) > contentNovelCeiling {
            return (false, "too-many-novel-content-tokens")
        }

        return (true, nil)
    }

    /// True when the cleaned output is a deletion-only cleanup of a repeated
    /// restart that carries no explicit correction cue — "let's go with the blue
    /// option for the homepage let's go with green" → "Let's go with green."
    /// Restarts have no cue word, so `hasSelfCorrectionCue` never covers them and
    /// a correct deletion whose abandoned half is large can otherwise be rejected
    /// by the coverage/length gates and reverted to the raw transcript. Two tight
    /// signals gate the latitude:
    ///   1. the output is an EXACT contiguous suffix of the input — the speaker
    ///      abandoned a head and restarted with the kept tail, and an exact
    ///      suffix guarantees no invented tokens (leading-context restarts are
    ///      already repaired locally before cloud cleanup);
    ///   2. the kept tail's opening phrase (2+ words) also opens the abandoned
    ///      head — the speaker re-started the same clause. This distinguishes a
    ///      real restart from the model truncating an ordinary sentence or
    ///      dropping a trailing second clause/question, where the tail's opening
    ///      does not echo the head's opening.
    private static func isCuelessRestartCleanup(original: String, result: String) -> Bool {
        let inputTokens = normalizeTokens(original)
        let outputTokens = normalizeTokens(result)
        guard outputTokens.count >= 2,
              inputTokens.count > outputTokens.count,
              Array(inputTokens.suffix(outputTokens.count)) == outputTokens
        else {
            return false
        }
        let head = inputTokens.prefix(inputTokens.count - outputTokens.count)
        let anchor = outputTokens.prefix(2)
        return head.count >= anchor.count && Array(head.prefix(anchor.count)) == Array(anchor)
    }

    /// Mirrors the cue vocabulary the cleanup prompt and FillerRemover repair
    /// on. Keep the three in sync: a cue the model is told to delete but this
    /// list misses makes the coverage gates below revert a correct cleanup.
    private static func hasSelfCorrectionCue(_ text: String) -> Bool {
        text.matches(
            #"\b(?:no,?\s+(?:wait|actually)|wait,?\s+no|sorry,?\s+no|(?:wait\s+)?but\s+actually|i\s+mean(?:t)?|sorry[,\s]+(?:i\s+)?(?:mean(?:t)?)|actually,?\s+(?:no|wait)|or\s+rather|scratch\s+(?:that|this)|strike\s+that|scrap\s+that|never\s*mind|cancel\s+that|forget\s+(?:that|what\s+i\s+said))\b"#,
            options: [.caseInsensitive]
        )
    }

    private static func looksLikeAssistantResponse(result: String, original: String) -> Bool {
        let output = result.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let input = original.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if badPrefixes.contains(where: { output.hasPrefix($0) && !input.hasPrefix($0) }) {
            return true
        }
        if output.contains("assistant:") || output.contains("user:") || output.hasPrefix("```") {
            return true
        }
        if output.matches(#"\b(?:i made changes|corrected to|cleaned message|cleaned text|edited message|edited text|revised text|final version)\b"#, options: .caseInsensitive),
           !input.matches(#"\b(?:i made changes|corrected to|cleaned message|cleaned text|edited message|edited text|revised text|final version)\b"#, options: .caseInsensitive) {
            return true
        }
        if output.matches(#"\bthere is no (?:email|message|text)\s+(?:provided|to (?:clean|rewrite|edit|reformat))\b"#, options: .caseInsensitive) {
            return true
        }
        if output.matches(#"\bplease provide the (?:email|message|text)(?:\s+text)?\s+(?:you(?:'d)? like me to|to)\s+(?:rewrite|reformat|edit|clean)\b"#, options: .caseInsensitive) {
            return true
        }
        // Catch bare conversational openers/acknowledgments added by the model.
        // These are the short replies a chat-tuned LLM emits when it treats an
        // ambiguous dictation as a turn to respond to instead of text to clean.
        if output.matches(#"^(?:yes|no|yeah|nah|nope|well|actually|so|right|okay|ok|alright|cool|gotcha|yep|yup|totally|exactly|understood|noted)\b"#, options: .caseInsensitive),
           !input.matches(#"^(?:yes|no|yeah|nah|nope|well|actually|so|right|okay|ok|alright|cool|gotcha|yep|yup|totally|exactly|understood|noted)\b"#, options: .caseInsensitive) {
            return true
        }
        // Catch conversational/answer-style patterns not in the original.
        // Only match specific assistant-sounding phrases — "I'll [word]" is too
        // broad because STT routinely drops apostrophes (e.g. "ill send" → "I'll
        // send"), causing the sanitizer to reject legitimate email content.
        if output.matches(#"\b(?:i(?:'d| would) (?:be happy|love|suggest|recommend) to\b|i(?:'ll| will) (?:help|assist|do that|take care)\b)"#, options: .caseInsensitive),
           !input.matches(#"\b(?:i(?:'d| would) (?:be happy|love|suggest|recommend) to\b|i(?:'ll| will) (?:help|assist|do that|take care)\b)"#, options: .caseInsensitive) {
            return true
        }
        // Catch "The [noun] is/are..." answers to "what/where/when" questions
        if isQuestionLike(input),
           output.matches(#"^the\s+\w+\s+(?:is|are|was|were|will|would|can|could|should|has|have|had)\b"#, options: .caseInsensitive),
           !input.matches(#"^the\s+\w+\s+(?:is|are|was|were|will|would|can|could|should|has|have|had)\b"#, options: .caseInsensitive) {
            return true
        }
        return false
    }

    private static func insertedUnrequestedShortBulletList(
        original: String,
        result: String,
        profile: CleanupPromptProfile
    ) -> Bool {
        let resultBulletCount = markdownBulletLineCount(in: result)
        guard (1...2).contains(resultBulletCount) else { return false }
        guard markdownBulletLineCount(in: original) == 0 else { return false }
        return listIntent(transcript: original, profile: profile) == .none
    }

    /// Detects when the model echoed the original transcript before the cleaned
    /// version (e.g. "raw text? cleaned text?") and returns just the cleaned tail.
    /// Matches on normalized content tokens so punctuation/casing differences
    /// between the two copies don't block detection.
    private static func stripDuplicatedOriginalPrefix(original: String, output: String) -> String {
        // Capture contractions as a single token so STT "whats" and cleaned
        // "what's" both compare as "whats" after apostrophe stripping.
        // Non-raw string so Swift substitutes the curly apostrophe char.
        let pattern = "[A-Za-z0-9]+(?:[._\u{2019}'-][A-Za-z0-9]+)*"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return output }

        let nsOriginal = original as NSString
        let origMatches = regex.matches(in: original, range: NSRange(location: 0, length: nsOriginal.length))
        let origTokens = origMatches.map { normalizeEchoToken(nsOriginal.substring(with: $0.range)) }
        guard origTokens.count >= 3 else { return output }

        let nsOutput = output as NSString
        let matches = regex.matches(in: output, range: NSRange(location: 0, length: nsOutput.length))
        guard matches.count >= origTokens.count * 2 else { return output }

        let prefixSlice = matches.prefix(origTokens.count).map { match -> String in
            normalizeEchoToken(nsOutput.substring(with: match.range))
        }
        guard Array(prefixSlice) == origTokens else { return output }

        let cutMatch = matches[origTokens.count - 1]
        let cutAt = cutMatch.range.location + cutMatch.range.length
        guard cutAt < nsOutput.length else { return output }

        let tail = nsOutput.substring(from: cutAt)
            .trimmingCharacters(in: duplicateSeparatorCharacters)
        return tail.isEmpty ? output : tail
    }

    private static func normalizeEchoToken(_ token: String) -> String {
        token
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
            .lowercased()
    }

    private static let duplicateSeparatorCharacters: CharacterSet = {
        var set = CharacterSet.whitespacesAndNewlines
        set.insert(charactersIn: ".,;:!?-—–()\"'`")
        return set
    }()

    /// Strips paired `Original: foo \n Cleaned: bar` or `Before: foo \n After: bar`
    /// blocks the model emits when narrating the transformation. Returns only
    /// the cleaned/after side. Conservative: both labels must appear on
    /// consecutive non-empty lines for the strip to fire.
    private static func stripPairedBeforeAfterBlock(_ text: String) -> String {
        let pattern = #"(?is)^\s*(?:original|before|raw|input|dictated|source)\s*[:\-–—]\s*[^\n]+\n+\s*(?:cleaned(?:\s+(?:text|message|version))?|after|output|result|corrected(?:\s+text)?|revised(?:\s+text)?|final(?:\s+(?:text|version))?)\s*[:\-–—]\s*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return text
        }
        let tail = ns.substring(from: match.range.location + match.range.length)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return tail.isEmpty ? text : tail
    }

    private static func extractLastEditorialSection(_ text: String, original: String = "") -> String {
        let labelPattern = #"(?:^|\n)\s*(?:cleaned message|cleaned text|edited text|edited message|revised text|final text|final version|corrected to|here(?:'s| is)(?:\s+(?:the|a|your)\s+\w+)?)\s*[:\n]\s*"#
        var working = text
        if let regex = try? NSRegularExpression(pattern: labelPattern, options: [.caseInsensitive]) {
            let nsText = working as NSString
            let matches = regex.matches(in: working, range: NSRange(location: 0, length: nsText.length))
            if let last = matches.last {
                let tail = nsText.substring(from: last.range.location + last.range.length).trimmingCharacters(in: .whitespacesAndNewlines)
                if !tail.isEmpty { working = tail }
            }
        }

        // Strip "... becomes ..." transformation descriptions the model emits
        // instead of just returning the cleaned text (e.g. `"foo" becomes "foo."`
        // or `becomes: foo.`). Only strip when "becomes" isn't part of the
        // original transcript, so legitimate content like "water becomes ice"
        // passes through untouched.
        let originalLower = original.lowercased()
        if !originalLower.contains("becomes") {
            let becomesPattern = #"^(?:[^\n]{0,400}?)\bbecomes\b\s*:?\s*"#
            if let becomesRegex = try? NSRegularExpression(pattern: becomesPattern, options: [.caseInsensitive]) {
                let nsWorking = working as NSString
                if let match = becomesRegex.firstMatch(in: working, range: NSRange(location: 0, length: nsWorking.length)) {
                    let tail = nsWorking.substring(from: match.range.location + match.range.length).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !tail.isEmpty { working = tail }
                }
            }
        }

        return working
    }

    private static func preserveTrailingPunctuation(original: String, output: String) -> String {
        let originalTrimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !originalTrimmed.isEmpty else { return output }

        let originalEndsWithPunctuation = originalTrimmed.matches(#"[.!?]$"#)
        let outputEndsWithPunctuation = output.matches(#"[.!?]$"#)

        if !originalEndsWithPunctuation, outputEndsWithPunctuation {
            // Keep a trailing `?` when the output is clearly a question —
            // STT often drops the punctuation on dictated questions.
            if output.hasSuffix("?"), isQuestionLike(originalTrimmed) || isQuestionLike(output) {
                return output
            }
            return output.replacingOccurrences(of: #"[.!?]+$"#, with: "", options: .regularExpression)
        }
        if originalEndsWithPunctuation, !outputEndsWithPunctuation, let suffix = originalTrimmed.last {
            return output + String(suffix)
        }
        // Dictated question with no punctuation: add `?` so the cleaned
        // output reads correctly. Echo-stripping also removes trailing
        // question marks; this restores them.
        if !originalEndsWithPunctuation, !outputEndsWithPunctuation, isQuestionLike(originalTrimmed) {
            return output + "?"
        }
        return output
    }

    private static func normalizeTokens(_ text: String) -> [String] {
        let lowercased = text.lowercased()
        let pattern = #"[a-z0-9]+(?:[._-][a-z0-9]+)*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsText = lowercased as NSString
        return regex.matches(in: lowercased, range: NSRange(location: 0, length: nsText.length))
            .map { nsText.substring(with: $0.range) }
    }

    private static func uniqueTokenSet(_ tokens: [String]) -> Set<String> {
        Set(tokens)
    }

    private static func coverageRatio(source: Set<String>, target: Set<String>) -> Double {
        guard !source.isEmpty else { return 1 }
        return Double(source.intersection(target).count) / Double(source.count)
    }

    private static func novelRatio(source: Set<String>, target: Set<String>) -> Double {
        guard !target.isEmpty else { return 0 }
        return Double(target.subtracting(source).count) / Double(target.count)
    }

    private static func isQuestionLike(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        if normalized.hasSuffix("?") { return true }
        if normalized.matches(#"[.!]$"#) { return false }
        // Match WH-words plus STT/contraction variants ("whats", "what's").
        // Apostrophe stripped via a non-raw pattern so `\u{2019}` resolves.
        let questionPattern = "^(?:whos|whats|whens|wheres|whys|hows|who|what|when|where|why|how)[\u{2019}'s]*\\b"
        if normalized.matches(questionPattern, options: .caseInsensitive) {
            return true
        }
        return normalized.matches(
            #"^(?:can|could|should|would|will|do|does|did|is|are|am|was|were|have|has|had)\b"#,
            options: .caseInsensitive
        )
    }

    private static func textHasTemplateScaffolding(_ text: String) -> Bool {
        text.matches(#"^\s*subject\s*:"#, options: [.caseInsensitive])
            || text.matches(#"(?:^|\n)\s*(?:dear\b|hi\b|hello\b)"#, options: [.caseInsensitive])
            || text.matches(#"(?:^|\n)\s*(?:best regards|kind regards|regards|sincerely|thanks|thank you),?(?:\n|$)"#, options: [.caseInsensitive])
            || text.matches(#"\[(?:recipient|recipient name|your name|sender|sender name|company|company name)\]"#, options: [.caseInsensitive])
    }

    private static func selectionCommandAllowsTemplateExpansion(_ command: String) -> Bool {
        command.matches(
            #"\b(?:draft|compose|expand|elaborate)\b|\b(?:turn|format|rewrite|make)\b[\s\S]{0,24}\b(?:email|message|reply|letter|cover letter|announcement|memo)\b|\b(?:add|include)\b[\s\S]{0,24}\b(?:greeting|sign-off|signature|subject line)\b"#,
            options: [.caseInsensitive]
        )
    }

    private static func insertedEmailGreetingLine(original: String, result: String) -> Bool {
        hasEmailGreetingLine(result) && !hasEmailGreetingLine(original)
    }

    private static func insertedUndictatedEmailGreeting(original: String, result: String) -> Bool {
        hasEmailGreetingLine(result) && !hasEmailGreetingCue(original)
    }

    private static func insertedEmailClosingBlock(original: String, result: String) -> Bool {
        hasEmailClosingBlock(result) && !hasEmailClosingBlock(original)
    }

    private static func insertedUndictatedEmailClosing(original: String, result: String) -> Bool {
        hasEmailClosingBlock(result) && !hasEmailClosingCue(original)
    }

    private static func hasEmailGreetingCue(_ text: String) -> Bool {
        text.matches(#"(?is)^\s*(?:"# + EmailSignatureSupport.primaryGreetingWords + #")\b"#)
            || text.matches(recipientGreetingCuePattern)
    }

    private static let emailClosingPhrases =
        "all the best|all my best|best regards|kind regards|best wishes|many thanks|thanks again|yours truly|yours sincerely|thank you|take care|talk soon|speak soon|appreciate it|with love|lots of love|until next time|until soon|catch you later|bye for now|regards|sincerely|thanks|cheers|aloha|love|best|yours|warmly|hugs|ciao|peace|bye|goodbye|xoxo|xo"

    private static let emailClosingNamePattern =
        #"(?-i:[\p{Lu}][\p{L}'-]{0,30}(?:\s+[\p{Lu}][\p{L}'-]{0,30}){0,2})"#

    private static let emailClosingTailPattern =
        #"(?:(?:"# + emailClosingPhrases + #"),?(?:\s*\n\s*|\s+)(?:"# + emailClosingNamePattern + #")(?:[.!?])?|(?:"# + emailClosingPhrases + #")(?:,|[.!?])?)"#

    private static let recipientGreetingExcludedWords = EmailSignatureSupport.recipientGreetingExcludedWords

    private static let recipientGreetingLinePattern: String =
        #"(?is)^\s*(?!(?:"# + recipientGreetingExcludedWords + #")\b)[\p{Lu}][\p{L}'-]{1,29}(?:\s+[\p{Lu}][\p{L}'-]{1,29})?,(?:\s*\n|$)"#

    private static let recipientGreetingCuePattern: String =
        #"(?is)^\s*(?!(?:"# + recipientGreetingExcludedWords + #")\b)[\p{Lu}][\p{L}'-]{1,29}(?:\s+[\p{Lu}][\p{L}'-]{1,29})?,\s+\S"#

    private static func hasEmailGreetingLine(_ text: String) -> Bool {
        text.matches(#"(?is)^\s*(?:"# + EmailSignatureSupport.primaryGreetingWords + #")(?:,\s+|\s+)[^\n,]{1,80}?[,.](?:\s*\n|$)"#)
            || text.matches(recipientGreetingLinePattern)
    }

    private static func hasEmailClosingBlock(_ text: String) -> Bool {
        text.matches(
            #"(?is)(?:^|\n)\s*(?:"# + emailClosingPhrases + #"),?\s*\n\s*(?:"# + emailClosingNamePattern + #")\s*$"#
        )
    }

    private static func hasEmailClosingCue(_ text: String) -> Bool {
        text.matches(
            #"(?is)\b"# + emailClosingTailPattern + #"\s*$"#
        )
    }

    private static func hasExistingEmailDraftContent(_ text: String?) -> Bool {
        guard let normalized = text?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !normalized.isEmpty else {
            return false
        }

        if normalized.matches(
            #"^(?:message|message body|compose|compose email|new message|new email|write|write email|type a message|start typing)$"#,
            options: [.caseInsensitive]
        ) {
            return false
        }

        return !strippingExistingEmailBoilerplate(from: normalized).isEmpty
    }

    private static func looksLikeFullEmailTranscript(_ text: String) -> Bool {
        hasEmailGreetingCue(text) || hasEmailClosingCue(text)
    }

    private static func isEmailSignoffOnlyTranscript(
        _ text: String,
        fallbackSenderName: String?
    ) -> Bool {
        let normalized = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }

        if normalized.matches(#"(?is)^"# + emailClosingTailPattern + #"$"#) {
            return true
        }

        guard let fallbackSenderName = fallbackSenderName?
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !fallbackSenderName.isEmpty else {
            return false
        }

        if normalized.compare(fallbackSenderName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            return true
        }

        let escapedSenderName = NSRegularExpression.escapedPattern(for: fallbackSenderName)
        return normalized.matches(
            #"(?is)^(?:"# + emailClosingPhrases + #")(?:,)?\s+"# + escapedSenderName + #"(?:[.!?])?$"#,
            options: [.caseInsensitive]
        )
    }

    private static func isContentToken(_ token: String) -> Bool {
        token.rangeOfCharacter(from: CharacterSet(charactersIn: "._-0123456789")) != nil || token.count >= 4
    }

    private static func strippingExistingEmailBoilerplate(from text: String) -> String {
        var working = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !working.isEmpty else { return "" }

        if let quoteRange = firstMatchRange(
            of: #"(?im)^\s*(?:on .+wrote:|from:|sent:|to:|subject:)\b.*$"#,
            in: working
        ) {
            let nsText = working as NSString
            working = nsText.substring(to: quoteRange.location)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        working = working.replacingOccurrences(
            of: #"(?im)^\s*>.*(?:\n|$)"#,
            with: "",
            options: [.regularExpression]
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        var didStrip = false
        repeat {
            didStrip = false

            let withoutFooter = working.replacingOccurrences(
                of: #"(?is)(?:\n\s*\n|\A)\s*(?:(?:sent\s+(?:with|using|from)\s+(?:resonant|proton(?:\s+mail)?(?:\s+mobile|\s+secure\s+email)?|spark|willow(?:\s+voice)?|my\s+(?:iphone|ipad|android|phone)|outlook(?:\s+for\s+(?:ios|android))?))(?:\s*\n\s*https?://\S+)?|get\s+outlook\s+for\s+(?:ios|android))\s*$"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            if withoutFooter != working {
                working = withoutFooter
                didStrip = true
            }

            let withoutClosing = working.replacingOccurrences(
                of: #"(?is)(?:\n\s*\n|\A)\s*"# + emailClosingTailPattern + #"\s*$"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            if withoutClosing != working {
                working = withoutClosing
                didStrip = true
            }
        } while didStrip

        return working
    }

    private static func firstMatchRange(of pattern: String, in text: String) -> NSRange? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, range: range)?.range
    }
}

private extension String {
    func matches(_ pattern: String, options: NSRegularExpression.Options = []) -> Bool {
        (try? NSRegularExpression(pattern: pattern, options: options))?
            .firstMatch(in: self, range: NSRange(startIndex..., in: self)) != nil
    }

    func hasWrapped(with character: Character) -> Bool {
        first == character && last == character
    }
}
