import XCTest
@testable import Resonant

final class AccessibilityPlaceholderFilterTests: XCTestCase {

    func testCodexBypassesAXValueInsertion() {
        XCTAssertTrue(
            AccessibilityPlaceholderFilter.shouldBypassAXValueInsertion(
                bundleID: AccessibilityPlaceholderFilter.codexBundleID
            )
        )
        XCTAssertFalse(
            AccessibilityPlaceholderFilter.shouldBypassAXValueInsertion(
                bundleID: "com.apple.TextEdit"
            )
        )
    }

    func testCMUXAppUsesAXInsertionFirst() {
        XCTAssertFalse(
            AccessibilityPlaceholderFilter.shouldBypassAXValueInsertion(
                bundleID: "com.conductor.app",
                windowTitle: "CMUX"
            )
        )
    }

    func testClaudeWebBypassesAXValueInsertion() {
        XCTAssertTrue(
            AccessibilityPlaceholderFilter.shouldBypassAXValueInsertion(
                bundleID: "com.google.Chrome",
                windowTitle: "Claude",
                browserURL: "https://claude.ai/chat/123"
            )
        )
    }

    func testLinkedInWebBypassesAXValueInsertion() {
        XCTAssertTrue(
            AccessibilityPlaceholderFilter.shouldBypassAXValueInsertion(
                bundleID: "com.google.Chrome",
                windowTitle: "Messaging | LinkedIn",
                browserURL: "https://www.linkedin.com/messaging/thread/123"
            )
        )
    }

    func testSanitizesCodexFollowUpPlaceholder() {
        XCTAssertEqual(
            AccessibilityPlaceholderFilter.sanitizeFocusedFieldValue(
                "\nAsk for follow-up changes",
                bundleID: AccessibilityPlaceholderFilter.codexBundleID
            ),
            ""
        )
    }

    func testSanitizesCodexComposerPlaceholder() {
        XCTAssertEqual(
            AccessibilityPlaceholderFilter.sanitizeFocusedFieldValue(
                "Ask Codex anything, @ to add files, / for commands, $ for skills",
                bundleID: AccessibilityPlaceholderFilter.codexBundleID
            ),
            ""
        )
    }

    func testPreservesRealCodexDraftText() {
        let text = "Can you review this patch before I send it?"
        XCTAssertEqual(
            AccessibilityPlaceholderFilter.sanitizeFocusedFieldValue(
                text,
                bundleID: AccessibilityPlaceholderFilter.codexBundleID
            ),
            text
        )
    }

    func testSanitizesClaudeWebReplyPlaceholder() {
        XCTAssertEqual(
            AccessibilityPlaceholderFilter.sanitizeFocusedFieldValue(
                "Reply...",
                bundleID: "com.google.Chrome",
                windowTitle: "Claude",
                browserURL: "https://claude.ai/chat/123"
            ),
            ""
        )
    }

    func testPreservesReplySentenceOutsideClaude() {
        let text = "Reply tomorrow morning once the build finishes."
        XCTAssertEqual(
            AccessibilityPlaceholderFilter.sanitizeFocusedFieldValue(
                text,
                bundleID: "com.google.Chrome",
                windowTitle: "GitHub",
                browserURL: "https://github.com/openai/openai-python"
            ),
            text
        )
    }

    func testSanitizesGenericAXPlaceholderMatch() {
        XCTAssertEqual(
            AccessibilityPlaceholderFilter.sanitizeFocusedFieldValue(
                "Type a message",
                bundleID: "com.apple.TextEdit",
                placeholderValue: "Type a message"
            ),
            ""
        )
    }
}
