import Foundation
import Observation
import SwiftData

/// Merges dictation history, memos, and achievement events into a unified chronological feed.
@MainActor
@Observable
final class FeedManager {

    private(set) var items: [FeedItem] = []
    private(set) var version = 0
    private(set) var isLoading = false
    private var dataStore: DataStore?

    // Day-grouped for the feed UI
    var grouped: [(date: Date, items: [FeedItem])] {
        let calendar = Calendar.current
        let dict = Dictionary(grouping: items) { item in
            calendar.startOfDay(for: item.date)
        }
        return dict.keys.sorted(by: >).map { date in
            (date: date, items: dict[date, default: []].sorted { $0.date > $1.date })
        }
    }

    func load(from store: DataStore) async {
        dataStore = store
        await reload()
    }

    func reload() async {
        guard let dataStore else {
            items = []
            bumpVersion()
            return
        }

        isLoading = true
        defer { isLoading = false }

        var result: [FeedItem] = []

        // Dictation entries
        var dictDescriptor = FetchDescriptor<DictationEntry>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        dictDescriptor.fetchLimit = 200
        let dictations = await dataStore.fetchInBackground(dictDescriptor)
        result += dictations.map(feedItem(from:))

        // Memos
        var memoDescriptor = FetchDescriptor<MemoEntry>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        memoDescriptor.fetchLimit = 100
        let memos = await dataStore.fetchInBackground(memoDescriptor)
        result += memos.map(feedItem(from:))

        // Meetings
        var meetingDescriptor = FetchDescriptor<MeetingEntry>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        meetingDescriptor.fetchLimit = 50
        let meetings = await dataStore.fetchInBackground(meetingDescriptor)
            .filter { $0.activeJSONLPath == nil }
        result += meetings.map(feedItem(from:))

        items = result.sorted { $0.date > $1.date }
        bumpVersion()
    }

    func search(_ query: String) -> [FeedItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return items }
        return items.filter {
            $0.text.lowercased().contains(q) ||
            ($0.appName?.lowercased().contains(q) ?? false) ||
            ($0.contextLabel?.lowercased().contains(q) ?? false) ||
            ($0.browserURL?.lowercased().contains(q) ?? false)
        }
    }

    func record(_ entry: DictationEntry) {
        prepend(feedItem(from: entry))
    }

    func record(_ memo: MemoEntry) {
        prepend(feedItem(from: memo))
    }

    func record(_ meeting: MeetingEntry) {
        prepend(feedItem(from: meeting))
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
        bumpVersion()
    }

    func updateText(id: UUID, newText: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let old = items[index]
        let wordCount = newText.split(separator: " ").count
        var metadata = old.metadata
        metadata["wordCount"] = "\(wordCount)"
        items[index] = FeedItem(
            id: old.id,
            kind: old.kind,
            text: newText,
            date: old.date,
            appName: old.appName,
            bundleId: old.bundleId,
            contextLabel: old.contextLabel,
            windowTitle: old.windowTitle,
            browserURL: old.browserURL,
            audioPath: old.audioPath,
            metadata: metadata
        )
        bumpVersion()
    }

    func updateMeetingTitle(id: UUID, title: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let old = items[index]
        guard old.kind == .meeting else { return }

        var metadata = old.metadata
        metadata["title"] = title

        items[index] = FeedItem(
            id: old.id,
            kind: old.kind,
            text: title,
            date: old.date,
            appName: old.appName,
            bundleId: old.bundleId,
            contextLabel: old.contextLabel,
            windowTitle: old.windowTitle,
            browserURL: old.browserURL,
            audioPath: old.audioPath,
            metadata: metadata
        )
        bumpVersion()
    }

    func clearWorkspaceData() {
        items = []
        isLoading = false
        bumpVersion()
    }

    private func prepend(_ item: FeedItem) {
        items.insert(item, at: 0)
        bumpVersion()
    }

    private func bumpVersion() {
        version += 1
    }

    /// Resolves a relative audio path (under App Support/Resonant/) to a full URL.
    func resolveAudioURL(_ audioPath: String?) -> URL? {
        guard let audioPath, !audioPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        if audioPath.hasPrefix("/") {
            let url = URL(fileURLWithPath: audioPath)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        let support = AppSupportPaths.resonantRoot()
        let url = support.appendingPathComponent(audioPath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func feedItem(from entry: DictationEntry) -> FeedItem {
        let durationSeconds = max(Int(entry.duration.rounded()), 0)
        return FeedItem(
            id: entry.id,
            kind: .dictation,
            text: entry.text,
            date: entry.date,
            appName: entry.appName.nilIfEmpty,
            bundleId: entry.bundleId.nilIfEmpty,
            contextLabel: contextLabel(for: entry),
            windowTitle: entry.windowTitle?.nilIfEmpty,
            browserURL: entry.browserURL?.nilIfEmpty,
            audioPath: entry.audioPath,
            metadata: [
                "wordCount": "\(entry.wordCount)",
                "duration": "\(durationSeconds)s",
                "durationSeconds": "\(durationSeconds)"
            ]
        )
    }

    private func feedItem(from memo: MemoEntry) -> FeedItem {
        let durationSeconds = max(Int(memo.duration.rounded()), 0)
        return FeedItem(
            id: memo.id,
            kind: .memo,
            text: memo.text,
            date: memo.date,
            appName: nil,
            bundleId: nil,
            contextLabel: "Voice memo",
            windowTitle: nil,
            browserURL: nil,
            audioPath: memo.audioPath,
            metadata: [
                "duration": "\(durationSeconds)s",
                "durationSeconds": "\(durationSeconds)",
                "title": memo.displayTitle
            ]
        )
    }

    private func feedItem(from meeting: MeetingEntry) -> FeedItem {
        let durationSeconds = max(Int(meeting.durationSeconds.rounded()), 0)
        return FeedItem(
            id: meeting.id,
            kind: .meeting,
            text: meeting.displayTitle,
            date: meeting.startedAt,
            appName: meeting.detectedApp,
            bundleId: nil,
            contextLabel: "Meeting",
            windowTitle: nil,
            browserURL: nil,
            audioPath: meeting.audioPath,
            metadata: [
                "duration": "\(durationSeconds)s",
                "durationSeconds": "\(durationSeconds)",
                "title": meeting.displayTitle,
                "wordCount": "\(meeting.wordCount)"
            ]
        )
    }

    private func contextLabel(for entry: DictationEntry) -> String? {
        if let fileName = entry.codeFileName?.nilIfEmpty {
            return fileName
        }
        if let recipient = entry.slackRecipient?.nilIfEmpty {
            return recipient
        }
        if let browserURL = entry.browserURL?.nilIfEmpty,
           let host = URL(string: browserURL)?.host?.nilIfEmpty {
            return host
        }
        if let windowTitle = entry.windowTitle?.nilIfEmpty {
            return windowTitle
        }
        return entry.appName.nilIfEmpty ?? "Resonant"
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
