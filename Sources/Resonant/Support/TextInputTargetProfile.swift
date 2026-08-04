import Foundation

struct TextInputTargetProfile: Equatable {
    enum Kind: Equatable {
        case unknown
        case codexApp
        case cmuxApp
        case terminalApp
        case electronEditorApp
        case firefoxEngineBrowser
        case claudeWeb
        case discordDesktop
        case discordWeb
        case googleDocsWeb
        case gmailWeb
        case protonMailWeb
        case webMailClient  // Outlook, Fastmail, Yahoo Mail, Hey, Tuta, Zoho
        case linkedInWeb
    }

    let kind: Kind

    init(bundleID: String?, windowTitle: String? = nil, browserURL: String? = nil) {
        kind = Self.resolveKind(
            bundleID: bundleID,
            windowTitle: windowTitle,
            browserURL: browserURL
        )
    }

    var bypassesAXValueInsertion: Bool {
        switch kind {
        case .codexApp, .terminalApp, .electronEditorApp, .firefoxEngineBrowser, .claudeWeb, .discordDesktop, .discordWeb, .googleDocsWeb, .gmailWeb, .protonMailWeb, .webMailClient, .linkedInWeb:
            return true
        // Conductor (.cmuxApp) renders its composer in WKWebView (it's a Tauri
        // app), NOT Chromium/Electron. WebKit honors AX value writes — they fire
        // DOM input events — so AX insertion lands, and unlike synthetic Cmd+V it
        // is immune to Secure Event Input from Conductor's embedded terminal/PTY
        // panes. Keep it on the AX-insertion-first path (it still falls back to
        // Cmd+V when AX is unavailable). Bypassing AX here (the Chromium-webview
        // policy) left Cmd+V as the sole delivery path and regressed paste into
        // Conductor to the "Copied to clipboard" fallback.
        case .cmuxApp, .unknown:
            return false
        }
    }

    var bypassesCorrectionReadback: Bool {
        switch kind {
        case .codexApp, .cmuxApp, .terminalApp, .electronEditorApp, .firefoxEngineBrowser, .claudeWeb, .discordDesktop, .discordWeb:
            return true
        case .unknown, .googleDocsWeb, .gmailWeb, .protonMailWeb, .webMailClient, .linkedInWeb:
            return false
        }
    }

    var prefersDirectTyping: Bool {
        switch kind {
        case .terminalApp:
            return true
        case .unknown, .codexApp, .cmuxApp, .electronEditorApp, .firefoxEngineBrowser, .claudeWeb, .discordDesktop, .discordWeb, .googleDocsWeb, .gmailWeb, .protonMailWeb, .webMailClient, .linkedInWeb:
            return false
        }
    }

    /// Some targets reject AX writes but still expose a reliable enough
    /// read-only AX text snapshot that keyboard delivery should be treated as
    /// failed when it cannot be verified.
    var requiresVerifiedKeyboardDelivery: Bool {
        switch kind {
        case .unknown, .codexApp, .cmuxApp, .terminalApp, .electronEditorApp, .firefoxEngineBrowser, .claudeWeb, .discordDesktop, .discordWeb, .googleDocsWeb, .gmailWeb, .protonMailWeb, .webMailClient, .linkedInWeb:
            return false
        }
    }

    var capturesFocusedFieldValue: Bool {
        !isChatComposerSurface
    }

    var collectsVisibleTextSnippets: Bool {
        !isChatComposerSurface
    }

    var isChatComposerSurface: Bool {
        switch kind {
        case .codexApp, .claudeWeb, .discordDesktop, .discordWeb:
            return true
        case .unknown, .cmuxApp, .terminalApp, .electronEditorApp, .firefoxEngineBrowser, .googleDocsWeb, .gmailWeb, .protonMailWeb, .webMailClient, .linkedInWeb:
            return false
        }
    }

    var autoSendDelay: Duration {
        switch kind {
        case .codexApp, .cmuxApp:
            return .milliseconds(180)
        case .terminalApp:
            return .milliseconds(80)
        case .claudeWeb, .discordDesktop, .discordWeb, .linkedInWeb:
            return .milliseconds(220)
        case .electronEditorApp, .firefoxEngineBrowser, .googleDocsWeb, .gmailWeb, .protonMailWeb, .webMailClient:
            return .milliseconds(80)
        case .unknown:
            return .milliseconds(80)
        }
    }

    private static let discordBundleIDs: Set<String> = [
        "com.hnc.discord",
        "com.hnc.discordcanary",
        "com.hnc.discordptb",
    ]

    // Electron-based editors whose webview inputs silently accept AX writes
    // without firing DOM events — bypass AX and use Cmd+V instead.
    private static let electronEditorBundleIDs: Set<String> = [
        "com.microsoft.vscode",
        "com.todesktop.230313mzl4w4u92",  // Cursor (AI code editor)
    ]

    // Firefox-engine browsers whose AX implementation inserts
    // kAXSelectedTextAttribute at position 0 instead of the cursor.
    private static let firefoxEngineBundleIDs: Set<String> = [
        "org.mozilla.firefox",
        "app.zen-browser.desktop",
        "io.github.nicholasbeach.zen-browser",
    ]

    private static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
    ]

    private static func resolveKind(
        bundleID: String?,
        windowTitle: String?,
        browserURL: String?
    ) -> Kind {
        let normalizedBundleID = normalize(bundleID)
        if normalizedBundleID == "com.openai.codex" {
            return .codexApp
        }
        // The CMUX desktop app currently ships as Conductor.app with this
        // bundle identifier.
        if normalizedBundleID == "com.conductor.app" {
            return .cmuxApp
        }

        if let normalizedBundleID, firefoxEngineBundleIDs.contains(normalizedBundleID) {
            return .firefoxEngineBrowser
        }

        if let normalizedBundleID, terminalBundleIDs.contains(normalizedBundleID) {
            return .terminalApp
        }

        if let normalizedBundleID, electronEditorBundleIDs.contains(normalizedBundleID) {
            return .electronEditorApp
        }

        if let normalizedBundleID, discordBundleIDs.contains(normalizedBundleID) {
            return .discordDesktop
        }

        if let host = normalizedHost(from: browserURL) {
            if isGoogleDocsHost(host) {
                return .googleDocsWeb
            }
            if isGmailHost(host) {
                return .gmailWeb
            }
            if isClaudeHost(host) {
                return .claudeWeb
            }
            if isDiscordHost(host) {
                return .discordWeb
            }
            if isLinkedInHost(host) {
                return .linkedInWeb
            }
            if isProtonMailHost(host) {
                return .protonMailWeb
            }
            if isWebMailClientHost(host) {
                return .webMailClient
            }
        }

        if BrowserCatalog.isBrowser(normalizedBundleID) {
            let normalizedWindowTitle = normalize(windowTitle) ?? ""
            if normalizedWindowTitle.contains("google docs") {
                return .googleDocsWeb
            }
            if normalizedWindowTitle.contains("gmail") {
                return .gmailWeb
            }
            if normalizedWindowTitle.contains("claude") {
                return .claudeWeb
            }
            if normalizedWindowTitle.contains("discord") {
                return .discordWeb
            }
            if normalizedWindowTitle.contains("linkedin") {
                return .linkedInWeb
            }
            if normalizedWindowTitle.contains("proton mail") || normalizedWindowTitle.contains("protonmail") {
                return .protonMailWeb
            }
            if normalizedWindowTitle.contains("outlook")
                || normalizedWindowTitle.contains("fastmail")
                || normalizedWindowTitle.contains("yahoo mail")
                || normalizedWindowTitle.contains("hey")
                || normalizedWindowTitle.contains("tuta mail") || normalizedWindowTitle.contains("tutanota")
                || normalizedWindowTitle.contains("zoho mail")
                || normalizedWindowTitle.contains("canary mail") {
                return .webMailClient
            }
        }

        return .unknown
    }

    private static func normalizedHost(from browserURL: String?) -> String? {
        guard let browserURL = browserURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !browserURL.isEmpty,
              let url = URL(string: browserURL),
              let host = url.host?.lowercased(),
              !host.isEmpty else {
            return nil
        }
        return host
    }

    private static func isHost(_ host: String, _ apex: String) -> Bool {
        host == apex || host.hasSuffix("." + apex)
    }

    private static func isClaudeHost(_ host: String) -> Bool {
        isHost(host, "claude.ai") || isHost(host, "anthropic.com")
    }

    private static func isGoogleDocsHost(_ host: String) -> Bool {
        isHost(host, "docs.google.com")
    }

    private static func isGmailHost(_ host: String) -> Bool {
        isHost(host, "mail.google.com")
    }

    private static func isDiscordHost(_ host: String) -> Bool {
        isHost(host, "discord.com") || isHost(host, "discordapp.com")
    }

    private static func isLinkedInHost(_ host: String) -> Bool {
        isHost(host, "linkedin.com")
    }

    private static func isProtonMailHost(_ host: String) -> Bool {
        isHost(host, "mail.proton.me") || isHost(host, "protonmail.com")
    }

    private static func isWebMailClientHost(_ host: String) -> Bool {
        // Outlook (consumer + Microsoft 365)
        isHost(host, "outlook.live.com")
            || isHost(host, "outlook.office.com")
            || isHost(host, "outlook.office365.com")
            // Fastmail
            || isHost(host, "app.fastmail.com")
            // Yahoo Mail
            || isHost(host, "mail.yahoo.com")
            // Hey
            || isHost(host, "app.hey.com")
            // Tuta (formerly Tutanota)
            || isHost(host, "app.tuta.com")
            || isHost(host, "mail.tutanota.com")
            // Zoho Mail
            || isHost(host, "mail.zoho.com")
            || isHost(host, "mail.zoho.eu")
            // Canary Mail (web)
            || isHost(host, "canarymail.io")
    }

    private static func normalize(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }
}
