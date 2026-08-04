import Defaults
import Foundation

extension Defaults.Keys {
    static let analyticsInstallDate = Key<String?>("analyticsInstallDate", default: nil, suite: AppDefaults.suite)
    static let analyticsLaunchCount = Key<Int>("analyticsLaunchCount", default: 0, suite: AppDefaults.suite)
    static let analyticsLastActiveDate = Key<String?>("analyticsLastActiveDate", default: nil, suite: AppDefaults.suite)
    static let analyticsInstallId = Key<String?>("analyticsInstallId", default: nil, suite: AppDefaults.suite)
    static let analyticsFirstSeenAppVersion = Key<String?>("analyticsFirstSeenAppVersion", default: nil, suite: AppDefaults.suite)
    static let marketingAttributionId = Key<String?>("marketingAttributionId", default: nil, suite: AppDefaults.suite)
    static let marketingInitialUTMSource = Key<String?>("marketingInitialUTMSource", default: nil, suite: AppDefaults.suite)
    static let marketingInitialUTMMedium = Key<String?>("marketingInitialUTMMedium", default: nil, suite: AppDefaults.suite)
    static let marketingInitialUTMCampaign = Key<String?>("marketingInitialUTMCampaign", default: nil, suite: AppDefaults.suite)
    static let marketingInitialUTMContent = Key<String?>("marketingInitialUTMContent", default: nil, suite: AppDefaults.suite)
    static let marketingInitialUTMTerm = Key<String?>("marketingInitialUTMTerm", default: nil, suite: AppDefaults.suite)
    static let marketingInitialUTMId = Key<String?>("marketingInitialUTMId", default: nil, suite: AppDefaults.suite)
    static let marketingInitialSourceLink = Key<String?>("marketingInitialSourceLink", default: nil, suite: AppDefaults.suite)
    static let marketingInitialLandingPath = Key<String?>("marketingInitialLandingPath", default: nil, suite: AppDefaults.suite)
    static let marketingInitialReferrer = Key<String?>("marketingInitialReferrer", default: nil, suite: AppDefaults.suite)
    static let marketingLatestUTMSource = Key<String?>("marketingLatestUTMSource", default: nil, suite: AppDefaults.suite)
    static let marketingLatestUTMMedium = Key<String?>("marketingLatestUTMMedium", default: nil, suite: AppDefaults.suite)
    static let marketingLatestUTMCampaign = Key<String?>("marketingLatestUTMCampaign", default: nil, suite: AppDefaults.suite)
    static let marketingLatestUTMContent = Key<String?>("marketingLatestUTMContent", default: nil, suite: AppDefaults.suite)
    static let marketingLatestUTMTerm = Key<String?>("marketingLatestUTMTerm", default: nil, suite: AppDefaults.suite)
    static let marketingLatestUTMId = Key<String?>("marketingLatestUTMId", default: nil, suite: AppDefaults.suite)
    static let marketingLatestSourceLink = Key<String?>("marketingLatestSourceLink", default: nil, suite: AppDefaults.suite)
    static let marketingLatestLandingPath = Key<String?>("marketingLatestLandingPath", default: nil, suite: AppDefaults.suite)
    static let marketingLatestReferrer = Key<String?>("marketingLatestReferrer", default: nil, suite: AppDefaults.suite)
}

enum AnalyticsIdentity {
    static func installID() -> String {
        if let existing = Defaults[.analyticsInstallId]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty {
            return existing
        }

        let generated = UUID().uuidString.lowercased()
        Defaults[.analyticsInstallId] = generated
        return generated
    }

    static func firstSeenAppVersion(currentAppVersion: String) -> String {
        if let existing = Defaults[.analyticsFirstSeenAppVersion]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty {
            return existing
        }

        let normalizedVersion = currentAppVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedVersion = normalizedVersion.isEmpty ? "unknown" : normalizedVersion
        Defaults[.analyticsFirstSeenAppVersion] = resolvedVersion
        return resolvedVersion
    }
}
