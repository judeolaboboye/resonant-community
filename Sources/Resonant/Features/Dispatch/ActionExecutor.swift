import AppKit
import Foundation

/// Executes `CommandAction`s using existing Resonant infrastructure.
/// Each action maps to concrete macOS APIs already available in the app.
@MainActor
final class ActionExecutor {

    private let pasteManager: PasteManager
    private let dataStore: DataStore
    private let voiceFeedback: VoiceFeedback
    private var currentProcess: Process?

    init(pasteManager: PasteManager, dataStore: DataStore, voiceFeedback: VoiceFeedback) {
        self.pasteManager = pasteManager
        self.dataStore = dataStore
        self.voiceFeedback = voiceFeedback
    }

    func cancel() {
        if currentProcess?.isRunning == true {
            currentProcess?.terminate()
        }
        currentProcess = nil
        voiceFeedback.stop()
    }

    func execute(_ action: CommandAction) async -> CommandActionResult {
        switch action {
        case .typeText(let text, let appHint):
            return await executeTypeText(text: text, appHint: appHint)

        case .openURL(let urlString):
            return executeOpenURL(urlString: urlString)

        case .openApp(let name):
            return await executeOpenApp(name: name)

        case .searchWorkspace(let query):
            return await executeSearchWorkspace(query: query)

        case .speakAnswer(let text):
            return await executeSpeakAnswer(text: text)

        case .createTicket(let title, let body, let service):
            return await executeCreateTicket(title: title, body: body, service: service)

        case .postSlack(let channel, let message):
            return await executePostSlack(channel: channel, message: message)

        case .delegateToAgent(let agent, let prompt, let context):
            return await executeDelegateToAgent(agent: agent, prompt: prompt, context: context)

        case .composite(let actions):
            return await executeComposite(actions)
        }
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Type text

    private func executeTypeText(text: String, appHint: String?) async -> CommandActionResult {
        let targetApp: NSRunningApplication?
        if let appHint {
            targetApp = NSWorkspace.shared.runningApplications.first {
                $0.localizedName?.lowercased().contains(appHint.lowercased()) == true
            } ?? NSWorkspace.shared.frontmostApplication
        } else {
            targetApp = NSWorkspace.shared.frontmostApplication
        }

        let delivered = await pasteManager.deliver(
            text: text,
            copyToClipboard: true,
            autoPaste: true,
            autoSend: false,
            targetApplication: targetApp,
            deliveryMode: .automatic
        )

        let appName = targetApp?.localizedName ?? "the active app"
        if delivered {
            return .ok("Typed into \(appName)")
        } else {
            return .failed("Failed to type into \(appName)")
        }
    }

    // MARK: - Open URL

    private func executeOpenURL(urlString: String) -> CommandActionResult {
        guard let url = URL(string: urlString) else {
            return .failed("Invalid URL: \(urlString)")
        }
        guard NSWorkspace.shared.open(url) else {
            return .failed("Could not open \(url.host ?? urlString)")
        }
        return .ok("Opened \(url.host ?? urlString)")
    }

    // MARK: - Open app

    private func executeOpenApp(name: String) async -> CommandActionResult {
        let workspace = NSWorkspace.shared

        // Try to activate an already-running app first
        if let running = workspace.runningApplications.first(where: {
            $0.localizedName?.lowercased() == name.lowercased()
        }) {
            if running.activate() {
                return .ok("Switched to \(running.localizedName ?? name)")
            }
            return .failed("Could not switch to \(running.localizedName ?? name)")
        }

        // Try to open by name from /Applications
        let appURL = URL(fileURLWithPath: "/Applications/\(name).app")
        if FileManager.default.fileExists(atPath: appURL.path) {
            return await withCheckedContinuation { continuation in
                workspace.openApplication(
                    at: appURL,
                    configuration: NSWorkspace.OpenConfiguration()
                ) { app, error in
                    if let error {
                        continuation.resume(returning: .failed("Could not open \(name)", detail: error.localizedDescription))
                    } else if app != nil {
                        continuation.resume(returning: .ok("Opened \(name)"))
                    } else {
                        continuation.resume(returning: .failed("Could not open \(name)"))
                    }
                }
            }
        }

        // Try Spotlight-style open
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", name]
        do {
            currentProcess = task
            try task.run()
            let status = await waitForTaskExit(task)
            currentProcess = nil
            if status == 0 {
                return .ok("Opened \(name)")
            }
            return .failed("Could not open \(name)", detail: "`open -a \(name)` exited with status \(status).")
        } catch {
            currentProcess = nil
            return .failed("Could not open \(name)", detail: error.localizedDescription)
        }
    }

    private func waitForTaskExit(_ task: Process) async -> Int32 {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                task.waitUntilExit()
                continuation.resume(returning: task.terminationStatus)
            }
        }
    }

    // MARK: - Search workspace

    private func executeSearchWorkspace(query: String) async -> CommandActionResult {
        let result = await WorkspaceTools.handle(
            tool: "search",
            arguments: ["query": .string(query), "limit": .int(5)],
            dataStore: dataStore
        )

        if result.isError {
            return .failed("Search failed", detail: result.errorMessage)
        }

        let items = result.payload.objectValue?["results"]?.arrayValue ?? []
        if items.isEmpty {
            return .ok("No results found for \"\(query)\"")
        }

        let summaries = items.prefix(3).compactMap { item -> String? in
            let obj = item.objectValue ?? [:]
            let type = obj["type"]?.stringValue ?? ""
            let text = obj["text"]?.stringValue ?? ""
            let preview = String(text.prefix(100))
            return "[\(type)] \(preview)"
        }

        return .ok(
            "Found \(items.count) results for \"\(query)\"",
            detail: summaries.joined(separator: "\n")
        )
    }

    // MARK: - Speak answer

    private func executeSpeakAnswer(text: String) async -> CommandActionResult {
        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else {
            return .failed("No answer to speak")
        }

        return await withCheckedContinuation { (continuation: CheckedContinuation<CommandActionResult, Never>) in
            voiceFeedback.speak(answer) {
                continuation.resume(returning: .ok(answer))
            }
        }
    }

    // MARK: - Create ticket (Linear/GitHub via HTTP)

    private func executeCreateTicket(
        title: String,
        body: String,
        service: CommandAction.TicketService
    ) async -> CommandActionResult {
        // MVP: make prepared-only ticket actions visible by opening the target
        // surface and copying the draft. Direct creation still needs auth/API.
        switch service {
        case .linear:
            let detail = "Title: \(title)\nBody: \(body)"
            copyToClipboard(detail)
            let opened = await executeOpenApp(name: "Linear")
            if !opened.success, let url = URL(string: "https://linear.app") {
                NSWorkspace.shared.open(url)
            }
            return .ok(
                "Linear ticket ready: \(title)",
                detail: "\(detail)\n\nCopied draft to clipboard and opened Linear. Direct creation requires a Linear API integration."
            )
        case .github:
            let detail = "Title: \(title)\nBody: \(body)"
            copyToClipboard(detail)
            if let url = URL(string: "https://github.com/issues") {
                NSWorkspace.shared.open(url)
            }
            return .ok(
                "GitHub issue ready: \(title)",
                detail: "\(detail)\n\nCopied draft to clipboard and opened GitHub issues. Direct creation requires a GitHub API integration."
            )
        }
    }

    // MARK: - Post Slack

    private func executePostSlack(channel: String, message: String) async -> CommandActionResult {
        // MVP: type the message if Slack is the active app, otherwise prepare it
        let isSlackActive = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.tinyspeck.slackmacgap"

        if isSlackActive {
            return await executeTypeText(text: message, appHint: nil)
        }

        copyToClipboard(message)
        return .ok(
            "Copied Slack message for #\(channel)",
            detail: "Message: \(message)\n\n(Direct Slack posting requires an API integration.)"
        )
    }

    // MARK: - Delegate to agent

    private func executeDelegateToAgent(
        agent: CommandAction.AgentTarget,
        prompt: String,
        context: String?
    ) async -> CommandActionResult {
        let plan = await DelegationWorkflowResolver(dataStore: dataStore).resolve(
            agent: agent,
            prompt: prompt,
            explicitContext: context
        )
        let detail = plan.detail(prompt: prompt, explicitContext: context)

        switch agent {
        case .devin:
            // MVP: make prepared-only agent actions visible by opening Devin and
            // copying the task prompt. Direct session creation requires API auth.
            copyToClipboard(detail)
            openDevinSurface(from: plan)
            return .ok(
                plan.confidence >= 0.45 ? "Task prepared for Devin using local context" : "Task prepared for Devin",
                detail: "\(detail)\n\nCopied task to clipboard and opened Devin. Direct Devin session creation requires an API integration."
            )

        case .claudeCode:
            // Launch claude CLI if available
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/local/bin/claude")
            task.arguments = ["-p", detail]
            do {
                currentProcess = task
                try task.run()
                currentProcess = nil
                return .ok("Sent to Claude Code", detail: detail)
            } catch {
                currentProcess = nil
                copyToClipboard(detail)
                return .ok(
                    "Copied Claude Code prompt",
                    detail: "\(detail)\n\n(Install Claude Code CLI to auto-launch.)"
                )
            }

        case .cursor:
            copyToClipboard(detail)
            return .ok(
                "Copied Cursor task prompt",
                detail: "\(detail)\n\n(Use Cursor's MCP integration to pass this context.)"
            )
        }
    }

    private func openDevinSurface(from plan: DelegationWorkflowResolver.Plan) {
        let evidenceURL = plan.evidence.compactMap { line -> URL? in
            guard line.hasPrefix("URL: ") else { return nil }
            return URL(string: String(line.dropFirst(5)))
        }.first
        let url = evidenceURL ?? URL(string: "https://app.devin.ai")
        if let url {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Composite

    private func executeComposite(_ actions: [CommandAction]) async -> CommandActionResult {
        var results: [String] = []
        var allSucceeded = true

        for action in actions {
            let result = await execute(action)
            results.append(result.summary)
            if !result.success { allSucceeded = false }
        }

        return CommandActionResult(
            success: allSucceeded,
            summary: results.joined(separator: " → "),
            detail: nil
        )
    }
}
