import XCTest
@testable import Resonant

final class CloudProcessingSupportTests: XCTestCase {

    func testNormalizeAppKeyRecognizesTutaInFirefoxAsEmail() {
        XCTAssertEqual(
            CloudProcessingSupport.normalizeAppKey(
                appName: "Firefox",
                bundleId: "org.mozilla.firefox",
                windowTitle: "Compose",
                browserURL: "https://app.tuta.com/mail"
            ),
            "email"
        )
    }

    func testNormalizeAppKeyRecognizesThunderbirdAsEmail() {
        XCTAssertEqual(
            CloudProcessingSupport.normalizeAppKey(
                appName: "Thunderbird",
                bundleId: "org.mozilla.thunderbird",
                windowTitle: "Write: Project update",
                browserURL: nil
            ),
            "email"
        )
    }

    func testEmailCleanupUsesDedicatedPrompt() {
        let profile = CloudProcessingSupport.cleanupPromptProfile(
            appName: "Thunderbird",
            bundleId: "org.mozilla.thunderbird",
            windowTitle: "Write",
            browserURL: nil,
            emailMode: .fullEmail
        )

        XCTAssertEqual(profile, .emailFull)
        XCTAssertNotEqual(
            CloudProcessingSupport.cleanupInstruction(for: profile),
            CloudProcessingSupport.messageCleanupInstruction
        )
        XCTAssertTrue(
            CloudProcessingSupport.cleanupInstruction(for: profile)
                .localizedCaseInsensitiveContains("outbound email")
        )
        XCTAssertTrue(
            CloudProcessingSupport.cleanupInstruction(for: profile)
                .localizedCaseInsensitiveContains("do not guess ambiguous names")
        )
        XCTAssertTrue(
            CloudProcessingSupport.cleanupInstruction(for: profile)
                .localizedCaseInsensitiveContains("block-format a greeting")
        )
    }

    func testQualityRepairInstructionScopesRepairToListedIssues() {
        let instruction = CloudProcessingSupport.qualityRepairInstruction(
            for: .emailFull,
            issues: ["numeric_idiom", "malformed_email_closing"],
            listIntent: .none
        )

        XCTAssertTrue(instruction.contains("Fix ONLY the listed quality issues"))
        XCTAssertTrue(instruction.contains("numeric_idiom, malformed_email_closing"))
        XCTAssertTrue(instruction.contains("Do not add new facts"))
        XCTAssertTrue(instruction.contains(#""1 last time" -> "one last time""#))
        XCTAssertTrue(instruction.contains(#""Best regards to Alex" means "Best regards,\#nAlex""#))
    }

    func testQualityRepairInstructionAddsStructureGuidanceOnlyForLongTextIssue() {
        let plain = CloudProcessingSupport.qualityRepairInstruction(
            for: .default,
            issues: ["numeric_idiom"],
            listIntent: .none
        )
        let structured = CloudProcessingSupport.qualityRepairInstruction(
            for: .default,
            issues: ["long_unstructured_text"],
            listIntent: .explicit
        )

        XCTAssertFalse(plain.contains("Long-form structure"))
        XCTAssertTrue(structured.contains("Long-form structure"))
        XCTAssertTrue(structured.localizedCaseInsensitiveContains("markdown bullets"))
    }

    func testEmailModeDefaultsToFullEmailForBlankBodyOnlyTranscript() {
        let mode = CloudProcessingSupport.emailDictationMode(
            transcript: "For some reason I'm not getting the option in either.",
            focusedFieldContent: nil,
            appName: "Mail",
            bundleId: "com.apple.mail",
            windowTitle: "Compose",
            browserURL: nil,
            fallbackSenderName: "Alex"
        )

        XCTAssertEqual(mode, .fullEmail)
    }

    func testEmailModeTreatsSignatureOnlyFieldAsNotExistingDraft() {
        let mode = CloudProcessingSupport.emailDictationMode(
            transcript: "Hey Alice thank you for your message kind regards Alex",
            focusedFieldContent: """
            Kind regards,
            Alex

            Sent with Resonant
            """,
            appName: "Mail",
            bundleId: "com.apple.mail",
            windowTitle: "Compose",
            browserURL: nil,
            fallbackSenderName: "Alex"
        )

        XCTAssertEqual(mode, .fullEmail)
    }

    func testEmailModeTreatsProtonMobileSignatureOnlyFieldAsNotExistingDraft() {
        let mode = CloudProcessingSupport.emailDictationMode(
            transcript: "Thanks for sending this over.",
            focusedFieldContent: "Sent from Proton Mail mobile",
            appName: "Safari",
            bundleId: "com.apple.Safari",
            windowTitle: "Proton Mail",
            browserURL: "https://mail.proton.me/u/0/inbox",
            fallbackSenderName: "Alex"
        )

        XCTAssertEqual(mode, .fullEmail)
    }

    func testEmailModeTreatsSparkSignatureOnlyFieldAsNotExistingDraft() {
        let mode = CloudProcessingSupport.emailDictationMode(
            transcript: "Thanks for sending this over.",
            focusedFieldContent: "Sent with Spark",
            appName: "Spark",
            bundleId: "com.readdle.smartemail",
            windowTitle: "Compose",
            browserURL: nil,
            fallbackSenderName: "Alex"
        )

        XCTAssertEqual(mode, .fullEmail)
    }

    func testEmailModeKeepsExistingDraftWithSignatureAsFragment() {
        let mode = CloudProcessingSupport.emailDictationMode(
            transcript: "One more detail.",
            focusedFieldContent: """
            Thanks for the update.

            Sent from Proton Mail mobile
            """,
            appName: "Safari",
            bundleId: "com.apple.Safari",
            windowTitle: "Proton Mail",
            browserURL: "https://mail.proton.me/u/0/inbox",
            fallbackSenderName: "Alex"
        )

        XCTAssertEqual(mode, .fragment)
    }

    func testEmailModeDetectsSignoffOnlyTranscript() {
        let mode = CloudProcessingSupport.emailDictationMode(
            transcript: "Kind regards Alex",
            focusedFieldContent: "Existing draft body",
            appName: "Mail",
            bundleId: "com.apple.mail",
            windowTitle: "Compose",
            browserURL: nil,
            fallbackSenderName: "Alex"
        )

        XCTAssertEqual(mode, .signoffOnly)
    }

    func testEmailModePreservesDictatedGreetingWithExistingDraftContent() {
        let mode = CloudProcessingSupport.emailDictationMode(
            transcript: "Hi Alex, thank you for sending this over.",
            focusedFieldContent: "Existing reply text",
            appName: "Mail",
            bundleId: "com.apple.mail",
            windowTitle: "Compose",
            browserURL: nil,
            fallbackSenderName: "Alex"
        )

        XCTAssertEqual(mode, .fullEmail)
    }

    func testEmailModeTreatsSubjectFieldAsFragment() {
        let mode = CloudProcessingSupport.emailDictationMode(
            transcript: "Quick follow up on the launch plan",
            focusedFieldContent: nil,
            focusedFieldContext: EmailFocusedFieldContext(
                role: "AXTextField",
                subrole: nil,
                title: "Subject",
                placeholderValue: "Subject",
                identifier: nil,
                description: nil,
                help: nil
            ),
            appName: "Mail",
            bundleId: "com.apple.mail",
            windowTitle: "Compose",
            browserURL: nil,
            fallbackSenderName: "Alex"
        )

        XCTAssertEqual(mode, .fragment)
    }

    func testCleanupInstructionEmbedsPauseReference() {
        let instruction = CloudProcessingSupport.cleanupInstruction(
            for: .default,
            pauseAnnotatedTranscript: "send it Monday <pause> actually no Wednesday"
        )
        XCTAssertTrue(instruction.contains("Pause reference:"))
        XCTAssertTrue(instruction.contains("send it Monday <pause> actually no Wednesday"))
        XCTAssertTrue(instruction.contains("clean only the main transcript"))
    }

    func testCleanupInstructionOmitsPauseReferenceWithoutMarkers() {
        // An annotation that carries no marker adds tokens but no signal.
        let instruction = CloudProcessingSupport.cleanupInstruction(
            for: .default,
            pauseAnnotatedTranscript: "send it Monday actually no Wednesday"
        )
        XCTAssertFalse(instruction.contains("Pause reference:"))

        XCTAssertFalse(
            CloudProcessingSupport.cleanupInstruction(for: .default)
                .contains("Pause reference:")
        )
    }

    func testCleanupInstructionOmitsOversizedPauseReference() {
        let oversized = Array(
            repeating: "some words <pause> more words",
            count: 150
        ).joined(separator: " ")
        let instruction = CloudProcessingSupport.cleanupInstruction(
            for: .default,
            pauseAnnotatedTranscript: oversized
        )
        XCTAssertFalse(instruction.contains("Pause reference:"))
    }

    func testSanitizerStripsEchoedPauseMarkers() {
        let result = CloudProcessingSupport.sanitizePostProcessingOutput(
            original: "send it Monday actually no Wednesday",
            result: "Send it <pause> Wednesday."
        )
        XCTAssertTrue(result.accepted, "Expected accepted, got reason: \(result.reason ?? "nil")")
        XCTAssertEqual(result.text, "Send it Wednesday")
    }

    func testSanitizerAcceptsApostropheFixedIll() {
        // STT often drops apostrophes: "ill send" → "I'll send".
        // The sanitizer must not reject this as an assistant response.
        let result = CloudProcessingSupport.sanitizePostProcessingOutput(
            original: "ill send you the report tomorrow",
            result: "I'll send you the report tomorrow."
        )
        XCTAssertTrue(result.accepted, "Expected accepted, got reason: \(result.reason ?? "nil")")
        XCTAssertEqual(result.text, "I'll send you the report tomorrow")
    }

    func testSanitizerRejectsAssistantIllHelp() {
        // "I'll help" should still be caught as an assistant response
        // when the original didn't contain it.
        let result = CloudProcessingSupport.sanitizePostProcessingOutput(
            original: "what time is the meeting",
            result: "I'll help you find that. The meeting is at 3pm."
        )
        XCTAssertFalse(result.accepted)
    }

    func testSanitizerGivesCorrectionLatitudeToWaitNoCue() {
        // "wait no" is a cue the cleanup prompt resolves by deleting the
        // abandoned wording — the shortened, non-suffix output must not be
        // reverted by the short-coverage gate.
        let result = CloudProcessingSupport.sanitizePostProcessingOutput(
            original: "send it to tom wait no tim",
            result: "Send it to Tim."
        )
        XCTAssertTrue(result.accepted, "Expected accepted, got reason: \(result.reason ?? "nil")")
        XCTAssertEqual(result.text, "Send it to Tim")
    }

    func testShortDictationWithCorrectionCueStillGoesToCloud() {
        // A short transcript that carries a correction cue needs the cleanup
        // pass — the local bypass must not skip it.
        XCTAssertFalse(
            CloudProcessingSupport.shouldBypassCloudCleanupForShortDictation(
                transcript: "tom wait no tim",
                profile: .default
            )
        )
    }

    func testSanitizerStripsDuplicatedOriginalPrefix() {
        // Model sometimes echoes the raw transcript before the cleaned version.
        // The sanitizer should return only the cleaned tail.
        let original = "What happens when you have multiple harnesses or different environments or your own local models and your own local harnesses?"
        let doubled = "What happens when you have multiple harnesses or different environments or your own local models and your own local harnesses? What happens when you have multiple harnesses, or different environments, or your own local models and your own local harnesses?"
        let cleaned = "What happens when you have multiple harnesses, or different environments, or your own local models and your own local harnesses?"

        let result = CloudProcessingSupport.sanitizePostProcessingOutput(
            original: original,
            result: doubled
        )

        XCTAssertTrue(result.accepted, "Expected accepted, got reason: \(result.reason ?? "nil")")
        XCTAssertEqual(result.text, cleaned)
    }

    func testSanitizerStripsDuplicatedOriginalPrefixWithNewlineSeparator() {
        let original = "let me know when the next deploy window opens"
        let doubled = "let me know when the next deploy window opens\n\nLet me know when the next deploy window opens."

        let result = CloudProcessingSupport.sanitizePostProcessingOutput(
            original: original,
            result: doubled
        )

        XCTAssertTrue(result.accepted, "Expected accepted, got reason: \(result.reason ?? "nil")")
        XCTAssertEqual(result.text, "Let me know when the next deploy window opens")
    }

    func testSanitizerStripsBecomesTransformationDescription() {
        // Model sometimes emits `"foo" becomes "foo."` describing the
        // transformation instead of just returning the cleaned text.
        let original = "hey can you send me the report"
        let described = "\"hey can you send me the report\" becomes \"Hey, can you send me the report?\""

        let result = CloudProcessingSupport.sanitizePostProcessingOutput(
            original: original,
            result: described
        )

        XCTAssertTrue(result.accepted, "Expected accepted, got reason: \(result.reason ?? "nil")")
        // Question starter "can" → preserve the cleaned `?`.
        XCTAssertEqual(result.text, "Hey, can you send me the report?")
    }

    func testSanitizerStripsBecomesWithColonPrefix() {
        let original = "let me know when deploy opens"
        let described = "becomes: Let me know when deploy opens."

        let result = CloudProcessingSupport.sanitizePostProcessingOutput(
            original: original,
            result: described
        )

        XCTAssertTrue(result.accepted, "Expected accepted, got reason: \(result.reason ?? "nil")")
        XCTAssertEqual(result.text, "Let me know when deploy opens")
    }

    func testSanitizerPreservesLegitimateBecomes() {
        // If "becomes" is genuinely part of the transcript, leave it alone.
        let original = "water becomes ice at zero degrees"
        let cleaned = "Water becomes ice at zero degrees."

        let result = CloudProcessingSupport.sanitizePostProcessingOutput(
            original: original,
            result: cleaned
        )

        XCTAssertTrue(result.accepted, "Expected accepted, got reason: \(result.reason ?? "nil")")
        XCTAssertEqual(result.text, "Water becomes ice at zero degrees")
    }

    func testSanitizerLeavesSingleCleanedVersionUntouched() {
        let original = "what happens when you have multiple harnesses?"
        let cleaned = "What happens when you have multiple harnesses?"

        let result = CloudProcessingSupport.sanitizePostProcessingOutput(
            original: original,
            result: cleaned
        )

        XCTAssertTrue(result.accepted)
        XCTAssertEqual(result.text, cleaned)
    }

    func testEmailSanitizerRejectsInsertedClosingBlock() {
        let original = "Hey Sky, for some reason I'm not getting the option in either best promise"
        let rewritten = """
        For some reason I'm not getting the option in either Best Buy or Promise.

        Kind regards,
        Tschlossmacher.
        """

        let result = CloudProcessingSupport.sanitizePostProcessingOutput(
            original: original,
            result: rewritten,
            profile: .emailFragment
        )

        XCTAssertFalse(result.accepted)
        XCTAssertEqual(result.reason, "inserted-email-signoff")
        XCTAssertEqual(result.text, original)
    }

    func testEmailFullSanitizerRejectsInsertedGreetingWhenNotDictated() {
        let result = CloudProcessingSupport.sanitizePostProcessingOutput(
            original: "For some reason I'm not getting the option in either.",
            result: """
            Hi Skye,

            For some reason I'm not getting the option in either.
            """,
            profile: .emailFull
        )

        XCTAssertFalse(result.accepted)
        XCTAssertEqual(result.reason, "inserted-email-greeting")
    }

    func testChatCleanupStillUsesMessagePrompt() {
        let profile = CloudProcessingSupport.cleanupPromptProfile(
            appName: "Slack",
            bundleId: "com.tinyspeck.slackmacgap",
            windowTitle: "Engineering",
            browserURL: nil
        )

        XCTAssertEqual(profile, .message)
        let instruction = CloudProcessingSupport.cleanupInstruction(for: profile)
        XCTAssertTrue(
            instruction.hasPrefix(CloudProcessingSupport.messageCleanupInstruction),
            instruction
        )
        XCTAssertTrue(
            instruction.localizedCaseInsensitiveContains("preserve normal message prose"),
            instruction
        )
    }

    func testCleanupInstructionAllowsConservativeDefaultListInference() {
        let instruction = CloudProcessingSupport.cleanupInstruction(for: .default)

        XCTAssertTrue(
            instruction.localizedCaseInsensitiveContains("3 or more distinct items"),
            instruction
        )
        XCTAssertTrue(
            instruction.localizedCaseInsensitiveContains("do not use bullets for ordinary prose"),
            instruction
        )
    }

    func testCleanupInstructionIncludesRepeatedRestartCorrectionGuidance() {
        let instruction = CloudProcessingSupport.cleanupInstruction(for: .default)

        XCTAssertTrue(
            instruction.localizedCaseInsensitiveContains("Repeated restarts"),
            instruction
        )
        XCTAssertTrue(
            instruction.localizedCaseInsensitiveContains("we get a new recent mem"),
            instruction
        )
        XCTAssertTrue(
            instruction.localizedCaseInsensitiveContains("False-start lead-ins"),
            instruction
        )
        XCTAssertTrue(
            instruction.localizedCaseInsensitiveContains("and then we actually know"),
            instruction
        )
    }

    func testCleanupInstructionUsesExplicitListHint() {
        let instruction = CloudProcessingSupport.cleanupInstruction(
            for: .default,
            listIntent: .explicit
        )

        XCTAssertTrue(
            instruction.localizedCaseInsensitiveContains("speaker appears to be asking for a list"),
            instruction
        )
        XCTAssertTrue(
            instruction.localizedCaseInsensitiveContains("using \"- \""),
            instruction
        )
    }

    func testListIntentDetectsExplicitBulletRequest() {
        XCTAssertEqual(
            CloudProcessingSupport.listIntent(
                transcript: "turn this into bullets ship alpha confirm QA announce friday",
                profile: .default
            ),
            .explicit
        )
    }

    func testListIntentDoesNotTreatBulletPointAsContentRequest() {
        XCTAssertEqual(
            CloudProcessingSupport.listIntent(
                transcript: "add a bullet point system to the app",
                profile: .default
            ),
            .none
        )
    }

    func testListIntentDetectsColonFormListIntros() {
        let cases = [
            "action items: ship alpha confirm QA announce friday",
            "options: alpha beta gamma",
            "next steps: review the design and ship",
            "requirements: auth, billing, search",
            "todos: rewrite onboarding, polish settings, ship",
            "to-dos: fix flake, audit logs, retry policy",
            "action item: rewrite the prompt"
        ]

        for transcript in cases {
            XCTAssertEqual(
                CloudProcessingSupport.listIntent(
                    transcript: transcript,
                    profile: .default
                ),
                .explicit,
                transcript
            )
        }
    }

    func testListIntentIgnoresIncidentalKeywordMentions() {
        let cases = [
            "I have many options to consider before deciding",
            "the action items list looks great so far",
            "we set up requirements for the new flow",
            // Mid-clause colon mentions must not be promoted to explicit lists.
            "we have requirements: mostly around performance",
            "I see options: but mostly the obvious one"
        ]

        for transcript in cases {
            XCTAssertEqual(
                CloudProcessingSupport.listIntent(
                    transcript: transcript,
                    profile: .default
                ),
                .none,
                transcript
            )
        }
    }

    func testListIntentDetectsColonFormAfterSentenceBoundary() {
        let cases = [
            "Here is the rundown. Action items: ship alpha, confirm QA",
            "Plan for tomorrow:\nNext steps: review the design and ship"
        ]

        for transcript in cases {
            XCTAssertEqual(
                CloudProcessingSupport.listIntent(
                    transcript: transcript,
                    profile: .default
                ),
                .explicit,
                transcript
            )
        }
    }

    func testListIntentDetectsListIntroducingPhrasesBeforeColonForm() {
        let cases = [
            "Here are the action items: ship alpha, confirm QA",
            "These are the requirements: auth, billing, search",
            "The options: alpha, beta, gamma"
        ]

        for transcript in cases {
            XCTAssertEqual(
                CloudProcessingSupport.listIntent(
                    transcript: transcript,
                    profile: .default
                ),
                .explicit,
                transcript
            )
        }
    }

    func testListIntentDetectsLikelyStructuredList() {
        XCTAssertEqual(
            CloudProcessingSupport.listIntent(
                transcript: "three things we need to fix onboarding settings search and the empty state",
                profile: .default
            ),
            .likely
        )
    }

    func testListIntentDoesNotPromoteContrastiveOrdinalSentence() {
        XCTAssertEqual(
            CloudProcessingSupport.listIntent(
                transcript: "I like the first line but not the second",
                profile: .default
            ),
            .none
        )
    }

    func testListIntentDetectsPricingBreakdown() {
        XCTAssertEqual(
            CloudProcessingSupport.listIntent(
                transcript: "1 video is 1200. 3 videos cross-posted to Instagram, TikTok, and YouTube Shorts is 250 hundred. This does not include whitelisting, but it does include a many chat automation.",
                profile: .default
            ),
            .likely
        )
    }

    func testListIntentDoesNotPromoteSinglePricingSentence() {
        XCTAssertEqual(
            CloudProcessingSupport.listIntent(
                transcript: "it costs five dollars and fifty cents",
                profile: .default
            ),
            .none
        )
    }

    func testListIntentKeepsEmailConservativeWithoutExplicitRequest() {
        XCTAssertEqual(
            CloudProcessingSupport.listIntent(
                transcript: "three things I wanted to mention pricing timeline and onboarding",
                profile: .emailFragment
            ),
            .none
        )
    }

    func testCleanupSanitizerAllowsInferredBulletFormatting() {
        let original = "three things we need to fix onboarding settings search and the empty state"
        let result = CloudProcessingSupport.sanitizePostProcessingOutput(
            original: original,
            result: """
            - Fix onboarding
            - Improve settings search
            - Polish the empty state
            """
        )

        XCTAssertTrue(result.accepted, "Expected accepted, got reason: \(result.reason ?? "nil")")
        XCTAssertTrue(result.text.hasPrefix("- Fix onboarding"))
    }

    func testCleanupSanitizerRejectsUnrequestedTwoBulletSplit() {
        let original = "I like the first line but not the second"
        let result = CloudProcessingSupport.sanitizePostProcessingOutput(
            original: original,
            result: """
            I like the
            - First line but not the
            - Second.
            """
        )

        XCTAssertFalse(result.accepted)
        XCTAssertEqual(result.reason, "unrequested-bullet-list")
        XCTAssertEqual(result.text, original)
    }

    func testCleanupInstructionsKeepOnlyFinalSelfCorrection() {
        let expectedFragment = "keep only the final intended wording"

        let instructions = [
            CloudProcessingSupport.defaultCleanupInstruction,
            CloudProcessingSupport.messageCleanupInstruction,
            CloudProcessingSupport.emailFragmentCleanupInstruction,
            CloudProcessingSupport.emailFullCleanupInstruction,
        ]

        for instruction in instructions {
            XCTAssertTrue(
                instruction.localizedCaseInsensitiveContains(expectedFragment),
                instruction
            )
        }
    }

    func testCleanupInstructionsForbidNoChangesNeededCommentary() {
        let expectedFragment = #"No changes needed"#

        let instructions = [
            CloudProcessingSupport.defaultCleanupInstruction,
            CloudProcessingSupport.messageCleanupInstruction,
            CloudProcessingSupport.emailFragmentCleanupInstruction,
            CloudProcessingSupport.emailFullCleanupInstruction,
        ]

        for instruction in instructions {
            XCTAssertTrue(
                instruction.contains(expectedFragment),
                instruction
            )
        }
    }

    func testSelectionTransformSanitizerRejectsEmptyResponse() {
        let result = CloudProcessingSupport.sanitizeSelectionTransformOutput(
            selectedText: "please send the report",
            result: "   ",
            command: "make this more professional"
        )

        XCTAssertFalse(result.accepted)
        XCTAssertEqual(result.reason, "empty-output")
        XCTAssertEqual(result.text, "please send the report")
    }

    func testSelectionTransformSanitizerStripsEchoedCommand() {
        let result = CloudProcessingSupport.sanitizeSelectionTransformOutput(
            selectedText: "send me the report when you can",
            result: """
            Make this more professional:

            Please send me the report when you have a chance.
            """,
            command: "Make this more professional"
        )

        XCTAssertTrue(result.accepted, "Expected accepted, got reason: \(result.reason ?? "nil")")
        XCTAssertEqual(result.text, "Please send me the report when you have a chance.")
    }

    func testSelectionTransformSanitizerRejectsExplanation() {
        let result = CloudProcessingSupport.sanitizeSelectionTransformOutput(
            selectedText: "send me the report",
            result: "I rewrote the selected text to be more professional: Please send me the report when you have a chance.",
            command: "make this more professional"
        )

        XCTAssertFalse(result.accepted)
        XCTAssertEqual(result.reason, "transform-explanation")
    }

    func testSelectionTransformSanitizerRejectsUnexpectedTemplateExpansion() {
        let result = CloudProcessingSupport.sanitizeSelectionTransformOutput(
            selectedText: "following up on the pricing",
            result: """
            Subject: Pricing follow-up

            Hi Alex,

            Following up on the pricing.

            Best regards,
            Alex
            """,
            command: "make this clearer"
        )

        XCTAssertFalse(result.accepted)
        XCTAssertEqual(result.reason, "unexpected-template-expansion")
    }

    func testSelectionTransformSanitizerAllowsLongProRewrite() {
        let selected = String(repeating: "Original sentence. ", count: 80)
        let expanded = String(repeating: "Expanded replacement sentence with useful detail. ", count: 180)
        let policy = CloudProcessingSupport.selectionTransformLengthPolicy(
            command: "make this more detailed",
            selectedText: selected
        )

        let result = CloudProcessingSupport.sanitizeSelectionTransformOutput(
            selectedText: selected,
            result: expanded,
            command: "make this more detailed",
            lengthPolicy: policy
        )

        XCTAssertTrue(result.accepted, "Expected accepted, got reason: \(result.reason ?? "nil")")
    }

    func testSelectionTransformSanitizerStillRejectsExtremeOutput() {
        let selected = "Short note."
        let expanded = String(repeating: "Runaway replacement sentence. ", count: 4_000)
        let policy = CloudProcessingSupport.selectionTransformLengthPolicy(
            command: "make this more detailed",
            selectedText: selected
        )

        let result = CloudProcessingSupport.sanitizeSelectionTransformOutput(
            selectedText: selected,
            result: expanded,
            command: "make this more detailed",
            lengthPolicy: policy
        )

        XCTAssertFalse(result.accepted)
        XCTAssertEqual(result.reason, "too-long")
    }

    func testSelectionTransformLengthPolicyIsIntentAware() {
        let selected = String(repeating: "Draft. ", count: 100)
        let normal = CloudProcessingSupport.selectionTransformLengthPolicy(
            command: "make this better",
            selectedText: selected
        )
        let expansive = CloudProcessingSupport.selectionTransformLengthPolicy(
            command: "expand this into a full proposal",
            selectedText: selected
        )

        XCTAssertEqual(normal.intent, .normal)
        XCTAssertEqual(expansive.intent, .expansive)
        XCTAssertGreaterThan(expansive.maxOutputCharacters, normal.maxOutputCharacters)
    }

    func testSelectionTransformCommandDetectionRequiresRewriteIntent() {
        XCTAssertTrue(
            CloudProcessingSupport.looksLikeSelectionTransformCommand("rewrite this to be clearer")
        )
        XCTAssertTrue(
            CloudProcessingSupport.looksLikeSelectionTransformCommand("turn this into bullets")
        )
        XCTAssertTrue(
            CloudProcessingSupport.looksLikeSelectionTransformCommand("quick rewrite this for investors")
        )
        XCTAssertTrue(
            CloudProcessingSupport.looksLikeSelectionTransformCommand("detailed rewrite this for investors")
        )
        XCTAssertFalse(
            CloudProcessingSupport.looksLikeSelectionTransformCommand("thanks for sending this over")
        )
        XCTAssertFalse(
            CloudProcessingSupport.looksLikeSelectionTransformCommand("I agree with the selected paragraph")
        )
    }

    func testSelectionTransformCommandDetectionAllowsDetailedLongPrompt() {
        let command = "Rewrite this as a crisp investor update. Keep all metrics and dates, remove hedging, make it confident but not salesy, preserve the first-person voice, and end with one clear next step for the board."

        XCTAssertTrue(
            CloudProcessingSupport.looksLikeSelectionTransformCommand(command)
        )
    }

    func testSelectionTransformRoutingUsesAdvancedForDetailedPrompt() {
        let routing = CloudProcessingSupport.selectionTransformRouting(
            command: "Rewrite this for investors. Preserve the numbers but remove hedging, keep a confident tone, and end with a clear next step.",
            selectedText: "We maybe did pretty well this week and there are numbers in the dashboard."
        )

        XCTAssertEqual(routing.route, .advanced)
    }

    func testSelectionTransformRoutingHonorsQuickOverride() {
        let routing = CloudProcessingSupport.selectionTransformRouting(
            command: "Quick rewrite this for investors. Preserve the numbers but remove hedging, keep a confident tone, and end with a clear next step.",
            selectedText: "We maybe did pretty well this week and there are numbers in the dashboard."
        )

        XCTAssertEqual(routing.route, .quick)
        XCTAssertEqual(routing.reason, "user_forced_quick")
    }

    func testSelectionTransformRoutingUsesAdvancedForLongSelection() {
        let routing = CloudProcessingSupport.selectionTransformRouting(
            command: "rewrite this to be clearer",
            selectedText: String(repeating: "Long selected paragraph. ", count: 140)
        )

        XCTAssertEqual(routing.route, .advanced)
        XCTAssertEqual(routing.reason, "long_selection")
    }

    func testSelectionTransformStageUsesDetailedCopyForAdvancedRoute() {
        XCTAssertEqual(
            CloudProcessingSupport.selectionTransformStage(command: "rewrite this", route: .advanced),
            "Applying detailed edit..."
        )
    }

    func testSelectionTransformSanitizerAllowsRequestedBullets() {
        let result = CloudProcessingSupport.sanitizeSelectionTransformOutput(
            selectedText: "ship the alpha today confirm QA tomorrow announce friday",
            result: """
            - Ship the alpha today.
            - Confirm QA tomorrow.
            - Announce on Friday.
            """,
            command: "turn this into bullets"
        )

        XCTAssertTrue(result.accepted, "Expected accepted, got reason: \(result.reason ?? "nil")")
        XCTAssertEqual(
            result.text,
            """
            - Ship the alpha today.
            - Confirm QA tomorrow.
            - Announce on Friday.
            """
        )
    }
}
