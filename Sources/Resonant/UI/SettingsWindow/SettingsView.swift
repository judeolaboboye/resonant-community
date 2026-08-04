import AppKit
import SwiftUI

// MARK: - Layout Tier

/// Discrete window layout configurations.
/// The app snaps between these based on total window width so each region
/// (sidebar, feed, detail) has a guaranteed minimum before being dropped.
enum LayoutTier: Equatable {
    /// Feed only. Sidebar hidden, no detail panel.
    case compact
    /// Sidebar + feed. No detail panel.
    case medium
    /// Sidebar + feed + detail panel (integrated, not floating).
    case wide

    /// Width threshold where `medium` unlocks (sidebar becomes visible).
    /// Sidebar ≈ 200 + feed min 545 + slack.
    static let mediumMinWidth: CGFloat = 760
    /// Width threshold where `wide` unlocks (detail panel becomes visible).
    /// Sidebar ≈ 200 + feed min 545 + detail 380 + slack.
    static let wideMinWidth: CGFloat = 1140

    /// Minimum overall window width (compact tier lower bound = feed min).
    static let windowMinWidth: CGFloat = 545

    static func tier(for width: CGFloat) -> LayoutTier {
        if width >= wideMinWidth { return .wide }
        if width >= mediumMinWidth { return .medium }
        return .compact
    }
}

private struct LayoutTierKey: EnvironmentKey {
    static let defaultValue: LayoutTier = .medium
}

extension EnvironmentValues {
    var layoutTier: LayoutTier {
        get { self[LayoutTierKey.self] }
        set { self[LayoutTierKey.self] = newValue }
    }
}

/// Root settings window — sidebar + tab content.
/// UI is intentionally minimal here; the user will redesign the visual layer.
struct SettingsView: View {

    @Environment(AppState.self) private var appState
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        let tabBinding = Binding<SettingsTab?>(
            get: { appState.selectedSettingsTab ?? .home },
            set: { newValue in
                guard newValue != appState.selectedSettingsTab else { return }
                appState.selectedSettingsTab = newValue
                if let newValue {
                    appState.trackSettingsTabViewed(newValue)
                }
            }
        )

        GeometryReader { proxy in
            let tier = LayoutTier.tier(for: proxy.size.width)

            NavigationSplitView(columnVisibility: $columnVisibility) {
                Group {
                    if appState.isShowingSettings {
                        SettingsSidebarView(selected: tabBinding)
                    } else {
                        SidebarView(selected: tabBinding)
                    }
                }
                .navigationSplitViewColumnWidth(
                    min: SettingsLayout.sidebarWidth - 20,
                    ideal: SettingsLayout.sidebarWidth,
                    max: SettingsLayout.sidebarWidth + 20
                )
            } detail: {
                tabContent(for: appState.selectedSettingsTab ?? .home)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background {
                        SettingsPalette.warmBackdrop.ignoresSafeArea()
                    }
            }
            .navigationSplitViewStyle(.balanced)
            .environment(\.layoutTier, tier)
            .onAppear {
                let tab = appState.selectedSettingsTab ?? .home
                appState.selectedSettingsTab = tab
                appState.trackSettingsTabViewed(tab)
                columnVisibility = (tier == .compact) ? .detailOnly : .all
            }
            .onChange(of: tier) { _, newTier in
                columnVisibility = (newTier == .compact) ? .detailOnly : .all
            }
            .background {
                // ⌘K — feed search from main app, no-op when inside settings
                // (the settings sidebar already has its own search field).
                Button("") {
                    guard !appState.isShowingSettings else { return }
                    if appState.selectedSettingsTab != .home {
                        appState.selectedSettingsTab = .home
                    }
                    appState.isHomeSearchOpen.toggle()
                }
                .keyboardShortcut("k", modifiers: .command)
                .hidden()

                // ⌘, — open Settings (Mac convention).
                Button("") {
                    if !appState.isShowingSettings {
                        appState.openSettingsAtPreferredTab()
                    }
                }
                .keyboardShortcut(",", modifiers: .command)
                .hidden()
            }
            .overlay {
                if appState.isHomeSearchOpen {
                    HomeSearchModal(appState: appState)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func tabContent(for selectedTab: SettingsTab) -> some View {
        switch selectedTab {
        case .home:            HomeTabView()
        case .space:           SpaceTabView()
        case .meetings:        MeetingsTabView()
        case .progression:     ProgressionTabView()
        case .journal:         JournalTabView()
        case .dictation:       DictationTabView()
        case .writing:         WritingTabView()
        case .personalization: PersonalizationSettingsView()
        case .appearance:      AppearanceTabView()
        case .dictionary:      DictionaryTabView()
        case .smartLinks:      SmartLinksTabView()
        case .meetingSettings: MeetingSettingsView()
        case .meetingAdvanced: MeetingAdvancedSettingsView()
        case .models:          ModelsLanguageTabView()
        case .workspace:       WorkspaceTabView()
        case .workspaceCloud:  WorkspaceCloudSettingsView()
        case .workspaceExcludedApps: WorkspaceExcludedAppsView()
        case .mcpServer:       MCPServerTabView()
        case .apiCli:          APICLITabView()
        case .advanced:        AdvancedTabView()
        case .dispatchDebug:
            #if DEBUG
            if selectedTab.isAvailable {
                DispatchDebugTabView()
            } else {
                AccountTabView()
            }
            #else
            AccountTabView()
            #endif
        case .account:         AccountTabView()
        case .support:         SupportTabView()
        }
    }
}

// MARK: - Sidebar

enum SettingsTab: String, CaseIterable, Identifiable {
    // Main
    case home        = "Home"
    case space       = "Space"
    case meetings    = "Meetings"
    case journal     = "Journal"
    // Settings — General
    case account          = "General"
    // Settings — Capture
    case dictation        = "Dictation"
    case writing          = "Writing"
    case dictionary       = "Dictionary"
    case smartLinks       = "Smart Links"
    case personalization   = "Personalization"
    // Settings — Meetings
    case meetingSettings      = "MeetingSettings"
    case meetingAdvanced      = "MeetingAdvanced"
    case models           = "Models"
    // Settings — Workspace
    case workspace        = "Workspace"
    case workspaceCloud   = "WorkspaceCloud"
    case workspaceExcludedApps = "WorkspaceExcludedApps"
    case mcpServer        = "MCP Server"
    case apiCli           = "API"
    case advanced         = "Advanced"
    case dispatchDebug    = "Dispatch Debug"
    // Settings — Display
    case appearance       = "Appearance"
    case progression      = "Progression"
    case support          = "Help & Support"

    var id: String { rawValue }

    /// Whether this tab belongs to the settings page (vs. the main sidebar).
    var isSettingsTab: Bool {
        switch self {
        case .home, .space, .meetings, .journal, .support:
            false
        default:
            true
        }
    }

    /// Tabs shown in the main app sidebar.
    static let mainTabs: [SettingsTab] = [.home, .meetings, .space]

    /// Grouped sections for the settings sidebar.
    static var settingsSections: [(label: String?, tabs: [SettingsTab])] {
        var sections: [(label: String?, tabs: [SettingsTab])] = [
            ("General",   [.account, .appearance]),
            ("Use",       [.dictation, .dictionary, .meetingSettings, .personalization, .smartLinks, .writing]),
            ("Privacy",   [.workspace]),
            ("Advanced",  [.advanced]),
        ]
        #if DEBUG
        if AppFeatureVisibility.dispatch {
            sections.append(("Developer", [.dispatchDebug]))
        }
        #endif

        return sections
            .map { section in
                (section.label, section.tabs.filter(\.isAvailable))
            }
            .filter { !$0.tabs.isEmpty }
    }

    static var settingsSidebarTabs: [SettingsTab] {
        settingsSections.flatMap(\.tabs)
    }

    /// Parent settings tab for sub-pages (drilled-in details). The Back button
    /// on those pages routes here. Nil for top-level tabs.
    var parentSettingsTab: SettingsTab? {
        switch self {
        case .meetingAdvanced: .meetingSettings
        case .workspaceCloud, .workspaceExcludedApps: .workspace
        default: nil
        }
    }

    var isSettingsSidebarTab: Bool {
        Self.settingsSidebarTabs.contains(self)
    }

    var isAvailable: Bool {
        switch self {
        case .dispatchDebug:
            #if DEBUG
            AppFeatureVisibility.dispatch && AppRuntime.appEnvironment == .development
            #else
            false
            #endif
        default:
            true
        }
    }

    var icon: String {
        switch self {
        case .home:            "house.fill"
        case .space:           "square.stack.3d.up.fill"
        case .meetings:        "video.fill"
        case .progression:     "trophy.fill"
        case .journal:         "book.closed.fill"
        case .dictation:       "mic.fill"
        case .writing:         "text.append"
        case .personalization:  "brain.head.profile"
        case .appearance:      "sparkles"
        case .dictionary:      "character.book.closed.fill"
        case .smartLinks:      "link"
        case .meetingSettings: "video.badge.ellipsis"
        case .meetingAdvanced: "slider.horizontal.3"
        case .models:          "cpu"
        case .workspace:       "externaldrive.fill"
        case .workspaceCloud:  "icloud.fill"
        case .workspaceExcludedApps: "app.badge"
        case .mcpServer:       "bolt.horizontal.fill"
        case .apiCli:          "terminal.fill"
        case .advanced:        "slider.horizontal.3"
        case .dispatchDebug:    "point.3.connected.trianglepath.dotted"
        case .account:         "person.circle.fill"
        case .support:         "questionmark.circle.fill"
        }
    }

    var displayName: String {
        switch self {
        case .meetingSettings: "Meetings"
        case .meetingAdvanced: "Meeting advanced"
        case .models:          "Models & Language"
        case .workspace:       "Privacy"
        case .workspaceCloud:  "Cloud Sync"
        case .workspaceExcludedApps: "Excluded apps"
        case .mcpServer:       "MCP Server"
        case .apiCli:          "Local API"
        case .dispatchDebug:    "Dispatch"
        default: rawValue
        }
    }
}

private struct SidebarView: View {
    @Binding var selected: SettingsTab?
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarBrandHeader()

            SidebarSearchField()
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(SettingsTab.mainTabs) { tab in
                        SidebarMainRow(tab: tab, selected: $selected)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 2)
                .padding(.bottom, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 8) {
                if appState.availableUpdate != nil {
                    SidebarUpdateCard()
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                SidebarSettingsButton {
                    appState.openSettingsAtPreferredTab()
                }

                SidebarSupportButton(selected: $selected)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}

// MARK: - Sidebar Nav Row (main tabs except Chat)

private struct SidebarMainRow: View {
    let tab: SettingsTab
    @Binding var selected: SettingsTab?
    @State private var isHovered = false

    private var isSelected: Bool { selected == tab }

    var body: some View {
        Button {
            selected = tab
        } label: {
            HStack(spacing: 8) {
                Image(systemName: tab.icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                Text(tab.displayName)
                    .font(.system(size: 13, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(SettingsPalette.infoText) : AnyShapeStyle(HierarchicalShapeStyle.primary))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(rowFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? SettingsPalette.accentBorder : .clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var rowFill: Color {
        if isSelected { return SettingsPalette.accentFill }
        if isHovered { return SettingsPalette.elevatedBackground.opacity(0.55) }
        return .clear
    }
}

// MARK: - Sidebar Search Field (opens the Home feed search modal)

private struct SidebarSearchField: View {
    @Environment(AppState.self) private var appState
    @State private var isHovered = false

    private var hasActiveFilters: Bool {
        !appState.homeSearchText.isEmpty
            || appState.homeSearchKindFilter != .all
            || appState.homeSearchTimeFilter != .allTime
    }

    var body: some View {
        Button {
            if appState.selectedSettingsTab != .home {
                appState.selectedSettingsTab = .home
                appState.isShowingSettings = false
            }
            appState.isHomeSearchOpen = true
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(hasActiveFilters ? AnyShapeStyle(SettingsPalette.infoText) : AnyShapeStyle(HierarchicalShapeStyle.tertiary))

                Text(hasActiveFilters ? "Filtered" : "Search")
                    .font(.system(size: 12))
                    .foregroundStyle(hasActiveFilters ? AnyShapeStyle(SettingsPalette.infoText) : AnyShapeStyle(HierarchicalShapeStyle.secondary))

                Spacer(minLength: 0)

                Text("⌘K")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(SettingsPalette.elevatedBackground.opacity(0.8))
                    )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? SettingsPalette.elevatedBackground.opacity(0.7) : SettingsPalette.elevatedBackground.opacity(0.35))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(SettingsPalette.border.opacity(hasActiveFilters ? 0.25 : 0.12), lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .help("Search feed (⌘K)")
    }
}

private struct SidebarSupportButton: View {
    @Binding var selected: SettingsTab?

    private var isSelected: Bool {
        selected == .support
    }

    var body: some View {
        Button {
            selected = .support
        } label: {
            Label(SettingsTab.support.rawValue, systemImage: SettingsTab.support.icon)
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? SettingsPalette.accentFill : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isSelected ? SettingsPalette.accentBorder : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

private struct SidebarBrandHeader: View {
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("Resonant")
                .font(.system(size: 18, weight: .semibold))

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Resonant")
        .accessibilityHint("Sidebar wordmark")
    }
}

// MARK: - Settings Sidebar (replaces main sidebar when showing settings)

private struct SettingsSidebarView: View {
    @Binding var selected: SettingsTab?
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                appState.isShowingSettings = false
                appState.selectedSettingsTab = .home
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Settings")
                        .font(.system(size: 18, weight: .semibold))
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 16)

            SettingsSearchField(selected: $selected)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(SettingsTab.settingsSections.enumerated()), id: \.offset) { _, section in
                        VStack(alignment: .leading, spacing: 6) {
                            if let label = section.label {
                                Text(label)
                                    .font(SettingsTypography.sectionLabel)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 10)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(section.tabs) { tab in
                                    SettingsSidebarNavRow(
                                        tab: tab,
                                        isSelected: selected == tab
                                    ) {
                                        selected = tab
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background {
            ZStack {
                VibrancyBackground(material: .sidebar)
                SettingsPalette.sidebarBackground.opacity(0.35)
            }
            .ignoresSafeArea()
        }
    }
}

private struct SettingsSidebarNavRow: View {
    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: tab.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 22)

                Text(tab.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? .primary : .secondary)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: SettingsLayout.sidebarRowHeight, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: SettingsLayout.cardRadius, style: .continuous)
                    .fill(rowFill)
            )
            .contentShape(RoundedRectangle(cornerRadius: SettingsLayout.cardRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tab.displayName)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var rowFill: Color {
        if isSelected { return SettingsPalette.elevatedBackground }
        if isHovered { return SettingsPalette.mutedCardBackground.opacity(0.7) }
        return .clear
    }
}

// MARK: - Settings Button (Main Sidebar Footer)

private struct SidebarSettingsButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)

                Text("Settings")
                    .font(.system(size: 13, weight: .medium))

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, minHeight: SettingsLayout.sidebarRowHeight, alignment: .leading)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SidebarUpdateCard: View {
    @Environment(AppState.self) private var appState
    @State private var isHovered = false

    private var isReady: Bool {
        appState.availableUpdate?.isReadyToRestart ?? false
    }

    var body: some View {
        Button {
            appState.relaunchForAvailableUpdate()
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: isReady ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(SettingsPalette.infoText)

                VStack(alignment: .leading, spacing: 2) {
                    Text(appState.availableUpdate?.sidebarTitle ?? "Update ready")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if let subtitle = appState.availableUpdate?.sidebarSubtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if isReady {
                    Text("Restart")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SettingsPalette.infoText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(SettingsPalette.infoText.opacity(0.14))
                        )
                        .overlay(
                            Capsule().stroke(SettingsPalette.infoText.opacity(0.3), lineWidth: 0.5)
                        )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(SettingsPalette.infoFill.opacity(isHovered ? 1.0 : 0.75))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(SettingsPalette.infoBorder, lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .help(appState.availableUpdate?.sidebarHelp ?? "Show update progress")
    }
}


enum ResonantBrand {
    static let amber = Color(red: 0.85, green: 0.46, blue: 0.02)       // #D97706
    static let amberLight = Color(red: 0.98, green: 0.62, blue: 0.15)  // warm highlight
    static let amberDark = Color(red: 0.71, green: 0.33, blue: 0.04)   // #B45309

    static let green = Color(red: 0.02, green: 0.59, blue: 0.41)       // #059669 emerald
    static let greenDark = Color(red: 0.02, green: 0.47, blue: 0.34)   // #047857 deeper emerald

    static let greenFill = LinearGradient(
        colors: [green, greenDark],
        startPoint: .top,
        endPoint: .bottom
    )
}



private struct ScrollViewAxisConfigurator: NSViewRepresentable {
    let configure: (NSScrollView) -> Void

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let scrollView = nsView.nearestEnclosingScrollView else { return }
            configure(scrollView)
        }
    }
}

private extension View {
    func lockToVerticalScrollAxis() -> some View {
        background(
            ScrollViewAxisConfigurator { scrollView in
                scrollView.hasHorizontalScroller = false
                scrollView.horizontalScrollElasticity = .none
                scrollView.usesPredominantAxisScrolling = true
            }
        )
    }
}

private extension NSView {
    var nearestEnclosingScrollView: NSScrollView? {
        if let enclosingScrollView {
            return enclosingScrollView
        }

        var ancestor = superview
        while let view = ancestor {
            if let scrollView = view as? NSScrollView {
                return scrollView
            }
            if let scrollView = view.enclosingScrollView {
                return scrollView
            }
            ancestor = view.superview
        }

        return nil
    }
}

struct JournalTabView: View {
    @Environment(AppState.self) private var appState
    @State private var isGenerating = false
    @State private var selectedDate = Calendar.current.startOfDay(for: Date())
    @State private var selectedDay: JournalDay?
    @State private var expandedBlockIDs: Set<UUID> = []
    @State private var isEvidenceExpanded = false
    @State private var showIntroModal = false
    @State private var journalQuestion = ""
    @State private var isAskingQuestion = false
    @State private var questionAnswer = ""
    @State private var questionError: String?

    private var sortedBlocks: [JournalBlock] {
        (selectedDay?.blocks ?? []).sorted { $0.startTime < $1.startTime }
    }

    private var dayData: DayData {
        DayData.build(day: selectedDay)
    }

    private var isToday: Bool {
        Calendar.current.isDateInToday(selectedDate)
    }

    private var isLoading: Bool {
        appState.journalManager.isLoading && selectedDay == nil && appState.journalManager.days.isEmpty
    }

    var body: some View {
        Group {
            if isLoading {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading journal\u{2026}")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                journalWorkspace
            }
        }
        .background(SettingsPalette.warmBackdrop)
        .overlay {
            Group {
                if showIntroModal {
                    JournalIntroModal(isPresented: $showIntroModal)
                        .transition(.opacity)
                }
            }
        }
        .task {
            await appState.journalManager.load(
                from: appState.dataStore,
                convexClient: appState.convexClient,
                settingsManager: appState.settingsManager
            )
            await syncSelectedDay()
        }
        .task(id: selectedDate) {
            await syncSelectedDay()
        }
        .onChange(of: appState.journalManager.days.map(\.generatedAt)) { _, _ in
            selectedDay = appState.journalManager.journal(on: selectedDate)
        }
        .onAppear {
            if !appState.settingsManager.journalIntroSeen {
                appState.settingsManager.journalIntroSeen = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    showIntroModal = true
                }
            }
        }
    }

    private var journalWorkspace: some View {
        HStack(alignment: .top, spacing: 12) {
            journalContentPanel

            JournalActivitySidebar(
                days: appState.journalManager.days,
                selectedDate: $selectedDate
            )
            .frame(minWidth: 220, idealWidth: 240, maxWidth: 260)
        }
        .padding(16)
    }

    @ViewBuilder
    private var journalContentPanel: some View {
        if appState.settingsManager.journalRedesignEnabled {
            JournalPageRedesignView(
                selectedDate: selectedDate,
                day: selectedDay,
                dayData: dayData,
                sortedBlocks: sortedBlocks,
                isToday: isToday,
                isGenerating: isGenerating || appState.journalManager.isLoading,
                isAskingQuestion: isAskingQuestion,
                questionAnswer: questionAnswer,
                questionError: questionError,
                errorMessage: appState.journalManager.lastErrorMessage?.journalTrimmed,
                expandedBlockIDs: $expandedBlockIDs,
                isEvidenceExpanded: $isEvidenceExpanded,
                journalQuestion: $journalQuestion,
                onPrevious: { shiftDate(by: -1) },
                onNext: { shiftDate(by: 1) },
                onRefresh: refreshJournal,
                onHowItWorks: {
                    showIntroModal = true
                },
                onSubmitQuestion: submitJournalQuestion,
                onPromptTap: { prompt in
                    journalQuestion = prompt
                    submitJournalQuestion()
                },
                onUseClassic: {
                    appState.settingsManager.journalRedesignEnabled = false
                }
            )
        } else {
            legacyJournalContentPanel
        }
    }

    private var legacyJournalContentPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !appState.settingsManager.journalBannerDismissed {
                    journalBanner
                }

                JournalDateHeaderView(
                    selectedDate: selectedDate,
                    isToday: isToday,
                    isRefreshing: isGenerating || appState.journalManager.isLoading,
                    onPrevious: { shiftDate(by: -1) },
                    onNext: { shiftDate(by: 1) },
                    onRefresh: refreshJournal,
                    onHowItWorks: {
                            showIntroModal = true
                    }
                )

                if let error = appState.journalManager.lastErrorMessage?.journalTrimmed {
                    JournalInlineMessageView(
                        message: error,
                        systemImage: "exclamationmark.triangle.fill",
                        tint: SettingsPalette.semanticRed
                    )
                }

                if sortedBlocks.isEmpty {
                    ContentUnavailableView(
                        isToday ? "No journal yet" : "No activity on this day",
                        systemImage: "book.closed",
                        description: Text(
                            isToday
                                ? "Start dictating and your day will build into the journal here."
                                : "Move to another day or regenerate if you expect captured activity."
                        )
                    )
                    .frame(maxWidth: .infinity, minHeight: 320)
                } else {
                    JournalTakeawaysView(
                        dayData: dayData,
                        blocks: sortedBlocks
                    )

                    JournalBriefSynthesisView(
                        dayData: dayData,
                        onRegenerate: refreshJournal
                    )

                    JournalEvidenceView(
                        day: selectedDay,
                        blocks: sortedBlocks,
                        isExpanded: $isEvidenceExpanded,
                        expandedBlockIDs: $expandedBlockIDs
                    )

                    if AppFeatureVisibility.hostedServices {
                        JournalAskPanel(
                            question: $journalQuestion,
                            isAsking: isAskingQuestion,
                            answer: questionAnswer,
                            error: questionError,
                            onSubmit: submitJournalQuestion,
                            onPrompt: { prompt in
                                journalQuestion = prompt
                                submitJournalQuestion()
                            }
                        )
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
        .scrollIndicators(.hidden)
    }

    private var journalBanner: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "book.closed.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SettingsPalette.infoText)

            Text("Your journal builds automatically from dictations and meetings throughout the day. Browse past days or regenerate to refresh.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Button {
                appState.settingsManager.journalRedesignEnabled = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Try new layout")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(SettingsPalette.infoText)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(SettingsPalette.infoText.opacity(0.10))
                )
            }
            .buttonStyle(.plain)
            .help("Preview the redesigned Journal page")

            Button {
                appState.settingsManager.journalBannerDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(SettingsPalette.infoFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(SettingsPalette.infoBorder, lineWidth: 1)
        )
    }

    private func shiftDate(by offset: Int) {
        guard let nextDate = Calendar.current.date(byAdding: .day, value: offset, to: selectedDate) else { return }
        selectedDate = Calendar.current.startOfDay(for: min(nextDate, Date()))
    }

    private func refreshJournal() {
        Task {
            isGenerating = true
            defer { isGenerating = false }

            let outcome = await appState.generateJournal(for: selectedDate, userInitiated: true)
            if let day = outcome.day {
                selectedDay = day
            } else {
                selectedDay = await appState.journalManager.journalAsync(on: selectedDate)
            }
        }
    }

    private func submitJournalQuestion() {
        let raw = journalQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !isAskingQuestion else { return }

        let target = selectedDate
        isAskingQuestion = true
        questionAnswer = ""
        questionError = nil
        journalQuestion = ""

        Task {
            let stream = appState.journalManager.streamChatMessage(
                for: target,
                userMessage: raw,
                attachments: []
            )

            do {
                for try await delta in stream {
                    questionAnswer += delta
                }
            } catch {
                questionError = error.localizedDescription
            }

            isAskingQuestion = false
            selectedDay = await appState.journalManager.journalAsync(on: target)
        }
    }

    private func syncSelectedDay() async {
        selectedDay = await appState.journalManager.journalAsync(on: selectedDate)
        expandedBlockIDs.removeAll()
        isEvidenceExpanded = false
        questionAnswer = ""
        questionError = nil
        generateBriefIfNeeded()
    }

    private func generateBriefIfNeeded() {
        guard !isGenerating else { return }
        guard let day = selectedDay, !day.blocks.isEmpty else { return }
        guard day.narrativeBrief?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else { return }

        let target = selectedDate
        Task {
            isGenerating = true
            defer { isGenerating = false }

            let outcome = await appState.generateJournal(for: target)
            guard Calendar.current.isDate(selectedDate, inSameDayAs: target) else { return }
            if let day = outcome.day {
                selectedDay = day
            } else {
                selectedDay = await appState.journalManager.journalAsync(on: target)
            }
        }
    }
}

// Journal shared views — see JournalSharedViews.swift


private func triggerUsageHint(
    mode: HotkeyMode,
    trigger: HotkeyTrigger,
    holdLockEnabled: Bool
) -> String {
    switch mode {
    case .hold:
        if holdLockEnabled {
            "Hold \(trigger.displayName), speak, release. Lock: \(trigger.displayName) + Spacebar. Stop a locked recording: tap \(trigger.displayName). Memos: \(trigger.displayName) + Control."
        } else {
            "Hold \(trigger.displayName), speak, release. Memos: \(trigger.displayName) + Control."
        }
    case .toggle:
        "Tap \(trigger.displayName) to start, tap again to stop. Memos: \(trigger.displayName) + Control."
    }
}

struct DictationTabView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var settings = appState.settingsManager
        let hotkeyDiagnostics = HotkeyDiagnostics.current()
        let reconfigureHotkey = {
            appState.hotkeyManager.reconfigure(
                triggers: settings.hotkeyTriggers,
                mode: settings.hotkeyMode,
                holdToTalkLockEnabled: settings.hotkeyHoldLockEnabled
            )
        }

        let hotkeyWarnings: [HotkeyTrigger: String] = {
            guard let reason = hotkeyDiagnostics.fnFallbackReason else { return [:] }
            return [.fn: "\(reason) Right Option usually works better on this Mac."]
        }()

        SettingsPage(title: "Dictation") {
            SettingsCardSection(
                "Trigger",
                footer: triggerUsageHint(
                    mode: settings.hotkeyMode,
                    trigger: settings.hotkeyTrigger,
                    holdLockEnabled: settings.hotkeyHoldLockEnabled
                )
            ) {
                SettingsValueRow("Key") {
                    HotkeyRecorderView(
                        trigger: $settings.hotkeyTrigger,
                        alternateTriggers: $settings.hotkeyAlternateTriggers,
                        warningsByTrigger: hotkeyWarnings,
                        onChange: { _, _ in
                            reconfigureHotkey()
                        }
                    )
                }

                SettingsRowDivider()
                SettingsValueRow("Mode") {
                    HotkeyModePicker(mode: $settings.hotkeyMode) {
                        reconfigureHotkey()
                    }
                    .frame(width: 360)
                }
                .accessibilityLabel("Start and stop")

                if settings.hotkeyMode == .hold {
                    SettingsRowDivider()
                    SettingsToggleRow(
                        "Lock hold-to-talk",
                        detail: "Press \(settings.hotkeyTrigger.displayName) + Spacebar to keep recording after you release; tap \(settings.hotkeyTrigger.displayName) to stop.",
                        isOn: $settings.hotkeyHoldLockEnabled
                    )
                    .onChange(of: settings.hotkeyHoldLockEnabled) { _, _ in
                        reconfigureHotkey()
                    }
                }

                SettingsRowDivider()
                SettingsValueRow(
                    "Backup key",
                    detail: "Optional alternates that do the same thing."
                ) {
                    HotkeyAlternateTriggersEditor(
                        trigger: $settings.hotkeyTrigger,
                        alternateTriggers: $settings.hotkeyAlternateTriggers,
                        onChange: { _, _ in
                            reconfigureHotkey()
                        }
                    )
                }
            }
            .id(SettingsAnchor.dictationHotkey)

            if AppFeatureVisibility.dispatch {
                SettingsCardSection(
                    "Dispatch",
                    footer: "When cloud fallback is off, Dispatch only runs local actions it can resolve immediately."
                ) {
                    SettingsToggleRow(
                        "Voice commands with Fn + Shift",
                        detail: "Hold Fn + Shift to speak a command, then release to run it.",
                        isOn: $settings.dispatchEnabled
                    )
                    SettingsRowDivider()
                    SettingsToggleRow("Speak command results", isOn: $settings.dispatchTTSEnabled)
                        .disabled(!settings.dispatchEnabled)
                    SettingsRowDivider()
                    SettingsToggleRow("Use cloud fallback for unknown commands", isOn: $settings.dispatchCloudFallbackEnabled)
                        .disabled(!settings.dispatchEnabled)
                }
            }

            SettingsCardSection("Output") {
                SettingsToggleRow("Copy to clipboard", isOn: $settings.copyToClipboardEnabled)
                SettingsRowDivider()
                SettingsToggleRow("Auto-send (Enter after paste)", isOn: $settings.autoSendEnabled)
            }
            .id(SettingsAnchor.dictationOutput)

            SettingsCardSection("Microphone") {
                SettingsPickerRow("Input device", selection: $settings.inputDeviceUID) {
                        Text("System Default").tag(Optional<String>.none)
                        ForEach(appState.audioInputDeviceManager.devices) { device in
                            Text(device.isSystemDefault ? "\(device.name) (Default)" : device.name)
                                .tag(Optional(device.id))
                        }
                }
                .onChange(of: settings.inputDeviceUID) { _, _ in
                    appState.didChangeInputSelection()
                }

                SettingsRowDivider()
                SettingsValueRow("Refresh devices") {
                    HStack(spacing: 10) {
                        if let activeMicrophone = appState.activeInputDeviceName {
                            SettingsMetaPill(title: "Active: \(activeMicrophone)", systemImage: "mic")
                        }

                        Button("Refresh") {
                            appState.refreshAudioInputStatus()
                        }
                        .buttonStyle(.bordered)
                    }
                }

                if let routingMessage = appState.inputRoutingMessage {
                    SettingsSectionBody {
                        Text(routingMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                SettingsRowDivider()
                SettingsToggleRow(
                    "Switch microphone when lid is closed",
                    detail: "In clamshell mode, swap from the built-in microphone to the next available external mic.",
                    isOn: $settings.clamshellMicSwitchEnabled
                )
            }
            .id(SettingsAnchor.dictationAudio)

            TranscriptionLanguageSettingsSection(anchor: SettingsAnchor.dictationLanguage)

            SettingsCardSection("Advanced") {
                SettingsDrillInRow(
                    title: "More Dictation Settings",
                    detail: "Models and recording behavior.",
                    value: nil,
                    systemImage: SettingsTab.advanced.icon
                ) {
                    appState.selectedSettingsTab = .advanced
                }
            }
        }
    }
}

struct WritingTabView: View {
    @Environment(AppState.self) private var appState
    private let resonantWebsiteURL: URL = URL(string: EmailSignatureSupport.footerURLString) ?? AppRuntime.appEnvironment.authBaseURL()

    var body: some View {
        @Bindable var settings = appState.settingsManager

        SettingsPage(title: "Writing") {
            SettingsCardSection("Text Cleanup") {
                SettingsToggleRow("Add punctuation", isOn: $settings.autoPunctuationEnabled)
                SettingsRowDivider()
                SettingsToggleRow("Remove filler words", isOn: $settings.removeFillersEnabled)
                SettingsRowDivider()
                SettingsToggleRow("Remove false starts", isOn: $settings.removeFalseStartsEnabled)
                SettingsRowDivider()
                SettingsToggleRow("Convert spoken numbers", isOn: $settings.itnEnabled)
                SettingsRowDivider()
                SettingsToggleRow("Bullet points", isOn: $settings.bulletPointsEnabled)
            }
            .id(SettingsAnchor.writingCleanup)

            if AppFeatureVisibility.hostedServices {
                SettingsCardSection(
                    "Polish",
                    footer: "How much the cloud cleanup may rewrite. Verbatim keeps exactly what you said, Clean fixes mistakes without rephrasing, Polished lightly rewrites so it reads as written."
                ) {
                    SettingsPickerRow(
                        "Messages",
                        detail: "Slack, iMessage, and other chat apps.",
                        selection: $settings.polishLevelChat,
                        presentation: .segmented
                    ) {
                        ForEach(DictationPolishLevel.allCases, id: \.self) { level in
                            Text(level.displayName).tag(level)
                        }
                    }
                    SettingsRowDivider()
                    SettingsPickerRow(
                        "Email",
                        detail: "Detected email compose windows.",
                        selection: $settings.polishLevelEmail,
                        presentation: .segmented
                    ) {
                        ForEach(DictationPolishLevel.allCases, id: \.self) { level in
                            Text(level.displayName).tag(level)
                        }
                    }
                    SettingsRowDivider()
                    SettingsPickerRow(
                        "Everything else",
                        detail: "Docs, notes, and other writing surfaces.",
                        selection: $settings.polishLevelOther,
                        presentation: .segmented
                    ) {
                        ForEach(DictationPolishLevel.allCases, id: \.self) { level in
                            Text(level.displayName).tag(level)
                        }
                    }
                }

                SettingsCardSection("Selection Transform") {
                    SettingsValueRow(
                        "Rewrite highlighted text",
                        detail: "Highlight any text, press your dictation key, and say what to do — like \"rewrite more formally\", \"shorten this\", or \"reformat as bullets\". Resonant transforms the selection instead of replacing it."
                    ) {
                        Toggle("", isOn: $settings.selectionTransformEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                }
            }

            SettingsCardSection(
                "Email",
                footer: AppRuntime.distributionFlavor == .official
                    ? "The footer is added in detected email compose windows and can be turned off here."
                    : "Controls formatting for detected email compose windows."
            ) {
                SettingsTextFieldRow(
                    "Sign-off name",
                    detail: "Leave empty to use your account name.",
                    placeholder: settings.userDisplayName ?? "Account name",
                    text: Binding(
                        get: { settings.emailSignoffName ?? "" },
                        set: { settings.emailSignoffName = $0 }
                    ),
                    controlWidth: 260
                )

                if AppRuntime.distributionFlavor == .official {
                    SettingsRowDivider()
                    SettingsToggleRow("Add Resonant footer", isOn: $settings.emailSignatureEnabled)

                    if settings.emailSignatureEnabled {
                        SettingsRowDivider()
                        SettingsValueRow("Footer preview") {
                            HStack(spacing: 0) {
                                Text("Sent with ")
                                    .foregroundStyle(.secondary)
                                Link("Resonant", destination: resonantWebsiteURL)
                                    .foregroundStyle(Color(red: 0, green: 0, blue: 0.933))
                            }
                            .font(.caption)
                        }
                    }
                }
            }
            .id(SettingsAnchor.writingEmail)

            SettingsCardSection("Related Writing Aids") {
                SettingsDrillInRow(
                    title: "Dictionary",
                    detail: "Correct names, terms, and words Resonant mishears.",
                    value: "\(appState.dictionaryStore.allWords.count)",
                    systemImage: SettingsTab.dictionary.icon
                ) {
                    appState.selectedSettingsTab = .dictionary
                }

                SettingsRowDivider()
                SettingsDrillInRow(
                    title: "Smart Links",
                    detail: "Replace spoken phrases with links.",
                    value: "\(appState.smartLinkStore.links.count)",
                    systemImage: SettingsTab.smartLinks.icon
                ) {
                    appState.selectedSettingsTab = .smartLinks
                }

            }
            .id(SettingsAnchor.writingAids)
        }
    }
}

private struct PasteReliabilitySettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var settings = appState.settingsManager

        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionBody {
                SettingsCallout(
                    "Keep Auto unless a specific app needs a workaround. Failed attempts copy the text so it can still be pasted manually.",
                    title: "Paste reliability",
                    systemImage: "keyboard.badge.ellipsis"
                )
            }

            SettingsRowDivider()
            SettingsPickerRow(
                "Paste method",
                detail: settings.pasteDeliveryMode.detail,
                selection: $settings.pasteDeliveryMode,
                presentation: .segmented
            ) {
                ForEach(PasteDeliveryMode.settingsOrder, id: \.self) { mode in
                    Text(mode.controlLabel).tag(mode)
                }
            }

            SettingsRowDivider()
            PasteDiagnosticTestView()
        }
    }
}

private struct PasteDiagnosticTestView: View {
    @Environment(AppState.self) private var appState
    @FocusState private var isTestFieldFocused: Bool
    @State private var testFieldText = ""
    @State private var report: PasteDiagnosticReport?
    @State private var isRunning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsValueRow(
                "Paste test",
                detail: "Verify the current paste method in this field."
            ) {
                HStack(alignment: .center, spacing: 8) {
                    TextField("Paste test output", text: $testFieldText, prompt: Text("Paste test output"))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .frame(width: 220)
                        .focused($isTestFieldFocused)
                        .accessibilityLabel("Paste test field")

                    Button {
                        runTest()
                    } label: {
                        Label("Test", systemImage: "keyboard")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRunning)

                    Button {
                        testFieldText = ""
                        report = nil
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(isRunning || testFieldText.isEmpty)
                    .help("Clear paste test")

                    if isRunning {
                        ProgressView()
                            .scaleEffect(0.65)
                            .frame(width: 16, height: 16)
                    }
                }
                .controlSize(.small)
            }

            SettingsRowDivider()
            if let report {
                SettingsSectionBody {
                    PasteDiagnosticResultView(report: report)
                }
            } else {
                SettingsSectionBody {
                    Text("Click Test to verify the current paste method in this field.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func runTest() {
        guard !isRunning else { return }

        Task { @MainActor in
            isRunning = true
            report = nil
            let marker = "Resonant paste test \(Int(Date().timeIntervalSince1970))"
            testFieldText = ""
            isTestFieldFocused = true

            try? await Task.sleep(for: .milliseconds(180))
            var diagnosticReport = await appState.runPasteDiagnosticTest(text: marker)
            try? await Task.sleep(for: .milliseconds(260))
            diagnosticReport = diagnosticReport.withInsertedIntoTestField(testFieldText.contains(marker))
            appState.recordPasteDiagnosticResult(diagnosticReport)
            report = diagnosticReport
            isRunning = false
        }
    }
}

private struct PasteDiagnosticResultView: View {
    let report: PasteDiagnosticReport

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                SettingsMetaPill(title: report.deliveryMode.displayName, systemImage: "arrow.triangle.2.circlepath")
                SettingsMetaPill(
                    title: report.accessibilityTrusted ? "Accessibility OK" : "Accessibility missing",
                    systemImage: report.accessibilityTrusted ? "checkmark.shield" : "exclamationmark.triangle",
                    tint: report.accessibilityTrusted ? .green : .orange
                )
                if report.secureInputActive {
                    SettingsMetaPill(title: "Secure input", systemImage: "lock.fill", tint: .orange)
                }
                if report.hasBlockingModifierFlags {
                    SettingsMetaPill(title: "Modifiers held", systemImage: "command", tint: .orange)
                }
            }
        }
        .padding(.top, 2)
    }

    private var title: String {
        if report.insertedIntoTestField == true {
            return "Paste test passed"
        }

        if report.deliverySucceeded {
            return "Paste was sent but not confirmed"
        }

        switch report.failure {
        case .accessibilityPermissionRequired, .accessibilityPermissionStale:
            return "Accessibility needs attention"
        case .secureInputActive:
            return "Secure Keyboard Entry is blocking paste"
        case .partialDelivery:
            return "Text was only partially inserted"
        case .targetActivationFailed, .noFrontmostTarget:
            return "No focused target"
        case .deliveryUnverified:
            return "Insertion was not verified"
        case .writeFailed:
            return "Clipboard write failed"
        case .none:
            return "Paste test failed"
        }
    }

    private var detail: String {
        if report.insertedIntoTestField == true {
            return "The current paste method inserted text into the focused test field."
        }

        switch report.failure {
        case .accessibilityPermissionStale:
            return "Remove Resonant from Accessibility settings, then add the app again from Applications."
        case .accessibilityPermissionRequired:
            return "Open Accessibility settings and enable Resonant."
        case .secureInputActive:
            return "Close password prompts or Terminal secure input sessions, then run the test again."
        case .partialDelivery:
            return "The target changed or Secure Keyboard Entry activated during direct typing. Refocus the field and try again."
        case .targetActivationFailed, .noFrontmostTarget:
            return "Click the test field and run the test again."
        case .deliveryUnverified:
            return "Try Clipboard or Direct typing from Paste method, then test again."
        case .writeFailed:
            return "macOS rejected the clipboard write. Try again after clearing clipboard utilities."
        case .none:
            return "The delivery call returned \(report.deliverySucceeded ? "success" : "failure"), but the test field did not receive the marker."
        }
    }

    private var icon: String {
        report.insertedIntoTestField == true ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private var tint: Color {
        report.insertedIntoTestField == true ? .green : .orange
    }
}

struct AppearanceTabView: View {
    @Environment(AppState.self) private var appState

    private static let defaultDictationOrbHue: Double = 0.60

    private var totalWords: Int {
        appState.statsTracker.totalWords
    }

    private var currentLevel: LevelSystem.Level {
        appState.statsTracker.currentLevel
    }

    private var currentLevelIndex: Int {
        LevelSystem.levels.firstIndex(where: { $0.name == currentLevel.name }) ?? 0
    }

    private var nextLevel: LevelSystem.Level? {
        appState.statsTracker.nextLevel
    }

    private var wordsToNextLevel: Int {
        guard let nextLevel else { return 0 }
        return max(0, nextLevel.minWords - totalWords)
    }

    private var selectedOrbLevelIndex: Int? {
        let savedHue = appState.settingsManager.dictationOrbHue
        let tolerance = 0.005
        return LevelSystem.levels.firstIndex { abs($0.hue - savedHue) < tolerance }
    }

    private var isUsingDefaultOrb: Bool {
        abs(appState.settingsManager.dictationOrbHue - Self.defaultDictationOrbHue) < 0.005
    }

    var body: some View {
        @Bindable var settings = appState.settingsManager

        SettingsPage(title: "Appearance") {
            SettingsCardSection("Notch") {
                SettingsToggleRow("Hide notch completely", isOn: $settings.notchHidden)

                if !settings.notchHidden {
                    SettingsRowDivider()
                    SettingsToggleRow("Show notch when idle", isOn: $settings.notchIdleVisible)

                    SettingsRowDivider()
                    SettingsToggleRow(
                        "Show detailed recovery popups",
                        detail: "Issue-style warnings when auto-paste falls back to clipboard.",
                        isOn: $settings.recoverableDictationIssueNoticesEnabled
                    )

                    SettingsRowDivider()
                    SettingsPickerRow(
                        "Active view",
                        detail: "Minimal keeps live dictation in one row. Expanded uses the full panel.",
                        selection: $settings.overlayMode
                    ) {
                        ForEach(OverlayMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                }
            }
            .id(SettingsAnchor.appearanceNotch)

            SettingsCardSection("Notch Orb") {
                AppearanceOrbStyledRow(
                    currentLevel: currentLevel,
                    nextLevel: nextLevel,
                    totalWords: totalWords,
                    levelProgress: appState.statsTracker.levelProgress,
                    wordsToNextLevel: wordsToNextLevel,
                    selectedOrbHue: settings.dictationOrbHue,
                    selectedOrbLevelIndex: selectedOrbLevelIndex,
                    isUsingDefaultOrb: isUsingDefaultOrb,
                    currentLevelIndex: currentLevelIndex,
                    onResetToDefault: {
                        settings.dictationOrbHue = Self.defaultDictationOrbHue
                    },
                    onSelectLevel: { level in
                        settings.dictationOrbHue = level.hue
                    }
                )
            }

            SettingsCardSection("Feedback Sounds") {
                SettingsToggleRow("Enable sounds", isOn: $settings.soundsEnabled)
                if settings.soundsEnabled {
                    SettingsRowDivider()
                    SettingsSliderRow("Volume", value: $settings.soundsVolume, in: 0...1, controlWidth: 260)
                }
            }
            .id(SettingsAnchor.appearanceSound)
        }
    }
}

private struct AppearanceOrbStyledRow: View {
    let currentLevel: LevelSystem.Level
    let nextLevel: LevelSystem.Level?
    let totalWords: Int
    let levelProgress: Double
    let wordsToNextLevel: Int
    let selectedOrbHue: Double
    let selectedOrbLevelIndex: Int?
    let isUsingDefaultOrb: Bool
    let currentLevelIndex: Int
    let onResetToDefault: () -> Void
    let onSelectLevel: (LevelSystem.Level) -> Void

    private var subtitle: String {
        if let nextLevel, wordsToNextLevel > 0 {
            return "\(currentLevel.name) · \(totalWords.formatted()) words · \(wordsToNextLevel.formatted()) to \(nextLevel.name)"
        }
        return "\(currentLevel.name) · \(totalWords.formatted()) words · all orb colors unlocked"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            AppearanceSettingIcon(systemName: "sparkles")

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Notch orb")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.primary)

                        Text(subtitle)
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                    }

                    Spacer(minLength: 18)

                    VStack(alignment: .trailing, spacing: 6) {
                        Text("Level \(currentLevelIndex + 1) of \(LevelSystem.levels.count)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()

                        SettingsLinearProgressBar(value: levelProgress, tint: Color.appearanceHex(currentLevel.color))
                            .frame(width: 150)
                    }
                    .padding(.top, 3)
                }

                AppearanceOrbStrip(
                    selectedOrbLevelIndex: selectedOrbLevelIndex,
                    isUsingDefaultOrb: isUsingDefaultOrb,
                    currentLevelIndex: currentLevelIndex,
                    defaultHue: selectedOrbHue,
                    onResetToDefault: onResetToDefault,
                    onSelectLevel: onSelectLevel
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
    }
}

private struct AppearanceSettingIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 40, height: 40)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(SettingsPalette.elevatedBackground.opacity(0.82))
            )
    }
}

private struct AppearanceOrbStrip: View {
    let selectedOrbLevelIndex: Int?
    let isUsingDefaultOrb: Bool
    let currentLevelIndex: Int
    let defaultHue: Double
    let onResetToDefault: () -> Void
    let onSelectLevel: (LevelSystem.Level) -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 7) {
            AppearanceOrbStripItem(
                hue: defaultHue,
                title: "Default",
                isUnlocked: true,
                isSelected: isUsingDefaultOrb,
                action: onResetToDefault
            )

            ForEach(Array(LevelSystem.levels.enumerated()), id: \.offset) { index, level in
                AppearanceOrbStripItem(
                    hue: level.hue,
                    title: level.name,
                    isUnlocked: index <= currentLevelIndex,
                    isSelected: !isUsingDefaultOrb && index == selectedOrbLevelIndex,
                    action: { onSelectLevel(level) }
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(SettingsPalette.elevatedBackground.opacity(0.46))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(SettingsPalette.border.opacity(0.85), lineWidth: 1)
        )
    }
}

private struct AppearanceOrbStripItem: View {
    let hue: Double
    let title: String
    let isUnlocked: Bool
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: { if isUnlocked { action() } }) {
            VStack(spacing: 7) {
                ZStack(alignment: .bottomTrailing) {
                    AppearanceOrbSwatch(hue: hue, size: 38)
                        .saturation(isUnlocked ? 1 : 0)
                        .opacity(isUnlocked ? 1 : 0.46)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(isSelected ? Color.appearanceHex("#2E2E2E").opacity(0.20) : .clear, lineWidth: 1)
                        )

                    if !isUnlocked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Color.black.opacity(0.66)))
                            .offset(x: 4, y: 4)
                    }
                }
                .help(isUnlocked ? title : "\(title) is locked")

                Circle()
                    .fill(isSelected ? Color.primary.opacity(0.55) : .clear)
                    .frame(width: 6, height: 6)
            }
        }
        .buttonStyle(.plain)
        .disabled(!isUnlocked)
    }
}

private struct AppearanceOrbSwatch: View {
    let hue: Double
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: max(8, size * 0.22), style: .continuous)
            .fill(
                RadialGradient(
                    stops: [
                        .init(color: Color(hue: hue, saturation: 0.22, brightness: 1.0), location: 0),
                        .init(color: Color(hue: hue, saturation: 0.62, brightness: 0.95), location: 0.55),
                        .init(color: Color(hue: wrappedHue(hue + 0.10), saturation: 0.70, brightness: 0.82), location: 1),
                    ],
                    center: UnitPoint(x: 0.34, y: 0.28),
                    startRadius: 0,
                    endRadius: size * 0.58
                )
            )
            .frame(width: size, height: size)
            .overlay(
                RoundedRectangle(cornerRadius: max(8, size * 0.22), style: .continuous)
                    .stroke(.white.opacity(0.35), lineWidth: 1)
            )
            .shadow(color: Color(hue: hue, saturation: 0.56, brightness: 0.82).opacity(0.26), radius: size * 0.16)
    }

    private func wrappedHue(_ h: Double) -> Double {
        let wrapped = h.truncatingRemainder(dividingBy: 1.0)
        return wrapped < 0 ? wrapped + 1.0 : wrapped
    }
}

private extension Color {
    static func appearanceHex(_ hex: String) -> Color {
        let cleaned = hex.trimmingCharacters(in: .init(charactersIn: "#"))
        guard cleaned.count == 6,
              let value = UInt64(cleaned, radix: 16)
        else {
            return .gray
        }

        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b)
    }
}

private struct TranscriptionModelSettingsSection: View {
    @Environment(AppState.self) private var appState
    let anchor: String

    var body: some View {
        SettingsCardSection("Dictation Model") {
            ForEach(Array(appState.modelRegistry.all.enumerated()), id: \.element.id) { index, model in
                if index > 0 {
                    SettingsRowDivider()
                }
                SettingsValueRow(model.displayName, detail: model.description) {
                    HStack(spacing: 8) {
                        if let url = model.modelURL {
                            Button {
                                NSWorkspace.shared.open(url)
                            } label: {
                                Image(systemName: "info.circle")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("View model on Hugging Face")
                            .frame(width: 20)
                        } else {
                            Color.clear.frame(width: 20)
                        }

                        Spacer(minLength: 0)

                    if appState.modelRegistry.active?.id == model.id {
                        if model.isLoaded {
                            SettingsStatusPill(
                                title: "Active",
                                detail: "Ready",
                                systemImage: "checkmark.circle.fill",
                                tint: .green
                            )
                        } else if appState.modelRegistry.isDownloading {
                            VStack(alignment: .trailing, spacing: 4) {
                                ProgressView(value: appState.modelRegistry.downloadProgress)
                                    .frame(width: 120)
                                Text("\(Int((appState.modelRegistry.downloadProgress * 100).rounded()))%")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        } else {
                            Button("Download") {
                                Task {
                                    try? await appState.modelRegistry.prepareActive(source: .settings)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    } else {
                        if model.isDownloaded {
                            SettingsStatusPill(
                                title: "Downloaded",
                                systemImage: "arrow.down.circle.fill"
                            )
                        }
                        Button("Select") {
                            appState.modelRegistry.select(id: model.id)
                        }
                        .controlSize(.small)
                        .disabled(appState.modelRegistry.isDownloading)
                    }
                    }
                }
            }
        }
        .id(anchor)
    }
}

private struct TranscriptionLanguageSettingsSection: View {
    @Environment(AppState.self) private var appState
    let anchor: String

    var body: some View {
	        @Bindable var settings = appState.settingsManager

	        SettingsCardSection("Language") {
	            SettingsPickerRow("Transcription language", selection: $settings.transcriptionLanguage, controlWidth: 260) {
	                Text("Auto-detect").tag("auto")
	                Divider()
	                Text("English").tag("en")
	                Text("Swedish").tag("sv")
	                Text("Italian").tag("it")
	                Text("French").tag("fr")
	                Text("German").tag("de")
	                Text("Spanish").tag("es")
	                Text("Portuguese").tag("pt")
	                Text("Dutch").tag("nl")
	                Text("Danish").tag("da")
	                Text("Finnish").tag("fi")
	                Text("Polish").tag("pl")
	                Text("Czech").tag("cs")
	                Text("Greek").tag("el")
	                Text("Hungarian").tag("hu")
	                Text("Romanian").tag("ro")
	                Text("Turkish").tag("tr")
	                Text("Russian").tag("ru")
	                Text("Arabic").tag("ar")
	                Text("Hindi").tag("hi")
	                Text("Japanese").tag("ja")
	                Text("Korean").tag("ko")
	                Text("Chinese").tag("zh")
	                Text("Thai").tag("th")
	                Text("Vietnamese").tag("vi")
	                Text("Indonesian").tag("id")
	                Text("Malay").tag("ms")
	                Text("Filipino").tag("fil")
	                Text("Persian").tag("fa")
	                Text("Macedonian").tag("mk")
	                Text("Cantonese").tag("yue")
	            }

            SettingsRowDivider()
            SettingsSectionBody {
                LanguageSupportRow(
                    language: settings.transcriptionLanguage,
                    models: appState.modelRegistry.all,
                    activeId: appState.modelRegistry.active?.id
                )
            }

            if let activeId = appState.modelRegistry.active?.id {
                let language = settings.transcriptionLanguage
                if activeId == "parakeet-tdt-0.6b-v3",
                   language != "auto",
                   FluidAudioLanguageHint.map(language) == nil {
                    SettingsRowDivider()
                    SettingsSectionBody {
                        Text("Parakeet v3's script-aware filter doesn't cover this language; output may mix scripts. Switch to Qwen3 ASR or Cohere Transcribe for full coverage.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } else if activeId == "cohere-transcribe-q8",
                          language == "auto" {
                    SettingsRowDivider()
                    SettingsSectionBody {
                        Text("Cohere Transcribe needs an explicit language; auto-detect falls back to English.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .id(anchor)
    }
}

private struct LanguageSupportRow: View {
    let language: String
    let models: [any Transcriber]
    let activeId: String?

    private func isSupported(_ model: any Transcriber) -> Bool {
        if language == "auto" {
            return model.supportsAutoLanguageDetection
        }
        return model.supportedLanguageCodes.contains(language)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(language == "auto" ? "Auto-detect" : "Supports this language")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            HStack(spacing: 6) {
                ForEach(models, id: \.id) { model in
                    ModelSupportPill(
                        name: model.displayName,
                        isSupported: isSupported(model),
                        isActive: activeId == model.id
                    )
                }
            }
        }
    }
}

private struct ModelSupportPill: View {
    let name: String
    let isSupported: Bool
    let isActive: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: isSupported ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isSupported ? .green : .secondary)
            Text(name)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isSupported ? .primary : .secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(isActive ? SettingsPalette.accentFill : SettingsPalette.elevatedBackground)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(isActive ? SettingsPalette.accent : SettingsPalette.border, lineWidth: 1)
        )
        .opacity(isSupported ? 1.0 : 0.55)
    }
}

struct ModelsLanguageTabView: View {
    var body: some View {
        SettingsPage(title: "Models & Language") {
            TranscriptionModelSettingsSection(anchor: SettingsAnchor.advancedModel)
            TranscriptionLanguageSettingsSection(anchor: SettingsAnchor.advancedLanguage)
        }
    }
}

struct AdvancedTabView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var settings = appState.settingsManager

        SettingsPage(title: "Advanced") {
                SettingsCardSection("Dictation") {
                    SettingsDrillInRow(
                        title: "Models & Language",
                        detail: "Choose the speech model or pin a transcription language.",
                        value: appState.modelRegistry.active?.displayName,
                        systemImage: SettingsTab.models.icon
                    ) {
                        appState.selectedSettingsTab = .models
                        appState.settingsScrollAnchor = SettingsAnchor.advancedModel
                    }

                    SettingsRowDivider()
                    SettingsToggleRow(
                        "Hot mic",
                        detail: "Always listen for a spoken phrase that pastes everything transcribed so far.",
                        isOn: $settings.hotMicEnabled
                    )
	                    if settings.hotMicEnabled {
	                        SettingsRowDivider()
	                        SettingsTextFieldRow(
	                            "Hot word",
	                            placeholder: "e.g. paste it",
	                            text: $settings.hotWord,
	                            controlWidth: 240
	                        ) {
	                            Task {
	                                await appState.stopHotMic()
	                                await appState.startHotMic()
	                            }
	                        }
	                    }

                    SettingsRowDivider()
                    SettingsToggleRow(
                        "Pause media while recording",
                        detail: "Pauses Music, Spotify, and supported browser videos when you start recording.",
                        isOn: $settings.pauseMediaWhileRecording
                    )

                    SettingsRowDivider()
                    SettingsToggleRow(
                        "Lower system volume while recording",
                        detail: "Quiets other audio during dictation or memos so your voice comes through cleaner.",
                        isOn: $settings.duckSystemAudioWhileRecording
                    )

                    SettingsRowDivider()
                    SettingsToggleRow(
                        "Instant-on microphone",
                        detail: "Keeps the mic ready in the background so dictation starts the moment you press the key. Uses a little more battery, and skips cloud cleanup and vocabulary boost to stay fast.",
                        isOn: $settings.lowLatencyMode
                    )

                    SettingsRowDivider()
                    SettingsToggleRow(
                        "Live transcript while dictating",
                        detail: "Shows your words in the notch as you speak. The pasted text still comes from the full-quality pass at the end.",
                        isOn: $settings.liveTranscriptPreviewEnabled
                    )
	                }

                SettingsCardSection("Writing Aids") {
                    SettingsDrillInRow(
                        title: "Dictionary",
                        detail: "Correct names, terms, and words Resonant mishears.",
                        value: "\(appState.dictionaryStore.allWords.count)",
                        systemImage: SettingsTab.dictionary.icon
                    ) {
                        appState.pendingSettingsBackTarget = .advanced
                        appState.selectedSettingsTab = .dictionary
                    }

                    SettingsRowDivider()
                    SettingsDrillInRow(
                        title: "Smart Links",
                        detail: "Replace spoken phrases with links.",
                        value: "\(appState.smartLinkStore.links.count)",
                        systemImage: SettingsTab.smartLinks.icon
                    ) {
                        appState.pendingSettingsBackTarget = .advanced
                        appState.selectedSettingsTab = .smartLinks
                    }
                }

                SettingsCardSection("Integrations") {
                    SettingsDrillInRow(
                        title: "Local API",
                        detail: "Expose local workspace tools for scripts and automations.",
                        value: settings.localAPIEnabled ? "On" : "Off",
                        systemImage: SettingsTab.apiCli.icon
                    ) {
                        appState.selectedSettingsTab = .apiCli
                    }

                    SettingsRowDivider()
                    SettingsDrillInRow(
                        title: "MCP Server",
                        detail: "Connect Resonant memory to Claude, Cursor, or other MCP clients.",
                        value: settings.mcpServerEnabled ? "On" : "Off",
                        systemImage: SettingsTab.mcpServer.icon
                    ) {
                        appState.selectedSettingsTab = .mcpServer
                    }
                }

                #if DEBUG
                if SettingsTab.dispatchDebug.isAvailable {
                    SettingsCardSection("Developer") {
                        SettingsDrillInRow(
                            title: "Dispatch Debug",
                            detail: "Inspect recent command routing and learned bindings.",
                            value: nil,
                            systemImage: SettingsTab.dispatchDebug.icon
                        ) {
                            appState.selectedSettingsTab = .dispatchDebug
                        }
                    }
                }
                #endif
        }
    }
}

struct AccountTabView: View {
    @Environment(AppState.self) private var appState

    private var analyticsBinding: Binding<Bool> {
        Binding(
            get: { appState.settingsManager.analyticsEnabled },
            set: { appState.setAnalyticsEnabled($0) }
        )
    }

    private var crashDiagnosticsBinding: Binding<Bool> {
        Binding(
            get: { appState.settingsManager.crashDiagnosticsEnabled },
            set: { appState.setCrashDiagnosticsEnabled($0) }
        )
    }

    private var betaTesterBinding: Binding<Bool> {
        Binding(
            get: { appState.settingsManager.betaTesterEnabled },
            set: { appState.setBetaTesterEnabled($0) }
        )
    }

    var body: some View {
        @Bindable var settings = appState.settingsManager

        SettingsPage(title: "General") {
            if AppFeatureVisibility.hostedServices,
               let sessionExpiredMessage = appState.authManager.sessionExpiredMessage {
                SettingsCardSection("Account") {
                    SettingsSectionBody {
                        Text(sessionExpiredMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            if AppFeatureVisibility.hostedServices {
                accountSection()
                    .id(SettingsAnchor.accountIdentity)
            }
            generalSection(launchAtLogin: $settings.launchAtLogin)
                .id(SettingsAnchor.accountGeneral)
            if analyticsRuntimeConfigured {
                betaSection(betaTesterEnabled: betaTesterBinding)
                    .id(SettingsAnchor.accountBeta)
            }
            gettingStartedSection()
                .id(SettingsAnchor.accountOnboarding)
            if diagnosticsRuntimeConfigured {
                diagnosticsSection(
                    crashDiagnosticsEnabled: crashDiagnosticsBinding,
                    analyticsEnabled: analyticsBinding
                )
                .id(SettingsAnchor.accountDiagnostics)
            }

            if AppFeatureVisibility.hostedServices, appState.authManager.isLoggedIn {
                signOutSection()
                    .id(SettingsAnchor.accountSignOut)
            }
        }
    }

    private var analyticsRuntimeConfigured: Bool {
        AnalyticsRuntimeConfiguration.from(infoDictionary: Bundle.main.infoDictionary) != nil
    }

    private var diagnosticsRuntimeConfigured: Bool {
        analyticsRuntimeConfigured
            || SentryRuntimeConfiguration.from(infoDictionary: Bundle.main.infoDictionary) != nil
    }

    @ViewBuilder
    private func accountSection() -> some View {
        if appState.authManager.isLoggedIn {
            SettingsCardSection("Account") {
                SettingsValueRow("Email") {
                    Text(appState.authManager.userEmail ?? "")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        } else {
            SettingsCardSection("Account", footer: "Sign in to use cloud features like cleanup, summaries, and selection transform.") {
                SettingsSectionBody {
                    HStack {
                        Spacer(minLength: 0)
                        Button("Sign in") {
                            appState.initiateLogin(source: "account_tab_existing")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }

    private func generalSection(launchAtLogin: Binding<Bool>) -> some View {
        SettingsCardSection("General", footer: "Start Resonant automatically when you sign in to your Mac.") {
            SettingsToggleRow("Launch at login", isOn: launchAtLogin)
        }
    }

    private func gettingStartedSection() -> some View {
        SettingsCardSection("Getting Started", footer: "Walk through permissions, setup, and the initial product tour again.") {
            SettingsSectionBody {
                Button("Reopen Onboarding") {
                    appState.reopenOnboarding()
                }
            }
        }
    }

    // Beta program opt-in. Toggling this sets the `beta_tester` person property
    // on PostHog via AnalyticsManager.setBetaTesterEnabled(), which makes the user
    // match the "Beta Testers" cohort. Feature flags targeting that cohort then
    // evaluate to true, gating beta-only features throughout the app.
    private func betaSection(betaTesterEnabled: Binding<Bool>) -> some View {
        SettingsCardSection("Beta", footer: "Get early access to new features before they're released. Beta features may be less stable.") {
            SettingsToggleRow("Join the beta program", isOn: betaTesterEnabled)
        }
    }

    private func diagnosticsSection(
        crashDiagnosticsEnabled: Binding<Bool>,
        analyticsEnabled: Binding<Bool>
    ) -> some View {
        SettingsCardSection("Diagnostics", footer: "Crash diagnostics send sanitized crash and error reports to Sentry. Product analytics send usage events to PostHog.") {
            SettingsToggleRow("Share crash diagnostics", isOn: crashDiagnosticsEnabled)
            SettingsRowDivider()
            SettingsToggleRow("Share product analytics", isOn: analyticsEnabled)
        }
    }

    private func signOutSection() -> some View {
        SettingsCardSection("Sign Out") {
            SettingsSectionBody {
                HStack {
                    Spacer(minLength: 0)
                    Button("Sign Out", role: .destructive) {
                        Task {
                            await appState.signOut()
                        }
                    }
                }
            }
        }
    }

}

private enum BugSeverity: String, CaseIterable, Identifiable {
    case annoying   = "annoying"
    case shouldFix  = "should-fix"
    case cantWork   = "cant-work"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .annoying:  "Annoying"
        case .shouldFix: "Should fix"
        case .cantWork:  "Can't work"
        }
    }

    var description: String {
        switch self {
        case .annoying:  "Minor issue, I can work around it"
        case .shouldFix: "It gets in my way regularly"
        case .cantWork:  "This blocks me from using Resonant"
        }
    }
}

struct SupportTabView: View {
    @Environment(AppState.self) private var appState

    @State private var bugSeverity: BugSeverity?
    @State private var bugDescription = ""
    @State private var bugSubmitted = false
    @State private var isSubmittingBug = false
    @State private var showSeverityError = false
    @State private var bugSubmissionError: String?

    private var canSubmitBug: Bool {
        bugSeverity != nil
            && !bugDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isSubmittingBug
    }

    var body: some View {
        SettingsPage(title: "Help & Support") {
            if AppRuntime.hasHostedServices {
                SettingsCardSection("Report a Bug") {
                if bugSubmitted {
                    SettingsSectionBody {
                        Label("Thanks. We got your report.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                } else {
                    SettingsPickerRow(
                        "Severity",
                        detail: "Choose the closest impact so the report is routed correctly.",
                        selection: $bugSeverity,
                        controlWidth: 240
                    ) {
                        Text("Select\u{2026}").tag(nil as BugSeverity?)
                        ForEach(BugSeverity.allCases) { severity in
                            Text(severity.label).tag(severity as BugSeverity?)
                        }
                    }
                    .foregroundStyle(showSeverityError ? .red : .primary)
                    .onChange(of: bugSeverity) { _, newValue in
                        if newValue != nil { showSeverityError = false }
                    }

                    SettingsRowDivider()
                    SettingsTextEditorRow(
                        title: "What happened?",
                        detail: "Include your email address if you'd like a response.",
                        placeholder: "Describe the issue",
                        text: $bugDescription,
                        minHeight: 86
                    )

                    SettingsRowDivider()
                    SettingsSectionBody {
	                        HStack {
	                            Spacer()
	                            Button {
	                                if bugSeverity == nil {
	                                    showSeverityError = true
	                                } else {
	                                    submitBugReport()
	                                }
	                            } label: {
	                                Label("Send Report", systemImage: "arrow.right")
	                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(bugDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmittingBug)
                        }
                    }

                    if let bugSubmissionError {
                        SettingsRowDivider()
                        SettingsSectionBody {
                            Text(bugSubmissionError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
                }
            } else {
                SettingsCardSection("Report a Bug") {
                    SettingsSectionBody {
                        Text("This build has no configured support relay. Report issues through the repository that supplied your build. Review the report before posting and do not attach recordings, transcripts, API keys, or other private data.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            SettingsCardSection("Paste Reliability") {
                PasteReliabilitySettingsView()
            }

            if AppRuntime.distributionFlavor == .official {
                SettingsCardSection("Connect") {
                    SettingsSectionBody {
                        ConnectGrid(appState: appState)
                    }
                }
            }

            SettingsCardSection("About") {
                SettingsValueRow("Version") {
                    Text(AppRuntime.appVersion)
                        .foregroundStyle(.secondary)
                }
                if let noticeURL = Bundle.main.url(forResource: "NOTICE", withExtension: nil) {
                    SettingsRowDivider()
                    SettingsValueRow("Licenses", detail: "Source, dependency, and model notices bundled with this build.") {
                        Button("Open") {
                            NSWorkspace.shared.open(noticeURL)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
        .onAppear {
            appState.analyticsManager.capture("support_tab_viewed")
        }
    }

    // MARK: - Bug report submission

    private func submitBugReport() {
        guard let severity = bugSeverity, canSubmitBug else { return }
        isSubmittingBug = true
        bugSubmissionError = nil
        let description = bugDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let reportID = UUID().uuidString.lowercased()
        let analyticsProperties: [String: Any] = [
            "report_id": reportID,
            "severity": severity.rawValue,
            "description_length": description.count,
            "description_line_count": max(1, description.split(separator: "\n", omittingEmptySubsequences: false).count),
        ]

        Task { @MainActor in
            let result = await TelegramReporter.shared.sendBugReport(
                severity: severity.rawValue,
                description: description,
                reportID: reportID
            )

            guard result.delivered else {
                var failureProperties = analyticsProperties
                failureProperties["attempts"] = result.attempts
                if let route = result.route {
                    failureProperties["delivery_route"] = route
                }
                if let failureReason = result.failureReason?.rawValue {
                    failureProperties["failure_reason"] = failureReason
                }
                if let statusCode = result.statusCode {
                    failureProperties["status_code"] = statusCode
                }
                appState.analyticsManager.capture("support_bug_report_failed", properties: failureProperties)
                bugSubmissionError = "Could not send the report. Check your connection and try again."
                isSubmittingBug = false
                return
            }

            var submittedProperties = analyticsProperties
            submittedProperties["attempts"] = result.attempts
            if let route = result.route {
                submittedProperties["delivery_route"] = route
            }
            appState.analyticsManager.capture("support_bug_report_submitted", properties: submittedProperties)
            bugSubmitted = true
            try? await Task.sleep(for: .seconds(3))
            bugSeverity = nil
            bugDescription = ""
            bugSubmitted = false
            isSubmittingBug = false
        }
    }
}

// MARK: - Connect grid

private struct ConnectItem: Identifiable {
    let id: String
    let label: String
    let sublabel: String
    let icon: String
    let kind: String
    let url: String
}

private let connectItems: [ConnectItem] = [
    .init(id: "email",     label: "Email",       sublabel: "team@onresonant.com",  icon: "envelope.fill",                     kind: "email",     url: "mailto:team@onresonant.com"),
    .init(id: "community", label: "Discord",     sublabel: "Community & support",  icon: "bubble.left.and.bubble.right.fill", kind: "community", url: "https://discord.gg/fC7KkyzsZw"),
    .init(id: "website",   label: "Website",     sublabel: "onresonant.com",       icon: "globe",                             kind: "website",   url: "https://onresonant.com"),
    .init(id: "twitter",   label: "X / Twitter", sublabel: "@onresonant",          icon: "link",                              kind: "twitter",   url: "https://x.com/onresonant"),
]

private struct ConnectGrid: View {
    let appState: AppState
    @State private var hoveredId: String?

    private let columns = [
        GridItem(.adaptive(minimum: 132), spacing: 10)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(connectItems) { item in
                ConnectCard(item: item, isHovered: hoveredId == item.id)
                    .onTapGesture {
                        appState.openSupportURL(kind: item.kind, value: item.url)
                    }
                    .onHover { over in hoveredId = over ? item.id : nil }
                }
        }
    }
}

private struct ConnectCard: View {
    let item: ConnectItem
    let isHovered: Bool

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(isHovered ? SettingsPalette.accentFill : SettingsPalette.mutedCardBackground)
                    .overlay(
                        Circle()
                            .strokeBorder(isHovered ? SettingsPalette.accentBorder : SettingsPalette.border, lineWidth: 1)
                    )
                    .frame(width: 34, height: 34)

                Image(systemName: item.icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isHovered ? Color.accentColor : .secondary)
            }

            VStack(spacing: 2) {
                Text(item.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)

                Text(item.sublabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isHovered ? SettingsPalette.accentFill.opacity(0.5) : .clear)
        )
        .contentShape(Rectangle())
    }
}

// MARK: - Journal Intro Modal

private struct JournalIntroModal: View {
    @Binding var isPresented: Bool
    @State private var revealed = false

    private let accentBlue = SettingsPalette.semanticBlue

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(alignment: .leading, spacing: 0) {
                header
                Divider().opacity(0.5)
                content
            }
            .frame(width: 380)
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
            HStack(spacing: 6) {
                Image(systemName: "book.pages")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(accentBlue)
                Text("How the Journal Works")
                    .font(.system(size: 14, weight: .semibold))
            }

            Spacer()

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(SettingsPalette.elevatedBackground))
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(SettingsPalette.elevatedBackground.opacity(0.6))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            JournalIntroStep(
                number: 1,
                title: "Automatic work log",
                description: "The journal captures what you dictate throughout the day, grouped by app and context window."
            )

            JournalIntroStep(
                number: 2,
                title: "AI-powered summaries",
                description: "Each session and day gets a concise summary so you can review your work at a glance."
            )

            JournalIntroStep(
                number: 3,
                title: "Browse by date",
                description: "Navigate between days to see your history. Entries are organized into blocks you can expand for detail."
            )

            Button { dismiss() } label: {
                Text("Got it")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(accentBlue)
                    )
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
        .padding(20)
    }

    private func dismiss() {
        isPresented = false
        revealed = false
    }
}

private struct JournalIntroStep: View {
    private static let accent = SettingsPalette.semanticBlue

    let number: Int
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Self.accent))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                if !description.isEmpty {
                    Text(description)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
