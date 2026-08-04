import SwiftUI

/// Sidebar search field for the Settings page. Filters `SettingsSearchIndex`
/// and shows a results popover; selecting a result navigates to the matching
/// tab and (if applicable) sets `appState.settingsScrollAnchor` so the tab
/// view can scroll to the right section.
struct SettingsSearchField: View {
    @Environment(AppState.self) private var appState
    @Binding var selected: SettingsTab?

    @State private var query: String = ""
    @State private var isFocused: Bool = false
    @State private var highlightedIndex: Int = 0
    @FocusState private var fieldFocus: Bool

    private var results: [SettingsSearchEntry] {
        SettingsSearchIndex.search(query)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            inputField
                .popover(
                    isPresented: Binding(
                        get: { fieldFocus && !results.isEmpty },
                        set: { newValue in
                            if !newValue { fieldFocus = false }
                        }
                    ),
                    attachmentAnchor: .rect(.bounds),
                    arrowEdge: .top
                ) {
                    resultsList
                        .frame(width: 280)
                }
        }
        .onChange(of: query) { _, _ in
            highlightedIndex = 0
        }
    }

    private var inputField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)

            TextField("Search settings", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($fieldFocus)
                .onSubmit { commitHighlightedResult() }
                .onKeyPress(.upArrow) {
                    moveHighlight(by: -1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    moveHighlight(by: 1)
                    return .handled
                }
                .onKeyPress(.escape) {
                    if !query.isEmpty {
                        query = ""
                        return .handled
                    }
                    fieldFocus = false
                    return .handled
                }

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(SettingsPalette.elevatedBackground.opacity(fieldFocus ? 0.7 : 0.35))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(SettingsPalette.border.opacity(fieldFocus ? 0.25 : 0.12), lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private var resultsList: some View {
        let items = results
        VStack(alignment: .leading, spacing: 0) {
            if items.isEmpty {
                Text("No matches")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { idx, entry in
                                SettingsSearchResultRow(
                                    entry: entry,
                                    isHighlighted: idx == highlightedIndex
                                ) {
                                    select(entry)
                                }
                                .id(idx)
                                .onHover { hovering in
                                    if hovering { highlightedIndex = idx }
                                }
                            }
                        }
                        .padding(4)
                    }
                    .frame(maxHeight: 320)
                    .onChange(of: highlightedIndex) { _, newValue in
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
        }
    }

    private func moveHighlight(by delta: Int) {
        let count = results.count
        guard count > 0 else { return }
        highlightedIndex = (highlightedIndex + delta + count) % count
    }

    private func commitHighlightedResult() {
        guard !results.isEmpty else { return }
        let safeIndex = max(0, min(highlightedIndex, results.count - 1))
        select(results[safeIndex])
    }

    private func select(_ entry: SettingsSearchEntry) {
        selected = entry.tab
        if let parent = entry.tab.parentSettingsTab {
            appState.pendingSettingsBackTarget = parent
        }
        appState.selectedSettingsTab = entry.tab
        appState.settingsScrollAnchor = entry.anchor
        appState.trackSettingsTabViewed(entry.tab)
        query = ""
        fieldFocus = false
    }
}

private struct SettingsSearchResultRow: View {
    let entry: SettingsSearchEntry
    let isHighlighted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: entry.icon)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(isHighlighted ? AnyShapeStyle(SettingsPalette.infoText) : AnyShapeStyle(HierarchicalShapeStyle.secondary))

                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if !entry.isPage {
                        Text(entry.pageLabel)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                if entry.isPage {
                    Text("Page")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(SettingsPalette.elevatedBackground.opacity(0.7))
                        )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHighlighted ? SettingsPalette.accentFill : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
