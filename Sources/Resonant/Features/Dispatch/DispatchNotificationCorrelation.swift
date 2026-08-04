import Foundation

enum DispatchNotificationCorrelation {
    static func conversationIdentifiers(in values: [String?]) -> Set<String> {
        values.reduce(into: Set<String>()) { result, value in
            for identifier in conversationIdentifiers(in: value) {
                result.insert(identifier)
            }
        }
    }

    static func conversationIdentifiers(in value: String?, allowLooseIdentifiers: Bool = true) -> Set<String> {
        guard let value else { return [] }
        let normalizedValue = normalized(value)
        guard !normalizedValue.isEmpty else { return [] }

        var identifiers = Set<String>()
        identifiers.formUnion(channelIdentifiers(in: normalizedValue))
        identifiers.formUnion(slackURLIdentifiers(in: value))

        if identifiers.isEmpty, allowLooseIdentifiers {
            let tokens = normalizedValue
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { token in
                    token.count >= 3 && !ignoredConversationTokens.contains(token)
                }
            if tokens.count <= 4 {
                identifiers.formUnion(tokens)
            }
        }

        return identifiers
    }

    static func matches(notificationIdentifiers: Set<String>, currentIdentifiers: Set<String>) -> Bool? {
        guard !notificationIdentifiers.isEmpty else { return true }
        guard !currentIdentifiers.isEmpty else { return nil }
        return notificationIdentifiers.contains { notification in
            currentIdentifiers.contains { current in
                notification == current
                    || notification.contains(current)
                    || current.contains(notification)
            }
        }
    }

    private static func channelIdentifiers(in value: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9])#[A-Za-z0-9][A-Za-z0-9._-]*"#) else {
            return []
        }
        let nsValue = value as NSString
        return Set(regex.matches(in: value, range: NSRange(location: 0, length: nsValue.length)).flatMap { match in
            let channel = nsValue.substring(with: match.range).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            return [channel, "#\(channel)"]
        })
    }

    private static func slackURLIdentifiers(in value: String) -> Set<String> {
        guard let url = URL(string: value),
              url.host(percentEncoded: false)?.contains("slack.com") == true else {
            return []
        }
        return Set(url.path
            .split(separator: "/")
            .map(String.init)
            .map(normalized)
            .filter { $0.count >= 3 && !$0.hasPrefix("client") })
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let ignoredConversationTokens: Set<String> = [
        "app", "browser", "can", "check", "client", "com", "conversation", "current", "desktop", "from",
        "google", "message", "notification", "reply", "safari", "saying", "slack",
        "that", "the", "with", "window"
    ]
}
