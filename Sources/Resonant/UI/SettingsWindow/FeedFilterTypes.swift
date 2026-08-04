import SwiftUI

// MARK: - Kind Filter

enum FeedKindFilter: String, CaseIterable {
    case all
    case dictations
    case memos
    case meetings

    var title: String {
        switch self {
        case .all:        "All"
        case .dictations: "Dictations"
        case .memos:      "Memos"
        case .meetings:   "Meetings"
        }
    }

    func includes(_ item: FeedItem) -> Bool {
        switch self {
        case .all:        true
        case .dictations: item.kind == .dictation
        case .memos:      item.kind == .memo
        case .meetings:   item.kind == .meeting
        }
    }
}

// MARK: - Time Filter

enum FeedTimeFilter: String, CaseIterable {
    case allTime
    case today
    case last7Days
    case last30Days

    var title: String {
        switch self {
        case .allTime:    "Any time"
        case .today:      "Today"
        case .last7Days:  "7 days"
        case .last30Days: "30 days"
        }
    }

    func includes(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        switch self {
        case .allTime:
            return true
        case .today:
            return calendar.isDateInToday(date)
        case .last7Days:
            guard let threshold = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) else {
                return true
            }
            return date >= threshold
        case .last30Days:
            guard let threshold = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now)) else {
                return true
            }
            return date >= threshold
        }
    }
}

// MARK: - Presentation Helpers

enum FeedPresentation {
    static func filtered(
        _ items: [FeedItem],
        kindFilter: FeedKindFilter,
        timeFilter: FeedTimeFilter
    ) -> [FeedItem] {
        items.filter { item in
            kindFilter.includes(item) && timeFilter.includes(item.date)
        }
    }

    static func grouped(_ items: [FeedItem]) -> [(date: Date, items: [FeedItem])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: items) { item in
            calendar.startOfDay(for: item.date)
        }

        return grouped.keys.sorted(by: >).map { date in
            (date: date, items: grouped[date]!.sorted { $0.date > $1.date })
        }
    }
}

// MARK: - Feed Source Display

/// Title/subtitle/favicon for a feed item card.
struct FeedSourceDisplay {
    let title: String
    let subtitle: String?
    let faviconURL: URL?

    var rendersTightFavicon: Bool {
        guard let host = faviconURL?.query?.lowercased() else { return false }
        return host.contains("claude.ai") || host.contains("anthropic.com")
    }

    init(item: FeedItem) {
        if item.kind == .memo {
            title = "Voice memo"
            if let memoTitle = item.feedMemoTitle.feedTrimmed,
               memoTitle != item.text.feedNilIfEmpty {
                subtitle = memoTitle
            } else {
                subtitle = nil
            }
            faviconURL = nil
            return
        }

        if let website = BrowserWebsiteDisplay.from(
            windowTitle: item.windowTitle,
            browserURL: item.browserURL,
            bundleId: item.bundleId,
            browserNameOverride: item.appName
        ) {
            title = website.title
            subtitle = website.subtitle
            faviconURL = website.faviconURL
            return
        }

        let defaultTitle = item.kind == .memo ? "Voice memo" : "Dictation"
        let resolvedTitle = item.appName.feedTrimmed
            ?? item.contextLabel.feedTrimmed
            ?? defaultTitle
        let resolvedSubtitle = [
            item.contextLabel.feedTrimmed,
            item.windowTitle.feedTrimmed
        ]
        .compactMap { $0 }
        .first { $0 != resolvedTitle }

        title = resolvedTitle
        subtitle = resolvedSubtitle
        faviconURL = nil
    }

    var monogram: String {
        String(title.prefix(1)).uppercased()
    }
}

// MARK: - Feed Quick Action Button

/// Capsule action button used by feed item rows and detail panels.
struct FeedQuickActionButton: View {
    let title: String
    let systemImage: String
    var isDisabled = false
    var isDestructive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11, weight: .medium))
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Capsule())
                .background(backgroundColor)
                .foregroundStyle(foregroundColor)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(borderColor, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }

    private var backgroundColor: Color {
        if isDestructive {
            return SettingsPalette.destructiveFill
        }
        return SettingsPalette.cardBackground
    }

    private var borderColor: Color {
        if isDestructive {
            return SettingsPalette.destructiveBorder
        }
        return SettingsPalette.border.opacity(0.18)
    }

    private var foregroundColor: Color {
        isDestructive ? .red : .secondary
    }
}

// MARK: - Memo distillation default prompt

let kDefaultMemoDistillPrompt = "Summarize this memo into clear bullets with the key ideas, decisions, and next steps."

// MARK: - Feed string helpers

extension Optional where Wrapped == String {
    var feedTrimmed: String? {
        switch self {
        case .some(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .none:
            return nil
        }
    }
}

extension String {
    var feedNilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
