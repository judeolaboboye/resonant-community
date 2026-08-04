@preconcurrency import AVFoundation
import Foundation

struct MeetingVoiceProfileStore {
    static let minimumEnrollmentDuration: TimeInterval = 4
    static let recommendedEnrollmentDuration: TimeInterval = 12
    static let targetSampleRate: Double = 16_000

    let rootURL: URL
    let enrollmentFileName: String
    private let fileManager: FileManager

    init(
        rootURL: URL = MeetingVoiceProfileStore.defaultRootURL(),
        enrollmentFileName: String = "local-user-voice-profile.caf",
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL
        self.enrollmentFileName = enrollmentFileName
        self.fileManager = fileManager
    }

    var enrollmentURL: URL {
        let preferred = preferredEnrollmentURL
        if fileManager.fileExists(atPath: preferred.path) {
            return preferred
        }
        let legacy = legacyEnrollmentURL
        if enrollmentFileName == "local-user-voice-profile.caf",
           fileManager.fileExists(atPath: legacy.path) {
            return legacy
        }
        return preferred
    }

    private var preferredEnrollmentURL: URL {
        rootURL.appendingPathComponent(enrollmentFileName, isDirectory: false)
    }

    private var legacyEnrollmentURL: URL {
        rootURL.appendingPathComponent(
            "local-user-voice-profile.m4a",
            isDirectory: false
        )
    }

    var hasEnrollment: Bool {
        fileManager.fileExists(atPath: enrollmentURL.path)
    }

    @discardableResult
    func saveEnrollment(from sourceURL: URL) throws -> URL {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let destination = preferredEnrollmentURL
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        if enrollmentFileName == "local-user-voice-profile.caf",
           fileManager.fileExists(atPath: legacyEnrollmentURL.path) {
            try fileManager.removeItem(at: legacyEnrollmentURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destination)
        return destination
    }

    @discardableResult
    func saveEnrollmentIfAbsent(from sourceURL: URL) throws -> URL? {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let destination = preferredEnrollmentURL
        guard !fileManager.fileExists(atPath: destination.path) else {
            return nil
        }

        do {
            try fileManager.copyItem(at: sourceURL, to: destination)
            return destination
        } catch {
            if fileManager.fileExists(atPath: destination.path) {
                return nil
            }
            throw error
        }
    }

    func deleteEnrollment() throws {
        var candidates = Set([preferredEnrollmentURL])
        if enrollmentFileName == "local-user-voice-profile.caf" {
            candidates.insert(legacyEnrollmentURL)
        }
        for candidate in candidates where fileManager.fileExists(atPath: candidate.path) {
            try fileManager.removeItem(at: candidate)
        }
    }

    func loadEnrollmentSamples(maxDuration: TimeInterval = 30) throws -> [Float] {
        guard hasEnrollment else {
            throw MeetingVoiceProfileStoreError.missingEnrollment
        }
        return try Self.decodeSamples(
            from: enrollmentURL,
            targetSampleRate: Self.targetSampleRate,
            maxDuration: maxDuration
        )
    }

    static func decodeSamples(
        from url: URL,
        targetSampleRate: Double = targetSampleRate,
        maxDuration: TimeInterval? = nil
    ) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        )!

        guard let converter = AVAudioConverter(from: file.processingFormat, to: targetFormat) else {
            throw MeetingVoiceProfileStoreError.conversionUnavailable
        }

        let sourceFrameCapacity: AVAudioFrameCount = 8192
        let ratio = targetFormat.sampleRate / file.processingFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(sourceFrameCapacity) * ratio) + 64
        let maximumSampleCount = maxDuration.map { Int($0 * targetSampleRate) } ?? Int.max
        var samples: [Float] = []
        samples.reserveCapacity(min(maximumSampleCount, Int(targetSampleRate * 12)))

        while file.framePosition < file.length, samples.count < maximumSampleCount {
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: outputCapacity
            ) else {
                throw MeetingVoiceProfileStoreError.conversionUnavailable
            }

            var error: NSError?
            nonisolated(unsafe) var didProvideInput = false

            converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                if didProvideInput {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                guard let readBuffer = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat,
                    frameCapacity: sourceFrameCapacity
                ) else {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: readBuffer)
                    guard readBuffer.frameLength > 0 else {
                        outStatus.pointee = .endOfStream
                        return nil
                    }
                    didProvideInput = true
                    outStatus.pointee = .haveData
                    return readBuffer
                } catch {
                    outStatus.pointee = .endOfStream
                    return nil
                }
            }

            if let error {
                throw MeetingVoiceProfileStoreError.conversionFailed(error.localizedDescription)
            }

            guard outputBuffer.frameLength > 0,
                  let channelData = outputBuffer.floatChannelData else {
                break
            }

            let frameCount = min(Int(outputBuffer.frameLength), maximumSampleCount - samples.count)
            samples.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: frameCount))
        }

        guard !samples.isEmpty else {
            throw MeetingVoiceProfileStoreError.emptyAudio
        }
        return samples
    }

    private static func defaultRootURL() -> URL {
        AppSupportPaths.resonantRoot()
            .appendingPathComponent("VoiceProfile", isDirectory: true)
    }
}

enum MeetingVoiceProfileStoreError: LocalizedError {
    case missingEnrollment
    case conversionUnavailable
    case conversionFailed(String)
    case emptyAudio

    var errorDescription: String? {
        switch self {
        case .missingEnrollment:
            return "No local voice profile has been recorded."
        case .conversionUnavailable:
            return "Voice profile audio could not be converted."
        case .conversionFailed(let reason):
            return "Voice profile audio conversion failed: \(reason)"
        case .emptyAudio:
            return "Voice profile audio did not contain usable samples."
        }
    }
}
