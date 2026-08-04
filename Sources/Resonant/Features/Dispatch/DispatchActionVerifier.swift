import AppKit
import Foundation

enum DispatchActionVerificationVerdict: String, Codable, Sendable, Equatable {
    case passed
    case failed
    case inconclusive

    var permitsLearning: Bool {
        self == .passed
    }
}

struct DispatchActionProbe: Sendable, Equatable {
    var capturedAt: Date
    var frontmostAppName: String?
    var frontmostBundleID: String?
    var focusedFieldContent: String?
    var clipboardString: String?
    var browserTitle: String?
    var browserURL: String?

    init(
        capturedAt: Date = Date(),
        frontmostAppName: String?,
        frontmostBundleID: String?,
        focusedFieldContent: String?,
        clipboardString: String?,
        browserTitle: String? = nil,
        browserURL: String? = nil
    ) {
        self.capturedAt = capturedAt
        self.frontmostAppName = frontmostAppName
        self.frontmostBundleID = frontmostBundleID
        self.focusedFieldContent = focusedFieldContent
        self.clipboardString = clipboardString
        self.browserTitle = browserTitle
        self.browserURL = browserURL
    }
}

struct DispatchActionVerification: Sendable, Equatable {
    var verdict: DispatchActionVerificationVerdict
    var summary: String
    var failureStage: DispatchFailureStage?
    var evidence: [String: String]

    var failed: Bool {
        verdict == .failed
    }
}

@MainActor
struct DispatchActionVerifier {
    private let pasteManager: PasteManager

    init(pasteManager: PasteManager) {
        self.pasteManager = pasteManager
    }

    func capture(contextPacket: ContextPacket?) -> DispatchActionProbe {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let browserContext = BrowserAutomationSupport.activeTabContext(
            bundleId: frontmost?.bundleIdentifier,
            allowUserPrompt: false
        )
        return DispatchActionProbe(
            frontmostAppName: frontmost?.localizedName,
            frontmostBundleID: frontmost?.bundleIdentifier,
            focusedFieldContent: pasteManager.focusedFieldContent(
                for: frontmost,
                windowTitle: contextPacket?.surface.windowTitle,
                browserURL: contextPacket?.surface.browserURL
            ),
            clipboardString: NSPasteboard.general.string(forType: .string),
            browserTitle: browserContext?.windowTitle,
            browserURL: browserContext?.browserURL
        )
    }

    func verify(
        action: CommandAction,
        route: DispatchRouteResolution,
        executionResult: CommandActionResult,
        before: DispatchActionProbe,
        contextPacket: ContextPacket?
    ) async -> DispatchActionVerification {
        try? await Task.sleep(for: .milliseconds(250))
        let after = capture(contextPacket: contextPacket)
        return Self.evaluate(
            action: action,
            route: route,
            executionResult: executionResult,
            before: before,
            after: after
        )
    }

    nonisolated static func evaluate(
        action: CommandAction,
        route: DispatchRouteResolution,
        executionResult: CommandActionResult,
        before: DispatchActionProbe,
        after: DispatchActionProbe
    ) -> DispatchActionVerification {
        var evidence = baseEvidence(route: route, executionResult: executionResult, before: before, after: after)

        guard executionResult.success else {
            return DispatchActionVerification(
                verdict: .failed,
                summary: "Execution failed before verification: \(executionResult.summary)",
                failureStage: .actionExecution,
                evidence: evidence
            )
        }

        switch action {
        case .typeText(let text, _):
            return verifyTextInsertion(text: text, route: route, before: before, after: after, evidence: evidence)

        case .openApp(let name):
            evidence["expected_app"] = name
            let afterSurface = DispatchAppSurfaceResolver.resolve(
                appName: after.frontmostAppName,
                bundleID: after.frontmostBundleID,
                browserTitle: after.browserTitle,
                browserURL: after.browserURL
            )
            let matched = DispatchAppSurfaceResolver.matches(expectedApp: name, surface: afterSurface)
            evidence["frontmost_app_matches_expected"] = matched ? "true" : "false"
            if matched {
                return passed("Verified \(name) is frontmost.", evidence: evidence)
            }
            if foregroundChanged(from: before, to: after) {
                return failed("Expected \(name) to be frontmost, found \(after.frontmostAppName ?? "unknown app").", evidence: evidence)
            }
            return inconclusive("Open-app request succeeded, but \(name) was not frontmost before the verification timeout.", evidence: evidence)

        case .createTicket(let title, let body, let service):
            let clipboard = after.clipboardString ?? ""
            evidence["expected_service"] = service.rawValue
            evidence["clipboard_contains_title"] = containsNormalized(clipboard, title) ? "true" : "false"
            evidence["clipboard_contains_body"] = body.isEmpty || containsNormalized(clipboard, body) ? "true" : "false"
            let pass = containsNormalized(clipboard, title)
                && (body.isEmpty || containsNormalized(clipboard, body))
            return pass
                ? passed("Verified \(service.rawValue) draft on clipboard.", evidence: evidence)
                : failed("Prepared ticket draft was not observable on the clipboard.", evidence: evidence)

        case .delegateToAgent(let agent, let prompt, _):
            let clipboard = after.clipboardString ?? ""
            evidence["expected_agent"] = agent.rawValue
            evidence["clipboard_contains_agent"] = containsNormalized(clipboard, "Agent: \(agent.rawValue)") ? "true" : "false"
            evidence["clipboard_contains_task_prompt"] = containsNormalized(clipboard, "Task prompt:") ? "true" : "false"
            evidence["clipboard_contains_prompt"] = containsNormalized(clipboard, prompt) ? "true" : "false"
            let pass = containsNormalized(clipboard, "Task prompt:")
                && containsNormalized(clipboard, prompt)
                && containsNormalized(clipboard, "Agent: \(agent.rawValue)")
            return pass
                ? passed("Verified \(agent.rawValue) task prompt on clipboard.", evidence: evidence)
                : inconclusive("Could not verify agent handoff from local clipboard state.", evidence: evidence)

        case .postSlack(_, let message):
            let clipboard = after.clipboardString ?? ""
            let afterSurface = DispatchAppSurfaceResolver.resolve(
                appName: after.frontmostAppName,
                bundleID: after.frontmostBundleID,
                browserTitle: after.browserTitle,
                browserURL: after.browserURL
            )
            evidence["expected_surface_app"] = DispatchAppSurfaceKind.slack.rawValue
            if containsNormalized(after.focusedFieldContent ?? "", message) {
                guard afterSurface.kind == .slack else {
                    return failed("Slack message text was inserted into \(afterSurface.label), not Slack.", evidence: evidence)
                }
                return passed("Verified Slack message text in the focused field.", evidence: evidence)
            }
            if containsNormalized(clipboard, message) {
                return passed("Verified Slack message text on clipboard.", evidence: evidence)
            }
            return inconclusive("Slack action succeeded, but local probes could not confirm the message target.", evidence: evidence)

        case .searchWorkspace, .speakAnswer:
            return passed("Verified background action completed successfully.", evidence: evidence)

        case .openURL(let url):
            return verifyOpenURL(expectedURL: url, before: before, after: after, evidence: evidence)

        case .composite:
            return executionResult.success
                ? inconclusive("Composite action succeeded, but per-step verification is not wired yet.", evidence: evidence)
                : failed("Composite action failed: \(executionResult.summary)", evidence: evidence)
        }
    }

    private nonisolated static func verifyTextInsertion(
        text: String,
        route: DispatchRouteResolution,
        before: DispatchActionProbe,
        after: DispatchActionProbe,
        evidence: [String: String]
    ) -> DispatchActionVerification {
        var evidence = evidence
        evidence["expected_text_length"] = "\(text.count)"

        guard let afterText = after.focusedFieldContent, !afterText.isEmpty else {
            return inconclusive("Text delivery succeeded, but the focused field could not be read back.", evidence: evidence)
        }

        let containsInsertedText = containsNormalized(afterText, text)
        let changed = before.focusedFieldContent.map { normalized(afterText) != normalized($0) } ?? true
        evidence["focused_field_contains_inserted_text"] = containsInsertedText ? "true" : "false"
        evidence["focused_field_changed"] = changed ? "true" : "false"

        if containsInsertedText {
            guard changed else {
                return inconclusive("Text delivery succeeded, but the focused field was unchanged after delivery.", evidence: evidence)
            }
            if let notificationIssue = notificationCorrelationIssue(route: route, after: after) {
                evidence["notification_correlation"] = "failed"
                evidence["notification_correlation_issue"] = notificationIssue
                return failed(notificationIssue, evidence: evidence)
            }
            if isNotificationReply(route: route) {
                evidence["notification_correlation"] = "passed"
            }
            return passed("Verified inserted text in the focused field.", evidence: evidence)
        }
        return failed("Focused field did not contain the inserted text after delivery.", evidence: evidence)
    }

    private nonisolated static func verifyOpenURL(
        expectedURL: String,
        before: DispatchActionProbe,
        after: DispatchActionProbe,
        evidence: [String: String]
    ) -> DispatchActionVerification {
        var evidence = evidence
        evidence["expected_url"] = expectedURL
        evidence["after_browser_url"] = after.browserURL ?? ""
        evidence["after_browser_title"] = after.browserTitle ?? ""

        guard let expected = normalizedURLComponents(expectedURL) else {
            return failed("Open URL action had an invalid expected URL.", evidence: evidence)
        }
        guard let actualURL = after.browserURL,
              let actual = normalizedURLComponents(actualURL) else {
            return inconclusive("URL open request succeeded, but active browser tab URL could not be read.", evidence: evidence)
        }

        let hostMatches = actual.host == expected.host
        let pathMatches = expected.path.isEmpty || actual.path == expected.path || actual.path.hasPrefix(expected.path)
        evidence["browser_host_matches_expected"] = hostMatches ? "true" : "false"
        evidence["browser_path_matches_expected"] = pathMatches ? "true" : "false"

        if hostMatches && pathMatches {
            return passed("Verified active browser tab opened \(expected.host).", evidence: evidence)
        }
        if browserURLChanged(from: before, to: after) {
            return failed("Expected browser tab \(expected.host), found \(actual.host).", evidence: evidence)
        }
        return inconclusive("URL open request succeeded, but active browser tab did not change before the verification timeout.", evidence: evidence)
    }

    private nonisolated static func baseEvidence(
        route: DispatchRouteResolution,
        executionResult: CommandActionResult,
        before: DispatchActionProbe,
        after: DispatchActionProbe
    ) -> [String: String] {
        let beforeSurface = DispatchAppSurfaceResolver.resolve(
            appName: before.frontmostAppName,
            bundleID: before.frontmostBundleID,
            browserTitle: before.browserTitle,
            browserURL: before.browserURL
        )
        let afterSurface = DispatchAppSurfaceResolver.resolve(
            appName: after.frontmostAppName,
            bundleID: after.frontmostBundleID,
            browserTitle: after.browserTitle,
            browserURL: after.browserURL
        )
        var evidence: [String: String] = [:]
        evidence["route_id"] = route.card.id
        evidence["route_source"] = route.source.rawValue
        evidence["execution_success"] = executionResult.success ? "true" : "false"
        evidence["before_frontmost_app"] = before.frontmostAppName ?? ""
        evidence["before_frontmost_bundle_id"] = before.frontmostBundleID ?? ""
        evidence["after_frontmost_app"] = after.frontmostAppName ?? ""
        evidence["after_frontmost_bundle_id"] = after.frontmostBundleID ?? ""
        evidence["before_field_length"] = "\(before.focusedFieldContent?.count ?? 0)"
        evidence["after_field_length"] = "\(after.focusedFieldContent?.count ?? 0)"
        evidence["before_clipboard_length"] = "\(before.clipboardString?.count ?? 0)"
        evidence["after_clipboard_length"] = "\(after.clipboardString?.count ?? 0)"
        evidence["before_browser_url"] = before.browserURL ?? ""
        evidence["after_browser_url"] = after.browserURL ?? ""
        evidence["before_surface_app"] = beforeSurface.kind.rawValue
        evidence["before_surface_variant"] = beforeSurface.variant.rawValue
        evidence["before_surface_label"] = beforeSurface.label
        evidence["after_surface_app"] = afterSurface.kind.rawValue
        evidence["after_surface_variant"] = afterSurface.variant.rawValue
        evidence["after_surface_label"] = afterSurface.label
        return evidence
    }

    private nonisolated static func passed(_ summary: String, evidence: [String: String]) -> DispatchActionVerification {
        DispatchActionVerification(verdict: .passed, summary: summary, failureStage: nil, evidence: evidence)
    }

    private nonisolated static func failed(_ summary: String, evidence: [String: String]) -> DispatchActionVerification {
        DispatchActionVerification(verdict: .failed, summary: summary, failureStage: .verification, evidence: evidence)
    }

    private nonisolated static func inconclusive(_ summary: String, evidence: [String: String]) -> DispatchActionVerification {
        DispatchActionVerification(verdict: .inconclusive, summary: summary, failureStage: nil, evidence: evidence)
    }

    private nonisolated static func foregroundChanged(from before: DispatchActionProbe, to after: DispatchActionProbe) -> Bool {
        let beforeKey = normalizedToken([before.frontmostAppName, before.frontmostBundleID].compactMap { $0 }.joined(separator: " "))
        let afterKey = normalizedToken([after.frontmostAppName, after.frontmostBundleID].compactMap { $0 }.joined(separator: " "))
        return !afterKey.isEmpty && beforeKey != afterKey
    }

    private nonisolated static func browserURLChanged(from before: DispatchActionProbe, to after: DispatchActionProbe) -> Bool {
        normalized(before.browserURL ?? "") != normalized(after.browserURL ?? "")
            && !(after.browserURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private nonisolated static func normalizedURLComponents(_ rawURL: String) -> (host: String, path: String)? {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: withScheme),
              let host = url.host(percentEncoded: false)?.lowercased(),
              !host.isEmpty else {
            return nil
        }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        return (host, path)
    }

    private nonisolated static func isNotificationReply(route: DispatchRouteResolution) -> Bool {
        route.evidence.contains { $0.localizedCaseInsensitiveContains("Recent notification:") }
    }

    private nonisolated static func notificationCorrelationIssue(
        route: DispatchRouteResolution,
        after: DispatchActionProbe
    ) -> String? {
        guard let notificationLine = route.evidence.first(where: { $0.localizedCaseInsensitiveContains("Recent notification:") }) else {
            return nil
        }

        let notificationKind = DispatchAppSurfaceResolver.kindMentioned(in: notificationLine)
        let afterSurface = DispatchAppSurfaceResolver.resolve(
            appName: after.frontmostAppName,
            bundleID: after.frontmostBundleID,
            browserTitle: after.browserTitle,
            browserURL: after.browserURL
        )
        if let notificationKind, afterSurface.kind != notificationKind {
            return "Reply text was inserted, but the active surface was \(afterSurface.label), not \(notificationKind.rawValue)."
        }

        let notificationIdentifiers = notificationConversationIdentifiers(in: route.evidence)
        if !notificationIdentifiers.isEmpty {
            let currentIdentifiers = DispatchNotificationCorrelation.conversationIdentifiers(in: [
                after.browserTitle,
                after.browserURL
            ])
            switch DispatchNotificationCorrelation.matches(
                notificationIdentifiers: notificationIdentifiers,
                currentIdentifiers: currentIdentifiers
            ) {
            case true:
                return nil
            case false:
                return "Reply text was inserted, but the active conversation did not match the recent notification."
            case nil:
                return "Reply text was inserted, but the active notification conversation could not be verified."
            }
        }

        if notificationKind != nil {
            return nil
        }

        let normalizedNotification = normalized(notificationLine)
        let currentSurface = normalized([
            after.frontmostAppName,
            after.frontmostBundleID,
            after.browserURL,
            after.browserTitle
        ].compactMap { $0 }.joined(separator: " "))
        guard !currentSurface.isEmpty else {
            return "Reply text was inserted, but the current notification surface could not be read."
        }

        let importantTokens = normalizedNotification
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { token in
                token.count >= 4 && !["recent", "notification", "that", "from", "with", "message", "saying"].contains(token)
            }
        guard !importantTokens.isEmpty else { return nil }
        let matched = importantTokens.contains { currentSurface.contains($0) }
        return matched ? nil : "Reply text was inserted, but the active surface did not match the recent notification evidence."
    }

    private nonisolated static func notificationConversationIdentifiers(in evidence: [String]) -> Set<String> {
        evidence.reduce(into: Set<String>()) { result, line in
            if line.localizedCaseInsensitiveContains("Notification conversation:") {
                result.formUnion(DispatchNotificationCorrelation.conversationIdentifiers(in: line))
            } else if line.localizedCaseInsensitiveContains("Recent notification:") {
                result.formUnion(DispatchNotificationCorrelation.conversationIdentifiers(
                    in: line,
                    allowLooseIdentifiers: false
                ))
            }
        }
    }

    private nonisolated static func containsNormalized(_ haystack: String, _ needle: String) -> Bool {
        let normalizedHaystack = normalized(haystack)
        let normalizedNeedle = normalized(needle)
        guard !normalizedNeedle.isEmpty else { return true }
        return normalizedHaystack.contains(normalizedNeedle)
    }

    private nonisolated static func normalized(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func normalizedToken(_ value: String) -> String {
        normalized(value)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined()
    }
}
