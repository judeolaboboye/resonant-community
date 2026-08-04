import Foundation
import XCTest
@testable import Resonant

final class AudioCaptureHardwareCoordinatorTests: XCTestCase {
    func testInvalidationPublishesDuringConstructorAndWaitsForItToFinish() {
        let gate = AudioWarmRequestGenerationGate()
        gate.publish(1)

        let constructorEntered = expectation(description: "constructor seam entered")
        let constructorFinished = expectation(description: "constructor seam finished")
        let publisherReturned = expectation(description: "publisher returned")
        let publisherDidReturn = LockedTestValue(false)
        let releaseConstructor = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            XCTAssertTrue(
                gate.performIfCurrent(1) {
                    constructorEntered.fulfill()
                    releaseConstructor.wait()
                }
            )
            constructorFinished.fulfill()
        }
        wait(for: [constructorEntered], timeout: 1)

        DispatchQueue.global(qos: .userInitiated).async {
            gate.publish(2)
            publisherDidReturn.withValue { $0 = true }
            publisherReturned.fulfill()
        }

        // Publication is immediately visible to the lifecycle worker's
        // post-construction check, while publish itself remains a barrier until
        // the constructor seam exits.
        let generationChanged = expectation(description: "generation changed")
        DispatchQueue.global(qos: .userInitiated).async {
            let deadline = Date().addingTimeInterval(1)
            while gate.isCurrent(1), Date() < deadline {
                Thread.sleep(forTimeInterval: 0.001)
            }
            generationChanged.fulfill()
        }
        wait(for: [generationChanged], timeout: 1)
        XCTAssertFalse(gate.isCurrent(1))
        XCTAssertFalse(publisherDidReturn.value)

        releaseConstructor.signal()
        wait(for: [constructorFinished, publisherReturned], timeout: 1)
        XCTAssertTrue(gate.isCurrent(2))
    }

    func testGenerationPublishedAfterHeadCheckStillVetoesConstructorSeam() {
        let gate = AudioWarmRequestGenerationGate()
        gate.publish(7)
        XCTAssertTrue(gate.isCurrent(7))

        // Simulate recovery arriving after the lifecycle block starts but
        // before AudioRecorder reaches AVCaptureDeviceInput(device:).
        gate.publish(8)
        var didConstruct = false
        XCTAssertFalse(
            gate.performIfCurrent(7) {
                didConstruct = true
            }
        )
        XCTAssertFalse(didConstruct)
    }

    func testSupersededWarmWorkDoesNotPassProductionGenerationSeam() {
        let gate = AudioWarmRequestGenerationGate()
        gate.publish(41)

        let blocker = DispatchSemaphore(value: 0)
        let blockerStarted = expectation(description: "shared queue blocked")
        AudioCaptureHardwareCoordinator.lifecycleQueue.async {
            blockerStarted.fulfill()
            blocker.wait()
        }
        wait(for: [blockerStarted], timeout: 1)

        let didTouchInputConstruction = LockedTestValue(false)
        let staleWorkFinished = expectation(description: "stale warm work drained")
        AudioCaptureHardwareCoordinator.lifecycleQueue.async {
            gate.performIfCurrent(41) {
                didTouchInputConstruction.withValue { $0 = true }
            }
            staleWorkFinished.fulfill()
        }

        // Recovery publishes before the already-submitted lifecycle block can
        // run. AudioRecorder's production warm closure uses this same seam as
        // its first lifecycle decision.
        gate.publish(42)
        blocker.signal()

        wait(for: [staleWorkFinished], timeout: 1)
        XCTAssertFalse(didTouchInputConstruction.value)
    }

    func testSharedLifecycleQueuePreservesReleaseBeforeOpenFIFOOrder() {
        let operations = LockedTestValue<[String]>([])
        let finished = expectation(description: "lifecycle operations drained")

        AudioCaptureHardwareCoordinator.lifecycleQueue.async {
            operations.withValue { $0.append("release") }
        }
        AudioCaptureHardwareCoordinator.lifecycleQueue.async {
            operations.withValue { $0.append("open") }
            finished.fulfill()
        }

        wait(for: [finished], timeout: 1)
        XCTAssertEqual(operations.value, ["release", "open"])
    }

    func testPersistentWarmIntentCannotBeDowngradedBySpeculativeCapture() {
        XCTAssertEqual(
            AudioRecorder.WarmUpIntent.merged(
                existing: .persistent,
                requested: .imminentCapture
            ),
            .persistent
        )
        XCTAssertEqual(
            AudioRecorder.WarmUpIntent.merged(
                existing: .imminentCapture,
                requested: .persistent
            ),
            .persistent
        )
        XCTAssertEqual(
            AudioRecorder.WarmUpIntent.merged(
                existing: .imminentCapture,
                requested: .imminentCapture
            ),
            .imminentCapture
        )
    }
}

private final class LockedTestValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func withValue(_ operation: (inout Value) -> Void) {
        lock.lock()
        operation(&storage)
        lock.unlock()
    }
}
