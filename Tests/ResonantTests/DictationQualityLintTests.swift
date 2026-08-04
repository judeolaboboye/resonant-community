import XCTest
@testable import Resonant

final class DictationQualityLintTests: XCTestCase {
    func testDetectsNumericIdiom() {
        let result = DictationQualityLint.evaluate(
            originalTranscript: "allow me to review the brief one last time",
            candidateText: "Allow me to review the brief 1 last time.",
            profile: .emailFull,
            appKey: "email",
            surfaceKind: "email"
        )

        XCTAssertEqual(result.issues, [.numericIdiom])
        XCTAssertEqual(result.policy.mode, .polished)
        XCTAssertEqual(
            DictationQualityLint.applyLocalRepairs(to: "Allow me to review the brief 1 last time.", policy: result.policy),
            "Allow me to review the brief one last time."
        )
    }

    func testDetectsAndRepairsCollapsedWordRun() {
        let result = DictationQualityLint.evaluate(
            originalTranscript: "Iproposeditto",
            candidateText: "Iproposeditto",
            profile: .default,
            appKey: "docs",
            surfaceKind: "docs"
        )

        XCTAssertEqual(result.issues, [.collapsedWordRun])
        XCTAssertEqual(result.policy.mode, .polished)
        XCTAssertEqual(
            DictationQualityLint.applyLocalRepairs(to: "Iproposeditto", policy: result.policy),
            "I proposed it to"
        )
        XCTAssertEqual(
            DictationQualityLint.applyLocalRepairs(to: "theyneededit", policy: result.policy),
            "they needed it"
        )
    }

    func testDetectsMalformedEmailClosing() {
        let result = DictationQualityLint.evaluate(
            originalTranscript: "best regards alex",
            candidateText: "Best regards to Alex.",
            profile: .emailFull,
            appKey: "email",
            surfaceKind: "email"
        )

        XCTAssertEqual(result.issues, [.malformedEmailClosing])
    }

    func testDetectsUnformattedEmailEnvelope() {
        let result = DictationQualityLint.evaluate(
            originalTranscript: "hi jamie thank you best regards alex",
            candidateText: "Hi Jamie, thank you for sending this over. Best regards, Alex.",
            profile: .emailFull,
            appKey: "email",
            surfaceKind: "email"
        )

        XCTAssertEqual(result.issues, [.unformattedEmailEnvelope])
    }

    func testDetectsLongUnstructuredDocsText() {
        let candidate = """
        The launch plan has three parts. First we need to finish the project brief and make sure the Nimbus talking points are accurate. Second we need to confirm the production timeline with Jamie so everyone knows when drafts are due. Third we need to package the reporting plan so the team can see what is working. I also want to make sure we keep the next steps clear because the last few updates have been scattered across email and chat.
        """

        let result = DictationQualityLint.evaluate(
            originalTranscript: candidate,
            candidateText: candidate,
            profile: .default,
            appKey: "docs",
            surfaceKind: "docs"
        )

        XCTAssertEqual(result.issues, [.longUnstructuredText])
        XCTAssertEqual(result.policy.mode, .structured)
    }

    func testLongUnstructuredTextWordThresholdEdges() {
        let below = prose(wordCount: 69, sentenceCount: 4)
        XCTAssertFalse(lintIssues(for: below).contains(.longUnstructuredText))

        let exact = prose(wordCount: 70, sentenceCount: 4)
        XCTAssertTrue(lintIssues(for: exact).contains(.longUnstructuredText))
    }

    func testLongUnstructuredTextCharacterThresholdEdges() {
        let below = prose(exactCharacterCount: 419)
        XCTAssertFalse(lintIssues(for: below).contains(.longUnstructuredText))

        let exact = prose(exactCharacterCount: 420)
        XCTAssertTrue(lintIssues(for: exact).contains(.longUnstructuredText))
    }

    func testLongUnstructuredTextRequiresFourSentences() {
        let threeSentences = prose(wordCount: 70, sentenceCount: 3)
        XCTAssertFalse(lintIssues(for: threeSentences).contains(.longUnstructuredText))

        let fourSentences = prose(wordCount: 70, sentenceCount: 4)
        XCTAssertTrue(lintIssues(for: fourSentences).contains(.longUnstructuredText))
    }

    func testDoesNotStructureLongChatText() {
        let candidate = """
        The launch plan has three parts. First we need to finish the project brief and make sure the Nimbus talking points are accurate. Second we need to confirm the production timeline with Jamie so everyone knows when drafts are due. Third we need to package the reporting plan so the team can see what is working. I also want to make sure we keep the next steps clear because the last few updates have been scattered across email and chat.
        """

        let result = DictationQualityLint.evaluate(
            originalTranscript: candidate,
            candidateText: candidate,
            profile: .message,
            appKey: "chat",
            surfaceKind: "chat"
        )

        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertEqual(result.policy.mode, .clean)
    }

    func testVerbatimPolicyDoesNotApplyLocalRepairs() {
        let result = DictationQualityLint.evaluate(
            originalTranscript: "grep one last time",
            candidateText: "grep 1 last time",
            profile: .default,
            appKey: "terminal",
            surfaceKind: "terminal"
        )

        XCTAssertEqual(result.policy.mode, .verbatim)
        XCTAssertEqual(
            DictationQualityLint.applyLocalRepairs(to: "grep 1 last time", policy: result.policy),
            "grep 1 last time"
        )
    }

    func testRejectsIncidentCleanupThatDeletesWaveformClause() {
        let original = """
        One Thijs that I'm noticing is that the web socket is failing to the application… So I don't see the waveform, I don't see the login capability. It's Kind regards to get into the app.
        """
        let candidate = """
        1 Thijs that I'm noticing is that the web socket is failing to the application… So I don't see the login capability. Is Kind regards to get into the app.
        """

        let decision = DictationCleanupCandidateGate.resolve(
            original: original,
            candidate: candidate
        )
        let lint = DictationQualityLint.evaluate(
            originalTranscript: original,
            candidateText: candidate,
            profile: .default,
            appKey: "docs",
            surfaceKind: "docs"
        )

        XCTAssertFalse(decision.accepted)
        XCTAssertEqual(decision.issue, .parallelClauseContentDeletion)
        XCTAssertTrue(decision.text.contains("I don't see the waveform"))
        XCTAssertTrue(lint.issues.contains(.parallelClauseContentDeletion))
    }

    func testParallelClauseRejectionAnnotatesFallbackTrace() {
        let decision = DictationCleanupCandidateGate.resolve(
            original: "I don't see the waveform, I don't see the login capability.",
            candidate: "I don't see the login capability."
        )

        let trace = decision.applying(to: .skipped(reason: "placeholder"))

        XCTAssertEqual(trace.status, .fallbackLocal)
        XCTAssertEqual(trace.accepted, false)
        XCTAssertEqual(trace.fallbackReason, "parallel_clause_content_deletion")
        XCTAssertEqual(trace.qualityIssues, ["parallel_clause_content_deletion"])
    }

    func testAllowsDashMarkedSelfCorrectionToCollapse() {
        let decision = DictationCleanupCandidateGate.resolve(
            original: "I went to the— I drove to the store.",
            candidate: "I drove to the store."
        )

        XCTAssertTrue(decision.accepted)
        XCTAssertEqual(decision.text, "I drove to the store.")
    }

    func testAllowsLongSharedPrefixDashRepair() {
        let decision = DictationCleanupCandidateGate.resolve(
            original: "I think the launch plan needs a review— I think the launch plan needs a rewrite.",
            candidate: "I think the launch plan needs a rewrite."
        )

        XCTAssertTrue(decision.accepted)
    }

    func testAllowsIntactParallelClauses() {
        let text = "I don't see the waveform, I don't see the login capability."

        XCTAssertTrue(DictationCleanupCandidateGate.resolve(
            original: text,
            candidate: text
        ).accepted)
    }

    func testAllowsClauseDropWhenDistinctiveContentSurvivesElsewhere() {
        let decision = DictationCleanupCandidateGate.resolve(
            original: "Waveform details matter. I don't see the waveform, I don't see the login capability.",
            candidate: "Waveform details matter. I don't see the login capability."
        )

        XCTAssertTrue(decision.accepted)
    }

    func testRejectsDeletionOfEntireParallelClauseBlock() {
        let decision = DictationCleanupCandidateGate.resolve(
            original: "I don't see the waveform, I don't see the login capability. Everything is broken.",
            candidate: "Everything is broken."
        )

        XCTAssertFalse(decision.accepted)
        XCTAssertEqual(decision.issue, .parallelClauseContentDeletion)
    }

    func testRejectsDeletionFromTwoTokenParallelFrame() {
        let decision = DictationCleanupCandidateGate.resolve(
            original: "We need waveform support, we need login support.",
            candidate: "We need login support."
        )

        XCTAssertFalse(decision.accepted)
        XCTAssertEqual(decision.issue, .parallelClauseContentDeletion)
    }

    func testNoPrefixDoesNotDisableParallelClauseProtection() {
        let decision = DictationCleanupCandidateGate.resolve(
            original: "No users can see the waveform, no users can see the login button.",
            candidate: "No users can see the login button."
        )

        XCTAssertFalse(decision.accepted)
        XCTAssertEqual(decision.issue, .parallelClauseContentDeletion)
    }

    @MainActor
    func testPipelineRejectsIncidentCandidateWithoutQualityRepairCall() async {
        let original = """
        One Thijs that I'm noticing is that the web socket is failing to the application… So I don't see the waveform, I don't see the login capability. It's Kind regards to get into the app.
        """
        let candidate = """
        1 Thijs that I'm noticing is that the web socket is failing to the application… So I don't see the login capability. Is Kind regards to get into the app.
        """
        var cleanupCalls = 0
        var repairCalls = 0
        var pipeline = makePipeline()
        pipeline.cleanupResultProvider = {
            cleanupCalls += 1
            return ConvexClient.DictationCleanupResult(
                text: candidate,
                trace: Self.acceptedCleanupTrace
            )
        }
        pipeline.qualityRepairResultProvider = {
            repairCalls += 1
            return .notAttempted(reason: "unexpected")
        }

        let outcome = await pipeline.resolve(
            transcript: original,
            result: makeTranscriptionResult(text: original),
            emailMode: .nonEmail
        )

        XCTAssertEqual(cleanupCalls, 1)
        XCTAssertEqual(repairCalls, 0)
        XCTAssertTrue(outcome.text.contains("I don't see the waveform"))
        XCTAssertEqual(outcome.cleanup.status, .fallbackLocal)
        XCTAssertEqual(outcome.cleanup.fallbackReason, "parallel_clause_content_deletion")
        XCTAssertTrue(outcome.cleanup.qualityIssues.contains("parallel_clause_content_deletion"))
    }

    @MainActor
    func testQualityRepairCannotBypassParallelClauseGate() async {
        let original = """
        I don't see the waveform, I don't see the login capability. The launch plan has three parts. First we need to finish the project brief and make sure the Nimbus talking points are accurate. Second we need to confirm the production timeline with Jamie so everyone knows when drafts are due. Third we need to package the reporting plan so the team can see what is working. I also want to keep the next steps clear because the last updates were scattered across email and chat.
        """
        let destructiveRepair = """
        The login capability is missing.

        Launch plan:
        - Finish the project brief and verify the Nimbus talking points.
        - Confirm the production timeline with Jamie.
        - Package the reporting plan and clarify next steps.
        """
        var cleanupCalls = 0
        var repairCalls = 0
        var pipeline = makePipeline()
        pipeline.cleanupResultProvider = {
            cleanupCalls += 1
            return ConvexClient.DictationCleanupResult(
                text: original,
                trace: Self.acceptedCleanupTrace
            )
        }
        pipeline.qualityRepairResultProvider = {
            repairCalls += 1
            return ConvexClient.DictationQualityRepairResult(
                text: destructiveRepair,
                attempted: true,
                accepted: true,
                rejectReason: nil,
                clientDurationMs: 1,
                serverDurationMs: 1
            )
        }

        let outcome = await pipeline.resolve(
            transcript: original,
            result: makeTranscriptionResult(text: original),
            emailMode: .nonEmail
        )

        XCTAssertEqual(cleanupCalls, 1)
        XCTAssertEqual(repairCalls, 1)
        XCTAssertTrue(outcome.text.contains("I don't see the waveform"))
        XCTAssertEqual(outcome.cleanup.qualityRepairAccepted, false)
        XCTAssertEqual(
            outcome.cleanup.qualityRepairRejectReason,
            "parallel_clause_content_deletion"
        )
        XCTAssertTrue(
            outcome.cleanup.qualityIssuesAfterRepair.contains("parallel_clause_content_deletion")
        )
    }

    @MainActor
    func testCleanupTraceRecordsOnlySanitizedLearnedCloudSubmission() async throws {
        let learned = ContextEntity(
            type: .customTerm,
            value: "RetainedProduct",
            normalizedValue: "retainedproduct",
            spokenForms: ["retained product"],
            source: .correctionMemory,
            confidence: 0.95,
            recencyScore: 0.1,
            proximityScore: 0.8,
            trustTier: .biasTerm,
            isSensitive: false,
            evidence: "test",
            surfaceScope: "docs",
            appScope: "com.cognition.devin",
            siteScope: nil,
            projectScope: nil
        )
        let packet = ContextPacketBuilder.build(
            transcript: "Please write a detailed project update covering the launch plan and tomorrow's review.",
            hot: ContextExtractor.HotContext(
                appName: "Devin",
                bundleId: "com.cognition.devin",
                windowTitle: "Project notes"
            ),
            personalizationSnapshot: PersonalizationMemorySnapshot(
                entities: [learned],
                biasTerms: [learned.value],
                styleHint: "Prefer concise learned phrasing."
            )
        )
        var pipeline = makePipeline()
        pipeline.cleanupResultProvider = {
            ConvexClient.DictationCleanupResult(
                text: "Please write a detailed project update covering the launch plan and tomorrow's review.",
                trace: Self.acceptedCleanupTrace
            )
        }

        let outcome = await pipeline.resolve(
            transcript: "Please write a detailed project update covering the launch plan and tomorrow's review.",
            result: makeTranscriptionResult(
                text: "Please write a detailed project update covering the launch plan and tomorrow's review.",
                contextPacket: packet
            ),
            emailMode: .nonEmail
        )

        XCTAssertEqual(outcome.cleanup.contextPersonalizationCloudEntitySubmittedCount, 1)
        XCTAssertTrue(outcome.cleanup.contextPersonalizationCloudStyleSubmitted)
    }

    @MainActor
    private func makePipeline() -> DictationCleanupPipeline {
        DictationCleanupPipeline(
            convexClient: ConvexClient(authManager: AuthManager()),
            cloudProcessingEnabled: true,
            lowLatencyMode: false,
            isLoggedIn: true,
            fallbackSenderName: nil,
            recentTexts: []
        )
    }

    private static let acceptedCleanupTrace = DictationQualityTrace.Cleanup(
        status: .accepted,
        profile: "default",
        listIntent: "none",
        attempted: true,
        accepted: true,
        path: "test",
        fallbackReason: nil,
        sanitizerRejectReason: nil,
        clientDurationMs: 1,
        serverDurationMs: 1
    )

    private func makeTranscriptionResult(
        text: String,
        contextPacket: ContextPacket? = nil
    ) -> TranscriptionResult {
        TranscriptionResult(
            text: text,
            rawTranscript: text,
            duration: 1,
            captureDiagnostics: nil,
            recordingURL: nil,
            selectedText: nil,
            selectedRange: nil,
            targetApp: "Devin",
            targetBundleId: "com.cognition.devin",
            windowTitle: "Devin",
            browserURL: nil,
            codeFileName: nil,
            slackRecipient: nil,
            focusedFieldContent: nil,
            visibleTextSnippets: nil,
            contextPacket: contextPacket
        )
    }

    private func lintIssues(for text: String) -> [DictationQualityIssue] {
        DictationQualityLint.evaluate(
            originalTranscript: text,
            candidateText: text,
            profile: .default,
            appKey: "docs",
            surfaceKind: "docs"
        ).issues
    }

    private func prose(wordCount: Int, sentenceCount: Int) -> String {
        precondition(wordCount >= sentenceCount)
        var remaining = wordCount
        return (0..<sentenceCount).map { index in
            let sentencesLeft = sentenceCount - index
            let wordsInSentence = remaining / sentencesLeft
            remaining -= wordsInSentence
            var words = Array(repeating: "word", count: wordsInSentence)
            words[0] = "Team"
            return words.joined(separator: " ") + "."
        }.joined(separator: " ")
    }

    private func prose(exactCharacterCount: Int) -> String {
        let prefix = "Alpha beta. Gamma delta. Epsilon zeta. Eta "
        let suffix = "."
        let fillCount = exactCharacterCount - prefix.count - suffix.count
        precondition(fillCount > 0)
        return prefix + String(repeating: "x", count: fillCount) + suffix
    }
}
