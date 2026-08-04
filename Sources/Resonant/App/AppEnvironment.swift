import Foundation

enum AppDistribution: String, CaseIterable {
    case community
    case official

    enum InfoDictionaryKey {
        static let distribution = "ResonantDistribution"
    }

    enum ProcessEnvironmentKey {
        static let distribution = "RESONANT_DISTRIBUTION"
    }

    static var current: AppDistribution {
        resolve(
            processEnvironment: ProcessInfo.processInfo.environment,
            infoDictionary: Bundle.main.infoDictionary
        )
    }

    static func resolve(
        processEnvironment: [String: String],
        infoDictionary: [String: Any]?
    ) -> AppDistribution {
        if let rawProcessValue = processEnvironment[ProcessEnvironmentKey.distribution],
           let distribution = parse(rawValue: rawProcessValue) {
            return distribution
        }

        if let rawInfoValue = infoDictionary?[InfoDictionaryKey.distribution] as? String,
           let distribution = parse(rawValue: rawInfoValue) {
            return distribution
        }

        return .community
    }

    static func parse(rawValue: String) -> AppDistribution? {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "community":
            .community
        case "official":
            .official
        default:
            nil
        }
    }

    func defaultBundleIdentifier(for environment: AppEnvironment) -> String {
        switch (self, environment) {
        case (.community, .development):
            "org.resonant.community.dev"
        case (.community, .production):
            "org.resonant.community"
        case (.official, .development):
            "com.resonance.resonant.dev"
        case (.official, .production):
            "com.resonance.resonant"
        }
    }

    func defaultsSuiteName(
        environment: AppEnvironment,
        bundleIdentifier: String?
    ) -> String {
        if self == .official,
           Self.isCanonicalOfficialBundleIdentifier(bundleIdentifier, environment: environment) {
            return environment.officialDefaultsSuiteName
        }

        return "\(identityBase(environment: environment, bundleIdentifier: bundleIdentifier)).defaults"
    }

    func keychainServiceName(
        environment: AppEnvironment,
        bundleIdentifier: String?
    ) -> String {
        if self == .official,
           Self.isCanonicalOfficialBundleIdentifier(bundleIdentifier, environment: environment) {
            return environment.officialKeychainServiceName
        }

        return "\(identityBase(environment: environment, bundleIdentifier: bundleIdentifier)).keychain"
    }

    /// A filesystem- and config-key-safe identity for local integration files.
    /// Custom distributions get their own namespace when they use their own
    /// bundle identifier; development and production never share state.
    func localIdentitySlug(
        environment: AppEnvironment,
        bundleIdentifier: String?
    ) -> String {
        let canonicalBundleIdentifier = defaultBundleIdentifier(for: environment)
        let resolvedBundleIdentifier = identityBase(
            environment: environment,
            bundleIdentifier: bundleIdentifier
        )

        if resolvedBundleIdentifier == canonicalBundleIdentifier {
            switch (self, environment) {
            case (.community, .development): return "resonant-community-dev"
            case (.community, .production): return "resonant-community"
            case (.official, .development): return "resonant-dev"
            case (.official, .production): return "resonant"
            }
        }

        let sanitized = resolvedBundleIdentifier.lowercased()
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
        let collapsed = String(sanitized)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return "resonant-\(collapsed.isEmpty ? "custom" : collapsed)"
    }

    func applicationSupportDirectoryName(
        environment: AppEnvironment,
        bundleIdentifier: String?
    ) -> String {
        switch localIdentitySlug(environment: environment, bundleIdentifier: bundleIdentifier) {
        case "resonant": return "Resonant"
        case "resonant-dev": return "Resonant Dev"
        case "resonant-community": return "Resonant Community"
        case "resonant-community-dev": return "Resonant Community Dev"
        case let slug: return "Resonant \(slug)"
        }
    }

    private func identityBase(
        environment: AppEnvironment,
        bundleIdentifier: String?
    ) -> String {
        guard let bundleIdentifier,
              Self.isValidIdentityBundleIdentifier(bundleIdentifier) else {
            return defaultBundleIdentifier(for: environment)
        }

        return bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isCanonicalOfficialBundleIdentifier(
        _ bundleIdentifier: String?,
        environment: AppEnvironment
    ) -> Bool {
        bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
            == AppDistribution.official.defaultBundleIdentifier(for: environment)
    }

    private static func isValidIdentityBundleIdentifier(_ rawValue: String) -> Bool {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2, components.allSatisfy({ !$0.isEmpty }) else {
            return false
        }

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        return components.allSatisfy { component in
            guard let first = component.unicodeScalars.first,
                  let last = component.unicodeScalars.last,
                  CharacterSet.alphanumerics.contains(first),
                  CharacterSet.alphanumerics.contains(last) else {
                return false
            }
            return component.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
    }
}

struct HostedServicesConfiguration: Equatable {
    let convexCloudURL: URL
    let authBaseURL: URL
}

enum HostedServicesConfigurationError: Error, Equatable {
    case incomplete
    case invalidConvexCloudURL
    case invalidAuthBaseURL
}

enum AppEnvironment: String, CaseIterable {
    case development
    case production

    enum InfoDictionaryKey {
        static let environment = "ResonantAppEnvironment"
        static let convexCloudURL = "ResonantConvexCloudURL"
        static let authBaseURL = "ResonantAuthBaseURL"
    }

    enum ProcessEnvironmentKey {
        static let environment = "RESONANT_APP_ENV"
        static let convexCloudURL = "RESONANT_CONVEX_CLOUD_URL"
        static let authBaseURL = "RESONANT_AUTH_BASE_URL"
    }

    // Existing cloud clients currently require concrete URLs. These reserved
    // .invalid endpoints keep an unconfigured Community build fail-closed
    // without contacting Resonant or another operator's hosted services.
    static let unavailableConvexCloudURL = URL(string: "https://convex.invalid")!
    static let unavailableAuthBaseURL = URL(string: "https://auth.invalid")!

    // Compatibility for the two hosted-only sharing call sites that still use
    // this symbol. It deliberately does not point at Resonant production.
    static let productionAuthBaseURL = unavailableAuthBaseURL

    static var current: AppEnvironment {
        resolve(
            processEnvironment: ProcessInfo.processInfo.environment,
            infoDictionary: Bundle.main.infoDictionary
        )
    }

    static func resolve(
        processEnvironment: [String: String],
        infoDictionary: [String: Any]?
    ) -> AppEnvironment {
        if let rawProcessValue = processEnvironment[ProcessEnvironmentKey.environment],
           let environment = parse(rawValue: rawProcessValue) {
            return environment
        }

        if let rawInfoValue = infoDictionary?[InfoDictionaryKey.environment] as? String,
           let environment = parse(rawValue: rawInfoValue) {
            return environment
        }

        #if DEBUG
        return .development
        #else
        return .production
        #endif
    }

    static func parse(rawValue: String) -> AppEnvironment? {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "dev", "development":
            .development
        case "prod", "production":
            .production
        default:
            nil
        }
    }

    static func resolveHostedServicesConfiguration(
        processEnvironment: [String: String],
        infoDictionary: [String: Any]?
    ) throws -> HostedServicesConfiguration? {
        let processConvex = normalized(processEnvironment[ProcessEnvironmentKey.convexCloudURL])
        let processAuth = normalized(processEnvironment[ProcessEnvironmentKey.authBaseURL])

        // Process overrides are one atomic configuration layer. If either is
        // present, do not combine it with the other value from Info.plist.
        if processConvex != nil || processAuth != nil {
            return try makeHostedServicesConfiguration(
                convexCloudURL: processConvex,
                authBaseURL: processAuth,
                environment: resolve(
                    processEnvironment: processEnvironment,
                    infoDictionary: infoDictionary
                )
            )
        }

        let infoConvex = normalized(infoDictionary?[InfoDictionaryKey.convexCloudURL] as? String)
        let infoAuth = normalized(infoDictionary?[InfoDictionaryKey.authBaseURL] as? String)
        if infoConvex != nil || infoAuth != nil {
            return try makeHostedServicesConfiguration(
                convexCloudURL: infoConvex,
                authBaseURL: infoAuth,
                environment: resolve(
                    processEnvironment: processEnvironment,
                    infoDictionary: infoDictionary
                )
            )
        }

        return nil
    }

    func hostedServicesConfiguration(
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) throws -> HostedServicesConfiguration? {
        try Self.resolveHostedServicesConfiguration(
            processEnvironment: processEnvironment,
            infoDictionary: infoDictionary
        )
    }

    func convexCloudURL(
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> URL {
        resolvedHostedServicesConfiguration(
            processEnvironment: processEnvironment,
            infoDictionary: infoDictionary
        )?.convexCloudURL ?? Self.unavailableConvexCloudURL
    }

    func authBaseURL(
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> URL {
        resolvedHostedServicesConfiguration(
            processEnvironment: processEnvironment,
            infoDictionary: infoDictionary
        )?.authBaseURL ?? Self.unavailableAuthBaseURL
    }

    var defaultsSuiteName: String {
        officialDefaultsSuiteName
    }

    var keychainServiceName: String {
        officialKeychainServiceName
    }

    fileprivate var officialDefaultsSuiteName: String {
        switch self {
        case .development:
            "com.resonance.resonant.dev"
        case .production:
            "com.resonance.resonant"
        }
    }

    fileprivate var officialKeychainServiceName: String {
        officialDefaultsSuiteName
    }

    var sentryEnvironmentName: String {
        rawValue
    }

    private static func makeHostedServicesConfiguration(
        convexCloudURL: String?,
        authBaseURL: String?,
        environment: AppEnvironment
    ) throws -> HostedServicesConfiguration {
        guard let convexCloudURL, let authBaseURL else {
            throw HostedServicesConfigurationError.incomplete
        }

        guard let parsedConvexCloudURL = parseServiceURL(convexCloudURL, environment: environment) else {
            throw HostedServicesConfigurationError.invalidConvexCloudURL
        }
        guard let parsedAuthBaseURL = parseServiceURL(authBaseURL, environment: environment) else {
            throw HostedServicesConfigurationError.invalidAuthBaseURL
        }

        return HostedServicesConfiguration(
            convexCloudURL: parsedConvexCloudURL,
            authBaseURL: parsedAuthBaseURL
        )
    }

    private func resolvedHostedServicesConfiguration(
        processEnvironment: [String: String],
        infoDictionary: [String: Any]?
    ) -> HostedServicesConfiguration? {
        do {
            return try hostedServicesConfiguration(
                processEnvironment: processEnvironment,
                infoDictionary: infoDictionary
            )
        } catch {
            return nil
        }
    }

    private static func normalized(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func parseServiceURL(_ rawValue: String, environment: AppEnvironment) -> URL? {
        guard let url = URL(string: rawValue),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              !host.isEmpty else {
            return nil
        }
        if scheme == "https" {
            return url
        }
        let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]
        guard environment == .development,
              scheme == "http",
              loopbackHosts.contains(host) else {
            return nil
        }
        return url
    }
}
