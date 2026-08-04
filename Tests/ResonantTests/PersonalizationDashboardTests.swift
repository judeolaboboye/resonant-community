import XCTest
@testable import Resonant

@MainActor
final class PersonalizationDashboardTests: XCTestCase {
    func testOutcomeProviderIsExplicitlyUnavailableUntilActorSeamIsAttached() async {
        let store = PersonalizationMemoryStore()

        var controls = await store.controlsSnapshot()
        XCTAssertEqual(controls.evaluation.outcomes, .unavailable)

        let expected = Self.summary()
        store.attachOutcomeSummaryProvider { expected }
        controls = await store.controlsSnapshot()
        XCTAssertEqual(controls.evaluation.outcomes, .available(expected))

        let dashboard = await store.dashboardSnapshot()
        XCTAssertEqual(dashboard.outcomes, .available(expected))

        store.detachOutcomeSummaryProvider()
        controls = await store.controlsSnapshot()
        XCTAssertEqual(controls.evaluation.outcomes, .unavailable)
    }

    func testAttachedZeroPopulationRemainsAvailableAndDistinctFromMissingProvider() async {
        let store = PersonalizationMemoryStore()
        let empty = PersonalizationOutcomeSummary.make(
            records: [],
            capturedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )

        store.attachOutcomeSummaryProvider { empty }
        let controls = await store.controlsSnapshot()

        XCTAssertEqual(controls.evaluation.outcomes, .available(empty))
        XCTAssertEqual(empty.global.attemptCount, 0)
        XCTAssertEqual(empty.global.coverage.denominator, 0)
        XCTAssertEqual(empty.global.observedNoEditRate.denominator, 0)
    }

    func testEvaluationNeverSubstitutesCorrectionLogRowsForOutcomePopulation() {
        let event = PersonalizationEvaluationInput(
            id: UUID(),
            timestamp: Date(),
            appName: "Slack",
            surfaceKind: "chat",
            pastedText: "unchanged",
            editedText: "unchanged",
            corrections: [],
            hadCorrection: false
        )

        let unavailable = PersonalizationEvaluationEngine.evaluate(
            [event],
            outcomes: .unavailable
        )
        XCTAssertEqual(unavailable.correctionLogEventCount, 1)
        XCTAssertEqual(unavailable.editedCorrectionLogEventCount, 0)
        XCTAssertEqual(unavailable.outcomes, .unavailable)

        let expected = Self.summary()
        let available = PersonalizationEvaluationEngine.evaluate(
            [event],
            outcomes: .available(expected)
        )
        XCTAssertEqual(available.outcomes, .available(expected))
    }

    func testDashboardRatesKeepExactNumeratorsDenominatorsAndUnknownSurface() throws {
        let summary = Self.summary()

        XCTAssertEqual(summary.global.coverage.numerator, 2)
        XCTAssertEqual(summary.global.coverage.denominator, 4)
        XCTAssertEqual(summary.global.pendingCount, 1)
        XCTAssertEqual(summary.global.unobservableCount, 1)
        XCTAssertEqual(summary.global.excludedCount, 1)
        XCTAssertEqual(summary.global.observedNoEditRate.numerator, 1)
        XCTAssertEqual(summary.global.observedNoEditRate.denominator, 2)

        let unknown = try XCTUnwrap(summary.surfaces.first { $0.surface == .unknown })
        XCTAssertEqual(unknown.population.attemptCount, 1)
        XCTAssertEqual(unknown.population.excludedCount, 1)
        XCTAssertEqual(unknown.population.coverage.denominator, 0)
    }

    func testSettingsCopyAndRateFormattingAreObservationalAndAuditable() {
        XCTAssertEqual(PersonalizationSettingsCopy.writingHabitsTitle, "Writing Habits")
        XCTAssertEqual(PersonalizationSettingsCopy.eligibleTermsMetric, "eligible learned terms")
        XCTAssertEqual(PersonalizationSettingsCopy.eligibleHabitsMetric, "eligible writing habits")
        XCTAssertEqual(PersonalizationSettingsCopy.eligibleFormattingMetric, "eligible formatting rules")
        XCTAssertEqual(PersonalizationSettingsCopy.readbackCoverageTitle, "Readback coverage")
        XCTAssertEqual(PersonalizationSettingsCopy.observedNoEditTitle, "Observed no-edit")
        XCTAssertEqual(
            PersonalizationOutcomePresentation.rate(
                PersonalizationOutcomeRate(numerator: 2, denominator: 3)
            ),
            "2 / 3 (67%)"
        )
        XCTAssertEqual(
            PersonalizationOutcomePresentation.rate(
                PersonalizationOutcomeRate(numerator: 0, denominator: 0)
            ),
            "—"
        )
        XCTAssertEqual(
            PersonalizationOutcomePresentation.surfaceLabel(.unknown),
            "Unknown surface"
        )

        let publicCopy = [
            PersonalizationSettingsCopy.outcomesNotStarted,
            PersonalizationSettingsCopy.outcomesSettingUp,
            PersonalizationSettingsCopy.outcomesRetrying,
            PersonalizationSettingsCopy.outcomesLocalStorageNotReady,
            PersonalizationSettingsCopy.outcomesBootstrapUnavailable,
            PersonalizationSettingsCopy.outcomesLoadingSummary,
            PersonalizationSettingsCopy.outcomesEmpty,
            PersonalizationSettingsCopy.eligibleOutcomesEmpty,
            PersonalizationSettingsCopy.coverageExplanation,
            PersonalizationSettingsCopy.noEditExplanation,
            PersonalizationSettingsCopy.eligibleTermsMetric,
            PersonalizationSettingsCopy.eligibleHabitsMetric,
            PersonalizationSettingsCopy.eligibleFormattingMetric,
        ].joined(separator: " ").lowercased()
        XCTAssertFalse(publicCopy.contains("accepted output"))
        XCTAssertFalse(publicCopy.contains("acceptance"))
        XCTAssertFalse(publicCopy.contains("uplift"))
        XCTAssertFalse(publicCopy.contains("in use"))
        XCTAssertFalse(publicCopy.contains("active"))
    }

    private static func summary() -> PersonalizationOutcomeSummary {
        let global = PersonalizationOutcomePopulationSummary(
            attemptCount: 5,
            terminalCount: 4,
            pendingCount: 1,
            excludedCount: 1,
            unobservableCount: 1,
            acceptedCount: 1,
            correctedCount: 1,
            statusCounts: [
                .accepted: 1,
                .corrected: 1,
                .pending: 1,
                .targetMismatch: 1,
                .excludedCopyOnly: 1,
            ],
            exclusionCounts: [.excludedCopyOnly: 1],
            coverage: PersonalizationOutcomeRate(numerator: 2, denominator: 4),
            observedNoEditRate: PersonalizationOutcomeRate(numerator: 1, denominator: 2)
        )
        let chat = PersonalizationOutcomePopulationSummary(
            attemptCount: 4,
            terminalCount: 3,
            pendingCount: 1,
            excludedCount: 0,
            unobservableCount: 1,
            acceptedCount: 1,
            correctedCount: 1,
            statusCounts: [
                .accepted: 1,
                .corrected: 1,
                .pending: 1,
                .targetMismatch: 1,
            ],
            exclusionCounts: [:],
            coverage: PersonalizationOutcomeRate(numerator: 2, denominator: 4),
            observedNoEditRate: PersonalizationOutcomeRate(numerator: 1, denominator: 2)
        )
        let unknown = PersonalizationOutcomePopulationSummary(
            attemptCount: 1,
            terminalCount: 1,
            pendingCount: 0,
            excludedCount: 1,
            unobservableCount: 0,
            acceptedCount: 0,
            correctedCount: 0,
            statusCounts: [.excludedCopyOnly: 1],
            exclusionCounts: [.excludedCopyOnly: 1],
            coverage: PersonalizationOutcomeRate(numerator: 0, denominator: 0),
            observedNoEditRate: PersonalizationOutcomeRate(numerator: 0, denominator: 0)
        )
        return PersonalizationOutcomeSummary(
            capturedAt: Date(timeIntervalSince1970: 2_000_000_000),
            global: global,
            surfaces: [
                PersonalizationOutcomeSurfaceSummary(surface: .chat, population: chat),
                PersonalizationOutcomeSurfaceSummary(surface: .unknown, population: unknown),
            ]
        )
    }
}
