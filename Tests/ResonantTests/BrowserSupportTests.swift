import Foundation
import XCTest
@testable import Resonant

final class BrowserSupportTests: XCTestCase {

    func testCommonMeetingBrowsersAreRecognized() {
        XCTAssertTrue(BrowserCatalog.isBrowser("com.brave.Browser"))
        XCTAssertEqual(BrowserCatalog.displayName(for: "com.brave.Browser"), "Brave")

        XCTAssertTrue(BrowserCatalog.isBrowser("org.mozilla.firefox"))
        XCTAssertEqual(BrowserCatalog.displayName(for: "org.mozilla.firefox"), "Firefox")

        XCTAssertTrue(BrowserCatalog.isBrowser("com.operasoftware.Opera"))
        XCTAssertEqual(BrowserCatalog.displayName(for: "com.operasoftware.Opera"), "Opera")

        XCTAssertTrue(BrowserCatalog.isBrowser("com.operasoftware.OperaGX"))
        XCTAssertEqual(BrowserCatalog.displayName(for: "com.operasoftware.OperaGX"), "Opera GX")
    }

    func testWebsiteDisplayPrefersWebsiteTitleAndHost() {
        let display = BrowserWebsiteDisplay.from(
            windowTitle: "PAR-123 Improve dictation context - Linear - Brave",
            browserURL: "https://linear.app/example-workspace/issue/PAR-123",
            bundleId: "com.brave.Browser"
        )

        XCTAssertEqual(display?.title, "Linear")
        XCTAssertEqual(display?.subtitle, "Brave · linear.app")
        XCTAssertNil(display?.faviconURL)
    }

    func testWebsiteDisplayFallsBackToHostWhenWindowTitleCannotBeParsed() {
        let display = BrowserWebsiteDisplay.from(
            windowTitle: "New Tab",
            browserURL: "https://github.com/openai/openai-python",
            bundleId: "com.brave.Browser"
        )

        XCTAssertEqual(display?.title, "github.com")
        XCTAssertEqual(display?.subtitle, "Brave · github.com")
    }

    // MARK: - URL detection (looksLikeURL)

    func testLooksLikeURLMatchesFullURLs() {
        XCTAssertTrue(ContextExtractor.looksLikeURL("https://threads.net/@user"))
        XCTAssertTrue(ContextExtractor.looksLikeURL("http://example.com"))
    }

    func testLooksLikeURLMatchesBareDomains() {
        XCTAssertTrue(ContextExtractor.looksLikeURL("threads.net"))
        XCTAssertTrue(ContextExtractor.looksLikeURL("linear.app/resonance/issue/PAR-1"))
        XCTAssertTrue(ContextExtractor.looksLikeURL("github.com"))
    }

    func testLooksLikeURLRejectsNonURLs() {
        XCTAssertFalse(ContextExtractor.looksLikeURL("Search or enter address"))
        XCTAssertFalse(ContextExtractor.looksLikeURL("hello world"))
        XCTAssertFalse(ContextExtractor.looksLikeURL(""))
        XCTAssertFalse(ContextExtractor.looksLikeURL("file.3"))  // numeric TLD-like part
    }

    func testWebsiteDisplayFallsBackToWindowTitleWhenNoURL() {
        let display = BrowserWebsiteDisplay.from(
            windowTitle: "Threads - Brave",
            browserURL: nil,
            bundleId: "com.brave.Browser"
        )

        XCTAssertEqual(display?.title, "Threads")
        XCTAssertEqual(display?.subtitle, "Brave")
        XCTAssertNil(display?.faviconURL)
    }

    func testWebsiteDisplayReturnsNilWhenNoURLAndUnparseableTitle() {
        let display = BrowserWebsiteDisplay.from(
            windowTitle: "New Tab",
            browserURL: nil,
            bundleId: "com.brave.Browser"
        )

        XCTAssertNil(display)
    }

    func testWebsiteDisplayWorksWithBareURL() {
        let display = BrowserWebsiteDisplay.from(
            windowTitle: "Threads - Brave",
            browserURL: "https://threads.net",
            bundleId: "com.brave.Browser"
        )

        XCTAssertEqual(display?.title, "Threads")
        XCTAssertEqual(display?.subtitle, "Brave · threads.net")
        XCTAssertNil(display?.faviconURL)
    }

    func testWebsiteDisplayNormalizesThreadsTabTitleFromAutomationFallback() {
        let display = BrowserWebsiteDisplay.from(
            windowTitle: "alex / Threads - Brave",
            browserURL: "https://threads.net/@alex",
            bundleId: "com.brave.Browser"
        )

        XCTAssertEqual(display?.title, "Threads")
        XCTAssertEqual(display?.subtitle, "Brave · threads.net")
        XCTAssertNil(display?.faviconURL)
    }
}
