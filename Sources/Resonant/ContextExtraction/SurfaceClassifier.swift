import Foundation

enum SurfaceClassifier {
    static func classify(hot: ContextExtractor.HotContext) -> SurfaceDescriptor {
        classify(
            appName: hot.appName,
            bundleId: hot.bundleId,
            windowTitle: hot.windowTitle,
            browserURL: hot.browserURL,
            focusedFieldContent: hot.focusedFieldContent
        )
    }

    static func classify(context: ContextExtractor.Context) -> SurfaceDescriptor {
        classify(
            appName: context.appName,
            bundleId: context.bundleId,
            windowTitle: context.windowTitle,
            browserURL: context.browserURL,
            focusedFieldContent: context.focusedFieldContent
        )
    }

    static func classify(
        appName: String?,
        bundleId: String?,
        windowTitle: String?,
        browserURL: String?,
        focusedFieldContent: String? = nil
    ) -> SurfaceDescriptor {
        let normalizedAppName = normalize(appName)?.lowercased() ?? ""
        let normalizedBundleId = normalize(bundleId)?.lowercased() ?? ""
        let normalizedWindowTitle = normalize(windowTitle) ?? ""
        let normalizedBrowserURL = normalize(browserURL)
        let host = hostName(from: normalizedBrowserURL)
        let normalizedHost = host?.lowercased() ?? ""
        let combined = [
            normalizedAppName,
            normalizedBundleId,
            normalizedWindowTitle.lowercased(),
            normalizedHost,
        ].joined(separator: " ")

        let kind = surfaceKind(
            appName: normalizedAppName,
            bundleId: normalizedBundleId,
            host: normalizedHost,
            combined: combined
        )
        let fieldKind = fieldKind(
            surfaceKind: kind,
            windowTitle: normalizedWindowTitle,
            browserURL: normalizedBrowserURL,
            focusedFieldContent: focusedFieldContent
        )

        return SurfaceDescriptor(
            kind: kind,
            appName: normalize(appName),
            bundleId: normalize(bundleId),
            windowTitle: normalize(windowTitle),
            browserURL: normalizedBrowserURL,
            siteHost: host,
            siteName: siteName(host: normalizedHost),
            fieldKind: fieldKind,
            conversationLabel: conversationLabel(
                kind: kind,
                appName: normalizedAppName,
                host: normalizedHost,
                windowTitle: normalizedWindowTitle
            ),
            documentLabel: documentLabel(kind: kind, windowTitle: normalizedWindowTitle),
            projectLabel: nil
        )
    }

    private static func surfaceKind(
        appName: String,
        bundleId: String,
        host: String,
        combined: String
    ) -> SurfaceKind {
        if bundleId == "com.apple.finder" || appName == "finder" {
            return .finder
        }
        if codeBundles.contains(bundleId) || codeApps.contains(appName) {
            return .code
        }
        if terminalBundles.contains(bundleId) || terminalApps.contains(appName) {
            return .terminal
        }
        if emailBundles.contains(bundleId) || emailHosts.contains(host) || containsAny(combined, emailNeedles) {
            return .email
        }
        if chatBundles.contains(bundleId) || chatHosts.contains(host) || containsAny(combined, chatNeedles) {
            return .chat
        }
        if socialHosts.contains(host) || containsAny(combined, socialNeedles) {
            return .social
        }
        if taskHosts.contains(host) || containsAny(combined, taskNeedles) {
            return .task
        }
        if docsBundles.contains(bundleId) || docsHosts.contains(host) || containsAny(combined, docsNeedles) {
            return .docs
        }
        if searchHosts.contains(host) {
            return .search
        }
        if !host.isEmpty {
            return .browser
        }
        return .other
    }

    private static func fieldKind(
        surfaceKind: SurfaceKind,
        windowTitle: String,
        browserURL: String?,
        focusedFieldContent: String?
    ) -> FieldKind {
        let title = windowTitle.lowercased()
        let url = browserURL?.lowercased() ?? ""
        if surfaceKind == .search || title.contains("search") || url.contains("/search") {
            return .search
        }
        if surfaceKind == .terminal {
            return .terminal
        }
        if surfaceKind == .code {
            return .code
        }
        if surfaceKind == .social {
            return .comment
        }
        if surfaceKind == .email {
            if title.contains("reply") || (focusedFieldContent?.isEmpty == false) {
                return .reply
            }
            return .compose
        }
        if surfaceKind == .chat {
            return .compose
        }
        if surfaceKind == .docs {
            return .richText
        }
        if surfaceKind == .task {
            return .comment
        }
        return .unknown
    }

    private static func conversationLabel(
        kind: SurfaceKind,
        appName: String,
        host: String,
        windowTitle: String
    ) -> String? {
        guard [.email, .chat, .social, .task].contains(kind) else { return nil }
        let label = cleanedWindowTitle(windowTitle, appName: appName, host: host)
        return label.isEmpty ? nil : String(label.prefix(120))
    }

    private static func documentLabel(kind: SurfaceKind, windowTitle: String) -> String? {
        guard [.docs, .code, .browser].contains(kind) else { return nil }
        let label = cleanedWindowTitle(windowTitle, appName: "", host: "")
        return label.isEmpty ? nil : String(label.prefix(120))
    }

    private static func cleanedWindowTitle(_ title: String, appName: String, host: String) -> String {
        var parts = title
            .split(separator: "—")
            .flatMap { $0.split(separator: "-") }
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if let last = parts.last?.lowercased(),
           !appName.isEmpty,
           (last == appName || last.contains(appName)) {
            parts.removeLast()
        }
        if let last = parts.last?.lowercased(),
           !host.isEmpty,
           last.contains(host) {
            parts.removeLast()
        }
        return parts.first ?? title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func hostName(from browserURL: String?) -> String? {
        guard let raw = normalize(browserURL) else { return nil }
        let withScheme = raw.contains("://") ? raw : "https://\(raw)"
        guard let host = URL(string: withScheme)?.host?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private static func siteName(host: String) -> String? {
        guard !host.isEmpty else { return nil }
        if host.contains("mail.google.") { return "Gmail" }
        if host.contains("outlook.") || host.contains("office.") { return "Outlook" }
        if host.contains("reddit.") { return "Reddit" }
        if host == "x.com" || host.contains("twitter.") { return "X" }
        if host.contains("github.") { return "GitHub" }
        if host.contains("linear.") { return "Linear" }
        if host.contains("notion.") { return "Notion" }
        if host.contains("slack.") { return "Slack" }
        if host.contains("teams.") { return "Teams" }
        if host.contains("whatsapp.") { return "WhatsApp" }
        if host.contains("telegram.") { return "Telegram" }
        return host.split(separator: ".").first.map(String.init)
    }

    private static func containsAny(_ haystack: String, _ needles: Set<String>) -> Bool {
        needles.contains(where: { haystack.contains($0) })
    }

    private static func normalize(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static let emailBundles: Set<String> = [
        "com.apple.mail",
        "com.microsoft.outlook",
        "com.readdle.smartemail-mac",
    ]
    private static let emailHosts: Set<String> = [
        "mail.google.com",
        "outlook.office.com",
        "outlook.live.com",
        "mail.proton.me",
        "app.fastmail.com",
        "mail.superhuman.com",
    ]
    private static let emailNeedles: Set<String> = [
        "gmail", "outlook", "apple mail", "proton mail", "fastmail", "superhuman"
    ]

    private static let chatBundles: Set<String> = [
        "com.tinyspeck.slackmacgap",
        "com.microsoft.teams",
        "com.hnc.discord",
        "org.whispersystems.signal-desktop",
        "ru.keepcoder.telegram",
        "net.whatsapp.whatsapp",
        "com.apple.messages",
    ]
    private static let chatHosts: Set<String> = [
        "app.slack.com",
        "teams.microsoft.com",
        "discord.com",
        "web.telegram.org",
        "web.whatsapp.com",
        "messages.google.com",
        "chat.google.com",
    ]
    private static let chatNeedles: Set<String> = [
        "slack", "teams", "discord", "telegram", "whatsapp", "signal", "messages", "google chat"
    ]

    private static let socialHosts: Set<String> = [
        "reddit.com",
        "x.com",
        "twitter.com",
        "linkedin.com",
        "news.ycombinator.com",
        "bsky.app",
        "mastodon.social",
        "threads.net",
    ]
    private static let socialNeedles: Set<String> = [
        "reddit", "twitter", "x.com", "linkedin", "hacker news", "mastodon", "bluesky", "threads"
    ]

    private static let codeBundles: Set<String> = [
        "com.apple.dt.xcode",
        "com.microsoft.vscode",
        "com.todesktop.230313mzl4w4u92",
        "dev.zed.zed",
        "com.jetbrains.intellij",
        "com.jetbrains.pycharm",
        "com.jetbrains.webstorm",
    ]
    private static let codeApps: Set<String> = [
        "xcode", "visual studio code", "code", "cursor", "zed", "intellij idea", "pycharm", "webstorm"
    ]

    private static let terminalBundles: Set<String> = [
        "com.apple.terminal",
        "com.googlecode.iterm2",
        "dev.warp.warp-stable",
    ]
    private static let terminalApps: Set<String> = ["terminal", "iterm2", "warp"]

    private static let docsBundles: Set<String> = [
        "com.microsoft.word",
        "com.apple.pages",
        "md.obsidian",
        "notion.id",
    ]
    private static let docsHosts: Set<String> = [
        "docs.google.com",
        "www.notion.so",
        "notion.so",
    ]
    private static let docsNeedles: Set<String> = [
        "google docs", "notion", "obsidian", "word", "pages"
    ]

    private static let taskHosts: Set<String> = [
        "linear.app",
        "jira.com",
        "atlassian.net",
        "app.asana.com",
        "todoist.com",
        "github.com",
    ]
    private static let taskNeedles: Set<String> = [
        "linear", "jira", "asana", "todoist", "github issue", "pull request"
    ]

    private static let searchHosts: Set<String> = [
        "google.com",
        "duckduckgo.com",
        "bing.com",
        "perplexity.ai",
    ]
}
