import Foundation
import SwiftUI

/// One searchable entry in the settings index — either a whole settings page
/// or a specific section/item inside a page.
struct SettingsSearchEntry: Identifiable, Hashable {
    let id: String
    let title: String
    /// Synonyms / extra terms to match against (not displayed).
    let keywords: [String]
    let tab: SettingsTab
    /// When non-nil, scrolls the destination tab to a section with this id
    /// (the section view must tag itself with `.id(anchor)`).
    let anchor: String?
    /// Optional override icon; falls back to the tab icon.
    let iconOverride: String?

    var icon: String { iconOverride ?? tab.icon }

    /// Page-level entry (no anchor): selecting this just navigates to the tab.
    init(
        title: String,
        keywords: [String] = [],
        tab: SettingsTab,
        icon: String? = nil
    ) {
        self.id = "page:\(tab.rawValue)"
        self.title = title
        self.keywords = keywords
        self.tab = tab
        self.anchor = nil
        self.iconOverride = icon
    }

    /// Item-level entry (anchor scrolls to a specific section in the tab).
    init(
        title: String,
        keywords: [String] = [],
        tab: SettingsTab,
        anchor: String,
        icon: String? = nil
    ) {
        self.id = "item:\(tab.rawValue):\(anchor)"
        self.title = title
        self.keywords = keywords
        self.tab = tab
        self.anchor = anchor
        self.iconOverride = icon
    }

    /// Display label for the page this entry belongs to.
    var pageLabel: String { tab.displayName }

    /// True for whole-page results; used to badge them differently.
    var isPage: Bool { anchor == nil }
}

// MARK: - Anchor IDs

/// Stable string IDs for scrollable sections inside settings tabs.
/// Tab views tag sections with `.id(SettingsAnchor.xxx)` and the search
/// uses these as anchor values.
enum SettingsAnchor {
    // MeetingSettingsView (Recording tab)
    static let meetingRecording          = "meeting.recording"
    static let meetingHowItWorks         = "meeting.howItWorks"
    static let meetingTranscriptionModel = "meeting.transcriptionModel"
    static let meetingSpeakerModel       = "meeting.speakerModel"
    static let meetingAutomation         = "meeting.automation"
    static let meetingAIFeatures         = "meeting.aiFeatures"
    static let meetingPrivacy            = "meeting.privacy"
    static let meetingWebhooks           = "meeting.webhooks"

    // APICLITabView
    static let apiToggle  = "api.toggle"
    static let apiConnect = "api.connect"

    // MCPServerTabView
    static let mcpToggle = "mcp.toggle"
    static let mcpConfig = "mcp.config"

    // WorkspaceTabView
    static let workspaceStorage = "workspace.storage"
    static let workspaceArchive = "workspace.archive"
    static let workspaceCloud   = "workspace.cloud"
    static let workspacePrivacy = "workspace.privacy"
    static let workspaceReset   = "workspace.reset"

    // DictationTabView
    static let dictationHotkey         = "dictation.hotkey"
    static let dictationTextProcessing = "dictation.textProcessing"
    static let dictationOutput         = "dictation.output"
    static let dictationAudio          = "dictation.audio"
    static let dictationLanguage       = "dictation.language"

    // WritingTabView
    static let writingCleanup = "writing.cleanup"
    static let writingEmail   = "writing.email"
    static let writingAids    = "writing.aids"

    // AdvancedTabView
    static let advancedModel    = "advanced.model"
    static let advancedLanguage = "advanced.language"

    // AccountTabView
    static let accountIdentity    = "account.identity"
    static let accountGeneral     = "account.general"
    static let accountBeta        = "account.beta"
    static let accountOnboarding  = "account.onboarding"
    static let accountDiagnostics = "account.diagnostics"
    static let accountSignOut     = "account.signOut"

    // AppearanceTabView
    static let appearanceNotch = "appearance.notch"
    static let appearanceSound = "appearance.sound"
}

// MARK: - Index

enum SettingsSearchIndex {
    /// All searchable entries across the settings UI. Order is the default
    /// ordering for results when the query is empty (used for ranking ties).
    static var entries: [SettingsSearchEntry] {
        baseEntries.filter { entry in
            guard entry.tab.isAvailable else { return false }
            if !AppFeatureVisibility.hostedServices {
                let hostedAnchors = [
                    SettingsAnchor.accountIdentity,
                    SettingsAnchor.accountSignOut,
                    SettingsAnchor.meetingAIFeatures
                ]
                if let anchor = entry.anchor, hostedAnchors.contains(anchor) {
                    return false
                }
            }
            return true
        }
    }

    private static let baseEntries: [SettingsSearchEntry] = [
        // MARK: Pages
        SettingsSearchEntry(
            title: "General",
            keywords: ["sign in", "sign out", "log out", "email", "profile", "user"],
            tab: .account
        ),
        SettingsSearchEntry(
            title: "Privacy",
            keywords: ["folder", "directory", "storage", "files", "vault", "privacy"],
            tab: .workspace
        ),
        SettingsSearchEntry(
            title: "MCP Server",
            keywords: ["mcp", "model context protocol", "claude", "tools"],
            tab: .mcpServer
        ),
        SettingsSearchEntry(
            title: "Local API",
            keywords: ["http", "endpoint", "developer", "curl", "rest", "automation"],
            tab: .apiCli
        ),
        SettingsSearchEntry(
            title: "Models & Language",
            keywords: ["model", "language", "parakeet", "qwen", "cohere", "transcription", "locale"],
            tab: .models
        ),
        SettingsSearchEntry(
            title: "Advanced",
            keywords: ["developer", "integrations", "debug"],
            tab: .advanced
        ),
        SettingsSearchEntry(
            title: "Dictation",
            keywords: ["voice", "transcribe", "mic", "microphone", "speech", "stt", "whisper", "parakeet", "start key", "live transcript", "preview", "streaming"],
            tab: .dictation
        ),
        SettingsSearchEntry(
            title: "Writing",
            keywords: ["cleanup", "punctuation", "email", "signature", "dictionary", "smart links", "style"],
            tab: .writing
        ),
        SettingsSearchEntry(
            title: "Personalization",
            keywords: ["learned terms", "formatting", "casing", "suppress", "restore", "memory", "cloud correction examples", "snippets", "redaction", "HIPAA"],
            tab: .personalization
        ),
        SettingsSearchEntry(
            title: "Dictionary",
            keywords: ["custom words", "vocabulary", "spelling", "names", "boost", "recognition", "contacts", "import names"],
            tab: .dictionary
        ),
        SettingsSearchEntry(
            title: "Smart Links",
            keywords: ["url", "link", "expand", "shortcuts"],
            tab: .smartLinks
        ),
        SettingsSearchEntry(
            title: "Meetings",
            keywords: ["meetings", "meeting", "calls", "video", "zoom", "google meet", "teams"],
            tab: .meetingSettings
        ),
        SettingsSearchEntry(
            title: "Appearance",
            keywords: ["theme", "color", "dark mode", "light mode", "ui", "look"],
            tab: .appearance
        ),
        SettingsSearchEntry(
            title: "Progression",
            keywords: ["streaks", "trophy", "stats", "achievements", "goals"],
            tab: .progression
        ),
        SettingsSearchEntry(
            title: "Help & Support",
            keywords: ["contact", "feedback", "bug", "support", "documentation", "docs"],
            tab: .support
        ),

        // MARK: Recording (MeetingSettingsView) items
        SettingsSearchEntry(
            title: "Enable Meeting Recording",
            keywords: ["start recording", "record meeting", "turn on"],
            tab: .meetingSettings,
            anchor: SettingsAnchor.meetingRecording,
            icon: "record.circle.fill"
        ),
        SettingsSearchEntry(
            title: "How meetings work",
            keywords: ["overview", "explanation", "intro"],
            tab: .meetingSettings,
            anchor: SettingsAnchor.meetingHowItWorks,
            icon: "info.circle.fill"
        ),
        SettingsSearchEntry(
            title: "Transcription model",
            keywords: ["parakeet", "qwen", "qwen3", "cohere", "backend", "engine", "stt"],
            tab: .meetingAdvanced,
            anchor: SettingsAnchor.meetingTranscriptionModel,
            icon: "cpu"
        ),
        SettingsSearchEntry(
            title: "Room speaker model",
            keywords: ["speaker", "speakers", "room mode", "diarization", "sortformer", "separation"],
            tab: .meetingAdvanced,
            anchor: SettingsAnchor.meetingSpeakerModel,
            icon: "person.2.wave.2.fill"
        ),
        SettingsSearchEntry(
            title: "Meeting automation",
            keywords: ["auto-start", "auto-stop", "join prompt", "calendar hints", "automatic"],
            tab: .meetingSettings,
            anchor: SettingsAnchor.meetingAutomation,
            icon: "wand.and.stars"
        ),
        SettingsSearchEntry(
            title: "Meeting summaries",
            keywords: ["ai summary", "summarize", "action items", "key decisions", "ai features"],
            tab: .meetingSettings,
            anchor: SettingsAnchor.meetingAIFeatures,
            icon: "sparkles"
        ),
        SettingsSearchEntry(
            title: "Meeting transcript emails",
            keywords: ["email transcript", "email meeting", "send to myself", "call link", "post-meeting email"],
            tab: .meetingSettings,
            anchor: SettingsAnchor.meetingAIFeatures,
            icon: "envelope"
        ),
        SettingsSearchEntry(
            title: "Meeting privacy",
            keywords: ["data", "on-device", "local", "encryption", "save meeting audio"],
            tab: .meetingSettings,
            anchor: SettingsAnchor.meetingPrivacy,
            icon: "lock.shield.fill"
        ),
        SettingsSearchEntry(
            title: "Meeting webhooks",
            keywords: ["zapier", "post", "callback", "integration", "notify", "webhook"],
            tab: .meetingAdvanced,
            anchor: SettingsAnchor.meetingWebhooks,
            icon: "arrow.turn.up.right"
        ),
        SettingsSearchEntry(
            title: "Meeting transcription model",
            keywords: ["deepgram", "cohere", "nova", "parakeet", "qwen", "cloud transcription", "meeting model"],
            tab: .meetingAdvanced,
            anchor: SettingsAnchor.meetingTranscriptionModel,
            icon: "waveform"
        ),

        // MARK: API items
        SettingsSearchEntry(
            title: "Enable local API",
            keywords: ["http server", "port", "localhost", "127.0.0.1"],
            tab: .apiCli,
            anchor: SettingsAnchor.apiToggle,
            icon: "power"
        ),
        SettingsSearchEntry(
            title: "API base URL & token",
            keywords: ["curl", "bearer", "authorization", "endpoint", "example"],
            tab: .apiCli,
            anchor: SettingsAnchor.apiConnect,
            icon: "link"
        ),

        // MARK: MCP items
        SettingsSearchEntry(
            title: "Enable MCP server",
            keywords: ["mcp toggle", "claude code", "cursor", "windsurf"],
            tab: .mcpServer,
            anchor: SettingsAnchor.mcpToggle,
            icon: "power"
        ),
        SettingsSearchEntry(
            title: "MCP config snippet",
            keywords: ["yaml", "config", "paste", "manual setup"],
            tab: .mcpServer,
            anchor: SettingsAnchor.mcpConfig,
            icon: "doc.on.doc"
        ),

        // MARK: Workspace items
        SettingsSearchEntry(
            title: "Storage & retention",
            keywords: ["save audio", "history", "retention", "30 days", "90 days", "180 days", "forever"],
            tab: .workspace,
            anchor: SettingsAnchor.workspaceStorage,
            icon: "internaldrive"
        ),
        SettingsSearchEntry(
            title: "Local archive folder",
            keywords: ["finder", "obsidian", "markdown", "export", "vault folder", "meetings", "transcripts"],
            tab: .workspace,
            anchor: SettingsAnchor.workspaceArchive,
            icon: "archivebox.fill"
        ),
        SettingsSearchEntry(
            title: "Context & ambient",
            keywords: ["app context", "window title", "ambient", "url", "excluded apps", "passwords"],
            tab: .workspace,
            anchor: SettingsAnchor.workspacePrivacy,
            icon: "eye.slash.fill"
        ),
        SettingsSearchEntry(
            title: "Clear workspace data",
            keywords: ["delete", "reset", "wipe", "destructive"],
            tab: .workspace,
            anchor: SettingsAnchor.workspaceReset,
            icon: "trash.fill"
        ),

        // MARK: Dictation items
        SettingsSearchEntry(
            title: "Hotkey & start mode",
            keywords: ["push to talk", "hold", "toggle", "key", "fn", "right option", "shortcut", "lock", "spacebar"],
            tab: .dictation,
            anchor: SettingsAnchor.dictationHotkey,
            icon: "keyboard"
        ),
        SettingsSearchEntry(
            title: "Text processing",
            keywords: ["filler", "false starts", "punctuation", "itn", "numbers", "bullet points", "selection transform"],
            tab: .writing,
            anchor: SettingsAnchor.writingCleanup,
            icon: "text.alignleft"
        ),
        SettingsSearchEntry(
            title: "Polish level",
            keywords: ["polish", "verbatim", "clean", "polished", "rewrite", "rephrase", "tone", "style", "cleanup strength"],
            tab: .writing,
            anchor: SettingsAnchor.writingCleanup,
            icon: "wand.and.stars"
        ),
        SettingsSearchEntry(
            title: "Output",
            keywords: ["auto-paste", "clipboard", "auto-send", "paste method", "paste reliability"],
            tab: .dictation,
            anchor: SettingsAnchor.dictationOutput,
            icon: "arrow.up.right.square"
        ),
        SettingsSearchEntry(
            title: "Email footer and sign-off",
            keywords: ["email signature", "sent with resonant", "footer", "sign-off", "signoff"],
            tab: .writing,
            anchor: SettingsAnchor.writingEmail,
            icon: "envelope.fill"
        ),
        SettingsSearchEntry(
            title: "Writing aids",
            keywords: ["dictionary", "smart links", "personalization", "custom words", "replace phrases"],
            tab: .writing,
            anchor: SettingsAnchor.writingAids,
            icon: "text.append"
        ),
        SettingsSearchEntry(
            title: "Microphone & audio",
            keywords: ["mic", "input device", "hot mic", "hot word", "duck", "pause music", "low latency"],
            tab: .dictation,
            anchor: SettingsAnchor.dictationAudio,
            icon: "mic.circle.fill"
        ),
        SettingsSearchEntry(
            title: "Transcription model",
            keywords: ["parakeet", "qwen", "cohere", "stt", "backend", "engine"],
            tab: .models,
            anchor: SettingsAnchor.advancedModel,
            icon: "cpu"
        ),
        SettingsSearchEntry(
            title: "Transcription language",
            keywords: ["english", "swedish", "auto-detect", "language", "locale"],
            tab: .models,
            anchor: SettingsAnchor.advancedLanguage,
            icon: "globe"
        ),

        // MARK: Account items
        SettingsSearchEntry(
            title: "Email",
            keywords: ["account", "profile", "user", "sign in"],
            tab: .account,
            anchor: SettingsAnchor.accountIdentity,
            icon: "person.crop.circle"
        ),
        SettingsSearchEntry(
            title: "Launch at login",
            keywords: ["startup", "boot", "auto launch", "login items"],
            tab: .account,
            anchor: SettingsAnchor.accountGeneral,
            icon: "power"
        ),
        SettingsSearchEntry(
            title: "Beta program",
            keywords: ["beta tester", "early access", "preview features"],
            tab: .account,
            anchor: SettingsAnchor.accountBeta,
            icon: "flask.fill"
        ),
        SettingsSearchEntry(
            title: "Reopen onboarding",
            keywords: ["tour", "permissions", "setup", "intro", "walkthrough"],
            tab: .account,
            anchor: SettingsAnchor.accountOnboarding,
            icon: "arrow.counterclockwise.circle"
        ),
        SettingsSearchEntry(
            title: "Diagnostics & analytics",
            keywords: ["crash", "telemetry", "posthog", "sentry", "tracking", "privacy", "opt out"],
            tab: .account,
            anchor: SettingsAnchor.accountDiagnostics,
            icon: "chart.bar.xaxis"
        ),
        SettingsSearchEntry(
            title: "Sign out",
            keywords: ["log out", "logout", "session"],
            tab: .account,
            anchor: SettingsAnchor.accountSignOut,
            icon: "rectangle.portrait.and.arrow.right"
        ),

        // MARK: Appearance items
        SettingsSearchEntry(
            title: "Notch & overlay",
            keywords: ["menu bar", "hide notch", "idle", "minimal", "expanded", "overlay", "popups", "warnings", "no speech", "clipboard"],
            tab: .appearance,
            anchor: SettingsAnchor.appearanceNotch,
            icon: "rectangle.topthird.inset.filled"
        ),
        SettingsSearchEntry(
            title: "Sounds & volume",
            keywords: ["audio cues", "confirmation sound", "chime", "volume"],
            tab: .appearance,
            anchor: SettingsAnchor.appearanceSound,
            icon: "speaker.wave.2.fill"
        ),

    ]

    /// Filter and rank entries against a query. Empty query returns [].
    static func search(_ rawQuery: String, limit: Int = 12) -> [SettingsSearchEntry] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }

        // Score: title prefix > title contains > pageLabel contains > keyword contains.
        var scored: [(entry: SettingsSearchEntry, score: Int)] = []
        for entry in entries {
            let title = entry.title.lowercased()
            let page = entry.pageLabel.lowercased()
            var score = 0
            if title == query { score = 1000 }
            else if title.hasPrefix(query) { score = 800 }
            else if title.contains(query) { score = 600 }
            else if page.hasPrefix(query) { score = 500 }
            else if page.contains(query) { score = 400 }
            else if entry.keywords.contains(where: { $0.lowercased().contains(query) }) {
                score = 250
            }
            // Tiny boost for page-level entries so "API" surfaces the page first.
            if entry.isPage { score += 25 }
            if score > 0 {
                scored.append((entry, score))
            }
        }

        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.entry.title < rhs.entry.title
        }

        return scored.prefix(limit).map(\.entry)
    }
}

// MARK: - Anchor scroll modifier

private struct SettingsScrollAnchorHandler: ViewModifier {
    @Environment(AppState.self) private var appState
    let proxy: ScrollViewProxy

    func body(content: Content) -> some View {
        content
            .onAppear { applyPendingAnchor() }
            .onChange(of: appState.settingsScrollAnchor) { _, _ in
                applyPendingAnchor()
            }
    }

    private func applyPendingAnchor() {
        guard let anchor = appState.settingsScrollAnchor else { return }
        // Defer so the destination tab, and any disclosure rows it expands for
        // search, can mount their section ids before we ask the proxy to scroll.
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                guard appState.settingsScrollAnchor == anchor else { return }
                proxy.scrollTo(anchor, anchor: .top)
                DispatchQueue.main.async {
                    guard appState.settingsScrollAnchor == anchor else { return }
                    appState.settingsScrollAnchor = nil
                }
            }
        }
    }
}

extension View {
    /// Attach to the scrollable container in a settings tab so it responds to
    /// `appState.settingsScrollAnchor` (set by the settings search field) by
    /// scrolling to the matching section id and clearing the request.
    func settingsScrollAnchorHandler(proxy: ScrollViewProxy) -> some View {
        modifier(SettingsScrollAnchorHandler(proxy: proxy))
    }
}
