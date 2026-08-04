import XCTest
@testable import Resonant

final class AppEnvironmentTests: XCTestCase {

    func testDistributionDefaultsToCommunityIndependentlyOfAppEnvironment() {
        XCTAssertEqual(
            AppDistribution.resolve(processEnvironment: [:], infoDictionary: nil),
            .community
        )
        XCTAssertEqual(
            AppDistribution.resolve(
                processEnvironment: [:],
                infoDictionary: [AppEnvironment.InfoDictionaryKey.environment: "production"]
            ),
            .community
        )
    }

    func testDistributionPrefersProcessOverride() {
        XCTAssertEqual(
            AppDistribution.resolve(
                processEnvironment: [AppDistribution.ProcessEnvironmentKey.distribution: "official"],
                infoDictionary: [AppDistribution.InfoDictionaryKey.distribution: "community"]
            ),
            .official
        )
    }

    func testCommunityIdentityIsDerivedFromBundleAndSeparatedByStore() {
        XCTAssertEqual(
            AppDistribution.community.defaultsSuiteName(
                environment: .production,
                bundleIdentifier: "dev.example.resonant"
            ),
            "dev.example.resonant.defaults"
        )
        XCTAssertEqual(
            AppDistribution.community.keychainServiceName(
                environment: .production,
                bundleIdentifier: "dev.example.resonant"
            ),
            "dev.example.resonant.keychain"
        )
    }

    func testCommunityIdentityRejectsMalformedBundleIdentifier() {
        XCTAssertEqual(
            AppDistribution.community.defaultsSuiteName(
                environment: .production,
                bundleIdentifier: "../../com.resonance.resonant"
            ),
            "org.resonant.community.defaults"
        )
    }

    func testCanonicalOfficialIdentityPreservesExistingStorageNames() {
        XCTAssertEqual(
            AppDistribution.official.defaultsSuiteName(
                environment: .production,
                bundleIdentifier: "com.resonance.resonant"
            ),
            "com.resonance.resonant"
        )
        XCTAssertEqual(
            AppDistribution.official.keychainServiceName(
                environment: .development,
                bundleIdentifier: "com.resonance.resonant.dev"
            ),
            "com.resonance.resonant.dev"
        )
    }

    func testDownstreamOfficialIdentityDoesNotReuseOfficialStorage() {
        XCTAssertEqual(
            AppDistribution.official.defaultsSuiteName(
                environment: .production,
                bundleIdentifier: "com.example.resonant"
            ),
            "com.example.resonant.defaults"
        )
        XCTAssertEqual(
            AppDistribution.official.keychainServiceName(
                environment: .production,
                bundleIdentifier: "com.example.resonant"
            ),
            "com.example.resonant.keychain"
        )
    }

    func testLocalIntegrationIdentitySeparatesEditionEnvironmentAndForks() {
        XCTAssertEqual(
            AppDistribution.official.localIdentitySlug(
                environment: .production,
                bundleIdentifier: "com.resonance.resonant"
            ),
            "resonant"
        )
        XCTAssertEqual(
            AppDistribution.community.localIdentitySlug(
                environment: .development,
                bundleIdentifier: "org.resonant.community.dev"
            ),
            "resonant-community-dev"
        )
        XCTAssertEqual(
            AppDistribution.community.localIdentitySlug(
                environment: .production,
                bundleIdentifier: "dev.example.My-Fork"
            ),
            "resonant-dev-example-my-fork"
        )
        XCTAssertEqual(
            AppDistribution.community.applicationSupportDirectoryName(
                environment: .production,
                bundleIdentifier: "dev.example.My-Fork"
            ),
            "Resonant resonant-dev-example-my-fork"
        )
    }

    func testResolvePrefersProcessEnvironmentOverride() {
        let environment = AppEnvironment.resolve(
            processEnvironment: [AppEnvironment.ProcessEnvironmentKey.environment: "dev"],
            infoDictionary: [AppEnvironment.InfoDictionaryKey.environment: "production"]
        )

        XCTAssertEqual(environment, .development)
    }

    func testResolveFallsBackToInfoDictionaryValue() {
        let environment = AppEnvironment.resolve(
            processEnvironment: [:],
            infoDictionary: [AppEnvironment.InfoDictionaryKey.environment: "production"]
        )

        XCTAssertEqual(environment, .production)
    }

    func testUnconfiguredHostedServicesFailClosed() throws {
        XCTAssertNil(try AppEnvironment.resolveHostedServicesConfiguration(
            processEnvironment: [:],
            infoDictionary: nil
        ))
        XCTAssertEqual(
            AppEnvironment.production.convexCloudURL(
                processEnvironment: [:],
                infoDictionary: nil
            ),
            AppEnvironment.unavailableConvexCloudURL
        )
        XCTAssertEqual(
            AppEnvironment.production.authBaseURL(
                processEnvironment: [:],
                infoDictionary: nil
            ),
            AppEnvironment.unavailableAuthBaseURL
        )
    }

    func testHostedServicesRequireCompleteProcessOverride() {
        XCTAssertThrowsError(try AppEnvironment.resolveHostedServicesConfiguration(
            processEnvironment: [
                AppEnvironment.ProcessEnvironmentKey.convexCloudURL: "https://example.convex.cloud"
            ],
            infoDictionary: [
                AppEnvironment.InfoDictionaryKey.authBaseURL: "https://auth.example.com"
            ]
        )) { error in
            XCTAssertEqual(error as? HostedServicesConfigurationError, .incomplete)
        }
    }

    func testHostedServicesRequireHTTPURLs() {
        XCTAssertThrowsError(try AppEnvironment.resolveHostedServicesConfiguration(
            processEnvironment: [
                AppEnvironment.ProcessEnvironmentKey.convexCloudURL: "file:///tmp/cloud",
                AppEnvironment.ProcessEnvironmentKey.authBaseURL: "https://auth.example.com"
            ],
            infoDictionary: nil
        )) { error in
            XCTAssertEqual(error as? HostedServicesConfigurationError, .invalidConvexCloudURL)
        }
    }

    func testRemotePlainHTTPHostedServicesAreRejected() {
        XCTAssertThrowsError(try AppEnvironment.resolveHostedServicesConfiguration(
            processEnvironment: [
                AppEnvironment.ProcessEnvironmentKey.environment: "development",
                AppEnvironment.ProcessEnvironmentKey.convexCloudURL: "http://api.example.com",
                AppEnvironment.ProcessEnvironmentKey.authBaseURL: "http://auth.example.com"
            ],
            infoDictionary: nil
        )) { error in
            XCTAssertEqual(error as? HostedServicesConfigurationError, .invalidConvexCloudURL)
        }
    }

    func testDevelopmentLoopbackHTTPHostedServicesAreAllowed() throws {
        let configuration = try XCTUnwrap(AppEnvironment.resolveHostedServicesConfiguration(
            processEnvironment: [
                AppEnvironment.ProcessEnvironmentKey.environment: "development",
                AppEnvironment.ProcessEnvironmentKey.convexCloudURL: "http://127.0.0.1:3210",
                AppEnvironment.ProcessEnvironmentKey.authBaseURL: "http://localhost:3211"
            ],
            infoDictionary: nil
        ))
        XCTAssertEqual(configuration.convexCloudURL.host, "127.0.0.1")
        XCTAssertEqual(configuration.authBaseURL.host, "localhost")
    }

    func testProductionLoopbackHTTPHostedServicesAreRejected() {
        XCTAssertThrowsError(try AppEnvironment.resolveHostedServicesConfiguration(
            processEnvironment: [
                AppEnvironment.ProcessEnvironmentKey.environment: "production",
                AppEnvironment.ProcessEnvironmentKey.convexCloudURL: "http://127.0.0.1:3210",
                AppEnvironment.ProcessEnvironmentKey.authBaseURL: "http://localhost:3211"
            ],
            infoDictionary: nil
        ))
    }

    func testCompleteURLOverridesWinOverBundleMetadata() throws {
        let configuration = try XCTUnwrap(AppEnvironment.resolveHostedServicesConfiguration(
            processEnvironment: [
                AppEnvironment.ProcessEnvironmentKey.convexCloudURL: "https://example.convex.cloud",
                AppEnvironment.ProcessEnvironmentKey.authBaseURL: "https://auth.example.com"
            ],
            infoDictionary: [
                AppEnvironment.InfoDictionaryKey.convexCloudURL: "https://ignored.convex.cloud",
                AppEnvironment.InfoDictionaryKey.authBaseURL: "https://ignored.example.com"
            ]
        ))

        XCTAssertEqual(configuration.convexCloudURL.absoluteString, "https://example.convex.cloud")
        XCTAssertEqual(configuration.authBaseURL.absoluteString, "https://auth.example.com")
    }
}
