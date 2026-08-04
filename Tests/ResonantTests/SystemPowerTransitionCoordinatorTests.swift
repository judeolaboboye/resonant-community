import XCTest
@testable import Resonant

@MainActor
final class SystemPowerTransitionCoordinatorTests: XCTestCase {
    func testWakeWaitsForRetiredSleepAndLatestTransitionWins() async {
        let coordinator = SystemPowerTransitionCoordinator()
        let sleepGate = AsyncTestGate()
        let sleepEntered = expectation(description: "sleep cleanup entered")
        var events: [String] = []

        coordinator.enqueue { stillOwnsTransition in
            events.append("sleep-start")
            sleepEntered.fulfill()
            await sleepGate.wait()
            guard stillOwnsTransition() else {
                events.append("sleep-retired")
                return
            }
            events.append("sleep-finish")
        }

        await fulfillment(of: [sleepEntered], timeout: 1)
        coordinator.enqueue { stillOwnsTransition in
            guard stillOwnsTransition() else { return }
            events.append("wake-finish")
        }

        await sleepGate.open()
        await coordinator.waitForIdle()

        XCTAssertEqual(events, ["sleep-start", "sleep-retired", "wake-finish"])
    }

    func testInvalidationVetoesPostAwaitSideEffects() async {
        let coordinator = SystemPowerTransitionCoordinator()
        let gate = AsyncTestGate()
        let entered = expectation(description: "transition entered")
        var didPerformPostAwaitEffect = false

        coordinator.enqueue { stillOwnsTransition in
            entered.fulfill()
            await gate.wait()
            guard stillOwnsTransition() else { return }
            didPerformPostAwaitEffect = true
        }

        await fulfillment(of: [entered], timeout: 1)
        coordinator.invalidate()
        await gate.open()
        await coordinator.waitForIdle()

        XCTAssertFalse(didPerformPostAwaitEffect)
    }
}

private actor AsyncTestGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let waiting = continuations
        continuations.removeAll()
        for continuation in waiting {
            continuation.resume()
        }
    }
}
