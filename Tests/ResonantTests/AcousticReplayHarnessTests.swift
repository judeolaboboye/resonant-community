import Foundation
import XCTest
@testable import Resonant

/// Opt-in acoustic regression harness. It never downloads models or audio.
/// Point `RESONANT_ASR_REPLAY_MANIFEST` at JSONL records such as:
/// {"id":"short-hello","audioPath":"clips/hello.wav","expectedText":"hello","modelId":"parakeet-tdt-0.6b-v3","language":"en","maximumWER":0.25,"maximumCER":0.20,"maximumRTF":0.5,"requireValidTimings":true,"requireAlignedTimings":true}
final class AcousticReplayHarnessTests: XCTestCase {

    func testLocalAcousticCorpusWhenProvided() async throws {
        guard let manifestPath = ProcessInfo.processInfo.environment["RESONANT_ASR_REPLAY_MANIFEST"] else {
            throw XCTSkip("RESONANT_ASR_REPLAY_MANIFEST not set")
        }

        let manifestURL = URL(fileURLWithPath: manifestPath)
        let cases = try loadCases(from: manifestURL)
        XCTAssertFalse(cases.isEmpty, "Acoustic replay manifest is empty")

        var measurements: [Measurement] = []
        var adapters: [String: any Transcriber] = [:]

        for replayCase in cases {
            let modelID = replayCase.modelId ?? "parakeet-tdt-0.6b-v3"
            let adapter: any Transcriber
            if let cached = adapters[modelID] {
                adapter = cached
            } else {
                adapter = try makeLocalAdapter(id: modelID)
                guard adapter.isDownloaded else {
                    XCTFail("Model \(modelID) is not installed; the replay harness never downloads")
                    continue
                }
                try await adapter.load()
                adapters[modelID] = adapter
            }

            let audioURL = URL(fileURLWithPath: replayCase.audioPath, relativeTo: manifestURL.deletingLastPathComponent())
                .standardizedFileURL
            let samples = try DictationAudioAnalyzer.loadMono16kSamples(from: audioURL)
            let audioSeconds = Double(samples.count) / Double(DictationAudioAnalyzer.sampleRate)
            let clock = ContinuousClock()
            let start = clock.now
            let detailed = try await adapter.transcribeDetailed(
                audioSamples: samples,
                language: replayCase.language
            )
            let elapsed = start.duration(to: clock.now)
            let elapsedSeconds = elapsed.secondsValue
            let referenceWords = words(replayCase.expectedText)
            let hypothesisWords = words(detailed.text)
            let referenceCharacters = Array(normalizedCharacters(replayCase.expectedText))
            let hypothesisCharacters = Array(normalizedCharacters(detailed.text))
            guard !referenceWords.isEmpty, !referenceCharacters.isEmpty else {
                XCTFail("\(replayCase.id) has an empty normalized reference")
                continue
            }
            let wordEdits = editDistance(reference: referenceWords, hypothesis: hypothesisWords)
            let characterEdits = editDistance(
                reference: referenceCharacters,
                hypothesis: hypothesisCharacters
            )
            let wer = Double(wordEdits) / Double(referenceWords.count)
            let cer = Double(characterEdits) / Double(referenceCharacters.count)
            let timingValid = validTimingSequence(
                detailed.tokenTimings,
                audioSeconds: audioSeconds
            )
            let timingAligned = timingValid
                && normalizedCharacters(detailed.tokenTimings.map(\.token).joined())
                    == normalizedCharacters(detailed.text)

            let measurement = Measurement(
                id: replayCase.id,
                modelID: modelID,
                durationBucket: durationBucket(audioSeconds),
                referenceWordCount: referenceWords.count,
                wordEditCount: wordEdits,
                referenceCharacterCount: referenceCharacters.count,
                characterEditCount: characterEdits,
                wer: wer,
                cer: cer,
                processingMilliseconds: Int((elapsedSeconds * 1_000).rounded()),
                realTimeFactor: audioSeconds > 0 ? elapsedSeconds / audioSeconds : 0,
                timingValid: timingValid,
                timingAligned: timingAligned
            )
            measurements.append(measurement)

            XCTAssertLessThanOrEqual(
                wer,
                replayCase.maximumWER,
                "\(replayCase.id) exceeded its WER budget: \(detailed.text)"
            )
            XCTAssertLessThanOrEqual(
                cer,
                replayCase.maximumCER,
                "\(replayCase.id) exceeded its CER budget: \(detailed.text)"
            )
            XCTAssertLessThanOrEqual(
                measurement.realTimeFactor,
                replayCase.maximumRTF,
                "\(replayCase.id) exceeded its RTF budget"
            )
            if replayCase.requireValidTimings {
                XCTAssertTrue(timingValid, "\(replayCase.id) returned invalid token timings")
            }
            if replayCase.requireAlignedTimings {
                XCTAssertTrue(timingAligned, "\(replayCase.id) returned text-misaligned token timings")
            }
        }

        XCTAssertFalse(measurements.isEmpty)
        print(report(measurements))
    }

    private func makeLocalAdapter(id: String) throws -> any Transcriber {
        switch id {
        case "parakeet-tdt-0.6b-v3":
            return FluidAudioAdapter()
        case "qwen3-asr-0.6b":
            guard #available(macOS 15, *) else { throw HarnessError.unsupportedModel(id) }
            return Qwen3AudioAdapter()
        case "cohere-transcribe-q8":
            return CohereTranscribeAdapter()
        default:
            throw HarnessError.unsupportedModel(id)
        }
    }

    private func loadCases(from url: URL) throws -> [ReplayCase] {
        let contents = try String(contentsOf: url, encoding: .utf8)
        let decoder = JSONDecoder()
        return try contents.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return try decoder.decode(ReplayCase.self, from: Data(trimmed.utf8))
        }
    }

    private func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private func normalizedCharacters(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    private func editDistance<T: Equatable>(reference: [T], hypothesis: [T]) -> Int {
        var previous = Array(0...hypothesis.count)
        for (referenceIndex, referenceValue) in reference.enumerated() {
            var current = [referenceIndex + 1] + Array(repeating: 0, count: hypothesis.count)
            for (hypothesisIndex, hypothesisValue) in hypothesis.enumerated() {
                current[hypothesisIndex + 1] = min(
                    current[hypothesisIndex] + 1,
                    previous[hypothesisIndex + 1] + 1,
                    previous[hypothesisIndex] + (referenceValue == hypothesisValue ? 0 : 1)
                )
            }
            previous = current
        }
        return previous[hypothesis.count]
    }

    private func validTimingSequence(
        _ timings: [TranscriptTokenTiming],
        audioSeconds: TimeInterval
    ) -> Bool {
        guard !timings.isEmpty else { return false }
        var previousStart = -Double.infinity
        var previousEnd = -Double.infinity
        for timing in timings {
            guard timing.startTime.isFinite,
                  timing.endTime.isFinite,
                  timing.startTime >= 0,
                  timing.endTime >= timing.startTime,
                  timing.startTime >= previousStart,
                  timing.endTime >= previousEnd,
                  timing.endTime <= audioSeconds + TranscriberAudioSupport.timingBoundaryToleranceSeconds
            else { return false }
            previousStart = timing.startTime
            previousEnd = timing.endTime
        }
        return true
    }

    private func durationBucket(_ seconds: Double) -> String {
        switch seconds {
        case ..<1: return "under_1s"
        case ..<3: return "1_3s"
        case ..<10: return "3_10s"
        case ..<30: return "10_30s"
        default: return "30s_plus"
        }
    }

    private func report(_ measurements: [Measurement]) -> String {
        let grouped = Dictionary(grouping: measurements) {
            MeasurementGroup(modelID: $0.modelID, durationBucket: $0.durationBucket)
        }
        let groupRows = grouped.keys.sorted {
            ($0.modelID, $0.durationBucket) < ($1.modelID, $1.durationBucket)
        }.map { key in
            let values = grouped[key] ?? []
            let sortedLatencies = values.map(\.processingMilliseconds).sorted()
            func percentile(_ fraction: Double) -> Int {
                let index = min(
                    sortedLatencies.count - 1,
                    Int((Double(sortedLatencies.count - 1) * fraction).rounded())
                )
                return sortedLatencies[index]
            }
            let macroWER = values.map(\.wer).reduce(0, +) / Double(values.count)
            let macroCER = values.map(\.cer).reduce(0, +) / Double(values.count)
            let corpusWER = Double(values.map(\.wordEditCount).reduce(0, +))
                / Double(values.map(\.referenceWordCount).reduce(0, +))
            let corpusCER = Double(values.map(\.characterEditCount).reduce(0, +))
                / Double(values.map(\.referenceCharacterCount).reduce(0, +))
            return "GROUP model=\(key.modelID) bucket=\(key.durationBucket) cases=\(values.count) corpusWER=\(String(format: "%.3f", corpusWER)) corpusCER=\(String(format: "%.3f", corpusCER)) macroWER=\(String(format: "%.3f", macroWER)) macroCER=\(String(format: "%.3f", macroCER)) p50=\(percentile(0.5))ms p95=\(percentile(0.95))ms"
        }.joined(separator: "\n")
        let rows = measurements.map {
            "\($0.id) model=\($0.modelID) bucket=\($0.durationBucket) WER=\(String(format: "%.3f", $0.wer)) CER=\(String(format: "%.3f", $0.cer)) RTF=\(String(format: "%.3f", $0.realTimeFactor)) timingValid=\($0.timingValid) timingAligned=\($0.timingAligned)"
        }.joined(separator: "\n")
        return "ASR acoustic replay cases=\(measurements.count)\n\(groupRows)\n\(rows)"
    }
}

private extension Duration {
    var secondsValue: Double {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

private extension AcousticReplayHarnessTests {
    struct ReplayCase: Decodable {
        let id: String
        let audioPath: String
        let expectedText: String
        let modelId: String?
        let language: String?
        let maximumWER: Double
        let maximumCER: Double
        let maximumRTF: Double
        let requireValidTimings: Bool
        let requireAlignedTimings: Bool
    }

    struct Measurement {
        let id: String
        let modelID: String
        let durationBucket: String
        let referenceWordCount: Int
        let wordEditCount: Int
        let referenceCharacterCount: Int
        let characterEditCount: Int
        let wer: Double
        let cer: Double
        let processingMilliseconds: Int
        let realTimeFactor: Double
        let timingValid: Bool
        let timingAligned: Bool
    }

    struct MeasurementGroup: Hashable {
        let modelID: String
        let durationBucket: String
    }

    enum HarnessError: LocalizedError {
        case unsupportedModel(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedModel(let id): "Unsupported acoustic replay model: \(id)"
            }
        }
    }
}
