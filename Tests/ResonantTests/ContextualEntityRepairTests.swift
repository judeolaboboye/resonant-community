import XCTest
@testable import Resonant

final class ContextualEntityRepairTests: XCTestCase {
    func testRepairsSoundAlikeGreetingFromStructuredLinkedInRecipient() {
        let packet = linkedInRecipientPacket()

        let repaired = ContextualEntityRepair.repair(
            "Hey Henry, how are you?",
            using: packet
        )

        XCTAssertEqual(repaired.text, "Hey Henri, how are you?")
        XCTAssertEqual(repaired.personalization, .none)
    }

    func testRecipientDirectAddressRepairSupportsConservativePositions() {
        let packet = linkedInRecipientPacket()

        let cases = [
            ("Henry, can you send it?", "Henri, can you send it?"),
            ("Henry — can you send it?", "Henri — can you send it?"),
            ("Henry, you can send it now.", "Henri, you can send it now."),
            ("Henry, I wanted to ask you something.", "Henri, I wanted to ask you something."),
            ("Thanks, Henry", "Thanks, Henri"),
            ("Sorry Henry, I missed that", "Sorry Henri, I missed that"),
            ("Okay, Henry, let's ship", "Okay, Henri, let's ship"),
            ("Good morning Henry", "Good morning Henri"),
            ("What do you think, Henry?", "What do you think, Henri?"),
            ("Henry", "Henri"),
        ]

        for (input, expected) in cases {
            XCTAssertEqual(
                ContextualEntityRepair.repair(input, using: packet).text,
                expected,
                input
            )
        }
    }

    func testRecipientDirectAddressRepairPreservesAmbiguousReferencesAndLabels() {
        let packet = linkedInRecipientPacket()

        for text in [
            "I spoke with Henry yesterday",
            "Henry said he would send it",
            "No Henry was involved",
            "Henry: CEO",
            "Henry; send the report",
            "Henry, the account manager, will join tomorrow.",
            "Henry — the account manager — will join tomorrow.",
            "Henry, I think, is the account manager.",
            "Henry, you may remember him, is the account manager.",
            "Henry — you may remember him — is the account manager.",
            "We shortlisted Alice, Henry.",
            "Hey Harold, how are you?",
            "\"Hey Henry,\" she wrote",
            "\"What do you think, Henry?\"",
        ] {
            XCTAssertEqual(
                ContextualEntityRepair.repair(text, using: packet).text,
                text
            )
        }

        let annPacket = linkedInRecipientPacket(
            fullName: "Ann Smith",
            firstName: "Ann"
        )
        XCTAssertEqual(
            ContextualEntityRepair.repair(
                "Anne-Marie said she would send it",
                using: annPacket
            ).text,
            "Anne-Marie said she would send it"
        )
    }

    func testRecipientDirectAddressRepairAppliesUnequalLengthRangesRightToLeft() {
        let packet = linkedInRecipientPacket(
            fullName: "Anne Smith",
            firstName: "Anne"
        )

        XCTAssertEqual(
            ContextualEntityRepair.repair(
                "Ann, can you review this, Ann?",
                using: packet
            ).text,
            "Anne, can you review this, Anne?"
        )
    }

    func testRecipientDirectAddressRepairRejectsCommonVocatives() {
        let packet = linkedInRecipientPacket()
        for text in [
            "Hello team, quick update",
            "Hey there, quick update",
            "Hi all, quick update",
            "Hello everyone, quick update",
        ] {
            XCTAssertEqual(
                ContextualEntityRepair.repair(text, using: packet).text,
                text
            )
        }
    }

    func testRecipientDirectAddressRepairRequiresStructuredRecipientAndBrowserMessageSurface() {
        let visibleOnly = ContextPacketBuilder.build(
            transcript: "Hey Henry",
            hot: ContextExtractor.HotContext(
                appName: "Brave Browser",
                bundleId: "com.brave.browser",
                windowTitle: "Henri Enguerran Badoux | LinkedIn",
                browserURL: "https://www.linkedin.com/feed/",
                targetFingerprint: ContextTargetFingerprint(role: "AXTextArea")
            )
        )
        XCTAssertEqual(
            ContextualEntityRepair.repair("Hey Henry", using: visibleOnly).text,
            "Hey Henry"
        )

        let nonBrowser = ContextPacketBuilder.build(
            transcript: "Hey Henry",
            hot: ContextExtractor.HotContext(
                appName: "Notes",
                bundleId: "com.apple.Notes",
                targetFingerprint: ContextTargetFingerprint(role: "AXTextArea"),
                activeRecipient: ActiveRecipientContext(
                    fullName: "Henri Enguerran Badoux",
                    firstName: "Henri",
                    confidence: 0.96
                )
            )
        )
        XCTAssertEqual(
            ContextualEntityRepair.repair("Hey Henry", using: nonBrowser).text,
            "Hey Henry"
        )
    }

    func testRepairsVisiblePersonNameCasingWhenSpoken() {
        var context = ContextExtractor.Context()
        context.appName = "Chrome"
        context.bundleId = "com.google.chrome"
        context.windowTitle = "Follow up with Sarah Chen - Gmail"
        context.browserURL = "https://mail.google.com/mail/u/0/#inbox"
        context.visibleTextSnippets = ["Sarah Chen <sarah@example.com>"]

        let packet = ContextPacketBuilder.build(
            transcript: "please ask sarah chen if Tuesday works",
            context: context
        )
        let repaired = ContextualEntityRepair.repair(
            "please ask sarah chen if Tuesday works",
            using: packet
        )

        XCTAssertEqual(repaired.text, "please ask Sarah Chen if Tuesday works")
        XCTAssertEqual(repaired.personalization, .none)
    }

    func testDoesNotInsertVisiblePersonNameWhenNotSpoken() {
        var context = ContextExtractor.Context()
        context.appName = "Chrome"
        context.bundleId = "com.google.chrome"
        context.windowTitle = "Follow up with Sarah Chen - Gmail"
        context.browserURL = "https://mail.google.com/mail/u/0/#inbox"
        context.visibleTextSnippets = ["Sarah Chen <sarah@example.com>"]

        let packet = ContextPacketBuilder.build(
            transcript: "please ask her if Tuesday works",
            context: context
        )
        let repaired = ContextualEntityRepair.repair(
            "please ask her if Tuesday works",
            using: packet
        )

        XCTAssertEqual(repaired.text, "please ask her if Tuesday works")
    }

    func testRepairsOpenFilenameWhenSpoken() {
        let hot = ContextExtractor.HotContext(
            appName: "Cursor",
            bundleId: "com.todesktop.230313mzl4w4u92",
            windowTitle: "missoula - Cursor",
            browserURL: "",
            selectedText: "",
            selectedRange: nil,
            focusedFieldContent: ""
        )
        let cold = ContextExtractor.ColdContext(
            codeFiles: ["AppState.swift"],
            slackMembers: [],
            visibleTextSnippets: []
        )
        let packet = ContextPacketBuilder.build(
            transcript: "update app state swift",
            hot: hot,
            cold: cold
        )

        let repaired = ContextualEntityRepair.repair(
            "update app state swift",
            using: packet
        )

        XCTAssertEqual(repaired.text, "update AppState.swift")
    }

    func testRepairsVisibleHandleWhenSpokenAsAtWords() {
        var context = ContextExtractor.Context()
        context.appName = "Safari"
        context.bundleId = "com.apple.Safari"
        context.windowTitle = "Post from @alex_dev / X"
        context.browserURL = "https://x.com/alex_dev/status/123"
        context.visibleTextSnippets = ["@alex_dev"]

        let packet = ContextPacketBuilder.build(
            transcript: "reply to at alex dev that this looks good",
            context: context
        )
        let repaired = ContextualEntityRepair.repair(
            "reply to at alex dev that this looks good",
            using: packet
        )

        XCTAssertEqual(repaired.text, "reply to @alex_dev that this looks good")
        XCTAssertEqual(repaired.personalization, .none)
    }

    func testLearnedRepairReportsConsideredMatchedAndActuallyApplied() {
        let packet = learnedPacket(spokenForm: "reson antia", value: "Resonantia")

        let repaired = ContextualEntityRepair.repair(
            "mention reson antia in the update",
            using: packet
        )

        XCTAssertEqual(repaired.text, "mention Resonantia in the update")
        XCTAssertEqual(repaired.personalization.learnedEntityConsideredCount, 1)
        XCTAssertEqual(repaired.personalization.learnedEntityMatchedCount, 1)
        XCTAssertEqual(repaired.personalization.learnedEntityAppliedCount, 1)
    }

    func testLearnedOfferWithoutMatchNeverCountsAsLocalApplication() {
        let packet = learnedPacket(spokenForm: "reson antia", value: "Resonantia")

        let repaired = ContextualEntityRepair.repair(
            "mention the launch in the update",
            using: packet
        )

        XCTAssertEqual(repaired.text, "mention the launch in the update")
        XCTAssertEqual(repaired.personalization.learnedEntityConsideredCount, 1)
        XCTAssertEqual(repaired.personalization.learnedEntityMatchedCount, 0)
        XCTAssertEqual(repaired.personalization.learnedEntityAppliedCount, 0)
    }

    func testManualDictionaryRepairNeverCountsAsLearnedApplication() {
        let manual = ContextEntity(
            type: .customTerm,
            value: "ManualProduct",
            normalizedValue: "manualproduct",
            spokenForms: ["manual product"],
            source: .dictionary,
            confidence: 1,
            recencyScore: 1,
            proximityScore: 1,
            trustTier: .biasTerm,
            isSensitive: false,
            evidence: "manual",
            surfaceScope: nil,
            appScope: nil,
            siteScope: nil,
            projectScope: nil
        )
        let packet = ContextPacketBuilder.build(
            transcript: "mention manual product",
            hot: ContextExtractor.HotContext(appName: "Notes"),
            personalizationSnapshot: PersonalizationMemorySnapshot(
                entities: [manual],
                biasTerms: [manual.value],
                styleHint: nil
            )
        )

        let repaired = ContextualEntityRepair.repair("mention manual product", using: packet)

        XCTAssertEqual(repaired.text, "mention ManualProduct")
        XCTAssertEqual(repaired.personalization, .none)
    }

    private func learnedPacket(spokenForm: String, value: String) -> ContextPacket {
        let surface = SurfaceClassifier.classify(
            appName: "Notes",
            bundleId: "com.apple.Notes",
            windowTitle: nil,
            browserURL: nil
        )
        let learned = ContextEntity(
            type: .customTerm,
            value: value,
            normalizedValue: value.lowercased(),
            spokenForms: [spokenForm],
            source: .correctionMemory,
            confidence: 1,
            recencyScore: 1,
            proximityScore: 1,
            trustTier: .biasTerm,
            isSensitive: false,
            evidence: "learned",
            surfaceScope: surface.kind.rawValue,
            appScope: surface.bundleId,
            siteScope: nil,
            projectScope: nil
        )
        let profile = PersonalizationProfileBuilder.build(
            surface: surface,
            snapshot: PersonalizationMemorySnapshot(
                entities: [learned],
                biasTerms: [learned.value],
                styleHint: nil
            ),
            styleSampleCount: 0,
            seed: "local-repair",
            holdoutRate: 0
        )
        return ContextPacketBuilder.build(
            transcript: "mention \(spokenForm)",
            hot: ContextExtractor.HotContext(
                appName: "Notes",
                bundleId: "com.apple.Notes"
            ),
            personalizationProfile: profile
        )
    }

    private func linkedInRecipientPacket(
        fullName: String = "Henri Enguerran Badoux",
        firstName: String = "Henri"
    ) -> ContextPacket {
        ContextPacketBuilder.build(
            transcript: "Hey Henry, how are you?",
            hot: ContextExtractor.HotContext(
                appName: "Brave Browser",
                bundleId: "com.brave.browser",
                windowTitle: "Feed | LinkedIn",
                browserURL: "https://www.linkedin.com/feed/",
                targetFingerprint: ContextTargetFingerprint(
                    role: "AXTextArea",
                    isSensitiveInput: false
                ),
                activeRecipient: ActiveRecipientContext(
                    fullName: fullName,
                    firstName: firstName,
                    confidence: 0.96
                )
            )
        )
    }
}
