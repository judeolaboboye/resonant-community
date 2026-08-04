import XCTest
@testable import Resonant

final class DictationReplayHarnessTests: XCTestCase {

    // MARK: - Scoring

    func testMatchesEditedWhenPipelineNowProducesUserEdit() {
        // The user reformatted the old bullet output into a numbered list —
        // exactly what the pipeline produces today.
        let cases = [
            DictationReplayCase(
                id: "numbered-list",
                rawTranscript: "first buy milk second call john",
                pastedText: "- First buy milk\n- Second call john",
                editedText: "1. Buy milk\n2. Call john"
            )
        ]
        let report = DictationReplayHarness.replay(cases)
        XCTAssertEqual(report.matchesEdited, 1)
        XCTAssertEqual(report.regressed, 0)
        XCTAssertEqual(report.outcomes[0].reproducedPaste, false)
    }

    func testImprovedWhenOutputMovesCloserToUserEdit() {
        let cases = [
            DictationReplayCase(
                id: "closer",
                rawTranscript: "the budget is fifty percent bigger now",
                pastedText: "The budget is fifty percent bigger now.",
                editedText: "The budget is 50% bigger right now."
            )
        ]
        let report = DictationReplayHarness.replay(cases)
        XCTAssertEqual(report.improved, 1, report.summaryText())
    }

    func testUnchangedWhenUserEditIsContentOnly() {
        // User swapped a word the pipeline could never know about; distance
        // before and after is identical.
        let cases = [
            DictationReplayCase(
                id: "content-edit",
                rawTranscript: "Send it to the whole team.",
                pastedText: "Send it to the whole team.",
                editedText: "Send it to the design team."
            )
        ]
        let report = DictationReplayHarness.replay(cases)
        XCTAssertEqual(report.unchanged, 1, report.summaryText())
        XCTAssertEqual(report.outcomes[0].reproducedPaste, true)
    }

    func testRegressedWhenOutputMovesAwayFromUserEdit() {
        // The user kept the spoken phrase verbatim, but today's pipeline
        // converts it to a list — moving away from what this user wanted.
        let cases = [
            DictationReplayCase(
                id: "list-not-wanted",
                rawTranscript: "bullet point milk bullet point eggs",
                pastedText: "bullet point milk bullet point eggs",
                editedText: "bullet point milk bullet point eggs"
            )
        ]
        let report = DictationReplayHarness.replay(cases)
        XCTAssertEqual(report.regressed, 1, report.summaryText())
        XCTAssertEqual(report.regressions.count, 1)
    }

    func testUnscoredWithoutEditedText() {
        let cases = [
            DictationReplayCase(
                id: "stability-only",
                rawTranscript: "hello there",
                pastedText: "Hello there."
            )
        ]
        let report = DictationReplayHarness.replay(cases)
        XCTAssertEqual(report.scoredCases, 0)
        XCTAssertEqual(report.reproducedPastes, 1)
        XCTAssertEqual(report.pasteComparableCases, 1)
    }

    // MARK: - JSONL round-trip

    func testJSONLRoundTrip() throws {
        let original = [
            DictationReplayCase(
                id: "a",
                rawTranscript: "raw one",
                pastedText: "pasted one",
                editedText: "edited one",
                appName: "Slack",
                surfaceKind: "chat"
            ),
            DictationReplayCase(id: "b", rawTranscript: "raw two"),
        ]
        let jsonl = try DictationReplayHarness.jsonl(from: original)
        XCTAssertEqual(jsonl.split(separator: "\n").count, 2)
        let decoded = try DictationReplayHarness.cases(fromJSONL: jsonl)
        XCTAssertEqual(decoded, original)
    }

    func testJSONLSkipsBlankLines() throws {
        let jsonl = """

        {"id":"x","rawTranscript":"hello"}

        """
        let decoded = try DictationReplayHarness.cases(fromJSONL: jsonl)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].id, "x")
    }

    // MARK: - Export from stored history

    func testExportFromCorrectionEvents() {
        let event = DictationCorrectionEvent(
            appName: "Slack",
            surfaceKind: "chat",
            rawTranscriptPreview: "raw words",
            pastedTextPreview: "Raw words.",
            editedTextPreview: "Raw words!",
            hadCorrection: true
        )
        let missingRaw = DictationCorrectionEvent(
            pastedTextPreview: "no raw stored",
            editedTextPreview: "no raw stored",
            hadCorrection: false
        )
        let cases = DictationReplayHarness.cases(from: [event, missingRaw])
        XCTAssertEqual(cases.count, 1)
        XCTAssertEqual(cases[0].rawTranscript, "raw words")
        XCTAssertEqual(cases[0].pastedText, "Raw words.")
        XCTAssertEqual(cases[0].editedText, "Raw words!")
        XCTAssertEqual(cases[0].appName, "Slack")
        XCTAssertEqual(cases[0].surfaceKind, "chat")
    }

    func testExportFromDictationEntries() {
        let entry = DictationEntry(
            id: UUID(),
            text: "Final text.",
            appName: "Mail",
            bundleId: "com.apple.mail",
            wordCount: 2,
            duration: 1,
            mode: .dictation,
            date: Date(timeIntervalSince1970: 0),
            rawTranscript: "final text",
            deliveredText: "Final text."
        )
        let cases = DictationReplayHarness.cases(from: [entry])
        XCTAssertEqual(cases.count, 1)
        XCTAssertEqual(cases[0].rawTranscript, "final text")
        XCTAssertEqual(cases[0].pastedText, "Final text.")
        XCTAssertNil(cases[0].editedText)
    }

    // MARK: - Report rendering

    func testSummaryTextListsRegressions() {
        let cases = [
            DictationReplayCase(
                id: "reg-1",
                rawTranscript: "bullet point milk bullet point eggs",
                pastedText: "bullet point milk bullet point eggs",
                editedText: "bullet point milk bullet point eggs"
            )
        ]
        let summary = DictationReplayHarness.replay(cases).summaryText()
        XCTAssertTrue(summary.contains("REGRESSED reg-1"), summary)
    }

    // MARK: - Real corpus (opt-in)

    /// Export real data with DictationReplayHarness.jsonl(from:) and point
    /// RESONANT_REPLAY_CORPUS at the file to replay it under `swift test`.
    func testReplayRealCorpusWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["RESONANT_REPLAY_CORPUS"] else {
            throw XCTSkip("RESONANT_REPLAY_CORPUS not set")
        }
        let report = try DictationReplayHarness.replay(
            contentsOfJSONL: URL(fileURLWithPath: path)
        )
        print(report.summaryText())
        XCTAssertGreaterThan(report.totalCases, 0)
        XCTAssertEqual(
            report.regressed, 0,
            "Pipeline regressions against real user edits:\n" + report.summaryText()
        )
    }
}
