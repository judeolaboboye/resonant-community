import XCTest
@testable import Resonant

final class SmartLinkProcessorTests: XCTestCase {

    func testProcessReplacesMatchingTriggerCaseInsensitively() {
        let processor = SmartLinkProcessor()
        let links = [
            SmartLink(trigger: "open github", url: "https://github.com", label: "GitHub")
        ]

        let (result, matchCount) = processor.process("Please OPEN GITHUB for the repo.", links: links)

        XCTAssertEqual(result, "Please [GitHub](https://github.com) for the repo.")
        XCTAssertEqual(matchCount, 1)
    }

    func testProcessPrefersLongestOverlappingTrigger() {
        let processor = SmartLinkProcessor()
        let links = [
            SmartLink(trigger: "github", url: "https://github.com/resonance"),
            SmartLink(trigger: "open github", url: "https://github.com")
        ]

        let (result, matchCount) = processor.process("I pushed it to open github", links: links)

        XCTAssertEqual(result, "I pushed it to [open github](https://github.com)")
        XCTAssertEqual(matchCount, 1)
    }
}
