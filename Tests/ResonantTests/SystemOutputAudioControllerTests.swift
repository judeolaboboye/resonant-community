import CoreAudio
import Foundation
import XCTest
@testable import Resonant

@MainActor
final class SystemOutputAudioControllerTests: XCTestCase {

    func testBeginAndEndDuckingRestoresOriginalVolume() async {
        let volumeBox = LockedFloat32(0.8)
        let controller = SystemOutputAudioController(
            defaultOutputDeviceIDProvider: { 11 },
            getVolume: { _ in volumeBox.value },
            setVolume: { _, volume in
                volumeBox.value = volume
                return true
            }
        )

        controller.beginDuckingIfNeeded(enabled: true)
        await waitForVolume(volumeBox, toEqual: 0.15)

        controller.endDuckingIfNeeded()
        await waitForVolume(volumeBox, toEqual: 0.8)
    }

    func testDuckingDoesNothingWhenAlreadyQuiet() {
        var setCalls = 0
        let controller = SystemOutputAudioController(
            defaultOutputDeviceIDProvider: { 11 },
            getVolume: { _ in 0.1 },
            setVolume: { _, _ in
                setCalls += 1
                return true
            }
        )

        controller.beginDuckingIfNeeded(enabled: true)
        controller.endDuckingIfNeeded()

        XCTAssertEqual(setCalls, 0)
    }

    func testRestoreDoesNothingWhenDuckingWasNeverApplied() {
        var setCalls = 0
        let controller = SystemOutputAudioController(
            defaultOutputDeviceIDProvider: { 11 },
            getVolume: { _ in nil },
            setVolume: { _, _ in
                setCalls += 1
                return true
            }
        )

        controller.beginDuckingIfNeeded(enabled: true)
        controller.endDuckingIfNeeded()

        XCTAssertEqual(setCalls, 0)
    }

    func testQuickRestartKeepsDuckingAfterPendingBeginCompletes() async {
        let volumeBox = LockedFloat32(0.8)
        let firstDuckingApplied = expectation(description: "first ducking volume applied")
        let restoredDuringRestart = expectation(description: "volume restored during restart")
        restoredDuringRestart.isInverted = true
        let allowFirstDuckingAttemptToFinish = DispatchSemaphore(value: 0)
        let hasBlockedFirstDuckingAttempt = LockedBool(false)
        let restartActive = LockedBool(false)

        let controller = SystemOutputAudioController(
            defaultOutputDeviceIDProvider: { 11 },
            getVolume: { _ in volumeBox.value },
            setVolume: { _, volume in
                volumeBox.value = volume
                if abs(volume - 0.8) <= 0.0001, restartActive.value {
                    restoredDuringRestart.fulfill()
                }
                if abs(volume - 0.15) <= 0.0001, !hasBlockedFirstDuckingAttempt.value {
                    hasBlockedFirstDuckingAttempt.value = true
                    firstDuckingApplied.fulfill()
                    allowFirstDuckingAttemptToFinish.wait()
                }
                return true
            }
        )

        controller.beginDuckingIfNeeded(enabled: true)
        await fulfillment(of: [firstDuckingApplied], timeout: 1.0)

        controller.endDuckingIfNeeded()
        restartActive.value = true
        controller.beginDuckingIfNeeded(enabled: true)
        allowFirstDuckingAttemptToFinish.signal()

        await fulfillment(of: [restoredDuringRestart], timeout: 0.5)
        XCTAssertEqual(volumeBox.value, 0.15, accuracy: 0.0001)

        restartActive.value = false
        controller.endDuckingIfNeeded()
        await waitForVolume(volumeBox, toEqual: 0.8)
    }

    private func waitForVolume(
        _ volume: LockedFloat32,
        toEqual expected: Float32,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<50 {
            if abs(volume.value - expected) <= 0.0001 {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(volume.value, expected, accuracy: 0.0001, file: file, line: line)
    }
}

private final class LockedFloat32: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Float32

    init(_ value: Float32) {
        storage = value
    }

    var value: Float32 {
        get {
            lock.withLock { storage }
        }
        set {
            lock.withLock { storage = newValue }
        }
    }
}

private final class LockedBool: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Bool

    init(_ value: Bool) {
        storage = value
    }

    var value: Bool {
        get {
            lock.withLock { storage }
        }
        set {
            lock.withLock { storage = newValue }
        }
    }
}
