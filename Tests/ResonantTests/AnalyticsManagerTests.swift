import Defaults
import XCTest
@testable import Resonant

@MainActor
final class AnalyticsManagerTests: XCTestCase {

    private var attributionSnapshot: MarketingAttributionDefaults!

    override func setUp() {
        super.setUp()
        attributionSnapshot = MarketingAttributionDefaults()
        clearMarketingAttributionDefaults()
    }

    override func tearDown() {
        attributionSnapshot.restore()
        attributionSnapshot = nil
        super.tearDown()
    }

    func testCaptureMarketingAttributionMapsStandardUTMParamsToInitialAndLatestProperties() throws {
        let url = try XCTUnwrap(URL(string: "resonantmac://auth/complete?utm_source=resonant_email_signature&utm_medium=email&utm_campaign=sent_with_resonant&utm_content=footer_link"))

        XCTAssertTrue(AnalyticsManager.shared.captureMarketingAttribution(from: url, source: "test"))
        XCTAssertEqual(Defaults[.marketingInitialUTMSource], "resonant_email_signature")
        XCTAssertEqual(Defaults[.marketingLatestUTMSource], "resonant_email_signature")
        XCTAssertEqual(Defaults[.marketingInitialUTMMedium], "email")
        XCTAssertEqual(Defaults[.marketingLatestUTMMedium], "email")
        XCTAssertEqual(Defaults[.marketingInitialUTMCampaign], "sent_with_resonant")
        XCTAssertEqual(Defaults[.marketingLatestUTMCampaign], "sent_with_resonant")
        XCTAssertEqual(Defaults[.marketingInitialUTMContent], "footer_link")
        XCTAssertEqual(Defaults[.marketingLatestUTMContent], "footer_link")
        XCTAssertEqual(Defaults[.marketingInitialLandingPath], "/complete")
        XCTAssertEqual(Defaults[.marketingLatestLandingPath], "/complete")
    }

    func testCaptureMarketingAttributionDoesNotOverwriteExistingInitialUTMFromStandardParams() throws {
        Defaults[.marketingInitialUTMSource] = "original_source"

        let url = try XCTUnwrap(URL(string: "resonantmac://auth/complete?utm_source=resonant_email_signature"))

        XCTAssertTrue(AnalyticsManager.shared.captureMarketingAttribution(from: url, source: "test"))
        XCTAssertEqual(Defaults[.marketingInitialUTMSource], "original_source")
        XCTAssertEqual(Defaults[.marketingLatestUTMSource], "resonant_email_signature")
    }

    func testVocabularyAttemptTelemetryBuildsTwoUnitEventsInsteadOfCumulativeSnapshots() {
        let skipped = VocabularyBoostAttemptTelemetry.properties(
            for: .skipped(.unsupportedAdapter)
        )
        let attempted = VocabularyBoostAttemptTelemetry.properties(
            for: .attempted(result: .applied, language: .explicitEnglish)
        )

        XCTAssertEqual(skipped["schema_version"] as? Int, 1)
        XCTAssertEqual(skipped["pipeline_name"] as? String, "vocabulary_boost_attempt")
        XCTAssertEqual(skipped["attempt_total_count"] as? Int, 1)
        XCTAssertEqual(skipped["skip_unsupported_adapter_count"] as? Int, 1)
        XCTAssertNil(skipped["attempt_explicit_english_applied_count"])

        XCTAssertEqual(attempted["attempt_total_count"] as? Int, 1)
        XCTAssertEqual(attempted["attempt_explicit_english_applied_count"] as? Int, 1)
        XCTAssertNil(attempted["skip_unsupported_adapter_count"])
        XCTAssertEqual(
            (skipped["attempt_total_count"] as? Int ?? 0)
                + (attempted["attempt_total_count"] as? Int ?? 0),
            2
        )
        XCTAssertEqual(Set(skipped.keys).count, 4)
        XCTAssertEqual(Set(attempted.keys).count, 4)

        for properties in [skipped, attempted] {
            XCTAssertTrue(Set(properties.keys).isSubset(of: VocabularyBoostAttemptTelemetry.metricPropertyKeys))
            XCTAssertFalse(properties.keys.contains { key in
                key.contains("term") || key.contains("text") || key.contains("error")
            })
        }
    }

    private func clearMarketingAttributionDefaults() {
        Defaults[.marketingAttributionId] = nil
        Defaults[.marketingInitialUTMSource] = nil
        Defaults[.marketingInitialUTMMedium] = nil
        Defaults[.marketingInitialUTMCampaign] = nil
        Defaults[.marketingInitialUTMContent] = nil
        Defaults[.marketingInitialUTMTerm] = nil
        Defaults[.marketingInitialUTMId] = nil
        Defaults[.marketingInitialSourceLink] = nil
        Defaults[.marketingInitialLandingPath] = nil
        Defaults[.marketingInitialReferrer] = nil
        Defaults[.marketingLatestUTMSource] = nil
        Defaults[.marketingLatestUTMMedium] = nil
        Defaults[.marketingLatestUTMCampaign] = nil
        Defaults[.marketingLatestUTMContent] = nil
        Defaults[.marketingLatestUTMTerm] = nil
        Defaults[.marketingLatestUTMId] = nil
        Defaults[.marketingLatestSourceLink] = nil
        Defaults[.marketingLatestLandingPath] = nil
        Defaults[.marketingLatestReferrer] = nil
    }

    private struct MarketingAttributionDefaults {
        let attributionId = Defaults[.marketingAttributionId]
        let initialUTMSource = Defaults[.marketingInitialUTMSource]
        let initialUTMMedium = Defaults[.marketingInitialUTMMedium]
        let initialUTMCampaign = Defaults[.marketingInitialUTMCampaign]
        let initialUTMContent = Defaults[.marketingInitialUTMContent]
        let initialUTMTerm = Defaults[.marketingInitialUTMTerm]
        let initialUTMId = Defaults[.marketingInitialUTMId]
        let initialSourceLink = Defaults[.marketingInitialSourceLink]
        let initialLandingPath = Defaults[.marketingInitialLandingPath]
        let initialReferrer = Defaults[.marketingInitialReferrer]
        let latestUTMSource = Defaults[.marketingLatestUTMSource]
        let latestUTMMedium = Defaults[.marketingLatestUTMMedium]
        let latestUTMCampaign = Defaults[.marketingLatestUTMCampaign]
        let latestUTMContent = Defaults[.marketingLatestUTMContent]
        let latestUTMTerm = Defaults[.marketingLatestUTMTerm]
        let latestUTMId = Defaults[.marketingLatestUTMId]
        let latestSourceLink = Defaults[.marketingLatestSourceLink]
        let latestLandingPath = Defaults[.marketingLatestLandingPath]
        let latestReferrer = Defaults[.marketingLatestReferrer]

        func restore() {
            Defaults[.marketingAttributionId] = attributionId
            Defaults[.marketingInitialUTMSource] = initialUTMSource
            Defaults[.marketingInitialUTMMedium] = initialUTMMedium
            Defaults[.marketingInitialUTMCampaign] = initialUTMCampaign
            Defaults[.marketingInitialUTMContent] = initialUTMContent
            Defaults[.marketingInitialUTMTerm] = initialUTMTerm
            Defaults[.marketingInitialUTMId] = initialUTMId
            Defaults[.marketingInitialSourceLink] = initialSourceLink
            Defaults[.marketingInitialLandingPath] = initialLandingPath
            Defaults[.marketingInitialReferrer] = initialReferrer
            Defaults[.marketingLatestUTMSource] = latestUTMSource
            Defaults[.marketingLatestUTMMedium] = latestUTMMedium
            Defaults[.marketingLatestUTMCampaign] = latestUTMCampaign
            Defaults[.marketingLatestUTMContent] = latestUTMContent
            Defaults[.marketingLatestUTMTerm] = latestUTMTerm
            Defaults[.marketingLatestUTMId] = latestUTMId
            Defaults[.marketingLatestSourceLink] = latestSourceLink
            Defaults[.marketingLatestLandingPath] = latestLandingPath
            Defaults[.marketingLatestReferrer] = latestReferrer
        }
    }
}
