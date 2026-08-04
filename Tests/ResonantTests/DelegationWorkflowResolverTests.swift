import XCTest
@testable import Resonant

@MainActor
final class DelegationWorkflowResolverTests: XCTestCase {

    func testPrefersRecentDevinWebContext() {
        let snapshots = [
            DelegationWorkflowResolver.Snapshot(
                timestamp: Date().addingTimeInterval(-60),
                appName: "Safari",
                bundleId: "com.apple.Safari",
                windowTitle: "Devin",
                browserURL: "https://app.devin.ai/sessions/abc",
                codeFileName: nil,
                focusedFieldContent: nil,
                visibleTextSnippets: ["Task details for parakeet-swift"],
                browserTabs: []
            )
        ]

        let plan = DelegationWorkflowResolver.resolve(
            agent: .devin,
            prompt: "fix the dictation race",
            explicitContext: nil,
            snapshots: snapshots
        )

        XCTAssertEqual(plan.surface, .devinWeb)
        XCTAssertGreaterThan(plan.confidence, 0.6)
    }

    func testInfersConductorWorkspaceForDevin() {
        let snapshots = [
            DelegationWorkflowResolver.Snapshot(
                timestamp: Date().addingTimeInterval(-120),
                appName: "Terminal",
                bundleId: "com.apple.Terminal",
                windowTitle: "Conductor - Devin",
                browserURL: nil,
                codeFileName: nil,
                focusedFieldContent: "cd /Users/dev/conductor/workspaces/example-project/feature-branch",
                visibleTextSnippets: ["devin task in conductor"],
                browserTabs: []
            )
        ]

        let plan = DelegationWorkflowResolver.resolve(
            agent: .devin,
            prompt: "add a resolver",
            explicitContext: nil,
            snapshots: snapshots
        )

        XCTAssertEqual(plan.surface, .conductorTerminal)
        XCTAssertEqual(plan.projectHint, "example-project")
        XCTAssertEqual(plan.workspacePath, "/Users/dev/conductor/workspaces/example-project/feature-branch")
    }
}
