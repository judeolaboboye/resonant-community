import Foundation
import XCTest
@testable import Resonant

final class TextInputTargetProfileTests: XCTestCase {

    func testClaudeWebDisablesAXInsertionAndComposerContext() {
        let profile = TextInputTargetProfile(
            bundleID: "com.google.Chrome",
            windowTitle: "Claude",
            browserURL: "https://claude.ai/chat/abc"
        )

        XCTAssertTrue(profile.bypassesAXValueInsertion)
        XCTAssertFalse(profile.capturesFocusedFieldValue)
        XCTAssertFalse(profile.collectsVisibleTextSnippets)
        XCTAssertFalse(profile.requiresVerifiedKeyboardDelivery)
        XCTAssertEqual(profile.autoSendDelay, .milliseconds(220))
    }

    func testCodexUsesKeyboardPasteWithoutAXInsertion() {
        let profile = TextInputTargetProfile(
            bundleID: "com.openai.codex",
            windowTitle: "Codex"
        )

        XCTAssertTrue(profile.bypassesAXValueInsertion)
        XCTAssertFalse(profile.prefersDirectTyping)
        XCTAssertFalse(profile.requiresVerifiedKeyboardDelivery)
        XCTAssertFalse(profile.capturesFocusedFieldValue)
        XCTAssertFalse(profile.collectsVisibleTextSnippets)
        XCTAssertEqual(profile.autoSendDelay, .milliseconds(180))
    }

    func testConductorAppUsesAXInsertionFirst() {
        let profile = TextInputTargetProfile(
            bundleID: "com.conductor.app",
            windowTitle: "CMUX"
        )

        XCTAssertEqual(profile.kind, .cmuxApp)
        // Conductor is a Tauri/WKWebView (WebKit) app, not Chromium/Electron.
        // WebKit honors AX value writes (they fire DOM input events) and that
        // path is immune to Secure Event Input from Conductor's terminal panes,
        // so it must NOT bypass AX insertion. (Cmd+V remains the fallback.)
        XCTAssertFalse(profile.bypassesAXValueInsertion)
        XCTAssertTrue(profile.bypassesCorrectionReadback)
        XCTAssertFalse(profile.prefersDirectTyping)
        XCTAssertFalse(profile.requiresVerifiedKeyboardDelivery)
        XCTAssertTrue(profile.capturesFocusedFieldValue)
        XCTAssertTrue(profile.collectsVisibleTextSnippets)
        XCTAssertEqual(profile.autoSendDelay, .milliseconds(180))
    }

    func testGoogleDocsWebDisablesAXInsertionButKeepsContextCapture() {
        let profile = TextInputTargetProfile(
            bundleID: "com.google.Chrome",
            windowTitle: "Quarterly Plan - Google Docs",
            browserURL: "https://docs.google.com/document/d/123/edit"
        )

        XCTAssertTrue(profile.bypassesAXValueInsertion)
        XCTAssertFalse(profile.bypassesCorrectionReadback)
        XCTAssertFalse(profile.prefersDirectTyping)
        XCTAssertTrue(profile.capturesFocusedFieldValue)
        XCTAssertTrue(profile.collectsVisibleTextSnippets)
        XCTAssertEqual(profile.autoSendDelay, .milliseconds(80))
    }

    func testGmailWebBypassesAXInsertionButAllowsCorrectionReadback() {
        let profile = TextInputTargetProfile(
            bundleID: "com.google.Chrome",
            windowTitle: "Follow up - Gmail",
            browserURL: "https://mail.google.com/mail/u/0/#inbox"
        )

        XCTAssertTrue(profile.bypassesAXValueInsertion)
        XCTAssertFalse(profile.bypassesCorrectionReadback)
        XCTAssertTrue(profile.capturesFocusedFieldValue)
        XCTAssertTrue(profile.collectsVisibleTextSnippets)
    }

    func testGoogleDocsWindowTitleFallbackDisablesAXInsertion() {
        let profile = TextInputTargetProfile(
            bundleID: "com.google.Chrome",
            windowTitle: "Meeting Notes - Google Docs"
        )

        XCTAssertTrue(profile.bypassesAXValueInsertion)
        XCTAssertFalse(profile.isChatComposerSurface)
    }

    func testBraveWindowTitleFallbackUsesBrowserClassification() {
        let profile = TextInputTargetProfile(
            bundleID: "com.brave.Browser",
            windowTitle: "Meeting Notes - Google Docs"
        )

        XCTAssertTrue(profile.bypassesAXValueInsertion)
        XCTAssertFalse(profile.isChatComposerSurface)
    }

    func testLinkedInWebDisablesAXInsertionWithoutSuppressingContextCapture() {
        let profile = TextInputTargetProfile(
            bundleID: "com.google.Chrome",
            windowTitle: "Messaging | LinkedIn",
            browserURL: "https://www.linkedin.com/messaging/thread/123"
        )

        XCTAssertTrue(profile.bypassesAXValueInsertion)
        XCTAssertFalse(profile.bypassesCorrectionReadback)
        XCTAssertFalse(profile.prefersDirectTyping)
        XCTAssertTrue(profile.capturesFocusedFieldValue)
        XCTAssertTrue(profile.collectsVisibleTextSnippets)
        XCTAssertFalse(profile.isChatComposerSurface)
        XCTAssertEqual(profile.autoSendDelay, .milliseconds(220))
    }

    func testDiscordDesktopDisablesAXInsertionAndComposerContext() {
        let profile = TextInputTargetProfile(
            bundleID: "com.hnc.discord",
            windowTitle: "Discord"
        )

        XCTAssertTrue(profile.bypassesAXValueInsertion)
        XCTAssertTrue(profile.bypassesCorrectionReadback)
        XCTAssertFalse(profile.capturesFocusedFieldValue)
        XCTAssertFalse(profile.collectsVisibleTextSnippets)
    }

    func testGhosttyPrefersDirectTypingWithoutSuppressingContextCapture() {
        let profile = TextInputTargetProfile(
            bundleID: "com.mitchellh.ghostty",
            windowTitle: "Ghostty"
        )

        XCTAssertTrue(profile.bypassesAXValueInsertion)
        XCTAssertTrue(profile.bypassesCorrectionReadback)
        XCTAssertTrue(profile.prefersDirectTyping)
        XCTAssertTrue(profile.capturesFocusedFieldValue)
        XCTAssertTrue(profile.collectsVisibleTextSnippets)
        XCTAssertEqual(profile.autoSendDelay, .milliseconds(80))
    }

    func testVSCodeBypassesAXAndUsesKeyboardPaste() {
        let profile = TextInputTargetProfile(
            bundleID: "com.microsoft.VSCode",
            windowTitle: "my-project — Visual Studio Code"
        )

        XCTAssertTrue(profile.bypassesAXValueInsertion)
        XCTAssertTrue(profile.bypassesCorrectionReadback)
        XCTAssertFalse(profile.prefersDirectTyping)
        XCTAssertTrue(profile.capturesFocusedFieldValue)
        XCTAssertTrue(profile.collectsVisibleTextSnippets)
        XCTAssertFalse(profile.isChatComposerSurface)
        XCTAssertEqual(profile.autoSendDelay, .milliseconds(80))
    }

    func testFirefoxEngineBypassesAXInsertionButKeepsContextCapture() {
        let firefox = TextInputTargetProfile(
            bundleID: "org.mozilla.firefox",
            windowTitle: "GitHub - Firefox"
        )
        XCTAssertTrue(firefox.bypassesAXValueInsertion)
        XCTAssertFalse(firefox.prefersDirectTyping)
        XCTAssertTrue(firefox.capturesFocusedFieldValue)
        XCTAssertTrue(firefox.collectsVisibleTextSnippets)

        let zen = TextInputTargetProfile(
            bundleID: "app.zen-browser.desktop",
            windowTitle: "GitHub - Zen"
        )
        XCTAssertTrue(zen.bypassesAXValueInsertion)
        XCTAssertFalse(zen.prefersDirectTyping)
        XCTAssertTrue(zen.capturesFocusedFieldValue)
    }

    func testUnknownSurfaceKeepsRichContextAndAXInsertion() {
        let profile = TextInputTargetProfile(
            bundleID: "com.apple.TextEdit",
            windowTitle: "Notes"
        )

        XCTAssertFalse(profile.bypassesAXValueInsertion)
        XCTAssertTrue(profile.capturesFocusedFieldValue)
        XCTAssertTrue(profile.collectsVisibleTextSnippets)
        XCTAssertEqual(profile.autoSendDelay, .milliseconds(80))
    }
}
