import Foundation

enum AccessibilityPlaceholderFilter {
    static let codexBundleID = "com.openai.codex"

    private static let codexPlaceholderValues: Set<String> = [
        "Ask for follow-up changes",
        "Ask Codex anything, @ to add files, / for commands",
        "Ask Codex anything, @ to add files, / for commands, $ for skills",
    ]

    static func shouldBypassAXValueInsertion(
        bundleID: String?,
        windowTitle: String? = nil,
        browserURL: String? = nil
    ) -> Bool {
        TextInputTargetProfile(
            bundleID: bundleID,
            windowTitle: windowTitle,
            browserURL: browserURL
        ).bypassesAXValueInsertion
    }

    static func shouldBypassCorrectionReadback(
        bundleID: String?,
        windowTitle: String? = nil,
        browserURL: String? = nil
    ) -> Bool {
        TextInputTargetProfile(
            bundleID: bundleID,
            windowTitle: windowTitle,
            browserURL: browserURL
        ).bypassesCorrectionReadback
    }

    static func sanitizeFocusedFieldValue(
        _ value: String,
        bundleID: String?,
        windowTitle: String? = nil,
        browserURL: String? = nil,
        placeholderValue: String? = nil
    ) -> String {
        let profile = TextInputTargetProfile(
            bundleID: bundleID,
            windowTitle: windowTitle,
            browserURL: browserURL
        )
        if placeholderMatchesValue(value, placeholderValue: placeholderValue) {
            return ""
        }
        return isKnownPlaceholder(value, profile: profile) ? "" : value
    }

    static func shouldKeepVisibleSnippet(
        _ value: String,
        bundleID: String?,
        windowTitle: String? = nil,
        browserURL: String? = nil
    ) -> Bool {
        let profile = TextInputTargetProfile(
            bundleID: bundleID,
            windowTitle: windowTitle,
            browserURL: browserURL
        )
        return !isKnownPlaceholder(value, profile: profile)
    }

    private static func isKnownPlaceholder(
        _ value: String,
        profile: TextInputTargetProfile
    ) -> Bool {
        let normalized = normalize(value)
        guard !normalized.isEmpty else { return false }

        switch profile.kind {
        case .codexApp, .cmuxApp:
            return isKnownCodexPlaceholder(normalized)
        case .claudeWeb:
            return isKnownClaudeReplyPlaceholder(normalized)
        case .unknown, .terminalApp, .electronEditorApp, .firefoxEngineBrowser, .discordDesktop, .discordWeb, .googleDocsWeb, .gmailWeb, .protonMailWeb, .webMailClient, .linkedInWeb:
            return false
        }
    }

    private static func isKnownCodexPlaceholder(_ normalized: String) -> Bool {
        if codexPlaceholderValues.contains(normalized) {
            return true
        }

        return normalized.hasPrefix("Ask Codex anything")
            && normalized.contains("@ to add files")
            && normalized.contains("/ for commands")
    }

    private static func isKnownClaudeReplyPlaceholder(_ normalized: String) -> Bool {
        let lowercased = normalized.lowercased()
        if lowercased == "reply"
            || lowercased == "reply..."
            || lowercased == "reply…" {
            return true
        }

        return lowercased.hasPrefix("reply") && lowercased.contains("claude")
    }

    private static func placeholderMatchesValue(_ value: String, placeholderValue: String?) -> Bool {
        guard let placeholderValue else { return false }
        return normalize(value) == normalize(placeholderValue)
    }

    private static func normalize(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
