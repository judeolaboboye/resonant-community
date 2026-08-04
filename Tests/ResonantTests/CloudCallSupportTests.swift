import XCTest
@testable import Resonant

final class CloudCallSupportTests: XCTestCase {

    // MARK: - CloudErrorClassifier

    func testDailyLimitDetection() {
        XCTAssertTrue(CloudErrorClassifier.isDailyLimit("ConvexError: DAILY_LIMIT_REACHED for user"))
        XCTAssertFalse(CloudErrorClassifier.isDailyLimit("ConvexError: weekly quota exceeded"))
    }

    func testFunctionNotFoundRequiresMatchingPath() {
        let error = "Could not find public function for 'cloudProcessing:processDictationCleanup'"

        XCTAssertTrue(
            CloudErrorClassifier.isFunctionNotFound(error, path: "cloudProcessing:processDictationCleanup")
        )
        XCTAssertFalse(
            CloudErrorClassifier.isFunctionNotFound(error, path: "cloudProcessing:processQualityRepair")
        )
        XCTAssertFalse(
            CloudErrorClassifier.isFunctionNotFound(
                "cloudProcessing:processDictationCleanup timed out",
                path: "cloudProcessing:processDictationCleanup"
            )
        )
    }

    func testExtraFieldValidationErrorMatchesQuotedVariants() {
        for quoted in ["`styleHint`", "'styleHint'", "\"styleHint\"", "styleHint"] {
            let error = "ArgumentValidationError: Object contains extra field \(quoted) that is not in the validator"
            XCTAssertTrue(
                CloudErrorClassifier.hasExtraFieldValidationError(error, fields: ["styleHint"]),
                "expected match for \(quoted)"
            )
        }

        XCTAssertFalse(
            CloudErrorClassifier.hasExtraFieldValidationError(
                "Server error: extra field `styleHint`",
                fields: ["styleHint"]
            ),
            "must require ArgumentValidationError marker"
        )
        XCTAssertFalse(
            CloudErrorClassifier.hasExtraFieldValidationError(
                "ArgumentValidationError: Object contains extra field `other`",
                fields: ["styleHint"]
            )
        )
    }

    func testCleanupFallbackCoversMissingEndpointAndContractDrift() {
        XCTAssertTrue(
            CloudErrorClassifier.canFallbackFromDedicatedCleanup(
                "Could not find public function for 'cloudProcessing:processDictationCleanup'"
            )
        )
        XCTAssertTrue(
            CloudErrorClassifier.canFallbackFromDedicatedCleanup(
                "ArgumentValidationError: Object contains extra field `recentTexts`"
            )
        )
        XCTAssertFalse(
            CloudErrorClassifier.canFallbackFromDedicatedCleanup("network timeout")
        )
    }

    func testQualityRepairFallbackCoversQualityIssuesField() {
        XCTAssertTrue(
            CloudErrorClassifier.canFallbackFromDedicatedQualityRepair(
                "ArgumentValidationError: Object contains extra field `qualityIssues`"
            )
        )
        XCTAssertFalse(
            CloudErrorClassifier.canFallbackFromDedicatedQualityRepair("DAILY_LIMIT_REACHED")
        )
    }

    // MARK: - CloudProcessingFailure

    func testClassifyMapsDailyLimitAndSessionExpiry() {
        XCTAssertEqual(
            CloudProcessingFailure.classify(ConvexError.serverError("DAILY_LIMIT_REACHED")),
            .dailyLimitReached
        )
        XCTAssertEqual(
            CloudProcessingFailure.classify(ConvexError.sessionExpired("expired")),
            .sessionExpired
        )
        XCTAssertEqual(
            CloudProcessingFailure.classify(CloudProcessingFailure.signInRequired),
            .signInRequired
        )
        if case .serverError = CloudProcessingFailure.classify(ConvexError.httpError("HTTP 500")) {
        } else {
            XCTFail("transport errors should classify as serverError")
        }
    }

    // MARK: - CloudUsageDay

    func testUsageDayKeyUsesLocalDayBoundary() {
        let calendar = Calendar(identifier: .gregorian)
        var components = calendar.dateComponents(in: .autoupdatingCurrent, from: Date())
        components.hour = 12
        components.minute = 0
        components.second = 0
        let noon = calendar.date(from: components)!

        let key = CloudUsageDay.key(for: noon)
        XCTAssertNotNil(key.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression))
        XCTAssertEqual(
            key,
            String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
        )
    }

    // MARK: - CloudTimeouts

    func testRouteSpecificTimeouts() {
        XCTAssertEqual(CloudTimeouts.selectionTransform(for: .quick), CloudTimeouts.selectionTransformQuickMs)
        XCTAssertEqual(CloudTimeouts.selectionTransform(for: .advanced), CloudTimeouts.selectionTransformAdvancedMs)
        XCTAssertEqual(CloudTimeouts.memo(for: nil), CloudTimeouts.memoMs)
        XCTAssertEqual(CloudTimeouts.memo(for: .meetingSummary), CloudTimeouts.memoMeetingSummaryMs)
        XCTAssertEqual(CloudTimeouts.memo(for: .selectionTransformAdvanced), CloudTimeouts.memoSelectionTransformAdvancedMs)
    }
}
