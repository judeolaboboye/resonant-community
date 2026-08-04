import XCTest
@testable import Resonant

final class VocabularyBoostRuntimeStateTests: XCTestCase {
    func testApplicabilityMatrixIsIndependentFromHelperLifecycle() {
        struct Scenario {
            let name: String
            var enabled = true
            var liveAdapterSupportsBoosting = true
            var lowLatencyMode = false
            var selectedLanguage: String? = "en"
            var eligibleTermCount = 1
            let expected: VocabularyBoostApplicabilityState
        }

        let scenarios = [
            Scenario(name: "off", enabled: false, expected: .off),
            Scenario(
                name: "unsupported live model",
                liveAdapterSupportsBoosting: false,
                expected: .unsupportedModel
            ),
            Scenario(name: "low latency", lowLatencyMode: true, expected: .lowLatencyPaused),
            Scenario(
                name: "explicit non-English",
                selectedLanguage: "de",
                expected: .unsupportedLanguage
            ),
            Scenario(name: "no terms", eligibleTermCount: 0, expected: .noEligibleTerms),
            Scenario(
                name: "Auto conditional",
                selectedLanguage: "auto",
                expected: .automaticConditional
            ),
            Scenario(name: "explicit English", expected: .eligible),
        ]

        let helperStates: [VocabularyBoostHelperDownloadState] = [
            .absent,
            .downloading,
            .ready,
            .failed(.network),
        ]
        for scenario in scenarios {
            for helper in helperStates {
                let state = VocabularyBoostRuntimeState.resolve(
                    enabled: scenario.enabled,
                    liveAdapterSupportsBoosting: scenario.liveAdapterSupportsBoosting,
                    lowLatencyMode: scenario.lowLatencyMode,
                    selectedLanguage: scenario.selectedLanguage,
                    eligibleTermCount: scenario.eligibleTermCount,
                    helperDownloadState: helper
                )
                XCTAssertEqual(state.applicability, scenario.expected, scenario.name)
                XCTAssertEqual(state.helper, helper, scenario.name)
            }
        }
    }

    func testDownloadingAndFailureStayVisibleAcrossEveryInapplicableState() {
        let applicabilityScenarios: [(
            name: String,
            adapter: Bool,
            lowLatency: Bool,
            language: String?,
            terms: Int,
            expected: VocabularyBoostApplicabilityState
        )] = [
            ("no terms", true, false, "en", 0, .noEligibleTerms),
            ("unsupported adapter", false, false, "en", 1, .unsupportedModel),
            ("low latency", true, true, "en", 1, .lowLatencyPaused),
            ("non-English", true, false, "fr", 1, .unsupportedLanguage),
        ]

        for scenario in applicabilityScenarios {
            let downloading = VocabularyBoostRuntimeState.resolve(
                enabled: true,
                liveAdapterSupportsBoosting: scenario.adapter,
                lowLatencyMode: scenario.lowLatency,
                selectedLanguage: scenario.language,
                eligibleTermCount: scenario.terms,
                helperDownloadState: .downloading
            )
            XCTAssertEqual(downloading.applicability, scenario.expected, scenario.name)
            XCTAssertEqual(downloading.helper.title, "Downloading 98 MB", scenario.name)
            XCTAssertTrue(
                downloading.detail(eligibleTermCount: scenario.terms).contains("Downloading the 98 MB"),
                scenario.name
            )

            for failure in VocabularyBoostHelperFailureCategory.allCases {
                let failed = VocabularyBoostRuntimeState.resolve(
                    enabled: true,
                    liveAdapterSupportsBoosting: scenario.adapter,
                    lowLatencyMode: scenario.lowLatency,
                    selectedLanguage: scenario.language,
                    eligibleTermCount: scenario.terms,
                    helperDownloadState: .failed(failure)
                )
                XCTAssertEqual(failed.applicability, scenario.expected, scenario.name)
                XCTAssertEqual(failed.helper.title, "Download failed", scenario.name)
                XCTAssertEqual(failed.helper.recoveryAction, .retry, scenario.name)
                XCTAssertTrue(
                    failed.detail(eligibleTermCount: scenario.terms)
                        .localizedCaseInsensitiveContains("retry"),
                    scenario.name
                )
            }
        }
    }

    func testAbsentHelperAlwaysOffersVisible98MBManualDownload() {
        let off = VocabularyBoostRuntimeState.resolve(
            enabled: false,
            liveAdapterSupportsBoosting: false,
            lowLatencyMode: true,
            selectedLanguage: "de",
            eligibleTermCount: 0,
            helperDownloadState: .absent
        )

        XCTAssertEqual(off.applicability, .off)
        XCTAssertEqual(off.helper.recoveryAction, .download)
        XCTAssertTrue(off.helper.detail.contains("98 MB"))
        XCTAssertTrue(off.helper.detail.contains("Choose Download"))
    }

    // Removed: testUsesLiveActiveAdapterNotStaleSavedSelection. Its
    // `staleSavedSelectionSupportsBoosting` parameter was unused (`_:`), so
    // what remained duplicated the "unsupported live model" and "explicit
    // English" scenarios already covered by
    // testApplicabilityMatrixIsIndependentFromHelperLifecycle. `resolve` reads
    // only the live adapter flag, so no stale-selection path exists to test.

    func testAutoLanguageConditionalButExplicitNonEnglishUnsupported() {
        let autoSelections: [String?] = [nil, "", "auto", " AUTO "]
        for selection in autoSelections {
            XCTAssertEqual(
                VocabularyBoostRuntimeState.resolve(
                    enabled: true,
                    liveAdapterSupportsBoosting: true,
                    lowLatencyMode: false,
                    selectedLanguage: selection,
                    eligibleTermCount: 1,
                    helperDownloadState: .ready
                ).applicability,
                .automaticConditional
            )
        }

        XCTAssertEqual(
            VocabularyBoostRuntimeState.resolve(
                enabled: true,
                liveAdapterSupportsBoosting: true,
                lowLatencyMode: false,
                selectedLanguage: "fr",
                eligibleTermCount: 1,
                helperDownloadState: .ready
            ).applicability,
            .unsupportedLanguage
        )
    }

    func testAutoDetailUsesTheRuntimeLanguageGateContract() {
        let detail = VocabularyBoostApplicabilityState.automaticConditional.detail(
            eligibleTermCount: 1
        )

        XCTAssertTrue(detail.contains("local check"))
        XCTAssertTrue(detail.contains("confidently identifies"))
        XCTAssertTrue(detail.contains("Non-English, uncertain"))
        XCTAssertFalse(detail.contains("May be used when Auto detects English"))
        XCTAssertFalse(detail.localizedCaseInsensitiveContains("acoustic similarity"))
    }

    func testOnlyEligibleAndAutoConditionalAllowAutomaticDownload() {
        let cases: [(VocabularyBoostApplicabilityState, Bool)] = [
            (.off, false),
            (.unsupportedModel, false),
            (.lowLatencyPaused, false),
            (.automaticConditional, true),
            (.unsupportedLanguage, false),
            (.noEligibleTerms, false),
            (.eligible, true),
        ]

        for (state, expected) in cases {
            XCTAssertEqual(state.allowsAutomaticHelperDownload, expected)
        }
    }

    // Removed: testContextHoldoutDoesNotDisableVocabularyBoost. Its holdout
    // parameter was unused (`_:`), so both branches called `resolve` with
    // identical arguments and it could not fail. `resolve` takes no
    // context-personalization input, so the compiler already enforces the
    // invariant the test claimed to prove.
}
