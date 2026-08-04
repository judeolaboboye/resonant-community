import Foundation

struct EmailFocusedFieldContext: Equatable {
    let role: String?
    let subrole: String?
    let title: String?
    let placeholderValue: String?
    let identifier: String?
    let description: String?
    let help: String?
}

enum EmailContextSupport {
    private static let appContextPattern = #"\b(?:mail|gmail|outlook|superhuman|spark|airmail|fastmail|hey|proton(?:\s+mail)?|tuta(?:nota)?|yahoo\s+mail|icloud\s+mail|zoho\s+mail|aol\s+mail|gmx|thunderbird|canary\s+mail|mailmate|postbox|em\s*client|missive|mimestream|polymail|shortwave)\b"#
    private static let windowTitlePattern = #"\b(?:apple\s+mail|gmail|outlook|superhuman|spark|airmail|fastmail|hey|proton(?:\s+mail)?|tuta(?:nota)?|yahoo\s+mail|icloud\s+mail|zoho\s+mail|aol\s+mail|gmx|thunderbird|canary\s+mail|mailmate|postbox|em\s*client|missive|mimestream|polymail|shortwave)\b"#
    private static let webmailURLPattern = #"mail\.google\.com|outlook\.office\.com|outlook\.office365\.com|outlook\.live\.com|mail\.yahoo\.com|icloud\.com/mail|fastmail\.com|hey\.com|mail\.proton\.me|proton\.me/mail|protonmail\.com|app\.tuta\.com|mail\.tutanota\.com|tutanota\.com|mail\.zoho\.|mail\.aol\.com|(?:mail|webmail)\.gmx\.|mailbox\.org|mailfence\.com|missiveapp\.com|shortwave\.com"#
    private static let nonBodyFieldPattern = #"\b(?:subject|to|cc|bcc|from|sender|recipient|address|contacts?|search|find|filter|mailbox|folder)\b"#
    private static let bodyFieldPattern = #"\b(?:body|message|compose|reply|write|email body|mail body|content)\b"#

    static func isEmailContext(
        appName: String?,
        bundleId: String?,
        windowTitle: String?,
        browserURL: String?
    ) -> Bool {
        let appCandidates = [appName, bundleId]
            .compactMap { $0?.trimmedNilIfEmpty }

        if appCandidates.contains(where: { $0.matchesPattern(appContextPattern) }) {
            return true
        }

        if windowTitle?.trimmedNilIfEmpty?.matchesPattern(windowTitlePattern) == true {
            return true
        }

        return browserURL?.matchesPattern(webmailURLPattern) == true
    }

    static func isLikelyEmailBodyField(_ context: EmailFocusedFieldContext?) -> Bool {
        guard let context else { return true }

        let role = context.role?.lowercased()
        let subrole = context.subrole?.lowercased()
        if subrole?.contains("secure") == true {
            return false
        }

        let metadata = [
            context.title,
            context.placeholderValue,
            context.identifier,
            context.description,
            context.help,
        ]
            .compactMap { $0?.trimmedNilIfEmpty }
            .joined(separator: " ")
            .lowercased()

        if metadata.matchesPattern(nonBodyFieldPattern) {
            return false
        }

        if metadata.matchesPattern(bodyFieldPattern) {
            return true
        }

        if role == "axtextarea" {
            return true
        }

        if role == "axtextfield" || role == "axcombobox" || subrole == "axsearchfield" {
            return false
        }

        return true
    }
}

private extension String {
    var trimmedNilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func matchesPattern(_ pattern: String) -> Bool {
        range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
