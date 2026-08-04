import Foundation

struct CapturedContext: Codable, Equatable, Sendable {
    var appName: String?
    var bundleId: String?
    var windowTitle: String?
    var browserURL: String?
    var codeFileName: String?
    var slackRecipient: String?
    var selectedText: String?
    var focusedFieldContent: String?
    var visibleTextSnippets: [String]

    static let empty = CapturedContext()

    init(
        appName: String? = nil,
        bundleId: String? = nil,
        windowTitle: String? = nil,
        browserURL: String? = nil,
        codeFileName: String? = nil,
        slackRecipient: String? = nil,
        selectedText: String? = nil,
        focusedFieldContent: String? = nil,
        visibleTextSnippets: [String] = []
    ) {
        self.appName = Self.normalize(appName)
        self.bundleId = Self.normalize(bundleId)
        self.windowTitle = Self.normalize(windowTitle)
        self.browserURL = Self.normalize(browserURL)
        self.codeFileName = Self.normalize(codeFileName)
        self.slackRecipient = Self.normalize(slackRecipient)
        self.selectedText = Self.normalize(selectedText)
        self.focusedFieldContent = Self.normalize(focusedFieldContent)
        self.visibleTextSnippets = Self.normalizeSnippets(visibleTextSnippets)
    }

    var isEmpty: Bool {
        appName == nil
            && bundleId == nil
            && windowTitle == nil
            && browserURL == nil
            && codeFileName == nil
            && slackRecipient == nil
            && selectedText == nil
            && focusedFieldContent == nil
            && visibleTextSnippets.isEmpty
    }

    var persistenceKey: String {
        [bundleId ?? "", windowTitle ?? "", browserURL ?? ""].joined(separator: "|")
    }

    var storedAppName: String {
        appName ?? ""
    }

    var storedBundleId: String {
        bundleId ?? ""
    }

    private static func normalize(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizeSnippets(_ snippets: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for snippet in snippets {
            guard let normalized = normalize(snippet) else { continue }
            guard seen.insert(normalized).inserted else { continue }
            result.append(normalized)
        }

        return result
    }
}

enum LocalContextPersistencePolicy {
    static let ambientMaxSnippets = 100
    static let ambientMaxFieldCharacters = 4000
    static let archivePreviewCharacters = 200
    static let archiveVisibleSnippetLimit = 20

    static func dictationContext(
        from result: TranscriptionResult,
        includeMetadata: Bool
    ) -> CapturedContext {
        guard includeMetadata else { return .empty }
        return result.capturedContext
    }

    static func ambientContext(from context: ContextExtractor.Context) -> CapturedContext {
        var captured = context.capturedContext
        captured.focusedFieldContent = truncate(captured.focusedFieldContent, max: ambientMaxFieldCharacters)
        captured.visibleTextSnippets = Array(captured.visibleTextSnippets.prefix(ambientMaxSnippets))
        captured.selectedText = nil
        return captured
    }

    static func archiveSelectedTextPreview(from context: CapturedContext) -> String? {
        preview(context.selectedText)
    }

    static func archiveFocusedFieldPreview(from context: CapturedContext) -> String? {
        preview(context.focusedFieldContent)
    }

    static func archiveVisibleTextSnippets(from context: CapturedContext) -> [String] {
        Array(context.visibleTextSnippets.prefix(archiveVisibleSnippetLimit))
    }

    private static func preview(_ value: String?) -> String? {
        truncate(value, max: archivePreviewCharacters)
    }

    private static func truncate(_ value: String?, max: Int) -> String? {
        guard let value else { return nil }
        guard value.count > max else { return value }
        return String(value.prefix(max))
    }
}

extension ContextExtractor.Context {
    var capturedContext: CapturedContext {
        CapturedContext(
            appName: appName,
            bundleId: bundleId,
            windowTitle: windowTitle,
            browserURL: browserURL,
            codeFileName: primaryCodeFile,
            slackRecipient: primarySlackRecipient,
            selectedText: selectedText,
            focusedFieldContent: focusedFieldContent,
            visibleTextSnippets: visibleTextSnippets
        )
    }
}

extension TranscriptionResult {
    var capturedContext: CapturedContext {
        CapturedContext(
            appName: targetApp,
            bundleId: targetBundleId,
            windowTitle: windowTitle,
            browserURL: browserURL,
            codeFileName: codeFileName,
            slackRecipient: slackRecipient,
            selectedText: selectedText,
            focusedFieldContent: focusedFieldContent,
            visibleTextSnippets: visibleTextSnippets ?? []
        )
    }
}
