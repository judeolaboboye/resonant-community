import XCTest
@testable import Resonant

@MainActor
final class PostProcessorTests: XCTestCase {

    func testRepairsCollapsedSentenceAroundEmailAddress() async {
        let settings = SettingsManager.shared
        let originalRemoveFillersEnabled = settings.removeFillersEnabled
        let originalRemoveFalseStartsEnabled = settings.removeFalseStartsEnabled
        let originalITNEnabled = settings.itnEnabled
        let originalAutoPunctuationEnabled = settings.autoPunctuationEnabled
        let originalBulletPointsEnabled = settings.bulletPointsEnabled

        defer {
            settings.removeFillersEnabled = originalRemoveFillersEnabled
            settings.removeFalseStartsEnabled = originalRemoveFalseStartsEnabled
            settings.itnEnabled = originalITNEnabled
            settings.autoPunctuationEnabled = originalAutoPunctuationEnabled
            settings.bulletPointsEnabled = originalBulletPointsEnabled
        }

        settings.removeFillersEnabled = true
        settings.removeFalseStartsEnabled = true
        settings.itnEnabled = true
        settings.autoPunctuationEnabled = true
        settings.bulletPointsEnabled = false

        let processor = PostProcessor(dictionaryStore: DictionaryStore())
        let result = await processor.process("Iwanttousemyprotonmailemailmail@example. com.  ")

        XCTAssertEqual(result, "I want to use my proton mail email mail@example.com.")
    }

    func testCollapsedRunRepairLeavesPascalCaseIdentifiersIntact() {
        XCTAssertEqual(
            CollapsedRunRepair.repair("WorkspaceSyncEngine"),
            "WorkspaceSyncEngine"
        )
    }

    func testCollapsedRunRepairLeavesWholeWordsIntact() {
        let raw = [
            "applications",
            "commercialization",
            "considerations",
            "detection",
            "diarisation",
            "everything",
            "investigation",
            "journey",
            "marketing",
            "organizational",
            "production",
            "standardized",
            "transcripts",
            "underneath",
            "visualization",
            "workspace",
            "Cloudflare",
        ].joined(separator: " ")

        XCTAssertEqual(
            CollapsedRunRepair.repair(raw),
            raw
        )
    }

    func testCollapsedRunRepairUsesValidWordsMissingFromStaticDictionary() {
        XCTAssertEqual(
            CollapsedRunRepair.repair("It needsatitlecalleddistribute. software."),
            "It needs a title called distribute. software."
        )
    }

    func testCollapsedRunRepairHandlesTrailingFunctionWords() {
        XCTAssertEqual(
            CollapsedRunRepair.repair("Iproposeditto"),
            "I proposed it to"
        )
        XCTAssertEqual(
            CollapsedRunRepair.repair("theyneededit"),
            "they needed it"
        )
        XCTAssertEqual(
            FragmentedWordRepair.repair("I proposed it to"),
            "I proposed it to"
        )
        XCTAssertEqual(
            FragmentedWordRepair.repair("they needed it"),
            "they needed it"
        )
    }

    func testPostProcessorDoesNotRejoinRepairedTrailingFunctionWords() async {
        let settings = SettingsManager.shared
        let originalRemoveFillersEnabled = settings.removeFillersEnabled
        let originalRemoveFalseStartsEnabled = settings.removeFalseStartsEnabled
        let originalITNEnabled = settings.itnEnabled
        let originalAutoPunctuationEnabled = settings.autoPunctuationEnabled
        let originalBulletPointsEnabled = settings.bulletPointsEnabled

        defer {
            settings.removeFillersEnabled = originalRemoveFillersEnabled
            settings.removeFalseStartsEnabled = originalRemoveFalseStartsEnabled
            settings.itnEnabled = originalITNEnabled
            settings.autoPunctuationEnabled = originalAutoPunctuationEnabled
            settings.bulletPointsEnabled = originalBulletPointsEnabled
        }

        settings.removeFillersEnabled = true
        settings.removeFalseStartsEnabled = true
        settings.itnEnabled = true
        settings.autoPunctuationEnabled = false
        settings.bulletPointsEnabled = false

        let processor = PostProcessor(dictionaryStore: DictionaryStore())
        let result = await processor.process("Iproposeditto")

        XCTAssertEqual(result, "I proposed it to")
    }

    func testRepairsCollapsedRunWithInflectedWords() async {
        let settings = SettingsManager.shared
        let originalRemoveFillersEnabled = settings.removeFillersEnabled
        let originalRemoveFalseStartsEnabled = settings.removeFalseStartsEnabled
        let originalITNEnabled = settings.itnEnabled
        let originalAutoPunctuationEnabled = settings.autoPunctuationEnabled
        let originalBulletPointsEnabled = settings.bulletPointsEnabled

        defer {
            settings.removeFillersEnabled = originalRemoveFillersEnabled
            settings.removeFalseStartsEnabled = originalRemoveFalseStartsEnabled
            settings.itnEnabled = originalITNEnabled
            settings.autoPunctuationEnabled = originalAutoPunctuationEnabled
            settings.bulletPointsEnabled = originalBulletPointsEnabled
        }

        settings.removeFillersEnabled = true
        settings.removeFalseStartsEnabled = true
        settings.itnEnabled = true
        settings.autoPunctuationEnabled = false
        settings.bulletPointsEnabled = false

        let processor = PostProcessor(dictionaryStore: DictionaryStore())
        let result = await processor.process("pleasefixtheseissuesnow")

        XCTAssertEqual(result, "Please fix these issues now")
    }

    func testRepairsFragmentedWordRuns() async {
        let settings = SettingsManager.shared
        let originalRemoveFillersEnabled = settings.removeFillersEnabled
        let originalRemoveFalseStartsEnabled = settings.removeFalseStartsEnabled
        let originalITNEnabled = settings.itnEnabled
        let originalAutoPunctuationEnabled = settings.autoPunctuationEnabled
        let originalBulletPointsEnabled = settings.bulletPointsEnabled

        defer {
            settings.removeFillersEnabled = originalRemoveFillersEnabled
            settings.removeFalseStartsEnabled = originalRemoveFalseStartsEnabled
            settings.itnEnabled = originalITNEnabled
            settings.autoPunctuationEnabled = originalAutoPunctuationEnabled
            settings.bulletPointsEnabled = originalBulletPointsEnabled
        }

        settings.removeFillersEnabled = true
        settings.removeFalseStartsEnabled = true
        settings.itnEnabled = true
        settings.autoPunctuationEnabled = false
        settings.bulletPointsEnabled = false

        let processor = PostProcessor(dictionaryStore: DictionaryStore())
        let result = await processor.process("please fix the t rans format i on bug")

        XCTAssertEqual(result, "Please fix the transformation bug")
    }

    func testRepairsThreeLetterFragmentedWordRuns() async {
        let settings = SettingsManager.shared
        let originalRemoveFillersEnabled = settings.removeFillersEnabled
        let originalRemoveFalseStartsEnabled = settings.removeFalseStartsEnabled
        let originalITNEnabled = settings.itnEnabled
        let originalAutoPunctuationEnabled = settings.autoPunctuationEnabled
        let originalBulletPointsEnabled = settings.bulletPointsEnabled

        defer {
            settings.removeFillersEnabled = originalRemoveFillersEnabled
            settings.removeFalseStartsEnabled = originalRemoveFalseStartsEnabled
            settings.itnEnabled = originalITNEnabled
            settings.autoPunctuationEnabled = originalAutoPunctuationEnabled
            settings.bulletPointsEnabled = originalBulletPointsEnabled
        }

        settings.removeFillersEnabled = true
        settings.removeFalseStartsEnabled = true
        settings.itnEnabled = true
        settings.autoPunctuationEnabled = false
        settings.bulletPointsEnabled = false

        let processor = PostProcessor(dictionaryStore: DictionaryStore())
        let result = await processor.process("how is the meeting recording per form ing")

        XCTAssertEqual(result, "How is the meeting recording performing")
    }

    func testRepairsRecentParakeetBoundarySplits() async {
        let settings = SettingsManager.shared
        let originalRemoveFillersEnabled = settings.removeFillersEnabled
        let originalRemoveFalseStartsEnabled = settings.removeFalseStartsEnabled
        let originalITNEnabled = settings.itnEnabled
        let originalAutoPunctuationEnabled = settings.autoPunctuationEnabled
        let originalBulletPointsEnabled = settings.bulletPointsEnabled

        defer {
            settings.removeFillersEnabled = originalRemoveFillersEnabled
            settings.removeFalseStartsEnabled = originalRemoveFalseStartsEnabled
            settings.itnEnabled = originalITNEnabled
            settings.autoPunctuationEnabled = originalAutoPunctuationEnabled
            settings.bulletPointsEnabled = originalBulletPointsEnabled
        }

        settings.removeFillersEnabled = true
        settings.removeFalseStartsEnabled = true
        settings.itnEnabled = true
        settings.autoPunctuationEnabled = false
        settings.bulletPointsEnabled = false

        let processor = PostProcessor(dictionaryStore: DictionaryStore())
        let result = await processor.process(
            "meeting detect i on and t ran scripts d i ar i sat i on every thing about the user jour.ney"
        )

        XCTAssertEqual(
            result,
            "Meeting detection and transcripts diarisation everything about the user journey"
        )
    }

    func testRepairsUnderneathSplit() async {
        let settings = SettingsManager.shared
        let originalRemoveFillersEnabled = settings.removeFillersEnabled
        let originalRemoveFalseStartsEnabled = settings.removeFalseStartsEnabled
        let originalITNEnabled = settings.itnEnabled
        let originalAutoPunctuationEnabled = settings.autoPunctuationEnabled
        let originalBulletPointsEnabled = settings.bulletPointsEnabled

        defer {
            settings.removeFillersEnabled = originalRemoveFillersEnabled
            settings.removeFalseStartsEnabled = originalRemoveFalseStartsEnabled
            settings.itnEnabled = originalITNEnabled
            settings.autoPunctuationEnabled = originalAutoPunctuationEnabled
            settings.bulletPointsEnabled = originalBulletPointsEnabled
        }

        settings.removeFillersEnabled = true
        settings.removeFalseStartsEnabled = true
        settings.itnEnabled = true
        settings.autoPunctuationEnabled = false
        settings.bulletPointsEnabled = false

        let processor = PostProcessor(dictionaryStore: DictionaryStore())
        let result = await processor.process("fluid audio under neath as a dependency")

        XCTAssertEqual(result, "Fluid audio underneath as a dependency")
    }

    func testFragmentedWordRepairLeavesNormalProseIntact() async {
        let settings = SettingsManager.shared
        let originalRemoveFillersEnabled = settings.removeFillersEnabled
        let originalRemoveFalseStartsEnabled = settings.removeFalseStartsEnabled
        let originalITNEnabled = settings.itnEnabled
        let originalAutoPunctuationEnabled = settings.autoPunctuationEnabled
        let originalBulletPointsEnabled = settings.bulletPointsEnabled

        defer {
            settings.removeFillersEnabled = originalRemoveFillersEnabled
            settings.removeFalseStartsEnabled = originalRemoveFalseStartsEnabled
            settings.itnEnabled = originalITNEnabled
            settings.autoPunctuationEnabled = originalAutoPunctuationEnabled
            settings.bulletPointsEnabled = originalBulletPointsEnabled
        }

        settings.removeFillersEnabled = true
        settings.removeFalseStartsEnabled = true
        settings.itnEnabled = true
        settings.autoPunctuationEnabled = false
        settings.bulletPointsEnabled = false

        let processor = PostProcessor(dictionaryStore: DictionaryStore())
        let result = await processor.process("a test case should stay as a test case")

        XCTAssertEqual(result, "A test case should stay as a test case")
    }

    func testRepromptingIsNotLeftFragmented() async {
        let settings = SettingsManager.shared
        let originalRemoveFillersEnabled = settings.removeFillersEnabled
        let originalRemoveFalseStartsEnabled = settings.removeFalseStartsEnabled
        let originalITNEnabled = settings.itnEnabled
        let originalAutoPunctuationEnabled = settings.autoPunctuationEnabled
        let originalBulletPointsEnabled = settings.bulletPointsEnabled

        defer {
            settings.removeFillersEnabled = originalRemoveFillersEnabled
            settings.removeFalseStartsEnabled = originalRemoveFalseStartsEnabled
            settings.itnEnabled = originalITNEnabled
            settings.autoPunctuationEnabled = originalAutoPunctuationEnabled
            settings.bulletPointsEnabled = originalBulletPointsEnabled
        }

        settings.removeFillersEnabled = true
        settings.removeFalseStartsEnabled = true
        settings.itnEnabled = true
        settings.autoPunctuationEnabled = false
        settings.bulletPointsEnabled = false

        XCTAssertEqual(
            CollapsedRunRepair.repair("Reprompting with new instruction."),
            "Reprompting with new instruction."
        )
        XCTAssertEqual(
            FragmentedWordRepair.repair("Rep rompt ing with new instruction."),
            "Reprompting with new instruction."
        )

        let processor = PostProcessor(dictionaryStore: DictionaryStore())
        let result = await processor.process("Rep rompt ing with new instruction.")

        XCTAssertEqual(result, "Reprompting with new instruction.")
    }

    func testFragmentedWordRepairDoesNotCollapseCommonPhrases() {
        XCTAssertEqual(
            FragmentedWordRepair.repair("In terms of implementation, we can do that."),
            "In terms of implementation, we can do that."
        )
        XCTAssertEqual(
            FragmentedWordRepair.repair("To do that we should keep the spacing."),
            "To do that we should keep the spacing."
        )
        XCTAssertEqual(
            FragmentedWordRepair.repair("I do later today."),
            "I do later today."
        )
        XCTAssertEqual(
            FragmentedWordRepair.repair("We found a way back into the app."),
            "We found a way back into the app."
        )
        XCTAssertEqual(
            FragmentedWordRepair.repair("He says it's not from the model."),
            "He says it's not from the model."
        )
        XCTAssertEqual(
            FragmentedWordRepair.repair("It's not a feature from the model."),
            "It's not a feature from the model."
        )
        XCTAssertEqual(
            FragmentedWordRepair.repair("That wasn't a solution."),
            "That wasn't a solution."
        )
        XCTAssertEqual(
            FragmentedWordRepair.repair("There should be a better design."),
            "There should be a better design."
        )
        XCTAssertEqual(
            FragmentedWordRepair.repair("Should there should be a better design?"),
            "Should there should be a better design?"
        )
        // Regression: a run of short standalone words whose concatenation happens
        // to spell-check as one word ("gotoforatest") must not be glued. Every
        // fragment here is already a real word, so it is prose, not a split.
        XCTAssertEqual(
            FragmentedWordRepair.repair("Who can I go to for a test for this?"),
            "Who can I go to for a test for this?"
        )
        XCTAssertEqual(
            FragmentedWordRepair.repair("go to for a test"),
            "go to for a test"
        )
    }

    // MARK: - Two-fragment splits (chunk-seam boundary failures)

    func testRepairsTwoFragmentSplit() {
        XCTAssertEqual(
            FragmentedWordRepair.repair("the trans cription looks good"),
            "the transcription looks good"
        )
        XCTAssertEqual(
            FragmentedWordRepair.repair("we worked to gether on it"),
            "we worked together on it"
        )
        XCTAssertEqual(
            FragmentedWordRepair.repair("check the per formance numbers"),
            "check the performance numbers"
        )
    }

    func testTwoFragmentSplitPreservesCasingAndTrailingPunctuation() {
        XCTAssertEqual(
            FragmentedWordRepair.repair("Trans cription, then review."),
            "Transcription, then review."
        )
    }

    func testTwoFragmentRepairLeavesRealWordPairsAlone() {
        XCTAssertEqual(
            FragmentedWordRepair.repair("we meet of ten on Mondays"),
            "we meet of ten on Mondays"
        )
        XCTAssertEqual(
            FragmentedWordRepair.repair("a head of state"),
            "a head of state"
        )
        XCTAssertEqual(
            FragmentedWordRepair.repair("the in put was wrong"),
            "the in put was wrong"
        )
        XCTAssertEqual(
            FragmentedWordRepair.repair("it's not the model"),
            "it's not the model"
        )
    }

    func testTwoFragmentRepairJoinsWhenTokenTimingsAreAdjacent() {
        let timings = [
            TranscriptTokenTiming(token: "▁trans", startTime: 0.0, endTime: 0.30),
            TranscriptTokenTiming(token: "cription", startTime: 0.35, endTime: 0.70),
        ]
        XCTAssertEqual(
            FragmentedWordRepair.repair("trans cription", timings: timings),
            "transcription"
        )
    }

    func testTwoFragmentRepairBlocksJoinAcrossRealPause() {
        let timings = [
            TranscriptTokenTiming(token: "▁trans", startTime: 0.0, endTime: 0.30),
            TranscriptTokenTiming(token: "cription", startTime: 1.50, endTime: 1.90),
        ]
        XCTAssertEqual(
            FragmentedWordRepair.repair("trans cription", timings: timings),
            "trans cription"
        )
    }

    func testTwoFragmentRepairIgnoresMisalignedTimings() {
        let timings = [
            TranscriptTokenTiming(token: "▁completely", startTime: 0.0, endTime: 0.4),
            TranscriptTokenTiming(token: "▁different", startTime: 0.5, endTime: 0.9),
        ]
        XCTAssertEqual(
            FragmentedWordRepair.repair("trans cription", timings: timings),
            "transcription"
        )
    }

    func testTrailingPeriodOmitOverridesSurfaceDefaultThatWouldAppend() {
        let configuration = PostProcessingConfiguration(
            removeFillersEnabled: false,
            removeFalseStartsEnabled: false,
            itnEnabled: false,
            autoPunctuationEnabled: true,
            bulletPointsEnabled: true,
            learnedStylePolicy: StylePolicy(trailingPeriod: .omit)
        )

        let result = PostProcessingPipeline.run(
            "ship the update.",
            configuration: configuration,
            corrections: []
        )

        XCTAssertEqual(result.text, "Ship the update")
        XCTAssertEqual(result.styleApplicationProvenance.trailingPeriod?.policy, .omit)
        XCTAssertEqual(result.styleApplicationProvenance.trailingPeriod?.disposition, .changed)
    }

    func testTrailingPeriodRequireOverridesSubjectAndShortChatDefaults() {
        let base = PostProcessingConfiguration(
            removeFillersEnabled: false,
            removeFalseStartsEnabled: false,
            itnEnabled: false,
            autoPunctuationEnabled: true,
            bulletPointsEnabled: true
        )
        var defaults = SurfaceFormattingDefaults()
        defaults.suppressTrailingPunctuation = true
        defaults.chatShortMessageDefaults = true
        var preferences = DictationFormattingPreferences()
        preferences.stylePolicy.trailingPeriod = .require
        let configuration = base.applying(defaults).applying(preferences)

        let result = PostProcessingPipeline.run(
            "quarterly update",
            configuration: configuration,
            corrections: []
        )

        XCTAssertEqual(result.text, "Quarterly update.")
        XCTAssertEqual(result.styleApplicationProvenance.trailingPeriod?.policy, .require)
        XCTAssertEqual(result.styleApplicationProvenance.trailingPeriod?.disposition, .changed)
    }

    func testTrailingPeriodInheritPreservesSurfaceDefault() {
        let suppressed = PostProcessingPipeline.run(
            "quarterly update",
            configuration: PostProcessingConfiguration(
                removeFillersEnabled: false,
                removeFalseStartsEnabled: false,
                itnEnabled: false,
                autoPunctuationEnabled: true,
                bulletPointsEnabled: true,
                suppressTrailingPunctuation: true
            ),
            corrections: []
        )
        let normal = PostProcessingPipeline.run(
            "quarterly update",
            configuration: PostProcessingConfiguration(
                removeFillersEnabled: false,
                removeFalseStartsEnabled: false,
                itnEnabled: false,
                autoPunctuationEnabled: true,
                bulletPointsEnabled: true
            ),
            corrections: []
        )

        XCTAssertEqual(suppressed.text, "Quarterly update")
        XCTAssertEqual(normal.text, "Quarterly update.")
    }

    func testRequiredPeriodNeverOverridesGloballyDisabledPunctuation() {
        let requireConfiguration = PostProcessingConfiguration(
            removeFillersEnabled: false,
            removeFalseStartsEnabled: false,
            itnEnabled: false,
            autoPunctuationEnabled: false,
            bulletPointsEnabled: true,
            learnedStylePolicy: StylePolicy(trailingPeriod: .require)
        )

        let result = PostProcessingPipeline.run(
            "ship the update",
            configuration: requireConfiguration,
            corrections: []
        )
        let omitResult = PostProcessingPipeline.run(
            "ship the update.",
            configuration: PostProcessingConfiguration(
                removeFillersEnabled: false,
                removeFalseStartsEnabled: false,
                itnEnabled: false,
                autoPunctuationEnabled: false,
                bulletPointsEnabled: true,
                learnedStylePolicy: StylePolicy(trailingPeriod: .omit)
            ),
            corrections: []
        )

        XCTAssertEqual(result.text, "Ship the update")
        XCTAssertEqual(result.styleApplicationProvenance.trailingPeriod?.policy, .require)
        XCTAssertEqual(result.styleApplicationProvenance.trailingPeriod?.disposition, .vetoed)
        XCTAssertEqual(omitResult.text, "Ship the update.")
        XCTAssertEqual(omitResult.styleApplicationProvenance.trailingPeriod?.policy, .omit)
        XCTAssertEqual(omitResult.styleApplicationProvenance.trailingPeriod?.disposition, .vetoed)
    }

    func testOpeningCasePolicyChangesActualFormatterOutput() {
        let lowercase = PostProcessingPipeline.run(
            "Ship the update",
            configuration: PostProcessingConfiguration(
                removeFillersEnabled: false,
                removeFalseStartsEnabled: false,
                itnEnabled: false,
                autoPunctuationEnabled: true,
                bulletPointsEnabled: true,
                learnedStylePolicy: StylePolicy(openingCase: .lowercase)
            ),
            corrections: []
        )
        let sentenceCase = PostProcessingPipeline.run(
            "ship the update",
            configuration: PostProcessingConfiguration(
                removeFillersEnabled: false,
                removeFalseStartsEnabled: false,
                itnEnabled: false,
                autoPunctuationEnabled: true,
                bulletPointsEnabled: true,
                suppressLeadingCapitalization: true,
                learnedStylePolicy: StylePolicy(openingCase: .sentenceCase)
            ),
            corrections: []
        )

        XCTAssertEqual(lowercase.text, "ship the update.")
        XCTAssertEqual(sentenceCase.text, "Ship the update.")
        XCTAssertEqual(lowercase.styleApplicationProvenance.openingCase?.policy, .lowercase)
        XCTAssertEqual(lowercase.styleApplicationProvenance.openingCase?.disposition, .changed)
        XCTAssertEqual(sentenceCase.styleApplicationProvenance.openingCase?.policy, .sentenceCase)
        XCTAssertEqual(sentenceCase.styleApplicationProvenance.openingCase?.disposition, .changed)
    }

    func testTrailingPeriodOmitLeavesOtherTerminalPunctuationIntact() {
        let configuration = PostProcessingConfiguration(
            removeFillersEnabled: false,
            removeFalseStartsEnabled: false,
            itnEnabled: false,
            autoPunctuationEnabled: true,
            bulletPointsEnabled: true,
            learnedStylePolicy: StylePolicy(trailingPeriod: .omit)
        )

        let question = PostProcessingPipeline.run(
            "is this ready?",
            configuration: configuration,
            corrections: []
        )
        let ellipsis = PostProcessingPipeline.run(
            "wait...",
            configuration: configuration,
            corrections: []
        )

        XCTAssertEqual(question.text, "Is this ready?")
        XCTAssertEqual(ellipsis.text, "Wait...")
        XCTAssertEqual(
            question.styleApplicationProvenance.trailingPeriod?.disposition,
            .inapplicable
        )
        XCTAssertEqual(
            ellipsis.styleApplicationProvenance.trailingPeriod?.disposition,
            .inapplicable
        )
    }

    func testRequiredPeriodQuestionIsInapplicableAfterQuestionInference() {
        let result = PostProcessingPipeline.run(
            "can you ship the update",
            configuration: PostProcessingConfiguration(
                removeFillersEnabled: false,
                removeFalseStartsEnabled: false,
                itnEnabled: false,
                autoPunctuationEnabled: true,
                bulletPointsEnabled: true,
                learnedStylePolicy: StylePolicy(trailingPeriod: .require)
            ),
            corrections: []
        )

        XCTAssertEqual(result.text, "Can you ship the update?")
        XCTAssertEqual(result.styleApplicationProvenance.trailingPeriod?.policy, .require)
        XCTAssertEqual(
            result.styleApplicationProvenance.trailingPeriod?.disposition,
            .inapplicable
        )
    }

    func testTrailingPeriodPolicyUsesQuestionIntentNotQuestionMarkPresence() {
        func run(
            _ text: String,
            policy: TrailingPeriodPolicy,
            chatDefaults: Bool = false,
            flattenLineBreaks: Bool = false,
            autoPunctuationEnabled: Bool = true
        ) -> PostProcessingResult {
            PostProcessingPipeline.run(
                text,
                configuration: PostProcessingConfiguration(
                    removeFillersEnabled: false,
                    removeFalseStartsEnabled: false,
                    itnEnabled: false,
                    autoPunctuationEnabled: autoPunctuationEnabled,
                    bulletPointsEnabled: true,
                    flattenLineBreaks: flattenLineBreaks,
                    chatShortMessageDefaults: chatDefaults,
                    learnedStylePolicy: StylePolicy(trailingPeriod: policy)
                ),
                corrections: []
            )
        }

        let requiredQuestion = run("can you ship the update", policy: .require)
        XCTAssertEqual(requiredQuestion.text, "Can you ship the update?")
        XCTAssertEqual(
            requiredQuestion.styleApplicationProvenance.trailingPeriod?.disposition,
            .inapplicable
        )

        let omittedQuestion = run("can you ship the update", policy: .omit)
        XCTAssertEqual(omittedQuestion.text, "Can you ship the update?")
        XCTAssertEqual(
            omittedQuestion.styleApplicationProvenance.trailingPeriod?.disposition,
            .inapplicable
        )

        let omittedPeriodTerminatedQuestion = run(
            "can you ship the update.",
            policy: .omit
        )
        XCTAssertEqual(omittedPeriodTerminatedQuestion.text, "Can you ship the update?")
        XCTAssertEqual(
            omittedPeriodTerminatedQuestion
                .styleApplicationProvenance.trailingPeriod?.disposition,
            .inapplicable
        )

        for question in ["didn't you see it", "has the deploy finished"] {
            let result = run(question, policy: .omit)
            XCTAssertEqual(
                result.styleApplicationProvenance.trailingPeriod?.disposition,
                .inapplicable,
                question
            )
        }

        let requiredStatement = run("should work now", policy: .require)
        XCTAssertEqual(requiredStatement.text, "Should work now.")
        XCTAssertEqual(
            requiredStatement.styleApplicationProvenance.trailingPeriod?.disposition,
            .changed
        )

        let omittedStatement = run("should work now", policy: .omit)
        XCTAssertEqual(omittedStatement.text, "Should work now")
        XCTAssertEqual(
            omittedStatement.styleApplicationProvenance.trailingPeriod?.disposition,
            .alreadyConformed
        )

        let shortChatQuestion = run(
            "can you ship the update",
            policy: .omit,
            chatDefaults: true
        )
        XCTAssertEqual(shortChatQuestion.text, "Can you ship the update?")
        XCTAssertEqual(
            shortChatQuestion.styleApplicationProvenance.trailingPeriod?.disposition,
            .inapplicable
        )

        let globallyVetoedQuestion = run(
            "can you ship the update",
            policy: .omit,
            autoPunctuationEnabled: false
        )
        XCTAssertEqual(globallyVetoedQuestion.text, "Can you ship the update")
        XCTAssertEqual(
            globallyVetoedQuestion.styleApplicationProvenance.trailingPeriod?.disposition,
            .vetoed
        )

        let globallyVetoedExistingPeriod = run(
            "can you ship the update.",
            policy: .omit,
            autoPunctuationEnabled: false
        )
        XCTAssertEqual(globallyVetoedExistingPeriod.text, "Can you ship the update.")
    }

    func testFlattenedFinalClauseOwnsTrailingPeriodOpportunity() {
        func run(_ text: String) -> PostProcessingResult {
            PostProcessingPipeline.run(
                text,
                configuration: PostProcessingConfiguration(
                    removeFillersEnabled: false,
                    removeFalseStartsEnabled: false,
                    itnEnabled: false,
                    autoPunctuationEnabled: true,
                    bulletPointsEnabled: true,
                    flattenLineBreaks: true,
                    learnedStylePolicy: StylePolicy(trailingPeriod: .omit)
                ),
                corrections: []
            )
        }

        let finalQuestion = run("update\ncan you test")
        XCTAssertEqual(finalQuestion.text, "Update; Can you test?")
        XCTAssertEqual(
            finalQuestion.styleApplicationProvenance.trailingPeriod?.disposition,
            .inapplicable
        )

        let initialismFinalQuestion = run("we operate in the U.S.\ncan you verify")
        XCTAssertEqual(
            initialismFinalQuestion.text,
            "We operate in the U.S. Can you verify?"
        )
        XCTAssertEqual(
            initialismFinalQuestion.styleApplicationProvenance.trailingPeriod?.disposition,
            .inapplicable
        )

        let finalStatement = run("can you test\nupdate")
        XCTAssertEqual(finalStatement.text, "Can you test; Update")
        XCTAssertEqual(
            finalStatement.styleApplicationProvenance.trailingPeriod?.disposition,
            .alreadyConformed
        )

        let colonFinalQuestion = run("context:\ncan you test")
        XCTAssertEqual(colonFinalQuestion.text, "Context: Can you test?")
        XCTAssertEqual(
            colonFinalQuestion.styleApplicationProvenance.trailingPeriod?.disposition,
            .inapplicable
        )

        let colonFinalStatement = run("can you test:\nupdate")
        XCTAssertEqual(colonFinalStatement.text, "Can you test: Update")
        XCTAssertEqual(
            colonFinalStatement.styleApplicationProvenance.trailingPeriod?.disposition,
            .alreadyConformed
        )

        let ellipsisFinalQuestion = run("thinking…\ncan you test")
        XCTAssertEqual(ellipsisFinalQuestion.text, "Thinking… Can you test?")
        XCTAssertEqual(
            ellipsisFinalQuestion.styleApplicationProvenance.trailingPeriod?.disposition,
            .inapplicable
        )

        let ellipsisFinalStatement = run("can you test…\nupdate")
        XCTAssertEqual(ellipsisFinalStatement.text, "Can you test… Update")
        XCTAssertEqual(
            ellipsisFinalStatement.styleApplicationProvenance.trailingPeriod?.disposition,
            .alreadyConformed
        )
    }

    func testActiveListPolicyOnOrdinaryProseHasNoOpportunity() {
        let result = PostProcessingPipeline.run(
            "please ship the ordinary update",
            configuration: PostProcessingConfiguration(
                removeFillersEnabled: false,
                removeFalseStartsEnabled: false,
                itnEnabled: false,
                autoPunctuationEnabled: true,
                bulletPointsEnabled: true,
                learnedStylePolicy: StylePolicy(listMarkers: .require)
            ),
            corrections: []
        )

        XCTAssertEqual(result.text, "Please ship the ordinary update.")
        XCTAssertEqual(result.styleApplicationProvenance.listMarkers?.policy, .require)
        XCTAssertEqual(
            result.styleApplicationProvenance.listMarkers?.disposition,
            .inapplicable
        )
    }

    func testOpeningWithoutEligibleCasedLetterAndGloballyVetoedListAreExplicit() {
        let noOpening = PostProcessingPipeline.run(
            "123 !!!",
            configuration: PostProcessingConfiguration(
                removeFillersEnabled: false,
                removeFalseStartsEnabled: false,
                itnEnabled: false,
                autoPunctuationEnabled: true,
                bulletPointsEnabled: true,
                learnedStylePolicy: StylePolicy(openingCase: .sentenceCase)
            ),
            corrections: []
        )
        XCTAssertEqual(
            noOpening.styleApplicationProvenance.openingCase?.disposition,
            .inapplicable
        )

        let listVeto = PostProcessingPipeline.run(
            "first write tests second ship safely",
            configuration: PostProcessingConfiguration(
                removeFillersEnabled: false,
                removeFalseStartsEnabled: false,
                itnEnabled: false,
                autoPunctuationEnabled: true,
                bulletPointsEnabled: false,
                learnedStylePolicy: StylePolicy(listMarkers: .require)
            ),
            corrections: []
        )
        XCTAssertEqual(
            listVeto.styleApplicationProvenance.listMarkers?.disposition,
            .vetoed
        )
    }

    func testStyleProvenanceDistinguishesAlreadyConformedAndChangedOpportunities() {
        let alreadyConformed = PostProcessingPipeline.run(
            "already lowercase",
            configuration: PostProcessingConfiguration(
                removeFillersEnabled: false,
                removeFalseStartsEnabled: false,
                itnEnabled: false,
                autoPunctuationEnabled: true,
                bulletPointsEnabled: true,
                learnedStylePolicy: StylePolicy(openingCase: .lowercase)
            ),
            corrections: []
        )
        let changed = PostProcessingPipeline.run(
            "Already uppercase",
            configuration: PostProcessingConfiguration(
                removeFillersEnabled: false,
                removeFalseStartsEnabled: false,
                itnEnabled: false,
                autoPunctuationEnabled: true,
                bulletPointsEnabled: true,
                learnedStylePolicy: StylePolicy(openingCase: .lowercase)
            ),
            corrections: []
        )

        XCTAssertEqual(alreadyConformed.text, "already lowercase.")
        XCTAssertEqual(
            alreadyConformed.styleApplicationProvenance.openingCase?.disposition,
            .alreadyConformed
        )
        XCTAssertEqual(changed.text, "already uppercase.")
        XCTAssertEqual(
            changed.styleApplicationProvenance.openingCase?.disposition,
            .changed
        )
    }

    func testListPolicyRecordsRealChangedAndAlreadyConformedListOpportunities() {
        let requireResult = PostProcessingPipeline.run(
            "first write tests second ship safely",
            configuration: PostProcessingConfiguration(
                removeFillersEnabled: false,
                removeFalseStartsEnabled: false,
                itnEnabled: false,
                autoPunctuationEnabled: true,
                bulletPointsEnabled: true,
                learnedStylePolicy: StylePolicy(listMarkers: .require)
            ),
            corrections: []
        )
        let omitResult = PostProcessingPipeline.run(
            "first write tests second ship safely",
            configuration: PostProcessingConfiguration(
                removeFillersEnabled: false,
                removeFalseStartsEnabled: false,
                itnEnabled: false,
                autoPunctuationEnabled: true,
                bulletPointsEnabled: true,
                learnedStylePolicy: StylePolicy(listMarkers: .omit)
            ),
            corrections: []
        )

        XCTAssertTrue(TextFormatter.hasListMarkers(in: requireResult.text))
        XCTAssertEqual(
            requireResult.styleApplicationProvenance.listMarkers?.disposition,
            .changed
        )
        XCTAssertFalse(TextFormatter.hasListMarkers(in: omitResult.text))
        XCTAssertEqual(
            omitResult.styleApplicationProvenance.listMarkers?.disposition,
            .alreadyConformed
        )
    }
}
