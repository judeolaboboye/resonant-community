import AppKit
import SwiftUI

/// Home tab — unified feed with sliding detail panel.
/// Replaces the old Feed, Memos, and Journal tabs.
struct HomeTabView: View {

    private static let detailPanelWidth: CGFloat = 380
    private static let feedMinWidth: CGFloat = 545

    @Environment(AppState.self) private var appState
    @Environment(\.layoutTier) private var layoutTier
    @StateObject private var playbackController = MemoPlaybackController()
    @State private var displayLimit = 40
    @State private var hostWindowReference = SettingsHostWindowReference()

    private var showsDetailPanel: Bool {
        layoutTier == .wide && appState.selectedFeedItemID != nil
    }

    /// Lifetime counter, so a user who cleared their history keeps the plain
    /// empty state instead of being taught the basics again.
    private var hasNeverDictated: Bool {
        appState.statsTracker.totalDictations == 0
    }

    var body: some View {
        let presentation = HomeFeedPresentationCache.presentation(
            items: appState.feedManager.items,
            feedVersion: appState.feedManager.version,
            searchText: appState.homeSearchText,
            kindFilter: appState.homeSearchKindFilter,
            timeFilter: appState.homeSearchTimeFilter,
            displayLimit: displayLimit
        )

        HStack(spacing: 0) {
            feedColumn(
                allItems: presentation.allItems,
                filteredItems: presentation.filteredItems,
                groupedItems: presentation.groupedItems,
                hasMore: presentation.hasMore
            )
            .frame(minWidth: Self.feedMinWidth, maxWidth: .infinity, maxHeight: .infinity)

            if showsDetailPanel {
                HomeDetailPanel(playbackController: playbackController)
                    .frame(width: Self.detailPanelWidth)
                    .frame(maxHeight: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(SettingsPalette.cardBackground)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(SettingsPalette.border, lineWidth: 0.5)
                    )
                    .resonantShadow(.raised)
                    .padding(.vertical, 12)
                    .padding(.trailing, 12)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: showsDetailPanel)
        .background(WindowAccessor { hostWindowReference.window = $0 })
        .onExitCommand {
            playbackController.stop()
            appState.selectedFeedItemID = nil
        }
        .onChange(of: appState.selectedFeedItemID) { oldValue, newValue in
            if oldValue != nil && newValue != oldValue {
                playbackController.stop()
            }
            if newValue != nil {
                ensureWideWindow()
            }
        }
    }

    /// When the user opens a feed item on a narrow window, force the window
    /// out to at least the `.wide` layout-tier width so the detail panel has
    /// room to appear. Otherwise the click looks like a no-op.
    private func ensureWideWindow() {
        // Defer the AppKit window mutation until the current SwiftUI update
        // finishes. Resizing the window directly from this selection change can
        // re-enter NSHostingView layout while lazy content is updating.
        DispatchQueue.main.async {
            guard let window = hostWindowReference.window ?? NSApp.keyWindow else { return }
            let targetWidth = LayoutTier.wideMinWidth + 20
            guard window.frame.size.width < targetWidth else { return }

            var newFrame = window.frame
            let delta = targetWidth - newFrame.size.width
            newFrame.size.width = targetWidth

            if let screenFrame = window.screen?.visibleFrame {
                // Grow to the right if possible, otherwise shift left so the frame
                // stays on-screen.
                if newFrame.maxX > screenFrame.maxX {
                    newFrame.origin.x = max(screenFrame.minX, screenFrame.maxX - newFrame.size.width)
                }
                newFrame.size.width = min(newFrame.size.width, screenFrame.size.width)
            } else {
                newFrame.origin.x -= delta / 2
            }

            window.setFrame(newFrame, display: false, animate: false)
        }
    }

    // MARK: - Feed Column

    @ViewBuilder
    private func feedColumn(
        allItems: [FeedItem],
        filteredItems: [FeedItem],
        groupedItems: [HomeFeedDayGroup],
        hasMore: Bool
    ) -> some View {
        VStack(spacing: 0) {
            if allItems.isEmpty {
                Spacer()
                if hasNeverDictated {
                    // First run: an empty feed is the moment to teach the one
                    // action the app is built around, with the trigger key the
                    // user actually has configured.
                    ContentUnavailableView(
                        "Try your first dictation",
                        systemImage: "mic",
                        description: Text(
                            "Hold \(appState.settingsManager.hotkeyTrigger.shortName) in any app and speak — "
                            + "your words land wherever your cursor is."
                        )
                    )
                } else {
                    ContentUnavailableView(
                        "Feed is empty",
                        systemImage: "tray",
                        description: Text("Your dictations and memos will appear here.")
                    )
                }
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        HomeTodayOverviewView()
                            .padding(.bottom, 32)

                        if filteredItems.isEmpty {
                            ContentUnavailableView(
                                "No matches",
                                systemImage: "magnifyingglass",
                                description: Text("Try a different search or filter.")
                            )
                            .padding(.top, 24)
                        } else {
                            VStack(alignment: .leading, spacing: 32) {
                                ForEach(groupedItems) { group in
                                    VStack(alignment: .leading, spacing: 8) {
                                        HomeDayHeaderView(date: group.date)
                                        HomeDayCard(sourceRuns: group.sourceRuns)
                                    }
                                }

                                if hasMore {
                                    Button("Show earlier entries") {
                                        displayLimit += 40
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 16)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                }
            }
        }
        .background(SettingsPalette.warmBackdrop)
    }
}

/// Non-observed holder for the enclosing window. This intentionally avoids
/// SwiftUI state invalidation from NSViewRepresentable update/layout callbacks.
final class SettingsHostWindowReference {
    weak var window: NSWindow?
}

/// Captures the enclosing NSWindow for a SwiftUI view tree.
struct WindowAccessor: NSViewRepresentable {
    let callback: (NSWindow?) -> Void

    func makeNSView(context: Context) -> WindowAccessorView {
        let view = WindowAccessorView(frame: .zero)
        view.callback = callback
        return view
    }

    func updateNSView(_ nsView: WindowAccessorView, context: Context) {
        nsView.callback = callback
        nsView.reportWindowIfChanged()
    }
}

final class WindowAccessorView: NSView {
    var callback: ((NSWindow?) -> Void)?

    private var reportedWindowID: ObjectIdentifier?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportWindowIfChanged()
    }

    func reportWindowIfChanged() {
        let currentWindow = window
        let currentWindowID = currentWindow.map(ObjectIdentifier.init)
        guard currentWindowID != reportedWindowID else { return }

        reportedWindowID = currentWindowID
        let callback = callback
        DispatchQueue.main.async {
            callback?(currentWindow)
        }
    }
}

private struct HomeFeedPresentation {
    let allItems: [FeedItem]
    let filteredItems: [FeedItem]
    let groupedItems: [HomeFeedDayGroup]
    let hasMore: Bool
}

private struct HomeFeedDayGroup: Identifiable {
    let date: Date
    let sourceRuns: [HomeFeedSourceRun]

    var id: Date { date }
}

private struct HomeFeedSourceRun: Identifiable {
    let id: UUID
    let items: [FeedItem]
    let source: FeedSourceDisplay
}

private struct HomeFeedPresentationKey: Equatable {
    let feedVersion: Int
    let searchText: String
    let kindFilter: FeedKindFilter
    let timeFilter: FeedTimeFilter
    let displayLimit: Int
    let day: Date
}

@MainActor
private enum HomeFeedPresentationCache {
    private static var cachedKey: HomeFeedPresentationKey?
    private static var cachedPresentation: HomeFeedPresentation?

    static func presentation(
        items: [FeedItem],
        feedVersion: Int,
        searchText: String,
        kindFilter: FeedKindFilter,
        timeFilter: FeedTimeFilter,
        displayLimit: Int
    ) -> HomeFeedPresentation {
        let key = HomeFeedPresentationKey(
            feedVersion: feedVersion,
            searchText: searchText,
            kindFilter: kindFilter,
            timeFilter: timeFilter,
            displayLimit: displayLimit,
            day: Calendar.current.startOfDay(for: Date())
        )

        if cachedKey == key, let cachedPresentation {
            return cachedPresentation
        }

        let searchedItems = search(searchText, in: items)
        let filteredItems = FeedPresentation.filtered(
            searchedItems,
            kindFilter: kindFilter,
            timeFilter: timeFilter
        )
        let hasMore = filteredItems.count > displayLimit
        let paginatedItems = Array(filteredItems.prefix(displayLimit))
        let groupedItems = FeedPresentation.grouped(paginatedItems).map { group in
            HomeFeedDayGroup(
                date: group.date,
                sourceRuns: sourceRuns(for: group.items)
            )
        }
        let presentation = HomeFeedPresentation(
            allItems: items,
            filteredItems: filteredItems,
            groupedItems: groupedItems,
            hasMore: hasMore
        )

        cachedKey = key
        cachedPresentation = presentation
        return presentation
    }

    private static func search(_ query: String, in items: [FeedItem]) -> [FeedItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return items }
        return items.filter {
            $0.text.lowercased().contains(q) ||
            ($0.appName?.lowercased().contains(q) ?? false) ||
            ($0.contextLabel?.lowercased().contains(q) ?? false) ||
            ($0.browserURL?.lowercased().contains(q) ?? false)
        }
    }

    private static func sourceRuns(for items: [FeedItem]) -> [HomeFeedSourceRun] {
        var result: [HomeFeedSourceRun] = []
        var currentItems: [FeedItem] = []
        var currentKey: String?
        var currentSource: FeedSourceDisplay?

        func flush() {
            guard let first = currentItems.first, let currentSource else { return }
            result.append(HomeFeedSourceRun(id: first.id, items: currentItems, source: currentSource))
            currentItems.removeAll(keepingCapacity: true)
        }

        for item in items {
            let source = FeedSourceDisplay(item: item)
            let key = sourceKey(item: item, source: source)
            if currentKey == key {
                currentItems.append(item)
            } else {
                flush()
                currentKey = key
                currentSource = source
                currentItems.append(item)
            }
        }

        flush()
        return result
    }

    private static func sourceKey(item: FeedItem, source: FeedSourceDisplay) -> String {
        "\(item.kind.rawValue)|\(source.title)|\(source.subtitle ?? "")"
    }
}

// MARK: - Search Modal (Command+K style)

struct HomeSearchModal: View {
    @Bindable var appState: AppState
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        let panelShape = RoundedRectangle(cornerRadius: 12, style: .continuous)

        ZStack {
            // Backdrop — click to dismiss
            Color.black.opacity(0.15)
                .ignoresSafeArea()
                .onTapGesture { closeSearch() }

            VStack(alignment: .leading, spacing: 14) {
                // Search field
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.tertiary)

                    TextField("Search feed...", text: $appState.homeSearchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .focused($isFieldFocused)

                    if !appState.homeSearchText.isEmpty {
                        Button { appState.homeSearchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }

                    Text("esc")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.quaternary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(SettingsPalette.elevatedBackground)
                        )
                }

                Divider()

                // Filter row
                HStack(spacing: 6) {
                    ForEach(FeedKindFilter.allCases, id: \.self) { filter in
                        HomePillButton(
                            title: filter.title,
                            isSelected: appState.homeSearchKindFilter == filter
                        ) { appState.homeSearchKindFilter = filter }
                    }

                    Spacer(minLength: 4)

                    Menu {
                        ForEach(FeedTimeFilter.allCases, id: \.self) { filter in
                            Button(filter.title) { appState.homeSearchTimeFilter = filter }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text(appState.homeSearchTimeFilter.title)
                                .font(.system(size: 11, weight: .medium))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 7, weight: .bold))
                        }
                        .foregroundStyle(appState.homeSearchTimeFilter == .allTime ? .secondary : SettingsPalette.infoText)
                        .padding(.horizontal, 10)
                        .frame(minHeight: SettingsLayout.controlMinHeight)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(appState.homeSearchTimeFilter == .allTime ? .clear : SettingsPalette.accentFill)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            .padding(16)
            .frame(width: 480)
            .background(
                panelShape
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(color: .black.opacity(0.22), radius: 28, x: 0, y: 10)
            )
            .overlay(
                panelShape.stroke(SettingsPalette.border.opacity(0.2), lineWidth: 0.5)
            )
            .offset(y: -60)
            .onAppear { isFieldFocused = true }
            .onExitCommand { closeSearch() }
        }
        .transition(.opacity)
    }

    private func closeSearch() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
            appState.isHomeSearchOpen = false
        }
    }
}

private struct HomePillButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isSelected ? SettingsPalette.infoText : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? SettingsPalette.accentFill : (isHovered ? SettingsPalette.elevatedBackground : .clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(isSelected ? SettingsPalette.accentBorder : .clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.14)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Today Overview (always shown at top of feed)

struct HomeTodayOverviewView: View {
    @Environment(AppState.self) private var appState

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12:  return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<21: return "Good evening"
        default:      return "Good night"
        }
    }

    private var signalSubtitle: String? {
        let signals = JournalSignalEngine.signals(from: appState.journalManager.days, referenceDate: Date())
        guard !signals.isEmpty else { return nil }
        if signals.count == 1 {
            return signals[0].title
        }
        return signals.prefix(2).map(\.title).joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(greeting)
                    .font(.system(size: 16, weight: .bold))

                if let subtitle = signalSubtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
            }

            HStack(spacing: 8) {
                MetricCell(
                    value: formatTime(Int(appState.statsTracker.minutesSaved)),
                    label: "saved",
                    icon: "clock.arrow.circlepath",
                    tint: .blue
                )
                MetricCell(
                    value: abbreviatedCount(appState.statsTracker.totalWords),
                    label: "words",
                    icon: "text.alignleft",
                    tint: .green
                )
                MetricCell(
                    value: abbreviatedCount(appState.statsTracker.totalDictations),
                    label: "sessions",
                    icon: "waveform",
                    tint: .orange
                )
                if appState.statsTracker.streakDays > 0 {
                    MetricCell(
                        value: "\(appState.statsTracker.streakDays)",
                        label: "streak",
                        icon: "flame",
                        tint: .red
                    )
                }
            }
        }
    }

    private func formatTime(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        let h = minutes / 60, m = minutes % 60
        return m > 0 ? "\(h)h \(m)m" : "\(h)h"
    }

    private func abbreviatedCount(_ count: Int) -> String {
        if count < 1000 { return "\(count)" }
        if count < 10_000 { return String(format: "%.1fk", Double(count) / 1000) }
        return "\(count / 1000)k"
    }
}

// MARK: - Day Header

struct HomeDayHeaderView: View {
    let date: Date

    private static let fallbackFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d"
        return formatter
    }()

    private var dateLabel: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return Self.fallbackFormatter.string(from: date)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(dateLabel)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)

            Spacer()
        }
    }
}

// MARK: - Metric Cell (hover reveals icon)

private struct MetricCell: View {
    let value: String
    let label: String
    let icon: String
    let tint: Color

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint.opacity(isHovered ? 0.8 : 0.4))

            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)

            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint.opacity(0.7))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(SettingsPalette.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(SettingsPalette.border, lineWidth: 0.5)
        )
        .resonantShadow(.resting)
        .animation(.spring(response: 0.2, dampingFraction: 0.8), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Day Card (grouped by source)

private struct HomeDayCard: View {
    let sourceRuns: [HomeFeedSourceRun]

    var body: some View {
        VStack(spacing: 8) {
            ForEach(sourceRuns) { run in
                HomeSourceGroup(items: run.items, source: run.source)
            }
        }
    }
}

// MARK: - Source Group (icon + header + stacked dictations)

private struct HomeSourceGroup: View {
    let items: [FeedItem]
    let source: FeedSourceDisplay
    @Environment(AppState.self) private var appState
    @State private var isHovered = false

    private var representative: FeedItem { items[0] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                HomeItemIcon(item: representative, source: source, size: 32)

                Text(source.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let subtitle = source.subtitle.map(truncateContext) {
                    Text("·")
                        .font(.system(size: 11))
                        .foregroundStyle(.quaternary)

                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                    HomeDictationRow(
                        item: item,
                        isSelected: appState.selectedFeedItemID == item.id
                    )
                    .onTapGesture { toggle(item) }

                    if idx < items.count - 1 {
                        Divider()
                            .opacity(0.4)
                            .padding(.horizontal, 8)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(SettingsPalette.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(SettingsPalette.border, lineWidth: 0.5)
        )
        .resonantShadow(isHovered ? .raised : .resting)
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: isHovered)
        .onHover { isHovered = $0 }
    }

    private func toggle(_ item: FeedItem) {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            if appState.selectedFeedItemID == item.id {
                appState.selectedFeedItemID = nil
            } else {
                appState.selectedFeedItemID = item.id
            }
        }
    }

    private func truncateContext(_ text: String) -> String {
        if text.contains("/") {
            let filename = (text as NSString).lastPathComponent
            if !filename.isEmpty { return filename }
        }
        if text.count > 45 { return String(text.prefix(42)) + "..." }
        return text
    }
}

// MARK: - Dictation Row (content-first)

private struct HomeDictationRow: View {
    let item: FeedItem
    let isSelected: Bool
    @State private var isHovered = false

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    private var shouldShowMetrics: Bool {
        (item.durationSeconds ?? 0) >= 20 || (item.wordCount ?? 0) >= 30
    }

    private var metricsText: String? {
        guard shouldShowMetrics else { return nil }
        var parts: [String] = []
        if let duration = item.feedDurationText { parts.append(duration) }
        if let words = item.feedWordCountText { parts.append(words) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.text)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let metricsText {
                    Text(metricsText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }

            trailingControl
                .fixedSize()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(rowBackground)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.14)) { isHovered = hovering }
        }
    }

    private var rowBackground: Color {
        if isSelected { return SettingsPalette.accentFill }
        if isHovered { return SettingsPalette.elevatedBackground.opacity(0.5) }
        return .clear
    }

    @ViewBuilder
    private var trailingControl: some View {
        ZStack(alignment: .trailing) {
            Text(formatTime(item.date))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .opacity(isHovered || isSelected ? 0 : 1)

            HStack(spacing: 3) {
                Text(isSelected ? "Close" : "Open")
                    .font(.system(size: 11, weight: .medium))
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .offset(x: isHovered ? 1 : 0)
                    .animation(.spring(response: 0.32, dampingFraction: 0.82), value: isHovered)
            }
            .foregroundStyle(SettingsPalette.infoText)
            .opacity(isHovered || isSelected ? 1 : 0)
        }
    }

    private func formatTime(_ date: Date) -> String {
        Self.timeFormatter.string(from: date)
    }
}

// MARK: - Item Icon (with favicon + app icon support)

@MainActor
private enum HomeAppIconCache {
    private static var iconsByBundleID: [String: NSImage] = [:]
    private static var missingBundleIDs: Set<String> = []

    static func icon(for bundleID: String?) -> NSImage? {
        guard let rawBundleID = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawBundleID.isEmpty
        else {
            return nil
        }

        let key = rawBundleID.lowercased()
        if let cached = iconsByBundleID[key] {
            return cached
        }
        if missingBundleIDs.contains(key) {
            return nil
        }

        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: rawBundleID) else {
            missingBundleIDs.insert(key)
            return nil
        }

        let image = NSWorkspace.shared.icon(forFile: appURL.path)
        iconsByBundleID[key] = image
        return image
    }
}

struct HomeItemIcon: View {
    let item: FeedItem
    let source: FeedSourceDisplay
    var size: CGFloat = 36

    private var cornerRadius: CGFloat { size * 0.26 }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(backgroundColor)

            iconContent
        }
        .frame(width: size, height: size)
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(SettingsPalette.border.opacity(0.22), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var iconContent: some View {
        if item.kind == .memo {
            Image(systemName: "mic.fill")
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.blue)
        } else if item.kind == .meeting {
            Image(systemName: "video.fill")
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.green)
        } else if let faviconURL = source.faviconURL {
            let scale: CGFloat = source.rendersTightFavicon ? 0.82 : 0.66
            AsyncImage(url: faviconURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: size * scale, height: size * scale)
                        .clipShape(RoundedRectangle(cornerRadius: size * 0.18, style: .continuous))
                default:
                    appIconFallback
                }
            }
        } else {
            appIconFallback
        }
    }

    @ViewBuilder
    private var appIconFallback: some View {
        if let icon = HomeAppIconCache.icon(for: item.bundleId) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size * 0.72, height: size * 0.72)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.18, style: .continuous))
        } else {
            Text(source.monogram)
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var backgroundColor: Color {
        switch item.kind {
        case .memo:    Color.blue.opacity(0.1)
        case .meeting: Color.green.opacity(0.1)
        default:       SettingsPalette.elevatedBackground
        }
    }
}
