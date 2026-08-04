import XCTest
@testable import Resonant

final class MeetingSpeakerDiarizerSmokeTests: XCTestCase {
    func testSortformerDiarizerFindsMultipleSpeakersInSmokeFixture() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let audioPath = environment["RESONANT_DIARIZER_SMOKE_AUDIO"], !audioPath.isEmpty else {
            throw XCTSkip("Set RESONANT_DIARIZER_SMOKE_AUDIO to a multi-speaker audio file to run the diarizer smoke test.")
        }

        guard MeetingSpeakerDiarizer.isDownloaded() else {
            throw XCTSkip("Sortformer speaker model is not downloaded.")
        }

        let expectedSpeakers = Int(environment["RESONANT_DIARIZER_EXPECTED_SPEAKERS"] ?? "") ?? 3
        let audioURL = URL(fileURLWithPath: audioPath)
        let preparedInput = try TranscriberAudioSupport.preparedInput(from: audioURL)
        let samples = preparedInput.preparedSamples
        let durationSeconds = Float(samples.count) / 16_000

        let diarizer = MeetingSpeakerDiarizer()
        defer { diarizer.cleanup() }
        try await diarizer.prepare(allowDownload: false)

        let chunkSize = 16_000
        var offset = 0
        while offset < samples.count {
            let end = min(offset + chunkSize, samples.count)
            diarizer.feedAudio(Array(samples[offset..<end]))
            offset = end
        }

        var detectedSpeakerIndices = Set<Int>()
        var start: Float = 0
        while start < durationSeconds {
            let end = min(start + 2, durationSeconds)
            if let speakerIndex = diarizer.dominantSpeaker(from: start, to: end) {
                detectedSpeakerIndices.insert(speakerIndex)
            }
            start += 0.5
        }

        XCTAssertGreaterThanOrEqual(
            detectedSpeakerIndices.count,
            expectedSpeakers,
            "Expected at least \(expectedSpeakers) speaker slots in \(audioURL.lastPathComponent); got \(detectedSpeakerIndices.sorted())"
        )
    }
}
