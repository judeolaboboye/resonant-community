import XCTest
import Sentry
@testable import Resonant

final class SentryDiagnosticsSanitizerTests: XCTestCase {

    func testScrubEventRedactsSensitiveExceptionValues() {
        let event = Event(level: .error)
        event.exceptions = [
            Exception(value: "Transcript: this is a long dictated passage from the user", type: "ConvexError")
        ]

        SentryDiagnosticsSanitizer.scrubEvent(event)

        XCTAssertEqual(event.exceptions?.first?.value, "Transcript: [Redacted]")
    }

    func testScrubEventRedactsSensitiveBreadcrumbPayloads() throws {
        let event = Event(level: .error)
        let crumb = Breadcrumb(level: .error, category: "cloud")
        crumb.data = [
            "error": "The backend rejected \"this is definitely sensitive dictated content from the user\".",
            "selected_text": "draft reply"
        ]
        event.breadcrumbs = [crumb]

        SentryDiagnosticsSanitizer.scrubEvent(event)

        let scrubbedData = try XCTUnwrap(event.breadcrumbs?.first?.data)
        XCTAssertEqual(scrubbedData["error"] as? String, "[Redacted]")
        XCTAssertEqual(scrubbedData["selected_text"] as? String, "[Redacted]")
    }

    func testErrorContextUsesStructuredMetadataOnly() {
        struct SensitiveError: LocalizedError {
            var errorDescription: String? { "Transcript: private dictated content" }
        }

        let context = SentryDiagnosticsSanitizer.errorContext(for: SensitiveError())

        XCTAssertNil(context["error"])
        XCTAssertNil(context["error_reason"])
        XCTAssertEqual(context["error_code"] as? Int, 1)
        XCTAssertTrue((context["error_type"] as? String)?.contains("SensitiveError") == true)
    }

    func testShouldIgnoreDropsKnownOperationalAudioNoise() {
        let event = Event(level: .error)
        event.exceptions = [
            Exception(value: "AudioRecorderError.finishFailed(\"Cannot Record\")", type: "AudioRecorderError")
        ]

        XCTAssertTrue(SentryDiagnosticsSanitizer.shouldIgnore(event))
    }

    func testCapturedDictationBoundaryDropsModelReadinessErrors() {
        XCTAssertTrue(
            SentryDiagnosticsSanitizer.shouldDropCapturedException(
                TranscriberError.notLoaded,
                context: ["source": "AppState.endDictation"]
            )
        )
    }

    func testCapturedLaunchPreparationKeepsModelReadinessErrors() {
        XCTAssertFalse(
            SentryDiagnosticsSanitizer.shouldDropCapturedException(
                TranscriberError.notLoaded,
                context: ["source": "AppState.launch.prepareActive"]
            )
        )
    }
}
