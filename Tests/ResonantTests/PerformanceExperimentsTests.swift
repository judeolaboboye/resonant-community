import XCTest
@testable import Resonant

final class PerformanceExperimentsTests: XCTestCase {

    @MainActor
    private final class AnalyticsSpy: PerformanceExperimentAnalytics {
        var flags: [String: Any] = [:]
        var events: [(name: String, properties: [String: Any])] = []

        func getFeatureFlag(_ flag: String) -> Any? {
            flags[flag]
        }

        func capture(_ event: String, properties: [String: Any], allowWhenDisabled: Bool) {
            events.append((event, properties))
        }
    }

    func testLatencyBuckets() {
        XCTAssertEqual(PerformanceExperiments.latencyBucket(-1), "unknown")
        XCTAssertEqual(PerformanceExperiments.latencyBucket(0), "0-250ms")
        XCTAssertEqual(PerformanceExperiments.latencyBucket(249), "0-250ms")
        XCTAssertEqual(PerformanceExperiments.latencyBucket(250), "250-500ms")
        XCTAssertEqual(PerformanceExperiments.latencyBucket(999), "500-1000ms")
        XCTAssertEqual(PerformanceExperiments.latencyBucket(1_000), "1000-2000ms")
        XCTAssertEqual(PerformanceExperiments.latencyBucket(2_000), "2000-5000ms")
        XCTAssertEqual(PerformanceExperiments.latencyBucket(5_000), "5000ms+")
    }

    func testLatencyOutcomesAreCoarseAndValidated() {
        XCTAssertEqual(PerformanceExperiments.sanitizedOutcome("success"), "success")
        XCTAssertEqual(PerformanceExperiments.sanitizedOutcome("CANCELLED"), "cancelled")
        XCTAssertEqual(PerformanceExperiments.sanitizedOutcome("transcript leaked here"), "unknown")
        XCTAssertEqual(PerformanceExperiments.sanitizedOutcome(nil), "unknown")
    }

    func testTargetProfileUsesCoarseCategories() {
        XCTAssertEqual(
            PerformanceExperiments.targetProfile(bundleId: "com.conductor.app"),
            "ai_coding_app"
        )
        XCTAssertEqual(
            PerformanceExperiments.targetProfile(bundleId: "com.microsoft.VSCode"),
            "code_editor"
        )
        XCTAssertEqual(
            PerformanceExperiments.targetProfile(bundleId: "com.apple.Terminal"),
            "terminal"
        )
        XCTAssertEqual(
            PerformanceExperiments.targetProfile(bundleId: "com.apple.mail"),
            "email"
        )
        XCTAssertEqual(
            PerformanceExperiments.targetProfile(bundleId: "com.apple.Safari"),
            "browser"
        )
        XCTAssertEqual(
            PerformanceExperiments.targetProfile(bundleId: "com.example.NativeApp"),
            "native_app"
        )
        XCTAssertEqual(
            PerformanceExperiments.targetProfile(bundleId: nil),
            "unknown"
        )
    }

    @MainActor
    func testLatencyMetricReadsAssignmentsWithoutRecordingExposure() {
        let analytics = AnalyticsSpy()
        analytics.flags[PerformanceExperiments.Experiment.pasteVerificationDelay.flagKey] = "short_80ms"
        let experiments = PerformanceExperiments(analytics: analytics)

        experiments.recordDictationLatency(.init(outcome: "failure", totalMs: 123))

        XCTAssertEqual(analytics.events.map(\.name), ["dictation_latency_v2"])
        XCTAssertEqual(
            analytics.events.first?.properties["experiment_paste_verification_delay"] as? String,
            "short_80ms"
        )
        XCTAssertEqual(analytics.events.first?.properties["outcome"] as? String, "failure")
    }

    @MainActor
    func testDecisionPointAssignmentRecordsExposureWithSource() {
        let analytics = AnalyticsSpy()
        analytics.flags[PerformanceExperiments.Experiment.pasteVerificationDelay.flagKey] = "short_80ms"
        let experiments = PerformanceExperiments(analytics: analytics)

        _ = experiments.assignment(for: .pasteVerificationDelay, source: "paste_delivery")

        XCTAssertEqual(analytics.events.map(\.name), ["performance_experiment_exposure"])
        XCTAssertEqual(analytics.events.first?.properties["source"] as? String, "paste_delivery")
    }
}
