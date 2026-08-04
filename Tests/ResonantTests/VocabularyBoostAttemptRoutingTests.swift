import XCTest
@testable import Resonant

final class VocabularyBoostAttemptRoutingTests: XCTestCase {
    func testUnsupportedAdapterAndDiskBackedLongFormReportSkipReasons() {
        XCTAssertEqual(
            VocabularyBoostAttemptRouter.unsupportedAdapterOutcome(enabled: true),
            .skipped(.unsupportedAdapter)
        )
        XCTAssertEqual(
            VocabularyBoostAttemptRouter.unsupportedAdapterOutcome(enabled: false),
            .skipped(.disabled)
        )

        let configuration = VocabularyBoostEngineRuntimeConfiguration(
            enabled: true,
            lowLatencyMode: false
        )
        XCTAssertEqual(
            VocabularyBoostAttemptRouter.diskBackedOutcome(
                configuration: configuration,
                selectedLanguage: "en",
                eligibleTermCount: 1,
                helperModelDownloaded: true
            ),
            .skipped(.diskBackedLongForm)
        )
    }

    func testDiskBackedRouteUsesTheSameTypedPreflightPolicy() {
        let enabled = VocabularyBoostEngineRuntimeConfiguration(
            enabled: true,
            lowLatencyMode: false
        )
        XCTAssertEqual(
            VocabularyBoostAttemptRouter.diskBackedOutcome(
                configuration: .init(enabled: false, lowLatencyMode: false),
                selectedLanguage: "en",
                eligibleTermCount: 1,
                helperModelDownloaded: true
            ),
            .skipped(.disabled)
        )
        XCTAssertEqual(
            VocabularyBoostAttemptRouter.diskBackedOutcome(
                configuration: .init(enabled: true, lowLatencyMode: true),
                selectedLanguage: "en",
                eligibleTermCount: 1,
                helperModelDownloaded: true
            ),
            .skipped(.lowLatencyMode)
        )
        XCTAssertEqual(
            VocabularyBoostAttemptRouter.diskBackedOutcome(
                configuration: enabled,
                selectedLanguage: "de",
                eligibleTermCount: 1,
                helperModelDownloaded: true
            ),
            .skipped(.unsupportedLanguage)
        )
        XCTAssertEqual(
            VocabularyBoostAttemptRouter.diskBackedOutcome(
                configuration: enabled,
                selectedLanguage: "en",
                eligibleTermCount: 0,
                helperModelDownloaded: true
            ),
            .skipped(.noEligibleTerms)
        )
        XCTAssertEqual(
            VocabularyBoostAttemptRouter.diskBackedOutcome(
                configuration: enabled,
                selectedLanguage: "en",
                eligibleTermCount: 1,
                helperModelDownloaded: false
            ),
            .skipped(.modelUnavailable)
        )
    }

    func testRecorderAggregatesOnlyTypedCappedCounts() async {
        let recorder = VocabularyBoostAttemptRecorder()
        for _ in 0..<(VocabularyBoostAttemptCounts.maximumCountPerOutcome + 2) {
            await recorder.record(.skipped(.unsupportedAdapter))
        }
        await recorder.record(.attempted(result: .processingFailure, language: .explicitEnglish))
        await recorder.record(.attempted(result: .applied, language: .automaticConditional))

        let snapshot = await recorder.snapshot()
        XCTAssertEqual(
            snapshot.count(for: .skipped(.unsupportedAdapter)),
            VocabularyBoostAttemptCounts.maximumCountPerOutcome
        )
        XCTAssertEqual(
            snapshot.count(for: .attempted(
                result: .processingFailure,
                language: .explicitEnglish
            )),
            1
        )
        XCTAssertEqual(
            snapshot.count(for: .attempted(
                result: .applied,
                language: .automaticConditional
            )),
            1
        )
    }

    func testRecorderOutcomeHookEmitsEachCurrentOutcomeExactlyOnceInOrder() async {
        let spy = VocabularyBoostOutcomeSpy()
        let recorder = VocabularyBoostAttemptRecorder(onOutcome: { outcome in
            await spy.record(outcome)
        })
        let first = VocabularyBoostAttemptOutcome.skipped(.unsupportedAdapter)
        let second = VocabularyBoostAttemptOutcome.attempted(
            result: .applied,
            language: .automaticConditional
        )

        await recorder.record(first)
        await recorder.record(second)

        let emitted = await spy.outcomes()
        XCTAssertEqual(emitted, [first, second])

        // Cumulative counts remain available locally, but the hook above saw
        // the two current outcomes rather than cumulative snapshots 1 then 2.
        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.total, 2)
        XCTAssertEqual(snapshot.count(for: .skipped(.unsupportedAdapter)), 1)
        XCTAssertEqual(
            snapshot.count(for: .attempted(
                result: .applied,
                language: .automaticConditional
            )),
            1
        )
    }
}

private actor VocabularyBoostOutcomeSpy {
    private var recorded: [VocabularyBoostAttemptOutcome] = []

    func record(_ outcome: VocabularyBoostAttemptOutcome) {
        recorded.append(outcome)
    }

    func outcomes() -> [VocabularyBoostAttemptOutcome] {
        recorded
    }
}
