import FluidAudio
import Foundation
import os

/// Streaming speaker diarizer for meeting transcription.
///
/// Uses FluidAudio's SortformerDiarizer (NVIDIA Sortformer, ~11% DER) in streaming mode.
/// Audio is fed continuously via `feedAudio()`, and speaker queries are made against
/// the accumulated timeline when ASR produces an utterance.
///
/// Used for imported audio and Room Mode mixed-microphone recordings. Online
/// calls can continue using channel-based attribution.
/// 4 fixed speaker slots (Sortformer limitation).
final class MeetingSpeakerDiarizer: @unchecked Sendable {

    static let enrolledLocalSpeakerName = "You"

    private static let sampleRate: Double = 16_000
    private static let slowProcessThresholdMs = 250.0
    private static let diagnosticsIntervalSamples = Int(sampleRate * 60 * 5)
    private static let repeatedIssueLogInterval = 10

    private var diarizer: SortformerDiarizer?
    private var processedSampleCount = 0
    private var nextDiagnosticsSampleCount = diagnosticsIntervalSamples
    private var processErrorCount = 0
    private var slowProcessCount = 0
    private let log = Logger.resonant("MeetingSpeakerDiarizer")

    static func isDownloaded(config: SortformerConfig = .default) -> Bool {
        guard let bundle = ModelNames.Sortformer.bundle(for: config) else { return false }
        let modelURL = modelsDirectory()
            .appendingPathComponent(Repo.sortformer.folderName, isDirectory: true)
            .appendingPathComponent(bundle, isDirectory: true)
        let coreMLDataURL = modelURL.appendingPathComponent("coremldata.bin")

        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: modelURL.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && fileIsNonEmpty(coreMLDataURL)
    }

    static func downloadModels(progressHandler: DownloadUtils.ProgressHandler? = nil) async throws {
        let config = SortformerConfig.default
        guard let bundle = ModelNames.Sortformer.bundle(for: config) else {
            throw MeetingSpeakerDiarizerError.modelNotDownloaded
        }
        try await DownloadUtils.downloadRepo(
            .sortformer,
            to: modelsDirectory(),
            variant: bundle,
            progressHandler: progressHandler
        )
        guard isDownloaded(config: config) else {
            throw TranscriberError.downloadFailed("Room speaker model files are incomplete.")
        }
    }

    static func downloadModels(onProgress: (@Sendable (Double) -> Void)? = nil) async throws {
        try await downloadModels(progressHandler: { progress in
            onProgress?(progress.fractionCompleted)
        })
    }

    static func unavailableWarningMessage() -> String {
        if isDownloaded() {
            return "Speaker separation is unavailable because the speaker model could not load."
        }
        return "Speaker separation requires a speaker model download. Open Settings > Meetings to download it."
    }

    /// Download models and initialize the streaming diarization pipeline.
    func prepare(allowDownload: Bool = true) async throws {
        log.info("Loading Sortformer diarization models...")
        let config = SortformerConfig.default
        guard allowDownload || Self.isDownloaded(config: config) else {
            throw MeetingSpeakerDiarizerError.modelNotDownloaded
        }
        let models = try await SortformerModels.loadFromHuggingFace(
            config: config,
            cacheDirectory: Self.modelsDirectory()
        )
        let d = SortformerDiarizer(config: config)
        d.initialize(models: models)
        diarizer = d
        log.info("Sortformer diarization ready")
    }

    /// Feed audio samples to build the diarization timeline.
    /// Call this continuously with system audio chunks as they arrive.
    ///
    /// - Parameter samples: 16kHz mono Float32 audio samples.
    func feedAudio(_ samples: [Float]) {
        guard let diarizer else { return }
        diarizer.addAudio(samples)

        let startedAt = DispatchTime.now().uptimeNanoseconds
        do {
            try diarizer.process()
        } catch {
            processErrorCount += 1
            if Self.shouldLogRepeatedIssue(count: processErrorCount) {
                log.error(
                    "Sortformer diarization process failed count=\(self.processErrorCount, privacy: .public): \(error.localizedDescription)"
                )
            }
        }

        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
        if elapsedMs > Self.slowProcessThresholdMs {
            slowProcessCount += 1
            if Self.shouldLogRepeatedIssue(count: slowProcessCount) {
                log.warning(
                    "Sortformer diarization process slow elapsed_ms=\(elapsedMs, privacy: .public) threshold_ms=\(Self.slowProcessThresholdMs, privacy: .public) count=\(self.slowProcessCount, privacy: .public) samples=\(samples.count, privacy: .public)"
                )
            }
        }

        processedSampleCount += samples.count
        logTimelineDiagnosticsIfNeeded(for: diarizer)
    }

    /// Prime Sortformer with the user's local Voice ID sample so that Room Mode
    /// can emit `.you` instead of a generic speaker slot for matching speech.
    @discardableResult
    func enrollLocalUserVoice(samples: [Float]) throws -> Bool {
        guard let diarizer else { return false }
        let speaker = try diarizer.enrollSpeaker(
            withAudio: samples,
            sourceSampleRate: MeetingVoiceProfileStore.targetSampleRate,
            named: Self.enrolledLocalSpeakerName,
            overwritingAssignedSpeakerName: true
        )
        if let speaker {
            log.info("Enrolled local Voice ID into diarizer slot=\(speaker.index, privacy: .public)")
            return true
        }
        log.warning("Local Voice ID enrollment did not produce a speaker slot")
        return false
    }

    /// Query the timeline to find the dominant speaker in a time range.
    ///
    /// - Parameters:
    ///   - from: Start time in seconds from session start.
    ///   - to: End time in seconds from session start.
    /// - Returns: A speaker index (0-3), or nil if no speaker found.
    func dominantSpeaker(from startTime: Float, to endTime: Float) -> Int? {
        guard let diarizer else { return nil }
        let timeline = diarizer.timeline

        var bestSpeaker: Int?
        var bestDuration: Float = 0

        for (speakerIndex, speaker) in timeline.speakers {
            var overlap: Float = 0
            for seg in speaker.finalizedSegments + speaker.tentativeSegments {
                let overlapStart = max(seg.startTime, startTime)
                let overlapEnd = min(seg.endTime, endTime)
                if overlapEnd > overlapStart {
                    overlap += overlapEnd - overlapStart
                }
            }
            if overlap > bestDuration {
                bestDuration = overlap
                bestSpeaker = speakerIndex
            }
        }

        return bestSpeaker
    }

    func dominantMeetingSpeaker(
        from startTime: Float,
        to endTime: Float,
        fallback: MeetingSpeaker
    ) -> MeetingSpeaker {
        guard let speakerIndex = dominantSpeaker(from: startTime, to: endTime) else {
            return fallback
        }
        return meetingSpeaker(for: speakerIndex)
    }

    func meetingSpeaker(for speakerIndex: Int) -> MeetingSpeaker {
        guard let diarizer,
              diarizer.timeline.speakers[speakerIndex]?.name == Self.enrolledLocalSpeakerName else {
            return .participant(id: "SPEAKER_\(speakerIndex)")
        }
        return .you
    }

    func cleanup() {
        diarizer?.cleanup()
        diarizer = nil
    }

    private static func modelsDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models", isDirectory: true)
    }

    private static func fileIsNonEmpty(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber else {
            return false
        }
        return size.int64Value > 0
    }

    private static func shouldLogRepeatedIssue(count: Int) -> Bool {
        count == 1 || count.isMultiple(of: repeatedIssueLogInterval)
    }

    private func logTimelineDiagnosticsIfNeeded(for diarizer: SortformerDiarizer) {
        guard processedSampleCount >= nextDiagnosticsSampleCount else { return }

        let timeline = diarizer.timeline
        let finalizedSegments = timeline.speakers.values.reduce(0) { count, speaker in
            count + speaker.finalizedSegments.count
        }
        let tentativeSegments = timeline.speakers.values.reduce(0) { count, speaker in
            count + speaker.tentativeSegments.count
        }

        log.info(
            "Sortformer diarization timeline audio_s=\(Double(self.processedSampleCount) / Self.sampleRate, privacy: .public) speakers=\(timeline.speakers.count, privacy: .public) finalized_segments=\(finalizedSegments, privacy: .public) tentative_segments=\(tentativeSegments, privacy: .public) process_errors=\(self.processErrorCount, privacy: .public) slow_processes=\(self.slowProcessCount, privacy: .public)"
        )

        while nextDiagnosticsSampleCount <= processedSampleCount {
            nextDiagnosticsSampleCount += Self.diagnosticsIntervalSamples
        }
    }
}

private enum MeetingSpeakerDiarizerError: LocalizedError {
    case modelNotDownloaded

    var errorDescription: String? {
        switch self {
        case .modelNotDownloaded:
            return "Room speaker model is not downloaded."
        }
    }
}
