import XCTest
@testable import Resonant

final class MeetingSessionWriterTests: XCTestCase {

    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Reconstruct from JSONL

    func testReconstructParsesValidJSONL() throws {
        let lines = [
            #"{"speaker":"you","text":"Hello everyone","timestamp":"2023-11-14T14:13:20Z"}"#,
            #"{"speaker":"them","text":"Hey there","timestamp":"2023-11-14T14:13:25Z"}"#,
        ]
        let data = lines.joined(separator: "\n").data(using: .utf8)!

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).jsonl")
        try data.write(to: tmpURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: tmpURL) }

        let utterances = MeetingSessionWriter.reconstruct(from: tmpURL)

        XCTAssertEqual(utterances.count, 2)
        XCTAssertEqual(utterances[0].speaker, .you)
        XCTAssertEqual(utterances[0].text, "Hello everyone")
        XCTAssertEqual(utterances[1].speaker, .them)
        XCTAssertEqual(utterances[1].text, "Hey there")
    }

    func testReconstructSkipsMalformedLines() throws {
        let lines = [
            #"{"speaker":"you","text":"Valid line","timestamp":"2023-11-14T14:13:20Z"}"#,
            "not json at all",
            #"{"speaker":"them","text":"Also valid","timestamp":"2023-11-14T14:13:30Z"}"#,
        ]
        let data = lines.joined(separator: "\n").data(using: .utf8)!

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).jsonl")
        try data.write(to: tmpURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: tmpURL) }

        let utterances = MeetingSessionWriter.reconstruct(from: tmpURL)

        XCTAssertEqual(utterances.count, 2)
        XCTAssertEqual(utterances[0].text, "Valid line")
        XCTAssertEqual(utterances[1].text, "Also valid")
    }

    func testReconstructReturnsEmptyForMissingFile() {
        let bogusURL = URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString).jsonl")
        let utterances = MeetingSessionWriter.reconstruct(from: bogusURL)

        XCTAssertTrue(utterances.isEmpty)
    }

    func testReconstructReturnsEmptyForEmptyFile() throws {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).jsonl")
        try Data().write(to: tmpURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: tmpURL) }

        let utterances = MeetingSessionWriter.reconstruct(from: tmpURL)

        XCTAssertTrue(utterances.isEmpty)
    }

    func testReconstructPreservesParticipantSpeaker() throws {
        let lines = [
            #"{"speaker":"participant:SPEAKER_0","text":"From speaker zero","timestamp":"2023-11-14T14:13:20Z"}"#,
        ]
        let data = lines.joined(separator: "\n").data(using: .utf8)!

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).jsonl")
        try data.write(to: tmpURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: tmpURL) }

        let utterances = MeetingSessionWriter.reconstruct(from: tmpURL)

        XCTAssertEqual(utterances.count, 1)
        XCTAssertEqual(utterances[0].speaker, .participant(id: "SPEAKER_0"))
    }

    // MARK: - Write + Reconstruct Round-Trip

    func testWriterRoundTrip() async throws {
        let sessionID = UUID()
        let writer = try MeetingSessionWriter(sessionID: sessionID)

        let u1 = MeetingUtterance(text: "First utterance here", speaker: .you, timestamp: fixedDate)
        let u2 = MeetingUtterance(text: "Second utterance here", speaker: .them, timestamp: fixedDate.addingTimeInterval(5))

        await writer.append(u1)
        await writer.append(u2)

        let recorded = await writer.recordedUtterances
        XCTAssertEqual(recorded.count, 2)

        let closed = await writer.close()
        XCTAssertEqual(closed.count, 2)
        XCTAssertEqual(closed[0].text, "First utterance here")
        XCTAssertEqual(closed[1].text, "Second utterance here")

        // Reconstruct from the JSONL file
        let jsonlURL = AppSupportPaths.resonantRoot()
            .appendingPathComponent("meetings-active")
            .appendingPathComponent("\(sessionID.uuidString).jsonl")

        let reconstructed = MeetingSessionWriter.reconstruct(from: jsonlURL)
        XCTAssertEqual(reconstructed.count, 2)
        XCTAssertEqual(reconstructed[0].speaker, .you)
        XCTAssertEqual(reconstructed[0].text, "First utterance here")
        XCTAssertEqual(reconstructed[1].speaker, .them)
        XCTAssertEqual(reconstructed[1].text, "Second utterance here")

        // Cleanup
        await writer.deleteFile()
    }
}
