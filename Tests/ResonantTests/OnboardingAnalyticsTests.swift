import XCTest
@testable import Resonant

final class OnboardingAnalyticsTests: XCTestCase {
    func testSessionContextDistinguishesFirstRunWelcomeResumeLaterResumeAndReopen() {
        XCTAssertEqual(
            OnboardingAnalytics.SessionContext.resolve(
                onboardingCompleted: false,
                hadStarted: false,
                initialStep: "welcome"
            ),
            .init(sessionType: .firstRun, initialStep: "welcome")
        )
        XCTAssertEqual(
            OnboardingAnalytics.SessionContext.resolve(
                onboardingCompleted: false,
                hadStarted: true,
                initialStep: "welcome"
            ),
            .init(sessionType: .resume, initialStep: "welcome")
        )
        XCTAssertEqual(
            OnboardingAnalytics.SessionContext.resolve(
                onboardingCompleted: false,
                hadStarted: true,
                initialStep: "practice"
            ),
            .init(sessionType: .resume, initialStep: "practice")
        )
        XCTAssertEqual(
            OnboardingAnalytics.SessionContext.resolve(
                onboardingCompleted: false,
                hadStarted: false,
                initialStep: "practice"
            ),
            .init(sessionType: .resume, initialStep: "practice"),
            "Pre-v2 persisted progress must migrate into resume, not first_run"
        )
        XCTAssertEqual(
            OnboardingAnalytics.SessionContext.resolve(
                onboardingCompleted: true,
                hadStarted: true,
                initialStep: "welcome"
            ),
            .init(sessionType: .reopen, initialStep: "welcome")
        )
    }

    func testPermissionReducerIgnoresBaselineAndRepeatedTruePolls() {
        let baselineGranted = OnboardingAnalytics.PermissionSnapshot(
            microphone: true,
            accessibility: true,
            inputMonitoring: true
        )
        XCTAssertEqual(
            baselineGranted.newlyGranted(comparedTo: baselineGranted),
            []
        )
    }

    func testPermissionReducerEmitsOnlyFalseToTrueTransitions() {
        let previous = OnboardingAnalytics.PermissionSnapshot(
            microphone: false,
            accessibility: true,
            inputMonitoring: false
        )
        let current = OnboardingAnalytics.PermissionSnapshot(
            microphone: true,
            accessibility: true,
            inputMonitoring: true
        )

        XCTAssertEqual(
            current.newlyGranted(comparedTo: previous),
            [.microphone, .inputMonitoring]
        )
    }

    func testPropertiesAlwaysCarryV2SessionBoundary() {
        let context = OnboardingAnalytics.SessionContext(
            sessionType: .resume,
            initialStep: "permissions"
        )
        let properties = OnboardingAnalytics.properties(
            context: context,
            additional: ["step_id": "permissions"]
        )

        XCTAssertEqual(properties["schema_version"] as? Int, 2)
        XCTAssertEqual(properties["session_type"] as? String, "resume")
        XCTAssertEqual(properties["initial_step"] as? String, "permissions")
        XCTAssertEqual(properties["step_id"] as? String, "permissions")
    }
}
