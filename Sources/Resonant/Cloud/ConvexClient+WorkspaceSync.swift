import Foundation

struct WorkspaceCloudDeleteResult: Equatable {
    let dictations: Int
    let memos: Int
    let meetings: Int
}

// MARK: - Workspace text sync

extension ConvexClient {
    struct WorkspaceTextSyncResult: Equatable {
        let inserted: Int
        let updated: Int
    }

    struct WorkspaceSyncBatchResponse: Decodable {
        let dictations: Int
        let memos: Int
        let meetings: Int
        let inserted: Int
        let updated: Int
    }

    struct WorkspaceCloudDeleteResponse: Decodable {
        let dictations: Int
        let memos: Int
        let meetings: Int
    }

    func syncWorkspaceTextBatch(
        dictations: [[String: Any]],
        voiceNotes: [[String: Any]],
        meetings: [[String: Any]],
        smartLinks: [SmartLink] = [],
        dictionaryWords: [DictionaryStore.WorkspaceWord] = [],
        options: WorkspaceCloudUploadOptions = .current,
        progress: (@MainActor (_ completed: Int, _ total: Int) -> Void)? = nil
    ) async -> Result<WorkspaceTextSyncResult, ConvexError> {
        guard AppFeatureVisibility.cloudSync else {
            return .failure(.serverError("Workspace cloud sync is currently disabled."))
        }
        if resolvedCloudBearerToken == nil {
            _ = await authManager.refreshSessionIfPossible()
        }
        guard resolvedCloudBearerToken != nil else {
            return .failure(.sessionExpired("Sign in again to sync your workspace."))
        }

        let dictationPayloads = dictations.compactMap { Self.workspaceDictationPayload(from: $0, options: options) }
        let memoPayloads = voiceNotes.compactMap(Self.workspaceMemoPayload(from:))
        let meetingPayloads = meetings.compactMap { Self.workspaceMeetingPayload(from: $0, options: options) }
        let smartLinkPayloads = options.includeSmartLinks ? Self.workspaceSmartLinkPayloads(from: smartLinks) : []
        let dictionaryPayloads = options.includeDictionary ? Self.workspaceDictionaryPayloads(from: dictionaryWords) : []
        let totalCount = dictationPayloads.count + memoPayloads.count + meetingPayloads.count + smartLinkPayloads.count + dictionaryPayloads.count
        let maxCount = max(dictationPayloads.count, memoPayloads.count, meetingPayloads.count, smartLinkPayloads.count, dictionaryPayloads.count)
        guard maxCount > 0 else {
            progress?(0, 0)
            return .success(WorkspaceTextSyncResult(inserted: 0, updated: 0))
        }

        let batchSize = 50
        var completedCount = 0
        var insertedCount = 0
        var updatedCount = 0
        progress?(0, totalCount)
        for offset in stride(from: 0, to: maxCount, by: batchSize) {
            let batchDictations = Self.workspaceChunk(dictationPayloads, offset: offset, size: batchSize)
            let batchMemos = Self.workspaceChunk(memoPayloads, offset: offset, size: batchSize)
            let batchMeetings = Self.workspaceChunk(meetingPayloads, offset: offset, size: batchSize)
            let batchSmartLinks = Self.workspaceChunk(smartLinkPayloads, offset: offset, size: batchSize)
            let batchDictionaryWords = Self.workspaceChunk(dictionaryPayloads, offset: offset, size: batchSize)
            guard !batchDictations.isEmpty || !batchMemos.isEmpty || !batchMeetings.isEmpty || !batchSmartLinks.isEmpty || !batchDictionaryWords.isEmpty else { continue }

            do {
                var args: [String: Any] = [
                    "dictations": batchDictations,
                    "memos": batchMemos,
                    "meetings": batchMeetings,
                ]
                if options.includeSmartLinks {
                    args["smartLinks"] = batchSmartLinks
                }
                if options.includeDictionary {
                    args["dictionaryWords"] = batchDictionaryWords
                }
                let response: WorkspaceSyncBatchResponse = try await request(
                    type: .mutation,
                    path: "workspaceSync:syncBatch",
                    args: args,
                    authorizationMode: .requiredConvexBearer,
                    timeoutMs: CloudTimeouts.workspaceSyncBatchMs
                )
                insertedCount += response.inserted
                updatedCount += response.updated
                completedCount += batchDictations.count + batchMemos.count + batchMeetings.count + batchSmartLinks.count + batchDictionaryWords.count
                progress?(completedCount, totalCount)
            } catch ConvexError.sessionExpired {
                return .failure(.sessionExpired("Session expired. Sign in again to sync your workspace."))
            } catch {
                SentryManager.shared.cloudProcessingError(path: "workspaceSync:syncBatch", error: error)
                print("[ConvexClient] Workspace text sync failed: \(error)")
                return .failure(.serverError(error.localizedDescription))
            }
        }
        return .success(WorkspaceTextSyncResult(inserted: insertedCount, updated: updatedCount))
    }

    func deleteWorkspaceCloudData() async -> Result<WorkspaceCloudDeleteResult, ConvexError> {
        if resolvedCloudBearerToken == nil {
            _ = await authManager.refreshSessionIfPossible()
        }
        guard resolvedCloudBearerToken != nil else {
            return .failure(.sessionExpired("Sign in again to delete your cloud workspace."))
        }

        do {
            let response: WorkspaceCloudDeleteResponse = try await request(
                type: .mutation,
                path: "workspaceSync:deleteAll",
                args: [:],
                authorizationMode: .requiredConvexBearer,
                timeoutMs: CloudTimeouts.workspaceDeleteMs
            )
            return .success(WorkspaceCloudDeleteResult(
                dictations: response.dictations,
                memos: response.memos,
                meetings: response.meetings
            ))
        } catch ConvexError.sessionExpired {
            return .failure(.sessionExpired("Session expired. Sign in again to delete your cloud workspace."))
        } catch {
            SentryManager.shared.cloudProcessingError(path: "workspaceSync:deleteAll", error: error)
            return .failure(.serverError(error.localizedDescription))
        }
    }
}

// MARK: - Workspace payload builders

extension ConvexClient {
    static func workspaceDictationPayload(
        from record: [String: Any],
        options: WorkspaceCloudUploadOptions = .current
    ) -> [String: Any]? {
        guard
            let externalID = workspaceString(record["id"]),
            let capturedAt = workspaceEpochMilliseconds(record["timestamp"]),
            let text = workspaceString(record["sentText"]) ?? workspaceString(record["text"])
        else {
            return nil
        }

        var payload: [String: Any] = [
            "externalId": externalID,
            "text": text,
            "wordCount": workspaceWordCount(text),
            "capturedAt": capturedAt,
            "updatedAt": capturedAt,
            "sourcePlatform": "macos",
        ]
        if let rawTranscript = workspaceString(record["text"]) {
            payload["rawTranscript"] = rawTranscript
        }
        if let deliveredText = workspaceString(record["sentText"]) {
            payload["deliveredText"] = deliveredText
        }
        if options.includeContextMetadata {
            if let app = workspaceString(record["app"]) {
                payload["appName"] = app
                payload["bundleId"] = app
            }
            workspaceSet(&payload, key: "windowTitle", value: workspaceString(record["windowTitle"]))
            workspaceSet(&payload, key: "browserUrl", value: workspaceString(record["url"]))
        }
        workspaceSet(&payload, key: "durationSeconds", value: workspaceDurationSeconds(fromMilliseconds: record["duration"]))
        return payload
    }

    static func workspaceMemoPayload(from record: [String: Any]) -> [String: Any]? {
        guard
            let externalID = workspaceString(record["id"]),
            let capturedAt = workspaceEpochMilliseconds(record["timestamp"]),
            let text = workspaceString(record["text"])
        else {
            return nil
        }

        var payload: [String: Any] = [
            "externalId": externalID,
            "title": workspaceString(record["title"]) ?? "Voice note",
            "text": text,
            "wordCount": workspaceWordCount(text),
            "capturedAt": capturedAt,
            "updatedAt": capturedAt,
            "sourcePlatform": "macos",
        ]
        workspaceSet(&payload, key: "distilledText", value: workspaceString(record["clarifiedText"]))
        workspaceSet(&payload, key: "durationSeconds", value: workspaceDurationSeconds(fromMilliseconds: record["duration"]))
        return payload
    }

    static func workspaceMeetingPayload(
        from record: [String: Any],
        options: WorkspaceCloudUploadOptions = .current
    ) -> [String: Any]? {
        guard
            let externalID = workspaceString(record["id"]),
            let startedAt = workspaceEpochMilliseconds(record["timestamp"])
        else {
            return nil
        }

        let transcriptMarkdown = options.includeMeetingTranscripts ? workspaceString(record["markdown"]) : nil
        let summary = workspaceString(record["summary"])
        let fallbackWordSource = transcriptMarkdown ?? summary ?? ""
        var payload: [String: Any] = [
            "externalId": externalID,
            "title": workspaceString(record["title"]) ?? "Meeting",
            "startedAt": startedAt,
            "wordCount": workspaceInt(record["wordCount"]) ?? workspaceWordCount(fallbackWordSource),
            "updatedAt": Date().timeIntervalSince1970 * 1000,
            "sourcePlatform": "macos",
        ]
        workspaceSet(&payload, key: "endedAt", value: workspaceEpochMilliseconds(record["endedAt"]))
        workspaceSet(&payload, key: "durationSeconds", value: workspaceDouble(record["duration"]))
        if options.includeContextMetadata {
            workspaceSet(&payload, key: "appName", value: workspaceString(record["app"]))
            workspaceSet(&payload, key: "calendarEventId", value: workspaceString(record["calendarEventID"]))
            workspaceSet(&payload, key: "scheduledStartAt", value: workspaceEpochMilliseconds(record["scheduledStartAt"]))
            workspaceSet(&payload, key: "scheduledEndAt", value: workspaceEpochMilliseconds(record["scheduledEndAt"]))
            workspaceSet(&payload, key: "conferencingUrl", value: workspaceString(record["conferencingURL"]))
            workspaceSet(&payload, key: "calendarName", value: workspaceString(record["calendarName"]))
            workspaceSet(&payload, key: "recordingOrigin", value: workspaceString(record["recordingOrigin"]))
        }
        workspaceSet(&payload, key: "userNotes", value: workspaceString(record["notes"]))
        workspaceSet(&payload, key: "postMeetingNotes", value: workspaceString(record["postMeetingNotes"]))
        workspaceSet(&payload, key: "summary", value: summary)
        workspaceSet(&payload, key: "transcriptMarkdown", value: transcriptMarkdown)
        if options.includeMeetingParticipants {
            workspaceSet(&payload, key: "organizerName", value: workspaceString(record["organizerName"]))
            workspaceSet(&payload, key: "attendeeNames", value: workspaceStringArray(record["attendeeNames"]))
            workspaceSet(&payload, key: "attendeeEmails", value: workspaceStringArray(record["attendeeEmails"]))
            workspaceSet(&payload, key: "speakerAliases", value: workspaceJSONString(record["speakerAliases"]))
        }
        return payload
    }

    static func workspaceSmartLinkPayloads(from links: [SmartLink]) -> [[String: Any]] {
        links.compactMap { link in
            let trigger = link.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
            let url = link.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trigger.isEmpty, !url.isEmpty else { return nil }

            var payload: [String: Any] = [
                "externalId": link.id.uuidString.lowercased(),
                "trigger": trigger,
                "url": url,
                "isEnabled": link.isEnabled,
                "sourcePlatform": "macos",
            ]
            if let label = link.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
                payload["label"] = label
            }
            return payload
        }
    }

    static func workspaceDictionaryPayloads(from words: [DictionaryStore.WorkspaceWord]) -> [[String: Any]] {
        words.compactMap { word in
            let spoken = word.spoken.trimmingCharacters(in: .whitespacesAndNewlines)
            let written = word.written.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !spoken.isEmpty, !written.isEmpty else { return nil }

            return [
                "externalId": word.id.uuidString.lowercased(),
                "spoken": spoken,
                "written": written,
                "createdAt": word.createdAt.timeIntervalSince1970 * 1000,
                "correctedCount": word.correctedCount,
                "seenUncorrectedCount": word.seenUncorrectedCount,
                "isAutoLearned": word.isAutoLearned,
                "isSuppressed": word.isSuppressed,
                "spokenIsRealWord": word.spokenIsRealWord,
                "lastSeenAt": word.lastSeenAt.timeIntervalSince1970 * 1000,
                "sourcePlatform": "macos",
            ]
        }
    }

    static func workspaceSet(_ payload: inout [String: Any], key: String, value: Any?) {
        if let value {
            payload[key] = value
        }
    }

    static func workspaceChunk<T>(_ items: [T], offset: Int, size: Int) -> [T] {
        guard offset < items.count else { return [] }
        return Array(items[offset..<min(items.count, offset + size)])
    }

    static func workspaceString(_ value: Any?) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    static func workspaceStringArray(_ value: Any?) -> [String]? {
        guard let values = value as? [Any] else { return nil }
        let strings = values.compactMap(workspaceString)
        return strings.isEmpty ? nil : strings
    }

    static func workspaceJSONString(_ value: Any?) -> String? {
        if let string = workspaceString(value) {
            return string
        }
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let string = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return string
    }

    static func workspaceInt(_ value: Any?) -> Int? {
        if let int = value as? Int {
            return int
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = workspaceString(value), let int = Int(string) {
            return int
        }
        return nil
    }

    static func workspaceDouble(_ value: Any?) -> Double? {
        if let double = value as? Double {
            return double
        }
        if let int = value as? Int {
            return Double(int)
        }
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = workspaceString(value), let double = Double(string) {
            return double
        }
        return nil
    }

    static func workspaceDurationSeconds(fromMilliseconds value: Any?) -> Double? {
        guard let milliseconds = workspaceDouble(value), milliseconds >= 0 else { return nil }
        return milliseconds / 1000
    }

    static func workspaceEpochMilliseconds(_ value: Any?) -> Double? {
        if let date = value as? Date {
            return date.timeIntervalSince1970 * 1000
        }
        if let number = workspaceDouble(value), number > 0 {
            return number < 10_000_000_000 ? number * 1000 : number
        }
        guard let string = workspaceString(value) else { return nil }

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: string) {
            return date.timeIntervalSince1970 * 1000
        }

        let standardFormatter = ISO8601DateFormatter()
        standardFormatter.formatOptions = [.withInternetDateTime]
        if let date = standardFormatter.date(from: string) {
            return date.timeIntervalSince1970 * 1000
        }

        return nil
    }

    static func workspaceWordCount(_ text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }
}
