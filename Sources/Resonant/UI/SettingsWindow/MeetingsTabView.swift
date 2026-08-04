import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// MARK: - Shared Card Container

/// Rounded card container matching the home feed visual language: gradient
/// fill + gradient stroke. Used throughout the Meetings tab so the list and
/// detail panels feel like the same surface.
private struct MeetingContentCard<Content: View>: View {
    var cornerRadius: CGFloat = 14
    var padding: EdgeInsets = EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
    /// Use flat fill + flat border for list-container cards (sections that
    /// stack vertically and hold a uniform list of rows). Hero/section tiles
    /// with heterogeneous content should keep the default gradient.
    var flat: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(strokeStyle, lineWidth: flat ? 0.5 : 1)
            )
    }

    private var fill: AnyShapeStyle {
        if flat {
            return AnyShapeStyle(SettingsPalette.cardBackground)
        }
        return AnyShapeStyle(
            LinearGradient(
                colors: [
                    SettingsPalette.cardBackground,
                    SettingsPalette.cardBackground.opacity(0.25)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var strokeStyle: AnyShapeStyle {
        if flat {
            return AnyShapeStyle(SettingsPalette.border.opacity(0.12))
        }
        return AnyShapeStyle(
            LinearGradient(
                colors: [
                    SettingsPalette.border.opacity(0.22),
                    SettingsPalette.border.opacity(0.04)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

private struct MeetingSectionHeader: View {
    let title: String
    let icon: String
    var count: Int? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
            if let count, count > 0 {
                Text("\(count)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(
                        Capsule(style: .continuous)
                            .fill(SettingsPalette.mutedCardBackground)
                    )
            }
            Spacer(minLength: 0)
        }
    }
}

private extension MeetingTimelineSection {
    var iconName: String {
        switch self {
        case .now:      return "dot.radiowaves.left.and.right"
        case .upcoming: return "calendar"
        case .recent:   return "clock.arrow.circlepath"
        case .earlier:  return "clock"
        case .recorded: return "waveform"
        }
    }
}

private enum NewMeetingCreationMode: String, Identifiable {
    case instantRecording
    case notesOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .instantRecording:
            return "Record ad-hoc meeting"
        case .notesOnly:
            return "Create notes-only meeting"
        }
    }

    var message: String {
        switch self {
        case .instantRecording:
            return "Starts recording immediately and opens the scratchpad, even when there is no calendar event to attach."
        case .notesOnly:
            return "Creates a meeting entry without a transcript so you can capture notes manually and keep it in your history."
        }
    }

    var confirmTitle: String {
        switch self {
        case .instantRecording:
            return "Start Recording"
        case .notesOnly:
            return "Create Meeting"
        }
    }

    var systemImage: String {
        switch self {
        case .instantRecording:
            return "record.circle"
        case .notesOnly:
            return "square.and.pencil"
        }
    }
}

private struct MeetingQuickActionTile: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var tint: Color = SettingsPalette.infoText
    var isProminent = false
    var isDisabled = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    tint.opacity(isHovered ? 0.32 : 0.22),
                                    tint.opacity(isHovered ? 0.18 : 0.10)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    Circle()
                        .stroke(tint.opacity(0.18), lineWidth: 0.5)
                    Image(systemName: systemImage)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(tint)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 116, alignment: .leading)
            .background(tileBackground)
            .overlay(tileBorder)
            .overlay(alignment: .top) {
                LinearGradient(
                    colors: [Color.white.opacity(isHovered ? 0.10 : 0.06), Color.clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 36)
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 14,
                        bottomLeadingRadius: 0,
                        bottomTrailingRadius: 0,
                        topTrailingRadius: 14,
                        style: .continuous
                    )
                )
                .allowsHitTesting(false)
            }
            .scaleEffect(isHovered && !isDisabled ? 1.015 : 1)
            .shadow(
                color: isProminent ? tint.opacity(isHovered ? 0.18 : 0.06) : Color.black.opacity(isHovered ? 0.06 : 0.02),
                radius: isHovered ? 12 : 6,
                y: isHovered ? 4 : 2
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: isHovered)
        .onHover { hovering in
            guard !isDisabled else { return }
            isHovered = hovering
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var tileBackground: some View {
        if isProminent {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            tint.opacity(isHovered ? 0.20 : 0.14),
                            tint.opacity(isHovered ? 0.08 : 0.05)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.regularMaterial)
                )
        } else {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(SettingsPalette.cardBackground.opacity(isHovered ? 0.55 : 0.7))
                )
        }
    }

    private var tileBorder: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(
                isProminent
                    ? tint.opacity(isHovered ? 0.45 : 0.28)
                    : SettingsPalette.border.opacity(isHovered ? 0.28 : 0.14),
                lineWidth: 0.75
            )
    }
}

struct MeetingsTabView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.layoutTier) private var layoutTier
    private static let autosaveDelay: Duration = .milliseconds(700)
    private static let detailPanelWidth: CGFloat = 380
    private static let feedMinWidth: CGFloat = 545
    private struct SharedRecapURLCacheEntry {
        let url: URL
        let expiresAt: Date

        func isValid(now: Date = Date()) -> Bool {
            now < expiresAt
        }
    }

    @State private var selectedItemID: String?
    @State private var searchText = ""
    @State private var titleDraft = ""
    @State private var userNotesDraft = ""
    @State private var postNoteDraft = ""
    @State private var speakerAliasDrafts: [String: String] = [:]
    @State private var didCopyTranscript = false
    @State private var sharedRecapURLsByMeetingID: [UUID: SharedRecapURLCacheEntry] = [:]
    @State private var sharingRecapMeetingID: UUID?
    @State private var showHowItWorks = false
    @State private var showClearAllConfirm = false
    @State private var meetings: [MeetingEntry] = []
    @State private var calendarEvents: [MeetingCalendarEvent] = []
    @State private var calendarRefreshTimer: Timer?
    @State private var hostWindowReference = SettingsHostWindowReference()
    @State private var calendarAuthStatus: MeetingCalendarAuthorizationStatus?
    @State private var hasCompletedCalendarRefresh = false
    @State private var calendarRefreshSummary: MeetingCalendarEventRefreshSummary?
    @State private var isRequestingCalendarAccess = false
    @State private var isImporting = false
    @State private var isRefreshingMeetingList = false
    @State private var autosaveTask: Task<Void, Never>?
    @State private var isDistillingMeeting = false
    @State private var newMeetingCreationMode: NewMeetingCreationMode?
    @State private var historyDisplayLimit = 40
    private static let historyPageSize = 40

    private var timelineItems: [MeetingTimelineItem] {
        MeetingTimelineBuilder.build(
            calendarEvents: calendarEvents,
            meetings: meetings,
            activeSession: appState.meetingRecorderManager?.activeSession,
            hiddenCalendarEventIDs: Set(appState.settingsManager.meetingTimelineHiddenEventIDs),
            ignoredCalendarEventIDs: Set(appState.settingsManager.meetingTimelineIgnoredEventIDs)
        )
    }

    private var filteredTimelineItems: [MeetingTimelineItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { return timelineItems }
        let normalized = query.lowercased()
        return timelineItems.filter { item in
            item.displayTitle.lowercased().contains(normalized)
                || (item.detectedAppName?.lowercased().contains(normalized) ?? false)
                || (item.organizerName?.lowercased().contains(normalized) ?? false)
                || item.attendeeNames.contains(where: { $0.lowercased().contains(normalized) })
        }
    }

    private var selectedTimelineItem: MeetingTimelineItem? {
        guard let id = selectedItemID else { return nil }
        return filteredTimelineItems.first { $0.id == id } ?? timelineItems.first { $0.id == id }
    }

    private var groupedTimelineItems: [(section: MeetingTimelineSection, items: [MeetingTimelineItem])] {
        MeetingTimelineSection.allCases.compactMap { section in
            let items = filteredTimelineItems.filter { $0.section == section }
            guard !items.isEmpty else { return nil }
            return (section, items)
        }
    }

    /// Items that belong to "Today" — anything happening now plus everything
    /// dated today. Recording-now is pinned first, then `.now`, then today's
    /// chronological list.
    private var todayHeroItems: [MeetingTimelineItem] {
        let calendar = Calendar.current
        let items = filteredTimelineItems.filter { item in
            item.section == .now || calendar.isDateInToday(item.sortDate)
        }
        return items.sorted { lhs, rhs in
            if lhs.status == .recording && rhs.status != .recording { return true }
            if rhs.status == .recording && lhs.status != .recording { return false }
            if lhs.section == .now && rhs.section != .now { return true }
            if rhs.section == .now && lhs.section != .now { return false }
            return lhs.sortDate < rhs.sortDate
        }
    }

    /// Everything not in the Today hero, newest first, ready to be grouped by
    /// date for the History feed.
    private var historyItems: [MeetingTimelineItem] {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        return filteredTimelineItems
            .filter { item in
                item.section != .now && item.sortDate < startOfToday
            }
            .sorted { $0.sortDate > $1.sortDate }
    }

    /// Today is always rendered in full — pagination only applies to history
    /// so the active day never gets truncated. While searching the user has
    /// already narrowed the set, so we skip paginating then too.
    private var paginatedHistoryItems: [MeetingTimelineItem] {
        if isSearchActive { return historyItems }
        return Array(historyItems.prefix(historyDisplayLimit))
    }

    private var hasMoreHistory: Bool {
        !isSearchActive && historyItems.count > historyDisplayLimit
    }

    private var isSearchActive: Bool {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
    }

    /// History grouped by week-of-year so the feed reads as one continuous
    /// "History" section with light week dividers, instead of one card per day.
    private var historyGroups: [(weekStart: Date, label: String, items: [MeetingTimelineItem])] {
        let calendar = Calendar.current
        var order: [Date] = []
        var groups: [Date: [MeetingTimelineItem]] = [:]

        for item in paginatedHistoryItems {
            let weekStart = calendar.dateInterval(of: .weekOfYear, for: item.sortDate)?.start
                ?? calendar.startOfDay(for: item.sortDate)
            if groups[weekStart] == nil {
                order.append(weekStart)
                groups[weekStart] = []
            }
            groups[weekStart]?.append(item)
        }
        return order.map { start in
            (weekStart: start, label: Self.historyWeekLabel(for: start), items: groups[start] ?? [])
        }
    }

    private static func historyWeekLabel(for weekStart: Date) -> String {
        let calendar = Calendar.current
        let now = Date()
        let nowWeekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start
            ?? calendar.startOfDay(for: now)

        if calendar.isDate(weekStart, inSameDayAs: nowWeekStart) { return "This Week" }
        if let lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: nowWeekStart),
           calendar.isDate(weekStart, inSameDayAs: lastWeek) {
            return "Last Week"
        }

        let weekEnd = calendar.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
        let formatter = DateFormatter()
        if calendar.component(.year, from: weekStart) == calendar.component(.year, from: now),
           calendar.component(.year, from: weekEnd) == calendar.component(.year, from: now) {
            formatter.setLocalizedDateFormatFromTemplate("MMM d")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("MMM d, yyyy")
        }
        return "\(formatter.string(from: weekStart)) – \(formatter.string(from: weekEnd))"
    }

    private static let rowDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE, MMM d")
        return f
    }()

    /// Compact date stamp shown on each history row so the feed no longer needs
    /// per-day section headers.
    private static func historyRowDateLabel(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return rowDateFormatter.string(from: date)
    }

    private var showsDetailPanel: Bool {
        layoutTier == .wide && selectedTimelineItem != nil
    }

    var body: some View {
        let hasContent = !timelineItems.isEmpty || (appState.meetingRecorderManager?.isRecording ?? false)

        Group {
            if !hasContent {
                emptyState
            } else {
                HStack(spacing: 0) {
                    meetingList
                        .frame(minWidth: Self.feedMinWidth, maxWidth: .infinity, maxHeight: .infinity)

                    if showsDetailPanel {
                        detailPanel
                            .frame(width: Self.detailPanelWidth)
                            .frame(maxHeight: .infinity)
                            .background(SettingsPalette.warmBackdrop)
                            .overlay(alignment: .leading) {
                                Rectangle()
                                    .fill(SettingsPalette.border.opacity(0.18))
                                    .frame(width: 0.5)
                                    .allowsHitTesting(false)
                            }
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.32, dampingFraction: 0.86), value: showsDetailPanel)
            }
        }
        .overlay {
            if showHowItWorks {
                MeetingHowItWorksModal(isPresented: $showHowItWorks)
                    .transition(.opacity)
            }
        }
        .sheet(item: $newMeetingCreationMode) { mode in
            NewMeetingCreationSheet(mode: mode) { title in
                switch mode {
                case .instantRecording:
                    startInstantMeetingRecording(title: title)
                case .notesOnly:
                    createOfflineNotesMeeting(title: title)
                }
            }
        }
        .background(WindowAccessor { hostWindowReference.window = $0 })
        .onChange(of: selectedItemID) { oldValue, newValue in
            if newValue != nil {
                ensureWideWindow()
            }
            if newValue != oldValue,
               let newValue,
               newValue.hasPrefix("meeting:"),
               let meeting = selectedTimelineItem?.meeting {
                appState.analyticsManager.capture("meeting_opened", properties: [
                    "has_summary": (meeting.summary?.isEmpty == false),
                    "has_distilled": (meeting.distilledSummary?.isEmpty == false),
                    "age_days": Int(Date().timeIntervalSince(meeting.startedAt) / 86_400)
                ])
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: showHowItWorks)
        .confirmationDialog(
            "Delete all \(meetings.count) meetings?",
            isPresented: $showClearAllConfirm
        ) {
            Button("Delete All", role: .destructive) { clearAllMeetings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete all meeting transcripts and audio. This cannot be undone.")
        }
        .task(id: appState.meetingRecorderManager?.isRecording) {
            await loadMeetings()
        }
        .task(id: appState.meetingDataVersion) {
            // Bumps after each MeetingEntry write (save pipeline finish, summary
            // land, manual edits). Without this, the meetings tab snapshot lags
            // behind SwiftData and freshly-saved meetings vanish until refresh.
            await loadMeetings()
        }
        .task(id: appState.settingsManager.meetingUseCalendarHints) {
            await refreshCalendarEvents()
        }
        .task(id: appState.meetingCalendarDataVersion) {
            await refreshCalendarEvents()
        }
        .onAppear {
            startCalendarRefreshTimer()
        }
        .onChange(of: searchText) { _, newValue in
            // When the user clears the search, reset to the first page so the
            // list doesn't stay expanded into hundreds of historical meetings.
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 {
                historyDisplayLimit = Self.historyPageSize
            }
        }
        .onChange(of: titleDraft) { _, _ in
            scheduleAutosaveIfNeeded()
        }
        .onChange(of: userNotesDraft) { _, _ in
            scheduleAutosaveIfNeeded()
        }
        .onChange(of: postNoteDraft) { _, _ in
            scheduleAutosaveIfNeeded()
        }
        .onChange(of: speakerAliasDrafts) { _, _ in
            scheduleAutosaveIfNeeded()
        }
        .onDisappear {
            stopCalendarRefreshTimer()
            flushAutosaveIfNeeded()
        }
    }

    private func loadMeetings() async {
        let descriptor = FetchDescriptor<MeetingEntry>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        meetings = await appState.dataStore.fetchInBackground(descriptor)
            .filter { $0.activeJSONLPath == nil }
    }

    /// Grow the window out to the wide layout tier so the detail panel has
    /// room to slide in when the user clicks a meeting.
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

    private var howItWorksButton: some View {
        Button {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                showHowItWorks = true
            }
        } label: {
            Label("How it works", systemImage: "questionmark.circle")
                .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Learn how meeting detection and recording work")
        .accessibilityLabel("How meetings work")
    }

    private var refreshButton: some View {
        Button {
            Task {
                await refreshMeetingList()
            }
        } label: {
            ZStack {
                Image(systemName: "arrow.clockwise")
                    .opacity(isRefreshingMeetingList ? 0 : 1)

                if isRefreshingMeetingList {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(width: 14, height: 14)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isRefreshingMeetingList || isRequestingCalendarAccess)
        .help("Refresh meetings")
        .accessibilityLabel("Refresh meetings")
    }

    private var canStartInstantMeeting: Bool {
        guard let manager = appState.meetingRecorderManager else { return false }
        return !manager.isRecording && !manager.isFinalizing
    }

    private var quickStartLabel: some View {
        Text("Quick start")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.5)
    }

    private var quickActionDescription: some View {
        Text("Record ad-hoc, create notes-only entries, or import audio without waiting for a calendar match.")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var quickActionTileRow: some View {
        HStack(spacing: 10) {
            instantRecordingTile
            offlineNotesTile
            importAudioTile
        }
    }

    private var quickActionTileStack: some View {
        VStack(alignment: .leading, spacing: 8) {
            instantRecordingTile
            offlineNotesTile
            importAudioTile
        }
    }

    private var quickActionTiles: some View {
        quickActionTileRow
    }

    private var instantRecordingTile: some View {
        MeetingQuickActionTile(
            title: "Record now",
            subtitle: "Start an ad-hoc recording — title auto-fills from time.",
            systemImage: "record.circle",
            tint: .red,
            isProminent: true,
            isDisabled: !canStartInstantMeeting
        ) {
            startInstantMeetingRecording(title: nil)
        }
    }

    private var offlineNotesTile: some View {
        MeetingQuickActionTile(
            title: "Notes only",
            subtitle: "Create a meeting entry without recording audio.",
            systemImage: "square.and.pencil",
            tint: SettingsPalette.infoText
        ) {
            newMeetingCreationMode = .notesOnly
        }
    }

    private var importAudioTile: some View {
        MeetingQuickActionTile(
            title: "Import audio",
            subtitle: "Turn an existing call recording into a meeting.",
            systemImage: "square.and.arrow.down",
            tint: .green,
            isDisabled: isImporting
        ) {
            importAudioFile()
        }
    }

    @ViewBuilder
    private var quickActionProgressIndicator: some View {
        if isImporting {
            ProgressView()
                .controlSize(.small)
        }
    }

    private var meetingUtilityCard: some View {
        MeetingContentCard(
            padding: EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12),
            flat: true
        ) {
            HStack(alignment: .center, spacing: 10) {
                quickActionSplitButton
                quickActionProgressIndicator

                searchField
                    .frame(maxWidth: .infinity)
                    .layoutPriority(1)

                refreshButton
                howItWorksButton
            }
        }
    }

    private var quickActionSplitButton: some View {
        HStack(spacing: 0) {
            Button {
                startInstantMeetingRecording(title: nil)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "record.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.red)
                    Text("New meeting")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .padding(.leading, 12)
                .padding(.trailing, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canStartInstantMeeting)

            Rectangle()
                .fill(SettingsPalette.border.opacity(0.18))
                .frame(width: 0.5, height: 16)

            Menu {
                Button {
                    newMeetingCreationMode = .notesOnly
                } label: {
                    Label("Notes only", systemImage: "square.and.pencil")
                }

                Button {
                    importAudioFile()
                } label: {
                    Label("Import audio", systemImage: "square.and.arrow.down")
                }
                .disabled(isImporting)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: SettingsLayout.controlMinHeight, height: SettingsLayout.controlMinHeight)
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .background(
            Capsule(style: .continuous)
                .fill(SettingsPalette.cardBackground)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(SettingsPalette.border.opacity(0.18), lineWidth: 0.5)
        )
        .fixedSize(horizontal: true, vertical: false)
        .help("Click to start recording. Use the chevron for Notes only / Import audio.")
    }

    private var quickActionsCard: some View {
        MeetingContentCard(
            padding: EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14),
            flat: true
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Quick start")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Create an ad hoc meeting even when nothing is on the calendar.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 12)

                    quickActionProgressIndicator
                }

                quickActionTiles
                quickActionDescription
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        let settings = appState.settingsManager
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                emptySetupChecklist(settings: settings)
                calendarAccessBanner
                calendarConnectedEmptyBanner
                if settings.meetingRecordingEnabled {
                    quickActionsCard
                }
                emptySkeletonPreview
            }
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 32)
            .padding(.top, 48)
            .padding(.bottom, 40)
        }
        .background(SettingsPalette.warmBackdrop)
    }

    @ViewBuilder
    private func emptySetupChecklist(settings: SettingsManager) -> some View {
        let recordingEnabled = Binding<Bool>(
            get: { settings.meetingRecordingEnabled },
            set: { enabled in
                let shouldPrepare = enabled && settings.meetingRecordingEnabled != enabled
                settings.meetingRecordingEnabled = enabled
                guard shouldPrepare else { return }
                Task {
                    await appState.ensureMeetingRecordingSetupAuthorization()
                    await refreshCalendarEvents()
                }
            }
        )
        let calendarHintsEnabled = Binding<Bool>(
            get: { settings.meetingUseCalendarHints },
            set: { enabled in
                let shouldRequestAccess = enabled && settings.meetingUseCalendarHints != enabled
                settings.meetingUseCalendarHints = enabled
                guard shouldRequestAccess else { return }
                requestCalendarAccess()
            }
        )
        let autoStartEnabled = Binding<Bool>(
            get: { settings.meetingAutoStartEnabled },
            set: { enabled in
                let shouldPrepare = enabled && settings.meetingAutoStartEnabled != enabled
                settings.meetingAutoStartEnabled = enabled
                guard shouldPrepare else { return }
                Task {
                    await appState.ensureMeetingAutomationSetupAuthorization()
                    await refreshCalendarEvents()
                }
            }
        )

        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Image(systemName: "video.badge.waveform")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(SettingsPalette.infoText)
                    Text("Set up meetings")
                        .font(.system(size: 17, weight: .semibold))
                }

                Text("Enable recording, connect your calendar, and Resonant will show scheduled calls here before they start.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            VStack(spacing: 0) {
                emptyChecklistToggle(
                    title: "Enable meeting recording",
                    subtitle: "Allow Resonant to transcribe calls when you ask it to.",
                    isOn: recordingEnabled
                )
                Divider().padding(.leading, 44)
                emptyChecklistToggle(
                    title: "Use calendar hints",
                    subtitle: "Surface scheduled meetings and past uncaptured calls in this tab.",
                    isOn: calendarHintsEnabled
                )
                Divider().padding(.leading, 44)
                emptyChecklistToggle(
                    title: "Auto-start when a meeting begins",
                    subtitle: "Start recording when a known meeting app becomes active.",
                    isOn: autoStartEnabled,
                    disabled: !settings.meetingRecordingEnabled
                )
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)

            HStack {
                Button {
                    appState.isShowingSettings = true
                    appState.selectedSettingsTab = .meetingSettings
                } label: {
                    Label("Open meeting settings", systemImage: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(SettingsPalette.infoText)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        .background(SettingsPalette.elevatedBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(SettingsPalette.border.opacity(0.5), lineWidth: 0.5)
        )
    }

    private func emptyChecklistToggle(
        title: String,
        subtitle: String,
        isOn: Binding<Bool>,
        disabled: Bool = false
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isOn.wrappedValue ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16))
                .foregroundStyle(isOn.wrappedValue ? AnyShapeStyle(Color.green) : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
                .frame(width: 20)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(disabled ? .secondary : .primary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .disabled(disabled)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .opacity(disabled ? 0.5 : 1)
    }

    private var emptySkeletonPreview: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Text("What this tab will show")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.7)
                Spacer()
                Text("Preview")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous)
                            .fill(SettingsPalette.mutedCardBackground)
                    )
            }

            VStack(alignment: .leading, spacing: 16) {
                skeletonSection(
                    title: "Upcoming",
                    icon: "calendar",
                    rows: [
                        .init(title: "Design review", meta: "Google Meet · 30 min", statusTint: .secondary),
                        .init(title: "1:1 with Alex", meta: "Zoom · 45 min", statusTint: .secondary),
                    ]
                )

                skeletonSection(
                    title: "Earlier",
                    icon: "clock.arrow.circlepath",
                    rows: [
                        .init(title: "Weekly team sync", meta: "Zoom · Not captured", statusTint: .orange),
                        .init(title: "Customer call", meta: "Teams · Not captured", statusTint: .orange),
                    ]
                )
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(SettingsPalette.elevatedBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(SettingsPalette.border.opacity(0.5), lineWidth: 0.5)
        )
    }

    private func skeletonSection(
        title: String,
        icon: String,
        rows: [SkeletonRowData]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.5)
            }

            VStack(spacing: 6) {
                ForEach(rows) { row in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(row.statusTint.opacity(0.35))
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text(row.meta)
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(SettingsPalette.mutedCardBackground.opacity(0.6))
                    )
                }
            }
        }
    }

    private struct SkeletonRowData: Identifiable {
        let id = UUID()
        let title: String
        let meta: String
        let statusTint: Color
    }

    // MARK: - Meeting List

    private var meetingList: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    meetingUtilityCard
                        .padding(.bottom, 16)

                    if shouldShowCalendarAccessBanner {
                        calendarAccessBanner
                            .padding(.bottom, 16)
                    } else if shouldShowCalendarConnectedEmptyBanner {
                        calendarConnectedEmptyBanner
                            .padding(.bottom, 16)
                    }

                    if let manager = appState.meetingRecorderManager,
                       manager.isRecording,
                       manager.activeSession?.captureContext?.calendarEventID == nil {
                        MeetingContentCard(
                            padding: EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12),
                            flat: true
                        ) {
                            MeetingActiveRow(manager: manager) {
                                appState.showActiveMeetingCompanion()
                            }
                        }
                        .padding(.bottom, 16)
                    }

                    VStack(alignment: .leading, spacing: 24) {
                        if !todayHeroItems.isEmpty {
                            feedDayGroup(label: "Meetings", items: todayHeroItems)
                        }

                        if !historyGroups.isEmpty {
                            feedHistorySection(groups: historyGroups)
                        }

                        if hasMoreHistory {
                            Button {
                                historyDisplayLimit += Self.historyPageSize
                            } label: {
                                Text("Show earlier meetings")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(SettingsPalette.infoText)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 16)
            }
        }
        .background(SettingsPalette.warmBackdrop)
    }

    /// Day-grouped card matching the home feed's visual rhythm: a small day
    /// label above a rounded card that stacks rows separated by faint dividers.
    @ViewBuilder
    private func feedDayGroup(label: String, items: [MeetingTimelineItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                    feedRow(for: item)

                    if idx < items.count - 1 {
                        Divider()
                            .opacity(0.4)
                            .padding(.horizontal, 8)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(SettingsPalette.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(SettingsPalette.border.opacity(0.12), lineWidth: 0.5)
            )
        }
    }

    /// Single "History" card containing all past meetings, with light week
    /// sub-headers ("This Week", "Last Week", "Apr 13 – Apr 19", …) inline.
    @ViewBuilder
    private func feedHistorySection(
        groups: [(weekStart: Date, label: String, items: [MeetingTimelineItem])]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("History")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(groups.enumerated()), id: \.offset) { groupIdx, group in
                    Text(group.label)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                        .tracking(0.5)
                        .padding(.horizontal, 8)
                        .padding(.top, groupIdx == 0 ? 2 : 14)
                        .padding(.bottom, 6)

                    ForEach(Array(group.items.enumerated()), id: \.element.id) { idx, item in
                        feedRow(for: item, dateLabel: Self.historyRowDateLabel(for: item.sortDate))

                        if idx < group.items.count - 1 {
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
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(SettingsPalette.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(SettingsPalette.border.opacity(0.12), lineWidth: 0.5)
            )
        }
    }

    @ViewBuilder
    private func feedRow(for item: MeetingTimelineItem, dateLabel: String? = nil) -> some View {
        MeetingFeedRow(
            item: item,
            isSelected: selectedItemID == item.id,
            isAutoRecordArmed: isAutoRecordArmed(for: item),
            dateLabel: dateLabel,
            onPrimaryAction: { handlePrimaryAction(for: item) },
            onToggleAutoRecord: {
                if let event = item.calendarEvent {
                    toggleAutoRecord(for: event)
                }
            }
        )
        .contentShape(Rectangle())
        .onTapGesture { select(item: item) }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
            TextField("Search meetings", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(SettingsPalette.mutedCardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(SettingsPalette.border.opacity(0.22), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func timelineRow(_ item: MeetingTimelineItem) -> some View {
        MeetingTimelineRow(
            item: item,
            isSelected: selectedItemID == item.id,
            isAutoRecordArmed: isAutoRecordArmed(for: item),
            onPrimaryAction: { handlePrimaryAction(for: item) },
            onToggleAutoRecord: {
                if let event = item.calendarEvent {
                    toggleAutoRecord(for: event)
                }
            }
        )
        .contentShape(Rectangle())
        .onTapGesture { select(item: item) }
    }

    private func sectionEyebrow(icon: String, title: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
            Spacer(minLength: 0)
            Text("\(count)")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(
                    Capsule(style: .continuous)
                        .fill(SettingsPalette.mutedCardBackground)
                )
        }
        .padding(.horizontal, 4)
    }

    private var todayHeroCard: some View {
        MeetingContentCard(
            padding: EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14),
            flat: true
        ) {
            VStack(alignment: .leading, spacing: 10) {
                sectionEyebrow(icon: "sun.max", title: "Today", count: todayHeroItems.count)

                VStack(spacing: 0) {
                    ForEach(Array(todayHeroItems.enumerated()), id: \.element.id) { idx, item in
                        timelineRow(item)
                        if idx < todayHeroItems.count - 1 {
                            Divider()
                                .opacity(0.3)
                                .padding(.horizontal, 4)
                        }
                    }
                }
            }
        }
    }

    private var historyCard: some View {
        MeetingContentCard(
            padding: EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14),
            flat: true
        ) {
            VStack(alignment: .leading, spacing: 10) {
                sectionEyebrow(icon: "clock.arrow.circlepath", title: "History", count: historyItems.count)

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(historyGroups.enumerated()), id: \.offset) { groupIdx, group in
                        Text(group.label)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .textCase(.uppercase)
                            .tracking(0.5)
                            .padding(.horizontal, 4)
                            .padding(.top, groupIdx == 0 ? 2 : 10)
                            .padding(.bottom, 2)

                        VStack(spacing: 0) {
                            ForEach(Array(group.items.enumerated()), id: \.element.id) { idx, item in
                                MeetingTimelineRow(
                                    item: item,
                                    isSelected: selectedItemID == item.id,
                                    isAutoRecordArmed: false,
                                    density: .compact,
                                    onPrimaryAction: { handlePrimaryAction(for: item) }
                                )
                                .contentShape(Rectangle())
                                .onTapGesture { select(item: item) }

                                if idx < group.items.count - 1 {
                                    Divider()
                                        .opacity(0.3)
                                        .padding(.horizontal, 4)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func refreshCalendarEvents() async {
        let source = appState.calendarHintSource
        let status = source.authorizationStatus
        calendarAuthStatus = status

        guard appState.settingsManager.meetingUseCalendarHints else {
            calendarEvents = []
            hasCompletedCalendarRefresh = false
            calendarRefreshSummary = nil
            return
        }

        guard status == .authorized else {
            calendarEvents = []
            hasCompletedCalendarRefresh = true
            calendarRefreshSummary = nil
            return
        }

        let result = await source.calendarEventRefreshResultForMeetingsTab()
        calendarEvents = result.events
        calendarRefreshSummary = result.summary
        hasCompletedCalendarRefresh = true
    }

    private func refreshMeetingList() async {
        guard !isRefreshingMeetingList else { return }

        isRefreshingMeetingList = true
        defer { isRefreshingMeetingList = false }

        await loadMeetings()
        await refreshCalendarEvents()
    }

    private func requestCalendarAccess() {
        Task {
            let source = appState.calendarHintSource
            if !appState.settingsManager.meetingUseCalendarHints {
                appState.settingsManager.meetingUseCalendarHints = true
            }
            calendarAuthStatus = source.authorizationStatus

            defer { isRequestingCalendarAccess = false }
            isRequestingCalendarAccess = true
            let granted = await appState.ensureMeetingCalendarAuthorization()

            await refreshCalendarEvents()
            let status = source.authorizationStatus
            calendarAuthStatus = status
            if granted || status == .authorized {
                await appState.refreshMeetingDetection()
            } else if status == .denied {
                openCalendarPrivacySettings()
            }
        }
    }

    private func openCalendarPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    private var shouldShowCalendarAccessBanner: Bool {
        guard appState.settingsManager.meetingUseCalendarHints else { return false }
        guard let status = calendarAuthStatus else { return false }
        return status != .authorized
    }

    private var shouldShowCalendarConnectedEmptyBanner: Bool {
        appState.settingsManager.meetingUseCalendarHints
            && calendarAuthStatus == .authorized
            && hasCompletedCalendarRefresh
            && calendarEvents.isEmpty
    }

    private var calendarConnectedEmptyDetail: String {
        guard let summary = calendarRefreshSummary, summary.didFetchEvents else {
            return "No calendar events with attendees or call links were found in the last 14 days or next 7 days."
        }

        if summary.fetchedEventCount == 0 {
            return "Apple Calendar returned no events in the last 14 days or next 7 days."
        }

        if summary.nonAllDayEventCount == 0 {
            return "Apple Calendar returned \(summary.fetchedEventCount) events in this window, but all of them are all-day events."
        }

        if summary.meetingLikeEventCount == 0 {
            return "Apple Calendar returned \(summary.nonAllDayEventCount) timed events in this window, but none had attendees, call links, or known meeting keywords."
        }

        return "Apple Calendar returned \(summary.meetingLikeEventCount) meeting-like events, but none could be converted into meeting rows."
    }

    @ViewBuilder
    private var calendarAccessBanner: some View {
        if shouldShowCalendarAccessBanner {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: calendarAuthStatus == .denied ? "calendar.badge.exclamationmark" : "calendar.badge.plus")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(calendarAuthStatus == .denied ? AnyShapeStyle(Color.orange) : AnyShapeStyle(SettingsPalette.infoText))
                    .frame(width: 20)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    Text(calendarAuthStatus == .denied ? "Calendar access blocked" : "Connect Apple Calendar")
                        .font(.system(size: 13, weight: .semibold))
                    Text(calendarAuthStatus == .denied
                         ? "Resonant can't read your calendar. Grant access in System Settings to see upcoming meetings here."
                         : "Resonant reads calendars available to macOS. Google Calendar events appear here after they are synced into Apple Calendar.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Button {
                    if calendarAuthStatus == .denied {
                        openCalendarPrivacySettings()
                    } else {
                        requestCalendarAccess()
                    }
                } label: {
                    Text(calendarAuthStatus == .denied ? "Open Settings" : "Connect")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isRequestingCalendarAccess)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(SettingsPalette.accentFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(SettingsPalette.accentBorder, lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private var calendarConnectedEmptyBanner: some View {
        if shouldShowCalendarConnectedEmptyBanner {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "calendar.badge.checkmark")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.green)
                    .frame(width: 20)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Apple Calendar connected")
                        .font(.system(size: 13, weight: .semibold))
                    Text(calendarConnectedEmptyDetail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(SettingsPalette.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(SettingsPalette.border.opacity(0.14), lineWidth: 0.5)
            )
        }
    }

    private func startCalendarRefreshTimer() {
        calendarRefreshTimer?.invalidate()
        calendarRefreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in
                await refreshCalendarEvents()
            }
        }
    }

    private func stopCalendarRefreshTimer() {
        calendarRefreshTimer?.invalidate()
        calendarRefreshTimer = nil
    }

    // MARK: - Detail Panel

    @ViewBuilder
    private var detailPanel: some View {
        if let item = selectedTimelineItem {
            if let meeting = item.meeting {
                MeetingDetailPanel(
                    meeting: meeting,
                    titleDraft: $titleDraft,
                    userNotesDraft: $userNotesDraft,
                    postNoteDraft: $postNoteDraft,
                    speakerAliasDrafts: $speakerAliasDrafts,
                    didCopyTranscript: $didCopyTranscript,
                    resolvedUserDisplayName: appState.settingsManager.resolvedEmailSignoffName,
                    resolvedUserEmail: appState.settingsManager.userEmail,
                    webhookConfigured: appState.settingsManager.meetingWebhookEnabled
                        && !appState.settingsManager.meetingWebhookURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    onSaveChanges: {
                        Task {
                            await saveMeetingChanges(for: meeting)
                        }
                    },
                    onCopyTranscript: { copyTranscript(for: meeting) },
                    onCopyRecap: { copyRecap(for: meeting) },
                    onRequestPrivateLink: { openPrivateLinkRequest(for: meeting) },
                    onRequestWorkspaceSharing: { openWorkspaceSharingContact(for: meeting) },
                    onSharePublicRecap: { delivery in sharePublicRecap(for: meeting, delivery: delivery) },
                    onDelete: { deleteMeeting(meeting) },
                    onDistill: { prompt in distillMeeting(meeting, prompt: prompt) },
                    onOpenSharedRecap: { url in openSharedRecap(url, for: meeting) },
                    isDistilling: isDistillingMeeting,
                    isSharingRecap: sharingRecapMeetingID == meeting.id,
                    sharedRecapURL: cachedSharedRecapURL(for: meeting.id)
                )
            } else if let event = item.calendarEvent {
                MeetingCalendarDetailPanel(
                    item: item,
                    isAutoRecordArmed: isAutoRecordArmed(for: event),
                    notesDraft: $userNotesDraft,
                    onRecord: { handleRecord(for: event) },
                    onRebind: { handleRebind(to: event) },
                    onImportAudio: { importAudioFile(for: event) },
                    onAddManualNotes: { createManualNotesMeeting(for: event) },
                    onToggleIgnored: { toggleIgnored(for: event) },
                    onToggleAutoRecord: { toggleAutoRecord(for: event) },
                    onHide: { hideEventFromTimeline(event) }
                )
            }
        } else {
            VStack {
                Spacer()
                Text("Pick a meeting from the left")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SettingsPalette.warmBackdrop)
        }
    }

    // MARK: - Actions

    private func select(item: MeetingTimelineItem) {
        let previousMeeting = selectedTimelineItem?.meeting
        flushAutosaveIfNeeded(for: previousMeeting)
        selectedItemID = item.id
        if let meeting = item.meeting {
            titleDraft = meeting.customTitle ?? ""
            userNotesDraft = meeting.userNotes ?? ""
            postNoteDraft = meeting.postMeetingNotes ?? ""
            speakerAliasDrafts = meeting.speakerAliases
            didCopyTranscript = false
        } else {
            titleDraft = item.calendarEvent?.title ?? ""
            userNotesDraft = ""
            postNoteDraft = ""
            speakerAliasDrafts = [:]
            didCopyTranscript = false
        }
    }

    private func meetingDraftsDiffer(from meeting: MeetingEntry) -> Bool {
        let titleTrimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let userTrimmed = userNotesDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let postTrimmed = postNoteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSpeakerAliases = MeetingSpeakerAliasResolver.normalized(speakerAliasDrafts)

        return titleTrimmed != (meeting.customTitle ?? "")
            || userTrimmed != (meeting.userNotes ?? "")
            || postTrimmed != (meeting.postMeetingNotes ?? "")
            || normalizedSpeakerAliases != meeting.speakerAliases
    }

    private func scheduleAutosaveIfNeeded() {
        autosaveTask?.cancel()

        if let meeting = selectedTimelineItem?.meeting {
            guard meetingDraftsDiffer(from: meeting) else { return }

            let meetingID = meeting.id
            autosaveTask = Task { @MainActor in
                try? await Task.sleep(for: Self.autosaveDelay)
                guard !Task.isCancelled,
                      let selectedMeeting = selectedTimelineItem?.meeting,
                      selectedMeeting.id == meetingID,
                      meetingDraftsDiffer(from: selectedMeeting)
                else {
                    return
                }

                await saveMeetingChanges(for: selectedMeeting, reloadTimeline: false)
            }
        } else if let event = selectedTimelineItem?.calendarEvent {
            let trimmed = userNotesDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            let eventID = event.id
            autosaveTask = Task { @MainActor in
                try? await Task.sleep(for: Self.autosaveDelay)
                guard !Task.isCancelled,
                      selectedTimelineItem?.calendarEvent?.id == eventID,
                      selectedTimelineItem?.meeting == nil
                else {
                    return
                }
                await promoteCalendarEventToMeetingWithNotes(event: event)
            }
        }
    }

    private func promoteCalendarEventToMeetingWithNotes(event: MeetingCalendarEvent) async {
        let typedNotes = userNotesDraft
        let typedTitle = titleDraft
        let meeting = await appState.createManualNotesMeeting(for: event)
        await loadMeetings()

        // Preserve the user's in-flight drafts across the view flip instead of
        // letting select(item:) wipe them back to the MeetingEntry's empty state.
        selectedItemID = "meeting:\(meeting.id.uuidString)"
        titleDraft = typedTitle.isEmpty ? (meeting.customTitle ?? "") : typedTitle
        userNotesDraft = typedNotes
        postNoteDraft = meeting.postMeetingNotes ?? ""
        speakerAliasDrafts = meeting.speakerAliases
        didCopyTranscript = false

        await saveMeetingChanges(for: meeting, reloadTimeline: false)
    }

    private func flushAutosaveIfNeeded(for meeting: MeetingEntry? = nil) {
        autosaveTask?.cancel()
        autosaveTask = nil

        if let meeting = meeting ?? selectedTimelineItem?.meeting {
            guard meetingDraftsDiffer(from: meeting) else { return }
            Task {
                await saveMeetingChanges(for: meeting, reloadTimeline: false)
            }
        } else if let event = selectedTimelineItem?.calendarEvent,
                  !userNotesDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Task {
                await promoteCalendarEventToMeetingWithNotes(event: event)
            }
        }
    }

    private func handlePrimaryAction(for item: MeetingTimelineItem) {
        if let event = item.calendarEvent {
            if item.isBoundToActiveRecording {
                return
            }
            if appState.meetingRecorderManager?.isRecording == true {
                handleRebind(to: event)
            } else {
                handleRecord(for: event)
            }
        }
    }

    private func handleRecord(for event: MeetingCalendarEvent) {
        Task {
            await appState.startMeetingRecording(
                suggestedTitle: event.title,
                captureContext: event.captureContext(origin: .manual),
                startOrigin: .calendar
            )
            await loadMeetings()
            await refreshCalendarEvents()
        }
    }

    private func startInstantMeetingRecording(title: String?) {
        let normalizedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let userProvided = (normalizedTitle?.isEmpty == false) ? normalizedTitle : nil
        let resolvedTitle = userProvided ?? Self.suggestedInstantMeetingTitle()

        Task {
            await appState.startMeetingRecording(
                suggestedTitle: resolvedTitle,
                captureContext: .adHoc(title: resolvedTitle, recordingOrigin: .manual),
                startOrigin: .quickStart
            )
            await loadMeetings()
            await refreshCalendarEvents()
        }
    }

    /// Pick a default title for an instant meeting: detect a running meeting
    /// app (Zoom, Teams, Meet, etc.) and name it after the host, otherwise
    /// fall back to a date-based label like "Meeting · Apr 26, 4:50 PM".
    private static func suggestedInstantMeetingTitle(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d, h:mm a")
        let timestamp = formatter.string(from: now)

        if let host = detectedMeetingHostName() {
            return "\(host) · \(timestamp)"
        }
        return "Meeting · \(timestamp)"
    }

    private static func detectedMeetingHostName() -> String? {
        let ownBundle = Bundle.main.bundleIdentifier
        let candidates = NSWorkspace.shared.runningApplications.filter { app in
            guard let bundleID = app.bundleIdentifier?.lowercased(),
                  bundleID != ownBundle?.lowercased()
            else { return false }
            return MeetingContextDetector.nativeMeetingBundleIDs.contains(bundleID)
        }

        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.lowercased()
        let preferred = candidates.first { $0.bundleIdentifier?.lowercased() == frontmost }
            ?? candidates.first

        guard let app = preferred,
              let name = app.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty
        else { return nil }
        return name
    }

    private func createOfflineNotesMeeting(title: String?) {
        let normalizedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveTitle = normalizedTitle?.isEmpty == true ? nil : normalizedTitle

        Task {
            let meeting = await appState.createAdHocManualNotesMeeting(title: effectiveTitle)
            await loadMeetings()
            selectRecordedMeeting(meeting)
        }
    }

    private func handleRebind(to event: MeetingCalendarEvent) {
        Task {
            await appState.rebindActiveMeeting(to: event)
            await loadMeetings()
        }
    }

    private func toggleIgnored(for event: MeetingCalendarEvent) {
        var ids = Set(appState.settingsManager.meetingTimelineIgnoredEventIDs)
        if ids.contains(event.id) {
            ids.remove(event.id)
        } else {
            ids.insert(event.id)
        }
        appState.settingsManager.meetingTimelineIgnoredEventIDs = Array(ids).sorted()
    }

    private func isAutoRecordArmed(for event: MeetingCalendarEvent) -> Bool {
        appState.settingsManager.meetingTimelineAutoRecordEventIDs.contains(event.id)
    }

    private func isAutoRecordArmed(for item: MeetingTimelineItem) -> Bool {
        guard let eventID = item.calendarEvent?.id else { return false }
        return appState.settingsManager.meetingTimelineAutoRecordEventIDs.contains(eventID)
    }

    private func toggleAutoRecord(for event: MeetingCalendarEvent) {
        var ids = Set(appState.settingsManager.meetingTimelineAutoRecordEventIDs)
        if ids.contains(event.id) {
            ids.remove(event.id)
        } else {
            ids.insert(event.id)
        }
        appState.settingsManager.meetingTimelineAutoRecordEventIDs = Array(ids).sorted()
    }

    private func hideEventFromTimeline(_ event: MeetingCalendarEvent) {
        var ids = Set(appState.settingsManager.meetingTimelineHiddenEventIDs)
        ids.insert(event.id)
        appState.settingsManager.meetingTimelineHiddenEventIDs = Array(ids).sorted()
        if selectedTimelineItem?.calendarEvent?.id == event.id {
            selectedItemID = nil
        }
    }

    private func createManualNotesMeeting(for event: MeetingCalendarEvent) {
        Task {
            let meeting = await appState.createManualNotesMeeting(for: event)
            await loadMeetings()
            selectRecordedMeeting(meeting)
        }
    }

    private func selectRecordedMeeting(_ meeting: MeetingEntry) {
        let itemID = "meeting:\(meeting.id.uuidString)"
        selectedItemID = itemID
        select(item: MeetingTimelineItem(
            id: itemID,
            section: .recorded,
            status: .recorded,
            sortDate: meeting.startedAt,
            meeting: meeting,
            calendarEvent: nil,
            hasActiveRecording: appState.meetingRecorderManager?.activeSession != nil,
            isBoundToActiveRecording: false
        ))
    }

    private func saveMeetingChanges(for meeting: MeetingEntry, reloadTimeline: Bool = true) async {
        let titleTrimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let userTrimmed = userNotesDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let postTrimmed = postNoteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTitle = titleTrimmed.isEmpty ? nil : titleTrimmed
        let normalizedUserNotes = userTrimmed.isEmpty ? nil : userTrimmed
        let normalizedPostNotes = postTrimmed.isEmpty ? nil : postTrimmed
        let previousSpeakerAliases = meeting.speakerAliases
        let normalizedSpeakerAliases = MeetingSpeakerAliasResolver.normalized(speakerAliasDrafts)

        meeting.customTitle = normalizedTitle
        meeting.userNotes = normalizedUserNotes
        meeting.postMeetingNotes = normalizedPostNotes
        meeting.speakerAliases = normalizedSpeakerAliases
        appState.feedManager.updateMeetingTitle(id: meeting.id, title: meeting.displayTitle)

        let meetingID = meeting.id
        _ = await appState.dataStore.performBackgroundWrite { context in
            var descriptor = FetchDescriptor<MeetingEntry>(
                predicate: #Predicate { $0.id == meetingID }
            )
            descriptor.fetchLimit = 1
            guard let persisted = try? context.fetch(descriptor).first else { return }
            persisted.customTitle = normalizedTitle
            persisted.userNotes = normalizedUserNotes
            persisted.postMeetingNotes = normalizedPostNotes
            persisted.speakerAliases = normalizedSpeakerAliases
        }

        // Update the markdown file on disk so exported meetings stay addressable by title.
        if let path = meeting.markdownPath {
            let effectiveTitle = MeetingMarkdownExporter.effectiveTitle(
                appName: meeting.detectedApp,
                customTitle: meeting.customTitle
            )
            let headingTitle = MeetingMarkdownExporter.headingTitle(
                startedAt: meeting.startedAt,
                customTitle: meeting.customTitle
            )
            await Self.patchMeetingMarkdownFile(
                atRelativePath: path,
                effectiveTitle: effectiveTitle,
                headingTitle: headingTitle,
                userNotes: userTrimmed,
                postMeetingNotes: postTrimmed,
                oldSpeakerAliases: previousSpeakerAliases,
                newSpeakerAliases: normalizedSpeakerAliases
            )
        }
        if reloadTimeline {
            await loadMeetings()
        }
    }

    private nonisolated static func patchMeetingMarkdownFile(
        atRelativePath path: String,
        effectiveTitle: String,
        headingTitle: String,
        userNotes: String,
        postMeetingNotes: String,
        oldSpeakerAliases: MeetingSpeakerAliasMap,
        newSpeakerAliases: MeetingSpeakerAliasMap
    ) async {
        let url = AppSupportPaths.resonantRoot().appendingPathComponent(path)
        await Task.detached(priority: .utility) {
            guard var content = try? String(contentsOf: url, encoding: .utf8) else { return }
            content = Self.patchMarkdownFrontmatter(content, title: effectiveTitle)
            content = Self.patchMarkdownHeading(content, title: headingTitle)
            content = Self.patchMarkdownTranscriptSpeakers(
                content,
                oldSpeakerAliases: oldSpeakerAliases,
                newSpeakerAliases: newSpeakerAliases
            )
            content = Self.patchMarkdownSpeakerFrontmatter(content, speakerAliases: newSpeakerAliases)
            content = Self.patchMarkdownSection(content, heading: "Notes", body: userNotes)
            content = Self.patchMarkdownSection(content, heading: "Post-Meeting Notes", body: postMeetingNotes)
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }.value
    }

    private nonisolated static func patchMarkdownTranscriptSpeakers(
        _ content: String,
        oldSpeakerAliases: MeetingSpeakerAliasMap,
        newSpeakerAliases: MeetingSpeakerAliasMap
    ) -> String {
        let lines = content.components(separatedBy: "\n")
        let normalizedOldAliases = MeetingSpeakerAliasResolver.normalized(oldSpeakerAliases)
        let normalizedNewAliases = MeetingSpeakerAliasResolver.normalized(newSpeakerAliases)
        var updatedLines: [String] = []
        updatedLines.reserveCapacity(lines.count)
        var inTranscript = false

        for line in lines {
            if line.hasPrefix("## Transcript") {
                inTranscript = true
                updatedLines.append(line)
                continue
            }
            if inTranscript && line.hasPrefix("## ") {
                inTranscript = false
            }

            if inTranscript,
               let header = MeetingTranscriptSupport.parseHeaderLine(
                line,
                speakerAliases: normalizedOldAliases
               ) {
                updatedLines.append(
                    MeetingTranscriptSupport.headerLine(
                        speakerKey: header.speakerKey,
                        timestamp: header.timestamp,
                        speakerAliases: normalizedNewAliases
                    )
                )
            } else {
                updatedLines.append(line)
            }
        }

        return updatedLines.joined(separator: "\n")
    }

    private nonisolated static func patchMarkdownSpeakerFrontmatter(
        _ content: String,
        speakerAliases: MeetingSpeakerAliasMap
    ) -> String {
        var lines = content.components(separatedBy: "\n")
        guard lines.first == "---",
              let closingIndex = lines[1...].firstIndex(of: "---") else {
            return content
        }

        let normalizedAliases = MeetingSpeakerAliasResolver.normalized(speakerAliases)
        var speakerLabels = Set<String>()
        var inTranscript = false
        for line in lines {
            if line.hasPrefix("## Transcript") {
                inTranscript = true
                continue
            }
            if inTranscript && line.hasPrefix("## ") {
                inTranscript = false
            }
            guard inTranscript,
                  let label = MeetingTranscriptSupport.parseHeaderLine(
                    line,
                    speakerAliases: normalizedAliases
                  )?.speakerLabel
            else {
                continue
            }
            speakerLabels.insert(label)
        }
        let sortedSpeakerLabels = speakerLabels.sorted()
        let speakersLine = "speakers: [" + sortedSpeakerLabels.map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" }.joined(separator: ", ") + "]"

        var frontmatter = Array(lines[1..<closingIndex])
        if let speakersIndex = frontmatter.firstIndex(where: { $0.hasPrefix("speakers:") }) {
            frontmatter[speakersIndex] = speakersLine
        } else {
            frontmatter.append(speakersLine)
        }

        lines.replaceSubrange(0...closingIndex, with: ["---"] + frontmatter + ["---"])
        return lines.joined(separator: "\n")
    }

    private nonisolated static func patchMarkdownSection(_ content: String, heading: String, body: String) -> String {
        var result = content
        let marker = "\n## \(heading)\n"

        if let range = result.range(of: marker) {
            let afterSection = result[range.upperBound...]
            if let nextHeading = afterSection.range(of: "\n## ") {
                result.removeSubrange(range.lowerBound..<nextHeading.lowerBound)
            } else {
                result.removeSubrange(range.lowerBound...)
                if !result.hasSuffix("\n") { result += "\n" }
            }
        }

        if !body.isEmpty {
            if !result.hasSuffix("\n") { result += "\n" }
            result += "\n## \(heading)\n\n\(body)\n"
        }

        return result
    }

    private nonisolated static func patchMarkdownFrontmatter(_ content: String, title: String) -> String {
        var lines = content.components(separatedBy: "\n")
        guard lines.first == "---",
              let closingIndex = lines[1...].firstIndex(of: "---") else {
            return content
        }

        var frontmatter = Array(lines[1..<closingIndex])
        let titleLine = "title: \(yamlQuoted(title))"
        if let existingIndex = frontmatter.firstIndex(where: { $0.hasPrefix("title:") }) {
            frontmatter[existingIndex] = titleLine
        } else if let idIndex = frontmatter.firstIndex(where: { $0.hasPrefix("id:") }) {
            frontmatter.insert(titleLine, at: frontmatter.index(after: idIndex))
        } else {
            frontmatter.insert(titleLine, at: 0)
        }

        lines.replaceSubrange(0...closingIndex, with: ["---"] + frontmatter + ["---"])
        return lines.joined(separator: "\n")
    }

    private nonisolated static func patchMarkdownHeading(_ content: String, title: String) -> String {
        let lines = content.components(separatedBy: "\n")
        guard let headingIndex = lines.firstIndex(where: { $0.hasPrefix("# ") }) else {
            return content
        }

        var updatedLines = lines
        updatedLines[headingIndex] = "# \(title)"
        return updatedLines.joined(separator: "\n")
    }

    private nonisolated static func yamlQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func copyTranscript(for meeting: MeetingEntry) {
        guard let path = meeting.markdownPath else { return }
        let url = AppSupportPaths.resonantRoot().appendingPathComponent(path)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        guard let transcript = MeetingMarkdownExporter.extractTranscript(from: content) else {
            appState.notchCoordinator.showError("Transcript section missing", subtype: .generic)
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript, forType: .string)
        didCopyTranscript = true
        appState.analyticsManager.capture("meeting_transcript_copied")
    }

    private func copyRecap(for meeting: MeetingEntry) {
        guard let recap = MeetingRecapShareBuilder.localRecapText(for: meeting) else {
            appState.notchCoordinator.showError("Add a summary before copying", subtype: .generic)
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(recap, forType: .string)
        if selectedTimelineItem?.meeting?.id == meeting.id {
            appState.notchCoordinator.showDone("Recap copied")
        }
        appState.analyticsManager.capture("meeting_recap_copied", properties: [
            "meeting_id": meeting.id.uuidString,
            "delivery": "local_clipboard",
            "character_count": recap.count
        ])
    }

    private func openPrivateLinkRequest(for meeting: MeetingEntry) {
        guard let url = MeetingRecapShareBuilder.privateLinkRequestURL(meetingTitle: meeting.displayTitle) else { return }
        NSWorkspace.shared.open(url)
        appState.analyticsManager.capture("meeting_recap_private_link_requested", properties: [
            "meeting_id": meeting.id.uuidString
        ])
    }

    private func openWorkspaceSharingContact(for meeting: MeetingEntry) {
        guard let url = MeetingRecapShareBuilder.workspaceSharingContactURL(meetingTitle: meeting.displayTitle) else { return }
        NSWorkspace.shared.open(url)
        appState.analyticsManager.capture("meeting_recap_workspace_sharing_contact_started", properties: [
            "meeting_id": meeting.id.uuidString
        ])
    }

    private func sharePublicRecap(for meeting: MeetingEntry, delivery: MeetingRecapPublicLinkDelivery) {
        guard AppFeatureVisibility.hostedServices else { return }
        guard sharingRecapMeetingID == nil else { return }
        if let existingShare = sharedRecapURLsByMeetingID[meeting.id] {
            if existingShare.isValid() {
                deliverSharedRecap(existingShare.url, for: meeting, delivery: delivery)
                return
            }
            sharedRecapURLsByMeetingID[meeting.id] = nil
        }

        guard let payload = MeetingRecapShareBuilder.payload(for: meeting) else {
            appState.notchCoordinator.showError("Add a summary before sharing", subtype: .generic)
            return
        }

        guard appState.authManager.isLoggedIn else {
            appState.notchCoordinator.showError("Sign in to share recaps", subtype: .generic)
            return
        }

        sharingRecapMeetingID = meeting.id
        let startedAt = Date()

        Task {
            do {
                let expiresInDays = MeetingRecapSharePolicy.defaultExpirationDays
                let result = try await appState.convexClient.createMeetingRecapShare(
                    payload: payload,
                    expiresInDays: expiresInDays
                )
                deliverSharedRecap(result.url, for: meeting, delivery: delivery)
                sharedRecapURLsByMeetingID[meeting.id] = SharedRecapURLCacheEntry(
                    url: result.url,
                    expiresAt: Date().addingTimeInterval(TimeInterval(expiresInDays) * 24 * 60 * 60)
                )
                appState.analyticsManager.capture("meeting_recap_shared", properties: [
                    "meeting_id": meeting.id.uuidString,
                    "recap_id": result.recapId,
                    "share_id": result.shareId,
                    "share_host": result.url.host ?? "",
                    "delivery": delivery.rawValue,
                    "expires_in_days": expiresInDays,
                    "latency_ms": max(0, Int(Date().timeIntervalSince(startedAt) * 1000)),
                    "attendee_count": payload.attendees.count,
                    "decision_count": payload.decisions.count,
                    "action_item_count": payload.actionItems.count
                ])
            } catch {
                appState.notchCoordinator.showError("Could not share recap", subtype: .generic)
                appState.analyticsManager.capture("meeting_recap_share_failed", properties: [
                    "meeting_id": meeting.id.uuidString,
                    "latency_ms": max(0, Int(Date().timeIntervalSince(startedAt) * 1000)),
                    "error": String(describing: error)
                ])
            }
            sharingRecapMeetingID = nil
        }
    }

    private func cachedSharedRecapURL(for meetingID: UUID) -> URL? {
        guard let existingShare = sharedRecapURLsByMeetingID[meetingID],
              existingShare.isValid()
        else {
            return nil
        }
        return existingShare.url
    }

    private func deliverSharedRecap(
        _ url: URL,
        for meeting: MeetingEntry,
        delivery: MeetingRecapPublicLinkDelivery
    ) {
        switch delivery {
        case .copyLink:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
            if selectedTimelineItem?.meeting?.id == meeting.id {
                appState.notchCoordinator.showDone("Recap link copied")
            }
            appState.analyticsManager.capture("meeting_recap_share_link_copied", properties: [
                "meeting_id": meeting.id.uuidString,
                "share_host": url.host ?? ""
            ])
        case .email:
            guard let emailURL = MeetingRecapShareBuilder.emailShareURL(
                meetingTitle: meeting.displayTitle,
                shareURL: url
            ) else {
                appState.notchCoordinator.showError("Could not open email", subtype: .generic)
                return
            }
            NSWorkspace.shared.open(emailURL)
            if selectedTimelineItem?.meeting?.id == meeting.id {
                appState.notchCoordinator.showDone("Email draft opened")
            }
            appState.analyticsManager.capture("meeting_recap_share_email_started", properties: [
                "meeting_id": meeting.id.uuidString,
                "share_host": url.host ?? ""
            ])
        }
    }

    private func openSharedRecap(_ url: URL, for meeting: MeetingEntry) {
        NSWorkspace.shared.open(url)
        appState.analyticsManager.capture("meeting_recap_share_opened_from_app", properties: [
            "meeting_id": meeting.id.uuidString,
            "share_host": url.host ?? ""
        ])
    }

    private func distillMeeting(_ meeting: MeetingEntry, prompt: String) {
        guard AppFeatureVisibility.hostedServices else { return }
        guard let path = meeting.markdownPath else { return }
        let url = AppSupportPaths.resonantRoot().appendingPathComponent(path)
        guard let markdown = try? String(contentsOf: url, encoding: .utf8) else { return }
        guard let transcript = MeetingMarkdownExporter.extractTranscript(from: markdown) else {
            appState.notchCoordinator.showError("Transcript section missing", subtype: .generic)
            return
        }

        guard appState.authManager.isLoggedIn else {
            appState.notchCoordinator.showError("Sign in to distill meetings", subtype: .generic)
            return
        }

        isDistillingMeeting = true
        let requestText = "\(prompt)\n\nMeeting: \(meeting.displayTitle)\n\nTranscript:\n\(transcript)"
        let distillStartedAt = Date()

        Task {
            let result = await appState.convexClient.processMemo(
                text: requestText
            )?.trimmingCharacters(in: .whitespacesAndNewlines)

            let latencyMs = Int(Date().timeIntervalSince(distillStartedAt) * 1000)
            if let result, !result.isEmpty {
                meeting.distilledSummary = result
                appState.dataStore.saveChanges()
                appState.analyticsManager.capture("meeting_distilled", properties: [
                    "transcript_length": transcript.count,
                    "result_length": result.count,
                    "latency_ms": latencyMs
                ])
            } else {
                appState.analyticsManager.capture("meeting_distill_failed", properties: [
                    "transcript_length": transcript.count,
                    "latency_ms": latencyMs
                ])
            }
            isDistillingMeeting = false
        }
    }

    private func deleteMeeting(_ meeting: MeetingEntry) {
        if selectedTimelineItem?.meeting?.id == meeting.id {
            selectedItemID = nil
        }
        appState.analyticsManager.capture("meeting_deleted")
        Task {
            await appState.deleteMeetings([meeting])
            await loadMeetings()
        }
    }

    private func importAudioFile() {
        importAudioFile(for: nil)
    }

    private func importAudioFile(for event: MeetingCalendarEvent?) {
        let panel = NSOpenPanel()
        panel.title = "Import Meeting Recording"
        panel.allowedContentTypes = [.audio, .mpeg4Audio, .mp3, .wav, .aiff]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let manager = appState.meetingRecorderManager else { return }

        appState.analyticsManager.capture("meeting_import_requested", properties: [
            "via_calendar": event != nil,
            "file_extension": url.pathExtension.lowercased()
        ])

        isImporting = true
        let importStartedAt = Date()
        Task {
            let succeeded: Bool
            if let event {
                succeeded = await appState.importMeetingAudio(for: event, url: url)
            } else {
                succeeded = await manager.importAudioFile(url: url)
            }
            let latencyMs = Int(Date().timeIntervalSince(importStartedAt) * 1000)
            appState.analyticsManager.capture(
                succeeded ? "meeting_imported" : "meeting_import_failed",
                properties: [
                    "via_calendar": event != nil,
                    "file_extension": url.pathExtension.lowercased(),
                    "latency_ms": latencyMs
                ]
            )
            isImporting = false
            await loadMeetings()
        }
    }

    private func clearAllMeetings() {
        selectedItemID = nil
        let allMeetings = meetings
        appState.analyticsManager.capture("meeting_all_cleared", properties: [
            "count": allMeetings.count
        ])
        Task {
            await appState.deleteMeetings(allMeetings)
            await loadMeetings()
        }
    }
}

private struct NewMeetingCreationSheet: View {
    let mode: NewMeetingCreationMode
    let onConfirm: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: mode.systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(SettingsPalette.infoText)
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(SettingsPalette.accentFill)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.title)
                        .font(.system(size: 18, weight: .semibold))
                    Text(mode.message)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Meeting title")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Optional title", text: $title)
                    .textFieldStyle(.roundedBorder)
            }

            Text("You can leave the title blank and rename the meeting later.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            HStack(spacing: 10) {
                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(mode.confirmTitle) {
                    onConfirm(title)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 430)
    }
}

// MARK: - Active Recording Row

private struct MeetingActiveRow: View {
    let manager: MeetingRecorderManager
    let onOpenCompanion: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(.green)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text("Recording...")
                    .font(.system(size: 13, weight: .medium))
                if let activeSubtitle {
                    Text(activeSubtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Text(formatElapsed(manager.recordingElapsed))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Button(action: onOpenCompanion) {
                Label("Open", systemImage: "sidebar.right")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(8)
        .background(.green.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var activeSubtitle: String? {
        if let title = manager.activeSession?.captureContext?.effectiveTitle {
            return title
        }
        if let app = manager.activeSession?.detectedApp {
            return app.name
        }
        return manager.activeSession?.captureContext?.recordingOrigin.untitledMeetingLabel
    }

    private func formatElapsed(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Timeline Row

private struct MeetingTimelineRow: View {
    enum Density { case full, compact }

    let item: MeetingTimelineItem
    let isSelected: Bool
    var isAutoRecordArmed: Bool = false
    var density: Density = .full
    let onPrimaryAction: () -> Void
    var onToggleAutoRecord: () -> Void = {}

    @State private var isHovered = false

    private var canArmAutoRecord: Bool {
        item.calendarEvent != nil && (item.status == .upcoming || item.status == .now)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE MMM d"
        return f
    }()

    private var isRecurringEvent: Bool {
        item.calendarEvent?.isRecurring ?? false
    }

    private var occurrenceDateLabel: String? {
        // For recurring events, show the day so two rows of the same series are distinguishable.
        // Skip if the occurrence is today — today's time is already in trailingControl.
        guard isRecurringEvent, let date = item.calendarEvent?.startDate else { return nil }
        if Calendar.current.isDateInToday(date) { return nil }
        return Self.dayFormatter.string(from: date)
    }

    private var metadataText: String {
        var parts: [String] = []
        if let occurrenceDateLabel {
            parts.append(occurrenceDateLabel)
        }
        if !item.durationText.isEmpty {
            parts.append(item.durationText)
        }
        if let typeLabel = item.meetingsTabTypeLabel {
            parts.append(typeLabel)
        }
        if let provider = provider {
            parts.append(provider.displayName)
        } else if let appName = item.detectedAppName {
            parts.append(appName)
        }
        if let organizer = item.organizerName {
            parts.append(organizer)
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    private var provider: MeetingProvider? {
        MeetingProvider.from(url: item.conferencingURL)
            ?? MeetingProvider.from(appName: item.detectedAppName)
    }

    private static let maxAvatars = 4

    private var visibleAttendees: [String] {
        Array(item.attendeeNames.prefix(Self.maxAvatars))
    }

    private var attendeeOverflow: Int {
        max(0, item.attendeeNames.count - Self.maxAvatars)
    }

    /// One-line snippet for the row, prioritising the most-refined source we
    /// have (custom distill > AI summary > user's live notes). Strips markdown
    /// and trims to ~140 chars so a row with a long summary doesn't dominate.
    private var notesPreview: String? {
        let candidates: [String?] = [
            item.meeting?.distilledSummary,
            item.meeting?.summary,
            item.meeting?.userNotes,
            item.meeting?.postMeetingNotes
        ]
        guard let raw = candidates
            .compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty })
        else { return nil }

        let stripped = raw
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "`", with: "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        if stripped.count > 140 {
            return String(stripped.prefix(140)) + "…"
        }
        return stripped
    }

    private var iconSize: CGFloat { density == .compact ? 22 : 28 }
    private var avatarSize: CGFloat { density == .compact ? 16 : 18 }
    private var verticalPadding: CGFloat { density == .compact ? 6 : 10 }

    private var displayedMetadata: String {
        density == .compact ? compactMetadataText : metadataText
    }

    /// Compact metadata leads with start time so the History feed reads as a
    /// chronological agenda, then keeps the most useful identifiers (provider,
    /// duration). Type/organizer drop out to keep one line.
    private var compactMetadataText: String {
        var parts: [String] = [Self.compactTimeFormatter.string(from: item.startedAt)]
        if !item.durationText.isEmpty {
            parts.append(item.durationText)
        }
        if let provider = provider {
            parts.append(provider.displayName)
        } else if let appName = item.detectedAppName {
            parts.append(appName)
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    private static let compactTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    var body: some View {
        HStack(alignment: density == .compact ? .center : .top, spacing: 10) {
            if let provider = provider {
                MeetingProviderBadge(provider: provider, size: iconSize)
            } else if let symbolName = item.meetingsTabSymbolName {
                ZStack {
                    RoundedRectangle(cornerRadius: density == .compact ? 6 : 7, style: .continuous)
                        .fill(item.meetingsTabSymbolTint.opacity(0.14))
                        .frame(width: iconSize, height: iconSize)
                    Image(systemName: symbolName)
                        .font(.system(size: density == .compact ? 11 : 12, weight: .semibold))
                        .foregroundStyle(item.meetingsTabSymbolTint)
                }
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: density == .compact ? 6 : 7, style: .continuous)
                        .fill(statusDotColor.opacity(0.14))
                        .frame(width: iconSize, height: iconSize)
                    Circle()
                        .fill(statusDotColor.opacity(0.85))
                        .frame(width: density == .compact ? 7 : 8, height: density == .compact ? 7 : 8)
                }
            }

            VStack(alignment: .leading, spacing: density == .compact ? 2 : 4) {
                HStack(spacing: 6) {
                    Text(item.displayTitle)
                        .font(.system(size: 13, weight: density == .compact ? .medium : .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if isLive {
                        liveBadge
                    }

                    if isRecurringEvent && density != .compact {
                        recurringBadge
                    }
                }

                Text(displayedMetadata)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if density == .full, let preview = notesPreview {
                    Text(preview)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if density == .full && !visibleAttendees.isEmpty {
                    AttendeeAvatarRow(names: visibleAttendees, overflow: attendeeOverflow)
                }
            }

            Spacer(minLength: 4)

            if density == .compact && !visibleAttendees.isEmpty {
                AttendeeAvatarRow(names: visibleAttendees, overflow: attendeeOverflow, avatarSize: avatarSize)
            }

            VStack(alignment: .trailing, spacing: 6) {
                trailingControl
                    .fixedSize()

                if density == .full {
                    HStack(spacing: 6) {
                        if canArmAutoRecord {
                            autoRecordHoverButton
                                .transition(.opacity)
                        }

                        if let url = conferencingURL {
                            openLinkHoverButton(url: url)
                                .transition(.opacity)
                        }
                    }
                }
            }
        }
        .padding(.vertical, verticalPadding)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(rowBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(rowStroke, lineWidth: 1)
        )
        .shadow(color: isLive ? Color.red.opacity(0.14) : .clear, radius: 12, y: 4)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.14)) { isHovered = hovering }
        }
    }

    private var isLive: Bool {
        item.status == .recording
    }

    private var rowBackground: Color {
        if isLive { return Color.red.opacity(0.08) }
        if isSelected { return SettingsPalette.accentFill }
        if isHovered { return SettingsPalette.mutedCardBackground.opacity(0.6) }
        return .clear
    }

    private var rowStroke: Color {
        if isLive { return Color.red.opacity(0.32) }
        if isSelected { return SettingsPalette.accentBorder }
        return .clear
    }

    private var liveBadge: some View {
        HStack(spacing: 4) {
            PulsingDot(color: .red, size: 6)
            Text("LIVE")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(0.5)
                .foregroundStyle(.red)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule(style: .continuous)
                .fill(Color.red.opacity(0.12))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.red.opacity(0.32), lineWidth: 0.5)
        )
        .accessibilityLabel("Recording in progress")
    }

    private var recurringBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "repeat")
                .font(.system(size: 8, weight: .bold))
            Text("Recurring")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            Capsule(style: .continuous)
                .fill(SettingsPalette.mutedCardBackground)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(SettingsPalette.border.opacity(0.3), lineWidth: 0.5)
        )
        .help("Recurring event — each occurrence is shown separately")
    }

    private var conferencingURL: URL? {
        guard let raw = item.conferencingURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return URL(string: raw)
    }

    private var autoRecordHoverButton: some View {
        Button(action: onToggleAutoRecord) {
            HStack(spacing: 4) {
                Image(systemName: isAutoRecordArmed ? "checkmark.circle.fill" : "bolt")
                    .font(.system(size: 10, weight: .bold))
                Text(isAutoRecordArmed ? "Armed" : "Auto-record")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(isAutoRecordArmed ? Color.red : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(isAutoRecordArmed ? Color.red.opacity(0.12) : SettingsPalette.mutedCardBackground)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(
                        isAutoRecordArmed ? Color.red.opacity(0.32) : SettingsPalette.border.opacity(0.32),
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .help(isAutoRecordArmed
              ? "Auto-record armed — recording will start when the meeting begins"
              : "Auto-record when this meeting starts")
    }

    private func openLinkHoverButton(url: URL) -> some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            Image(systemName: "arrow.up.right.square")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(SettingsPalette.infoText)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(SettingsPalette.accentFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(SettingsPalette.accentBorder, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .help("Open meeting link")
    }

    @ViewBuilder
    private var trailingControl: some View {
        if item.status == .recording {
            HStack(spacing: 4) {
                Circle()
                    .fill(.red)
                    .frame(width: 7, height: 7)
                Text("REC")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.red)
            }
            .help("Recording")
        } else if item.canStartRecording {
            Button(action: onPrimaryAction) {
                Label("Record", systemImage: "record.circle")
                    .font(.system(size: 11, weight: .semibold))
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.red.opacity(0.10))
                    )
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red.opacity(0.85))
            .help("Record now")
        } else if item.canRebindRecording {
            Button(action: onPrimaryAction) {
                Label("Bind", systemImage: "arrow.triangle.branch")
                    .font(.system(size: 11, weight: .semibold))
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(SettingsPalette.accentFill)
                    )
            }
            .buttonStyle(.plain)
            .foregroundStyle(SettingsPalette.infoText)
            .help("Switch active recording to this meeting")
        } else {
            Text(Self.timeFormatter.string(from: item.startedAt))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    private var statusDotColor: Color {
        switch item.status {
        case .recording: return .red
        case .now: return .green
        case .upcoming: return .blue
        case .missed: return .orange
        case .uncaptured: return .secondary
        case .ignored: return .secondary
        case .recorded: return .secondary
        }
    }

}

// MARK: - Feed-Style Meeting Row

/// Meeting row that mirrors `HomeDictationRow` from the home feed: 32pt
/// platform icon tile, title + participants subtitle, and a trailing slot
/// that swaps between time-of-day and an Open arrow on hover. Live/record
/// affordances stay; everything else (auto-record toggle, conferencing link
/// shortcut) lives in the detail panel to keep the row uncluttered.
private struct MeetingFeedRow: View {
    let item: MeetingTimelineItem
    let isSelected: Bool
    var isAutoRecordArmed: Bool = false
    /// Optional date stamp shown next to the title (used for History rows so
    /// individual meeting dates are readable without per-day section headers).
    var dateLabel: String? = nil
    let onPrimaryAction: () -> Void
    var onToggleAutoRecord: () -> Void = {}

    @State private var isHovered = false

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    private var provider: MeetingProvider? {
        MeetingProvider.from(url: item.conferencingURL)
            ?? MeetingProvider.from(appName: item.detectedAppName)
    }

    private var isLive: Bool { item.status == .recording }

    /// Two-tier subtitle: prefer participant names (Granola-style), fall back
    /// to platform/duration so the line is always informative.
    private var subtitleText: String {
        let attendees = item.attendeeNames
        if !attendees.isEmpty {
            let visible = attendees.prefix(3).joined(separator: ", ")
            let extra = attendees.count > 3 ? " +\(attendees.count - 3)" : ""
            return visible + extra
        }
        var parts: [String] = []
        if let provider = provider {
            parts.append(provider.displayName)
        } else if let app = item.detectedAppName {
            parts.append(app)
        }
        if !item.durationText.isEmpty {
            parts.append(item.durationText)
        }
        if parts.isEmpty, let organizer = item.organizerName {
            parts.append(organizer)
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// Prepends the date stamp (when set) to the subtitle so each history row
    /// surfaces its own date alongside attendees / provider info.
    private var combinedSubtitle: String? {
        let base = subtitleText
        guard let dateLabel else {
            return base.isEmpty ? nil : base
        }
        if base.isEmpty { return dateLabel }
        return "\(dateLabel) \u{00B7} \(base)"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            iconTile

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.displayTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if isLive {
                        liveBadge
                    }
                }

                if let combined = combinedSubtitle, !combined.isEmpty {
                    Text(combined)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 4)

            trailingControl
                .fixedSize()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(rowBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(rowStroke, lineWidth: isLive ? 1 : 0)
        )
        .shadow(color: isLive ? Color.red.opacity(0.14) : .clear, radius: 12, y: 4)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.14)) { isHovered = hovering }
        }
    }

    @ViewBuilder
    private var iconTile: some View {
        let size: CGFloat = 32
        let cornerRadius: CGFloat = size * 0.26

        if let provider {
            MeetingProviderBadge(provider: provider, size: size)
        } else if let symbolName = item.meetingsTabSymbolName {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(item.meetingsTabSymbolTint.opacity(0.14))
                Image(systemName: symbolName)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(item.meetingsTabSymbolTint)
            }
            .frame(width: size, height: size)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(SettingsPalette.border.opacity(0.22), lineWidth: 0.5)
            )
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(statusDotColor.opacity(0.14))
                Image(systemName: "video.fill")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(statusDotColor)
            }
            .frame(width: size, height: size)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(SettingsPalette.border.opacity(0.22), lineWidth: 0.5)
            )
        }
    }

    private var rowBackground: Color {
        if isLive { return Color.red.opacity(0.08) }
        if isSelected { return SettingsPalette.accentFill }
        if isHovered { return SettingsPalette.elevatedBackground.opacity(0.5) }
        return .clear
    }

    private var rowStroke: Color {
        if isLive { return Color.red.opacity(0.32) }
        return .clear
    }

    private var liveBadge: some View {
        HStack(spacing: 4) {
            PulsingDot(color: .red, size: 6)
            Text("LIVE")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(0.5)
                .foregroundStyle(.red)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule(style: .continuous)
                .fill(Color.red.opacity(0.12))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.red.opacity(0.32), lineWidth: 0.5)
        )
        .accessibilityLabel("Recording in progress")
    }

    @ViewBuilder
    private var trailingControl: some View {
        if item.status == .recording {
            HStack(spacing: 4) {
                Circle()
                    .fill(.red)
                    .frame(width: 7, height: 7)
                Text("REC")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.red)
            }
            .help("Recording")
        } else if item.canStartRecording {
            Button(action: onPrimaryAction) {
                Label("Record", systemImage: "record.circle")
                    .font(.system(size: 11, weight: .semibold))
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.red.opacity(0.10))
                    )
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red.opacity(0.85))
            .help("Record now")
        } else if item.canRebindRecording {
            Button(action: onPrimaryAction) {
                Label("Bind", systemImage: "arrow.triangle.branch")
                    .font(.system(size: 11, weight: .semibold))
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(SettingsPalette.accentFill)
                    )
            }
            .buttonStyle(.plain)
            .foregroundStyle(SettingsPalette.infoText)
            .help("Switch active recording to this meeting")
        } else {
            ZStack(alignment: .trailing) {
                Text(Self.timeFormatter.string(from: item.startedAt))
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
    }

    private var statusDotColor: Color {
        switch item.status {
        case .recording: return .red
        case .now: return .green
        case .upcoming: return .blue
        case .missed: return .orange
        case .uncaptured, .ignored, .recorded: return .secondary
        }
    }
}

// MARK: - Detail Panel

private struct MeetingCalendarDetailPanel: View {
    let item: MeetingTimelineItem
    var isAutoRecordArmed: Bool = false
    @Binding var notesDraft: String
    let onRecord: () -> Void
    let onRebind: () -> Void
    let onImportAudio: () -> Void
    let onAddManualNotes: () -> Void
    let onToggleIgnored: () -> Void
    var onToggleAutoRecord: () -> Void = {}
    let onHide: () -> Void

    private static let weekdayDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d"
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                headerCard
                statusCard
                notesCard
                if hasPeople {
                    peopleCard
                }
                if let urlString = item.conferencingURL,
                   let url = URL(string: urlString) {
                    linkCard(url: url)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity)
        .background(SettingsPalette.warmBackdrop)
    }

    // MARK: Notes card

    private var notesCard: some View {
        MeetingContentCard(
            padding: EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
        ) {
            VStack(alignment: .leading, spacing: 8) {
                MeetingSectionHeader(title: notesTitle, icon: "square.and.pencil")

                ZStack(alignment: .topLeading) {
                    if notesDraft.isEmpty {
                        Text(notesPlaceholder)
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $notesDraft)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 100)
                        .padding(10)
                }
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(SettingsPalette.mutedCardBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(SettingsPalette.border.opacity(0.24), lineWidth: 0.5)
                )
            }
        }
    }

    private var notesTitle: String {
        switch item.status {
        case .upcoming:
            return "Prep notes"
        case .now, .recording:
            return "Scratchpad"
        case .missed, .uncaptured, .ignored, .recorded:
            return "Meeting notes"
        }
    }

    private var notesPlaceholder: String {
        switch item.status {
        case .upcoming:
            return "Agenda, talking points, questions to ask..."
        case .now, .recording:
            return "Capture live notes while the meeting runs..."
        case .missed, .uncaptured, .ignored:
            return "Follow-ups, reflections, what you remember..."
        case .recorded:
            return "Notes about this meeting..."
        }
    }

    // MARK: Header card

    private var headerCard: some View {
        MeetingContentCard(
            padding: EdgeInsets(top: 16, leading: 16, bottom: 14, trailing: 16)
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    if let provider = provider {
                        MeetingProviderBadge(provider: provider, size: 34)
                    } else {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(SettingsPalette.mutedCardBackground)
                            .frame(width: 34, height: 34)
                            .overlay(
                                Image(systemName: "calendar")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            )
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.displayTitle)
                            .font(.system(size: 18, weight: .semibold))
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 4) {
                            Text(Self.weekdayDateFormatter.string(from: item.startedAt))
                            Text("·").foregroundStyle(.tertiary)
                            Text(Self.timeFormatter.string(from: item.startedAt))
                            if !item.durationText.isEmpty {
                                Text("·").foregroundStyle(.tertiary)
                                Text(item.durationText)
                            }
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)

                    overflowMenu
                }

                if hasMetaPills {
                    FlowLayout(spacing: 6) {
                        if let provider = provider {
                            SettingsMetaPill(title: provider.displayName, systemImage: "video", tint: provider.tint)
                        }
                        if let calendarName = item.calendarEvent?.calendarName {
                            SettingsMetaPill(title: calendarName, systemImage: "calendar")
                        }
                    }
                }

                if hasPrimaryActions {
                    Divider().opacity(0.4)
                    primaryActionRow
                }
            }
        }
    }

    private var hasMetaPills: Bool {
        provider != nil || item.calendarEvent?.calendarName != nil
    }

    private var hasPrimaryActions: Bool {
        item.canStartRecording || item.canRebindRecording || item.isMissedLike
    }

    private var hasPeople: Bool {
        !item.attendeeNames.isEmpty || item.organizerName != nil
    }

    // MARK: Primary action row

    @ViewBuilder
    private var primaryActionRow: some View {
        HStack(spacing: 8) {
            if item.canStartRecording {
                primaryButton(title: "Record now", systemImage: "record.circle", action: onRecord)
                if canShowAutoRecord {
                    autoRecordButton
                }
            } else if item.canRebindRecording {
                primaryButton(title: "Switch recording here", systemImage: "arrow.triangle.branch", action: onRebind)
            } else if item.isMissedLike {
                primaryButton(title: "Import audio", systemImage: "square.and.arrow.down", action: onImportAudio)
                textAction(title: "Add notes", systemImage: "square.and.pencil", action: onAddManualNotes)
            }

            Spacer(minLength: 0)
        }
    }

    private var canShowAutoRecord: Bool {
        item.status == .upcoming || item.status == .now
    }

    private var autoRecordButton: some View {
        Button(action: onToggleAutoRecord) {
            HStack(spacing: 5) {
                Image(systemName: isAutoRecordArmed ? "bolt.fill" : "bolt")
                    .font(.system(size: 11, weight: .semibold))
                Text(isAutoRecordArmed ? "Auto-record on" : "Auto-record")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(isAutoRecordArmed ? Color.red : .secondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(isAutoRecordArmed ? Color.red.opacity(0.10) : SettingsPalette.mutedCardBackground)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(
                        isAutoRecordArmed ? Color.red.opacity(0.30) : SettingsPalette.border.opacity(0.32),
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .help(isAutoRecordArmed
              ? "Disable auto-record for this meeting"
              : "Automatically start recording when this meeting begins")
    }

    private var overflowMenu: some View {
        Menu {
            if item.isMissedLike && !item.canStartRecording {
                Button {
                    onImportAudio()
                } label: {
                    Label("Import audio", systemImage: "square.and.arrow.down")
                }
                Button {
                    onAddManualNotes()
                } label: {
                    Label("Add notes manually", systemImage: "square.and.pencil")
                }
                Divider()
            }

            if item.isMissedLike {
                Button {
                    onToggleIgnored()
                } label: {
                    Label(
                        item.status == .ignored ? "Unignore meeting" : "Mark ignored",
                        systemImage: "eye.slash"
                    )
                }
                Button(role: .destructive) {
                    onHide()
                } label: {
                    Label("Hide from timeline", systemImage: "xmark.circle")
                }
            }

            if let urlString = item.conferencingURL,
               let url = URL(string: urlString) {
                Divider()
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Open conferencing link", systemImage: "arrow.up.right.square")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: SettingsLayout.controlMinHeight, height: SettingsLayout.controlMinHeight)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(SettingsPalette.mutedCardBackground)
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("More actions")
    }

    private func primaryButton(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(SettingsPalette.accent)
            )
        }
        .buttonStyle(.plain)
    }

    private func textAction(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(SettingsPalette.mutedCardBackground)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(SettingsPalette.border.opacity(0.32), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: Status card

    private var statusCard: some View {
        MeetingContentCard(
            padding: EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
        ) {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(stateDotColor)
                    .frame(width: 8, height: 8)
                    .padding(.top, 5)

                VStack(alignment: .leading, spacing: 3) {
                    Text(stateLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(stateLine)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: People card

    @ViewBuilder
    private var peopleCard: some View {
        MeetingContentCard(
            padding: EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
        ) {
            VStack(alignment: .leading, spacing: 10) {
                MeetingSectionHeader(
                    title: "People",
                    icon: "person.2",
                    count: displayAttendees.count
                )

                FlowLayout(spacing: 8) {
                    ForEach(displayAttendees, id: \.self) { name in
                        AttendeeChip(
                            name: name,
                            isOrganizer: name == item.organizerName
                        )
                    }
                }
            }
        }
    }

    private var displayAttendees: [String] {
        var names: [String] = []
        if let organizer = item.organizerName {
            names.append(organizer)
        }
        for attendee in item.attendeeNames where attendee != item.organizerName {
            names.append(attendee)
        }
        return names
    }

    // MARK: Link card

    private func linkCard(url: URL) -> some View {
        MeetingContentCard(
            padding: EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 10)
        ) {
            HStack(spacing: 10) {
                Image(systemName: "link")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SettingsPalette.infoText)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(SettingsPalette.accentFill)
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text("Conferencing link")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(url.host ?? url.absoluteString)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)

                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Text("Open")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SettingsPalette.infoText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule(style: .continuous)
                                .fill(SettingsPalette.accentFill)
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(SettingsPalette.accentBorder, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var provider: MeetingProvider? {
        MeetingProvider.from(url: item.conferencingURL)
            ?? MeetingProvider.from(appName: item.detectedAppName)
    }

    private var stateLabel: String {
        switch item.status {
        case .recording: "Recording"
        case .now: "Live now"
        case .upcoming: "Upcoming"
        case .missed: "Missed"
        case .uncaptured: "Not recorded"
        case .ignored: "Ignored"
        case .recorded: "Recorded"
        }
    }

    private var stateLine: String {
        switch item.status {
        case .recording:
            return "Resonant is capturing this call."
        case .now:
            return "On your calendar right now. Record to attach a transcript."
        case .upcoming:
            return "Will show up here when it starts."
        case .missed:
            return "Ended without a recording. Import audio or add notes."
        case .uncaptured:
            return "Had a conferencing link but wasn't recorded."
        case .ignored:
            return "Kept for context, not treated as missed."
        case .recorded:
            return "Transcript attached."
        }
    }

    private var stateDotColor: Color {
        switch item.status {
        case .recording, .now: return .green
        case .upcoming: return .blue
        case .missed: return .orange
        case .uncaptured: return Color.secondary.opacity(0.5)
        case .ignored: return Color.secondary.opacity(0.4)
        case .recorded: return Color.secondary.opacity(0.6)
        }
    }
}

// MARK: - Meeting Provider

private extension MeetingEntry {
    var meetingsTabHasCalendarBinding: Bool {
        guard let calendarEventID else { return false }
        return !calendarEventID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var meetingsTabTypeLabel: String? {
        switch recordingOrigin {
        case .manualNotes:
            return "Notes only"
        case .importedAudio:
            return "Imported audio"
        case .manual where !meetingsTabHasCalendarBinding:
            return "Ad-hoc recording"
        default:
            return nil
        }
    }

    var meetingsTabSymbolName: String? {
        switch recordingOrigin {
        case .manualNotes:
            return "square.and.pencil"
        case .importedAudio:
            return "square.and.arrow.down"
        case .manual where !meetingsTabHasCalendarBinding:
            return "record.circle"
        default:
            return nil
        }
    }

    var meetingsTabSymbolTint: Color {
        switch recordingOrigin {
        case .manual where !meetingsTabHasCalendarBinding:
            return .red.opacity(0.85)
        case .manualNotes, .importedAudio:
            return SettingsPalette.infoText
        default:
            return .secondary
        }
    }
}

private extension MeetingTimelineItem {
    var meetingsTabTypeLabel: String? {
        meeting?.meetingsTabTypeLabel
    }

    var meetingsTabSymbolName: String? {
        meeting?.meetingsTabSymbolName
    }

    var meetingsTabSymbolTint: Color {
        meeting?.meetingsTabSymbolTint ?? .secondary
    }
}

private enum MeetingProvider: String {
    case zoom
    case googleMeet
    case teams
    case webex
    case protonMeet

    var displayName: String {
        switch self {
        case .zoom: "Zoom"
        case .googleMeet: "Google Meet"
        case .teams: "Microsoft Teams"
        case .webex: "Webex"
        case .protonMeet: "Proton Meet"
        }
    }

    var tint: Color {
        switch self {
        case .zoom: Color(red: 0.18, green: 0.47, blue: 0.95)
        case .googleMeet: Color(red: 0.13, green: 0.60, blue: 0.38)
        case .teams: Color(red: 0.22, green: 0.45, blue: 0.82)
        case .webex: Color(red: 0.0, green: 0.53, blue: 0.62)
        case .protonMeet: Color(red: 0.24, green: 0.55, blue: 0.85)
        }
    }

    static func from(url: String?) -> MeetingProvider? {
        guard let url = url?.lowercased() else { return nil }
        if url.contains("meet.google.com") { return .googleMeet }
        if url.contains("zoom.us") { return .zoom }
        if url.contains("teams.microsoft.com") || url.contains("teams.live.com") { return .teams }
        if url.contains("webex.com") { return .webex }
        if url.contains("meet.proton.me") { return .protonMeet }
        return nil
    }

    static func from(appName: String?) -> MeetingProvider? {
        guard let name = appName?.lowercased() else { return nil }
        if name.contains("zoom") { return .zoom }
        if name.contains("meet") && name.contains("google") { return .googleMeet }
        if name.contains("teams") { return .teams }
        if name.contains("webex") { return .webex }
        if name.contains("proton") { return .protonMeet }
        return nil
    }
}

private struct MeetingProviderBadge: View {
    let provider: MeetingProvider
    let size: CGFloat

    private var cornerRadius: CGFloat { size * 0.26 }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(provider.tint.opacity(0.14))

            fallback
        }
        .frame(width: size, height: size)
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(provider.tint.opacity(0.22), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var fallback: some View {
        Image(systemName: "video.fill")
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(provider.tint)
    }
}

// MARK: - Attendee Chip

private struct AttendeeChip: View {
    let name: String
    let isOrganizer: Bool

    var body: some View {
        HStack(spacing: 8) {
            AvatarCircle(name: name, size: 22)
            Text(name)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .lineLimit(1)
            if isOrganizer {
                Text("Organizer")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
    }
}

/// Tiny dot that pulses opacity to signal a live state — used on the LIVE
/// badge for currently-recording meeting rows so the eye lands on them first.
private struct PulsingDot: View {
    let color: Color
    var size: CGFloat = 6

    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .scaleEffect(isPulsing ? 1.0 : 0.7)
            .opacity(isPulsing ? 1.0 : 0.55)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear { isPulsing = true }
    }
}

/// Compact stack of attendee avatars with overlap, used in the meeting feed
/// row beneath title + metadata. Mirrors Granola's "who was there" affordance.
private struct AttendeeAvatarRow: View {
    let names: [String]
    var overflow: Int = 0
    var avatarSize: CGFloat = 18

    var body: some View {
        HStack(spacing: -avatarSize * 0.32) {
            ForEach(Array(names.enumerated()), id: \.offset) { _, name in
                AvatarCircle(name: name, size: avatarSize)
                    .overlay(
                        Circle()
                            .stroke(SettingsPalette.cardBackground, lineWidth: 1.5)
                    )
            }

            if overflow > 0 {
                Text("+\(overflow)")
                    .font(.system(size: avatarSize * 0.44, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(width: avatarSize, height: avatarSize)
                    .background(
                        Circle()
                            .fill(SettingsPalette.mutedCardBackground)
                    )
                    .overlay(
                        Circle()
                            .stroke(SettingsPalette.cardBackground, lineWidth: 1.5)
                    )
            }
        }
    }
}

private struct AvatarCircle: View {
    let name: String
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(
                Text(initials)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }

    private var initials: String {
        let parts = name
            .split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            .prefix(2)
        let letters = parts.compactMap { $0.first.map(String.init) }.joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    private var color: Color {
        let palette: [Color] = [
            Color(red: 0.30, green: 0.62, blue: 0.93),
            Color(red: 0.95, green: 0.62, blue: 0.32),
            Color(red: 0.26, green: 0.70, blue: 0.52),
            Color(red: 0.90, green: 0.44, blue: 0.40),
            Color(red: 0.34, green: 0.47, blue: 0.78),
            Color(red: 0.24, green: 0.58, blue: 0.70),
            Color(red: 0.85, green: 0.56, blue: 0.22),
        ]
        let hash = abs(name.hashValue)
        return palette[hash % palette.count]
    }
}

// MARK: - Flow Layout (for attendee chips)

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            totalWidth = max(totalWidth, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: totalWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth && x > bounds.minX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private enum MeetingDetailTab: String, CaseIterable {
    case transcript = "Transcript"
    case notes = "Notes"
    case details = "Details"
}

private struct MeetingDetailPanel: View {
    let meeting: MeetingEntry
    @Binding var titleDraft: String
    @Binding var userNotesDraft: String
    @Binding var postNoteDraft: String
    @Binding var speakerAliasDrafts: [String: String]
    @Binding var didCopyTranscript: Bool
    let resolvedUserDisplayName: String?
    let resolvedUserEmail: String?
    let webhookConfigured: Bool
    let onSaveChanges: () -> Void
    let onCopyTranscript: () -> Void
    let onCopyRecap: () -> Void
    let onRequestPrivateLink: () -> Void
    let onRequestWorkspaceSharing: () -> Void
    let onSharePublicRecap: (MeetingRecapPublicLinkDelivery) -> Void
    let onDelete: () -> Void
    let onDistill: (String) -> Void
    let onOpenSharedRecap: (URL) -> Void
    var isDistilling: Bool = false
    var isSharingRecap: Bool = false
    var sharedRecapURL: URL?
    @State private var showDeleteConfirm = false
    @State private var activeTab: MeetingDetailTab
    @State private var isDistillSheetPresented = false
    @State private var distillPrompt = kDefaultMemoDistillPrompt
    @State private var didCopyRecap = false
    @State private var pendingPublicLinkDelivery: MeetingRecapPublicLinkDelivery?

    init(
        meeting: MeetingEntry,
        titleDraft: Binding<String>,
        userNotesDraft: Binding<String>,
        postNoteDraft: Binding<String>,
        speakerAliasDrafts: Binding<[String: String]>,
        didCopyTranscript: Binding<Bool>,
        resolvedUserDisplayName: String?,
        resolvedUserEmail: String?,
        webhookConfigured: Bool,
        onSaveChanges: @escaping () -> Void,
        onCopyTranscript: @escaping () -> Void,
        onCopyRecap: @escaping () -> Void,
        onRequestPrivateLink: @escaping () -> Void,
        onRequestWorkspaceSharing: @escaping () -> Void,
        onSharePublicRecap: @escaping (MeetingRecapPublicLinkDelivery) -> Void,
        onDelete: @escaping () -> Void,
        onDistill: @escaping (String) -> Void,
        onOpenSharedRecap: @escaping (URL) -> Void,
        isDistilling: Bool = false,
        isSharingRecap: Bool = false,
        sharedRecapURL: URL? = nil
    ) {
        self.meeting = meeting
        self._titleDraft = titleDraft
        self._userNotesDraft = userNotesDraft
        self._postNoteDraft = postNoteDraft
        self._speakerAliasDrafts = speakerAliasDrafts
        self._didCopyTranscript = didCopyTranscript
        self.resolvedUserDisplayName = resolvedUserDisplayName
        self.resolvedUserEmail = resolvedUserEmail
        self.webhookConfigured = webhookConfigured
        self.onSaveChanges = onSaveChanges
        self.onCopyTranscript = onCopyTranscript
        self.onCopyRecap = onCopyRecap
        self.onRequestPrivateLink = onRequestPrivateLink
        self.onRequestWorkspaceSharing = onRequestWorkspaceSharing
        self.onSharePublicRecap = onSharePublicRecap
        self.onDelete = onDelete
        self.onDistill = onDistill
        self.onOpenSharedRecap = onOpenSharedRecap
        self.isDistilling = isDistilling
        self.isSharingRecap = isSharingRecap
        self.sharedRecapURL = sharedRecapURL
        // When there's no transcript yet (manual-notes meetings, in-flight
        // recordings with nothing exported), land on Notes so the draft the
        // user was typing stays in view.
        let initialTab: MeetingDetailTab = meeting.markdownPath == nil ? .notes : .transcript
        self._activeTab = State(initialValue: initialTab)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .short
        return f
    }()

    private var showsAppMetadata: Bool {
        guard let title = meeting.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return !title.isEmpty
    }

    private var headerMetadataText: String {
        var parts: [String] = []
        if let typeLabel = meeting.meetingsTabTypeLabel {
            parts.append(typeLabel)
        }
        if showsAppMetadata, let app = meeting.detectedApp, !app.isEmpty {
            parts.append(app)
        }
        parts.append(Self.dateFormatter.string(from: meeting.startedAt))
        if meeting.hasMeaningfulDuration {
            parts.append(meeting.formattedDuration)
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    private var conferencingURL: URL? {
        guard let raw = meeting.conferencingURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    private var isRecapShareDisclosurePresented: Binding<Bool> {
        Binding(
            get: { pendingPublicLinkDelivery != nil },
            set: { isPresented in
                if !isPresented {
                    pendingPublicLinkDelivery = nil
                }
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                headerCard

                if let url = conferencingURL {
                    meetingLinkCard(url: url)
                }

                if let distilled = meeting.distilledSummary, !distilled.isEmpty {
                    distilledCard(distilled)
                }

                recapSharingCard

                contentCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .scrollContentBackground(.hidden)
    }

    private func meetingLinkCard(url: URL) -> some View {
        MeetingContentCard(
            padding: EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 10)
        ) {
            HStack(spacing: 10) {
                Image(systemName: "link")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SettingsPalette.infoText)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(SettingsPalette.accentFill)
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text("Meeting link")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(url.host ?? url.absoluteString)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)

                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .bold))
                        Text("Open")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(SettingsPalette.infoText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(SettingsPalette.accentFill)
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(SettingsPalette.accentBorder, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .help("Open meeting in browser")
            }
        }
    }

    private var headerCard: some View {
        MeetingContentCard(
            padding: EdgeInsets(top: 14, leading: 16, bottom: 12, trailing: 12)
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("", text: $titleDraft, prompt: Text(meeting.fallbackTitle))
                            .textFieldStyle(.plain)
                            .font(.system(size: 18, weight: .semibold))

                        Text(headerMetadataText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)

                    toolbarActions
                }

                Picker("", selection: $activeTab) {
                    ForEach(MeetingDetailTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    private var toolbarActions: some View {
        HStack(spacing: 4) {
            if AppFeatureVisibility.hostedServices {
                Menu {
                    Button("Quick summary") {
                        onDistill("Summarize this meeting into clear bullets with the key ideas, decisions, and next steps.")
                    }
                    Button("Action items") {
                        onDistill("Extract action items from this meeting as a bulleted list with owners if mentioned.")
                    }
                    Button("Meeting recap") {
                        onDistill("Write a brief recap of this meeting suitable for sharing with the team.")
                    }
                    Divider()
                    Button("Custom prompt...") {
                        isDistillSheetPresented = true
                    }
                } label: {
                    toolbarIcon(
                        systemImage: isDistilling ? "hourglass" : (meeting.distilledSummary != nil ? "text.document.fill" : "sparkles"),
                        tint: SettingsPalette.infoText
                    )
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(isDistilling ? "Distilling..." : "Distill meeting")
                .disabled(isDistilling)
                .sheet(isPresented: $isDistillSheetPresented) {
                    DistillPromptSheet(
                        prompt: $distillPrompt,
                        isProcessing: isDistilling,
                        error: nil,
                        onCancel: { isDistillSheetPresented = false },
                        onSubmit: {
                            isDistillSheetPresented = false
                            onDistill(distillPrompt)
                        }
                    )
                }
            }

            Button {
                onCopyTranscript()
            } label: {
                toolbarIcon(
                    systemImage: didCopyTranscript ? "checkmark" : "doc.on.doc",
                    tint: .secondary
                )
            }
            .buttonStyle(.plain)
            .help(didCopyTranscript ? "Copied" : "Copy transcript")

            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                toolbarIcon(systemImage: "trash", tint: .red.opacity(0.75))
            }
            .buttonStyle(.plain)
            .help("Delete meeting")
            .confirmationDialog("Delete this meeting?", isPresented: $showDeleteConfirm) {
                Button("Delete", role: .destructive) { onDelete() }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private func toolbarIcon<Tint: ShapeStyle>(systemImage: String, tint: Tint) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: SettingsLayout.controlMinHeight, height: SettingsLayout.controlMinHeight)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(SettingsPalette.mutedCardBackground)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func distilledCard(_ distilled: String) -> some View {
        MeetingContentCard(
            padding: EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
        ) {
            VStack(alignment: .leading, spacing: 8) {
                MeetingSectionHeader(title: "Distilled note", icon: "sparkles")
                Text(distilled)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var recapSharingCard: some View {
        MeetingContentCard(
            padding: EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SettingsPalette.infoText)
                        .frame(width: 26, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(SettingsPalette.accentFill)
                        )

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Share recap")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Copy is local. Links are optional.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: 6) {
                    Button {
                        onCopyRecap()
                        didCopyRecap = true
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(1.8))
                            didCopyRecap = false
                        }
                    } label: {
                        Label(didCopyRecap ? "Copied" : "Copy", systemImage: didCopyRecap ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(MeetingRecapShareBuilder.shareSummary(for: meeting) == nil)

                    if AppFeatureVisibility.hostedServices {
                        Spacer(minLength: 0)

                        Menu {
                            Button {
                                onRequestPrivateLink()
                            } label: {
                                Label("Private link", systemImage: "lock")
                            }
                            Button {
                                onRequestWorkspaceSharing()
                            } label: {
                                Label("Workspace-only", systemImage: "building.2")
                            }
                            Divider()
                            Button {
                                pendingPublicLinkDelivery = .copyLink
                            } label: {
                                Label("Copy public link", systemImage: "globe")
                            }
                            Button {
                                pendingPublicLinkDelivery = .email
                            } label: {
                                Label("Email public link", systemImage: "envelope")
                            }
                            if let sharedRecapURL {
                                Divider()
                                Button {
                                    onOpenSharedRecap(sharedRecapURL)
                                } label: {
                                    Label("Open public link", systemImage: "arrow.up.right.square")
                                }
                            }
                        } label: {
                            Label(isSharingRecap ? "Creating" : "Links", systemImage: "link")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .disabled(isSharingRecap || MeetingRecapShareBuilder.shareSummary(for: meeting) == nil)
                        .help("Private, workspace, and public link options")
                    }
                }
            }
        }
        .confirmationDialog(
            "Publish recap to the web?",
            isPresented: isRecapShareDisclosurePresented,
            titleVisibility: .visible
        ) {
            Button(pendingPublicLinkDelivery == .email ? "Publish and email link" : "Publish and copy link") {
                guard let delivery = pendingPublicLinkDelivery else { return }
                pendingPublicLinkDelivery = nil
                onSharePublicRecap(delivery)
            }
            Button("Cancel", role: .cancel) {
                pendingPublicLinkDelivery = nil
            }
        } message: {
            Text(MeetingRecapShareBuilder.publicDisclosureText())
        }
    }

    @ViewBuilder
    private var contentCard: some View {
        MeetingContentCard(
            padding: EdgeInsets(top: 14, leading: 16, bottom: 16, trailing: 16)
        ) {
            switch activeTab {
            case .transcript:
                transcriptContent
            case .notes:
                notesContent
            case .details:
                detailsContent
            }
        }
    }

    // MARK: - Transcript

    @ViewBuilder
    private var transcriptContent: some View {
        if let path = meeting.markdownPath {
            MeetingTranscriptView(
                meeting: meeting,
                markdownPath: path,
                speakerAliases: $speakerAliasDrafts,
                userDisplayName: resolvedUserDisplayName,
                userEmail: resolvedUserEmail
            )
        } else {
            ContentUnavailableView(
                "No transcript",
                systemImage: "text.quote",
                description: Text("This meeting has no transcript attached.")
            )
            .padding(.vertical, 24)
        }
    }

    // MARK: - Notes

    private var notesContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            notesSection(
                title: "Scratchpad",
                icon: "square.and.pencil",
                placeholder: "What you captured live during the meeting...",
                text: $userNotesDraft,
                minHeight: 120
            )

            notesSection(
                title: "Follow-up notes",
                icon: "clock.badge.checkmark",
                placeholder: "Decisions, action items, reflections...",
                text: $postNoteDraft,
                minHeight: 100
            )
        }
    }

    private func notesSection(
        title: String,
        icon: String,
        placeholder: String,
        text: Binding<String>,
        minHeight: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Spacer(minLength: 0)
            }

            ZStack(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
                BulletTextView(text: text, minHeight: minHeight)
                    .frame(minHeight: minHeight)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(SettingsPalette.mutedCardBackground.opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(SettingsPalette.border.opacity(0.18), lineWidth: 0.5)
            )
        }
    }

    // MARK: - Details

    @ViewBuilder
    private var detailsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            detailsGroup(title: "Meeting") {
                detailRow("Started", value: meeting.startedAt.formatted(date: .abbreviated, time: .standard))
                if let ended = meeting.endedAt {
                    detailRow("Ended", value: ended.formatted(date: .abbreviated, time: .standard))
                }
                if meeting.hasMeaningfulDuration {
                    detailRow("Duration", value: meeting.formattedDuration)
                }
                detailRow("Words", value: "\(meeting.wordCount)")
                if let app = trimmedValue(meeting.detectedApp) {
                    detailRow("Detected app", value: app)
                }
                if let origin = meeting.recordingOrigin {
                    detailRow("Origin", value: origin.detailDisplayLabel)
                }
            }

            if hasScheduledDetails {
                detailsGroup(title: "Calendar") {
                    if let calendar = trimmedValue(meeting.calendarName) {
                        detailRow("Calendar", value: calendar)
                    }
                    if let eventID = trimmedValue(meeting.calendarEventID) {
                        detailRow("Event ID", value: eventID)
                    }
                    if let scheduled = meeting.scheduledStartAt {
                        detailRow("Scheduled start", value: scheduled.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let scheduled = meeting.scheduledEndAt {
                        detailRow("Scheduled end", value: scheduled.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let url = trimmedValue(meeting.conferencingURL) {
                        detailRow("Conferencing", value: url, link: URL(string: url))
                    }
                }
            }

            if hasPeopleDetails {
                detailsGroup(title: "People") {
                    if let organizer = trimmedValue(meeting.organizerName) {
                        detailRow("Organizer", value: organizer)
                    }
                    if !meeting.attendeeNames.isEmpty {
                        detailRow("Attendees", value: meeting.attendeeNames.joined(separator: ", "))
                    }
                    if !meeting.attendeeEmails.isEmpty {
                        detailRow("Emails", value: meeting.attendeeEmails.joined(separator: ", "))
                    }
                }
            }

            detailsGroup(title: "Delivery") {
                detailRow("Webhook", value: webhookStatusLabel)
                detailRow("Distilled", value: (meeting.distilledSummary?.isEmpty == false) ? "Yes" : "No")
            }

            if hasFileDetails {
                detailsGroup(title: "Files") {
                    if let audio = trimmedValue(meeting.audioPath) {
                        detailFileRow("Audio", relativePath: audio)
                    }
                    if let markdown = trimmedValue(meeting.markdownPath) {
                        detailFileRow("Markdown", relativePath: markdown)
                    }
                    if let jsonl = trimmedValue(meeting.activeJSONLPath) {
                        detailFileRow("Active JSONL", relativePath: jsonl)
                    }
                }
            }

            detailsGroup(title: "Identity") {
                detailRow("ID", value: meeting.id.uuidString)
            }
        }
    }

    private var hasScheduledDetails: Bool {
        trimmedValue(meeting.calendarName) != nil
            || trimmedValue(meeting.calendarEventID) != nil
            || meeting.scheduledStartAt != nil
            || meeting.scheduledEndAt != nil
            || trimmedValue(meeting.conferencingURL) != nil
    }

    private var hasPeopleDetails: Bool {
        trimmedValue(meeting.organizerName) != nil
            || !meeting.attendeeNames.isEmpty
            || !meeting.attendeeEmails.isEmpty
    }

    private var hasFileDetails: Bool {
        trimmedValue(meeting.audioPath) != nil
            || trimmedValue(meeting.markdownPath) != nil
            || trimmedValue(meeting.activeJSONLPath) != nil
    }

    private var webhookStatusLabel: String {
        webhookConfigured ? "Configured — fires on recording completion" : "Not configured"
    }

    private func trimmedValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    @ViewBuilder
    private func detailsGroup<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .tracking(0.5)

            VStack(alignment: .leading, spacing: 6) {
                content()
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(SettingsPalette.mutedCardBackground.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(SettingsPalette.border.opacity(0.16), lineWidth: 0.5)
            )
        }
    }

    @ViewBuilder
    private func detailRow(_ label: String, value: String, link: URL? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.quaternary)
                .textCase(.uppercase)
                .tracking(0.3)
                .frame(width: 94, alignment: .leading)

            if let link {
                Button {
                    NSWorkspace.shared.open(link)
                } label: {
                    Text(value)
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsPalette.infoText)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .underline()
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            } else {
                Text(value)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func detailFileRow(_ label: String, relativePath: String) -> some View {
        let url = AppSupportPaths.resonantRoot().appendingPathComponent(relativePath)
        let exists = FileManager.default.fileExists(atPath: url.path)

        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.quaternary)
                .textCase(.uppercase)
                .tracking(0.3)
                .frame(width: 94, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text((relativePath as NSString).lastPathComponent)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                if exists {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "folder")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Show in Finder")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(SettingsPalette.infoText)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Transcript Renderer

fileprivate enum MeetingTranscriptSupport {

    struct Header: Sendable {
        let speakerKey: String
        let speakerLabel: String
        let timestamp: String
    }

    static func parseHeaderLine(
        _ line: String,
        speakerAliases: MeetingSpeakerAliasMap
    ) -> Header? {
        guard line.hasPrefix("**"),
              let closeBold = line.range(
                of: "**",
                range: line.index(line.startIndex, offsetBy: 2)..<line.endIndex
              )
        else {
            return nil
        }

        let rawSpeakerLabel = String(
            line[line.index(line.startIndex, offsetBy: 2)..<closeBold.lowerBound]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawSpeakerLabel.isEmpty,
              let openParen = line.range(of: "("),
              let closeParen = line.range(of: ")", range: openParen.upperBound..<line.endIndex)
        else {
            return nil
        }

        let timestamp = String(line[openParen.upperBound..<closeParen.lowerBound])
        let speakerKey = explicitSpeakerKey(in: line)
            ?? MeetingSpeakerAliasResolver.storageKey(
                forTranscriptLabel: rawSpeakerLabel,
                aliases: speakerAliases
            )
        guard let speakerKey else { return nil }

        let speakerLabel = MeetingSpeaker(storageKey: speakerKey)?
            .resolvedDisplayLabel(using: speakerAliases)
            ?? rawSpeakerLabel

        return Header(
            speakerKey: speakerKey,
            speakerLabel: speakerLabel,
            timestamp: timestamp
        )
    }

    static func headerLine(
        speakerKey: String,
        timestamp: String,
        speakerAliases: MeetingSpeakerAliasMap
    ) -> String {
        let speakerLabel = MeetingSpeaker(storageKey: speakerKey)?
            .resolvedDisplayLabel(using: speakerAliases)
            ?? speakerAliases[speakerKey]
            ?? "Speaker"
        return "**\(speakerLabel)** (\(timestamp)) <!-- speaker:\(speakerKey) -->"
    }

    private static func explicitSpeakerKey(in line: String) -> String? {
        guard let commentRange = line.range(of: "<!-- speaker:") else { return nil }
        guard let endRange = line.range(of: "-->", range: commentRange.upperBound..<line.endIndex) else {
            return nil
        }
        let storageKey = String(line[commentRange.upperBound..<endRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return storageKey.isEmpty ? nil : storageKey
    }
}

private struct MeetingTranscriptView: View {
    let meeting: MeetingEntry
    let markdownPath: String
    @Binding var speakerAliases: [String: String]
    let userDisplayName: String?
    let userEmail: String?
    @State private var utteranceLines: [UtteranceLine] = []
    @State private var isLoading = false

    private struct UtteranceLine: Identifiable, Sendable {
        let id: Int
        let speakerKey: String
        let fallbackSpeakerLabel: String
        let timestamp: String
        let text: String

        func speakerLabel(using aliases: MeetingSpeakerAliasMap) -> String {
            if let speaker = MeetingSpeaker(storageKey: speakerKey) {
                return speaker.resolvedDisplayLabel(using: aliases)
            }
            return aliases[speakerKey] ?? fallbackSpeakerLabel
        }

        var speakerColor: Color {
            if let speaker = MeetingSpeaker(storageKey: speakerKey) {
                return speaker.color
            }
            if let speaker = MeetingSpeaker.legacySpeaker(forTranscriptLabel: fallbackSpeakerLabel) {
                return speaker.color
            }
            return MeetingSpeaker.them.color
        }
    }

    private var detectedSpeakers: [MeetingSpeaker] {
        Array(Set(utteranceLines.compactMap { MeetingSpeaker(storageKey: $0.speakerKey) })).sorted {
            MeetingTranscriptView.speakerRank($0) < MeetingTranscriptView.speakerRank($1)
        }
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if utteranceLines.isEmpty {
                Text("No transcript available.")
                    .foregroundStyle(.secondary)
                    .italic()
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    if !detectedSpeakers.isEmpty {
                        speakerAliasesEditor
                    }
                    ForEach(utteranceLines) { line in
                        utteranceRow(line)
                    }
                }
            }
        }
        .task(id: markdownPath) {
            await loadTranscript()
        }
    }

    private func loadTranscript() async {
        isLoading = true
        let normalizedAliases = MeetingSpeakerAliasResolver.normalized(speakerAliases)
        let loadedLines = await Self.loadUtteranceLines(
            fromRelativePath: markdownPath,
            speakerAliases: normalizedAliases
        )
        utteranceLines = loadedLines
        let mergedAliases = MeetingSpeakerAliasResolver.mergedAliases(
            existing: normalizedAliases,
            speakers: loadedLines.compactMap { MeetingSpeaker(storageKey: $0.speakerKey) },
            captureContext: meeting.captureContext,
            userDisplayName: userDisplayName,
            userEmail: userEmail
        )
        if mergedAliases != normalizedAliases {
            speakerAliases = mergedAliases
        }
        isLoading = false
    }

    private var speakerAliasesEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Speaker names")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)

            ForEach(detectedSpeakers, id: \.storageKey) { speaker in
                HStack(spacing: 12) {
                    Text(speaker.legacyDisplayLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(speaker.color)
                        .frame(width: 78, alignment: .leading)

                    TextField(
                        speaker.legacyDisplayLabel,
                        text: aliasBinding(for: speaker)
                    )
                    .textFieldStyle(.roundedBorder)
                }
            }
        }
        .padding(14)
        .background(SettingsPalette.elevatedBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(SettingsPalette.border, lineWidth: 0.5)
        )
    }

    private func aliasBinding(for speaker: MeetingSpeaker) -> Binding<String> {
        Binding(
            get: {
                speakerAliases[speaker.storageKey] ?? speaker.legacyDisplayLabel
            },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    speakerAliases.removeValue(forKey: speaker.storageKey)
                } else {
                    speakerAliases[speaker.storageKey] = trimmed
                }
            }
        )
    }

    private nonisolated static func loadUtteranceLines(
        fromRelativePath markdownPath: String,
        speakerAliases: MeetingSpeakerAliasMap
    ) async -> [UtteranceLine] {
        await Task.detached(priority: .utility) {
            let url = AppSupportPaths.resonantRoot().appendingPathComponent(markdownPath)
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            return parseUtteranceLines(from: content, speakerAliases: speakerAliases)
        }.value
    }

    private nonisolated static func parseUtteranceLines(
        from content: String,
        speakerAliases: MeetingSpeakerAliasMap
    ) -> [UtteranceLine] {
        let lines = content.components(separatedBy: "\n")
        var inTranscript = false
        var results: [UtteranceLine] = []
        var currentSpeakerKey = ""
        var currentSpeakerLabel = ""
        var currentTimestamp = ""
        var currentText = ""
        var index = 0

        func appendCurrentIfNeeded() {
            guard !currentText.isEmpty, !currentSpeakerKey.isEmpty else { return }
            results.append(
                UtteranceLine(
                    id: index,
                    speakerKey: currentSpeakerKey,
                    fallbackSpeakerLabel: currentSpeakerLabel,
                    timestamp: currentTimestamp,
                    text: currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            )
            index += 1
            currentText = ""
        }

        for line in lines {
            if line.hasPrefix("## Transcript") {
                inTranscript = true
                continue
            }
            if inTranscript && line.hasPrefix("## ") {
                appendCurrentIfNeeded()
                break
            }
            if !inTranscript { continue }

            if let header = MeetingTranscriptSupport.parseHeaderLine(line, speakerAliases: speakerAliases) {
                appendCurrentIfNeeded()
                currentSpeakerKey = header.speakerKey
                currentSpeakerLabel = header.speakerLabel
                currentTimestamp = header.timestamp
            } else if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                currentText += (currentText.isEmpty ? "" : " ") + line.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        appendCurrentIfNeeded()
        return results
    }

    private func utteranceRow(_ line: UtteranceLine) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                Text(line.speakerLabel(using: speakerAliases))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(line.speakerColor)
                Text("  ")
                Text(line.timestamp)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.quaternary)
            }

            Text(line.text)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineSpacing(3)
        }
    }

    private nonisolated static func speakerRank(_ speaker: MeetingSpeaker) -> Int {
        switch speaker {
        case .you:
            return 0
        case .them:
            return 1
        case .participant(let id):
            return 100 + (MeetingSpeaker.participantIndex(for: id) ?? 999)
        }
    }
}

// MARK: - How It Works Modal

private struct MeetingHowItWorksModal: View {
    @Binding var isPresented: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(spacing: 0) {
                header

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        stepBlock(
                            number: "1",
                            title: "Hit Record now",
                            body: "Pick a meeting and click the red button. Or arm Auto-record to capture it hands-free when it starts."
                        ) {
                            recordButtonMock
                        }

                        stepBlock(
                            number: "2",
                            title: "Captures your mic + speaker audio",
                            body: "Two separate streams so we know who said what. Everything stays on your Mac."
                        ) {
                            captureMock
                        }

                        bluetoothCallout

                        stepBlock(
                            number: "3",
                            title: "Markdown notes with speakers",
                            body: "Speaker-labeled transcript with timestamps. Add your own notes alongside."
                        ) {
                            transcriptMock
                        }
                    }
                    .padding(24)
                }

                Divider().opacity(0.4)

                HStack {
                    Spacer()
                    Button("Got it") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.large)
                }
                .padding(16)
            }
            .frame(width: 460)
            .frame(maxHeight: 640)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(SettingsPalette.cardBackground)
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(SettingsPalette.border.opacity(0.3), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.18), radius: 30, x: 0, y: 16)
        }
    }

    private var header: some View {
        HStack {
            Text("How Meetings Work")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(SettingsPalette.mutedCardBackground))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private func stepBlock<Visual: View>(
        number: String,
        title: String,
        body: String,
        @ViewBuilder visual: () -> Visual
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(number)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(SettingsPalette.infoText)
                    .frame(width: 22, height: 22)
                    .background(
                        Circle().fill(SettingsPalette.accentFill)
                    )
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
            }
            Text(body)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 32)

            visual()
                .padding(.leading, 32)
                .padding(.top, 4)
        }
    }

    private var recordButtonMock: some View {
        HStack(spacing: 8) {
            Image(systemName: "record.circle")
                .font(.system(size: 12, weight: .semibold))
            Text("Record now")
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(Color.red.opacity(0.92)))
    }

    private var captureMock: some View {
        HStack(spacing: 10) {
            captureChip(icon: "mic.fill", label: "Your mic", color: MeetingSpeaker.you.color)
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.tertiary)
            captureChip(icon: "speaker.wave.2.fill", label: "Speaker audio", color: MeetingSpeaker.them.color)
            Image(systemName: "arrow.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.tertiary)
            HStack(spacing: 6) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SettingsPalette.infoText)
                Text("Local")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(SettingsPalette.accentFill))
        }
    }

    private func captureChip(icon: String, label: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(color.opacity(0.12)))
        .overlay(Capsule().stroke(color.opacity(0.22), lineWidth: 0.5))
    }

    private var bluetoothCallout: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "earbuds.case.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.orange)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.orange.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 3) {
                Text("Bluetooth tanks speaker audio")
                    .font(.system(size: 13, weight: .semibold))
                Text("AirPods and Bluetooth headphones downgrade mic/speaker quality and can drop chunks of speaker audio. Use built-in speakers or wired headphones whenever you can.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.orange.opacity(0.22), lineWidth: 0.5)
        )
    }

    private var transcriptMock: some View {
        VStack(alignment: .leading, spacing: 6) {
            transcriptLine(speaker: "You", color: MeetingSpeaker.you.color, text: "Can we ship by Thursday?", time: "0:32")
            transcriptLine(speaker: "Them", color: MeetingSpeaker.them.color, text: "If we keep the scope tight.", time: "0:38")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(SettingsPalette.mutedCardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(SettingsPalette.border.opacity(0.22), lineWidth: 0.5)
        )
    }

    private func transcriptLine(speaker: String, color: Color, text: String, time: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(speaker)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 36, alignment: .leading)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            Text(time)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    private func dismiss() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
            isPresented = false
        }
    }
}
