import XCTest
@testable import Resonant

final class DispatchTargetGuardTests: XCTestCase {
    func testStableTargetActionBlocksSecureCurrentTargetWithoutLearnedBinding() {
        let evaluation = DispatchTargetGuard.evaluate(
            action: .typeText(text: "ship it", appHint: nil),
            binding: nil,
            currentSurface: DispatchSurfaceFingerprint(
                axRole: "AXTextField",
                axSubrole: "AXSecureTextField",
                axIsSensitiveInput: true
            )
        )

        XCTAssertFalse(evaluation.allowed)
        XCTAssertEqual(evaluation.check.summary, "I won't type into a secure text field. Focus a normal text box and try again.")
    }

    func testNonTypingActionsDoNotRequireTargetGuard() {
        let evaluation = DispatchTargetGuard.evaluate(
            action: .openApp(name: "Slack"),
            binding: nil,
            currentSurface: DispatchSurfaceFingerprint(
                axRole: "AXTextField",
                axSubrole: "AXSecureTextField",
                axIsSensitiveInput: true
            )
        )

        XCTAssertTrue(evaluation.allowed)
        XCTAssertFalse(evaluation.check.required)
    }
}
