@preconcurrency import AVFoundation
import FluidAudio
import os

/// Consumes an audio buffer stream, detects speech via Silero VAD,
/// and transcribes completed speech segments via the MeetingTranscriptionBackend protocol.
/// Ported from OpenOats StreamingTranscriber — adapted for Resonant.
final class MeetingStreamingTranscriber: @unchecked Sendable {

    private let backend: any MeetingTranscriptionBackend
    private let locale: Locale
    private let vadManager: VadManager
    private let speaker: MeetingSpeaker
    private let channelLabel: String
    private let diarizer: MeetingSpeakerDiarizer?
    private let onAudioSamples: (@Sendable ([Float], TimeInterval) -> Void)?
    private let onFinal: @Sendable (String, MeetingSpeaker, TimeInterval) -> Void
    private let log = Logger.resonant("MeetingStreamingTranscriber")

    /// Resampler from source format to 16kHz mono Float32.
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    init(
        backend: any MeetingTranscriptionBackend,
        locale: Locale,
        vadManager: VadManager,
        speaker: MeetingSpeaker,
        channelLabel: String? = nil,
        diarizer: MeetingSpeakerDiarizer? = nil,
        onAudioSamples: (@Sendable ([Float], TimeInterval) -> Void)? = nil,
        onFinal: @escaping @Sendable (String, MeetingSpeaker, TimeInterval) -> Void
    ) {
        self.backend = backend
        self.locale = locale
        self.vadManager = vadManager
        self.speaker = speaker
        self.channelLabel = channelLabel ?? speaker.storageKey
        self.diarizer = diarizer
        self.onAudioSamples = onAudioSamples
        self.onFinal = onFinal
    }

    /// Silero VAD expects chunks of 4096 samples (256ms at 16kHz).
    private static let vadChunkSize = 4096
    private static let minimumSpeechSamples = 8000
    private static let prerollChunkCount = 2
    /// Flush speech for transcription every ~5 seconds (80,000 samples at 16kHz).
    private static let flushInterval = 80_000

    nonisolated static func normalizeTranscribedText(_ text: String) -> String {
        FragmentedWordRepair.repair(
            CollapsedRunRepair.repair(text)
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func resolvedSpeaker(
        configuredSpeaker: MeetingSpeaker,
        segmentSpeaker: MeetingSpeaker?
    ) -> MeetingSpeaker? {
        if configuredSpeaker.isFixedChannelSpeaker {
            return configuredSpeaker
        }
        return segmentSpeaker
    }

    /// Main loop: reads audio buffers, runs VAD, transcribes speech segments.
    func run(stream: AsyncStream<AVAudioPCMBuffer>) async {
        log.notice("Transcriber started channel=\(self.channelLabel, privacy: .public) backend=\(self.backend.displayName, privacy: .public) speaker=\(self.speaker.storageKey, privacy: .public)")
        var vadState = await vadManager.makeStreamState()
        var speechSamples: [Float] = []
        var vadBuffer: [Float] = []
        var recentChunks: [[Float]] = []
        var isSpeaking = false
        var totalObservedSamples = 0
        var currentSpeechStartSample: Int?
        var didLogFirstBuffer = false
        var nextProgressLogSample = 16000 * 30

        for await buffer in stream {
            guard let samples = extractSamples(buffer) else { continue }
            if !didLogFirstBuffer {
                didLogFirstBuffer = true
                let format = buffer.format
                log.notice("First audio buffer channel=\(self.channelLabel, privacy: .public) frames=\(Int(buffer.frameLength), privacy: .public) sample_rate=\(format.sampleRate, privacy: .public) channels=\(format.channelCount, privacy: .public)")
            }
            let chunkUptime = ProcessInfo.processInfo.systemUptime
            onAudioSamples?(samples, chunkUptime)

            // Feed all audio to diarizer continuously to build speaker timeline
            diarizer?.feedAudio(samples)

            vadBuffer.append(contentsOf: samples)

            while vadBuffer.count >= Self.vadChunkSize {
                let chunk = Array(vadBuffer.prefix(Self.vadChunkSize))
                vadBuffer.removeFirst(Self.vadChunkSize)
                let chunkStartSample = totalObservedSamples
                totalObservedSamples += chunk.count
                let chunkEndSample = totalObservedSamples
                let wasSpeaking = isSpeaking

                var startedSpeech = false
                var endedSpeech = false
                do {
                    let result = try await vadManager.processStreamingChunk(
                        chunk,
                        state: vadState,
                        config: .default,
                        returnSeconds: true,
                        timeResolution: 2
                    )
                    vadState = result.state

                    if let event = result.event {
                        switch event.kind {
                        case .speechStart:
                            if !wasSpeaking {
                                isSpeaking = true
                                startedSpeech = true
                                let prerollChunks = Array(recentChunks.suffix(Self.prerollChunkCount))
                                speechSamples = prerollChunks.flatMap { $0 }
                                let prerollSamples = prerollChunks.reduce(0) { $0 + $1.count }
                                currentSpeechStartSample = max(0, chunkStartSample - prerollSamples)
                                log.info("VAD speech start channel=\(self.channelLabel, privacy: .public) offset_s=\(Double(currentSpeechStartSample ?? chunkStartSample) / 16000.0, privacy: .public)")
                            }

                        case .speechEnd:
                            endedSpeech = wasSpeaking || isSpeaking
                            if endedSpeech, let segmentStartSample = currentSpeechStartSample {
                                log.info("VAD speech end channel=\(self.channelLabel, privacy: .public) offset_s=\(Double(chunkEndSample) / 16000.0, privacy: .public) duration_s=\(Double(chunkEndSample - segmentStartSample) / 16000.0, privacy: .public)")
                            }
                        }
                    }

                    if wasSpeaking || startedSpeech || endedSpeech {
                        speechSamples.append(contentsOf: chunk)
                        recentChunks.removeAll(keepingCapacity: true)
                    } else {
                        recentChunks.append(chunk)
                        if recentChunks.count > Self.prerollChunkCount {
                            recentChunks.removeFirst(recentChunks.count - Self.prerollChunkCount)
                        }
                    }

                    if endedSpeech {
                        isSpeaking = false
                        if speechSamples.count > Self.minimumSpeechSamples,
                           let segmentStartSample = currentSpeechStartSample {
                            let segment = speechSamples
                            speechSamples.removeAll(keepingCapacity: true)
                            await transcribeSegment(
                                segment,
                                startSample: segmentStartSample,
                                endSample: segmentStartSample + segment.count
                            )
                        } else {
                            speechSamples.removeAll(keepingCapacity: true)
                        }
                        currentSpeechStartSample = nil
                    } else if isSpeaking {
                        // Flush every ~5s for near-real-time output during continuous speech
                        if speechSamples.count >= Self.flushInterval,
                           let segmentStartSample = currentSpeechStartSample {
                            let segment = speechSamples
                            speechSamples.removeAll(keepingCapacity: true)
                            await transcribeSegment(
                                segment,
                                startSample: segmentStartSample,
                                endSample: segmentStartSample + segment.count
                            )
                            currentSpeechStartSample = chunkEndSample
                        }
                    }
                } catch {
                    log.error("VAD error channel=\(self.channelLabel, privacy: .public): \(error.localizedDescription)")
                }

                if totalObservedSamples >= nextProgressLogSample {
                    log.info("Audio observed channel=\(self.channelLabel, privacy: .public) seconds=\(Double(totalObservedSamples) / 16000.0, privacy: .public) speaking=\(isSpeaking, privacy: .public) pending_speech_s=\(Double(speechSamples.count) / 16000.0, privacy: .public)")
                    nextProgressLogSample += 16000 * 30
                }
            }
        }

        // Flush remaining speech at end of stream
        if speechSamples.count > Self.minimumSpeechSamples,
           let segmentStartSample = currentSpeechStartSample {
            await transcribeSegment(
                speechSamples,
                startSample: segmentStartSample,
                endSample: segmentStartSample + speechSamples.count
            )
        }
        log.info("Transcriber finished channel=\(self.channelLabel, privacy: .public) observed_s=\(Double(totalObservedSamples) / 16000.0, privacy: .public)")
    }

    // MARK: - Transcription

    private func transcribeSegment(_ samples: [Float], startSample: Int, endSample: Int) async {
        let duration = Double(endSample - startSample) / 16000.0
        log.info("ASR segment start channel=\(self.channelLabel, privacy: .public) duration_s=\(duration, privacy: .public) start_s=\(Double(startSample) / 16000.0, privacy: .public) samples=\(samples.count, privacy: .public)")
        do {
            let segments = try await backend.transcribeSegments(samples, locale: locale)
            var emittedAnySegment = false
            for segment in segments {
                let text = Self.normalizeTranscribedText(segment.text)
                guard !text.isEmpty else { continue }

                let relativeStart = boundedOffset(segment.startOffset, duration: duration, fallback: 0)
                let relativeEnd = boundedOffset(segment.endOffset, duration: duration, fallback: duration)
                let absoluteStart = TimeInterval(startSample) / 16000.0 + relativeStart
                let absoluteEnd = max(absoluteStart, TimeInterval(startSample) / 16000.0 + relativeEnd)
                let resolvedSpeaker = resolvedSpeaker(
                    for: segment,
                    absoluteStart: absoluteStart,
                    absoluteEnd: absoluteEnd
                )
                let words = text.split(separator: " ")

                log.info("ASR segment final channel=\(self.channelLabel, privacy: .public) words=\(words.count, privacy: .public) speaker=\(resolvedSpeaker.storageKey, privacy: .public)")
                onFinal(text, resolvedSpeaker, absoluteStart)
                emittedAnySegment = true
            }

            if !emittedAnySegment {
                log.warning("ASR returned empty channel=\(self.channelLabel, privacy: .public) duration_s=\(duration, privacy: .public)")
            }
        } catch {
            log.error("ASR error channel=\(self.channelLabel, privacy: .public) speaker=\(self.speaker.storageKey, privacy: .public): \(error.localizedDescription)")
        }
    }

    private func resolvedSpeaker(
        for segment: MeetingTranscriptionSegment,
        absoluteStart: TimeInterval,
        absoluteEnd: TimeInterval
    ) -> MeetingSpeaker {
        if let segmentSpeaker = Self.resolvedSpeaker(
            configuredSpeaker: speaker,
            segmentSpeaker: segment.speaker
        ) {
            return segmentSpeaker
        }

        guard let diarizer else {
            return speaker
        }

        let startTime = Float(absoluteStart)
        let endTime = Float(max(absoluteStart, absoluteEnd))
        return diarizer.dominantMeetingSpeaker(
            from: startTime,
            to: endTime,
            fallback: speaker
        )
    }

    private func boundedOffset(
        _ value: TimeInterval?,
        duration: TimeInterval,
        fallback: TimeInterval
    ) -> TimeInterval {
        let raw = value ?? fallback
        guard raw.isFinite else { return fallback }
        return min(max(0, raw), duration)
    }

    // MARK: - Audio Format Conversion

    /// Extract [Float] samples from an AVAudioPCMBuffer, resampling if needed.
    private func extractSamples(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        let sourceFormat = buffer.format
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else {
            logExtractionFailure("empty input buffer", format: sourceFormat)
            return nil
        }

        // Fast path: already Float32 at 16kHz
        if sourceFormat.commonFormat == .pcmFormatFloat32,
           sourceFormat.sampleRate == 16000,
           sourceFormat.channelCount == 1 {
            guard let channelData = buffer.floatChannelData else {
                logExtractionFailure("missing float channel data for 16kHz mono buffer", format: sourceFormat)
                return nil
            }
            return Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
        }

        // Downmix multi-channel to mono before resampling
        var inputBuffer = buffer
        if sourceFormat.channelCount > 1, let src = buffer.floatChannelData {
            let monoFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sourceFormat.sampleRate,
                channels: 1,
                interleaved: false
            )!
            if let monoBuf = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameCapacity),
               let dst = monoBuf.floatChannelData?[0] {
                monoBuf.frameLength = buffer.frameLength
                let channels = Int(sourceFormat.channelCount)
                let scale = 1.0 / Float(channels)
                for i in 0..<frameLength {
                    var sum: Float = 0
                    for ch in 0..<channels { sum += src[ch][i] }
                    dst[i] = sum * scale
                }
                inputBuffer = monoBuf
            }
        }

        // Slow path: resample via AVAudioConverter
        let inputFormat = inputBuffer.format
        if converter == nil || converter?.inputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        }
        guard let converter else {
            logExtractionFailure("failed to create AVAudioConverter", format: inputFormat)
            return nil
        }

        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let outputFrames = AVAudioFrameCount(ceil(Double(inputBuffer.frameLength) * ratio))
        guard outputFrames > 0 else {
            logExtractionFailure("invalid output frame estimate", format: inputFormat)
            return nil
        }

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputFrames
        ) else {
            logExtractionFailure("failed to allocate output buffer", format: targetFormat)
            return nil
        }

        var error: NSError?
        let feedState = ConversionFeedState()
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if feedState.consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            feedState.consumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        if let error {
            log.error("Resample error: \(error.localizedDescription)")
            return nil
        }

        guard outputBuffer.frameLength > 0 else {
            logExtractionFailure("converter produced empty output", format: inputFormat)
            return nil
        }

        guard let channelData = outputBuffer.floatChannelData else {
            logExtractionFailure("missing float channel data after conversion", format: targetFormat)
            return nil
        }
        return Array(UnsafeBufferPointer(
            start: channelData[0],
            count: Int(outputBuffer.frameLength)
        ))
    }

    private func logExtractionFailure(_ reason: String, format: AVAudioFormat) {
        log.error(
            "Dropping audio chunk: \(reason, privacy: .public) [format=\(self.formatDescription(format), privacy: .public)]"
        )
    }

    private func formatDescription(_ format: AVAudioFormat) -> String {
        "\(Int(format.sampleRate))Hz/\(format.channelCount)ch/\(format.commonFormat.rawValue)"
    }
}

private final class ConversionFeedState {
    var consumed = false
}
