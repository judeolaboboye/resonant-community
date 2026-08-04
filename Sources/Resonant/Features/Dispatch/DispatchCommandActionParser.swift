import Foundation

enum DispatchCommandActionParser {
    static func parse(_ response: String) throws -> CommandAction {
        let json = strippedMarkdownFence(from: response)

        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CommandError.invalidResponse(response)
        }

        return try parseObject(object, originalResponse: response)
    }

    private static func parseObject(
        _ object: [String: Any],
        originalResponse: String
    ) throws -> CommandAction {
        guard let actionType = object["action"] as? String else {
            throw CommandError.invalidResponse(originalResponse)
        }

        switch actionType {
        case "type_text":
            let text = object["text"] as? String ?? ""
            let appHint = object["app_hint"] as? String
            return .typeText(text: text, appHint: appHint)

        case "open_url":
            let url = object["url"] as? String ?? ""
            return .openURL(url: url)

        case "open_app":
            let name = object["name"] as? String ?? ""
            return .openApp(name: name)

        case "search_workspace":
            let query = object["query"] as? String ?? ""
            return .searchWorkspace(query: query)

        case "speak_answer":
            let text = object["text"] as? String ?? ""
            return .speakAnswer(text: text)

        case "create_ticket":
            let title = object["title"] as? String ?? ""
            let body = object["body"] as? String ?? ""
            let serviceRaw = object["service"] as? String ?? "linear"
            let service = CommandAction.TicketService(rawValue: serviceRaw) ?? .linear
            return .createTicket(title: title, body: body, service: service)

        case "post_slack":
            let channel = object["channel"] as? String ?? ""
            let message = object["message"] as? String ?? ""
            return .postSlack(channel: channel, message: message)

        case "delegate_agent":
            let agentRaw = object["agent"] as? String ?? "devin"
            let agent: CommandAction.AgentTarget
            switch agentRaw {
            case "claude_code": agent = .claudeCode
            case "cursor": agent = .cursor
            default: agent = .devin
            }
            let prompt = object["prompt"] as? String ?? ""
            let context = object["context"] as? String
            return .delegateToAgent(agent: agent, prompt: prompt, context: context)

        case "composite":
            guard let actions = object["actions"] as? [[String: Any]] else {
                throw CommandError.invalidResponse(originalResponse)
            }
            return .composite(try actions.map { try parseObject($0, originalResponse: originalResponse) })

        default:
            throw CommandError.unknownAction(actionType)
        }
    }

    private static func strippedMarkdownFence(from response: String) -> String {
        var json = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if json.hasPrefix("```") {
            json = json
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return json
    }
}
