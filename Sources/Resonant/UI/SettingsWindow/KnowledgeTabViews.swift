import AppKit
import SwiftUI

// MARK: - Dictionary Tab

struct DictionaryTabView: View {
    @Environment(AppState.self) private var appState
    @State private var showIntroModal = false
    @State private var searchText = ""
    @State private var contactImportStatus: String?
    @State private var isImportingContacts = false

    private var corrections: [DictionaryWord] {
        // Surface recently auto-learned words first, then fall back to the
        // store's alphabetical ordering for everything else.
        appState.dictionaryStore.allWords.sorted { lhs, rhs in
            if lhs.isAutoLearned != rhs.isAutoLearned {
                return lhs.isAutoLearned
            }
            if lhs.isAutoLearned {
                return lhs.lastSeenAt > rhs.lastSeenAt
            }
            return lhs.spoken.localizedCaseInsensitiveCompare(rhs.spoken) == .orderedAscending
        }
    }

    private var filteredCorrections: [DictionaryWord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return corrections }
        return corrections.filter { word in
            word.spoken.localizedCaseInsensitiveContains(query)
                || word.written.localizedCaseInsensitiveContains(query)
        }
    }

    private var isFiltering: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var correctionCountLabel: String {
        corrections.count == 1 ? "1 correction" : "\(corrections.count) corrections"
    }

    private var vocabularyBoostState: VocabularyBoostRuntimeState {
        appState.vocabularyBoostRuntimeState
    }

    private var vocabularyBoostDetail: String {
        vocabularyBoostState.detail(
            eligibleTermCount: appState.vocabularyBoostEligibleTermCount
        )
    }

    private var vocabularyBoostStatus: (
        title: String,
        systemImage: String,
        tint: Color
    ) {
        switch vocabularyBoostState.applicability {
        case .off:
            return ("Off", "circle", .secondary)
        case .unsupportedModel:
            return ("Unsupported", "exclamationmark.triangle.fill", .orange)
        case .lowLatencyPaused:
            return ("Paused", "pause.circle.fill", .orange)
        case .automaticConditional:
            return ("Auto conditional", "globe", .blue)
        case .unsupportedLanguage:
            return ("English only", "globe", .orange)
        case .noEligibleTerms:
            return ("Needs words", "text.badge.plus", .secondary)
        case .eligible:
            return ("Eligible", "checkmark.circle.fill", .green)
        }
    }

    private var vocabularyBoostHelperStatus: (
        title: String,
        systemImage: String,
        tint: Color
    ) {
        switch vocabularyBoostState.helper {
        case .absent:
            return ("Helper absent", "arrow.down.circle", .orange)
        case .downloading:
            return ("Downloading 98 MB", "arrow.down.circle", .blue)
        case .ready:
            return ("Helper ready", "checkmark.circle.fill", .green)
        case .failed:
            return ("Download failed", "exclamationmark.circle.fill", .red)
        }
    }

    private var contactImportDetail: String {
        if let contactImportStatus {
            return contactImportStatus
        }
        let store = appState.contactNameStore
        if store.hasImported {
            return "\(store.importedNames.count) names stay on this Mac and improve recognition when boosting is on."
        }
        return "Import names so dictation recognizes the people you talk about. Names stay on this Mac."
    }

    private func importContactNames() {
        isImportingContacts = true
        contactImportStatus = nil
        Task { @MainActor in
            defer { isImportingContacts = false }
            do {
                let count = try await appState.contactNameStore.importFromSystemContacts()
                contactImportStatus = "Imported \(count) names."
            } catch {
                contactImportStatus = error.localizedDescription
            }
        }
    }

    var body: some View {
        @Bindable var settings = appState.settingsManager
        SettingsPage(title: "Dictionary") {
            if let backTarget = appState.settingsBackTarget {
                SettingsBackLink(target: backTarget) {
                    appState.selectedSettingsTab = backTarget
                }
            }

            SettingsCardSection(
                "Search",
                headerAccessory: { HelpIconButton { showIntroModal = true } }
            ) {
                SettingsValueRow("Find corrections", detail: correctionCountLabel) {
                    TextField("Search corrections", text: $searchText)
                        .consumerTextField(width: 320)
                }
            }

            SettingsCardSection("Recognition") {
                SettingsToggleRow(
                    "Boost my words during recognition",
                    isOn: $settings.vocabularyBoostEnabled
                )
                .onChange(of: settings.vocabularyBoostEnabled) { _, _ in
                    appState.reconcileVocabularyBoostHelperEligibility()
                }

                SettingsRowDivider()
                SettingsValueRow(
                    "Vocabulary recognition",
                    detail: vocabularyBoostDetail
                ) {
                    HStack(spacing: 8) {
                        SettingsStatusPill(
                            title: vocabularyBoostStatus.title,
                            systemImage: vocabularyBoostStatus.systemImage,
                            tint: vocabularyBoostStatus.tint
                        )

                        SettingsStatusPill(
                            title: vocabularyBoostHelperStatus.title,
                            systemImage: vocabularyBoostHelperStatus.systemImage,
                            tint: vocabularyBoostHelperStatus.tint
                        )

                        switch vocabularyBoostState.helper.recoveryAction {
                        case .download:
                            Button("Download 98 MB") {
                                appState.downloadVocabularyBoostModelManually()
                            }
                            .buttonStyle(.borderedProminent)
                        case .retry:
                            Button("Retry Download") {
                                appState.retryVocabularyBoostModelDownload()
                            }
                            .buttonStyle(.borderedProminent)
                        case nil:
                            EmptyView()
                        }
                    }
                }

                SettingsRowDivider()
                SettingsValueRow(
                    "Names from Contacts",
                    detail: contactImportDetail
                ) {
                    Button(isImportingContacts
                        ? "Importing…"
                        : (appState.contactNameStore.hasImported ? "Re-import" : "Import")) {
                        importContactNames()
                    }
                    .disabled(isImportingContacts)
                }
            }

            SettingsCardSection(
                "Add a correction",
                footer: "Automatically replace words that Resonant mishears with what you actually meant."
            ) {
                DictionaryAddCard()
            }

            if !corrections.isEmpty {
                SettingsCardSection(isFiltering ? "Filtered Corrections" : "Corrections") {
                    if filteredCorrections.isEmpty {
                        SettingsSectionBody {
                            ContentUnavailableView(
                                "No matching corrections",
                                systemImage: "magnifyingglass",
                                description: Text("Try a different word or phrase.")
                            )
                            .frame(maxWidth: .infinity, minHeight: 140)
                        }
                    } else {
                        ForEach(filteredCorrections) { word in
                            DictionaryRowView(word: word)
                        }
                    }
                }
            } else {
                SettingsCardSection("Corrections") {
                    SettingsSectionBody {
                    ContentUnavailableView(
                        "No corrections yet",
                        systemImage: "character.book.closed",
                        description: Text("Add what Resonant hears and what you actually meant above.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 160)
                    }
                }
            }
        }
        .overlay {
            Group {
                if showIntroModal {
                    DictionaryIntroModal(isPresented: $showIntroModal)
                        .transition(.opacity)
                }
            }
            .allowsHitTesting(showIntroModal)
        }
        .onAppear {
            if !appState.settingsManager.dictionaryIntroSeen {
                appState.settingsManager.dictionaryIntroSeen = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    showIntroModal = true
                }
            }
        }
    }
}

// MARK: - Dictionary Row

private struct DictionaryRowView: View {
    @Environment(AppState.self) private var appState
    let word: DictionaryWord

    @State private var isHovered = false
    @State private var isEditing = false
    @State private var editSpoken = ""
    @State private var editWritten = ""
    @FocusState private var editFocus: EditField?

    private enum EditField { case spoken, written }

    var body: some View {
        HStack(spacing: 12) {
            if isEditing {
                HStack(spacing: 8) {
                    TextField("Resonant heard", text: $editSpoken)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, weight: .semibold))
                        .focused($editFocus, equals: .spoken)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color(nsColor: .textBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(SettingsPalette.accent.opacity(0.45), lineWidth: 1)
                        )
                        .onSubmit { editFocus = .written }

                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)

                    TextField("I meant", text: $editWritten)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .focused($editFocus, equals: .written)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color(nsColor: .textBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(SettingsPalette.accent.opacity(0.45), lineWidth: 1)
                        )
                        .onSubmit(commitEdit)
                }

                HStack(spacing: 4) {
                    FeedQuickActionButton(
                        title: "Save",
                        systemImage: "checkmark",
                        action: commitEdit
                    )
                    FeedQuickActionButton(
                        title: "Cancel",
                        systemImage: "xmark",
                        action: cancelEdit
                    )
                }
            } else {
                HStack(spacing: 10) {
                    Text(word.spoken)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(SettingsPalette.elevatedBackground)
                        )
                        .overlay(
                            Capsule()
                                .stroke(SettingsPalette.border.opacity(0.3), lineWidth: 1)
                        )

                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.quaternary)

                    Text(word.written)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if word.isAutoLearned {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(SettingsPalette.accent)
                            .help("Learned automatically from your corrections")
                    }

                    Spacer(minLength: 4)

                    HStack(spacing: 4) {
                        FeedQuickActionButton(
                            title: "Edit",
                            systemImage: "pencil",
                            action: startEditing
                        )
                        FeedQuickActionButton(
                            title: "Delete",
                            systemImage: "trash",
                            isDestructive: true,
                            action: {
                                Task {
                                    appState.dictionaryStore.remove(spoken: word.spoken)
                                }
                            }
                        )
                    }
                    .opacity(isHovered ? 1 : 0.82)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isEditing ? SettingsPalette.accentFill.opacity(0.5) : (isHovered ? SettingsPalette.accentFill : .clear))
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture(count: 2) { startEditing() }
        .contextMenu {
            Button("Edit") { startEditing() }
            Button("Delete", role: .destructive) {
                Task {
                    appState.dictionaryStore.remove(spoken: word.spoken)
                }
            }
        }
    }

    private func startEditing() {
        editSpoken = word.spoken
        editWritten = word.written
        isEditing = true
        editFocus = .spoken
    }

    private func commitEdit() {
        let spoken = editSpoken.trimmingCharacters(in: .whitespacesAndNewlines)
        let written = editWritten.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty, !written.isEmpty else { return cancelEdit() }

        isEditing = false

        Task {
            appState.dictionaryStore.update(
                oldSpoken: word.spoken,
                spoken: spoken,
                written: written
            )
        }
    }

    private func cancelEdit() {
        isEditing = false
    }
}

// MARK: - Dictionary Add Card

private struct DictionaryAddCard: View {
    @Environment(AppState.self) private var appState

    @State private var newSpoken = ""
    @State private var newWritten = ""
    @FocusState private var focusedField: Field?

    private enum Field { case spoken, written }

    private var canAdd: Bool {
        !newSpoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !newWritten.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        SettingsSectionBody {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("RESONANT HEARD")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    TextField("e.g. react", text: $newSpoken)
                        .consumerTextField(width: 240)
                        .focused($focusedField, equals: .spoken)
                        .onSubmit { focusedField = .written }
                }

                Image(systemName: "arrow.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 18)

                VStack(alignment: .leading, spacing: 6) {
                    Text("I MEANT")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    TextField("e.g. React", text: $newWritten)
                        .consumerTextField(width: 240)
                        .focused($focusedField, equals: .written)
                        .onSubmit { if canAdd { addCorrection() } }
                }

                Spacer(minLength: 0)

                ConsumerPrimaryButton("Add correction", systemImage: "plus", action: addCorrection)
                    .disabled(!canAdd)
                    .padding(.top, 18)
            }
        }
    }

    private func addCorrection() {
        let spoken = newSpoken.trimmingCharacters(in: .whitespacesAndNewlines)
        let written = newWritten.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty, !written.isEmpty else { return }
        newSpoken = ""
        newWritten = ""
        Task {
            appState.dictionaryStore.add(spoken: spoken, written: written)
        }
    }
}

// MARK: - Dictionary Intro Modal

private struct DictionaryIntroModal: View {
    @Binding var isPresented: Bool

    private let accent = SettingsPalette.semanticBlue

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
                Image(systemName: "character.book.closed")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(accent)
                Text("How the Dictionary Works")
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
            .pointingHandCursor()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(SettingsPalette.elevatedBackground.opacity(0.6))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            DictionaryIntroStep(
                number: 1,
                title: "Add a correction",
                description: "Enter the word Resonant mishears and what you actually meant."
            )

            DictionaryIntroStep(
                number: 2,
                title: "Dictate naturally",
                description: "Whenever the misheard word appears in your dictation, it gets swapped automatically."
            )

            correctionPreview

            Button { dismiss() } label: {
                Text("Got it")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(accent)
                    )
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
        }
        .padding(20)
    }

    private var correctionPreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            DictionaryIntroStep(
                number: 3,
                title: "Example",
                description: ""
            )

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    Text("Before")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .frame(width: 44, alignment: .leading)

                    Text("I'll check the ")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("react")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.red.opacity(0.7))
                        .strikethrough()
                }
                .padding(.bottom, 10)

                HStack {
                    Spacer()
                    Image(systemName: "arrow.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.bottom, 10)

                HStack(spacing: 0) {
                    Text("After")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .frame(width: 44, alignment: .leading)

                    Text("I'll check the ")
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                    Text("React")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(accent)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(SettingsPalette.elevatedBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(SettingsPalette.border.opacity(0.22), lineWidth: 1)
            )
        }
    }

    private func dismiss() {
        isPresented = false
    }
}

private struct DictionaryIntroStep: View {
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

// MARK: - Pointing Hand Cursor

private struct PointingHandCursorModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

private extension View {
    func pointingHandCursor() -> some View {
        modifier(PointingHandCursorModifier())
    }
}

// MARK: - Smart Links Tab

struct SmartLinksTabView: View {
    @Environment(AppState.self) private var appState
    @State private var metadataCache = LinkMetadataCache()
    @State private var showIntroModal = false
    @State private var searchText = ""

    private var links: [SmartLink] {
        appState.smartLinkStore.links
            .sorted { $0.trigger.localizedCaseInsensitiveCompare($1.trigger) == .orderedAscending }
    }

    private var filteredLinks: [SmartLink] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return links }
        return links.filter { link in
            link.trigger.localizedCaseInsensitiveContains(query)
                || link.url.localizedCaseInsensitiveContains(query)
        }
    }

    private var isFiltering: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var linkCountLabel: String {
        links.count == 1 ? "1 link" : "\(links.count) links"
    }

    var body: some View {
        SettingsPage(title: "Smart Links") {
            if let backTarget = appState.settingsBackTarget {
                SettingsBackLink(target: backTarget) {
                    appState.selectedSettingsTab = backTarget
                }
            }

            SettingsCardSection(
                "Search",
                headerAccessory: { HelpIconButton { showIntroModal = true } }
            ) {
                SettingsValueRow("Find links", detail: linkCountLabel) {
                    TextField("Search links", text: $searchText)
                        .consumerTextField(width: 320)
                }
            }

            SettingsCardSection("Add a smart link", footer: "When a trigger phrase is spoken during dictation, it gets replaced with a link to the URL.") {
                SmartLinkAddCard()
            }

            if !links.isEmpty {
                SettingsCardSection(isFiltering ? "Filtered Links" : "Links") {
                    if filteredLinks.isEmpty {
                        SettingsSectionBody {
                            ContentUnavailableView(
                                "No matching links",
                                systemImage: "magnifyingglass",
                                description: Text("Try a different trigger phrase or URL.")
                            )
                            .frame(maxWidth: .infinity, minHeight: 140)
                        }
                    } else {
                        linkSection(filteredLinks)
                    }
                }
            } else {
                SettingsCardSection("Links") {
                    SettingsSectionBody {
                    ContentUnavailableView(
                        "No smart links yet",
                        systemImage: "link",
                        description: Text("Add a trigger phrase and URL above to create your first smart link.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 160)
                    }
                }
            }
        }
        .overlay {
            Group {
                if showIntroModal {
                    SmartLinkIntroModal(isPresented: $showIntroModal)
                        .transition(.opacity)
                }
            }
            .allowsHitTesting(showIntroModal)
        }
        .onAppear {
            if !appState.settingsManager.smartLinksIntroSeen {
                appState.settingsManager.smartLinksIntroSeen = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    showIntroModal = true
                }
            }
        }
    }

    @ViewBuilder
    private func linkSection(_ links: [SmartLink]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(links.enumerated()), id: \.element.id) { index, link in
                SmartLinkRowView(
                    link: link,
                    metadataCache: metadataCache
                )

                if index < links.count - 1 {
                    Divider()
                        .padding(.leading, 58)
                }
            }
        }
    }
}

// MARK: - Smart Link Intro Modal

private struct SmartLinkIntroModal: View {
    @Binding var isPresented: Bool
    @State private var revealed = false

    private let linkBlue = SettingsPalette.semanticBlue

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
                Image(systemName: "link.badge.plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(linkBlue)
                Text("How Smart Links Work")
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
            .pointingHandCursor()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(SettingsPalette.elevatedBackground.opacity(0.6))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            SmartLinkIntroStep(
                number: 1,
                title: "Create a trigger",
                description: "Add a phrase like \"open github\" and link it to a URL."
            )

            SmartLinkIntroStep(
                number: 2,
                title: "Speak naturally",
                description: "Use the trigger phrase anywhere in your dictation. Smart links only work in rich text formatting fields."
            )

            replacementPreview

            Button { dismiss() } label: {
                Text("Got it")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(linkBlue)
                    )
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
        }
        .padding(20)
    }

    private var replacementPreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            SmartLinkIntroStep(
                number: 3,
                title: "It gets replaced",
                description: ""
            )

            VStack(alignment: .leading, spacing: 0) {
                previewRow(label: "Before") {
                    Text("I pushed the fix to ")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("open github")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(revealed ? linkBlue : .secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(linkBlue.opacity(revealed ? 0.10 : 0))
                        )
                }

                HStack {
                    Spacer()
                    Image(systemName: "arrow.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.bottom, 10)

                previewRow(label: "After") {
                    Text("I pushed the fix to ")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.primary.opacity(revealed ? 1 : 0.3))

                    HStack(spacing: 3) {
                        Image(systemName: "link")
                            .font(.system(size: 9, weight: .semibold))
                        Text("github")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(linkBlue.opacity(revealed ? 1 : 0.3))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(linkBlue.opacity(revealed ? 0.10 : 0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(linkBlue.opacity(revealed ? 0.22 : 0.06), lineWidth: 1)
                    )
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(SettingsPalette.elevatedBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(SettingsPalette.border.opacity(0.22), lineWidth: 1)
            )
        }
    }

    private func previewRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 0) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 44, alignment: .leading)

            content()
        }
        .padding(.bottom, 10)
    }

    private func dismiss() {
        isPresented = false
        revealed = false
    }
}

private struct SmartLinkIntroStep: View {
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

// MARK: - Smart Link Row

private struct SmartLinkRowView: View {
    @Environment(AppState.self) private var appState
    let link: SmartLink
    let metadataCache: LinkMetadataCache

    @State private var isHovered = false
    @State private var isEditing = false
    @State private var editTrigger = ""
    @State private var editURL = ""
    @FocusState private var editFocus: EditField?

    private enum EditField { case trigger, url }

    var body: some View {
        HStack(spacing: 12) {
            SmartLinkIconView(urlString: isEditing ? editURL : link.url, cache: metadataCache)

            if isEditing {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Trigger phrase", text: $editTrigger)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, weight: .semibold))
                        .focused($editFocus, equals: .trigger)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color(nsColor: .textBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(SettingsPalette.accent.opacity(0.45), lineWidth: 1)
                        )
                        .onSubmit { editFocus = .url }

                    TextField("URL", text: $editURL)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .focused($editFocus, equals: .url)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color(nsColor: .textBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(SettingsPalette.accent.opacity(0.45), lineWidth: 1)
                        )
                        .onSubmit(commitEdit)
                }

                Spacer(minLength: 8)

                HStack(spacing: 4) {
                    FeedQuickActionButton(
                        title: "Save",
                        systemImage: "checkmark",
                        action: commitEdit
                    )
                    FeedQuickActionButton(
                        title: "Cancel",
                        systemImage: "xmark",
                        action: cancelEdit
                    )
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(link.trigger)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(link.isEnabled ? .primary : .secondary)
                        .lineLimit(1)

                    Text(link.url)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Toggle("", isOn: enabledBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)

                HStack(spacing: 4) {
                    FeedQuickActionButton(
                        title: "Edit",
                        systemImage: "pencil",
                        action: startEditing
                    )
                    FeedQuickActionButton(
                        title: "Delete",
                        systemImage: "trash",
                        isDestructive: true,
                        action: deleteLink
                    )
                }
                .opacity(isHovered ? 1 : 0.82)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isEditing ? SettingsPalette.accentFill.opacity(0.5) : (isHovered ? SettingsPalette.accentFill : .clear))
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture(count: 2) {
            startEditing()
        }
        .contextMenu {
            Button("Edit") { startEditing() }
            Button(link.isEnabled ? "Disable" : "Enable") {
                setLinkEnabled(!link.isEnabled)
            }
            Button("Delete", role: .destructive) { deleteLink() }
        }
        .task(id: link.url) {
            await metadataCache.fetchIfNeeded(for: link.url)
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { link.isEnabled },
            set: { setLinkEnabled($0) }
        )
    }

    private func setLinkEnabled(_ isEnabled: Bool) {
        guard isEnabled != link.isEnabled else { return }
        var updated = link
        updated.isEnabled = isEnabled
        appState.smartLinkStore.update(updated)
        appState.analyticsManager.capture("smart_link_toggled", properties: [
            "enabled": updated.isEnabled
        ])
    }

    private func deleteLink() {
        appState.smartLinkStore.remove(id: link.id)
        appState.analyticsManager.capture("smart_link_deleted", properties: [
            "link_count": appState.smartLinkStore.links.count
        ])
    }

    private func startEditing() {
        editTrigger = link.trigger
        editURL = link.url
        isEditing = true
        editFocus = .trigger
    }

    private func commitEdit() {
        let trigger = editTrigger.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = editURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trigger.isEmpty, !url.isEmpty else { return cancelEdit() }

        var updated = link
        updated.trigger = trigger
        updated.url = url
        appState.smartLinkStore.update(updated)
        appState.analyticsManager.capture("smart_link_updated")

        isEditing = false
    }

    private func cancelEdit() {
        isEditing = false
    }
}

// MARK: - Smart Link Icon

private struct SmartLinkIconView: View {
    let urlString: String
    let cache: LinkMetadataCache

    private let size: CGFloat = 32

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(SettingsPalette.elevatedBackground)

            if let image = cache.image(for: urlString) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size - 8, height: size - 8)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else {
                Image(systemName: "globe")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(SettingsPalette.border.opacity(0.22), lineWidth: 1)
        )
    }
}

// MARK: - Smart Link Add Card

private struct SmartLinkAddCard: View {
    @Environment(AppState.self) private var appState

    @State private var newTrigger = ""
    @State private var newURL = ""
    @FocusState private var focusedField: Field?

    private enum Field { case trigger, url }

    private var canAdd: Bool {
        !newTrigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !newURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        SettingsSectionBody {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("TRIGGER PHRASE")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    TextField("e.g. open github", text: $newTrigger)
                        .consumerTextField(width: 240)
                        .focused($focusedField, equals: .trigger)
                        .onSubmit { focusedField = .url }
                }

                Image(systemName: "arrow.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 18)

                VStack(alignment: .leading, spacing: 6) {
                    Text("URL")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    TextField("https://github.com", text: $newURL)
                        .consumerTextField(width: 240)
                        .focused($focusedField, equals: .url)
                        .onSubmit { if canAdd { addLink() } }
                }

                Spacer(minLength: 0)

                ConsumerPrimaryButton("Add link", systemImage: "plus", action: addLink)
                    .disabled(!canAdd)
                    .padding(.top, 18)
            }
        }
    }

    private func addLink() {
        let trigger = newTrigger.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = newURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trigger.isEmpty, !url.isEmpty else { return }
        appState.smartLinkStore.add(trigger: trigger, url: url)
        appState.analyticsManager.capture("smart_link_created", properties: [
            "link_count": appState.smartLinkStore.links.count
        ])
        newTrigger = ""
        newURL = ""
    }
}
