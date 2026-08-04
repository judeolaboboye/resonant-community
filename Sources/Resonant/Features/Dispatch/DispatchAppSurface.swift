import Foundation

enum DispatchAppSurfaceKind: String, Codable, Sendable, Equatable {
    case slack
    case discord
    case linear
    case devin
    case github
    case browser
    case unknown
}

enum DispatchAppSurfaceVariant: String, Codable, Sendable, Equatable {
    case native
    case web
    case browser
    case unknown
}

struct DispatchAppSurface: Codable, Sendable, Equatable {
    var kind: DispatchAppSurfaceKind
    var variant: DispatchAppSurfaceVariant
    var label: String
    var bundleID: String?
    var browserHost: String?
    var browserURL: String?

    var isKnownApp: Bool {
        switch kind {
        case .slack, .discord, .linear, .devin, .github:
            true
        case .browser, .unknown:
            false
        }
    }
}

enum DispatchAppSurfaceResolver {
    static func resolve(
        appName: String?,
        bundleID: String?,
        browserTitle: String?,
        browserURL: String?
    ) -> DispatchAppSurface {
        let normalizedBundle = normalized(bundleID)
        let host = browserHost(from: browserURL)

        if let native = nativeSurface(appName: appName, bundleID: normalizedBundle, originalBundleID: bundleID) {
            return native
        }

        if BrowserCatalog.isBrowser(bundleID),
           let web = webSurface(host: host, browserURL: browserURL) {
            return web
        }

        if BrowserCatalog.isBrowser(bundleID) {
            return DispatchAppSurface(
                kind: .browser,
                variant: .browser,
                label: BrowserCatalog.displayName(for: bundleID) ?? trimmedNilIfEmpty(appName) ?? "Browser",
                bundleID: bundleID,
                browserHost: host,
                browserURL: browserURL
            )
        }

        let label = trimmedNilIfEmpty(appName)
            ?? trimmedNilIfEmpty(bundleID)
            ?? trimmedNilIfEmpty(browserTitle)
            ?? "Unknown"
        return DispatchAppSurface(
            kind: .unknown,
            variant: .unknown,
            label: label,
            bundleID: bundleID,
            browserHost: host,
            browserURL: browserURL
        )
    }

    static func matches(expectedApp: String, surface: DispatchAppSurface) -> Bool {
        let expected = normalizedToken(expectedApp)
        guard !expected.isEmpty else { return false }
        if surface.kind.rawValue == expected {
            return true
        }
        let actual = normalizedToken([surface.label, surface.bundleID, surface.browserHost].compactMap { $0 }.joined(separator: " "))
        return actual.contains(expected)
    }

    static func kindMentioned(in text: String) -> DispatchAppSurfaceKind? {
        let token = normalizedToken(text)
        for kind in [DispatchAppSurfaceKind.slack, .discord, .linear, .devin, .github] where token.contains(kind.rawValue) {
            return kind
        }
        return nil
    }

    private static func nativeSurface(
        appName: String?,
        bundleID: String?,
        originalBundleID: String?
    ) -> DispatchAppSurface? {
        let nativeBundles: [(DispatchAppSurfaceKind, Set<String>)] = [
            (.slack, ["com.tinyspeck.slackmacgap"]),
            (.discord, ["com.hnc.discord", "com.hnc.discordcanary", "com.hnc.discordptb"]),
            (.linear, ["com.linear", "app.linear", "com.linear.app"])
        ]
        for (kind, bundles) in nativeBundles where bundleID.map({ bundle in bundles.contains { bundle == $0 || bundle.contains($0) } }) == true {
            return DispatchAppSurface(
                kind: kind,
                variant: .native,
                label: displayName(for: kind),
                bundleID: originalBundleID,
                browserHost: nil,
                browserURL: nil
            )
        }

        let nameToken = normalizedToken(appName ?? "")
        for kind in [DispatchAppSurfaceKind.slack, .discord, .linear] where nameToken == kind.rawValue {
            return DispatchAppSurface(
                kind: kind,
                variant: .native,
                label: displayName(for: kind),
                bundleID: originalBundleID,
                browserHost: nil,
                browserURL: nil
            )
        }
        return nil
    }

    private static func webSurface(host: String?, browserURL: String?) -> DispatchAppSurface? {
        guard let host else { return nil }
        let mappings: [(DispatchAppSurfaceKind, [String])] = [
            (.slack, ["app.slack.com", "slack.com"]),
            (.discord, ["discord.com", "discordapp.com"]),
            (.linear, ["linear.app"]),
            (.devin, ["app.devin.ai", "devin.ai"]),
            (.github, ["github.com"])
        ]
        for (kind, hosts) in mappings where hosts.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) {
            return DispatchAppSurface(
                kind: kind,
                variant: .web,
                label: displayName(for: kind),
                bundleID: nil,
                browserHost: host,
                browserURL: browserURL
            )
        }
        return nil
    }

    private static func browserHost(from rawURL: String?) -> String? {
        guard let trimmed = trimmedNilIfEmpty(rawURL) else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        return URL(string: withScheme)?.host(percentEncoded: false)?.lowercased()
    }

    private static func displayName(for kind: DispatchAppSurfaceKind) -> String {
        switch kind {
        case .slack: "Slack"
        case .discord: "Discord"
        case .linear: "Linear"
        case .devin: "Devin"
        case .github: "GitHub"
        case .browser: "Browser"
        case .unknown: "Unknown"
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = trimmedNilIfEmpty(value) else { return nil }
        return value.lowercased()
    }

    private static func trimmedNilIfEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedToken(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined()
    }
}
