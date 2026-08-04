import Foundation

enum ChatMentionKind: String, Sendable, Equatable {
    case meeting
    case memo

    var label: String {
        switch self {
        case .meeting:
            return "meeting"
        case .memo:
            return "memo"
        }
    }
}

struct ChatMentionAttachment: Sendable, Equatable {
    let id: UUID
    let token: String
    let kind: ChatMentionKind
    let title: String
    let date: Date
    let body: String

    func promptBlock() -> String {
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        ### \(token)
        **\(kind.label.capitalized):** \(title)
        **When:** \(Self.longDateFormatter.string(from: date))

        <workspace_attachment untrusted="true" kind="\(kind.label)" title="\(escapeForAttribute(title))">
        \(trimmedBody)
        </workspace_attachment>
        """
    }

    private func escapeForAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static let longDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        return formatter
    }()
}
