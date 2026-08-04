import XCTest
@testable import Resonant

final class DispatchCommandActionParserTests: XCTestCase {
    func testParsesMarkdownFencedTypeTextAction() throws {
        let action = try DispatchCommandActionParser.parse(
            """
            ```json
            {"action":"type_text","text":"Done","app_hint":"Slack"}
            ```
            """
        )

        guard case .typeText(let text, let appHint) = action else {
            return XCTFail("Expected typeText action")
        }
        XCTAssertEqual(text, "Done")
        XCTAssertEqual(appHint, "Slack")
    }

    func testParsesCompositeActionRecursively() throws {
        let action = try DispatchCommandActionParser.parse(
            """
            {
              "action": "composite",
              "actions": [
                {"action": "open_url", "url": "https://google.com/search?q=weather"},
                {"action": "speak_answer", "text": "Opened weather."}
              ]
            }
            """
        )

        guard case .composite(let actions) = action else {
            return XCTFail("Expected composite action")
        }
        XCTAssertEqual(actions.count, 2)
        guard case .openURL(let url) = actions[0] else {
            return XCTFail("Expected first action to open URL")
        }
        XCTAssertEqual(url, "https://google.com/search?q=weather")
        guard case .speakAnswer(let text) = actions[1] else {
            return XCTFail("Expected second action to speak")
        }
        XCTAssertEqual(text, "Opened weather.")
    }

    func testUnknownActionThrowsTypedCommandError() {
        XCTAssertThrowsError(try DispatchCommandActionParser.parse(#"{"action":"unknown"}"#)) { error in
            guard case CommandError.unknownAction("unknown") = error else {
                return XCTFail("Expected unknownAction error")
            }
        }
    }
}
