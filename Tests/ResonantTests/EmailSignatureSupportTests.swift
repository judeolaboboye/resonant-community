import XCTest
@testable import Resonant

final class EmailSignatureSupportTests: XCTestCase {

    func testFooterLinkUsesStableUTMAttribution() throws {
        let components = try XCTUnwrap(URLComponents(string: EmailSignatureSupport.footerURLString))
        let queryItems = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "www.onresonant.com")
        XCTAssertEqual(queryItems["utm_source"], "resonant_email_signature")
        XCTAssertEqual(queryItems["utm_medium"], "email")
        XCTAssertEqual(queryItems["utm_campaign"], "sent_with_resonant")
        XCTAssertEqual(queryItems["utm_content"], "footer_link")
        XCTAssertEqual(
            EmailSignatureSupport.footerMarkdown,
            "Sent with [Resonant](\(EmailSignatureSupport.footerURLString))"
        )
    }

    func testAppliesFooterInDesktopMailContext() {
        let result = EmailSignatureSupport.applyingIfNeeded(
            to: "Thanks for the update.",
            enabled: true,
            appName: "Mail",
            bundleId: "com.apple.mail",
            windowTitle: "Re: Product update",
            browserURL: nil
        )

        XCTAssertEqual(
            result,
            "Thanks for the update.\n\n\(EmailSignatureSupport.footerMarkdown)"
        )
    }

    func testAppliesFooterInWebmailContext() {
        let result = EmailSignatureSupport.applyingIfNeeded(
            to: "Following up on this.",
            enabled: true,
            appName: "Google Chrome",
            bundleId: "com.google.Chrome",
            windowTitle: "Compose",
            browserURL: "https://mail.google.com/mail/u/0/#inbox?compose=new"
        )

        XCTAssertEqual(
            result,
            "Following up on this.\n\n\(EmailSignatureSupport.footerMarkdown)"
        )
    }

    func testAppliesFooterInTutaWebmailContext() {
        let result = EmailSignatureSupport.applyingIfNeeded(
            to: "Please review the attached notes.",
            enabled: true,
            appName: "Firefox",
            bundleId: "org.mozilla.firefox",
            windowTitle: "Compose",
            browserURL: "https://app.tuta.com/mail"
        )

        XCTAssertEqual(
            result,
            "Please review the attached notes.\n\n\(EmailSignatureSupport.footerMarkdown)"
        )
    }

    func testAppliesFooterInThunderbirdContext() {
        let result = EmailSignatureSupport.applyingIfNeeded(
            to: "Thanks, sending the draft now.",
            enabled: true,
            appName: "Thunderbird",
            bundleId: "org.mozilla.thunderbird",
            windowTitle: "Write: Project update",
            browserURL: nil
        )

        XCTAssertEqual(
            result,
            "Thanks, sending the draft now.\n\n\(EmailSignatureSupport.footerMarkdown)"
        )
    }

    func testDoesNotApplyOutsideEmailContext() {
        let result = EmailSignatureSupport.applyingIfNeeded(
            to: "Please review the PR.",
            enabled: true,
            appName: "Slack",
            bundleId: "com.tinyspeck.slackmacgap",
            windowTitle: "Engineering",
            browserURL: nil
        )

        XCTAssertEqual(result, "Please review the PR.")
    }

    func testDoesNotApplyFooterInEmailSubjectField() {
        let result = EmailSignatureSupport.applyingIfNeeded(
            to: "Project update",
            enabled: true,
            appName: "Mail",
            bundleId: "com.apple.mail",
            windowTitle: "Compose",
            browserURL: nil,
            emailMode: .fullEmail,
            focusedFieldContext: EmailFocusedFieldContext(
                role: "AXTextField",
                subrole: nil,
                title: "Subject",
                placeholderValue: "Subject",
                identifier: nil,
                description: nil,
                help: nil
            )
        )

        XCTAssertEqual(result, "Project update")
    }

    func testAppliesFooterInEmailBodyTextArea() {
        let result = EmailSignatureSupport.applyingIfNeeded(
            to: "Thanks for sending this over.",
            enabled: true,
            appName: "Mail",
            bundleId: "com.apple.mail",
            windowTitle: "Compose",
            browserURL: nil,
            emailMode: .fullEmail,
            focusedFieldContext: EmailFocusedFieldContext(
                role: "AXTextArea",
                subrole: nil,
                title: nil,
                placeholderValue: "Message body",
                identifier: nil,
                description: nil,
                help: nil
            )
        )

        XCTAssertEqual(
            result,
            "Thanks for sending this over.\n\n\(EmailSignatureSupport.footerMarkdown)"
        )
    }

    func testFooterDecisionReportsAppliedBodyField() {
        let decision = EmailSignatureSupport.footerDecision(
            to: "Thanks for sending this over.",
            enabled: true,
            appName: "Mail",
            bundleId: "com.apple.mail",
            windowTitle: "Compose",
            browserURL: nil,
            emailMode: .fullEmail,
            focusedFieldContext: EmailFocusedFieldContext(
                role: "AXTextArea",
                subrole: nil,
                title: nil,
                placeholderValue: "Message body",
                identifier: nil,
                description: nil,
                help: nil
            )
        )

        XCTAssertEqual(decision.outcome, .applied)
        XCTAssertEqual(decision.reason, .applied)
        XCTAssertEqual(decision.emailMode, .fullEmail)
        XCTAssertTrue(decision.isEmailContext)
        XCTAssertTrue(decision.isLikelyEmailBodyField)
        XCTAssertFalse(decision.textAlreadyHasFooter)
        XCTAssertFalse(decision.fieldAlreadyHasFooter)
    }

    func testFooterDecisionReportsSubjectFieldSkip() {
        let decision = EmailSignatureSupport.footerDecision(
            to: "Project update",
            enabled: true,
            appName: "Mail",
            bundleId: "com.apple.mail",
            windowTitle: "Compose",
            browserURL: nil,
            emailMode: .fullEmail,
            focusedFieldContext: EmailFocusedFieldContext(
                role: "AXTextField",
                subrole: nil,
                title: "Subject",
                placeholderValue: "Subject",
                identifier: nil,
                description: nil,
                help: nil
            )
        )

        XCTAssertEqual(decision.outcome, .skipped)
        XCTAssertEqual(decision.reason, .nonBodyField)
        XCTAssertTrue(decision.isEmailContext)
        XCTAssertFalse(decision.isLikelyEmailBodyField)
    }

    func testDoesNotApplyFooterToEmailFragments() {
        let result = EmailSignatureSupport.applyingIfNeeded(
            to: "One more thing before I send this.",
            enabled: true,
            appName: "Google Chrome",
            bundleId: "com.google.Chrome",
            windowTitle: "Compose",
            browserURL: "https://mail.google.com/mail/u/0/#inbox?compose=new",
            emailMode: .fragment
        )

        XCTAssertEqual(result, "One more thing before I send this.")
    }

    func testAppliesFooterToCompleteEmailMode() {
        let result = EmailSignatureSupport.applyingIfNeeded(
            to: """
            Hi Priya,

            Thanks for the update.

            Kind regards,
            Alex
            """,
            enabled: true,
            appName: "Google Chrome",
            bundleId: "com.google.Chrome",
            windowTitle: "Compose",
            browserURL: "https://mail.google.com/mail/u/0/#inbox?compose=new",
            emailMode: .fullEmail
        )

        XCTAssertEqual(
            result,
            """
            Hi Priya,

            Thanks for the update.

            Kind regards,
            Alex

            \(EmailSignatureSupport.footerMarkdown)
            """
        )
    }

    func testDoesNotDuplicateExistingFooter() {
        let result = EmailSignatureSupport.applyingIfNeeded(
            to: "Thanks.\n\nSent with [Resonant](https://onresonant.com)",
            enabled: true,
            appName: "Mail",
            bundleId: "com.apple.mail",
            windowTitle: "Draft",
            browserURL: nil
        )

        XCTAssertEqual(
            result,
            "Thanks.\n\nSent with [Resonant](https://onresonant.com)"
        )
    }

    func testDoesNotDuplicateWhenFieldAlreadyHasSignature() {
        let result = EmailSignatureSupport.applyingIfNeeded(
            to: "One more thing — the deadline moved to Friday.",
            enabled: true,
            appName: "Mail",
            bundleId: "com.apple.mail",
            windowTitle: "Re: Project update",
            browserURL: nil,
            existingFieldContent: "Thanks for the update.\n\nSent with [Resonant](https://onresonant.com)"
        )

        XCTAssertEqual(
            result,
            "One more thing — the deadline moved to Friday."
        )
    }

    func testAppliesFooterWhenFieldHasNoSignature() {
        let result = EmailSignatureSupport.applyingIfNeeded(
            to: "Following up on our call.",
            enabled: true,
            appName: "Mail",
            bundleId: "com.apple.mail",
            windowTitle: "Re: Call notes",
            browserURL: nil,
            existingFieldContent: "Hey team,"
        )

        XCTAssertEqual(
            result,
            "Following up on our call.\n\n\(EmailSignatureSupport.footerMarkdown)"
        )
    }

    func testRemovesDuplicateClosingWhenFieldAlreadyHasOne() {
        let result = EmailSignatureSupport.removingDuplicateClosingIfNeeded(
            from: """
            I just took another look. Unfortunately, I don't see the option in either.

            Kind regards,
            Tschlossmacher
            """,
            appName: "Mail",
            bundleId: "com.apple.mail",
            windowTitle: "Draft",
            browserURL: nil,
            existingFieldContent: """
            Hey Skye,

            Existing draft body.

            Kind regards,
            Tschlossmacher
            """
        )

        XCTAssertEqual(
            result,
            "I just took another look. Unfortunately, I don't see the option in either."
        )
    }

    func testKeepsClosingWhenFieldDoesNotAlreadyHaveOne() {
        let result = EmailSignatureSupport.removingDuplicateClosingIfNeeded(
            from: """
            I just took another look. Unfortunately, I don't see the option in either.

            Kind regards,
            Tschlossmacher
            """,
            appName: "Mail",
            bundleId: "com.apple.mail",
            windowTitle: "Draft",
            browserURL: nil,
            existingFieldContent: "Hey Skye,"
        )

        XCTAssertEqual(
            result,
            """
            I just took another look. Unfortunately, I don't see the option in either.

            Kind regards,
            Tschlossmacher
            """
        )
    }

    func testFragmentModeRemovesGreetingAndClosingEnvelope() {
        let result = EmailSignatureSupport.normalizeDictatedEmailText(
            """
            Hi Skye,

            I just took another look. Unfortunately, I don't see the option in either.

            Kind regards,
            Alex
            """,
            mode: .fragment,
            fallbackSenderName: "Alex",
            existingFieldContent: "Existing draft body"
        )

        XCTAssertEqual(
            result,
            "I just took another look. Unfortunately, I don't see the option in either."
        )
    }

    func testFullEmailModeFormatsInlineClosingWithFallbackSenderName() {
        let result = EmailSignatureSupport.normalizeDictatedEmailText(
            "Hi Skye, I just took another look. Unfortunately, I don't see the option in either. Kind regards",
            mode: .fullEmail,
            fallbackSenderName: "Alex"
        )

        XCTAssertEqual(
            result,
            """
            Hi Skye,

            I just took another look. Unfortunately, I don't see the option in either.

            Kind regards,
            Alex
            """
        )
    }

    func testFullEmailModeMovesGreetingOntoItsOwnLine() {
        let result = EmailSignatureSupport.normalizeDictatedEmailText(
            "Hey Alice, thank you for your message. I'm doing short form content right now.",
            mode: .fullEmail,
            fallbackSenderName: "Alex"
        )

        XCTAssertEqual(
            result,
            """
            Hey Alice,

            Thank you for your message. I'm doing short form content right now.
            """
        )
    }

    func testFullEmailModeRemovesRedundantInlineClosingBeforeClosingBlock() {
        let result = EmailSignatureSupport.normalizeDictatedEmailText(
            """
            Hey Alice, Thank you for your message. Please find my rates available here. Kind regards, Alex.

            Kind regards,
            Alex
            """,
            mode: .fullEmail,
            fallbackSenderName: "Alex"
        )

        XCTAssertEqual(
            result,
            """
            Hey Alice,

            Thank you for your message.

            Please find my rates available here.

            Kind regards,
            Alex
            """
        )
    }

    func testSignoffOnlyUsesFallbackSenderName() {
        let result = EmailSignatureSupport.normalizeDictatedEmailText(
            "Kind regards",
            mode: .signoffOnly,
            fallbackSenderName: "Alex"
        )

        XCTAssertEqual(
            result,
            """
            Kind regards,
            Alex
            """
        )
    }

    func testFullEmailModeFormatsPeriodGreetingAndLoveClosing() {
        let result = EmailSignatureSupport.normalizeDictatedEmailText(
            "Hey Grandma. I wanted to wish you a happy birthday. Sending good health and smiles from home. Love, Alex.",
            mode: .fullEmail,
            fallbackSenderName: "Alex"
        )

        XCTAssertEqual(
            result,
            """
            Hey Grandma,

            I wanted to wish you a happy birthday. Sending good health and smiles from home.

            Love,
            Alex
            """
        )
    }

    func testFullEmailModeDoesNotTreatBodyLoveAsClosing() {
        let result = EmailSignatureSupport.normalizeDictatedEmailText(
            "Hi Mom. You should know how much I love Sarah.",
            mode: .fullEmail,
            fallbackSenderName: "Alex"
        )

        XCTAssertEqual(
            result,
            """
            Hi Mom,

            You should know how much I love Sarah.
            """
        )
    }

    func testFullEmailModeRecognizesLoveClosingWithoutGreeting() {
        let result = EmailSignatureSupport.normalizeDictatedEmailText(
            "Just thinking of you today. Love, Alex",
            mode: .fullEmail,
            fallbackSenderName: "Alex"
        )

        XCTAssertEqual(
            result,
            """
            Just thinking of you today.

            Love,
            Alex
            """
        )
    }

    func testFullEmailModeRecognizesAllTheBestClosing() {
        let result = EmailSignatureSupport.normalizeDictatedEmailText(
            "Hi Sarah, I've sent the contract over for review. All the best, Alex.",
            mode: .fullEmail,
            fallbackSenderName: "Alex"
        )

        XCTAssertEqual(
            result,
            """
            Hi Sarah,

            I've sent the contract over for review.

            All the best,
            Alex
            """
        )
    }

    func testFullEmailModeRecognizesTakeCareClosing() {
        let result = EmailSignatureSupport.normalizeDictatedEmailText(
            "Hey Mom. Hope school is going well. Take care, Alex.",
            mode: .fullEmail,
            fallbackSenderName: "Alex"
        )

        XCTAssertEqual(
            result,
            """
            Hey Mom,

            Hope school is going well.

            Take care,
            Alex
            """
        )
    }

    func testFullEmailModeRecognizesWarmlyWithComma() {
        let result = EmailSignatureSupport.normalizeDictatedEmailText(
            "Hi friends. Thanks for the lovely evening. Warmly, Alex.",
            mode: .fullEmail,
            fallbackSenderName: "Alex"
        )

        XCTAssertEqual(
            result,
            """
            Hi friends,

            Thanks for the lovely evening.

            Warmly,
            Alex
            """
        )
    }

    func testFullEmailModeBestRequiresCommaForClosing() {
        let result = EmailSignatureSupport.normalizeDictatedEmailText(
            "Hi Sarah. I think this option is best. Hope it works for you.",
            mode: .fullEmail,
            fallbackSenderName: "Alex"
        )

        XCTAssertEqual(
            result,
            """
            Hi Sarah,

            I think this option is best. Hope it works for you.
            """
        )
    }

    func testFullEmailModeRecognizesBestWithCommaAsClosing() {
        let result = EmailSignatureSupport.normalizeDictatedEmailText(
            "Hi Sarah. The proposal is attached. Best, Alex.",
            mode: .fullEmail,
            fallbackSenderName: "Alex"
        )

        XCTAssertEqual(
            result,
            """
            Hi Sarah,

            The proposal is attached.

            Best,
            Alex
            """
        )
    }

    func testFullEmailModeRecognizesRecipientOnlyGreeting() {
        let result = EmailSignatureSupport.normalizeDictatedEmailText(
            "John, please review the attached contract by Friday.",
            mode: .fullEmail,
            fallbackSenderName: "Alex"
        )

        XCTAssertEqual(
            result,
            """
            John,

            Please review the attached contract by Friday.
            """
        )
    }

    func testFullEmailModeRecognizesTwoWordRecipientName() {
        let result = EmailSignatureSupport.normalizeDictatedEmailText(
            "Mary Jane, thank you for your message.",
            mode: .fullEmail,
            fallbackSenderName: "Alex"
        )

        XCTAssertEqual(
            result,
            """
            Mary Jane,

            Thank you for your message.
            """
        )
    }

    func testFullEmailModeDoesNotTreatSorryAsRecipientGreeting() {
        let result = EmailSignatureSupport.normalizeDictatedEmailText(
            "Sorry, I was late getting back to you. Will follow up tomorrow.",
            mode: .fullEmail,
            fallbackSenderName: "Alex"
        )

        XCTAssertEqual(
            result,
            "Sorry, I was late getting back to you. Will follow up tomorrow."
        )
    }

    func testFullEmailModeDoesNotTreatYesAsRecipientGreeting() {
        let result = EmailSignatureSupport.normalizeDictatedEmailText(
            "Yes, that timeline works for me.",
            mode: .fullEmail,
            fallbackSenderName: "Alex"
        )

        XCTAssertEqual(
            result,
            "Yes, that timeline works for me."
        )
    }

    func testFullEmailModeDoesNotTreatHonestlyAsRecipientGreeting() {
        let result = EmailSignatureSupport.normalizeDictatedEmailText(
            "Honestly, I think we should reconsider.",
            mode: .fullEmail,
            fallbackSenderName: "Alex"
        )

        XCTAssertEqual(
            result,
            "Honestly, I think we should reconsider."
        )
    }

    func testFullEmailModeRecipientGreetingWithLoveClosing() {
        let result = EmailSignatureSupport.normalizeDictatedEmailText(
            "Mom, hope school is going well. Love, Alex.",
            mode: .fullEmail,
            fallbackSenderName: "Alex"
        )

        XCTAssertEqual(
            result,
            """
            Mom,

            Hope school is going well.

            Love,
            Alex
            """
        )
    }

    func testFullEmailModeRecognizesGoodMorningGreeting() {
        let result = EmailSignatureSupport.normalizeDictatedEmailText(
            "Good morning Sarah, attaching the latest deck for review. Best regards, Alex.",
            mode: .fullEmail,
            fallbackSenderName: "Alex"
        )

        XCTAssertEqual(
            result,
            """
            Good morning Sarah,

            Attaching the latest deck for review.

            Best regards,
            Alex
            """
        )
    }

    func testFullEmailModeRecognizesGreetingWithCommaAfterSalutation() {
        let result = EmailSignatureSupport.normalizeDictatedEmailText(
            "Good morning, Sarah, attaching the latest deck for review. Best regards, Alex.",
            mode: .fullEmail,
            fallbackSenderName: "Alex"
        )

        XCTAssertEqual(
            result,
            """
            Good morning Sarah,

            Attaching the latest deck for review.

            Best regards,
            Alex
            """
        )
    }

    func testFullEmailModeRecognizesHowdyGreeting() {
        let result = EmailSignatureSupport.normalizeDictatedEmailText(
            "Howdy John. Hope all is well with the team.",
            mode: .fullEmail,
            fallbackSenderName: "Alex"
        )

        XCTAssertEqual(
            result,
            """
            Howdy John,

            Hope all is well with the team.
            """
        )
    }

    func testFullEmailModeRecognizesGreetingWithMissingComma() {
        let result = EmailSignatureSupport.normalizeDictatedEmailText(
            "Hi Sarah I wanted to follow up on our call yesterday. Best, Alex.",
            mode: .fullEmail,
            fallbackSenderName: "Alex"
        )

        XCTAssertEqual(
            result,
            """
            Hi Sarah,

            I wanted to follow up on our call yesterday.

            Best,
            Alex
            """
        )
    }

    func testFullEmailModeRecognizesHugsClosing() {
        let result = EmailSignatureSupport.normalizeDictatedEmailText(
            "Mom, hope you're doing well. Hugs, Alex.",
            mode: .fullEmail,
            fallbackSenderName: "Alex"
        )

        XCTAssertEqual(
            result,
            """
            Mom,

            Hope you're doing well.

            Hugs,
            Alex
            """
        )
    }

    func testFullEmailModeRecognizesWithLoveClosing() {
        let result = EmailSignatureSupport.normalizeDictatedEmailText(
            "Hey Mom, just thinking of you today. With love, Alex.",
            mode: .fullEmail,
            fallbackSenderName: "Alex"
        )

        XCTAssertEqual(
            result,
            """
            Hey Mom,

            Just thinking of you today.

            With love,
            Alex
            """
        )
    }

    func testFullEmailModeBodyHugsDoesNotTriggerClosing() {
        let result = EmailSignatureSupport.normalizeDictatedEmailText(
            "Hi Mom. The kids send hugs and kisses to grandma.",
            mode: .fullEmail,
            fallbackSenderName: "Alex"
        )

        XCTAssertEqual(
            result,
            """
            Hi Mom,

            The kids send hugs and kisses to grandma.
            """
        )
    }

    func testFragmentModeStripsRecipientGreeting() {
        let result = EmailSignatureSupport.normalizeDictatedEmailText(
            "John, please review the attached contract.",
            mode: .fragment,
            fallbackSenderName: "Alex",
            existingFieldContent: "Existing draft body"
        )

        XCTAssertEqual(
            result,
            "please review the attached contract."
        )
    }

    func testFullEmailModeMovesTrailingThoughtAheadOfInlineClosing() {
        let result = EmailSignatureSupport.normalizeDictatedEmailText(
            "Hey Ted, Let's go for 230 ET. Best regards, Alex. That way I can start filming tomorrow if we can solve it.",
            mode: .fullEmail,
            fallbackSenderName: "Alex"
        )

        XCTAssertEqual(
            result,
            """
            Hey Ted,

            Let's go for 230 ET. That way I can start filming tomorrow if we can solve it.

            Best regards,
            Alex
            """
        )
    }

    func testFullEmailModeMovesTrailingThoughtAheadOfStrictInlineClosing() {
        let result = EmailSignatureSupport.normalizeDictatedEmailText(
            "Hi Sarah. The proposal is attached for review. Best, Alex. Let me know if you want changes.",
            mode: .fullEmail,
            fallbackSenderName: "Alex"
        )

        XCTAssertEqual(
            result,
            """
            Hi Sarah,

            The proposal is attached for review.

            Let me know if you want changes.

            Best,
            Alex
            """
        )
    }

    func testFullEmailModeKeepsBestRegardsPhraseInBodyWhenMidSentence() {
        let result = EmailSignatureSupport.normalizeDictatedEmailText(
            "Hi Mike. Send my best regards, Sarah. We can close tomorrow.",
            mode: .fullEmail,
            fallbackSenderName: "Alex"
        )

        XCTAssertTrue(
            result.contains("Send my best regards, Sarah."),
            "expected mid-sentence 'best regards' kept in body, got: \(result)"
        )
        XCTAssertFalse(
            result.contains("Best regards,\nSarah"),
            "expected no closing block to be invented, got: \(result)"
        )
    }

    func testFullEmailModeRecognizesClosingMisheardAsToSenderName() {
        let result = EmailSignatureSupport.normalizeDictatedEmailText(
            "Hi Jamie, Thank you. I'm glad we were able to make it work. I'm looking forward to collaborating with you and the Nimbus team on this campaign. Allow me to review the brief 1 last time, sign up for partner.example.com and move this forward. I will follow up if I have any questions. Best regards to Alex.",
            mode: .fullEmail,
            fallbackSenderName: "Alex"
        )

        XCTAssertTrue(
            result.contains("Best regards,\nAlex"),
            "expected misheard 'Best regards to Alex' normalized as closing, got: \(result)"
        )
        XCTAssertFalse(
            result.contains("Best regards to Alex"),
            "expected malformed closing removed from body, got: \(result)"
        )
    }

    func testFullEmailModePreservesExplicitBulletBlockWithHeader() {
        let result = EmailSignatureSupport.normalizeDictatedEmailText(
            """
            Hi Priya, Here are the updates:
            - alpha is ready
            - QA starts tomorrow
            - launch is Friday
            Best regards, Alex.
            """,
            mode: .fullEmail,
            fallbackSenderName: "Alex"
        )

        XCTAssertEqual(
            result,
            """
            Hi Priya,

            Here are the updates:

            - Alpha is ready
            - QA starts tomorrow
            - Launch is Friday

            Best regards,
            Alex
            """
        )
    }

    func testFullEmailModeMovesTrailingBulletAdditionsAheadOfInlineClosing() {
        let result = EmailSignatureSupport.normalizeDictatedEmailText(
            """
            Hi Ted. Let's go for 230 ET. Best regards, Alex.
            - send the links
            - confirm timing
            """,
            mode: .fullEmail,
            fallbackSenderName: "Alex"
        )

        XCTAssertEqual(
            result,
            """
            Hi Ted,

            Let's go for 230 ET.

            - Send the links
            - Confirm timing

            Best regards,
            Alex
            """
        )
    }

    func testFullEmailModeDoesNotBulletizeOrdinaryCommaProse() {
        let result = EmailSignatureSupport.normalizeDictatedEmailText(
            "Hi Sarah. We need alpha, beta, gamma, and launch by Friday. Best regards, Alex.",
            mode: .fullEmail,
            fallbackSenderName: "Alex"
        )

        XCTAssertEqual(
            result,
            """
            Hi Sarah,

            We need alpha, beta, gamma, and launch by Friday.

            Best regards,
            Alex
            """
        )
    }

    func testFullEmailModePicksLastClosingNotFirstInlineClosingLikePhrase() {
        let result = EmailSignatureSupport.normalizeDictatedEmailText(
            "Hi Mike. Thanks again, Bob, for the intro. Best regards, Alex. Let me know if you need anything.",
            mode: .fullEmail,
            fallbackSenderName: "Alex"
        )

        XCTAssertTrue(
            result.contains("Best regards,\nAlex"),
            "expected sender's actual closing detected, got: \(result)"
        )
        XCTAssertFalse(
            result.contains("Thanks again,\nBob"),
            "expected earlier 'thanks again' phrase not promoted to closing, got: \(result)"
        )
    }

    func testFullEmailModePrefersLastSenderMatchingClosingWhenLaterBodyMentionsAnotherSignoff() {
        let result = EmailSignatureSupport.normalizeDictatedEmailText(
            "Hi Sarah. Best regards, Alex. In the old template it says this. Best regards, Bob. That line is outdated.",
            mode: .fullEmail,
            fallbackSenderName: "Alex"
        )

        XCTAssertEqual(
            result,
            """
            Hi Sarah,

            In the old template it says this. Best regards, Bob. That line is outdated.

            Best regards,
            Alex
            """
        )
    }

    func testFullEmailModeKeepsThankYouOpenerInBody() {
        let result = EmailSignatureSupport.normalizeDictatedEmailText(
            "Thank you, Alex. I can take it from here.",
            mode: .fullEmail,
            fallbackSenderName: "Alex"
        )

        XCTAssertTrue(
            result.contains("Thank you, Alex."),
            "expected 'Thank you' opener preserved in body, got: \(result)"
        )
        XCTAssertFalse(
            result.contains("Thank you,\nAlex"),
            "expected 'Thank you' not reformatted as closing block, got: \(result)"
        )
    }

    func testFullEmailModeIgnoresPSAfterClosingButPreservesBody() {
        // Tightened name capture stops at "Alex" instead of swallowing
        // "Alex. P.S. Don't forget dinner." as a single 33-char name.
        // The trailing P.S. lives in the body since end-anchor blocks the match.
        let result = EmailSignatureSupport.normalizeDictatedEmailText(
            "Hi Sarah. The proposal is attached. Best, Alex. P.S. Don't forget dinner.",
            mode: .fullEmail,
            fallbackSenderName: "Alex"
        )

        XCTAssertTrue(result.contains("P.S. Don't forget dinner."), "expected P.S. preserved in body, got: \(result)")
        XCTAssertTrue(result.contains("The proposal is attached."), "expected body preserved, got: \(result)")
        XCTAssertFalse(
            result.contains("Best,\nAlex"),
            "expected inline closing to stay untouched when followed by P.S., got: \(result)"
        )
    }

    func testSignoffOnlyNoOpsWhenFieldAlreadyHasClosing() {
        let result = EmailSignatureSupport.normalizeDictatedEmailText(
            "Kind regards",
            mode: .signoffOnly,
            fallbackSenderName: "Alex",
            existingFieldContent: """
            Existing draft body.

            Kind regards,
            Alex
            """
        )

        XCTAssertEqual(result, "")
    }
}
