import XCTest
@testable import Resonant

@MainActor
final class BrowserAutomationSupportTests: XCTestCase {

    func testBraveAppleScriptFallbackReturnsTabContext() {
        let context = BrowserAutomationSupport.activeTabContext(bundleId: "com.brave.Browser") { source in
            XCTAssertTrue(source.contains("tell application id \"com.brave.browser\""))
            XCTAssertTrue(source.contains("title of active tab of front window"))
            XCTAssertTrue(source.contains("URL of active tab of front window"))
            return "Threads\u{1F}https://threads.net/@resonance"
        }

        XCTAssertEqual(context?.windowTitle, "Threads - Brave")
        XCTAssertEqual(context?.browserURL, "https://threads.net/@resonance")
    }

    func testOperaAppleScriptFallbackUsesChromiumTabAPI() {
        let context = BrowserAutomationSupport.activeTabContext(bundleId: "com.operasoftware.Opera") { source in
            XCTAssertTrue(source.contains("tell application id \"com.operasoftware.opera\""))
            XCTAssertTrue(source.contains("title of active tab of front window"))
            XCTAssertTrue(source.contains("URL of active tab of front window"))
            return "Standup\u{1F}https://meet.google.com/abc-defg-hij"
        }

        XCTAssertEqual(context?.windowTitle, "Standup - Opera")
        XCTAssertEqual(context?.browserURL, "https://meet.google.com/abc-defg-hij")
    }

    func testFirefoxIsNotAppleScriptTabScannable() {
        XCTAssertNil(BrowserAutomationSupport.scriptSource(for: "org.mozilla.firefox"))
        XCTAssertFalse(BrowserAutomationSupport.allScriptableBrowserBundleIDs().contains("org.mozilla.firefox"))
    }

    func testSafariAppleScriptFallbackUsesFrontDocument() {
        let context = BrowserAutomationSupport.activeTabContext(bundleId: "com.apple.Safari") { source in
            XCTAssertTrue(source.contains("tell application id \"com.apple.safari\""))
            XCTAssertTrue(source.contains("name of front document"))
            XCTAssertTrue(source.contains("URL of front document"))
            return "Apple\u{1F}https://apple.com"
        }

        XCTAssertEqual(context?.windowTitle, "Apple - Safari")
        XCTAssertEqual(context?.browserURL, "https://apple.com")
    }

    func testFallbackContextSkipsWhenAXAlreadyProvidedTitleAndURL() {
        let context = BrowserAutomationSupport.fallbackContext(
            bundleId: "com.brave.Browser",
            currentWindowTitle: "Threads",
            currentURL: "https://threads.net"
        )

        XCTAssertNil(context)
    }

    func testParseTabContextRejectsMalformedOutput() {
        XCTAssertNil(BrowserAutomationSupport.parseTabContext("Threads only"))
        XCTAssertNil(BrowserAutomationSupport.parseTabContext("\u{1F}"))
    }

    func testParseTabContextNormalizesBareURLs() {
        let context = BrowserAutomationSupport.parseTabContext("Threads\u{1F}threads.net")

        XCTAssertEqual(context?.windowTitle, "Threads")
        XCTAssertEqual(context?.browserURL, "https://threads.net")
    }

    func testAllTabContextsBuildsNoPromptTabScanScript() {
        let contexts = BrowserAutomationSupport.allTabContexts(
            bundleId: "com.google.Chrome",
            allowUserPrompt: true
        ) { source in
            XCTAssertTrue(source.contains("resonant_all_browser_tabs"))
            XCTAssertTrue(source.contains("repeat with browserWindow in windows"))
            XCTAssertTrue(source.contains("repeat with tabRef in tabs of browserWindow"))
            return [
                "Inbox\u{1F}https://mail.google.com/mail/u/0/#inbox",
                "Team sync\u{1F}https://meet.google.com/abc-defg-hij",
            ].joined(separator: "\n")
        }

        XCTAssertEqual(
            contexts,
            [
                BrowserAutomationSupport.TabContext(
                    windowTitle: "Inbox",
                    browserURL: "https://mail.google.com/mail/u/0/#inbox"
                ),
                BrowserAutomationSupport.TabContext(
                    windowTitle: "Team sync",
                    browserURL: "https://meet.google.com/abc-defg-hij"
                ),
            ]
        )
    }

    func testPauseSupportedMediaTabsBuildsChromiumTabScanScript() {
        let pausedTabs = BrowserAutomationSupport.pauseSupportedMediaTabs(bundleId: "com.google.Chrome") { source in
            XCTAssertTrue(source.contains("resonant_media_pause_supported_tabs"))
            XCTAssertTrue(source.contains("repeat with browserWindow in windows"))
            XCTAssertTrue(source.contains("repeat with tabRef in tabs of browserWindow"))
            XCTAssertTrue(source.contains("execute tabRef javascript"))
            return "https://www.youtube.com/watch?v=abc123\nhttps://soundcloud.com/example/set"
        }

        XCTAssertEqual(
            pausedTabs,
            [
                BrowserAutomationSupport.MediaTabSession(browserURL: "https://www.youtube.com/watch?v=abc123"),
                BrowserAutomationSupport.MediaTabSession(browserURL: "https://soundcloud.com/example/set"),
            ]
        )
    }

    func testResumeMediaTabTargetsSpecificSafariURL() {
        let resumed = BrowserAutomationSupport.resumeMediaTab(
            bundleId: "com.apple.Safari",
            browserURL: "https://www.youtube.com/watch?v=abc123"
        ) { source in
            XCTAssertTrue(source.contains("resonant_media_resume_matching_url"))
            XCTAssertTrue(source.contains("set targetURL to \"https://www.youtube.com/watch?v=abc123\""))
            XCTAssertTrue(source.contains("do JavaScript"))
            return "ok"
        }

        XCTAssertTrue(resumed)
    }
}
