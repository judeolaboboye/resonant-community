import XCTest
@testable import Resonant

final class AnalyticsRuntimeConfigurationTests: XCTestCase {

    func testConfigurationRequiresNonEmptyAPIKey() {
        XCTAssertNil(AnalyticsRuntimeConfiguration.from(infoDictionary: nil))
        XCTAssertNil(AnalyticsRuntimeConfiguration.from(infoDictionary: [
            AnalyticsRuntimeConfiguration.apiKeyInfoKey: "   "
        ]))
    }

    func testConfigurationTrimsValuesAndDefaultsHost() {
        let configuration = AnalyticsRuntimeConfiguration.from(infoDictionary: [
            AnalyticsRuntimeConfiguration.apiKeyInfoKey: " phc_exampleProjectKey "
        ])

        XCTAssertEqual(configuration, AnalyticsRuntimeConfiguration(
            apiKey: "phc_exampleProjectKey",
            host: AnalyticsRuntimeConfiguration.defaultHost
        ))
    }

    func testConfigurationHonorsCustomHost() {
        let configuration = AnalyticsRuntimeConfiguration.from(infoDictionary: [
            AnalyticsRuntimeConfiguration.apiKeyInfoKey: "phc_exampleProjectKey",
            AnalyticsRuntimeConfiguration.hostInfoKey: " https://us.i.posthog.com "
        ])

        XCTAssertEqual(configuration?.host, "https://us.i.posthog.com")
    }
}
