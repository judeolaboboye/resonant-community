import XCTest
@testable import Resonant

final class MeetingEchoSuppressorTests: XCTestCase {

    private func utterance(_ text: String, speaker: MeetingSpeaker, at offset: TimeInterval) -> MeetingUtterance {
        MeetingUtterance(
            text: text,
            speaker: speaker,
            timestamp: Date(timeIntervalSince1970: offset)
        )
    }

    // MARK: - Basic Suppression

    func testSuppressesIdenticalUtteranceWithinWindow() {
        var mic = [utterance("the quick brown fox jumps over", speaker: .you, at: 10.0)]
        let system = [utterance("the quick brown fox jumps over", speaker: .them, at: 10.5)]

        MeetingEchoSuppressor.suppress(micUtterances: &mic, systemUtterances: system)

        XCTAssertTrue(mic.isEmpty)
    }

    func testKeepsUtteranceOutsideTimeWindow() {
        var mic = [utterance("the quick brown fox jumps over", speaker: .you, at: 10.0)]
        let system = [utterance("the quick brown fox jumps over", speaker: .them, at: 15.0)]

        MeetingEchoSuppressor.suppress(micUtterances: &mic, systemUtterances: system)

        XCTAssertEqual(mic.count, 1)
    }

    func testKeepsShortUtterancesBelowMinimumWordCount() {
        var mic = [utterance("yes okay", speaker: .you, at: 10.0)]
        let system = [utterance("yes okay", speaker: .them, at: 10.2)]

        MeetingEchoSuppressor.suppress(micUtterances: &mic, systemUtterances: system)

        XCTAssertEqual(mic.count, 1, "Utterances below minimum word count should not be suppressed")
    }

    // MARK: - Similarity Thresholds

    func testSuppressesHighJaccardSimilarity() {
        // Same words, minor difference — should exceed 0.78 threshold
        var mic = [utterance("we should schedule the follow up meeting soon", speaker: .you, at: 10.0)]
        let system = [utterance("we should schedule the follow up meeting", speaker: .them, at: 10.3)]

        MeetingEchoSuppressor.suppress(micUtterances: &mic, systemUtterances: system)

        XCTAssertTrue(mic.isEmpty)
    }

    func testKeepsLowSimilarityUtterances() {
        var mic = [utterance("I think we should revisit the architecture", speaker: .you, at: 10.0)]
        let system = [utterance("the deployment pipeline needs more testing capacity", speaker: .them, at: 10.3)]

        MeetingEchoSuppressor.suppress(micUtterances: &mic, systemUtterances: system)

        XCTAssertEqual(mic.count, 1)
    }

    // MARK: - Subset Detection

    func testSuppressesMicSubsetOfSystem() {
        var mic = [utterance("the project timeline looks good", speaker: .you, at: 10.0)]
        let system = [utterance("the project timeline looks good and we can proceed", speaker: .them, at: 10.2)]

        MeetingEchoSuppressor.suppress(micUtterances: &mic, systemUtterances: system)

        XCTAssertTrue(mic.isEmpty)
    }

    func testSuppressesSystemSubsetOfMic() {
        var mic = [utterance("the project timeline looks good and we can proceed", speaker: .you, at: 10.0)]
        let system = [utterance("the project timeline looks good", speaker: .them, at: 10.2)]

        MeetingEchoSuppressor.suppress(micUtterances: &mic, systemUtterances: system)

        XCTAssertTrue(mic.isEmpty)
    }

    // MARK: - Edge Cases

    func testNoOpWithEmptySystemUtterances() {
        var mic = [utterance("hello world this is a test", speaker: .you, at: 10.0)]

        MeetingEchoSuppressor.suppress(micUtterances: &mic, systemUtterances: [])

        XCTAssertEqual(mic.count, 1)
    }

    func testNoOpWithEmptyMicUtterances() {
        var mic: [MeetingUtterance] = []
        let system = [utterance("hello world this is a test", speaker: .them, at: 10.0)]

        MeetingEchoSuppressor.suppress(micUtterances: &mic, systemUtterances: system)

        XCTAssertTrue(mic.isEmpty)
    }

    func testSelectivelySuppressesFromMultipleMicUtterances() {
        var mic = [
            utterance("the quarterly report needs final review before submission", speaker: .you, at: 10.0),
            utterance("I agree we should prioritize the mobile release", speaker: .you, at: 15.0),
            utterance("the quarterly report needs final review before submission", speaker: .you, at: 20.0),
        ]
        let system = [
            utterance("the quarterly report needs final review before submission", speaker: .them, at: 10.2),
            utterance("the quarterly report needs final review before submission", speaker: .them, at: 20.1),
        ]

        MeetingEchoSuppressor.suppress(micUtterances: &mic, systemUtterances: system)

        XCTAssertEqual(mic.count, 1)
        XCTAssertEqual(mic[0].text, "I agree we should prioritize the mobile release")
    }

    func testCustomWindowParameter() {
        var mic = [utterance("the design review is scheduled for next week", speaker: .you, at: 10.0)]
        let system = [utterance("the design review is scheduled for next week", speaker: .them, at: 11.0)]

        // 0.5s window — 1.0s delta should NOT suppress
        MeetingEchoSuppressor.suppress(micUtterances: &mic, systemUtterances: system, window: 0.5)

        XCTAssertEqual(mic.count, 1)
    }
}
