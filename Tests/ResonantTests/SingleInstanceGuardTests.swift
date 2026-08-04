import XCTest
@testable import Resonant

final class SingleInstanceGuardTests: XCTestCase {

    private func instance(_ pid: pid_t, launchedSecondsAgo: TimeInterval?) -> SingleInstanceTerminationPolicy.Instance {
        SingleInstanceTerminationPolicy.Instance(
            processIdentifier: pid,
            launchDate: launchedSecondsAgo.map { Date(timeIntervalSinceNow: -$0) }
        )
    }

    func testNewestInstanceTerminatesAllOlderOnes() {
        let stale = SingleInstanceTerminationPolicy.instancesToTerminate(
            currentProcessIdentifier: 400,
            currentLaunchDate: Date(),
            others: [
                instance(100, launchedSecondsAgo: 3600),
                instance(200, launchedSecondsAgo: 60),
                instance(300, launchedSecondsAgo: 5),
            ]
        )
        XCTAssertEqual(stale, [100, 200, 300])
    }

    func testOlderInstanceLeavesNewerSiblingAlone() {
        let stale = SingleInstanceTerminationPolicy.instancesToTerminate(
            currentProcessIdentifier: 100,
            currentLaunchDate: Date(timeIntervalSinceNow: -3600),
            others: [instance(200, launchedSecondsAgo: 5)]
        )
        XCTAssertTrue(stale.isEmpty)
    }

    func testSimultaneousLaunchTieBreaksByProcessIdentifierSoExactlyOneSurvives() {
        let launchDate = Date()
        let winner = SingleInstanceTerminationPolicy.instancesToTerminate(
            currentProcessIdentifier: 200,
            currentLaunchDate: launchDate,
            others: [SingleInstanceTerminationPolicy.Instance(processIdentifier: 100, launchDate: launchDate)]
        )
        XCTAssertEqual(winner, [100])

        let loser = SingleInstanceTerminationPolicy.instancesToTerminate(
            currentProcessIdentifier: 100,
            currentLaunchDate: launchDate,
            others: [SingleInstanceTerminationPolicy.Instance(processIdentifier: 200, launchDate: launchDate)]
        )
        XCTAssertTrue(loser.isEmpty)
    }

    func testInstanceWithUnknownLaunchDateIsTreatedAsOldest() {
        let stale = SingleInstanceTerminationPolicy.instancesToTerminate(
            currentProcessIdentifier: 200,
            currentLaunchDate: Date(),
            others: [instance(100, launchedSecondsAgo: nil)]
        )
        XCTAssertEqual(stale, [100])
    }

    func testCurrentProcessIsNeverListed() {
        let stale = SingleInstanceTerminationPolicy.instancesToTerminate(
            currentProcessIdentifier: 100,
            currentLaunchDate: Date(),
            others: [instance(100, launchedSecondsAgo: 3600)]
        )
        XCTAssertTrue(stale.isEmpty)
    }
}
