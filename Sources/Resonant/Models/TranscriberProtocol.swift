import AVFoundation
import Foundation

// MARK: - Download progress

/// A backend-agnostic model-download progress update.
///
/// Carries the current `phase` in addition to a fraction so the UI can show
/// meaningful status during the long, byte-progress-free *preparing* window
/// (contacting the host and listing files) instead of a frozen "0%", and so
/// the download stall watchdog can apply a phase-appropriate timeout budget.
struct ModelDownloadProgress: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
        /// Contacting the host and listing the files to fetch. No byte-level
        /// progress is available yet, so `fraction` stays at 0 throughout.
        case preparing
        /// Transferring model files. `fraction` is byte-weighted.
        case downloading
        /// Compiling / preparing the downloaded model on-device.
        case finalizing

        /// Short, user-facing status line for this phase.
        var statusText: String {
            switch self {
            case .preparing: return "Connecting…"
            case .downloading: return "Downloading local model…"
            case .finalizing: return "Preparing local model…"
            }
        }
    }

    let fraction: Double
    let phase: Phase

    init(fraction: Double, phase: Phase) {
        self.fraction = fraction
        self.phase = phase
    }
}

// MARK: - Protocol

/// Uniform interface for all STT backends.
/// DictationManager only knows about this — never about FluidAudio or sherpa-onnx directly.
protocol Transcriber: AnyObject, Sendable {
    var id: String { get }
    var displayName: String { get }
    var description: String { get }
    var isLoaded: Bool { get }
    var isDownloaded: Bool { get }
    var requiresDownload: Bool { get }
    var downloadSizeBytes: Int64 { get }
    /// URL to the model's page (e.g. HuggingFace) for user transparency.
    var modelURL: URL? { get }
    /// ISO 639-1 codes the model supports natively. Empty means unrestricted.
    var supportedLanguageCodes: Set<String> { get }
    /// Whether the model handles "auto" (no explicit language) usefully.
    var supportsAutoLanguageDetection: Bool { get }
    /// Whether URL transcription remains bounded-memory for long recordings.
    /// Backends that decode the whole file before inference must keep this false.
    var supportsDiskBackedURLTranscription: Bool { get }

    func download(onProgress: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws
    func load() async throws
    /// Transcribe audio from a file URL.
    /// - Parameters:
    ///   - audioURL: Path to the audio file.
    ///   - language: ISO 639-1 code (e.g. "sv", "it") or "auto" / nil for automatic.
    func transcribe(audioURL: URL, language: String?) async throws -> String
    /// Transcribe audio from 16kHz mono Float32 samples.
    func transcribe(audioSamples: [Float], language: String?) async throws -> String
    /// Transcribe a file while preserving decoder token timings when the backend
    /// exposes them. Backends without timings inherit the plain-text wrapper.
    func transcribeDetailed(audioURL: URL, language: String?) async throws -> DetailedTranscription
    /// Transcribe canonical 16kHz mono samples while preserving decoder token
    /// timings when the backend exposes them.
    func transcribeDetailed(audioSamples: [Float], language: String?) async throws -> DetailedTranscription
    func unload()
    func purgeDownloadedModel()
}

// MARK: - Detailed transcription (token timings)

/// One decoded token with its audio-frame timing. Drives pause-based
/// sentence/paragraph segmentation in post-processing.
struct TranscriptTokenTiming: Sendable, Equatable {
    let token: String
    let startTime: Double
    let endTime: Double
}

struct DetailedTranscription: Sendable {
    let text: String
    let tokenTimings: [TranscriptTokenTiming]
    /// Decode-time vocabulary-boost outcome, when the backend ran the CTC
    /// rescoring pass. Defaults to nil so timing-only backends and the
    /// plain-text compatibility wrappers stay untouched.
    var boostAudit: VocabularyBoostAudit? = nil
}

extension Transcriber {
    var supportsDiskBackedURLTranscription: Bool { false }

    /// Backends that do not expose token timings get a lossless plain-text
    /// compatibility wrapper. These are protocol requirements (not extension-only
    /// methods) so calls through `any Transcriber` dynamically dispatch to timing-
    /// aware implementations.
    func transcribeDetailed(audioURL: URL, language: String?) async throws -> DetailedTranscription {
        DetailedTranscription(
            text: try await transcribe(audioURL: audioURL, language: language),
            tokenTimings: []
        )
    }

    func transcribeDetailed(audioSamples: [Float], language: String?) async throws -> DetailedTranscription {
        DetailedTranscription(
            text: try await transcribe(audioSamples: audioSamples, language: language),
            tokenTimings: []
        )
    }

    func purgeDownloadedModel() {}

    /// Bytes of this model already present in the on-disk cache. Lets the
    /// disk-space precheck demand only the *remaining* download, so a retry
    /// after a partial fetch isn't refused for space the files already occupy.
    var onDiskCacheBytes: Int64 { 0 }
}

// MARK: - Errors

enum TranscriberError: LocalizedError {
    case notLoaded
    case notDownloaded
    case transcriptionFailed(String)
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .notLoaded: "Model is not loaded."
        case .notDownloaded: "Model has not been downloaded."
        case .transcriptionFailed(let msg): "Transcription failed: \(msg)"
        case .downloadFailed(let msg): "Download failed: \(msg)"
        }
    }
}

enum TranscriberAudioSupport {
    static let minimumSampleCount = 16_000
    /// Matches FluidAudio's default disk-backed URL threshold. Above this,
    /// retry and empty-result handling must stay on the URL path as well.
    static let maximumInMemorySampleCount = 480_000
    static let preferredLeadingPaddingSampleCount = 1_920
    /// Parakeet emits timings on an 80 ms encoder-frame grid. Values no farther
    /// than one frame beyond the raw clip are clamped; anything farther outside
    /// the raw coordinate space invalidates the entire timing sequence.
    static let timingBoundaryToleranceSeconds: TimeInterval = 0.08
    private static let minimumUsableAmplitude: Float = 1e-7
    /// Above this peak the capture is over-driven; attenuate before ASR. FluidAudio
    /// feeds raw samples straight into the CoreML mel front-end with no normalization,
    /// so a hot waveform reaches the acoustic model distorted.
    static let normalizationPeakCeiling: Float = 0.95
    /// Target peak when attenuating a hot capture — leaves the front-end headroom.
    static let normalizationTargetPeak: Float = 0.9

    static func estimatedSampleCount(from audioURL: URL) throws -> Int {
        let file = try AVAudioFile(forReading: audioURL)
        let sourceSampleRate = max(file.processingFormat.sampleRate, 1)
        let resampleRatio = Double(DictationAudioAnalyzer.sampleRate) / sourceSampleRate
        return max(0, Int((Double(file.length) * resampleRatio).rounded(.up)))
    }

    static func captureDiagnostics(from audioURL: URL) throws -> DictationCaptureDiagnostics {
        DictationCaptureDiagnostics(
            sampleCount: try estimatedSampleCount(from: audioURL),
            sampleRate: DictationAudioAnalyzer.sampleRate
        )
    }

    static func preparedSamples(_ audioSamples: [Float]) throws -> [Float] {
        try preparedInput(audioSamples).preparedSamples
    }

    static func preparedInput(_ audioSamples: [Float]) throws -> PreparedInput {
        guard !audioSamples.isEmpty else {
            throw TranscriberError.transcriptionFailed("Audio too short")
        }

        var sanitized: [Float] = []
        sanitized.reserveCapacity(audioSamples.count)
        var hasUsableSignal = false
        var peak: Float = 0

        for sample in audioSamples {
            let sanitizedSample = sample.isFinite ? sample : 0
            sanitized.append(sanitizedSample)
            let magnitude = abs(sanitizedSample)
            if magnitude > minimumUsableAmplitude {
                hasUsableSignal = true
            }
            if magnitude > peak {
                peak = magnitude
            }
        }

        guard hasUsableSignal else {
            throw TranscriberError.transcriptionFailed("Audio contained no usable samples")
        }

        // Attenuate — never amplify — an over-driven capture so the ASR mel front-end
        // sees a consistent, in-distribution peak. This cannot recover information lost
        // to hard clipping at capture, but prevents front-end overflow and helps the
        // moderate over-drive case.
        if peak > normalizationPeakCeiling {
            let scale = normalizationTargetPeak / peak
            for index in sanitized.indices {
                sanitized[index] *= scale
            }
        }

        guard sanitized.count < minimumSampleCount else {
            return PreparedInput(
                originalSampleCount: sanitized.count,
                leadingPaddingSampleCount: 0,
                trailingPaddingSampleCount: 0,
                preparedSamples: sanitized
            )
        }

        let totalPadding = minimumSampleCount - sanitized.count
        let leadingPadding = min(preferredLeadingPaddingSampleCount, totalPadding / 2)
        let trailingPadding = totalPadding - leadingPadding

        return PreparedInput(
            originalSampleCount: sanitized.count,
            leadingPaddingSampleCount: leadingPadding,
            trailingPaddingSampleCount: trailingPadding,
            preparedSamples: Array(repeating: 0, count: leadingPadding)
                + sanitized
                + Array(repeating: 0, count: trailingPadding)
        )
    }

    static func preparedInput(from audioURL: URL) throws -> PreparedInput {
        let audioSamples = try DictationAudioAnalyzer.loadMono16kSamples(from: audioURL)
        return try preparedInput(audioSamples)
    }

    /// Translates timings produced against a padded ASR buffer back to the raw
    /// capture's coordinate space. Validation is deliberately all-or-nothing:
    /// pause formatting safely degrades to no timings instead of acting on a
    /// partially repaired or non-monotonic sequence.
    static func normalizedTokenTimings(
        _ tokenTimings: [TranscriptTokenTiming],
        for preparedInput: PreparedInput
    ) -> [TranscriptTokenTiming] {
        normalizedTokenTimings(
            tokenTimings,
            originalSampleCount: preparedInput.originalSampleCount,
            leadingPaddingSampleCount: preparedInput.leadingPaddingSampleCount,
            trailingPaddingSampleCount: preparedInput.trailingPaddingSampleCount,
            preparedSampleCount: preparedInput.preparedSamples.count
        )
    }

    static func normalizedTokenTimings(
        _ tokenTimings: [TranscriptTokenTiming],
        originalSampleCount: Int,
        leadingPaddingSampleCount: Int = 0,
        trailingPaddingSampleCount: Int = 0,
        preparedSampleCount: Int? = nil
    ) -> [TranscriptTokenTiming] {
        guard !tokenTimings.isEmpty,
              originalSampleCount > 0,
              leadingPaddingSampleCount >= 0,
              trailingPaddingSampleCount >= 0
        else {
            return []
        }

        let expectedPreparedSampleCount = originalSampleCount
            + leadingPaddingSampleCount
            + trailingPaddingSampleCount
        if let preparedSampleCount, preparedSampleCount != expectedPreparedSampleCount {
            return []
        }

        let sampleRate = Double(DictationAudioAnalyzer.sampleRate)
        let leadingOffset = Double(leadingPaddingSampleCount) / sampleRate
        let rawDuration = Double(originalSampleCount) / sampleRate
        let preparedDuration = Double(expectedPreparedSampleCount) / sampleRate
        let tolerance = timingBoundaryToleranceSeconds

        var normalized: [TranscriptTokenTiming] = []
        normalized.reserveCapacity(tokenTimings.count)
        var previousStart = -Double.infinity
        var previousEnd = -Double.infinity

        for timing in tokenTimings {
            guard timing.startTime.isFinite,
                  timing.endTime.isFinite,
                  timing.startTime >= 0,
                  timing.endTime >= timing.startTime,
                  timing.startTime <= preparedDuration + tolerance,
                  timing.endTime <= preparedDuration + tolerance
            else {
                return []
            }

            let rawStart = timing.startTime - leadingOffset
            let rawEnd = timing.endTime - leadingOffset

            // Reject tokens wholly inside synthetic padding, while allowing a
            // one-frame encoder quantization error at either real-audio edge.
            guard rawEnd > 0,
                  rawStart < rawDuration,
                  rawEnd <= rawDuration + tolerance
            else {
                return []
            }

            let clampedStart = min(rawDuration, max(0, rawStart))
            let clampedEnd = min(rawDuration, max(clampedStart, rawEnd))
            guard clampedStart >= previousStart,
                  clampedEnd >= previousEnd
            else {
                return []
            }

            normalized.append(
                TranscriptTokenTiming(
                    token: timing.token,
                    startTime: clampedStart,
                    endTime: clampedEnd
                )
            )
            previousStart = clampedStart
            previousEnd = clampedEnd
        }

        return normalized
    }

    struct PreparedInput: Sendable {
        let originalSampleCount: Int
        let leadingPaddingSampleCount: Int
        let trailingPaddingSampleCount: Int
        let preparedSamples: [Float]
    }
}
