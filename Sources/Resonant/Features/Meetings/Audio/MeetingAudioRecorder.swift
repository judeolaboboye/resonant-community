@preconcurrency import AVFoundation
import Dispatch
import Foundation
import os

/// Persists meeting mic and system audio as 16kHz mono PCM and produces a mixed file on finalize.
final class MeetingAudioRecorder: @unchecked Sendable {

    enum Channel: Hashable, Sendable {
        case mic
        case system
    }

    private let log = Logger.resonant("MeetingAudioRecorder")
    private let queue: DispatchQueue
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!
    private let startedUptime: TimeInterval
    private let micURL: URL
    private let systemURL: URL
    private let mixURL: URL

    private var micFile: AVAudioFile?
    private var systemFile: AVAudioFile?
    private var firstChunkUptimeByChannel: [Channel: TimeInterval] = [:]
    private var sampleCountByChannel: [Channel: Int] = [:]
    private var didFail = false
    private var didReportFailure = false

    /// Invoked at most once when audio capture stops being viable mid-session
    /// (write/mix error). The recording will end up discarded by `finish()` —
    /// callers should surface this to the user before that happens silently.
    var onCaptureFailed: (@Sendable (String) -> Void)?

    init(sessionID: UUID) throws {
        queue = DispatchQueue(label: "com.resonance.resonant.meeting-audio.\(sessionID.uuidString.lowercased())")
        let root = AppSupportPaths.resonantRoot()
            .appendingPathComponent("meetings-active/audio", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let baseName = sessionID.uuidString.lowercased()
        micURL = root.appendingPathComponent("\(baseName)-mic.wav")
        systemURL = root.appendingPathComponent("\(baseName)-system.wav")
        mixURL = root.appendingPathComponent("\(baseName)-mix.wav")

        micFile = try Self.makeFile(at: micURL, format: format)
        systemFile = try Self.makeFile(at: systemURL, format: format)
        startedUptime = ProcessInfo.processInfo.systemUptime
    }

    func append(_ samples: [Float], channel: Channel, uptime: TimeInterval) {
        guard !samples.isEmpty else { return }

        queue.sync {
            guard !didFail else { return }

            do {
                try writeInitialSilenceIfNeeded(for: channel, firstChunkUptime: uptime)
                try write(samples, to: channel)
            } catch {
                didFail = true
                log.error("Meeting audio capture failed: \(error.localizedDescription)")
                reportFailureUnlocked(error.localizedDescription)
            }
        }
    }

    func finish() -> URL? {
        queue.sync {
            guard !didFail else {
                discardUnlocked()
                return nil
            }

            micFile = nil
            systemFile = nil

            let micSamples = sampleCountByChannel[.mic] ?? 0
            let systemSamples = sampleCountByChannel[.system] ?? 0
            guard micSamples > 0 || systemSamples > 0 else {
                discardUnlocked()
                return nil
            }

            do {
                if FileManager.default.fileExists(atPath: mixURL.path) {
                    try FileManager.default.removeItem(at: mixURL)
                }

                if micSamples > 0 && systemSamples > 0 {
                    try mixTracks()
                } else {
                    let sourceURL = micSamples > 0 ? micURL : systemURL
                    try FileManager.default.copyItem(at: sourceURL, to: mixURL)
                }
            } catch {
                log.error("Failed to finalize meeting audio: \(error.localizedDescription)")
                reportFailureUnlocked(error.localizedDescription)
                discardUnlocked()
                return nil
            }

            cleanupStemFiles()
            return mixURL
        }
    }

    func discard() {
        queue.sync {
            discardUnlocked()
        }
    }

    private func writeInitialSilenceIfNeeded(for channel: Channel, firstChunkUptime: TimeInterval) throws {
        guard firstChunkUptimeByChannel[channel] == nil else { return }
        firstChunkUptimeByChannel[channel] = firstChunkUptime

        let leadingSeconds = max(0, firstChunkUptime - startedUptime)
        let leadingSamples = Int((leadingSeconds * format.sampleRate).rounded(.down))
        guard leadingSamples > 0 else { return }

        try writeSilence(frameCount: leadingSamples, to: channel)
    }

    private func write(_ samples: [Float], to channel: Channel) throws {
        var offset = 0
        while offset < samples.count {
            let count = min(samples.count - offset, 8192)
            let chunk = Array(samples[offset..<(offset + count)])
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(count)
            ), let channelData = buffer.floatChannelData?[0] else {
                throw MeetingAudioRecorderError.bufferAllocationFailed
            }
            buffer.frameLength = AVAudioFrameCount(count)
            for index in 0..<count {
                channelData[index] = chunk[index]
            }
            try file(for: channel)?.write(from: buffer)
            sampleCountByChannel[channel, default: 0] += count
            offset += count
        }
    }

    private func writeSilence(frameCount: Int, to channel: Channel) throws {
        var remaining = frameCount
        while remaining > 0 {
            let count = min(remaining, 8192)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(count)
            ) else {
                throw MeetingAudioRecorderError.bufferAllocationFailed
            }
            buffer.frameLength = AVAudioFrameCount(count)
            if let channelData = buffer.floatChannelData?[0] {
                for index in 0..<count {
                    channelData[index] = 0
                }
            }
            try file(for: channel)?.write(from: buffer)
            sampleCountByChannel[channel, default: 0] += count
            remaining -= count
        }
    }

    private func mixTracks() throws {
        let micInput = try AVAudioFile(forReading: micURL)
        let systemInput = try AVAudioFile(forReading: systemURL)
        let mixOutput = try Self.makeFile(at: mixURL, format: format)
        let chunkSize: AVAudioFrameCount = 8192

        while true {
            guard let micBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkSize),
                  let systemBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkSize),
                  let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkSize)
            else {
                throw MeetingAudioRecorderError.bufferAllocationFailed
            }

            try micInput.read(into: micBuffer)
            try systemInput.read(into: systemBuffer)

            let frameCount = max(micBuffer.frameLength, systemBuffer.frameLength)
            guard frameCount > 0 else { break }

            outputBuffer.frameLength = frameCount
            let output = outputBuffer.floatChannelData![0]
            let mic = micBuffer.floatChannelData?[0]
            let system = systemBuffer.floatChannelData?[0]

            for index in 0..<Int(frameCount) {
                let micSample: Float
                if index < Int(micBuffer.frameLength), let mic {
                    micSample = mic[index]
                } else {
                    micSample = 0
                }

                let systemSample: Float
                if index < Int(systemBuffer.frameLength), let system {
                    systemSample = system[index]
                } else {
                    systemSample = 0
                }

                let mixed = (micSample + systemSample) * 0.5
                output[index] = min(1, max(-1, mixed))
            }

            try mixOutput.write(from: outputBuffer)
        }
    }

    private func file(for channel: Channel) -> AVAudioFile? {
        switch channel {
        case .mic:
            return micFile
        case .system:
            return systemFile
        }
    }

    private func cleanupStemFiles() {
        try? FileManager.default.removeItem(at: micURL)
        try? FileManager.default.removeItem(at: systemURL)
    }

    private func discardUnlocked() {
        micFile = nil
        systemFile = nil
        cleanupStemFiles()
        try? FileManager.default.removeItem(at: mixURL)
    }

    private func reportFailureUnlocked(_ detail: String) {
        guard !didReportFailure else { return }
        didReportFailure = true
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = trimmed.isEmpty
            ? "Meeting audio capture failed. Recording will be saved without audio."
            : "Meeting audio capture failed: \(trimmed). Recording will be saved without audio."
        onCaptureFailed?(message)
    }

    private static func makeFile(at url: URL, format: AVAudioFormat) throws -> AVAudioFile {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        return try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
    }
}

private enum MeetingAudioRecorderError: Error {
    case bufferAllocationFailed
}
