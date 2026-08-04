import XCTest
@testable import Resonant

final class ArchiveWriterTests: XCTestCase {

    @MainActor
    func testDictationMarkdownLinksSuccessfullyCopiedAudio() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let recordingURL = root.appendingPathComponent("capture.wav")
        try Data([0, 1, 2, 3]).write(to: recordingURL)
        let entry = DictationEntry(
            id: UUID(),
            text: "hello world",
            appName: "Notes",
            bundleId: "com.apple.Notes",
            wordCount: 2,
            duration: 1,
            mode: .dictation,
            date: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let result = await ArchiveWriter(appSupportRoot: root).writeDictation(
            entry: entry,
            rawTranscript: nil,
            deliveredText: "hello world",
            recordingURL: recordingURL
        )

        XCTAssertTrue(result.didCopyRecordingToArchive)
        XCTAssertTrue(result.didWriteMarkdown)
        let audioPath = try XCTUnwrap(entry.audioPath)
        let audioURL = root.appendingPathComponent(audioPath)
        let markdownURL = audioURL.deletingPathExtension().appendingPathExtension("md")
        let markdown = try String(contentsOf: markdownURL, encoding: .utf8)
        XCTAssertTrue(markdown.contains("audio:"))
        XCTAssertTrue(markdown.contains(audioURL.lastPathComponent))
    }

    @MainActor
    func testDictationMarkdownIncludesVocabularyBoostDiagnosticLine() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audit = VocabularyBoostAudit(decisions: [VocabularyBoostAudit.Decision(
            outcome: .applied,
            term: "Codex",
            originalText: "model",
            guarded: false,
            originalWasRealWord: true,
            originalScore: -3.25,
            replacementScore: -1.75,
            similarity: 0.6
        )])
        let entry = DictationEntry(
            id: UUID(),
            text: "Codex",
            appName: "Notes",
            bundleId: "com.apple.Notes",
            wordCount: 1,
            duration: 1,
            mode: .dictation,
            date: Date(timeIntervalSince1970: 1_700_000_000),
            vocabularyBoostAuditSummary: VocabularyBoostAuditSummary(audit: audit)
        )

        let result = await ArchiveWriter(appSupportRoot: root).writeDictation(
            entry: entry,
            rawTranscript: "Codex",
            deliveredText: "Codex",
            recordingURL: nil
        )

        XCTAssertTrue(result.didWriteMarkdown)
        let markdown = try XCTUnwrap(markdownFiles(under: root).first)
        XCTAssertTrue(markdown.contains("## Vocabulary Boost"))
        XCTAssertTrue(markdown.contains(
            "boost: applied Codex over \"model\" (source=manual, guarded=false, realWord=true, "
                + "originalScore=-3.25, replacementScore=-1.75, sim=0.60)"
        ))
    }

    @MainActor
    func testMemoMarkdownOmitsAudioWhenRetentionIsOff() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let memo = MemoEntry(
            id: UUID(),
            text: "text only",
            title: "Text only",
            duration: 1,
            date: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let result = await ArchiveWriter(appSupportRoot: root).writeMemo(memo: memo)

        XCTAssertTrue(result.didWriteMarkdown)
        XCTAssertFalse(result.didCopyRecordingToArchive)
        let markdown = try XCTUnwrap(markdownFiles(under: root).first)
        XCTAssertFalse(markdown.contains("\naudio:"))
    }

    @MainActor
    func testMemoMarkdownUsesCopiedAudioExtension() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let audioDirectory = root.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = audioDirectory.appendingPathComponent("source.caf")
        try Data([0, 1, 2, 3]).write(to: sourceURL)
        let memo = MemoEntry(
            id: UUID(),
            text: "audio memo",
            title: "Audio memo",
            duration: 1,
            date: Date(timeIntervalSince1970: 1_700_000_000),
            audioPath: "audio/source.caf"
        )

        let result = await ArchiveWriter(appSupportRoot: root).writeMemo(memo: memo)

        XCTAssertTrue(result.didCopyRecordingToArchive)
        let markdown = try XCTUnwrap(markdownFiles(under: root).first)
        XCTAssertTrue(markdown.contains("audio:"))
        XCTAssertTrue(markdown.contains(".caf"))
        XCTAssertFalse(markdown.contains(".m4a"))
    }

    @MainActor
    func testSameSecondEntriesWithSharedUUIDPrefixDoNotCollide() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstSource = root.appendingPathComponent("first.caf")
        let secondSource = root.appendingPathComponent("second.caf")
        try Data([1]).write(to: firstSource)
        try Data([2]).write(to: secondSource)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let first = DictationEntry(
            id: UUID(uuidString: "AAAA0000-0000-0000-0000-000000000001")!,
            text: "first",
            appName: "Notes",
            bundleId: "com.apple.Notes",
            wordCount: 1,
            duration: 1,
            mode: .dictation,
            date: date
        )
        let second = DictationEntry(
            id: UUID(uuidString: "AAAA1111-0000-0000-0000-000000000002")!,
            text: "second",
            appName: "Notes",
            bundleId: "com.apple.Notes",
            wordCount: 1,
            duration: 1,
            mode: .dictation,
            date: date
        )
        let writer = ArchiveWriter(appSupportRoot: root)

        _ = await writer.writeDictation(
            entry: first,
            rawTranscript: nil,
            deliveredText: first.text,
            recordingURL: firstSource
        )
        _ = await writer.writeDictation(
            entry: second,
            rawTranscript: nil,
            deliveredText: second.text,
            recordingURL: secondSource
        )

        let firstPath = try XCTUnwrap(first.audioPath)
        let secondPath = try XCTUnwrap(second.audioPath)
        XCTAssertNotEqual(firstPath, secondPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(firstPath).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(secondPath).path))
    }

    func testUpdatedMeetingMarkdownReplacesExistingSummarySection() {
        let markdown = """
        ---
        type: meeting
        date: 2024-01-01T10:00:00Z
        ---

        # Design Review

        ## Summary

        Old summary

        ## Transcript

        **You** (0:00)
        Hello
        """

        let updated = ArchiveWriter.updatedMeetingMarkdown(
            markdown: markdown,
            newSummary: "New summary"
        )

        XCTAssertFalse(updated.contains("Old summary"))
        XCTAssertTrue(updated.contains("## Summary\n\nNew summary\n"))
        XCTAssertTrue(updated.contains("## Transcript"))
    }

    func testUpdatedMeetingMarkdownInsertsSummaryBeforeTranscriptWhenMissing() throws {
        let markdown = """
        ---
        type: meeting
        date: 2024-01-01T10:00:00Z
        ---

        # Design Review

        **Duration:** 10m

        ## Transcript

        **You** (0:00)
        Hello
        """

        let updated = ArchiveWriter.updatedMeetingMarkdown(
            markdown: markdown,
            newSummary: "Inserted summary"
        )

        let summaryRange = try XCTUnwrap(updated.range(of: "## Summary\n\nInserted summary\n"))
        let transcriptRange = try XCTUnwrap(updated.range(of: "## Transcript"))
        XCTAssertLessThan(summaryRange.lowerBound, transcriptRange.lowerBound)
    }

    private func markdownFiles(under root: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL,
                  url.pathExtension == "md",
                  !url.lastPathComponent.hasPrefix("_") else { return nil }
            return try? String(contentsOf: url, encoding: .utf8)
        }
    }
}
