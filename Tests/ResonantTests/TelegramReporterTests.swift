import Foundation
import XCTest
@testable import Resonant

@MainActor
final class TelegramReporterTests: XCTestCase {

    override func tearDown() {
        TelegramReporterURLProtocol.reset()
        super.tearDown()
    }

    func testSendBugReportRetriesTransientHTTPFailure() async {
        TelegramReporterURLProtocol.enqueue(statusCode: 500, body: #"{"status":"error","errorMessage":"temporary"}"#)
        TelegramReporterURLProtocol.enqueue(statusCode: 200, body: #"{"status":"success","value":{}}"#)

        let reporter = makeReporter(retryDelays: [.milliseconds(0)])
        let result = await reporter.sendBugReport(
            severity: "should-fix",
            description: "The app did something unexpected.",
            reportID: "report-123"
        )

        XCTAssertTrue(result.delivered)
        XCTAssertEqual(result.attempts, 2)
        XCTAssertEqual(result.route, "legacy_support_action")
        XCTAssertEqual(TelegramReporterURLProtocol.requests.count, 2)
    }

    func testSendBugReportFallsBackToFeedbackMutationWhenLegacyActionIsUnavailable() async throws {
        TelegramReporterURLProtocol.enqueue(statusCode: 404, body: #"{"errorMessage":"Could not find public function support:submitBugReport"}"#)
        TelegramReporterURLProtocol.enqueue(statusCode: 200, body: #"{"status":"success","value":{}}"#)

        let reporter = makeReporter(retryDelays: [])
        let result = await reporter.sendBugReport(
            severity: "cant-work",
            description: "Support relay unavailable.",
            reportID: "report-fallback"
        )

        XCTAssertTrue(result.delivered)
        XCTAssertEqual(result.attempts, 2)
        XCTAssertEqual(result.route, "feedback_mutation")
        XCTAssertEqual(TelegramReporterURLProtocol.requests.map(\.url?.path), ["/api/action", "/api/mutation"])

        let primaryBody = try XCTUnwrap(TelegramReporterURLProtocol.requestBodies.first ?? nil)
        let primaryPayload = try XCTUnwrap(JSONSerialization.jsonObject(with: primaryBody) as? [String: Any])
        XCTAssertEqual(primaryPayload["path"] as? String, "support:submitBugReport")

        let fallbackBody = try XCTUnwrap(TelegramReporterURLProtocol.requestBodies.last ?? nil)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: fallbackBody) as? [String: Any])
        let args = try XCTUnwrap(payload["args"] as? [String: Any])
        XCTAssertEqual(payload["path"] as? String, "feedback:submit")
        XCTAssertTrue((args["description"] as? String)?.contains("Report: report-fallback") == true)
    }

    func testSendBugReportReturnsHTTPFailureMetadata() async {
        TelegramReporterURLProtocol.enqueue(statusCode: 400, body: #"{"errorMessage":"legacy bad request"}"#)
        TelegramReporterURLProtocol.enqueue(statusCode: 400, body: #"{"errorMessage":"feedback bad request"}"#)

        let reporter = makeReporter(retryDelays: [])
        let result = await reporter.sendBugReport(
            severity: "cant-work",
            description: "Broken.",
            reportID: "report-456"
        )

        XCTAssertFalse(result.delivered)
        XCTAssertEqual(result.failureReason, .httpStatus)
        XCTAssertEqual(result.statusCode, 400)
        XCTAssertEqual(result.attempts, 2)
        XCTAssertEqual(result.message, "feedback bad request")
        XCTAssertNil(result.route)
        XCTAssertEqual(TelegramReporterURLProtocol.requests.map(\.url?.path), ["/api/action", "/api/mutation"])
    }

    func testSendBugReportIncludesStableReportID() async throws {
        TelegramReporterURLProtocol.enqueue(statusCode: 200, body: #"{"status":"success","value":{}}"#)

        let reporter = makeReporter(retryDelays: [])
        _ = await reporter.sendBugReport(
            severity: "annoying",
            description: "Small issue.",
            reportID: "report-789"
        )

        XCTAssertNotNil(TelegramReporterURLProtocol.requests.first)
        let body = try XCTUnwrap(TelegramReporterURLProtocol.requestBodies.first ?? nil)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let args = try XCTUnwrap(payload["args"] as? [String: Any])

        XCTAssertEqual(payload["path"] as? String, "support:submitBugReport")
        XCTAssertTrue((args["description"] as? String)?.contains("Report: report-789") == true)
    }

    private func makeReporter(retryDelays: [Duration]) -> TelegramReporter {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TelegramReporterURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return TelegramReporter(
            baseURL: URL(string: "https://example.convex.cloud")!,
            session: session,
            retryDelays: retryDelays
        )
    }
}

private final class TelegramReporterURLProtocol: URLProtocol {
    struct Response {
        let statusCode: Int
        let body: Data
    }

    static var responses: [Response] = []
    static var requests: [URLRequest] = []
    static var requestBodies: [Data?] = []

    static func enqueue(statusCode: Int, body: String) {
        responses.append(Response(statusCode: statusCode, body: Data(body.utf8)))
    }

    static func reset() {
        responses = []
        requests = []
        requestBodies = []
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requests.append(request)
        Self.requestBodies.append(request.httpBody ?? request.httpBodyStream?.readData())

        guard !Self.responses.isEmpty else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        let response = Self.responses.removeFirst()
        let httpResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: response.statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!

        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension InputStream {
    func readData() -> Data {
        open()
        defer { close() }

        var data = Data()
        let bufferSize = 1_024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while hasBytesAvailable {
            let count = read(buffer, maxLength: bufferSize)
            if count > 0 {
                data.append(buffer, count: count)
            } else {
                break
            }
        }

        return data
    }
}
