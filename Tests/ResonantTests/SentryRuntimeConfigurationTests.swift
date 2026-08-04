import XCTest
@testable import Resonant

final class SentryRuntimeConfigurationTests: XCTestCase {

    func testConfigurationRequiresNonEmptyDSN() {
        XCTAssertNil(SentryRuntimeConfiguration.from(infoDictionary: nil))
        XCTAssertNil(SentryRuntimeConfiguration.from(infoDictionary: [
            SentryRuntimeConfiguration.dsnInfoKey: "   "
        ]))
    }

    func testConfigurationTrimsValuesAndKeepsProject() {
        let configuration = SentryRuntimeConfiguration.from(infoDictionary: [
            SentryRuntimeConfiguration.dsnInfoKey: " https://examplePublicKey@o0.ingest.sentry.io/0 ",
            SentryRuntimeConfiguration.projectInfoKey: " apple-ios "
        ])

        XCTAssertEqual(configuration, SentryRuntimeConfiguration(
            dsn: "https://examplePublicKey@o0.ingest.sentry.io/0",
            project: "apple-ios"
        ))
    }
}
