import XCTest
@testable import Resonant

final class SurfaceFormattingDefaultsTests: XCTestCase {

    private func packet(
        fieldKind: FieldKind = .unknown,
        surfaceKind: SurfaceKind = .other,
        role: String? = nil
    ) -> ContextPacket {
        ContextPacket(
            id: UUID(),
            capturedAt: Date(),
            surface: SurfaceDescriptor(
                kind: surfaceKind,
                appName: "TestApp",
                bundleId: "com.test.app",
                windowTitle: nil,
                browserURL: nil,
                siteHost: nil,
                siteName: nil,
                fieldKind: fieldKind,
                conversationLabel: nil,
                documentLabel: nil,
                projectLabel: nil
            ),
            intent: DictationIntent(
                kind: .plainDictation,
                confidence: 1,
                allowsBiasTerms: true,
                allowsStyleHint: true,
                allowsSelectedTextGrounding: true,
                allowsVisibleContextGrounding: true,
                allowsMemoryGrounding: true,
                evidence: []
            ),
            entities: [],
            styleHint: nil,
            selectedTextPreview: nil,
            focusedFieldPreview: nil,
            targetFingerprint: role.map { ContextTargetFingerprint(role: $0) },
            visibleGroundingSnippets: [],
            safetyFlags: [],
            latency: .empty
        )
    }

    // MARK: - Inference

    func testSubjectFieldFlattensAndDropsTrailingPeriod() {
        let defaults = SurfaceFormattingDefaults.infer(from: packet(fieldKind: .subject))
        XCTAssertTrue(defaults.flattenLineBreaks)
        XCTAssertTrue(defaults.suppressTrailingPunctuation)
        XCTAssertEqual(defaults.trailingPeriodPolicy, .omit)
    }

    func testSearchFieldFlattensAndDropsTrailingPeriod() {
        let defaults = SurfaceFormattingDefaults.infer(from: packet(fieldKind: .search))
        XCTAssertTrue(defaults.flattenLineBreaks)
        XCTAssertTrue(defaults.suppressTrailingPunctuation)
    }

    func testSingleLineAXRoleFlattensOnly() {
        let defaults = SurfaceFormattingDefaults.infer(from: packet(role: "AXTextField"))
        XCTAssertTrue(defaults.flattenLineBreaks)
        XCTAssertFalse(defaults.suppressTrailingPunctuation)
    }

    func testChatSurfaceGetsShortMessageDefaults() {
        let defaults = SurfaceFormattingDefaults.infer(
            from: packet(fieldKind: .compose, surfaceKind: .chat)
        )
        XCTAssertTrue(defaults.chatShortMessageDefaults)
        XCTAssertFalse(defaults.flattenLineBreaks)
    }

    func testNilPacketIsNeutral() {
        XCTAssertEqual(SurfaceFormattingDefaults.infer(from: nil), .neutral)
        XCTAssertEqual(SurfaceFormattingDefaults.neutral.trailingPeriodPolicy, .inherit)
    }

    func testTextAreaRoleStaysMultiline() {
        let defaults = SurfaceFormattingDefaults.infer(from: packet(role: "AXTextArea"))
        XCTAssertFalse(defaults.flattenLineBreaks)
    }

    // MARK: - Pipeline behavior

    private func configuration(
        bullets: Bool = true,
        suppressTrailing: Bool = false,
        flatten: Bool = false,
        chatDefaults: Bool = false
    ) -> PostProcessingConfiguration {
        PostProcessingConfiguration(
            removeFillersEnabled: false,
            removeFalseStartsEnabled: false,
            itnEnabled: false,
            autoPunctuationEnabled: true,
            bulletPointsEnabled: bullets,
            suppressTrailingPunctuation: suppressTrailing,
            flattenLineBreaks: flatten,
            chatShortMessageDefaults: chatDefaults
        )
    }

    func testFlattenTurnsSpokenBulletsIntoSemicolons() {
        let result = PostProcessingPipeline.run(
            "we need bullet point milk bullet point eggs",
            configuration: configuration(flatten: true),
            corrections: []
        )
        XCTAssertEqual(result.text, "We need; Milk; Eggs")
    }

    func testFlattenJoinsSentencesWithSpace() {
        XCTAssertEqual(
            TextFormatter.flattenedLineBreaks("Done with part one.\n\nStarting part two"),
            "Done with part one. Starting part two"
        )
    }

    func testSubjectLineGetsNoTrailingPeriod() {
        let result = PostProcessingPipeline.run(
            "quarterly update draft two",
            configuration: configuration(suppressTrailing: true, flatten: true),
            corrections: []
        )
        XCTAssertEqual(result.text, "Quarterly update draft two")
    }

    func testShortChatMessageGetsNoTrailingPeriod() {
        let result = PostProcessingPipeline.run(
            "sounds good see you then",
            configuration: configuration(chatDefaults: true),
            corrections: []
        )
        XCTAssertEqual(result.text, "Sounds good see you then")
    }

    func testLongChatMessageStillGetsTrailingPeriod() {
        let result = PostProcessingPipeline.run(
            "I went through the whole review queue this morning and everything looks good to merge before the deadline",
            configuration: configuration(chatDefaults: true),
            corrections: []
        )
        XCTAssertTrue(result.text.hasSuffix("."), result.text)
    }

    func testShortChatQuestionStillGetsQuestionMark() {
        let result = PostProcessingPipeline.run(
            "can you check the deploy",
            configuration: configuration(chatDefaults: true),
            corrections: []
        )
        XCTAssertEqual(result.text, "Can you check the deploy?")
    }

    func testApplyingDefaultsDisablesBulletsWhenFlattening() {
        var defaults = SurfaceFormattingDefaults()
        defaults.flattenLineBreaks = true
        let adjusted = configuration(bullets: true).applying(defaults)
        XCTAssertFalse(adjusted.bulletPointsEnabled)
        XCTAssertTrue(adjusted.flattenLineBreaks)
    }
}
