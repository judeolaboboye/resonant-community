import Foundation

enum DispatchDiagnosticPrivacy: Sendable, Equatable {
    case raw
    case redacted

    var isRedacted: Bool {
        self == .redacted
    }
}

enum DispatchDiagnosticRedactor {
    static func redactCommand(_ text: String, privacy: DispatchDiagnosticPrivacy) -> String {
        guard privacy.isRedacted else { return text }
        return "[redacted command]"
    }

    static func redactPattern(_ text: String, privacy: DispatchDiagnosticPrivacy) -> String {
        guard privacy.isRedacted else { return text }
        return "[redacted pattern]"
    }

    static func redactDiagnosticText(_ text: String, privacy: DispatchDiagnosticPrivacy) -> String {
        guard privacy.isRedacted else { return text }
        var redacted = text
        redacted = redacted.replacingOccurrences(
            of: #"/Users/[^\s\"']+"#,
            with: "[path]",
            options: .regularExpression
        )
        redacted = redacted.replacingOccurrences(
            of: #"https?://[^\s]+"#,
            with: "[url]",
            options: .regularExpression
        )
        redacted = redacted.replacingOccurrences(
            of: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
            with: "[email]",
            options: [.regularExpression, .caseInsensitive]
        )
        return redacted
    }
}
