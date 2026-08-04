import Foundation

extension DictationEntry {
    static func make(
        id: UUID,
        text: String,
        context: CapturedContext = .empty,
        wordCount: Int,
        duration: TimeInterval,
        mode: DictationMode,
        date: Date,
        audioPath: String? = nil,
        rawTranscript: String? = nil,
        deliveredText: String? = nil,
        selectedText: String? = nil,
        autoPasted: Bool? = nil,
        copiedToClipboard: Bool? = nil,
        autoSent: Bool? = nil,
        focusedFieldContent: String? = nil,
        visibleTextSnippetsJSON: String? = nil,
        vocabularyBoostAuditSummary: VocabularyBoostAuditSummary? = nil,
        externalID: String? = nil
    ) -> DictationEntry {
        let selectedTextToStore = selectedText ?? context.selectedText
        let focusedFieldToStore = focusedFieldContent ?? context.focusedFieldContent
        let snippetsJSON = visibleTextSnippetsJSON ?? encodeJSONStringArray(context.visibleTextSnippets)

        return DictationEntry(
            id: id,
            text: text,
            appName: context.storedAppName,
            bundleId: context.storedBundleId,
            windowTitle: context.windowTitle,
            browserURL: context.browserURL,
            codeFileName: context.codeFileName,
            slackRecipient: context.slackRecipient,
            wordCount: wordCount,
            duration: duration,
            mode: mode,
            date: date,
            audioPath: audioPath,
            rawTranscript: rawTranscript,
            deliveredText: deliveredText,
            selectedText: selectedTextToStore,
            autoPasted: autoPasted,
            copiedToClipboard: copiedToClipboard,
            autoSent: autoSent,
            focusedFieldContent: focusedFieldToStore,
            visibleTextSnippetsJSON: snippetsJSON,
            vocabularyBoostAuditSummary: vocabularyBoostAuditSummary,
            externalID: externalID
        )
    }

    var capturedContext: CapturedContext {
        CapturedContext(
            appName: appName,
            bundleId: bundleId,
            windowTitle: windowTitle,
            browserURL: browserURL,
            codeFileName: codeFileName,
            slackRecipient: slackRecipient,
            selectedText: selectedText,
            focusedFieldContent: focusedFieldContent,
            visibleTextSnippets: visibleTextSnippets
        )
    }
}

extension AmbientContextSnapshot {
    static func make(
        timestamp: Date,
        context: CapturedContext,
        dwellDurationSeconds: Double? = nil,
        clipboardText: String? = nil,
        browserTabs: [String] = [],
        notificationAppName: String? = nil,
        notificationBundleId: String? = nil,
        notificationTitle: String? = nil,
        notificationBody: String? = nil,
        notificationURL: String? = nil,
        notificationReceivedAt: Date? = nil
    ) -> AmbientContextSnapshot {
        AmbientContextSnapshot(
            timestamp: timestamp,
            appName: context.storedAppName,
            bundleId: context.storedBundleId,
            windowTitle: context.windowTitle,
            browserURL: context.browserURL,
            codeFileName: context.codeFileName,
            slackRecipient: context.slackRecipient,
            focusedFieldContent: context.focusedFieldContent,
            visibleTextSnippetsJSON: encodeJSONStringArray(context.visibleTextSnippets),
            dwellDurationSeconds: dwellDurationSeconds,
            clipboardText: clipboardText,
            browserTabsJSON: encodeJSONStringArray(browserTabs),
            notificationAppName: notificationAppName,
            notificationBundleId: notificationBundleId,
            notificationTitle: notificationTitle,
            notificationBody: notificationBody,
            notificationURL: notificationURL,
            notificationReceivedAt: notificationReceivedAt
        )
    }

    var capturedContext: CapturedContext {
        CapturedContext(
            appName: appName,
            bundleId: bundleId,
            windowTitle: windowTitle,
            browserURL: browserURL,
            codeFileName: codeFileName,
            slackRecipient: slackRecipient,
            focusedFieldContent: focusedFieldContent,
            visibleTextSnippets: visibleTextSnippets
        )
    }
}

extension ActivityStreamEvent {
    init(
        id: String,
        timestamp: String,
        type: EventType,
        text: String,
        rawTranscript: String?,
        context: CapturedContext?,
        durationSeconds: Double,
        wordCount: Int,
        mode: String,
        audioPath: String?,
        delivery: Delivery?,
        memoTitle: String?,
        meetingTitle: String? = nil
    ) {
        let snippets = context?.visibleTextSnippets
        self.init(
            id: id,
            timestamp: timestamp,
            type: type,
            text: text,
            rawTranscript: rawTranscript,
            selectedText: context?.selectedText,
            appName: context?.appName,
            bundleId: context?.bundleId,
            windowTitle: context?.windowTitle,
            browserURL: context?.browserURL,
            codeFileName: context?.codeFileName,
            slackRecipient: context?.slackRecipient,
            focusedFieldContent: context?.focusedFieldContent,
            visibleTextSnippets: (snippets?.isEmpty == false) ? snippets : nil,
            durationSeconds: durationSeconds,
            wordCount: wordCount,
            mode: mode,
            audioPath: audioPath,
            delivery: delivery,
            memoTitle: memoTitle,
            meetingTitle: meetingTitle
        )
    }

    var capturedContext: CapturedContext {
        CapturedContext(
            appName: appName,
            bundleId: bundleId,
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
