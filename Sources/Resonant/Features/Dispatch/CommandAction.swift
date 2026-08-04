import Foundation

/// Structured action returned by the command LLM.
/// Each case maps to a concrete execution path in `ActionExecutor`.
enum CommandAction: Codable, Sendable {
    case typeText(text: String, appHint: String?)
    case openURL(url: String)
    case openApp(name: String)
    case searchWorkspace(query: String)
    case speakAnswer(text: String)
    case createTicket(title: String, body: String, service: TicketService)
    case postSlack(channel: String, message: String)
    case delegateToAgent(agent: AgentTarget, prompt: String, context: String?)
    case composite([CommandAction])

    enum TicketService: String, Codable, Sendable {
        case linear
        case github
    }

    enum AgentTarget: String, Codable, Sendable {
        case devin
        case claudeCode
        case cursor
    }

    var handlesVoiceFeedbackInline: Bool {
        switch self {
        case .speakAnswer:
            return true
        case .composite(let actions):
            return actions.contains { $0.handlesVoiceFeedbackInline }
        case .typeText, .openURL, .openApp, .searchWorkspace, .createTicket, .postSlack, .delegateToAgent:
            return false
        }
    }
}

/// The result of executing a `CommandAction`.
struct CommandActionResult: Sendable {
    let success: Bool
    let summary: String
    let detail: String?

    static func ok(_ summary: String, detail: String? = nil) -> CommandActionResult {
        CommandActionResult(success: true, summary: summary, detail: detail)
    }

    static func failed(_ summary: String, detail: String? = nil) -> CommandActionResult {
        CommandActionResult(success: false, summary: summary, detail: detail)
    }
}
