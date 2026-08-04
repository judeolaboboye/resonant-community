import Accessibility
import SwiftUI

enum PersonalizationDisclosureCopy {
    static let localMemory = "Learned memory is stored on this Mac. Cloud cleanup can use structured writing preferences without sending raw correction snippets."
    static let cloudExamples = "Corrections stay local by default. When enabled, cloud cleanup may send up to three prior correction snippets from this Mac with limited automatic redaction."
    static let deviceLocalConsent = "This opt-in applies only to this Mac and is cleared when HIPAA Mode is enabled."
    static let hipaaDisabled = "Unavailable while HIPAA Mode is on. Turn off HIPAA Mode, then opt in again if you want to share correction snippets."
}

enum PersonalizationSettingsCopy {
    static let writingHabitsTitle = "Writing Habits"
    static let eligibleTermsMetric = "eligible learned terms"
    static let eligibleHabitsMetric = "eligible writing habits"
    static let eligibleFormattingMetric = "eligible formatting rules"
    static let readbackCoverageTitle = "Readback coverage"
    static let observedNoEditTitle = "Observed no-edit"
    static let outcomesNotStarted = "Local outcome tracking is waiting for app setup."
    static let outcomesSettingUp = "Setting up local outcome tracking."
    static let outcomesRetrying = "Retrying local outcome tracking."
    static let outcomesLocalStorageNotReady = "Local storage is not ready, so local outcome tracking is unavailable."
    static let outcomesBootstrapUnavailable = "Local outcome tracking could not start from local storage."
    static let outcomesLoadingSummary = "Local outcome tracking is ready. Loading its current summary."
    static let outcomesEmpty = "No local delivery outcomes have been recorded yet."
    static let eligibleOutcomesEmpty = "No readback-eligible paste deliveries have been recorded yet."
    static let coverageExplanation = "Readback coverage is observable results divided by all readback-eligible paste deliveries, including pending attempts."
    static let noEditExplanation = "Observed no-edit is unchanged results divided by observable unchanged plus corrected results. It does not measure improvement."

    static func outcomesUnavailable(
        for setupState: PersonalizationOutcomeSetupState
    ) -> String {
        switch setupState {
        case .notStarted:
            outcomesNotStarted
        case .settingUp:
            outcomesSettingUp
        case .available:
            outcomesLoadingSummary
        case .unavailable(.localStorageNotReady):
            outcomesLocalStorageNotReady
        case .unavailable(.outcomeBootstrapUnavailable):
            outcomesBootstrapUnavailable
        }
    }
}

enum PersonalizationSettingsOperationStatus: Equatable {
    case idle
    case refreshCompleted(Date)
    case resetConfirmation
    case resetCompleted
}

enum PersonalizationSettingsSnapshotPurpose: Equatable {
    case initial
    case manual
    case userMutation
    case runtime
    case outcomeSetup

    fileprivate var showsProgress: Bool {
        switch self {
        case .initial, .manual, .userMutation:
            true
        case .runtime, .outcomeSetup:
            false
        }
    }
}

struct PersonalizationSettingsSnapshotRequest: Equatable {
    fileprivate let generation: UInt64
    fileprivate let purpose: PersonalizationSettingsSnapshotPurpose
}

struct PersonalizationSettingsResetRequest: Equatable {
    fileprivate let generation: UInt64
}

struct PersonalizationSettingsOutcomeRecoveryRequest: Equatable {
    fileprivate let generation: UInt64
}

enum PersonalizationSettingsAccessibilityAnnouncement: Equatable {
    case refreshCompleted
    case resetCompleted

    var text: String {
        switch self {
        case .refreshCompleted:
            "Personalization updated."
        case .resetCompleted:
            "Personalization memory reset."
        }
    }
}

struct PersonalizationSettingsSnapshotCompletion: Equatable {
    let announcement: PersonalizationSettingsAccessibilityAnnouncement?
}

struct PersonalizationSettingsPresentationState: Equatable {
    private(set) var operationStatus: PersonalizationSettingsOperationStatus = .idle
    private(set) var isResetArmed = false
    private(set) var isResetInProgress = false
    private(set) var isOutcomeRecoveryInProgress = false

    private var nextGeneration: UInt64 = 0
    private var currentSnapshotGeneration: UInt64?
    private var foregroundSnapshotGeneration: UInt64?
    private var resetGeneration: UInt64?
    private var outcomeRecoveryGeneration: UInt64?

    var disclosureText: String {
        PersonalizationDisclosureCopy.localMemory
    }

    var isRefreshing: Bool {
        foregroundSnapshotGeneration != nil
            || isResetInProgress
            || isOutcomeRecoveryInProgress
    }

    mutating func beginSnapshotRequest(
        _ purpose: PersonalizationSettingsSnapshotPurpose
    ) -> PersonalizationSettingsSnapshotRequest? {
        guard !isResetInProgress, !isOutcomeRecoveryInProgress else { return nil }

        let generation = advanceGeneration()
        currentSnapshotGeneration = generation
        foregroundSnapshotGeneration = purpose.showsProgress ? generation : nil
        return PersonalizationSettingsSnapshotRequest(
            generation: generation,
            purpose: purpose
        )
    }

    mutating func completeSnapshotRequest(
        _ request: PersonalizationSettingsSnapshotRequest,
        capturedAt: Date
    ) -> PersonalizationSettingsSnapshotCompletion? {
        if foregroundSnapshotGeneration == request.generation {
            foregroundSnapshotGeneration = nil
        }

        guard currentSnapshotGeneration == request.generation,
              !isResetInProgress
        else { return nil }
        currentSnapshotGeneration = nil

        switch request.purpose {
        case .initial:
            if operationStatus == .idle {
                operationStatus = .refreshCompleted(capturedAt)
            }
            return PersonalizationSettingsSnapshotCompletion(announcement: nil)
        case .manual:
            isResetArmed = false
            operationStatus = .refreshCompleted(capturedAt)
            return PersonalizationSettingsSnapshotCompletion(
                announcement: .refreshCompleted
            )
        case .userMutation:
            isResetArmed = false
            operationStatus = .refreshCompleted(capturedAt)
            return PersonalizationSettingsSnapshotCompletion(announcement: nil)
        case .runtime, .outcomeSetup:
            return PersonalizationSettingsSnapshotCompletion(announcement: nil)
        }
    }

    mutating func abandonSnapshotRequest(
        _ request: PersonalizationSettingsSnapshotRequest
    ) {
        if foregroundSnapshotGeneration == request.generation {
            foregroundSnapshotGeneration = nil
        }
        if currentSnapshotGeneration == request.generation {
            currentSnapshotGeneration = nil
        }
    }

    mutating func armReset() {
        guard !isResetInProgress, !isOutcomeRecoveryInProgress else { return }
        invalidateSnapshotRequests()
        isResetArmed = true
        operationStatus = .resetConfirmation
    }

    mutating func beginReset() -> PersonalizationSettingsResetRequest? {
        guard isResetArmed, !isResetInProgress, !isOutcomeRecoveryInProgress else {
            return nil
        }

        invalidateSnapshotRequests()
        let generation = advanceGeneration()
        resetGeneration = generation
        isResetArmed = false
        isResetInProgress = true
        return PersonalizationSettingsResetRequest(generation: generation)
    }

    func canCompleteReset(_ request: PersonalizationSettingsResetRequest) -> Bool {
        isResetInProgress && resetGeneration == request.generation
    }

    mutating func completeReset(
        _ request: PersonalizationSettingsResetRequest
    ) -> PersonalizationSettingsAccessibilityAnnouncement? {
        guard canCompleteReset(request) else { return nil }

        resetGeneration = nil
        isResetInProgress = false
        operationStatus = .resetCompleted
        return .resetCompleted
    }

    mutating func beginOutcomeRecovery() -> PersonalizationSettingsOutcomeRecoveryRequest? {
        guard !isResetInProgress, !isOutcomeRecoveryInProgress else { return nil }

        invalidateSnapshotRequests()
        let generation = advanceGeneration()
        outcomeRecoveryGeneration = generation
        isOutcomeRecoveryInProgress = true
        return PersonalizationSettingsOutcomeRecoveryRequest(generation: generation)
    }

    func canCompleteOutcomeRecovery(
        _ request: PersonalizationSettingsOutcomeRecoveryRequest
    ) -> Bool {
        isOutcomeRecoveryInProgress
            && outcomeRecoveryGeneration == request.generation
    }

    mutating func completeOutcomeRecovery(
        _ request: PersonalizationSettingsOutcomeRecoveryRequest
    ) -> Bool {
        guard canCompleteOutcomeRecovery(request) else { return false }
        outcomeRecoveryGeneration = nil
        isOutcomeRecoveryInProgress = false
        return true
    }

    private mutating func advanceGeneration() -> UInt64 {
        nextGeneration &+= 1
        return nextGeneration
    }

    private mutating func invalidateSnapshotRequests() {
        _ = advanceGeneration()
        currentSnapshotGeneration = nil
        foregroundSnapshotGeneration = nil
    }
}

enum PersonalizationSettingsOutcomeRecoveryResult: Equatable {
    case unavailable(PersonalizationOutcomeSetupState)
    case available(PersonalizationControlsSnapshot)
}

@MainActor
struct PersonalizationSettingsDataActions {
    private let loadControlsSnapshot: () async -> PersonalizationControlsSnapshot
    private let retryOutcomeSetup: () async -> PersonalizationOutcomeSetupState

    init(
        loadControlsSnapshot: @escaping () async -> PersonalizationControlsSnapshot,
        retryOutcomeSetup: @escaping () async -> PersonalizationOutcomeSetupState
    ) {
        self.loadControlsSnapshot = loadControlsSnapshot
        self.retryOutcomeSetup = retryOutcomeSetup
    }

    func refreshSnapshot() async -> PersonalizationControlsSnapshot {
        await loadControlsSnapshot()
    }

    func recoverOutcomes() async -> PersonalizationSettingsOutcomeRecoveryResult {
        let state = await retryOutcomeSetup()
        guard state == .available else {
            return .unavailable(state)
        }
        return .available(await loadControlsSnapshot())
    }
}

@MainActor
struct PersonalizationSettingsAccessibilityAnnouncer {
    private let postValue: (String) -> Void

    init(postValue: @escaping (String) -> Void) {
        self.postValue = postValue
    }

    func post(_ announcement: PersonalizationSettingsAccessibilityAnnouncement) {
        postValue(announcement.text)
    }

    static let system = PersonalizationSettingsAccessibilityAnnouncer { text in
        AccessibilityNotification.Announcement(text).post()
    }
}

enum PersonalizationOutcomePresentation {
    static func rate(_ rate: PersonalizationOutcomeRate) -> String {
        guard rate.denominator > 0 else { return "—" }
        return "\(rate.numerator) / \(rate.denominator) (\(Int((rate.value * 100).rounded()))%)"
    }

    static func surfaceLabel(_ surface: PersonalizationOutcomeSurface) -> String {
        switch surface {
        case .email: return "Email"
        case .chat: return "Chat"
        case .social: return "Social"
        case .code: return "Code"
        case .docs: return "Documents"
        case .task: return "Tasks"
        case .browser: return "Browser"
        case .search: return "Search"
        case .terminal: return "Terminal"
        case .finder: return "Finder"
        case .form: return "Forms"
        case .other: return "Other"
        case .unknown: return "Unknown surface"
        }
    }
}

struct PersonalizationSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var snapshot = PersonalizationControlsSnapshot.empty
    @State private var presentation = PersonalizationSettingsPresentationState()

    private let columns = [
        GridItem(.adaptive(minimum: 160), spacing: 12, alignment: .top)
    ]

    private var controlDataSource: PersonalizationControlDataSource {
        appState.personalizationMemoryStore
    }

    private var outcomeSetupState: PersonalizationOutcomeSetupState {
        appState.personalizationOutcomeSetupCoordinator.state
    }

    private var dataActions: PersonalizationSettingsDataActions {
        PersonalizationSettingsDataActions(
            loadControlsSnapshot: {
                await controlDataSource.controlsSnapshot()
            },
            retryOutcomeSetup: {
                await appState.personalizationOutcomeSetupCoordinator.setupOrRetry()
            }
        )
    }

    private var outcomeSetupDetail: String {
        if presentation.isOutcomeRecoveryInProgress, outcomeSetupState == .settingUp {
            return PersonalizationSettingsCopy.outcomesRetrying
        }
        return PersonalizationSettingsCopy.outcomesUnavailable(for: outcomeSetupState)
    }

    var body: some View {
        SettingsPage(
            title: "Personalization",
            subtitle: "Manage learned names, terms, and writing patterns used to improve dictation."
        ) {
            SettingsCardSection("Overview") {
                SettingsSectionBody {
                    HStack {
                        Spacer()
                        Button {
                            Task { await refresh(.manual) }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .disabled(presentation.isRefreshing || outcomeSetupState == .settingUp)
                    }
                }

                SettingsRowDivider()
                SettingsSectionBody {
                    metricGrid
                }
            }

            memorySection
            cloudExamplesSection
            entitySection
            formatPreferenceSection
            styleSection
            qualitySection

            #if DEBUG
            if AppRuntime.appEnvironment == .development {
                developerSection
            }
            #endif
        }
        .task { await refresh(.initial) }
        .onChange(of: appState.personalizationConsumerRuntimeContext) { _, newContext in
            Task { await refreshForRuntimeChange(expected: newContext) }
        }
        .onChange(of: outcomeSetupState) { _, newState in
            guard newState == .available else { return }
            Task { await refreshForOutcomeSetupAvailability() }
        }
    }

    private var metricGrid: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            SettingsMetricTile(
                value: "\(snapshot.entityConsumers.eligible)",
                label: PersonalizationSettingsCopy.eligibleTermsMetric,
                detail: "\(snapshot.entityConsumers.promptEligible) prompt-only · \(snapshot.entityConsumers.recognitionEligible) recognition eligible · \(recognizerAvailabilityLabel) · \(snapshot.entityConsumers.learningCandidates) learning · \(snapshot.entityConsumers.suppressed) suppressed"
            )
            SettingsMetricTile(
                value: "\(snapshot.styleConsumers.eligibleWritingHabits)",
                label: PersonalizationSettingsCopy.eligibleHabitsMetric,
                detail: "\(snapshot.styleConsumers.availableWritingHabits) available now · \(snapshot.styleConsumers.localPolicyAvailable)/\(snapshot.styleConsumers.localPolicyEligible) local ready · \(snapshot.styleConsumers.cloudStyleAvailable)/\(snapshot.styleConsumers.cloudStyleEligible) cloud ready · \(snapshot.styleConsumers.localPolicyVetoedFamilies) local families gated · \(snapshot.styleConsumers.learningCandidates) learning"
            )
            SettingsMetricTile(
                value: "\(snapshot.formatConsumers.formatterEligible)",
                label: PersonalizationSettingsCopy.eligibleFormattingMetric,
                detail: "\(snapshot.formatConsumers.learningCandidates) learning · \(snapshot.formatConsumers.suppressed) suppressed"
            )

            switch snapshot.evaluation.outcomes {
            case .unavailable:
                SettingsMetricTile(
                    value: "—",
                    label: "readback coverage",
                    detail: outcomeSetupDetail
                )
                SettingsMetricTile(
                    value: "—",
                    label: "observed no-edit",
                    detail: outcomeSetupDetail
                )
            case let .available(summary):
                SettingsMetricTile(
                    value: PersonalizationOutcomePresentation.rate(summary.global.coverage),
                    label: "readback coverage",
                    detail: "observable / eligible"
                )
                SettingsMetricTile(
                    value: PersonalizationOutcomePresentation.rate(summary.global.observedNoEditRate),
                    label: "observed no-edit",
                    detail: "unchanged / observable"
                )
            }
        }
    }

    private var recognizerAvailabilityLabel: String {
        switch snapshot.entityConsumers.recognizerAvailability {
        case .notEligible:
            "no recognition-eligible rows"
        case .runtimeUnavailable:
            "recognizer status unavailable"
        case .featureOff:
            "recognizer off"
        case .unsupportedAdapter:
            "recognizer unsupported"
        case .lowLatencyPaused:
            "recognizer paused"
        case .unsupportedLanguage:
            "recognizer English only"
        case .noEligibleTerms:
            "recognizer has no eligible terms"
        case .helperAbsent:
            "recognizer helper absent"
        case .helperDownloading:
            "recognizer helper downloading"
        case .helperFailed:
            "recognizer helper failed"
        case .automaticLanguageConditional:
            "recognizer Auto conditional"
        case .available:
            "recognizer ready"
        }
    }

    private var memorySection: some View {
        SettingsCardSection("Memory", footer: "Resetting removes learned terms, writing habits, formatting rules, and local correction-log events.") {
            SettingsSectionBody {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(presentation.disclosureText)
                        .font(SettingsTypography.body)
                        .foregroundStyle(.secondary)

                    if let operationStatusText {
                        Text(operationStatusText)
                            .font(SettingsTypography.metadata)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(operationStatusText)
                    }
                }

                Spacer()
            }
            }

            SettingsRowDivider()
            SettingsSectionBody {
            Button(role: presentation.isResetArmed ? .destructive : nil) {
                if presentation.isResetArmed {
                    Task { await resetMemory() }
                } else {
                    presentation.armReset()
                }
            } label: {
                Label(
                    presentation.isResetArmed ? "Confirm Reset" : "Reset Learned Memory",
                    systemImage: "trash"
                )
            }
            .disabled(
                presentation.isResetInProgress
                    || presentation.isOutcomeRecoveryInProgress
                    || outcomeSetupState == .settingUp
            )
            }
        }
    }

    private var cloudExamplesSection: some View {
        @Bindable var settings = appState.settingsManager

        return SettingsCardSection(
            "Cloud personalization",
            footer: PersonalizationDisclosureCopy.deviceLocalConsent
        ) {
            SettingsToggleRow(
                "Share correction examples",
                detail: PersonalizationDisclosureCopy.cloudExamples,
                isOn: $settings.cloudPersonalizationExamplesEnabled
            )
            .disabled(settings.hipaaMode)

            if settings.hipaaMode {
                SettingsRowDivider()
                SettingsSectionBody {
                    Label(PersonalizationDisclosureCopy.hipaaDisabled, systemImage: "lock.shield")
                        .font(SettingsTypography.metadata)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var entitySection: some View {
        SettingsCardSection("Learned Terms") {
            if snapshot.entities.isEmpty {
                SettingsSectionBody {
                PersonalizationEmptyRow(text: "No learned terms yet.")
                }
            } else {
                ForEach(snapshot.entities) { entity in
                    PersonalizationEntityControlRow(
                        entity: entity,
                        onPin: {
                            Task {
                                await controlDataSource.setEntityPinned(id: entity.id, isPinned: !entity.isUserPinned)
                                await refresh(.userMutation)
                            }
                        },
                        onSuppress: {
                            Task {
                                await controlDataSource.setEntitySuppressed(id: entity.id, isSuppressed: !entity.isSuppressed)
                                await refresh(.userMutation)
                            }
                        }
                    )
                }
            }
        }
    }

    private var styleSection: some View {
        SettingsCardSection(PersonalizationSettingsCopy.writingHabitsTitle) {
            if snapshot.styles.isEmpty {
                SettingsSectionBody {
                PersonalizationEmptyRow(text: "No writing habits yet.")
                }
            } else {
                ForEach(snapshot.styles) { style in
                    PersonalizationStyleControlRow(style: style)
                }
            }
        }
    }

    private var formatPreferenceSection: some View {
        SettingsCardSection(
            "Formatting Preferences",
            footer: "Suppress a learned casing or formatting rule without deleting its history."
        ) {
            if snapshot.formatPreferences.isEmpty {
                SettingsSectionBody {
                    PersonalizationEmptyRow(text: "No learned formatting preferences yet.")
                }
            } else {
                ForEach(snapshot.formatPreferences) { preference in
                    PersonalizationFormatPreferenceControlRow(
                        preference: preference,
                        onSuppress: {
                            Task {
                                await controlDataSource.setFormatPreferenceSuppressed(
                                    id: preference.id,
                                    isSuppressed: !preference.isSuppressed
                                )
                                await refresh(.userMutation)
                            }
                        }
                    )
                }
            }
        }
    }

    private var qualitySection: some View {
        SettingsCardSection(
            "Local Outcomes",
            footer: PersonalizationSettingsCopy.coverageExplanation + " " + PersonalizationSettingsCopy.noEditExplanation
        ) {
            switch snapshot.evaluation.outcomes {
            case .unavailable:
                SettingsSectionBody {
                    HStack(alignment: .center, spacing: 10) {
                        if outcomeSetupState == .settingUp {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                        }

                        Text(outcomeSetupDetail)
                            .font(SettingsTypography.metadata)
                            .foregroundStyle(.secondary)

                        Spacer()

                        if case .unavailable = outcomeSetupState {
                            Button {
                                Task { await retryOutcomeSetup() }
                            } label: {
                                Text(
                                    presentation.isOutcomeRecoveryInProgress
                                        ? "Retrying"
                                        : "Retry"
                                )
                            }
                            .controlSize(.small)
                            .disabled(
                                presentation.isRefreshing
                                    || outcomeSetupState == .settingUp
                            )
                        }
                    }
                }
            case let .available(summary):
                if summary.global.attemptCount == 0 {
                    SettingsSectionBody {
                        PersonalizationEmptyRow(text: PersonalizationSettingsCopy.outcomesEmpty)
                    }
                } else {
                    PersonalizationOutcomePopulationRows(
                        title: "All surfaces",
                        population: summary.global
                    )

                    if !summary.surfaces.isEmpty {
                        SettingsRowDivider()
                        SettingsSectionBody {
                            Text("By surface")
                                .font(.system(size: 13, weight: .semibold))
                        }
                    }
                    ForEach(summary.surfaces) { surface in
                        PersonalizationOutcomeSurfaceRow(surface: surface)
                    }

                    if summary.global.coverage.denominator == 0 {
                        SettingsRowDivider()
                        SettingsSectionBody {
                            Text(PersonalizationSettingsCopy.eligibleOutcomesEmpty)
                                .font(SettingsTypography.metadata)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !summary.global.exclusionCounts.isEmpty {
                        SettingsRowDivider()
                        SettingsSectionBody {
                            Text("Excluded delivery paths")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        ForEach(PersonalizationOutcomeStatus.allCases.filter(\.isExcluded), id: \.self) { status in
                            if let count = summary.global.exclusionCounts[status], count > 0 {
                                SettingsValueRow(outcomeStatusLabel(status)) {
                                    Text("\(count)").foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    #if DEBUG
    private var developerSection: some View {
        SettingsCardSection(
            "Developer Correction Log",
            footer: "These edit diagnostics come from retained correction-log rows and are not delivery-outcome rates."
        ) {
            if snapshot.evaluation.topCorrections.isEmpty {
                SettingsSectionBody {
                PersonalizationEmptyRow(text: "No correction pairs recorded.")
                }
            } else {
                ForEach(snapshot.evaluation.topCorrections) { correction in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(correction.written)
                                .font(.system(size: 13, weight: .semibold))
                            Text(correction.spoken)
                                .font(SettingsTypography.metadata)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(correction.count)x")
                            .font(SettingsTypography.metadata)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, SettingsLayout.rowHorizontalPadding)
                    .padding(.vertical, SettingsLayout.rowVerticalPadding)
                }
            }
        }
    }
    #endif

    private var operationStatusText: String? {
        switch presentation.operationStatus {
        case .idle:
            nil
        case let .refreshCompleted(capturedAt):
            "Updated \(Self.timeFormatter.string(from: capturedAt))"
        case .resetConfirmation:
            "Press reset again to confirm."
        case .resetCompleted:
            "Memory reset."
        }
    }

    private func refresh(
        _ purpose: PersonalizationSettingsSnapshotPurpose
    ) async {
        guard let request = presentation.beginSnapshotRequest(purpose) else { return }
        let refreshed = await dataActions.refreshSnapshot()
        guard let completion = presentation.completeSnapshotRequest(
            request,
            capturedAt: refreshed.capturedAt
        ) else { return }

        snapshot = refreshed
        if let announcement = completion.announcement {
            PersonalizationSettingsAccessibilityAnnouncer.system.post(announcement)
        }
    }

    private func retryOutcomeSetup() async {
        guard let request = presentation.beginOutcomeRecovery() else { return }
        let result = await dataActions.recoverOutcomes()

        switch result {
        case .unavailable:
            _ = presentation.completeOutcomeRecovery(request)

        case let .available(refreshed):
            guard presentation.canCompleteOutcomeRecovery(request) else { return }
            snapshot = refreshed
            guard presentation.completeOutcomeRecovery(request) else { return }

            let currentRuntimeContext = appState.personalizationConsumerRuntimeContext
            if refreshed.runtimeContext != currentRuntimeContext {
                await refreshForRuntimeChange(expected: currentRuntimeContext)
            }
        }
    }

    private func refreshForOutcomeSetupAvailability() async {
        guard outcomeSetupState == .available,
              let request = presentation.beginSnapshotRequest(.outcomeSetup)
        else { return }

        let refreshed = await dataActions.refreshSnapshot()
        guard !Task.isCancelled,
              outcomeSetupState == .available,
              case .available = refreshed.evaluation.outcomes
        else {
            presentation.abandonSnapshotRequest(request)
            return
        }
        guard presentation.completeSnapshotRequest(
            request,
            capturedAt: refreshed.capturedAt
        ) != nil else { return }
        snapshot = refreshed
    }

    private func refreshForRuntimeChange(
        expected: PersonalizationConsumerRuntimeContext
    ) async {
        guard let request = presentation.beginSnapshotRequest(.runtime) else { return }
        let refreshed = await controlDataSource.controlsSnapshot()
        guard !Task.isCancelled,
              refreshed.runtimeContext == expected,
              appState.personalizationConsumerRuntimeContext == expected
        else {
            presentation.abandonSnapshotRequest(request)
            return
        }
        guard presentation.completeSnapshotRequest(
            request,
            capturedAt: refreshed.capturedAt
        ) != nil else { return }
        snapshot = refreshed
    }

    private func resetMemory() async {
        guard let request = presentation.beginReset() else { return }
        await controlDataSource.clearPersonalizationMemory()
        let refreshed = await controlDataSource.controlsSnapshot()
        guard presentation.canCompleteReset(request) else { return }
        snapshot = refreshed
        guard let announcement = presentation.completeReset(request) else { return }
        PersonalizationSettingsAccessibilityAnnouncer.system.post(announcement)

        let currentRuntimeContext = appState.personalizationConsumerRuntimeContext
        if refreshed.runtimeContext != currentRuntimeContext {
            await refreshForRuntimeChange(expected: currentRuntimeContext)
        }
    }

    private func outcomeStatusLabel(_ status: PersonalizationOutcomeStatus) -> String {
        switch status {
        case .excludedDeliveryFailed: return "Delivery failed"
        case .excludedPartialDelivery: return "Partial delivery"
        case .excludedCopyOnly: return "Copy only"
        case .excludedAutoSent: return "Auto-sent"
        case .excludedSelectionTransform: return "Selection transform"
        default: return status.rawValue.replacingOccurrences(of: "_", with: " ")
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}

private struct PersonalizationEntityControlRow: View {
    let entity: PersonalizationEntitySummary
    let onPin: () -> Void
    let onSuppress: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(entity.value)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)

                    SettingsMetaPill(title: entity.type)
                    if entity.isUserPinned {
                        SettingsMetaPill(title: "pinned", systemImage: "pin.fill", tint: SettingsPalette.infoText)
                    }
                    PersonalizationEntityEligibilityPill(state: entity.eligibility)
                    if entity.eligibility.isRecognitionEligible {
                        PersonalizationRecognizerAvailabilityPill(
                            availability: entity.recognizerAvailability
                        )
                    }
                }

                Text("\(entity.scope) · \(entity.positiveCount) supporting / \(entity.negativeCount) contrary signals")
                    .font(SettingsTypography.metadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button(action: onPin) {
                Label(entity.isUserPinned ? "Unpin" : "Pin", systemImage: entity.isUserPinned ? "pin.slash" : "pin")
            }
            .controlSize(.small)

            Button(role: entity.isSuppressed ? nil : .destructive, action: onSuppress) {
                Label(entity.isSuppressed ? "Restore" : "Suppress", systemImage: entity.isSuppressed ? "eye" : "eye.slash")
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}

private struct PersonalizationStyleControlRow: View {
    let style: PersonalizationStyleSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(style.scope)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(style.evidenceCount) observations")
                    .font(SettingsTypography.metadata)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                if style.consumerState.isLearning {
                    SettingsMetaPill(title: "learning")
                }
                if style.consumerState.isLocalPolicyAvailable {
                    SettingsMetaPill(title: "local ready", systemImage: "textformat", tint: SettingsPalette.infoText)
                }
                if style.consumerState.localPolicyVetoedFamilyCount > 0 {
                    SettingsMetaPill(
                        title: "\(style.consumerState.localPolicyVetoedFamilyCount) local gate off",
                        systemImage: "pause.circle",
                        tint: .orange
                    )
                }
                if style.consumerState.localPolicyUnknownFamilyCount > 0 {
                    SettingsMetaPill(
                        title: "local status unavailable",
                        systemImage: "questionmark.circle",
                        tint: .orange
                    )
                }
                if style.consumerState.isCloudStyleEligible {
                    PersonalizationCloudStyleAvailabilityPill(
                        availability: style.consumerState.cloudAvailability
                    )
                }
            }

            Text(style.summary)
                .font(SettingsTypography.metadata)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}

private struct PersonalizationFormatPreferenceControlRow: View {
    let preference: PersonalizationFormatPreferenceSummary
    let onSuppress: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(preference.preferredValue)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    SettingsMetaPill(title: categoryLabel)
                    PersonalizationFormatEligibilityPill(state: preference.eligibility)
                }

                Text("\(preference.scope) · \(preference.positiveCount) supporting / \(preference.negativeCount) contrary signals")
                    .font(SettingsTypography.metadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button(role: preference.isSuppressed ? nil : .destructive, action: onSuppress) {
                Label(
                    preference.isSuppressed ? "Restore" : "Suppress",
                    systemImage: preference.isSuppressed ? "eye" : "eye.slash"
                )
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    private var categoryLabel: String {
        switch preference.category {
        case "wordCasing": "word casing"
        case "emailCasing": "email casing"
        case "phoneStyle": "phone style"
        case "urlExpansionRevert": "site naming"
        case "punctuation": "punctuation"
        default: preference.category.replacingOccurrences(of: "_", with: " ")
        }
    }
}

private struct PersonalizationEntityEligibilityPill: View {
    let state: PersonalizationEntityEligibilityState

    var body: some View {
        switch state {
        case .learning:
            SettingsMetaPill(title: "learning")
        case .promptEligible:
            SettingsMetaPill(title: "prompt eligible", systemImage: "text.bubble", tint: SettingsPalette.infoText)
        case .recognitionEligible:
            SettingsMetaPill(title: "recognition eligible", systemImage: "waveform", tint: SettingsPalette.infoText)
        case .suppressed:
            SettingsMetaPill(title: "suppressed", systemImage: "eye.slash", tint: .orange)
        }
    }
}

private struct PersonalizationRecognizerAvailabilityPill: View {
    let availability: PersonalizationRecognizerAvailability

    var body: some View {
        switch availability {
        case .notEligible:
            EmptyView()
        case .runtimeUnavailable:
            SettingsMetaPill(title: "recognizer status unavailable", systemImage: "questionmark.circle", tint: .orange)
        case .featureOff:
            SettingsMetaPill(title: "recognizer off", systemImage: "power", tint: .orange)
        case .unsupportedAdapter:
            SettingsMetaPill(title: "recognizer unsupported", systemImage: "nosign", tint: .orange)
        case .lowLatencyPaused:
            SettingsMetaPill(title: "recognizer paused", systemImage: "bolt", tint: .orange)
        case .unsupportedLanguage:
            SettingsMetaPill(title: "recognizer English only", systemImage: "character.book.closed", tint: .orange)
        case .noEligibleTerms:
            SettingsMetaPill(title: "recognizer unavailable", systemImage: "text.badge.xmark", tint: .orange)
        case .helperAbsent:
            SettingsMetaPill(title: "helper absent", systemImage: "arrow.down.circle", tint: .orange)
        case .helperDownloading:
            SettingsMetaPill(title: "helper downloading", systemImage: "arrow.down.circle", tint: .orange)
        case .helperFailed:
            SettingsMetaPill(title: "helper failed", systemImage: "exclamationmark.triangle", tint: .orange)
        case .automaticLanguageConditional:
            SettingsMetaPill(title: "recognizer Auto conditional", systemImage: "character.magnify", tint: SettingsPalette.infoText)
        case .available:
            SettingsMetaPill(title: "recognizer ready", systemImage: "checkmark.circle", tint: SettingsPalette.infoText)
        }
    }
}

private struct PersonalizationCloudStyleAvailabilityPill: View {
    let availability: PersonalizationCloudCleanupAvailability

    var body: some View {
        switch availability {
        case .eligible:
            // Deliberately "eligible", not "ready": the pipeline still skips a
            // short dictation, an email signoff-only edit, or a verbatim
            // surface, and none of those can be known before the utterance.
            SettingsMetaPill(title: "cloud eligible", systemImage: "cloud", tint: SettingsPalette.infoText)
        case .unknown:
            SettingsMetaPill(title: "cloud status unavailable", systemImage: "questionmark.circle", tint: .orange)
        case .polishVerbatim:
            SettingsMetaPill(title: "verbatim everywhere", systemImage: "text.badge.minus", tint: .orange)
        case .lowLatencyPaused:
            SettingsMetaPill(title: "cloud paused", systemImage: "bolt", tint: .orange)
        case .disabled:
            SettingsMetaPill(title: "cloud off", systemImage: "cloud.slash", tint: .orange)
        case .signedOut:
            SettingsMetaPill(title: "cloud signed out", systemImage: "person.crop.circle.badge.xmark", tint: .orange)
        }
    }
}

private struct PersonalizationFormatEligibilityPill: View {
    let state: PersonalizationFormatEligibilityState

    var body: some View {
        switch state {
        case .learning:
            SettingsMetaPill(title: "learning")
        case .formatterEligible:
            SettingsMetaPill(title: "formatter eligible", systemImage: "textformat", tint: SettingsPalette.infoText)
        case .suppressed:
            SettingsMetaPill(title: "suppressed", systemImage: "eye.slash", tint: .orange)
        }
    }
}

private struct PersonalizationOutcomePopulationRows: View {
    let title: String
    let population: PersonalizationOutcomePopulationSummary

    var body: some View {
        SettingsSectionBody {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(population.attemptCount) attempts")
                    .font(SettingsTypography.metadata)
                    .foregroundStyle(.secondary)
            }
        }

        SettingsRowDivider()
        SettingsValueRow(PersonalizationSettingsCopy.readbackCoverageTitle) {
            Text(PersonalizationOutcomePresentation.rate(population.coverage))
                .foregroundStyle(.secondary)
        }
        SettingsRowDivider()
        SettingsValueRow(PersonalizationSettingsCopy.observedNoEditTitle) {
            Text(PersonalizationOutcomePresentation.rate(population.observedNoEditRate))
                .foregroundStyle(.secondary)
        }
        SettingsRowDivider()
        SettingsValueRow("Pending / unobservable / excluded") {
            Text("\(population.pendingCount) / \(population.unobservableCount) / \(population.excludedCount)")
                .foregroundStyle(.secondary)
        }
    }
}

private struct PersonalizationOutcomeSurfaceRow: View {
    let surface: PersonalizationOutcomeSurfaceSummary

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(PersonalizationOutcomePresentation.surfaceLabel(surface.surface))
                    .font(.system(size: 13, weight: .semibold))
                Text("\(surface.population.attemptCount) attempts · \(surface.population.pendingCount) pending · \(surface.population.unobservableCount) unobservable · \(surface.population.excludedCount) excluded")
                    .font(SettingsTypography.metadata)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text("Coverage \(PersonalizationOutcomePresentation.rate(surface.population.coverage))")
                    .font(SettingsTypography.metadata)
                Text("No-edit \(PersonalizationOutcomePresentation.rate(surface.population.observedNoEditRate))")
                    .font(SettingsTypography.metadata)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct PersonalizationEmptyRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(SettingsTypography.body)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
    }
}
