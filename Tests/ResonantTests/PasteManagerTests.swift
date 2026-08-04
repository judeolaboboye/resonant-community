import AppKit
import CoreGraphics
import XCTest
@testable import Resonant

final class PasteManagerTests: XCTestCase {

    func testDeliveryOutcomeSeparatesPasteFromAutoSend() {
        let pastedOnly = PasteManager.DeliveryOutcome(
            delivered: true,
            sent: false,
            receipt: nil
        )
        let sent = PasteManager.DeliveryOutcome(
            delivered: true,
            sent: true,
            receipt: nil
        )

        XCTAssertTrue(pastedOnly.delivered)
        XCTAssertFalse(pastedOnly.sent)
        XCTAssertTrue(sent.delivered)
        XCTAssertTrue(sent.sent)
        XCTAssertNotEqual(pastedOnly.deliveryAttemptID, sent.deliveryAttemptID)
        XCTAssertNil(pastedOnly.requestedText)
        XCTAssertNil(pastedOnly.effectiveInsertedText)
    }

    /// The system Accessibility sheet is raised at most once per launch. A user
    /// who dismissed it once used to get a fresh sheet on every dictation; the
    /// copied-to-clipboard fallback toast carries the remediation copy instead.
    func testAccessibilitySheetIsRaisedAtMostOncePerLaunch() {
        let first = PasteManager.accessibilityTrustDecision(
            previouslyGranted: false,
            hasPromptedThisLaunch: false
        )
        XCTAssertTrue(first.presentsSystemPrompt)
        XCTAssertEqual(first.failure, .accessibilityPermissionRequired)

        let second = PasteManager.accessibilityTrustDecision(
            previouslyGranted: false,
            hasPromptedThisLaunch: true
        )
        XCTAssertFalse(second.presentsSystemPrompt)
        XCTAssertEqual(second.failure, .accessibilityPermissionRequired)
    }

    /// A grant that existed and vanished is a post-update signature invalidation,
    /// which needs its own remediation copy — and still gets one re-prompt.
    func testStaleGrantKeepsItsOwnFailureAndFirstPrompt() {
        let stale = PasteManager.accessibilityTrustDecision(
            previouslyGranted: true,
            hasPromptedThisLaunch: false
        )
        XCTAssertEqual(stale.failure, .accessibilityPermissionStale)
        XCTAssertTrue(stale.presentsSystemPrompt)

        let staleAfterPrompt = PasteManager.accessibilityTrustDecision(
            previouslyGranted: true,
            hasPromptedThisLaunch: true
        )
        XCTAssertEqual(staleAfterPrompt.failure, .accessibilityPermissionStale)
        XCTAssertFalse(staleAfterPrompt.presentsSystemPrompt)
    }

    @MainActor
    func testNoOpDeliveryStillCreatesOneAttemptAndCarriesRequestedText() async {
        let outcome = await PasteManager().deliverWithOutcome(
            text: "requested text",
            copyToClipboard: false,
            autoPaste: false,
            autoSend: false,
            targetApplication: nil
        )

        XCTAssertTrue(outcome.delivered)
        XCTAssertEqual(outcome.requestedText, "requested text")
        XCTAssertNil(outcome.effectiveInsertedText)
    }

    func testDeliveryOutcomeCarriesPostSpacingPostMarkdownEffectiveText() throws {
        let requestedText = "[Open docs](https://example.com)"
        let smartSpacedText = PasteManager.adjustTextForInsertionContext(
            requestedText,
            textBeforeCursor: "Existing text",
            continuesFromOurInsertion: true
        )
        let effectiveText = PasteManager.effectiveInsertedPlainText(
            afterSmartSpacing: smartSpacedText
        )
        let anchoredInsertion = try XCTUnwrap(PasteManager.makeUTF16InsertionAnchor(
            baselineValue: "Existing text tail",
            selectedRange: SelectionRange(location: 13, length: 0),
            postDeliveryValue: "Existing text Open docs tail"
        ))
        let fingerprint = ContextTargetFingerprint(
            role: kAXTextAreaRole,
            subrole: "AXStandardTextArea",
            isSensitiveInput: false,
            identifierToken: "composer",
            titleToken: "message",
            descriptionToken: nil,
            placeholderToken: "write",
            helpToken: nil,
            frameBucket: "1:2:3:4",
            selectedRangeBucket: "0:0"
        )
        let attribution = try XCTUnwrap(PasteManager.makeDeliveryAttribution(
            targetProcessIdentifier: 42,
            targetBundleIdentifier: "com.example.editor",
            targetFingerprint: fingerprint,
            anchor: anchoredInsertion.anchor,
            preDeliveryFieldUTF16Length: 18
        ))
        let attemptID = UUID()

        let outcome = PasteManager.DeliveryOutcome(
            delivered: true,
            receipt: nil,
            deliveryAttemptID: attemptID,
            requestedText: requestedText,
            effectiveInsertedText: effectiveText,
            targetObservedSettledText: anchoredInsertion.targetObservedInsertedText,
            deliveryAttribution: attribution
        )

        XCTAssertEqual(smartSpacedText, " [Open docs](https://example.com)")
        XCTAssertEqual(outcome.deliveryAttemptID, attemptID)
        XCTAssertEqual(outcome.requestedText, requestedText)
        XCTAssertEqual(outcome.effectiveInsertedText, " Open docs")
        XCTAssertEqual(outcome.targetObservedSettledText, " Open docs")
        XCTAssertNil(outcome.receipt)
        XCTAssertEqual(outcome.deliveryAttribution, attribution)
        XCTAssertEqual(outcome.targetProcessIdentifier, 42)
        XCTAssertEqual(outcome.targetBundleIdentifier, "com.example.editor")
    }

    func testStyleResolverUsesEffectiveThenPrefersTargetObservedInsertionBaseline() {
        let provenance = StyleApplicationProvenance(
            openingCase: StyleRuleApplication(.sentenceCase, disposition: .alreadyConformed),
            trailingPeriod: StyleRuleApplication(.require, disposition: .alreadyConformed)
        )
        let effectiveOnly = PasteManager.DeliveryOutcome(
            delivered: true,
            receipt: nil,
            requestedText: "Hello.",
            effectiveInsertedText: " hello."
        )
        let effectivePolicy = StyleDeliveryProvenanceResolver.appliedPolicyAtDelivery(
            provenance: provenance,
            localPostProcessedText: "Hello.",
            resolvedText: "Hello.",
            requestedDeliveryText: "Hello.",
            stageTrace: .localOnly,
            deliveryOutcome: effectiveOnly
        )
        XCTAssertNil(effectivePolicy.openingCase, "smart spacing lowercased the actual opening")
        XCTAssertEqual(effectivePolicy.trailingPeriod, .require)

        let observedWins = PasteManager.DeliveryOutcome(
            delivered: true,
            receipt: nil,
            requestedText: "Hello.",
            effectiveInsertedText: " hello.",
            targetObservedSettledText: " Hello?"
        )
        let observedPolicy = StyleDeliveryProvenanceResolver.appliedPolicyAtDelivery(
            provenance: provenance,
            localPostProcessedText: "Hello.",
            resolvedText: "Hello.",
            requestedDeliveryText: "Hello.",
            stageTrace: .localOnly,
            deliveryOutcome: observedWins
        )
        XCTAssertEqual(observedPolicy.openingCase, .sentenceCase)
        XCTAssertNil(observedPolicy.trailingPeriod, "observed question invalidates effective period")

        let noInsertionBaseline = PasteManager.DeliveryOutcome(
            delivered: true,
            receipt: nil,
            requestedText: "Hello."
        )
        XCTAssertEqual(
            StyleDeliveryProvenanceResolver.appliedPolicyAtDelivery(
                provenance: provenance,
                localPostProcessedText: "Hello.",
                resolvedText: "Hello.",
                requestedDeliveryText: "Hello.",
                stageTrace: .localOnly,
                deliveryOutcome: noInsertionBaseline
            ),
            .none
        )
    }

    func testSyntheticInputRequiresResolvedTargetToRemainFrontmost() {
        XCTAssertTrue(PasteManager.syntheticInputTargetMatches(
            expectedProcessIdentifier: 42,
            frontmostProcessIdentifier: 42
        ))
        XCTAssertFalse(PasteManager.syntheticInputTargetMatches(
            expectedProcessIdentifier: 42,
            frontmostProcessIdentifier: 7
        ))
        XCTAssertFalse(PasteManager.syntheticInputTargetMatches(
            expectedProcessIdentifier: 42,
            frontmostProcessIdentifier: nil
        ))
    }

    func testCorrectionReceiptRequiresObservedFieldChange() {
        XCTAssertFalse(PasteManager.shouldIssueCorrectionReceipt(
            baselineValue: "selected text",
            postDeliveryValue: "selected text"
        ))
        XCTAssertTrue(PasteManager.shouldIssueCorrectionReceipt(
            baselineValue: "selected text",
            postDeliveryValue: "dictated text"
        ))
    }

    func testPasteVerificationDelayExperimentVariantsOnlyReduceDelay() {
        XCTAssertEqual(
            PasteManager.adjustedVerificationDelayMilliseconds(
                baseMilliseconds: 120,
                variant: "control"
            ),
            120
        )
        XCTAssertEqual(
            PasteManager.adjustedVerificationDelayMilliseconds(
                baseMilliseconds: 120,
                variant: "short_80ms"
            ),
            80
        )
        XCTAssertEqual(
            PasteManager.adjustedVerificationDelayMilliseconds(
                baseMilliseconds: 120,
                variant: "short_60ms"
            ),
            60
        )
        XCTAssertEqual(
            PasteManager.adjustedVerificationDelayMilliseconds(
                baseMilliseconds: 120,
                variant: "aggressive_40ms"
            ),
            40
        )
        XCTAssertEqual(
            PasteManager.adjustedVerificationDelayMilliseconds(
                baseMilliseconds: 120,
                variant: "no_wait"
            ),
            0
        )
        XCTAssertEqual(
            PasteManager.adjustedVerificationDelayMilliseconds(
                baseMilliseconds: 40,
                variant: "short_80ms"
            ),
            40
        )
    }

    @MainActor
    func testCopyIfEnabledLeavesClipboardUntouchedWhenDisabled() {
        let pasteboard = NSPasteboard.general
        let snapshot = snapshotPasteboard(pasteboard)
        defer { restorePasteboard(snapshot, to: pasteboard) }

        pasteboard.clearContents()
        pasteboard.setString("keep existing", forType: .string)

        let manager = PasteManager()
        XCTAssertFalse(manager.copyIfEnabled(text: "new dictation", isEnabled: false))
        XCTAssertEqual(pasteboard.string(forType: .string), "keep existing")
    }

    @MainActor
    func testCopyIfEnabledWritesClipboardWhenEnabled() {
        let pasteboard = NSPasteboard.general
        let snapshot = snapshotPasteboard(pasteboard)
        defer { restorePasteboard(snapshot, to: pasteboard) }

        let manager = PasteManager()
        XCTAssertTrue(manager.copyIfEnabled(text: "new dictation", isEnabled: true))
        XCTAssertEqual(pasteboard.string(forType: .string), "new dictation")
    }

    @MainActor
    func testTransientMarkerDetectionUsesPasteboardItemTypes() {
        let pasteboard = NSPasteboard.general
        let snapshot = snapshotPasteboard(pasteboard)
        defer { restorePasteboard(snapshot, to: pasteboard) }

        pasteboard.clearContents()
        pasteboard.setString("dictation", forType: .string)
        XCTAssertFalse(PasteManager.hasTransientPasteboardMarker(pasteboard))

        pasteboard.setData(Data(), forType: PasteManager.transientType)
        XCTAssertTrue(PasteManager.hasTransientPasteboardMarker(pasteboard))
    }

    func testHTMLFromMarkdownLinksPreservesParagraphBreaks() {
        let html = PasteManager.htmlFromMarkdownLinks(
            """
            Hello team,

            Thanks for the update.

            Sent with [Resonant](https://onresonant.com)
            """
        )

        XCTAssertEqual(
            html,
            "<html><head><meta charset=\"utf-8\"><style>body{margin:0}.resonant-paste{font:inherit;font-family:inherit;font-size:inherit;color:inherit}.resonant-paste a{font:inherit;font-family:inherit;font-size:inherit;color:#0000EE;text-decoration:underline}</style></head><body><span class=\"resonant-paste\">Hello team,<br><br>Thanks for the update.<br><br>Sent with <a href=\"https://onresonant.com\">Resonant</a></span></body></html>"
        )
    }

    func testHTMLFromMarkdownLinksEscapesPlainTextAndURLAttributes() {
        let html = PasteManager.htmlFromMarkdownLinks(
            "5 < 6 & docs: [Open \"Docs\"](https://example.com?a=1&b=2)"
        )

        XCTAssertEqual(
            html,
            "<html><head><meta charset=\"utf-8\"><style>body{margin:0}.resonant-paste{font:inherit;font-family:inherit;font-size:inherit;color:inherit}.resonant-paste a{font:inherit;font-family:inherit;font-size:inherit;color:#0000EE;text-decoration:underline}</style></head><body><span class=\"resonant-paste\">5 &lt; 6 &amp; docs: <a href=\"https://example.com?a=1&amp;b=2\">Open &quot;Docs&quot;</a></span></body></html>"
        )
    }

    func testAdjustTextForInsertionContextPreservesCapitalizationAfterProseWord() {
        // After a regular word, preserve the model's capitalization
        // so consecutive dictations don't force-lowercase new sentences.
        XCTAssertEqual(
            PasteManager.adjustTextForInsertionContext(
                "World",
                textBeforeCursor: "Hello ",
                continuesFromOurInsertion: true
            ),
            "World"
        )
    }

    func testAdjustTextForInsertionContextAddsSpaceAndPreservesCapitalizationWhenContinuingProse() {
        XCTAssertEqual(
            PasteManager.adjustTextForInsertionContext(
                "World",
                textBeforeCursor: "Hello",
                continuesFromOurInsertion: true
            ),
            " World"
        )
    }

    func testAdjustTextForInsertionContextLowercasesAfterComma() {
        XCTAssertEqual(
            PasteManager.adjustTextForInsertionContext(
                "World",
                textBeforeCursor: "Hello, ",
                continuesFromOurInsertion: true
            ),
            "world"
        )
    }

    func testAdjustTextForInsertionContextCapitalizesAfterNewline() {
        XCTAssertEqual(
            PasteManager.adjustTextForInsertionContext(
                "hello",
                textBeforeCursor: "Previous line.\n",
                continuesFromOurInsertion: true
            ),
            "Hello"
        )
    }

    func testAdjustTextForInsertionContextCapitalizesAfterNewlineWithoutPeriod() {
        XCTAssertEqual(
            PasteManager.adjustTextForInsertionContext(
                "hello",
                textBeforeCursor: "Some text\n",
                continuesFromOurInsertion: true
            ),
            "Hello"
        )
    }

    func testAdjustTextForInsertionContextCapitalizesAfterSentenceBoundary() {
        XCTAssertEqual(
            PasteManager.adjustTextForInsertionContext(
                "world",
                textBeforeCursor: "Hello. ",
                continuesFromOurInsertion: true
            ),
            "World"
        )
    }

    func testAdjustTextForInsertionContextCapitalizesAfterQuotedSentenceBoundary() {
        XCTAssertEqual(
            PasteManager.adjustTextForInsertionContext(
                "world",
                textBeforeCursor: "Hello.\" ",
                continuesFromOurInsertion: true
            ),
            "World"
        )
    }

    func testAdjustTextForInsertionContextCapitalizesAtFieldStart() {
        XCTAssertEqual(
            PasteManager.adjustTextForInsertionContext(
                "hello",
                textBeforeCursor: nil,
                continuesFromOurInsertion: true
            ),
            "Hello"
        )
    }

    func testAdjustTextForInsertionContextIgnoresFormattingOnlyCursorContext() {
        XCTAssertEqual(
            PasteManager.adjustTextForInsertionContext(
                "hello",
                textBeforeCursor: "\u{200B}",
                continuesFromOurInsertion: true
            ),
            "Hello"
        )
    }

    func testAdjustTextForInsertionContextPreservesExistingSpaceBeforeFormattingMarker() {
        XCTAssertEqual(
            PasteManager.adjustTextForInsertionContext(
                "World",
                textBeforeCursor: "Hello \u{200B}",
                continuesFromOurInsertion: true
            ),
            "World"
        )
    }

    func testAdjustTextForInsertionContextAddsSpaceAfterProseBeforeFormattingMarker() {
        XCTAssertEqual(
            PasteManager.adjustTextForInsertionContext(
                "World",
                textBeforeCursor: "Hello\u{200B}",
                continuesFromOurInsertion: true
            ),
            " World"
        )
    }

    func testAdjustTextForInsertionContextSkipsSpacePrependWhenNotContinuingFromOurInsertion() {
        // Rich text editors return AX content that doesn't reliably reflect the
        // caret. When we can't verify we're continuing from our own dictation,
        // pass the model output through unchanged.
        XCTAssertEqual(
            PasteManager.adjustTextForInsertionContext(
                "World",
                textBeforeCursor: "Hello",
                continuesFromOurInsertion: false
            ),
            "World"
        )
    }

    func testAdjustTextForInsertionContextSkipsLowercaseWhenNotContinuingFromOurInsertion() {
        // Signature like "Best," in a browser contenteditable should not
        // trigger lowercasing of the user's dictated sentence.
        XCTAssertEqual(
            PasteManager.adjustTextForInsertionContext(
                "Hello team",
                textBeforeCursor: "Best,",
                continuesFromOurInsertion: false
            ),
            "Hello team"
        )
    }

    func testAdjustTextForInsertionContextStillCapitalizesAtFieldStartEvenWhenNotContinuing() {
        // Capitalize-at-field-start is the model's default and safe to apply
        // regardless of continuation status.
        XCTAssertEqual(
            PasteManager.adjustTextForInsertionContext(
                "hello",
                textBeforeCursor: nil,
                continuesFromOurInsertion: false
            ),
            "Hello"
        )
    }

    @MainActor
    func testCopyIfEnabledWritesHTMLForMarkdownLinksWithoutRTF() throws {
        let pasteboard = NSPasteboard.general
        let snapshot = snapshotPasteboard(pasteboard)
        defer { restorePasteboard(snapshot, to: pasteboard) }

        let manager = PasteManager()
        XCTAssertTrue(
            manager.copyIfEnabled(
                text: """
                Hello team,

                Sent with [Resonant](https://onresonant.com)
                """,
                isEnabled: true
            )
        )

        let item = try XCTUnwrap(pasteboard.pasteboardItems?.first)
        XCTAssertNotNil(item.data(forType: .html))
        XCTAssertNil(item.data(forType: .rtf))

        XCTAssertEqual(
            item.string(forType: .string),
            """
            Hello team,

            Sent with Resonant
            """
        )
    }

    @MainActor
    func testCopyIfEnabledWritesPlainTextOnlyForMultilinePlainText() throws {
        let pasteboard = NSPasteboard.general
        let snapshot = snapshotPasteboard(pasteboard)
        defer { restorePasteboard(snapshot, to: pasteboard) }

        let manager = PasteManager()
        XCTAssertTrue(
            manager.copyIfEnabled(
                text: """
                Hello team,

                Thanks for the update.
                """,
                isEnabled: true
            )
        )

        let item = try XCTUnwrap(pasteboard.pasteboardItems?.first)
        XCTAssertNil(item.data(forType: .html))
        XCTAssertNil(item.data(forType: .rtf))
        XCTAssertEqual(
            item.string(forType: .string),
            """
            Hello team,

            Thanks for the update.
            """
        )
    }

    func testSettableFieldsStillAllowAXValueInsertion() {
        XCTAssertTrue(
            PasteManager.shouldAttemptAXValueInsertion(
                role: kAXTextFieldRole,
                isValueSettable: true,
                currentValue: "Existing text"
            )
        )
    }

    func testNonSettableEmptyTextAreaStillAllowsAXValueInsertion() {
        XCTAssertTrue(
            PasteManager.shouldAttemptAXValueInsertion(
                role: kAXTextAreaRole,
                isValueSettable: false,
                currentValue: "   "
            )
        )
    }

    func testNonSettablePlaceholderBackedTextAreaFallsBackToKeyboardPaste() {
        XCTAssertFalse(
            PasteManager.shouldAttemptAXValueInsertion(
                role: kAXTextAreaRole,
                isValueSettable: false,
                currentValue: "",
                placeholderValue: "Write a message..."
            )
        )
    }

    func testNonSettablePopulatedTextAreaFallsBackToKeyboardPaste() {
        XCTAssertFalse(
            PasteManager.shouldAttemptAXValueInsertion(
                role: kAXTextAreaRole,
                isValueSettable: false,
                currentValue: "Type a message"
            )
        )
    }

    func testBypassedTargetsSkipKeyboardSelectionRestore() {
        XCTAssertFalse(
            PasteManager.shouldRestoreSelectionRangeForKeyboardDelivery(
                containsMarkdownLinks: false,
                bypassesAXValueInsertion: true,
                selectedRange: SelectionRange(location: 12, length: 5)
            )
        )
    }

    func testMarkdownLinkPastesRestoreSelectionBeforeKeyboardDelivery() {
        XCTAssertTrue(
            PasteManager.shouldRestoreSelectionRangeForKeyboardDelivery(
                containsMarkdownLinks: true,
                bypassesAXValueInsertion: false,
                selectedRange: SelectionRange(location: 4, length: 3)
            )
        )
    }

    func testAXInsertionPathSkipsKeyboardSelectionRestore() {
        XCTAssertFalse(
            PasteManager.shouldRestoreSelectionRangeForKeyboardDelivery(
                containsMarkdownLinks: false,
                bypassesAXValueInsertion: false,
                selectedRange: SelectionRange(location: 8, length: 2)
            )
        )
    }

    func testZeroLengthSelectionSkipsKeyboardSelectionRestore() {
        XCTAssertFalse(
            PasteManager.shouldRestoreSelectionRangeForKeyboardDelivery(
                containsMarkdownLinks: false,
                bypassesAXValueInsertion: true,
                selectedRange: SelectionRange(location: 8, length: 0)
            )
        )
    }

    func testExplicitVerifiedKeyboardTargetsCaptureVerificationSnapshotEvenWhenBypassingAXInsertion() {
        XCTAssertTrue(
            PasteManager.shouldCaptureVerificationSnapshot(
                bypassesAXValueInsertion: true,
                requiresVerifiedKeyboardDelivery: true,
                isSelfTargeting: false
            )
        )
    }

    func testGenericAXBypassTargetsSkipVerificationSnapshot() {
        XCTAssertFalse(
            PasteManager.shouldCaptureVerificationSnapshot(
                bypassesAXValueInsertion: true,
                requiresVerifiedKeyboardDelivery: false,
                isSelfTargeting: false
            )
        )
    }

    func testSelfTargetingSkipsVerificationSnapshot() {
        XCTAssertFalse(
            PasteManager.shouldCaptureVerificationSnapshot(
                bypassesAXValueInsertion: false,
                requiresVerifiedKeyboardDelivery: true,
                isSelfTargeting: true
            )
        )
    }

    func testReadableAXBypassTargetStillCapturesCorrectionReceiptSnapshot() {
        XCTAssertTrue(
            PasteManager.shouldCaptureCorrectionReceiptSnapshot(
                bypassesCorrectionReadback: false,
                isSelfTargeting: false
            )
        )
        XCTAssertFalse(
            PasteManager.shouldCaptureCorrectionReceiptSnapshot(
                bypassesCorrectionReadback: true,
                isSelfTargeting: false
            )
        )
        XCTAssertFalse(
            PasteManager.shouldCaptureCorrectionReceiptSnapshot(
                bypassesCorrectionReadback: false,
                isSelfTargeting: true
            )
        )
    }

    func testBlockingSyntheticInputModifierFlagsIncludePasteMutatingModifiers() {
        let blocking = PasteManager.blockingSyntheticInputModifierFlags(
            from: [
                .maskCommand,
                .maskShift,
                .maskAlternate,
                .maskControl,
                .maskSecondaryFn,
                .maskAlphaShift
            ]
        )

        XCTAssertTrue(blocking.contains(.maskCommand))
        XCTAssertTrue(blocking.contains(.maskShift))
        XCTAssertTrue(blocking.contains(.maskAlternate))
        XCTAssertTrue(blocking.contains(.maskControl))
        XCTAssertTrue(blocking.contains(.maskSecondaryFn))
        XCTAssertFalse(blocking.contains(.maskAlphaShift))
    }

    func testBlockingSyntheticInputModifierFlagsIgnoreNonMutatingFlags() {
        XCTAssertTrue(
            PasteManager.blockingSyntheticInputModifierFlags(from: []).isEmpty
        )
        XCTAssertTrue(
            PasteManager.blockingSyntheticInputModifierFlags(from: [.maskAlphaShift]).isEmpty
        )
    }

    func testPasteDeliveryModeControlsAccessibilityAttempt() {
        XCTAssertTrue(
            PasteManager.shouldAttemptAccessibilityDelivery(
                deliveryMode: .automatic,
                bypassesAXValueInsertion: false,
                containsMarkdownLinks: false
            )
        )
        XCTAssertFalse(
            PasteManager.shouldAttemptAccessibilityDelivery(
                deliveryMode: .automatic,
                bypassesAXValueInsertion: true,
                containsMarkdownLinks: false
            )
        )
        XCTAssertFalse(
            PasteManager.shouldAttemptAccessibilityDelivery(
                deliveryMode: .automatic,
                bypassesAXValueInsertion: false,
                containsMarkdownLinks: true
            )
        )
        XCTAssertTrue(
            PasteManager.shouldAttemptAccessibilityDelivery(
                deliveryMode: .accessibility,
                bypassesAXValueInsertion: true,
                containsMarkdownLinks: true
            )
        )
        XCTAssertFalse(
            PasteManager.shouldAttemptAccessibilityDelivery(
                deliveryMode: .clipboard,
                bypassesAXValueInsertion: false,
                containsMarkdownLinks: false
            )
        )
    }

    func testPasteDeliveryModeControlsDirectTyping() {
        XCTAssertTrue(
            PasteManager.shouldUseDirectTyping(
                deliveryMode: .automatic,
                targetPrefersDirectTyping: true,
                containsMarkdownLinks: false
            )
        )
        XCTAssertFalse(
            PasteManager.shouldUseDirectTyping(
                deliveryMode: .automatic,
                targetPrefersDirectTyping: true,
                containsMarkdownLinks: true
            )
        )
        XCTAssertTrue(
            PasteManager.shouldUseDirectTyping(
                deliveryMode: .directTyping,
                targetPrefersDirectTyping: false,
                containsMarkdownLinks: true
            )
        )
        XCTAssertFalse(
            PasteManager.shouldUseDirectTyping(
                deliveryMode: .clipboard,
                targetPrefersDirectTyping: true,
                containsMarkdownLinks: false
            )
        )
    }

    func testUTF16InsertionAnchorExtractsTargetObservedSelectionReplacement() throws {
        let baseline = "Before wurld after"
        let replacementRange = (baseline as NSString).range(of: "wurld")

        let insertion = try XCTUnwrap(PasteManager.makeUTF16InsertionAnchor(
            baselineValue: baseline,
            selectedRange: SelectionRange(
                location: replacementRange.location,
                length: replacementRange.length
            ),
            postDeliveryValue: "Before world after"
        ))

        XCTAssertEqual(insertion.anchor.prefixUTF16Length, 7)
        XCTAssertEqual(insertion.anchor.suffixUTF16Length, 6)
        XCTAssertTrue(insertion.anchor.hasClosedBoundaries)
        XCTAssertEqual(insertion.targetObservedInsertedText, "world")
        XCTAssertEqual(
            PasteManager.anchoredInsertedRegion(
                in: "Before World after",
                anchor: insertion.anchor
            ),
            "World"
        )
    }

    func testUTF16InsertionAnchorHandlesMultiUnitUnicodeSelection() throws {
        let baseline = "A😀B"
        let replacementRange = (baseline as NSString).range(of: "😀")
        XCTAssertEqual(replacementRange.length, 2)

        let insertion = try XCTUnwrap(PasteManager.makeUTF16InsertionAnchor(
            baselineValue: baseline,
            selectedRange: SelectionRange(
                location: replacementRange.location,
                length: replacementRange.length
            ),
            postDeliveryValue: "A🎙️B"
        ))

        XCTAssertEqual(insertion.anchor.prefixUTF16Length, 1)
        XCTAssertEqual(insertion.anchor.suffixUTF16Length, 1)
        XCTAssertEqual(insertion.targetObservedInsertedText, "🎙️")
        XCTAssertEqual(
            PasteManager.anchoredInsertedRegion(
                in: "A🎤B",
                anchor: insertion.anchor
            ),
            "🎤"
        )
    }

    func testUTF16InsertionAnchorRejectsChangedSurroundingContext() throws {
        let insertion = try XCTUnwrap(PasteManager.makeUTF16InsertionAnchor(
            baselineValue: "prefix suffix",
            selectedRange: SelectionRange(location: 7, length: 0),
            postDeliveryValue: "prefix inserted suffix"
        ))

        XCTAssertNil(PasteManager.anchoredInsertedRegion(
            in: "changed inserted suffix",
            anchor: insertion.anchor
        ))
        XCTAssertNil(PasteManager.anchoredInsertedRegion(
            in: "prefix inserted changed",
            anchor: insertion.anchor
        ))
    }

    func testDeliveryAttributionCarriesCompleteAnchorAndNoSurroundingText() throws {
        let baseline = "Before old after"
        let replacedNSRange = (baseline as NSString).range(of: "old")
        let insertion = try XCTUnwrap(PasteManager.makeUTF16InsertionAnchor(
            baselineValue: baseline,
            selectedRange: SelectionRange(
                location: replacedNSRange.location,
                length: replacedNSRange.length
            ),
            postDeliveryValue: "Before new after"
        ))
        let fingerprint = ContextTargetFingerprint(
            role: kAXTextFieldRole,
            subrole: "AXSearchField",
            isSensitiveInput: false,
            identifierToken: "field-id",
            titleToken: "title",
            descriptionToken: "description",
            placeholderToken: "placeholder",
            helpToken: "help",
            frameBucket: "0:1:2:3",
            selectedRangeBucket: "4:0"
        )

        let attribution = try XCTUnwrap(PasteManager.makeDeliveryAttribution(
            targetProcessIdentifier: 88,
            targetBundleIdentifier: "com.example.app",
            targetFingerprint: fingerprint,
            anchor: insertion.anchor,
            preDeliveryFieldUTF16Length: (baseline as NSString).length
        ))

        XCTAssertEqual(attribution.targetProcessIdentifier, 88)
        XCTAssertEqual(attribution.targetBundleIdentifier, "com.example.app")
        XCTAssertEqual(attribution.isSensitiveInput, false)
        XCTAssertEqual(attribution.targetFingerprint, fingerprint)
        XCTAssertEqual(attribution.anchor, insertion.anchor)
        XCTAssertEqual(attribution.anchor.replacedRange, SelectionRange(
            location: replacedNSRange.location,
            length: replacedNSRange.length
        ))
        XCTAssertEqual(attribution.anchor.prefixUTF16Length, 7)
        XCTAssertEqual(attribution.anchor.suffixUTF16Length, 6)
        XCTAssertEqual(attribution.preDeliveryFieldUTF16Length, 16)
        XCTAssertFalse(attribution.wholeFieldOwned)
        XCTAssertEqual(
            PasteManager.anchoredInsertedRegion(
                in: "Before edited after",
                anchor: attribution.anchor
            ),
            "edited"
        )
    }

    func testDeliveryAttributionMarksOnlyFullReplacementAsWholeFieldOwned() throws {
        let baseline = "replace me"
        let fullReplacement = try XCTUnwrap(PasteManager.makeUTF16InsertionAnchor(
            baselineValue: baseline,
            selectedRange: SelectionRange(
                location: 0,
                length: (baseline as NSString).length
            ),
            postDeliveryValue: "new value"
        ))
        let attribution = try XCTUnwrap(PasteManager.makeDeliveryAttribution(
            targetProcessIdentifier: 9,
            targetBundleIdentifier: "com.example.app",
            targetFingerprint: nil,
            anchor: fullReplacement.anchor,
            preDeliveryFieldUTF16Length: (baseline as NSString).length
        ))

        XCTAssertTrue(attribution.wholeFieldOwned)
        XCTAssertEqual(attribution.anchor.prefixUTF16Length, 0)
        XCTAssertEqual(attribution.anchor.suffixUTF16Length, 0)
        XCTAssertNil(attribution.isSensitiveInput)
    }

    @MainActor
    private func snapshotPasteboard(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
    }

    @MainActor
    private func restorePasteboard(
        _ snapshot: [[NSPasteboard.PasteboardType: Data]],
        to pasteboard: NSPasteboard
    ) {
        pasteboard.clearContents()
        let items = snapshot.map { dataByType -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in dataByType {
                item.setData(data, forType: type)
            }
            return item
        }

        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }
}
