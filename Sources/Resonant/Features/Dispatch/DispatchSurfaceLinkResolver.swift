import Foundation

struct DispatchSurfaceLink: Equatable, Sendable {
    enum Kind: String, Sendable {
        case browserPage = "browser page"
        case gmail = "Gmail"
        case slack = "Slack"
        case linear = "Linear"
        case github = "GitHub"
        case googleDocs = "Google Docs"
        case notion = "Notion"
        case webApp = "web app"
        case focusedFieldAnchor = "focused field"
    }

    let kind: Kind
    let url: String?
    let label: String
    let confidence: Double
    let evidence: String
}

enum DispatchSurfaceLinkResolver {
    static func links(contextPacket: ContextPacket?, snapshots: [DispatchRouteSnapshot] = []) -> [DispatchSurfaceLink] {
        var links: [DispatchSurfaceLink] = []

        if let contextPacket {
            if let link = link(
                urlString: contextPacket.surface.browserURL,
                appName: contextPacket.surface.appName,
                windowTitle: contextPacket.surface.windowTitle
            ) {
                links.append(link)
            }

            if let anchor = focusedFieldAnchor(contextPacket) {
                links.append(anchor)
            }
        }

        for snapshot in snapshots.prefix(5) {
            if let link = link(
                urlString: snapshot.browserURL,
                appName: snapshot.appName,
                windowTitle: snapshot.windowTitle
            ),
               !links.contains(where: { $0.url == link.url && $0.kind == link.kind }) {
                links.append(link)
            }
        }

        return Array(links.prefix(4))
    }

    private static func link(urlString: String?, appName: String?, windowTitle: String?) -> DispatchSurfaceLink? {
        guard let normalizedURL = normalizedURL(urlString),
              let url = URL(string: normalizedURL),
              let host = url.host(percentEncoded: false)?.lowercased() else {
            return nil
        }

        let kind = kind(host: host, path: url.path)
        let label = label(kind: kind, host: host, windowTitle: windowTitle, appName: appName)
        return DispatchSurfaceLink(
            kind: kind,
            url: normalizedURL,
            label: label,
            confidence: confidence(kind: kind),
            evidence: "Current browser/app URL"
        )
    }

    private static func focusedFieldAnchor(_ contextPacket: ContextPacket) -> DispatchSurfaceLink? {
        guard let target = contextPacket.targetFingerprint else { return nil }
        let parts = [
            target.role,
            target.subrole,
            target.identifierToken,
            target.titleToken,
            target.descriptionToken,
            target.placeholderToken,
            target.helpToken,
            target.frameBucket
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

        guard !parts.isEmpty else { return nil }
        let app = contextPacket.surface.appName ?? "active app"
        return DispatchSurfaceLink(
            kind: .focusedFieldAnchor,
            url: nil,
            label: "\(app) focused field: \(parts.prefix(4).joined(separator: " / "))",
            confidence: 0.62,
            evidence: "AX focused-field fingerprint"
        )
    }

    private static func kind(host: String, path: String) -> DispatchSurfaceLink.Kind {
        if host == "mail.google.com" { return .gmail }
        if host.hasSuffix(".slack.com") || host == "slack.com" { return .slack }
        if host == "linear.app" || host.hasSuffix(".linear.app") { return .linear }
        if host == "github.com" || host.hasSuffix(".github.com") { return .github }
        if host == "docs.google.com" { return .googleDocs }
        if host == "notion.so" || host.hasSuffix(".notion.so") { return .notion }
        if path != "/" && !path.isEmpty { return .webApp }
        return .browserPage
    }

    private static func confidence(kind: DispatchSurfaceLink.Kind) -> Double {
        switch kind {
        case .gmail, .slack, .linear, .github, .googleDocs, .notion:
            return 0.9
        case .webApp:
            return 0.78
        case .browserPage:
            return 0.72
        case .focusedFieldAnchor:
            return 0.62
        }
    }

    private static func label(
        kind: DispatchSurfaceLink.Kind,
        host: String,
        windowTitle: String?,
        appName: String?
    ) -> String {
        let title = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = title?.isEmpty == false ? title! : host
        if let appName, !appName.isEmpty {
            return "\(kind.rawValue): \(prefix) in \(appName)"
        }
        return "\(kind.rawValue): \(prefix)"
    }

    private static func normalizedURL(_ urlString: String?) -> String? {
        guard let trimmed = urlString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return trimmed
        }
        guard ContextExtractor.looksLikeURL(trimmed) else { return nil }
        return "https://\(trimmed)"
    }
}
