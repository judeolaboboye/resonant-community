import XCTest
@testable import Resonant

final class NumberListSegmenterTests: XCTestCase {

    /// One token per word with the requested inter-word gaps.
    private func timings(for words: [String], gaps: [Double]) -> [TranscriptTokenTiming] {
        precondition(gaps.count == words.count - 1)
        var result: [TranscriptTokenTiming] = []
        var clock = 0.0
        for (index, word) in words.enumerated() {
            let duration = 0.3
            result.append(TranscriptTokenTiming(token: word, startTime: clock, endTime: clock + duration))
            clock += duration
            if index < gaps.count {
                clock += gaps[index]
            }
        }
        return result
    }

    private func delimit(_ text: String, gaps: [Double]) -> String {
        let words = text.split(separator: " ").map(String.init)
        return NumberListSegmenter.delimit(text, timings: timings(for: words, gaps: gaps))
    }

    func testPausesBetweenNumbersBecomeCommas() {
        XCTAssertEqual(
            delimit(
                "seven eleven seventeen nineteen twenty three",
                gaps: [0.5, 0.5, 0.5, 0.5, 0.1]
            ),
            "seven, eleven, seventeen, nineteen, twenty three"
        )
    }

    func testFluentRunStaysJoined() {
        XCTAssertEqual(
            delimit("nineteen ninety nine", gaps: [0.1, 0.1]),
            "nineteen ninety nine"
        )
    }

    func testSingleDigitCodeNeverSplits() {
        // Digit-by-digit codes and phone numbers are dictated with exactly
        // these pauses; a pair of single digits must never split.
        XCTAssertEqual(
            delimit("four seven one", gaps: [0.5, 0.5]),
            "four seven one"
        )
    }

    func testParagraphGapLeftToPauseSegmenter() {
        XCTAssertEqual(
            delimit("seven eleven seventeen", gaps: [1.8, 0.5]),
            "seven eleven, seventeen"
        )
    }

    func testTwoNumberRunUntouched() {
        XCTAssertEqual(delimit("seven eleven", gaps: [0.5]), "seven eleven")
    }

    func testProseUntouched() {
        XCTAssertEqual(
            delimit("we shipped seven products yesterday", gaps: [0.5, 0.5, 0.5, 0.5]),
            "we shipped seven products yesterday"
        )
    }

    func testMisalignedTimingsBail() {
        let wrongTimings = timings(for: ["totally", "different", "words"], gaps: [0.5, 0.5])
        XCTAssertEqual(
            NumberListSegmenter.delimit("seven eleven seventeen", timings: wrongTimings),
            "seven eleven seventeen"
        )
    }

    // MARK: - End-to-end pipeline

    func testPipelineProducesDigitListFromPausedDictation() {
        let text = "i picked seven eleven twenty three"
        let words = text.split(separator: " ").map(String.init)
        let tokenTimings = timings(for: words, gaps: [0.05, 0.05, 0.5, 0.5, 0.05])
        let configuration = PostProcessingConfiguration(
            removeFillersEnabled: false,
            removeFalseStartsEnabled: false,
            itnEnabled: true,
            autoPunctuationEnabled: true,
            bulletPointsEnabled: false
        )
        let result = PostProcessingPipeline.run(
            text,
            configuration: configuration,
            corrections: [],
            contextPacket: nil,
            tokenTimings: tokenTimings,
            language: nil
        )
        XCTAssertTrue(result.text.contains("7, 11, 23"), result.text)
    }
}
