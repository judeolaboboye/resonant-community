@preconcurrency import AVFoundation
import XCTest
@testable import Resonant

final class MeetingVoiceProfileStoreTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVoiceProfileStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
    }

    func testSaveAndDeleteEnrollment() throws {
        let sourceURL = tempRoot.appendingPathComponent("source.txt")
        try Data("voice profile".utf8).write(to: sourceURL)

        let store = MeetingVoiceProfileStore(
            rootURL: tempRoot.appendingPathComponent("profile", isDirectory: true),
            enrollmentFileName: "sample.dat"
        )

        XCTAssertFalse(store.hasEnrollment)
        let savedURL = try store.saveEnrollment(from: sourceURL)
        XCTAssertEqual(savedURL, store.enrollmentURL)
        XCTAssertTrue(store.hasEnrollment)

        try store.deleteEnrollment()
        XCTAssertFalse(store.hasEnrollment)
    }

    func testSaveEnrollmentIfAbsentKeepsFirstProfile() throws {
        let firstSourceURL = tempRoot.appendingPathComponent("first.txt")
        let secondSourceURL = tempRoot.appendingPathComponent("second.txt")
        try Data("first profile".utf8).write(to: firstSourceURL)
        try Data("second profile".utf8).write(to: secondSourceURL)

        let store = MeetingVoiceProfileStore(
            rootURL: tempRoot.appendingPathComponent("profile", isDirectory: true),
            enrollmentFileName: "sample.dat"
        )

        XCTAssertEqual(try store.saveEnrollmentIfAbsent(from: firstSourceURL), store.enrollmentURL)
        XCTAssertNil(try store.saveEnrollmentIfAbsent(from: secondSourceURL))
        XCTAssertEqual(try Data(contentsOf: store.enrollmentURL), Data("first profile".utf8))
    }

    func testDefaultCAFPathReadsLegacyProfileAndMigratesOnReplacement() throws {
        let profileRoot = tempRoot.appendingPathComponent("profile", isDirectory: true)
        try FileManager.default.createDirectory(at: profileRoot, withIntermediateDirectories: true)
        let legacyURL = profileRoot.appendingPathComponent("local-user-voice-profile.m4a")
        try Data("legacy".utf8).write(to: legacyURL)
        let store = MeetingVoiceProfileStore(rootURL: profileRoot)

        XCTAssertEqual(store.enrollmentURL, legacyURL)
        XCTAssertTrue(store.hasEnrollment)

        let replacement = tempRoot.appendingPathComponent("replacement.caf")
        try Data("replacement".utf8).write(to: replacement)
        let saved = try store.saveEnrollment(from: replacement)

        XCTAssertEqual(saved.pathExtension, "caf")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertEqual(try Data(contentsOf: saved), Data("replacement".utf8))
    }

    func testLoadEnrollmentSamplesResamplesToSixteenKilohertzMono() throws {
        let sourceURL = tempRoot.appendingPathComponent("source.wav")
        try writeSineWave(to: sourceURL, sampleRate: 44_100, duration: 1.0)

        let store = MeetingVoiceProfileStore(
            rootURL: tempRoot.appendingPathComponent("profile", isDirectory: true),
            enrollmentFileName: "sample.wav"
        )
        try store.saveEnrollment(from: sourceURL)

        let samples = try store.loadEnrollmentSamples(maxDuration: 2)

        XCTAssertGreaterThan(samples.count, 15_000)
        XCTAssertLessThan(samples.count, 17_000)
        XCTAssertTrue(samples.contains { abs($0) > 0.01 })
    }

    private func writeSineWave(
        to url: URL,
        sampleRate: Double,
        duration: TimeInterval
    ) throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount

        let frequency: Float = 220
        let twoPi = Float.pi * 2
        let channel = buffer.floatChannelData![0]
        for frame in 0..<Int(frameCount) {
            let phase = twoPi * frequency * Float(frame) / Float(sampleRate)
            channel[frame] = Float(sin(Double(phase))) * 0.25
        }

        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
