import Foundation

enum BrowserCatalog {
    private static let displayNames: [String: String] = [
        "com.apple.safari": "Safari",
        "com.apple.safaritechnologypreview": "Safari Technology Preview",
        "com.brave.browser": "Brave",
        "com.brave.browser.beta": "Brave Beta",
        "com.duckduckgo.macos.browser": "DuckDuckGo",
        "com.google.chrome": "Google Chrome",
        "com.google.chrome.canary": "Chrome Canary",
        "com.kagi.orion": "Orion",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.operasoftware.opera": "Opera",
        "com.operasoftware.operagx": "Opera GX",
        "com.vivaldi.vivaldi": "Vivaldi",
        "company.thebrowser.browser": "Arc",
        "io.github.nicholasbeach.zen-browser": "Zen",
        "app.zen-browser.desktop": "Zen",
        "org.mozilla.firefox": "Firefox",
    ]

    static func displayName(for bundleId: String?) -> String? {
        guard let normalizedBundleId = normalizedBundleId(bundleId) else { return nil }
        return displayNames[normalizedBundleId]
    }

    static func isBrowser(_ bundleId: String?) -> Bool {
        guard let normalizedBundleId = normalizedBundleId(bundleId) else { return false }
        return displayNames[normalizedBundleId] != nil
    }

    /// All known browser bundle identifiers, lowercased. Stable ordering by key.
    static var allBundleIDs: [String] {
        displayNames.keys.sorted()
    }

    private static func normalizedBundleId(_ bundleId: String?) -> String? {
        let trimmed = bundleId?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed.lowercased()
    }
}

struct BrowserWebsiteDisplay: Equatable {
    let title: String
    let subtitle: String?
    let faviconURL: URL?

    static func from(
        windowTitle: String?,
        browserURL: String?,
        bundleId: String?,
        browserNameOverride: String? = nil
    ) -> BrowserWebsiteDisplay? {
        let browserName = browserNameOverride?.trimmedNilIfEmpty ?? BrowserCatalog.displayName(for: bundleId)

        if let host = host(from: browserURL) {
            let resolvedHostLabel = hostLabel(for: host)
            let websiteTitle = websiteLabel(from: windowTitle, bundleId: bundleId, host: host)
                ?? hostDisplayTitle(for: host)
                ?? resolvedHostLabel
            let subtitle = [browserName, resolvedHostLabel]
                .compactMap { $0?.trimmedNilIfEmpty }
                .uniquePreservingOrder()
                .joined(separator: " · ")
                .trimmedNilIfEmpty

            return BrowserWebsiteDisplay(
                title: websiteTitle,
                subtitle: subtitle,
                faviconURL: faviconURL(from: browserURL)
            )
        }

        // Fallback: no URL available, but we can still extract the website name from the window title
        if let websiteTitle = websiteLabel(from: windowTitle, bundleId: bundleId) {
            return BrowserWebsiteDisplay(
                title: websiteTitle,
                subtitle: browserName,
                faviconURL: nil
            )
        }

        return nil
    }

    static func host(from browserURL: String?) -> String? {
        guard let browserURL = browserURL?.trimmedNilIfEmpty else { return nil }
        let normalizedURL = browserURL.hasPrefix("http://") || browserURL.hasPrefix("https://")
            ? browserURL
            : "https://\(browserURL)"
        return URL(string: normalizedURL)?.host?.trimmedNilIfEmpty
    }

    static func faviconURL(from browserURL: String?) -> URL? {
        // Browser hosts can reveal sensitive activity. Use the local fallback
        // icon rather than disclosing them to a third-party favicon service.
        nil
    }

    private static func hostLabel(for host: String) -> String {
        host.replacingOccurrences(of: "www.", with: "")
    }

    private static let brandedHosts: [String: String] = [
        "threads.com": "Threads",
        "threads.net": "Threads",
    ]

    private static func hostDisplayTitle(for host: String) -> String? {
        brandedHosts[hostLabel(for: host).lowercased()]
    }

    static func websiteLabel(from windowTitle: String?, bundleId: String?, host: String? = nil) -> String? {
        guard let windowTitle = windowTitle?.trimmedNilIfEmpty,
              let browserName = BrowserCatalog.displayName(for: bundleId)
        else {
            return nil
        }

        var title = windowTitle
        let suffixes = [
            " - \(browserName)",
            " \u{2014} \(browserName)"
        ]

        for suffix in suffixes where title.hasSuffix(suffix) {
            title.removeLast(suffix.count)
            title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }

        guard title != windowTitle else { return nil }

        let separators = [" | ", " - ", " \u{2014} ", " \u{2013} "]
        let parts = separators.first(where: { title.contains($0) })
            .map { title.components(separatedBy: $0) } ?? [title]
        guard let candidate = parts.last?.trimmedNilIfEmpty,
              !["New Tab", "about:blank", "Untitled"].contains(candidate)
        else {
            return nil
        }

        if let host, let overrideTitle = hostDisplayTitle(for: host),
           candidate.localizedCaseInsensitiveContains(overrideTitle) {
            return overrideTitle
        }

        return candidate
    }
}

private extension Array where Element == String {
    func uniquePreservingOrder() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}

private extension String {
    var trimmedNilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
