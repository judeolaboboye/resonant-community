import XCTest
@testable import Resonant

final class CapturedContextTests: XCTestCase {

    func testCapturedContextNormalizesEmptyValuesAndDeduplicatesSnippets() {
        let context = CapturedContext(
            appName: "  Mail  ",
            bundleId: " ",
            windowTitle: "\nCompose\n",
            visibleTextSnippets: [" hello ", "", "hello", "world "]
        )

        XCTAssertEqual(context.appName, "Mail")
        XCTAssertNil(context.bundleId)
        XCTAssertEqual(context.windowTitle, "Compose")
        XCTAssertEqual(context.visibleTextSnippets, ["hello", "world"])
    }

    func testAmbientPolicyDropsSelectedTextAndTruncatesRichFields() {
        let extractorContext = ContextExtractor.Context(
            appName: "Safari",
            bundleId: "com.apple.Safari",
            windowTitle: "Inbox",
            selectedText: "secret selection",
            selectedRange: nil,
            browserURL: "https://mail.proton.me",
            codeFiles: [],
            slackMembers: [],
            focusedFieldContent: String(repeating: "a", count: 5000),
            visibleTextSnippets: Array(repeating: "snippet", count: 120)
        )

        let stored = LocalContextPersistencePolicy.ambientContext(from: extractorContext)

        XCTAssertNil(stored.selectedText)
        XCTAssertEqual(stored.focusedFieldContent?.count, LocalContextPersistencePolicy.ambientMaxFieldCharacters)
        XCTAssertEqual(stored.visibleTextSnippets.count, 1)
    }

    func testDictationEntryRoundTripsCapturedContext() {
        let context = CapturedContext(
            appName: "Safari",
            bundleId: "com.apple.Safari",
            windowTitle: "Compose",
            browserURL: "https://mail.proton.me",
            codeFileName: "AppState.swift",
            slackRecipient: "Alice Doe",
            selectedText: "draft body",
            focusedFieldContent: "hello world",
            visibleTextSnippets: ["snippet one", "snippet two"]
        )

        let entry = DictationEntry.make(
            id: UUID(),
            text: "hello world",
            context: context,
            wordCount: 2,
            duration: 1,
            mode: .dictation,
            date: .now
        )

        XCTAssertEqual(entry.capturedContext, context)
    }
}
