import AppKit
import ApplicationServices
import Defaults
import EventKit
import Foundation
import Observation
import SwiftData
import UserNotifications
import os

@MainActor
@Observable
final class AppState {
    @ObservationIgnored
    private static let log = Logger.resonant("AppState")

    private enum BackgroundCloudWorkDelay {
        // Debounce non-interactive cloud work so it doesn't contend with
        // foreground transforms and dictation cleanup.
        static let journalGeneration: Duration = .seconds(20)
        static let memoEnrichment: Duration = .seconds(10)
    }

    private struct PendingMeetingAutoStop {
        let meeting: MeetingContextDetector.DetectedMeeting
        let reason: MeetingAutoStopEvaluator.StopReason
        let startedAt: Date
    }

    private func logEmailSignatureDecision(
        _ decision: EmailSignatureSupport.FooterDecision,
        source: String
    ) {
        let outcome = decision.outcome.rawValue
        let reason = decision.reason.rawValue
        let enabled = decision.enabled.description
        let allowSignature = decision.allowSignature.description
        let emailContext = decision.isEmailContext.description
        let bodyField = decision.isLikelyEmailBodyField.description
        let emptyText = decision.trimmedTextIsEmpty.description
        let textHasFooter = decision.textAlreadyHasFooter.description
        let fieldHasFooter = decision.fieldAlreadyHasFooter.description
        let emailMode = decision.emailMode?.rawValue ?? "nil"
        let fieldRole = decision.fieldRole?.lowercased() ?? "nil"
        let fieldSubrole = decision.fieldSubrole?.lowercased() ?? "nil"
        let footerPasteboard = decision.shouldAppendFooter ? "html_plain_fallback" : "unchanged"

        Self.log.info("email_footer_decision source=\(source, privacy: .public) outcome=\(outcome, privacy: .public) reason=\(reason, privacy: .public) enabled=\(enabled, privacy: .public) allowSignature=\(allowSignature, privacy: .public) mode=\(emailMode, privacy: .public) emailContext=\(emailContext, privacy: .public) bodyField=\(bodyField, privacy: .public) emptyText=\(emptyText, privacy: .public) textHasFooter=\(textHasFooter, privacy: .public) fieldHasFooter=\(fieldHasFooter, privacy: .public) fieldRole=\(fieldRole, privacy: .public) fieldSubrole=\(fieldSubrole, privacy: .public) footerPasteboard=\(footerPasteboard, privacy: .public)")
    }

    // MARK: - No-dependency properties (inline init)

    let modelRegistry        = ModelRegistry()
    let meetingBackendDownloader = MeetingBackendDownloader()
    let settingsManager      = SettingsManager.shared
    let hotkeyManager        = HotkeyManager()
    let pasteManager         = PasteManager()
    let dictationMediaController = DictationMediaController()
    let systemOutputAudioController = SystemOutputAudioController()
    let audioRecorder        = AudioRecorder()
    let dictationLivePreview = DictationLivePreviewController()
    let audioInputDeviceManager = AudioInputDeviceManager()
    let dataStore            = DataStore()
    let memoManager          = MemoManager()
    let feedManager          = FeedManager()
    let journalManager       = JournalManager()
    let statsTracker         = StatsTracker()
    let streakTracker        = StreakTracker()
    let smartLinkStore       = SmartLinkStore()
    let dictionaryStore      = DictionaryStore()
    let contactNameStore     = ContactNameStore()
    let personalizationMemoryStore = PersonalizationMemoryStore()
    let personalizationOutcomeStore = PersonalizationOutcomeStore()
    let correctionObserver: CorrectionObserver
    let contextExtractor     = ContextExtractor()
    let screenContextBiasSession = ScreenContextBiasSession()
    private var vocabularyBoostEngine: ParakeetVocabularyBoostEngine?
    let vocabularyBoostAttemptRecorder = VocabularyBoostAttemptRecorder(
        onOutcome: { outcome in
            await VocabularyBoostAttemptTelemetry.capture(outcome)
        }
    )
    let vocabularyBoostDownloadController = VocabularyBoostDownloadController(
        isDownloaded: { ParakeetVocabularyBoostEngine.isModelDownloaded },
        download: { try await ParakeetVocabularyBoostEngine.downloadModelIfNeeded() }
    )
    let authManager          = AuthManager()
    let analyticsManager     = AnalyticsManager.shared
    let workspaceSyncEngine: WorkspaceSyncEngine
    let notchCoordinator     = NotchCoordinator()
    let cursorPasteHint      = CursorPasteHintController()
    let audioCuePlayer       = AudioCuePlayer()
    let activityStreamWriter = ActivityStreamWriter()
    let commandRouter        = CommandRouter()
    let dispatchLearningStore = DispatchLearningStore()
    let dispatchTrialStore   = DispatchTrialStore()
    let patternInferenceEngine = PatternInferenceEngine()
    let archiveWriter        = ArchiveWriter()
    let recoveryStore        = RecoveryStore()
    let meetingPromptNotifier = MeetingPromptNotifier()
    let wordLearnPromptNotifier = WordLearnPromptNotifier()
    let meetingWebhookSender = MeetingWebhookSender()
    let calendarHintSource = EventKitMeetingCalendarHintSource()
    let ambientContextCollector: AmbientContextCollector
    let mcpManager: MCPManager
    let localAPIServer: LocalAPIServer
    let settingsWindowController  = SettingsWindowController()
    let onboardingWindowController = OnboardingWindowController()
    let authWindowController = AuthWindowController()
    let microphoneSwitchNotifier = MicrophoneSwitchNotifier()
    let meetingCompanionState = MeetingCompanionState()
    let meetingScratchpadWindowController = MeetingScratchpadWindowController()
    /// Every `NotificationCenter` observer registered during launch/setup,
    /// torn down wholesale in `shutdown()` so a re-instantiated AppState (e.g.
    /// in tests) does not accumulate duplicate observers.
    @ObservationIgnored private let notificationObservers = NotificationObserverRegistry()

    /// Meeting recorder — only available on macOS 14.2+.
    @ObservationIgnored private(set) var meetingRecorderManager: MeetingRecorderManager?

    // MARK: - Dependency-initialized properties (set in init)

    let postProcessor:    PostProcessor
    let dictationManager: DictationManager
    let convexClient:     ConvexClient
    let hotMicManager:    HotMicManager
    let deliveryPersonalizationRouter: DeliveryPersonalizationRouter
    let personalizationOutcomeSetupCoordinator: PersonalizationOutcomeSetupCoordinator
    @ObservationIgnored private let runtimeSupportActions: AppRuntimeSupportActions
    @ObservationIgnored let clamshellMicrophoneSwitcher: ClamshellMicrophoneSwitcher
    @ObservationIgnored private let meetingContextDetector: MeetingContextDetector

    // MARK: - Mutable state

    private(set) var notchWindowManager: NotchWindowManager?
    var isRecording      = false
    var lastTranscriptionPreview: String?
    /// Where the most recent dictation landed — lets onboarding celebrate a
    /// real-app delivery ("12 words delivered to Notes") instead of a sandbox.
    var lastDictationTargetAppName: String?
    var lastDictationTargetBundleId: String?
    var currentMode: DictationMode = .dictation
    var recordingStartedAt: Date?
    private var recordingTargetApplication: NSRunningApplication?
    private var recordingPreselectedText: String?
    private var recordingPreselectedRange: SelectionRange?
    @ObservationIgnored private var notchTargetContextRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var preloadedHotContextTask: Task<ContextExtractor.HotContext, Never>?
    @ObservationIgnored private var activeRecipientContextTask: (
        id: UUID,
        task: Task<ActiveRecipientContext?, Never>
    )?
    @ObservationIgnored private var activeLatencyLogger: DictationLatencyLogger?
    @ObservationIgnored private var captureCancellationQuiescenceID: UUID?
    @ObservationIgnored private var captureCancellationQuiescenceTask: Task<Void, Never>?
    @ObservationIgnored private var activeCaptureFinalizationRetirement: CaptureFinalizationRetirement?
    @ObservationIgnored private var lowAudioWarningTask: Task<Void, Never>?
    /// When the most recent dictation capture ended *unproductively* (empty /
    /// silent / cancelled). Used to throttle rapid hold-mode re-triggers so a
    /// fumbled Fn+space lock can't oscillate the notch between the no-speech
    /// error and the recording overlay. Cleared once a capture produces text.
    @ObservationIgnored private var lastUnproductiveCaptureEndedAt: Date?
    /// Hotkey-accept → recorder-running for the current dictation, attached to
    /// start and failure analytics so the capture-start deficit stays visible.
    @ObservationIgnored private var lastCaptureStartGapMs: Int?
    @ObservationIgnored private var commandFollowUpTask: Task<Void, Never>?
    private var activeDictationID: String?
    @ObservationIgnored private var activeCaptureResultTask: (id: UUID, task: Task<Void, Never>)?
    @ObservationIgnored private var correctionFlushTask: Task<Void, Never>?
    @ObservationIgnored private var pendingLearnedWordNotices: [String] = []
    @ObservationIgnored private var learnedWordNoticeFlushTask: Task<Void, Never>?
    /// ID of the recovery marker we wrote for the in-flight capture. Used to
    /// scope `clearActiveCapture(id:)` so a delayed cleanup from a previous
    /// session can't wipe a marker written by a newer capture.
    @ObservationIgnored private var activeCaptureRecoveryID: UUID?
    @ObservationIgnored private var activeCaptureShouldPersistAudio: Bool?
    @ObservationIgnored private var hasUnreadableActiveCaptureRecovery = false
    /// A failed dictation whose audio survived on disk, offered for one-tap
    /// retry from the notch error strip. Superseded by the next capture.
    private var retryableDictationCapture: RetryableDictationCapture?
    private var isRetryingDictation = false
    private var isClearingWorkspace = false
    private var hasDetectedRecordingAudio = false
    @ObservationIgnored private var recordingLevelWindow = RecordingLevelWindow()
    @ObservationIgnored private var recordingHintIsNoiseBed = false
    private var isStartingRecording = false
    private(set) var isFinishingCapture = false
    /// Bumped after MeetingEntry SwiftData writes that happen *outside* a
    /// MeetingsTabView interaction (save pipeline finish, summary land,
    /// rebind-to-calendar). View-driven edits drive their own reload so they
    /// don't bump this. Views `.task(id:)` on this for live refresh without
    /// subscribing to the SwiftData container.
    private(set) var meetingDataVersion: Int = 0
    private(set) var meetingCalendarDataVersion: Int = 0
    private var pendingStopAfterStart = false
    @ObservationIgnored private var recordingStartOwnership = CaptureStartAttemptOwnership()
    @ObservationIgnored private var meetingStartOwnership = CaptureStartAttemptOwnership()
    private var startingRecordingWatchdog: Task<Void, Never>?
    @ObservationIgnored private var dictationFinalizationCommitted = false
    @ObservationIgnored private var memoFinalizationCommitted = false
    @ObservationIgnored private lazy var meetingNoteAutosaver = MeetingNoteAutosaver(dataStore: dataStore)
    @ObservationIgnored private var activeMeetingSummaryTasks: [UUID: MeetingSummaryTaskHandle] = [:]
    @ObservationIgnored private var meetingCalendarPromptRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var meetingCalendarStoreChangeTask: Task<Void, Never>?
    @ObservationIgnored private var meetingBackendAtStart: [UUID: String] = [:]
    @ObservationIgnored private let journalGenerationDebouncer = KeyedTaskDebouncer<Date>()
    @ObservationIgnored private let memoDistillationDebouncer = KeyedTaskDebouncer<UUID>()
    @ObservationIgnored private let memoTitleDebouncer = KeyedTaskDebouncer<UUID>()
    @ObservationIgnored private let audioWarmUpRecoveryCoordinator = AudioWarmUpRecoveryCoordinator()
    @ObservationIgnored private let systemPowerTransitionCoordinator = SystemPowerTransitionCoordinator()
    @ObservationIgnored private var hasMeetingWarmUpStartupSuppression = false
    @ObservationIgnored private var isSystemSleeping = false
    @ObservationIgnored private var isShuttingDown = false
    private var currentCaptureUsesPersistentPresentation = false
    private(set) var activeInputDeviceName: String?
    private(set) var inputRoutingMessage: String?
    private(set) var inputRoutingUsesFallback = false
    /// Name of the user-selected microphone we fell back *from* when it became
    /// unavailable. Lets failure copy explain why capture references the built-in
    /// mic instead of the input the user actually picked.
    private(set) var fallbackUnavailableDeviceName: String?
    /// Whether the previous device scan found no input devices at all — the
    /// "No microphone connected" alert fires only on the transition into that
    /// state, not on every scan while it persists.
    @ObservationIgnored private var lastAudioInputScanFoundNoDevices = false
    private(set) var isLowLatencyReady = false
    private var activeMeetingLifecycleContext: MeetingContextDetector.DetectedMeeting?
    @ObservationIgnored private var pendingMeetingAutoStop: PendingMeetingAutoStop?
    @ObservationIgnored private var pendingMeetingAutoStopRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var approvedMeetingAutoStopReason: MeetingAutoStopEvaluator.StopReason?
    @ObservationIgnored private var approvedMeetingAutoStopCandidate: MeetingContextDetector.MeetingEndCandidate?
    private var currentMeetingSystemTransport: MeetingAudioTransport?
    private var hasWarnedBluetoothThisSession = false
    var onMenuBarRecordingActivityChange: ((Bool) -> Void)?
    private(set) var lastSettingsEntryTab: SettingsTab = .dictation
    /// Tab the user came from when they drilled into the current settings tab,
    /// used to render a "Back to ..." link. Cleared automatically on the next
    /// tab change unless the caller re-arms it via `pendingSettingsBackTarget`.
    private(set) var settingsBackTarget: SettingsTab?
    var pendingSettingsBackTarget: SettingsTab?
    var selectedSettingsTab: SettingsTab? = .home {
        didSet {
            settingsBackTarget = pendingSettingsBackTarget
            pendingSettingsBackTarget = nil
            guard let selectedSettingsTab,
                  selectedSettingsTab.isSettingsSidebarTab
            else {
                return
            }
            lastSettingsEntryTab = selectedSettingsTab
        }
    }
    var isShowingSettings = false
    /// Optional anchor id to scroll to within the active settings tab.
    /// Set when the user picks a result from the settings search; tab views
    /// observe this and clear it after performing the scroll.
    var settingsScrollAnchor: String?
    var selectedMemoID: UUID?
    var selectedFeedItemID: UUID?
    var selectedJournalReviewDate: Date?
    var isHomeSearchOpen = false
    var homeSearchText = ""
    var homeSearchKindFilter = FeedKindFilter.all
    var homeSearchTimeFilter = FeedTimeFilter.allTime
    private(set) var workspaceCloudUploadState: WorkspaceCloudUploadState = .idle(
        lastSyncedAt: Defaults[.workspaceCloudTextLastSyncedAt]
    )
    var availableUpdate: AvailableUpdateInfo?
    @ObservationIgnored var onRelaunchForUpdate: (() -> Void)?
    private var pendingLoginSource = "settings"

    struct AvailableUpdateInfo: Equatable {
        enum Phase: Equatable {
            case available
            case downloading
            case preparingToInstall
            case readyToRestart
        }

        let version: String
        let build: String
        let phase: Phase

        var displayVersion: String {
            if build.isEmpty || build == version {
                return version
            }
            return "\(version) (\(build))"
        }

        var sidebarTitle: String {
            switch phase {
            case .available, .downloading, .preparingToInstall:
                return "Update downloading"
            case .readyToRestart:
                return "Update ready"
            }
        }

        var sidebarSubtitle: String {
            "v\(version)"
        }

        var sidebarHelp: String {
            switch phase {
            case .available, .downloading, .preparingToInstall:
                return "Show update progress"
            case .readyToRestart:
                return "Restart Resonant to install the update"
            }
        }

        var isReadyToRestart: Bool { phase == .readyToRestart }
    }

    func relaunchForAvailableUpdate() {
        onRelaunchForUpdate?()
    }

    var recordingElapsed: TimeInterval {
        guard isRecording, let start = recordingStartedAt else { return 0 }
        return Date().timeIntervalSince(start)
    }

    private var isLocalCaptureSuppressingMeetingAutomation: Bool {
        isRecording || isStartingRecording || isFinishingCapture || hotMicManager.isActive
    }

    private enum MeetingScratchpadProcessingStageID: String {
        case determineLanguage
        case understandContext
        case identifyParticipants
        case resolveSpeakerNames
        case saveMeeting
    }

    private struct MeetingSummaryTaskHandle {
        let token: UUID
        let task: Task<Void, Never>
    }

    private static let minimumMeetingScratchpadProcessingDuration: TimeInterval = 1.2

    // MARK: - Init

    init() {
        // Inline-initialized properties are ready before this body runs.
        modelRegistry.select(id: settingsManager.selectedModelId, persistSelection: false)
        let outcomeStore = personalizationOutcomeStore
        correctionObserver = CorrectionObserver(
            dictionaryStore: dictionaryStore,
            pasteManager: pasteManager,
            personalizationLearningEngine: personalizationMemoryStore,
            outcomeRecorder: { outcome in
                await outcomeStore.finalize(
                    attemptID: outcome.deliveryAttemptID,
                    with: DeliveryPersonalizationRouter.finalization(for: outcome)
                )
            }
        )
        deliveryPersonalizationRouter = DeliveryPersonalizationRouter(
            outcomeStore: outcomeStore,
            correctionObserver: correctionObserver,
            personalizationMemoryStore: personalizationMemoryStore
        )
        personalizationOutcomeSetupCoordinator = PersonalizationOutcomeSetupCoordinator(
            dataStore: dataStore,
            outcomeStore: outcomeStore,
            controlDataSource: personalizationMemoryStore
        )
        postProcessor    = PostProcessor(dictionaryStore: dictionaryStore)
        postProcessor.formattingPreferenceProvider = personalizationMemoryStore
        dictationManager = DictationManager(
            audioRecorder: audioRecorder,
            modelRegistry: modelRegistry,
            postProcessor: postProcessor,
            contextExtractor: contextExtractor,
            personalizationLearningEngine: personalizationMemoryStore
        )
        convexClient     = ConvexClient(authManager: authManager)
        hotMicManager    = HotMicManager(postProcessor: postProcessor)
        runtimeSupportActions = AppRuntimeSupportActions(
            settingsManager: settingsManager,
            hotkeyManager: hotkeyManager,
            pasteManager: pasteManager,
            analyticsManager: analyticsManager
        )
        meetingContextDetector = MeetingContextDetector(
            contextExtractor: contextExtractor,
            settingsManager: settingsManager,
            calendarHintSource: calendarHintSource
        )
        clamshellMicrophoneSwitcher = ClamshellMicrophoneSwitcher(
            settingsManager: settingsManager,
            audioInputDeviceManager: audioInputDeviceManager
        )
        ambientContextCollector = AmbientContextCollector(
            contextExtractor: contextExtractor,
            dataStore: dataStore,
            settingsManager: settingsManager,
            activityStreamWriter: activityStreamWriter
        )
        correctionObserver.ambientFieldContentProvider = ambientContextCollector
        personalizationMemoryStore.dictionaryCasingSuppressionProvider = { [weak dictionaryStore] preferredValue in
            dictionaryStore?.hasSuppressedCasingMapping(preferredValue: preferredValue) ?? false
        }
        dictionaryStore.onWordSuppressed = { [weak personalizationMemoryStore] spoken, written in
            personalizationMemoryStore?.suppressMatchingWordCasingPreference(
                spoken: spoken,
                written: written
            )
        }
        mcpManager = MCPManager(dataStore: dataStore)
        localAPIServer = LocalAPIServer(queryEngine: WorkspaceQueryEngine(dataStore: dataStore))
        workspaceSyncEngine = WorkspaceSyncEngine(
            dataStore: dataStore,
            settingsManager: settingsManager,
            smartLinkStore: smartLinkStore,
            dictionaryStore: dictionaryStore,
            memoManager: memoManager,
            feedManager: feedManager,
            journalManager: journalManager,
            archiveWriter: archiveWriter,
            convexClient: convexClient
        )
        workspaceSyncEngine.onCloudUploadStateChange = { [weak self] state in
            self?.workspaceCloudUploadState = state
        }

        if #available(macOS 14.2, *) {
            meetingRecorderManager = MeetingRecorderManager()
        }
        audioRecorder.onWarmSessionReadyChange = { [weak self] isReady in
            self?.handleWarmSessionReadyChange(isReady)
        }

        meetingWebhookSender.configure(secretProvider: {
            await MainActor.run { SettingsManager.shared.meetingWebhookSecret }
        })

        // Last: closures capturing self require every stored property above
        // to be initialized first.
        correctionObserver.learnSuggestionSink = { [weak self] candidate in
            Task { @MainActor [weak self] in
                await self?.offerToLearnWord(candidate)
            }
        }
        dictionaryStore.onVocabularyTermsChanged = { [weak self] in
            self?.vocabularyBoostInputsDidChange()
        }
        contactNameStore.onVocabularyTermsChanged = { [weak self] in
            self?.vocabularyBoostInputsDidChange()
        }
        personalizationMemoryStore.onRecognitionBiasTermsChanged = { [weak self] in
            self?.vocabularyBoostInputsDidChange()
        }
        screenContextBiasSession.onTermsChanged = { [weak self] in
            self?.vocabularyBoostInputsDidChange()
        }
        personalizationMemoryStore.attachConsumerRuntimeContextProvider { [weak self] in
            self?.personalizationConsumerRuntimeContext ?? .unavailable
        }
    }

    // MARK: - Launch

    func launch() async {
        syncSentryRuntimeConfiguration()
        if AppFeatureVisibility.hostedServices {
            await authManager.resume()
        }
        syncSentryRuntimeConfiguration()
        analyticsManager.setup()
        let launchContext = analyticsManager.beginLaunchSession()
        syncAnalyticsIdentity()
        reconcileMeetingWebhookDestination()
        await dataStore.setup()

        // Reserve any file-backed capture before hotkeys are wired. Model
        // preparation can take long enough for a memo hotkey to arrive, and a
        // new capture must never overwrite an interrupted capture's sole
        // recovery marker during that launch window.
        await reserveInterruptedCaptureIfPresent()

        // Wire persistence-dependent managers
        await memoManager.load(from: dataStore)
        await feedManager.load(from: dataStore)
        await journalManager.load(from: dataStore, convexClient: convexClient, settingsManager: settingsManager)
        dictionaryStore.setup(store: dataStore)
        personalizationMemoryStore.setup(store: dataStore)
        await personalizationOutcomeSetupCoordinator.setupOrRetry()
        await workspaceSyncEngine.start()
        await personalizationMemoryStore.reconcileSuppressedDictionaryCasings(
            dictionaryStore.allWords
        )

        // Purge expired history entries on launch
        let expiredMeetingIDs = await dataStore.purgeOldEntries(olderThan: settingsManager.historyRetentionDays)
        await meetingWebhookSender.removeMeetings(ids: Set(expiredMeetingIDs))
        let memoLoadVerified = await memoManager.load(from: dataStore)
        if memoLoadVerified {
            await memoManager.purgeOldAudio(olderThan: settingsManager.historyRetentionDays)
        }
        await activityStreamWriter.purgeOldFiles(olderThan: settingsManager.historyRetentionDays)
        let ambientSnapshots = await dataStore.fetchInBackground(FetchDescriptor<AmbientContextSnapshot>(
            sortBy: [SortDescriptor(\.timestamp)]
        ))
        await activityStreamWriter.bootstrapAmbientFiles(from: ambientSnapshots)
        await archiveWriter.purgeOldArchive(olderThan: settingsManager.historyRetentionDays)

        // Remove empty meeting recordings (0s / 0 words)
        let purgedMeetingIDs = await dataStore.purgeEmptyMeetings()
        await meetingWebhookSender.removeMeetings(ids: Set(purgedMeetingIDs))
        for id in purgedMeetingIDs { feedManager.remove(id: id) }
        await feedManager.reload()

        await meetingWebhookSender.reconcileDestination(
            currentURL: settingsManager.meetingWebhookURL,
            isEnabled: canFireMeetingWebhooks
        )

        setupNotch()
        wireHotkeys()
        setupDispatch()
        warnIfFnTriggerCapturedByOS()
        refreshAudioInputStatus()
        installVocabularyBoostEngine()
        armVocabularyBoostEligibilityObservation()

        dictationLivePreview.onPreviewText = { [weak self] text in
            guard let self else { return }
            // Only surface preview text while the recording strip is up — a
            // late streaming update must never repaint a processing/idle notch.
            guard case .recording = self.notchCoordinator.state else { return }
            self.notchCoordinator.recordingLiveText = text.isEmpty ? nil : text
        }
        observeDefault(.liveTranscriptPreviewChanged) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.settingsManager.liveTranscriptPreviewEnabled else { return }
                await self.dictationLivePreview.unload()
            }
        }

        rewarmIfLowLatency()
        observeDefault(.lowLatencyModeChanged) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.settingsManager.lowLatencyMode {
                    self.activateLowLatencyMode()
                } else {
                    self.deactivateLowLatencyMode()
                }
            }
        }

        observeDefault(.sentryDiagnosticsConfigurationChanged) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncSentryRuntimeConfiguration()
            }
        }

        observeDefault(DictionaryStore.didAutoLearnWordNotification) { [weak self] notification in
            let written = notification.userInfo?["written"] as? String
            Task { @MainActor [weak self] in
                self?.analyticsManager.capture("dictionary_word_auto_learned", properties: [
                    "written_length": written?.count ?? 0
                ])
                self?.showOrQueueLearnedWordNotice(written: written)
            }
        }

        showPrimaryWindow()
        analyticsManager.capture("app_launched", properties: [
            "analytics_enabled": settingsManager.analyticsEnabled,
            "cloud_processing_enabled": settingsManager.cloudProcessingEnabled,
            "hot_mic_enabled": settingsManager.hotMicEnabled,
            "hotkey_mode": settingsManager.hotkeyMode.rawValue,
            "is_first_launch": launchContext.isFirstLaunch,
            "onboarding_completed": settingsManager.onboardingCompleted,
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
            "was_quarantined": Self.appWasQuarantined(),
        ])
        if launchContext.isNewDay {
            var dailyActiveProperties: [String: Any] = [:]
            if let daysSinceInstall = launchContext.daysSinceInstall {
                dailyActiveProperties["days_since_install"] = daysSinceInstall
            }
            analyticsManager.capture("daily_active", properties: dailyActiveProperties)
        }
        if settingsManager.onboardingCompleted {
            if modelRegistry.active?.isDownloaded != true {
                notchCoordinator.showError("Speech model not installed — choose Download in Settings.", subtype: .model)
            } else {
                do {
                    showModelWarming(detail: nil)
                    try await modelRegistry.prepareActive(source: .appLaunch) { stage, progress in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            if case .notice = self.notchCoordinator.state {
                                self.showModelWarming(detail: Self.warmingDetail(stage: stage, progress: progress))
                            }
                        }
                    }
                    let recoveredInterruptedCapture = await recoverInterruptedCaptureIfNeeded()
                    if !recoveredInterruptedCapture {
                        notchCoordinator.showDone("Local model ready", timeout: .seconds(3.5))
                    }

                    if settingsManager.hotMicEnabled {
                        // Let the ready check breathe before hot mic claims the strip.
                        try? await Task.sleep(for: .milliseconds(1200))
                        await startHotMic()
                    }
                } catch {
                    SentryManager.shared.captureException(error, context: ["source": "AppState.launch.prepareActive"])
                    notchCoordinator.showError("Model failed to load", subtype: .model)
                }
            }
        }

        observeDefault(.hotMicEnabledChanged) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.analyticsManager.capture("hotmic_toggled", properties: [
                    "enabled": self.settingsManager.hotMicEnabled
                ])
                if self.settingsManager.hotMicEnabled {
                    await self.startHotMic()
                } else {
                    await self.stopHotMic()
                }
            }
        }

        // MCP server
        syncMCPServerState(removeManagedConfigurationWhenDisabled: false)
        observeDefault(.mcpServerEnabledChanged) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncMCPServerState(removeManagedConfigurationWhenDisabled: true)
            }
        }

        // Local API server
        syncLocalAPIState(cleanUpWhenDisabled: false)
        observeDefault(.localAPIEnabledChanged) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncLocalAPIState(cleanUpWhenDisabled: true)
            }
        }
        observeDefault(.historyRetentionDaysChanged) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.purgeExpiredHistoryForCurrentSetting()
            }
        }

        // Ambient context collector
        syncAmbientContextState()
        for name: Notification.Name in [.ambientContextEnabledChanged, .sentryDiagnosticsConfigurationChanged, .contextMetadataEnabledChanged] {
            observeDefault(name) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.syncAmbientContextState()
                }
            }
        }

        // Meeting recording
        if let manager = meetingRecorderManager {
            wireMeetingRecorder(manager)
            wireMeetingContextDetector()
            syncMeetingDetectionState()
            if settingsManager.meetingRecordingEnabled, settingsManager.meetingJoinPromptEnabled {
                await ensureMeetingPromptAuthorization()
            }
            if settingsManager.meetingRecordingEnabled, settingsManager.meetingUseCalendarHints {
                await ensureMeetingCalendarAuthorization()
            }
            syncMeetingCalendarPromptSchedule()
            let meetingRecovery = await manager.recoverOrphanedSessions(dataStore: dataStore, archiveWriter: archiveWriter)
            await feedManager.reload()
            if meetingRecovery.recoveredCount > 0 {
                workspaceSyncEngine.markExportNeeded()
                let recoveredLabel = meetingRecovery.recoveredCount == 1 ? "meeting" : "meetings"
                notchCoordinator.showNotice(
                    NotchOverlayState.Notice(
                        title: "Recovered \(meetingRecovery.recoveredCount) \(recoveredLabel)",
                        detail: "Saved \(meetingRecovery.recoveredWordCount) words to your workspace.",
                        icon: "arrow.counterclockwise"
                    ),
                    timeout: .seconds(7)
                )
            }
        }

        observeDefault(.EKEventStoreChanged) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleMeetingCalendarStoreChanged()
            }
        }

        observeDefault(.meetingRecordingEnabledChanged) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.handleMeetingRecordingEnabledChanged()
            }
        }

        observeDefault(.meetingJoinPromptEnabledChanged) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.syncMeetingDetectionState()
                if self.settingsManager.meetingRecordingEnabled,
                   self.settingsManager.meetingJoinPromptEnabled {
                    await self.ensureMeetingPromptAuthorization()
                    await self.refreshMeetingDetection()
                } else {
                    self.meetingPromptNotifier.clearPrompt()
                }
                self.syncMeetingCalendarPromptSchedule()
            }
        }

        observeDefault(.meetingCalendarHintsEnabledChanged) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.syncMeetingDetectionState()
                if self.settingsManager.meetingRecordingEnabled,
                   self.settingsManager.meetingUseCalendarHints {
                    await self.ensureMeetingCalendarAuthorization()
                }
                self.syncMeetingCalendarPromptSchedule()
                await self.refreshMeetingDetection()
            }
        }

        for name: Notification.Name in [.meetingAutoStartEnabledChanged, .meetingAutoStopEnabledChanged] {
            observeDefault(name) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.syncMeetingDetectionState()
                    await self.syncMeetingAutomationSettings()
                }
            }
        }

        observeDefault(.meetingTimelineAutoRecordEventIDsChanged) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.syncMeetingDetectionState()
                await self.refreshMeetingDetection()
            }
        }

        observeDefault(.workspaceRoamingSettingsChanged) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.workspaceSyncEngine.markExportNeeded(roamingSettingsChanged: true)
                await self?.workspaceSyncEngine.flushPendingExport()
            }
        }

        // Release audio hardware on sleep so macOS can actually sleep
        let wsCenter = NSWorkspace.shared.notificationCenter
        notificationObservers.observe(
            NSWorkspace.willSleepNotification, center: wsCenter
        ) { [weak self] _ in
            // NotificationObserverRegistry delivers on OperationQueue.main.
            // Publish the sleep veto synchronously; only awaited cleanup moves
            // into a Task so no finalizer can rewarm in the handoff gap.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.prepareForSystemSleep()
                self.systemPowerTransitionCoordinator.enqueue { [weak self] stillOwnsTransition in
                    await self?.finishSystemSleepPreparation(
                        stillOwnsTransition: stillOwnsTransition
                    )
                }
            }
        }
        notificationObservers.observe(
            NSWorkspace.didWakeNotification, center: wsCenter
        ) { [weak self] _ in
            // Generation invalidation and the recovery deadline must be visible
            // in this notification turn, before any runnable finalizer.
            MainActor.assumeIsolated {
                guard let self, !self.isShuttingDown else { return }
                self.prepareForSystemWake()
                self.systemPowerTransitionCoordinator.enqueue { [weak self] stillOwnsTransition in
                    await self?.finishSystemWakePreparation(
                        stillOwnsTransition: stillOwnsTransition
                    )
                }
            }
        }

        // CoreAudio hot-plug: invalidate warm session and refresh routing UI
        // so the next recording binds to a still-present device.
        audioInputDeviceManager.onHardwareChange = { [weak self] in
            guard let self else { return }
            self.beginAudioHardwareRecovery()
            self.refreshAudioInputStatus()
            self.clamshellMicrophoneSwitcher.reevaluateAfterDeviceChange()
            self.rewarmIfLowLatency()
        }

        clamshellMicrophoneSwitcher.onSelectionChanged = { [weak self] in
            self?.didChangeInputSelection()
        }
        clamshellMicrophoneSwitcher.onAutomaticSwitch = { [weak self] previousDevice, newDevice in
            guard let self else { return }
            let notifier = self.microphoneSwitchNotifier
            Task {
                await notifier.deliverClamshellSwitchNotice(
                    from: previousDevice.name,
                    to: newDevice.name
                )
            }
        }
        if settingsManager.clamshellMicSwitchEnabled {
            clamshellMicrophoneSwitcher.start()
        }
        observeDefault(.clamshellMicSwitchEnabledChanged) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.settingsManager.clamshellMicSwitchEnabled {
                    self.clamshellMicrophoneSwitcher.start()
                } else {
                    self.clamshellMicrophoneSwitcher.stop()
                }
            }
        }
    }

    private func presentMeetingCompanion(
        manager: MeetingRecorderManager,
        onStartDetected: @escaping () -> Void = {},
        onDismissDetected: @escaping () -> Void = {},
        onClose: (() -> Void)? = nil
    ) {
        meetingScratchpadWindowController.show(
            state: meetingCompanionState,
            manager: manager,
            notepad: manager.notepad,
            onStop: { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.stopMeetingRecording()
                }
            },
            onStartDetected: onStartDetected,
            onDismissDetected: onDismissDetected,
            microphoneOptions: audioInputDeviceManager.devices,
            selectedMicrophoneUID: settingsManager.meetingUseSelectedMicrophone ? settingsManager.inputDeviceUID : nil,
            onSelectMicrophone: { [weak self] uid in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let uid {
                        self.settingsManager.meetingUseSelectedMicrophone = true
                        self.settingsManager.inputDeviceUID = uid
                    } else {
                        self.settingsManager.meetingUseSelectedMicrophone = false
                    }
                    manager.switchMicrophoneInput(to: uid)
                    let name = uid.flatMap { self.audioInputDeviceManager.device(with: $0)?.name } ?? "system default"
                    self.meetingCompanionState.updateAudioHealth("Switching meeting microphone to \(name).")
                }
            },
            onOpenAudioSettings: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.showPrimaryWindow(selectedTab: .meetingSettings)
                }
            },
            onClose: onClose
        )
    }

    @discardableResult
    private func recoverInterruptedCaptureIfNeeded() async -> Bool {
        let loadResult = await recoveryStore.loadActiveCaptureResult()
        let recovery: ActiveCaptureRecovery
        switch loadResult {
        case .missing:
            hasUnreadableActiveCaptureRecovery = false
            return false
        case .loaded(let loadedRecovery):
            hasUnreadableActiveCaptureRecovery = false
            recovery = loadedRecovery
        case .unreadable:
            hasUnreadableActiveCaptureRecovery = true
            notchCoordinator.showNotice(
                NotchOverlayState.Notice(
                    title: "Recovery metadata needs attention",
                    detail: "Resonant preserved the recording because its recovery marker could not be read.",
                    icon: "exclamationmark.arrow.triangle.2.circlepath"
                ),
                timeout: .seconds(7)
            )
            return true
        }
        activeCaptureRecoveryID = recovery.id
        let audioURL = recovery.audioURL

        // Cancellation that raced a memo insert is itself a durable
        // transaction. Finish the requested rollback before considering any
        // ASR recovery, then remove the sole source only after delete evidence.
        if recovery.pendingDisposition == .discard {
            let rollbackCommitted: Bool
            if let pendingEntryID = recovery.pendingEntryID {
                switch recovery.kind {
                case .memo:
                    var descriptor = FetchDescriptor<MemoEntry>(
                        predicate: #Predicate { $0.id == pendingEntryID }
                    )
                    descriptor.fetchLimit = 1
                    do {
                        if let memo = try dataStore.fetchForRecovery(descriptor).first {
                            rollbackCommitted = await memoManager.rollback(memo)
                        } else if recovery.shouldPersistAudio == true {
                            rollbackCommitted = await MemoManager.removePersistedAudioForRecovery(
                                memoID: pendingEntryID,
                                sourceURL: audioURL
                            )
                        } else {
                            rollbackCommitted = true
                        }
                    } catch {
                        rollbackCommitted = false
                    }
                case .dictation:
                    var descriptor = FetchDescriptor<DictationEntry>(
                        predicate: #Predicate { $0.id == pendingEntryID }
                    )
                    descriptor.fetchLimit = 1
                    do {
                        if let entry = try dataStore.fetchForRecovery(descriptor).first {
                            rollbackCommitted = await dataStore.delete(entry)
                        } else {
                            rollbackCommitted = true
                        }
                    } catch {
                        rollbackCommitted = false
                    }
                }
            } else {
                rollbackCommitted = true
            }

            guard rollbackCommitted else {
                notchCoordinator.showNotice(
                    NotchOverlayState.Notice(
                        title: "Cancellation cleanup pending",
                        detail: "The recording is safe; Resonant will retry the cancelled-entry cleanup next launch.",
                        icon: "exclamationmark.arrow.triangle.2.circlepath"
                    ),
                    timeout: .seconds(7)
                )
                return true
            }
            await clearOwnedActiveCapture(id: recovery.id)
            cleanupTemporaryRecording(at: audioURL)
            return false
        }

        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            await clearOwnedActiveCapture(id: recovery.id)
            return false
        }

        if recovery.kind == .memo, let pendingEntryID = recovery.pendingEntryID {
            var descriptor = FetchDescriptor<MemoEntry>(
                predicate: #Predicate { $0.id == pendingEntryID }
            )
            descriptor.fetchLimit = 1
            let existingMemo: MemoEntry?
            do {
                existingMemo = try dataStore.fetchForRecovery(descriptor).first
            } catch {
                notchCoordinator.showNotice(
                    NotchOverlayState.Notice(
                        title: "Recovery still pending",
                        detail: "Resonant could not verify memo history yet; no recording was removed.",
                        icon: "exclamationmark.arrow.triangle.2.circlepath"
                    ),
                    timeout: .seconds(7)
                )
                return true
            }
            if let existingMemo {
                let shouldPersistAudio = recovery.shouldPersistAudio == true
                let requiresAudioRepair = shouldPersistAudio
                    && memoManager.audioURL(for: existingMemo) == nil
                if requiresAudioRepair {
                    let memoID = existingMemo.id
                    let repairedPath = await Task.detached(priority: .utility) {
                        MemoManager.persistAudioOffMain(
                            from: audioURL,
                            memoID: memoID,
                            removeSourceAfterCopy: false
                        )
                    }.value
                    guard let repairedPath else {
                        notchCoordinator.showNotice(
                            NotchOverlayState.Notice(
                                title: "Recovery still pending",
                                detail: "Your memo text is safe; the audio copy will be retried next launch.",
                                icon: "exclamationmark.arrow.triangle.2.circlepath"
                            ),
                            timeout: .seconds(7)
                        )
                        return true
                    }
                    existingMemo.audioPath = repairedPath
                    guard dataStore.saveChanges() else {
                        return true
                    }
                }
                _ = await archiveWriter.writeMemo(memo: existingMemo)
                guard await activityStreamWriter.writeMemoEvent(memo: existingMemo) else {
                    return true
                }
                workspaceSyncEngine.markExportNeeded()
                await clearOwnedActiveCapture(id: recovery.id)
                cleanupTemporaryRecording(at: audioURL)
                return false
            }
        }

        // A crash can land after the SwiftData row commits but before the
        // capture marker is removed. Reuse the intended entry ID to avoid
        // retranscribing/duplicating a durable dictation, and repair a pending
        // audio archive copy in place when necessary.
        if recovery.kind == .dictation, let pendingEntryID = recovery.pendingEntryID {
            var descriptor = FetchDescriptor<DictationEntry>(
                predicate: #Predicate { $0.id == pendingEntryID }
            )
            descriptor.fetchLimit = 1
            let existingEntry: DictationEntry?
            do {
                existingEntry = try dataStore.fetchForRecovery(descriptor).first
            } catch {
                notchCoordinator.showNotice(
                    NotchOverlayState.Notice(
                        title: "Recovery still pending",
                        detail: "Resonant could not verify dictation history yet; no recording was removed.",
                        icon: "exclamationmark.arrow.triangle.2.circlepath"
                    ),
                    timeout: .seconds(7)
                )
                return true
            }
            if let existingEntry {
                let requiresAudioRepair = recovery.shouldPersistAudio == true
                    && !persistedAudioExists(at: existingEntry.audioPath)
                if requiresAudioRepair {
                    let archiveResult = await archiveWriter.writeDictation(
                        entry: existingEntry,
                        rawTranscript: existingEntry.rawTranscript,
                        deliveredText: existingEntry.deliveredText,
                        recordingURL: audioURL
                    )
                    let updated = dataStore.saveChanges()
                    guard archiveResult.didCopyRecordingToArchive && updated else {
                        notchCoordinator.showNotice(
                            NotchOverlayState.Notice(
                                title: "Recovery still pending",
                                detail: "Your dictation text is safe; the audio copy will be retried next launch.",
                                icon: "exclamationmark.arrow.triangle.2.circlepath"
                            ),
                            timeout: .seconds(7)
                        )
                        return true
                    }
                }
                guard await activityStreamWriter.writeRecoveredDictationEvent(
                    entry: existingEntry
                ) else {
                    return true
                }
                scheduleJournalGeneration(for: existingEntry.date)
                workspaceSyncEngine.markExportNeeded()
                await clearOwnedActiveCapture(id: recovery.id)
                cleanupTemporaryRecording(at: audioURL)
                return false
            }
        }

        guard let transcriber = modelRegistry.active else {
            notchCoordinator.showNotice(
                NotchOverlayState.Notice(
                    title: "Recovery pending",
                    detail: "An interrupted recording was found, but the local model is not ready yet.",
                    icon: "arrow.counterclockwise"
                ),
                timeout: .seconds(7)
            )
            return true
        }

        let label = recovery.kind == .memo ? "memo" : "dictation"
        notchCoordinator.setState(.processing(progress: 0, stage: "Recovering \(label)..."))

        do {
            await recordUnsupportedVocabularyBoostAdapterAttemptIfNeeded()
            let language = settingsManager.transcriptionLanguage
            let rawText = try await transcriber.transcribe(audioURL: audioURL, language: language)
            var text = await postProcessor.process(rawText)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedRawText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty, !normalizedRawText.isEmpty {
                // Post-processing must never erase the only recovered evidence.
                text = normalizedRawText
            }

            guard !text.isEmpty else {
                // A marker with an intended entry ID proves the original
                // pipeline had non-empty text and began persistence. Never let
                // one model-dependent empty replay destroy that transaction.
                let confirmedSilent: Bool
                if recovery.pendingEntryID != nil {
                    confirmedSilent = false
                } else if let diagnostics = try? DictationAudioAnalyzer.preTranscriptionGateDiagnostics(
                    audioURL: audioURL
                ) {
                    confirmedSilent = DictationAudioAnalyzer
                        .shouldRejectBeforeTranscription(diagnostics)
                } else {
                    confirmedSilent = false
                }

                if confirmedSilent {
                    cleanupTemporaryRecording(at: audioURL)
                    await clearOwnedActiveCapture(id: recovery.id)
                    notchCoordinator.showNotice(
                        NotchOverlayState.Notice(
                            title: "Interrupted recording cleared",
                            detail: "Audio analysis confirmed that the capture contained no speech.",
                            icon: "waveform"
                        ),
                        timeout: .seconds(6)
                    )
                } else {
                    notchCoordinator.showNotice(
                        NotchOverlayState.Notice(
                            title: "Recovery still pending",
                            detail: "No words were recovered this time, so the original recording was preserved.",
                            icon: "exclamationmark.arrow.triangle.2.circlepath"
                        ),
                        timeout: .seconds(7)
                    )
                }
                return true
            }

            let captureDiagnostics = try? TranscriberAudioSupport.captureDiagnostics(from: audioURL)
            let duration = captureDiagnostics?.duration ?? recovery.elapsedDuration

            switch recovery.kind {
            case .memo:
                let memoID = recovery.pendingEntryID ?? UUID()
                let memoDate = recovery.pendingEntryDate ?? recovery.startedAt
                let shouldPersistAudio = recovery.shouldPersistAudio
                    ?? settingsManager.saveAudioEnabled
                guard await prepareOwnedActiveCaptureForPersistence(
                    id: recovery.id,
                    entryID: memoID,
                    entryDate: memoDate,
                    shouldPersistAudio: shouldPersistAudio
                ) else {
                    return true
                }
                let saveResult = await memoManager.save(
                    id: memoID,
                    date: memoDate,
                    text: text,
                    duration: duration,
                    recordingURL: audioURL,
                    shouldPersistAudio: shouldPersistAudio
                )
                let memo = saveResult.memo
                _ = await archiveWriter.writeMemo(memo: memo)
                let coreCommitted = saveResult.dataStoreCommitted
                    && saveResult.didPersistRequestedAudio
                let activityCommitted: Bool
                if coreCommitted {
                    activityCommitted = await activityStreamWriter.writeMemoEvent(memo: memo)
                } else {
                    activityCommitted = false
                }
                guard coreCommitted, activityCommitted else {
                    notchCoordinator.showNotice(
                        NotchOverlayState.Notice(
                            title: "Recovery still pending",
                            detail: "The memo recording is safe, but Resonant could not finish saving it yet.",
                            icon: "exclamationmark.arrow.triangle.2.circlepath"
                        ),
                        timeout: .seconds(7)
                    )
                    return true
                }
                feedManager.record(memo)
                workspaceSyncEngine.markExportNeeded()
                await clearOwnedActiveCapture(id: recovery.id)
                cleanupTemporaryRecording(at: audioURL)
                selectedSettingsTab = .home
                selectedFeedItemID = memo.id
                analyticsManager.capture("interrupted_capture_recovered", properties: [
                    "kind": recovery.kind.rawValue,
                    "word_count": text.split(separator: " ").count
                ])
                notchCoordinator.showNotice(
                    NotchOverlayState.Notice(
                        title: "Recovered memo saved",
                        detail: "Saved \(text.split(separator: " ").count) words to your workspace.",
                        icon: "arrow.counterclockwise"
                    ),
                    timeout: .seconds(7)
                )
            case .dictation:
                let copiedToClipboard = pasteManager.copy(text: text)
                let result = TranscriptionResult(
                    text: text,
                    rawTranscript: rawText,
                    duration: duration,
                    captureDiagnostics: captureDiagnostics,
                    recordingURL: audioURL,
                    selectedText: nil,
                    selectedRange: nil,
                    targetApp: recovery.targetAppName,
                    targetBundleId: recovery.targetBundleId,
                    windowTitle: recovery.windowTitle,
                    browserURL: recovery.browserURL,
                    codeFileName: nil,
                    slackRecipient: nil,
                    focusedFieldContent: nil,
                    visibleTextSnippets: nil
                )
                let entry = DictationEntry.make(
                    id: recovery.pendingEntryID ?? UUID(),
                    text: text,
                    context: result.capturedContext,
                    wordCount: text.split(separator: " ").count,
                    duration: duration,
                    mode: .dictation,
                    date: recovery.pendingEntryDate ?? recovery.startedAt,
                    rawTranscript: rawText == text ? nil : rawText,
                    autoPasted: false,
                    copiedToClipboard: copiedToClipboard,
                    autoSent: false
                )
                let shouldPersistAudio = recovery.shouldPersistAudio
                    ?? settingsManager.saveAudioEnabled
                guard await prepareOwnedActiveCaptureForPersistence(
                    id: recovery.id,
                    entryID: entry.id,
                    entryDate: entry.date,
                    shouldPersistAudio: shouldPersistAudio
                ) else {
                    return true
                }
                let committed = await persistCompletedDictation(
                    entry: entry,
                    result: result,
                    resolvedText: text,
                    deliveredText: nil,
                    autoPasted: false,
                    autoSent: false,
                    copiedToClipboard: copiedToClipboard,
                    includeContextMetadata: settingsManager.contextMetadataEnabled,
                    shouldPersistAudio: shouldPersistAudio
                )
                guard committed else {
                    notchCoordinator.showNotice(
                        NotchOverlayState.Notice(
                            title: "Recovery still pending",
                            detail: "The recording is safe, but Resonant could not finish saving it yet.",
                            icon: "exclamationmark.arrow.triangle.2.circlepath"
                        ),
                        timeout: .seconds(7)
                    )
                    return true
                }
                await clearOwnedActiveCapture(id: recovery.id)
                selectedSettingsTab = .home
                selectedFeedItemID = entry.id
                analyticsManager.capture("interrupted_capture_recovered", properties: [
                    "kind": recovery.kind.rawValue,
                    "copied_to_clipboard": copiedToClipboard,
                    "word_count": entry.wordCount
                ])
                notchCoordinator.showNotice(
                    NotchOverlayState.Notice(
                        title: "Recovered dictation",
                        detail: copiedToClipboard
                            ? "Copied to clipboard and saved \(entry.wordCount) words to your workspace."
                            : "Saved \(entry.wordCount) words to your workspace.",
                        icon: "arrow.counterclockwise"
                    ),
                    timeout: .seconds(7)
                )
            }

            return true
        } catch {
            SentryManager.shared.captureException(error, context: ["source": "AppState.recoverInterruptedCaptureIfNeeded"])
            analyticsManager.capture("interrupted_capture_recovery_failed", properties: [
                "kind": recovery.kind.rawValue,
                "error_type": analyticsErrorType(error)
            ])
            // Transcriber/model failures can be transient. Preserve the sole
            // source audio and marker rather than turning one bad launch into
            // permanent data loss.
            notchCoordinator.showNotice(
                NotchOverlayState.Notice(
                    title: "Could not recover interrupted \(label)",
                    detail: "The recording is still safe and recovery will retry next launch.",
                    icon: "exclamationmark.arrow.triangle.2.circlepath"
                ),
                timeout: .seconds(7)
            )
            return true
        }
    }

    private func reserveInterruptedCaptureIfPresent() async {
        switch await recoveryStore.loadActiveCaptureResult() {
        case .missing:
            hasUnreadableActiveCaptureRecovery = false
            await recoveryStore.purgeOrphanedCaptureFiles(keepingAudioPath: nil)
        case .loaded(let recovery):
            hasUnreadableActiveCaptureRecovery = false
            activeCaptureRecoveryID = recovery.id
            await recoveryStore.purgeOrphanedCaptureFiles(
                keepingAudioPath: recovery.audioPath
            )
        case .unreadable:
            // The unreadable marker may still be the only link to a valid CAF.
            // Do not purge or admit a new capture until the user explicitly
            // clears workspace data or the marker becomes readable.
            hasUnreadableActiveCaptureRecovery = true
        }
    }

    private func presentDetectedMeetingCompanion(
        _ detectedMeeting: MeetingContextDetector.DetectedMeeting,
        manager: MeetingRecorderManager
    ) {
        meetingCompanionState.showDetected(detectedMeeting)
        presentMeetingCompanion(
            manager: manager,
            onStartDetected: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.meetingCompanionState.beginStarting(
                        origin: .prompt,
                        title: detectedMeeting.calendarHint?.title,
                        detectedAppName: detectedMeeting.app.name,
                        subtitle: "Started from detection prompt"
                    )
                    self.meetingScratchpadWindowController.setExpanded(true)
                    await self.startMeetingRecording(
                        detectedApp: detectedMeeting.app,
                        lifecycleMeeting: detectedMeeting,
                        recordingOriginOverride: .promptAccepted,
                        startOrigin: .prompt
                    )
                }
            },
            onDismissDetected: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.dismissMeetingPrompt(for: detectedMeeting)
                    self?.meetingScratchpadWindowController.close()
                }
            },
            onClose: { [weak self] in
                // The header X in detection mode should suppress the same
                // re-prompt cycle as the explicit "Not now" button. Without
                // this, closing via X dismisses the panel but leaves the
                // detector free to re-prompt immediately.
                Task { @MainActor [weak self] in
                    self?.dismissMeetingPrompt(for: detectedMeeting)
                    self?.meetingScratchpadWindowController.close()
                }
            }
        )
        meetingScratchpadWindowController.setExpanded(false, animated: false)
    }

    private func wireMeetingRecorder(_ manager: MeetingRecorderManager) {
        manager.onSessionStarted = { [weak self] session in
            guard let self else { return }
            self.cancelPendingMeetingAutoStop()
            let backendAtStart = session.transcriptionBackendAtStart
            self.meetingBackendAtStart[session.id] = backendAtStart
            self.analyticsManager.capture("meeting_recording_started", properties: [
                "app_name": session.detectedApp?.name ?? "unknown",
                "origin": session.captureContext?.recordingOrigin.rawValue ?? "manual",
                "capture_mode": session.captureMode.rawValue,
                "backend": backendAtStart,
                "is_calendar_backed": session.captureContext?.isCalendarBacked ?? false
            ])

            // Imports don't capture live audio — emit analytics + persist the
            // backend snapshot but skip the recording UX (scratchpad, hot-mic
            // pause, start sound, notch state). The completion path creates
            // the MeetingEntry on its own.
            if session.captureContext?.recordingOrigin == .importedAudio {
                return
            }

            let sessionID = session.id
            let startedAt = session.startedAt
            let detectedAppName = session.detectedApp?.name
            let suggestedTitle = session.suggestedTitle
            let jsonlRelativePath = session.jsonlRelativePath
            let captureContext = session.captureContext
            let initialSpeakers: [MeetingSpeaker] = session.captureMode == .room ? [] : [.you, .them]
            let initialSpeakerAliases = self.meetingSpeakerAliases(
                speakers: initialSpeakers,
                captureContext: captureContext
            )
            _ = await self.dataStore.performBackgroundWrite { context in
                let entry = MeetingEntry(
                    id: sessionID,
                    startedAt: startedAt,
                    detectedApp: detectedAppName,
                    customTitle: suggestedTitle,
                    durationSeconds: 0,
                    wordCount: 0,
                    activeJSONLPath: jsonlRelativePath
                )
                entry.applyCaptureContext(captureContext)
                entry.speakerAliases = initialSpeakerAliases
                context.insert(entry)
            }
            let activeEntry = self.dataStore.meetingEntry(id: sessionID)
            self.meetingNoteAutosaver.configure(
                sessionID: sessionID,
                notepad: manager.notepad
            )
            if self.canFireMeetingWebhooks,
               !self.settingsManager.meetingWebhookURL.isEmpty {
                let sender = self.meetingWebhookSender
                let snapshot = activeEntry.map(sender.snapshotEntry)
                let webhookURL = self.settingsManager.meetingWebhookURL
                if let snapshot {
                    Task {
                        await sender.enqueueStarted(
                            session: session,
                            entrySnapshot: snapshot,
                            webhookURL: webhookURL
                        )
                    }
                }
            }
            self.meetingPromptNotifier.clearPrompt()
            if self.hotMicManager.isActive {
                await self.hotMicManager.pause()
            }
            await self.dictationMediaController.pausePlaybackIfNeeded(
                enabled: self.settingsManager.pauseMediaWhileRecording
            )
            self.notchCoordinator.isMeetingRecording = false
            self.notchCoordinator.meetingDetectedApp = nil
            self.notchCoordinator.meetingElapsed = 0
            self.meetingCompanionState.markRecording(session: session)
            self.presentMeetingCompanion(manager: manager)
        }
        manager.onSessionEnded = { [weak self] completed in
            guard let self else { return }
            self.cancelPendingMeetingAutoStop()
            self.meetingNoteAutosaver.stop(for: manager.notepad)
            self.activeMeetingLifecycleContext = nil
            self.currentMeetingSystemTransport = nil
            self.hasWarnedBluetoothThisSession = false
            self.meetingContextDetector.stopLifecycleTracking()
            self.updateMeetingScratchpadProcessing(
                manager.notepad,
                stage: .determineLanguage,
                status: .complete,
                detail: "Audio capture stopped. Building context now."
            )
            self.updateMeetingScratchpadProcessing(
                manager.notepad,
                stage: .understandContext,
                status: .active,
                detail: "Understanding the shape of the conversation."
            )

            // Run utterances through the standard post-processing pipeline
            // (filler removal, ITN, dictionary corrections, formatting)
            let cleanedUtterances = await self.cleanupMeetingUtterances(completed.utterances)
            self.updateMeetingScratchpadProcessing(
                manager.notepad,
                stage: .understandContext,
                status: .complete,
                detail: "Context understood. Identifying the participants."
            )
            self.updateMeetingScratchpadProcessing(
                manager.notepad,
                stage: .identifyParticipants,
                status: .active,
                detail: "Matching speakers and meeting metadata."
            )
            let persistedSpeakerAliases = completed.speakerAliases.isEmpty
                ? self.dataStore.meetingEntry(id: completed.id)?.speakerAliases ?? [:]
                : completed.speakerAliases
            let speakerAliases = self.meetingSpeakerAliases(
                existing: persistedSpeakerAliases,
                speakers: cleanedUtterances.map(\.speaker),
                captureContext: completed.captureContext
            )
            let cleaned = CompletedMeetingSession(
                id: completed.id,
                startedAt: completed.startedAt,
                endedAt: completed.endedAt,
                detectedApp: completed.detectedApp,
                suggestedTitle: completed.suggestedTitle,
                captureContext: completed.captureContext,
                speakerAliases: speakerAliases,
                utterances: cleanedUtterances,
                liveNotes: completed.liveNotes,
                postMeetingNotes: completed.postMeetingNotes,
                recordingURL: completed.recordingURL,
                shouldDeleteRecordingAfterSave: completed.shouldDeleteRecordingAfterSave
            )
            self.updateMeetingScratchpadProcessing(
                manager.notepad,
                stage: .identifyParticipants,
                status: .complete,
                detail: "Participants identified. Resolving how to refer to people."
            )
            self.updateMeetingScratchpadProcessing(
                manager.notepad,
                stage: .resolveSpeakerNames,
                status: .active,
                detail: "Applying participant names and speaker labels."
            )
            self.updateMeetingScratchpadProcessing(
                manager.notepad,
                stage: .resolveSpeakerNames,
                status: .complete,
                detail: "Speaker labels resolved. Saving transcript and notes."
            )
            self.updateMeetingScratchpadProcessing(
                manager.notepad,
                stage: .saveMeeting,
                status: .active
            )

            let archiveEntry = MeetingEntry(
                id: cleaned.id,
                startedAt: cleaned.startedAt
            )
            archiveEntry.startedAt = cleaned.startedAt
            archiveEntry.endedAt = cleaned.endedAt
            archiveEntry.detectedApp = cleaned.detectedApp?.name
            archiveEntry.customTitle = cleaned.suggestedTitle
            archiveEntry.durationSeconds = cleaned.durationSeconds
            archiveEntry.wordCount = cleaned.wordCount
            archiveEntry.activeJSONLPath = nil
            archiveEntry.userNotes = cleaned.liveNotes.isEmpty ? nil : cleaned.liveNotes
            archiveEntry.postMeetingNotes = cleaned.postMeetingNotes.isEmpty ? nil : cleaned.postMeetingNotes
            archiveEntry.applyCaptureContext(cleaned.captureContext)
            archiveEntry.speakerAliases = cleaned.speakerAliases
            let archiveWrite = await self.archiveWriter.writeMeeting(session: cleaned, entry: archiveEntry)
            let meetingID = cleaned.id
            let endedAt = cleaned.endedAt
            let detectedApp = cleaned.detectedApp?.name
            let customTitle = cleaned.suggestedTitle
            let durationSeconds = cleaned.durationSeconds
            let wordCount = cleaned.wordCount
            let userNotes = cleaned.liveNotes.isEmpty ? nil : cleaned.liveNotes
            let postMeetingNotes = cleaned.postMeetingNotes.isEmpty ? nil : cleaned.postMeetingNotes
            let audioPath = archiveEntry.audioPath
            let markdownPath = archiveEntry.markdownPath
            let captureContext = cleaned.captureContext
            _ = await self.dataStore.performBackgroundWrite { context in
                var descriptor = FetchDescriptor<MeetingEntry>(
                    predicate: #Predicate { $0.id == meetingID }
                )
                descriptor.fetchLimit = 1
                let entry: MeetingEntry
                if let existing = try? context.fetch(descriptor).first {
                    entry = existing
                } else {
                    entry = MeetingEntry(id: meetingID, startedAt: cleaned.startedAt)
                    context.insert(entry)
                }
                entry.startedAt = cleaned.startedAt
                entry.endedAt = endedAt
                entry.detectedApp = detectedApp
                entry.customTitle = customTitle
                entry.durationSeconds = durationSeconds
                entry.wordCount = wordCount
                entry.activeJSONLPath = nil
                entry.userNotes = userNotes
                entry.postMeetingNotes = postMeetingNotes
                entry.audioPath = audioPath
                entry.markdownPath = markdownPath
                entry.applyCaptureContext(captureContext)
                entry.speakerAliases = cleaned.speakerAliases
            }
            self.meetingDataVersion &+= 1
            let backendAtStart = self.meetingBackendAtStart.removeValue(forKey: cleaned.id)
                ?? self.settingsManager.meetingTranscriptionBackend.rawValue
            guard let entry = self.dataStore.meetingEntry(id: meetingID) else {
                manager.notepad.resetProcessing()
                self.meetingScratchpadWindowController.close()
                return
            }
            let didCopyRecordingToArchive = archiveWrite.didCopyRecordingToArchive
            if cleaned.shouldDeleteRecordingAfterSave,
               let recordingURL = cleaned.recordingURL,
               didCopyRecordingToArchive {
                self.cleanupTemporaryRecording(at: recordingURL)
            }
            await self.activityStreamWriter.writeMeetingEvent(entry: entry, transcript: cleaned.transcriptText)
            self.feedManager.record(entry)
            self.workspaceSyncEngine.markExportNeeded()
            self.updateMeetingScratchpadProcessing(
                manager.notepad,
                stage: .saveMeeting,
                status: .complete,
                detail: "Meeting saved."
            )
            await self.ensureMinimumMeetingScratchpadProcessingDuration(manager.notepad)
            self.resumeMediaAfterRecording()
            self.notchCoordinator.isMeetingRecording = false
            self.notchCoordinator.meetingDetectedApp = nil
            self.notchCoordinator.meetingElapsed = 0
            manager.notepad.resetProcessing()
            self.meetingCompanionState.markSaved(wordCount: wordCount)
            self.presentMeetingCompanion(manager: manager)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard self?.meetingCompanionState.phase == .saved else { return }
                self?.meetingScratchpadWindowController.close()
            }
            self.playAudioCue(.stop)
            let speakerCount = Set(cleaned.utterances.map { $0.speaker }).count
            self.analyticsManager.capture("meeting_recording_completed", properties: [
                "app_name": cleaned.detectedApp?.name ?? "unknown",
                "duration_seconds": cleaned.durationSeconds,
                "word_count": wordCount,
                "has_notes": !cleaned.liveNotes.isEmpty,
                "summarization_enabled": self.settingsManager.meetingSummarizationEnabled,
                "origin": cleaned.captureContext?.recordingOrigin.rawValue ?? "manual",
                "backend": backendAtStart,
                "is_calendar_backed": cleaned.captureContext?.isCalendarBacked ?? false,
                "speaker_count": speakerCount,
                "utterance_count": cleaned.utterances.count
            ])

            self.sendMeetingCompletionEmailIfNeeded(session: cleaned, entry: entry)

            // Fire webhook if configured (best-effort, non-blocking). The completed
            // event intentionally goes out immediately so downstream workflows can
            // start from the transcript before the async summary arrives.
            if self.canFireMeetingWebhooks,
               !self.settingsManager.meetingWebhookURL.isEmpty {
                let webhookURL = self.settingsManager.meetingWebhookURL
                let sender = self.meetingWebhookSender
                let snapshot = sender.snapshotEntry(entry)
                Task {
                    await sender.enqueueCompleted(
                        session: cleaned,
                        entrySnapshot: snapshot,
                        webhookURL: webhookURL
                    )
                }
            }

            if self.settingsManager.hotMicEnabled && !self.hotMicManager.isActive {
                await self.startHotMic()
            }

            // Generate LLM summary in the background (doesn't block session completion)
            if AppFeatureVisibility.hostedServices
                && self.settingsManager.meetingSummarizationEnabled
                && self.settingsManager.cloudProcessingEnabled
                && self.authManager.isLoggedIn {
                self.startMeetingSummaryTask(for: cleaned)
            }
        }
        manager.onError = { [weak self] message in
            guard let self else { return }
            self.cancelPendingMeetingAutoStop()
            self.activeMeetingLifecycleContext = nil
            self.currentMeetingSystemTransport = nil
            self.hasWarnedBluetoothThisSession = false
            self.meetingContextDetector.stopLifecycleTracking()
            self.meetingCompanionState.markError(message)
            if let recorder = self.meetingRecorderManager {
                self.presentMeetingCompanion(manager: recorder)
            }
            self.notchCoordinator.showError(message, subtype: .generic)
            if let activeID = self.meetingRecorderManager?.activeSession?.id {
                self.meetingBackendAtStart.removeValue(forKey: activeID)
            }
            self.analyticsManager.capture("meeting_recording_error", properties: [
                "error_message": String(message.prefix(120))
            ])
            // If the fatal error landed mid-recording, the session is still
            // alive but the UI hides Stop in `.error` — finalize so the
            // partial transcript is persisted instead of leaving the recorder
            // stuck holding the mic. `stopMeetingRecording` runs the normal
            // pipeline which calls `resumeMediaAfterRecording` itself once
            // the audio tap is fully torn down, so do NOT resume media here
            // — that would unduck system audio while the tap is still live
            // and bleed it into the saved partial transcript.
            let recorder = self.meetingRecorderManager
            if let recorder, recorder.isRecording, !recorder.isFinalizing {
                Task { @MainActor [weak self] in
                    await self?.stopMeetingRecording()
                }
            } else {
                // Startup-time failure: nothing was actively recording so the
                // tap is already inert. Safe to resume media synchronously.
                self.resumeMediaAfterRecording()
            }
        }
        manager.onSystemAudioSilent = { [weak self] in
            guard let self else { return }
            self.notchCoordinator.showError(
                "Not hearing other side — check System Settings › Screen & System Audio",
                subtype: .meetingSystemAudio
            )
            self.meetingCompanionState.updateAudioHealth(
                "Not hearing the other side. Check System Settings > Screen & System Audio."
            )
            self.analyticsManager.capture("meeting_system_audio_silent", properties: [
                "transport_type": self.currentMeetingSystemTransport?.rawValue ?? "unknown",
                "os_version": ProcessInfo.processInfo.operatingSystemVersionString
            ])
        }
        manager.onSystemAudioRecovered = { [weak self] in
            guard let self else { return }
            self.cancelPendingMeetingAutoStop()
            self.meetingCompanionState.updateAudioHealth(nil)
            self.analyticsManager.capture("meeting_system_audio_recovered")
        }
        manager.onSystemAudioTransportDetected = { [weak self] transport in
            guard let self else { return }
            self.currentMeetingSystemTransport = transport
            self.analyticsManager.capture("meeting_system_audio_transport", properties: [
                "transport_type": transport.rawValue,
                "os_version": ProcessInfo.processInfo.operatingSystemVersionString
            ])
            if transport.shouldWarnBeforeMeeting, !self.hasWarnedBluetoothThisSession {
                self.hasWarnedBluetoothThisSession = true
                self.notchCoordinator.showDone(
                    "Bluetooth output — other side may not be captured. Switch to built-in speakers for better results.",
                    timeout: .seconds(8)
                )
            }
        }
        manager.onWarning = { [weak self] message in
            guard let self else { return }
            self.meetingCompanionState.updateAudioHealth(message)
            self.notchCoordinator.showDone(message)
        }
    }

    private func wireMeetingContextDetector() {
        meetingContextDetector.onMeetingJoined = { [weak self] detectedMeeting in
            guard let self,
                  let manager = self.meetingRecorderManager,
                  !manager.isRecording,
                  !manager.isStartingSession,
                  !manager.isFinalizing,
                  !self.isLocalCaptureSuppressingMeetingAutomation
            else {
                return
            }

            self.analyticsManager.capture("meeting_auto_started", properties: [
                "app_name": detectedMeeting.app.name,
                "has_calendar_hint": detectedMeeting.calendarHint != nil
            ])
            await self.startMeetingRecording(
                detectedApp: detectedMeeting.app,
                lifecycleMeeting: detectedMeeting,
                recordingOriginOverride: .automatic,
                startOrigin: .automatic
            )
        }

        meetingContextDetector.onMeetingDetected = { [weak self] detectedMeeting in
            guard let self,
                  let recorder = self.meetingRecorderManager,
                  !recorder.isRecording,
                  !recorder.isStartingSession,
                  !recorder.isFinalizing,
                  !self.isLocalCaptureSuppressingMeetingAutomation,
                  self.settingsManager.meetingJoinPromptEnabled
            else {
                return
            }

            self.analyticsManager.capture("meeting_detected", properties: [
                "app_name": detectedMeeting.app.name,
                "has_calendar_hint": detectedMeeting.calendarHint != nil
            ])
            await self.meetingPromptNotifier.deliverPrompt(for: detectedMeeting)
        }

        meetingContextDetector.onLifecycleMeetingUpdated = { [weak self] updatedMeeting in
            guard let self,
                  let activeMeetingLifecycleContext = self.activeMeetingLifecycleContext,
                  activeMeetingLifecycleContext.matchesLifecycleIdentity(of: updatedMeeting)
            else {
                return
            }

            self.cancelPendingMeetingAutoStop()
            self.activeMeetingLifecycleContext = updatedMeeting
        }

        meetingContextDetector.shouldEndTrackedMeeting = { [weak self] candidate in
            guard let self else { return false }
            return await self.shouldAutoStopMeeting(for: candidate)
        }

        meetingContextDetector.onMeetingLeft = { [weak self] detectedMeeting, lifecycleSignal in
            guard let self,
                  let manager = self.meetingRecorderManager,
                  manager.isRecording,
                  !manager.isFinalizing,
                  self.settingsManager.meetingAutoStopEnabled
            else {
                return
            }

            guard let activeMeetingLifecycleContext = self.activeMeetingLifecycleContext,
                  activeMeetingLifecycleContext.matchesLifecycleIdentity(of: detectedMeeting)
            else {
                return
            }

            let reason = self.approvedMeetingAutoStopReason
                ?? Self.defaultAutoStopReason(for: lifecycleSignal)
            let approvedCandidate = self.approvedMeetingAutoStopCandidate
            self.approvedMeetingAutoStopReason = nil
            self.approvedMeetingAutoStopCandidate = nil
            self.cancelPendingMeetingAutoStop()
            self.analyticsManager.capture(
                "meeting_auto_stopped",
                properties: self.meetingAutoStopAnalyticsProperties(
                    detectedMeeting: detectedMeeting,
                    lifecycleSignal: lifecycleSignal,
                    reason: reason,
                    manager: manager,
                    cameraActive: approvedCandidate?.isCameraActive
                )
            )
            await self.stopMeetingRecording()
        }
    }

    private func shouldAutoStopMeeting(
        for candidate: MeetingContextDetector.MeetingEndCandidate
    ) async -> Bool {
        guard let manager = meetingRecorderManager,
              manager.isRecording,
              !manager.isFinalizing,
              settingsManager.meetingAutoStopEnabled,
              let activeMeetingLifecycleContext,
              activeMeetingLifecycleContext.matchesLifecycleIdentity(of: candidate.meeting)
        else {
            cancelPendingMeetingAutoStop()
            return false
        }

        let now = Date()
        let pendingStartedAt = pendingMeetingAutoStop.flatMap { pending -> Date? in
            pending.meeting.matchesLifecycleIdentity(of: candidate.meeting) ? pending.startedAt : nil
        }
        let snapshot = MeetingAutoStopEvaluator.Snapshot(
            lifecycleSignal: candidate.lifecycleSignal,
            cameraActive: candidate.isCameraActive,
            systemAudioSilent: manager.isSystemAudioSilent,
            secondsSinceLastUtterance: manager.secondsSinceLastUtterance(now: now),
            recordingDuration: manager.recordingElapsed,
            calendarPastEndGrace: MeetingContextDetector.calendarSuggestsMeetingEnded(candidate.meeting, now: now),
            pendingStopStartedAt: pendingStartedAt,
            now: now
        )

        switch MeetingAutoStopEvaluator.evaluate(snapshot) {
        case .keepRecording:
            cancelPendingMeetingAutoStop()
            return false
        case .pendingStop(let reason):
            armPendingMeetingAutoStop(
                meeting: candidate.meeting,
                reason: reason,
                startedAt: pendingStartedAt ?? now
            )
            return false
        case .stop(let reason):
            approvedMeetingAutoStopReason = reason
            approvedMeetingAutoStopCandidate = candidate
            return true
        }
    }

    private func armPendingMeetingAutoStop(
        meeting: MeetingContextDetector.DetectedMeeting,
        reason: MeetingAutoStopEvaluator.StopReason,
        startedAt: Date
    ) {
        if let pendingMeetingAutoStop,
           pendingMeetingAutoStop.meeting.matchesLifecycleIdentity(of: meeting),
           pendingMeetingAutoStop.startedAt == startedAt {
            if pendingMeetingAutoStopRefreshTask == nil {
                schedulePendingMeetingAutoStopRefresh()
            }
            return
        }

        pendingMeetingAutoStop = PendingMeetingAutoStop(
            meeting: meeting,
            reason: reason,
            startedAt: startedAt
        )
        schedulePendingMeetingAutoStopRefresh()
    }

    private func schedulePendingMeetingAutoStopRefresh() {
        pendingMeetingAutoStopRefreshTask?.cancel()
        pendingMeetingAutoStopRefreshTask = Task { @MainActor [weak self] in
            let nanoseconds = UInt64(MeetingAutoStopEvaluator.pendingStopGrace * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            self?.pendingMeetingAutoStopRefreshTask = nil
            await self?.meetingContextDetector.refreshLifecycleTracking()
        }
    }

    private func cancelPendingMeetingAutoStop() {
        pendingMeetingAutoStopRefreshTask?.cancel()
        pendingMeetingAutoStopRefreshTask = nil
        pendingMeetingAutoStop = nil
        approvedMeetingAutoStopReason = nil
        approvedMeetingAutoStopCandidate = nil
    }

    private static func defaultAutoStopReason(
        for signal: MeetingContextDetector.LifecycleSignal
    ) -> MeetingAutoStopEvaluator.StopReason {
        switch signal {
        case .strongEndSignal:
            return .strongLifecycleEnd
        case .active, .ambiguous, .weakEndSignal:
            return .weakLifecycleInactivity
        }
    }

    private func meetingAutoStopAnalyticsProperties(
        detectedMeeting: MeetingContextDetector.DetectedMeeting,
        lifecycleSignal: MeetingContextDetector.LifecycleSignal,
        reason: MeetingAutoStopEvaluator.StopReason,
        manager: MeetingRecorderManager,
        cameraActive: Bool?
    ) -> [String: Any] {
        let now = Date()
        var properties: [String: Any] = [
            "app_name": detectedMeeting.app.name,
            "reason": reason.rawValue,
            "lifecycle_signal": MeetingAutoStopEvaluator.lifecycleSignalName(lifecycleSignal),
            "system_audio_silent": manager.isSystemAudioSilent,
            "calendar_past_end": MeetingContextDetector.calendarSuggestsMeetingEnded(detectedMeeting, now: now)
        ]
        if let secondsSinceLastUtterance = manager.secondsSinceLastUtterance(now: now) {
            properties["seconds_since_last_utterance"] = Int(secondsSinceLastUtterance)
        }
        if let cameraActive {
            properties["camera_active"] = cameraActive
        }
        return properties
    }

    func startMeetingRecording(
        detectedApp: MeetingApp? = nil,
        lifecycleMeeting: MeetingContextDetector.DetectedMeeting? = nil,
        suggestedTitle: String? = nil,
        captureContext: MeetingCaptureContext? = nil,
        recordingOriginOverride: MeetingRecordingOrigin? = nil,
        startOrigin: MeetingStartOrigin? = nil
    ) async {
        guard !isClearingWorkspace, !isSystemSleeping, !isShuttingDown else { return }
        guard !isRecording, !isStartingRecording, !isFinishingCapture else { return }
        guard let manager = meetingRecorderManager else { return }
        guard !hasMeetingWarmUpStartupSuppression,
              !manager.isRecording,
              !manager.isStartingSession,
              !manager.isFinalizing else {
            showActiveMeetingCompanion()
            return
        }
        cancelPendingMeetingAutoStop()
        meetingPromptNotifier.clearPrompt()
        let resolvedLifecycleMeeting = lifecycleMeeting ?? meetingContextDetector.currentMeeting
        if let resolvedLifecycleMeeting {
            meetingPromptNotifier.clearCalendarPrompt(for: resolvedLifecycleMeeting)
        }
        let resolvedDetectedApp = detectedApp ?? resolvedLifecycleMeeting?.app
        let resolvedCaptureContext = captureContext
            ?? resolvedLifecycleMeeting?.calendarHint?.captureContext(
                origin: recordingOriginOverride ?? .manual,
                titleOverride: suggestedTitle
            )
            ?? .adHoc(title: suggestedTitle, recordingOrigin: recordingOriginOverride ?? .manual)
        let resolvedTitle = suggestedTitle ?? resolvedCaptureContext.effectiveTitle
        let resolvedStartOrigin = startOrigin
            ?? MeetingStartOrigin(
                recordingOrigin: resolvedCaptureContext.recordingOrigin,
                isCalendarBacked: resolvedCaptureContext.isCalendarBacked
            )

        // The bridge token closes the gap before MeetingRecorderManager exposes
        // `isStartingSession`. Publish warm invalidation synchronously, then
        // drain the shared lifecycle queue before meeting capture may open it.
        let meetingStartAttemptID = meetingStartOwnership.begin()
        hasMeetingWarmUpStartupSuppression = true
        audioWarmUpRecoveryCoordinator.cancelPendingActivation()
        audioRecorder.teardownWarmSession()
        setLowLatencyWarmActivity(false)
        defer {
            _ = meetingStartOwnership.finish(meetingStartAttemptID)
            hasMeetingWarmUpStartupSuppression = false
            rewarmIfLowLatency()
        }
        await audioRecorder.waitForWarmSessionTeardown()

        guard canContinueAudioStart(
                  ownsStartAttempt: meetingStartOwnership.owns(meetingStartAttemptID)
              ),
              !Task.isCancelled,
              !isRecording,
              !isStartingRecording,
              !isFinishingCapture,
              !manager.isRecording,
              !manager.isStartingSession,
              !manager.isFinalizing else { return }

        manager.notepad.clear()
        meetingCompanionState.beginStarting(
            origin: resolvedStartOrigin,
            title: resolvedTitle,
            detectedAppName: resolvedDetectedApp?.name,
            subtitle: resolvedCaptureContext.calendarName ?? resolvedLifecycleMeeting?.windowTitle
        )
        presentMeetingCompanion(manager: manager)
        await manager.startSession(
            detectedApp: resolvedDetectedApp,
            suggestedTitle: resolvedTitle,
            captureContext: resolvedCaptureContext,
            shouldContinue: { [weak self] in
                guard let self else { return false }
                return self.canContinueAudioStart(
                    ownsStartAttempt: self.meetingStartOwnership.owns(meetingStartAttemptID)
                ) && !Task.isCancelled
            }
        )

        guard canContinueAudioStart(
                  ownsStartAttempt: meetingStartOwnership.owns(meetingStartAttemptID)
              ),
              !Task.isCancelled,
              manager.isRecording else {
            if manager.isRecording {
                await manager.discardSession()
            }
            return
        }

        // Tuck the settings window into the Dock once recording is live —
        // the floating scratchpad companion takes over for note-taking, so
        // the heavy settings UI just gets in the user's way.
        settingsWindowController.miniaturize()

        notchCoordinator.meetingElapsed = manager.recordingElapsed
        activeMeetingLifecycleContext = resolvedLifecycleMeeting
        if settingsManager.meetingAutoStopEnabled, let resolvedLifecycleMeeting {
            meetingContextDetector.beginLifecycleTracking(for: resolvedLifecycleMeeting)
            await meetingContextDetector.refreshLifecycleTracking()
        } else {
            meetingContextDetector.stopLifecycleTracking()
        }
    }

    func stopMeetingRecording() async {
        guard let manager = meetingRecorderManager else { return }
        cancelPendingMeetingAutoStop()
        meetingPromptNotifier.clearPrompt()
        activeMeetingLifecycleContext = nil
        currentMeetingSystemTransport = nil
        hasWarnedBluetoothThisSession = false
        meetingContextDetector.stopLifecycleTracking()
        if manager.isRecording {
            meetingCompanionState.markProcessing(title: manager.activeSession?.suggestedTitle)
            presentMeetingCompanion(manager: manager)
            beginMeetingScratchpadProcessing(manager.notepad)
        }
        await manager.endSession()
        rewarmIfLowLatency()
    }

    func showActiveMeetingCompanion() {
        guard let manager = meetingRecorderManager,
              let session = manager.activeSession
        else { return }
        meetingCompanionState.markRecording(session: session)
        presentMeetingCompanion(manager: manager)
        meetingScratchpadWindowController.setExpanded(true)
    }

    func rebindActiveMeeting(to event: MeetingCalendarEvent) async {
        guard let manager = meetingRecorderManager, manager.isRecording else { return }
        let context = event.captureContext(origin: .rebound)
        manager.rebindActiveSession(to: context, suggestedTitle: context.effectiveTitle)
        if let session = manager.activeSession {
            let sessionID = session.id
            let captureContext = context
            _ = await dataStore.performBackgroundWrite { context in
                var descriptor = FetchDescriptor<MeetingEntry>(
                    predicate: #Predicate { $0.id == sessionID }
                )
                descriptor.fetchLimit = 1
                guard let entry = try? context.fetch(descriptor).first else { return }
                entry.applyCaptureContext(captureContext)
            }
            meetingDataVersion &+= 1
        }
        let reboundLifecycleMeeting = reboundLifecycleMeeting(for: event, activeSession: manager.activeSession)
        activeMeetingLifecycleContext = reboundLifecycleMeeting
        if settingsManager.meetingAutoStopEnabled, let reboundLifecycleMeeting {
            meetingContextDetector.beginLifecycleTracking(for: reboundLifecycleMeeting)
            await meetingContextDetector.refreshLifecycleTracking()
        } else if settingsManager.meetingAutoStopEnabled {
            meetingContextDetector.stopLifecycleTracking()
        }
    }

    @discardableResult
    func importMeetingAudio(for event: MeetingCalendarEvent, url: URL) async -> Bool {
        guard let manager = meetingRecorderManager else { return false }
        return await manager.importAudioFile(url: url, captureContext: event.captureContext(origin: .importedAudio))
    }

    func createAdHocManualNotesMeeting(
        title: String? = nil,
        startedAt: Date = .now
    ) async -> MeetingEntry {
        let normalizedTitle: String? = {
            guard let title else { return nil }
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }()
        let captureContext = MeetingCaptureContext.adHoc(
            title: normalizedTitle,
            recordingOrigin: .manualNotes
        )
        return await persistManualNotesMeeting(
            title: normalizedTitle,
            startedAt: startedAt,
            endedAt: startedAt,
            durationSeconds: 0,
            captureContext: captureContext
        )
    }

    func createManualNotesMeeting(for event: MeetingCalendarEvent) async -> MeetingEntry {
        let existingDescriptor = FetchDescriptor<MeetingEntry>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        if let existing = (await dataStore.fetchInBackground(existingDescriptor)).first(where: {
            $0.activeJSONLPath == nil && $0.calendarEventID == event.id
        }) {
            return existing
        }

        let captureContext = event.captureContext(origin: .manualNotes)
        return await persistManualNotesMeeting(
            title: event.title,
            startedAt: event.startDate,
            endedAt: event.endDate,
            durationSeconds: max(0, event.endDate.timeIntervalSince(event.startDate)),
            captureContext: captureContext
        )
    }

    private func meetingSpeakerAliases(
        existing: MeetingSpeakerAliasMap = [:],
        speakers: [MeetingSpeaker],
        captureContext: MeetingCaptureContext?
    ) -> MeetingSpeakerAliasMap {
        MeetingSpeakerAliasResolver.mergedAliases(
            existing: existing,
            speakers: speakers,
            captureContext: captureContext,
            userDisplayName: settingsManager.resolvedEmailSignoffName,
            userEmail: settingsManager.userEmail
        )
    }

    private func startMeetingSummaryTask(for session: CompletedMeetingSession) {
        let meetingID = session.id
        cancelMeetingSummaryTask(for: meetingID)

        let token = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.activeMeetingSummaryTasks[meetingID]?.token == token {
                    self.activeMeetingSummaryTasks.removeValue(forKey: meetingID)
                }
            }

            let transcript = session.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else { return }

            let startedAt = Date()
            guard let summary = await self.convexClient.summarizeMeeting(
                transcript: transcript,
                appName: session.detectedApp?.name,
                durationSeconds: session.durationSeconds,
                style: self.settingsManager.meetingSummaryStyle
            ) else {
                // ConvexClient.summarizeMeeting funnels every thrown error —
                // including CancellationError when shutdown/clearWorkspace
                // cancels in-flight summary tasks — into nil. Suppress the
                // failure analytic for cancellations so the dashboard
                // reflects real failures only.
                guard !Task.isCancelled else { return }
                self.analyticsManager.capture("meeting_summary_failed", properties: [
                    "app_name": session.detectedApp?.name ?? "unknown",
                    "duration_seconds": session.durationSeconds,
                    "word_count": session.wordCount,
                    "latency_ms": Int(Date().timeIntervalSince(startedAt) * 1000)
                ])
                return
            }
            self.analyticsManager.capture("meeting_summary_generated", properties: [
                "app_name": session.detectedApp?.name ?? "unknown",
                "duration_seconds": session.durationSeconds,
                "word_count": session.wordCount,
                "summary_length": summary.count,
                "latency_ms": Int(Date().timeIntervalSince(startedAt) * 1000)
            ])

            do {
                try Task.checkCancellation()
                try await self.persistMeetingSummary(for: session, summary: summary)
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }

        activeMeetingSummaryTasks[meetingID] = MeetingSummaryTaskHandle(token: token, task: task)
    }

    private func persistMeetingSummary(
        for session: CompletedMeetingSession,
        summary: String
    ) async throws {
        let meetingID = session.id
        let normalizedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSummary.isEmpty else { return }
        guard let existingEntry = dataStore.meetingEntry(id: meetingID) else { return }

        var rewrittenAudioPath: String?
        var rewrittenMarkdownPath: String?

        try Task.checkCancellation()
        guard dataStore.meetingEntry(id: meetingID) != nil else { return }

        if let markdownPath = existingEntry.markdownPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !markdownPath.isEmpty {
            let didRewrite = await archiveWriter.rewriteMeetingSummary(
                markdownPath: markdownPath,
                newSummary: normalizedSummary
            )
            if !didRewrite {
                let archiveEntry = makeSummaryArchiveEntry(
                    from: existingEntry,
                    session: session,
                    summary: normalizedSummary
                )
                _ = await archiveWriter.writeMeeting(session: session, entry: archiveEntry, summary: normalizedSummary)
                rewrittenAudioPath = archiveEntry.audioPath
                rewrittenMarkdownPath = archiveEntry.markdownPath
            }
        } else {
            let archiveEntry = makeSummaryArchiveEntry(
                from: existingEntry,
                session: session,
                summary: normalizedSummary
            )
            _ = await archiveWriter.writeMeeting(session: session, entry: archiveEntry, summary: normalizedSummary)
            rewrittenAudioPath = archiveEntry.audioPath
            rewrittenMarkdownPath = archiveEntry.markdownPath
        }

        try Task.checkCancellation()
        guard dataStore.meetingEntry(id: meetingID) != nil else { return }

        let resolvedAudioPath = rewrittenAudioPath
        let resolvedMarkdownPath = rewrittenMarkdownPath
        _ = await dataStore.performBackgroundWrite { context in
            var descriptor = FetchDescriptor<MeetingEntry>(
                predicate: #Predicate { $0.id == meetingID }
            )
            descriptor.fetchLimit = 1
            guard let persisted = try? context.fetch(descriptor).first else { return }
            persisted.summary = normalizedSummary
            persisted.audioPath = resolvedAudioPath ?? persisted.audioPath
            persisted.markdownPath = resolvedMarkdownPath ?? persisted.markdownPath
        }
        meetingDataVersion &+= 1

        guard let refreshedEntry = dataStore.meetingEntry(id: meetingID) else { return }

        try Task.checkCancellation()
        if canFireMeetingWebhooks,
           !settingsManager.meetingWebhookURL.isEmpty {
            let webhookURL = settingsManager.meetingWebhookURL
            let sender = meetingWebhookSender
            let snapshot = sender.snapshotEntry(refreshedEntry)
            await sender.enqueueSummaryReady(
                session: session,
                entrySnapshot: snapshot,
                webhookURL: webhookURL,
                summary: normalizedSummary
            )
        }
    }

    private func makeSummaryArchiveEntry(
        from existingEntry: MeetingEntry,
        session: CompletedMeetingSession,
        summary: String
    ) -> MeetingEntry {
        let archiveEntry = MeetingEntry(id: session.id, startedAt: session.startedAt)
        archiveEntry.endedAt = existingEntry.endedAt ?? session.endedAt
        archiveEntry.detectedApp = existingEntry.detectedApp ?? session.detectedApp?.name
        archiveEntry.customTitle = existingEntry.customTitle ?? session.suggestedTitle
        archiveEntry.durationSeconds = max(existingEntry.durationSeconds, session.durationSeconds)
        archiveEntry.wordCount = max(existingEntry.wordCount, session.wordCount)
        archiveEntry.userNotes = existingEntry.userNotes ?? session.liveNotes.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        archiveEntry.postMeetingNotes = existingEntry.postMeetingNotes ?? session.postMeetingNotes.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        archiveEntry.summary = summary
        archiveEntry.audioPath = existingEntry.audioPath
        archiveEntry.markdownPath = existingEntry.markdownPath
        archiveEntry.applyCaptureContext(existingEntry.captureContext ?? session.captureContext)
        archiveEntry.speakerAliases = existingEntry.speakerAliases.isEmpty ? session.speakerAliases : existingEntry.speakerAliases
        return archiveEntry
    }

    private func cancelMeetingSummaryTask(for meetingID: UUID) {
        activeMeetingSummaryTasks.removeValue(forKey: meetingID)?.task.cancel()
    }

    private func cancelMeetingSummaryTasks(for meetingIDs: [UUID]) {
        for meetingID in meetingIDs {
            cancelMeetingSummaryTask(for: meetingID)
        }
    }

    private func cancelAllMeetingSummaryTasks() {
        let tasks = activeMeetingSummaryTasks.values.map(\.task)
        activeMeetingSummaryTasks.removeAll()
        for task in tasks {
            task.cancel()
        }
    }

    private func cancelAllMeetingSummaryTasksAndWait() async {
        let tasks = activeMeetingSummaryTasks.values.map(\.task)
        activeMeetingSummaryTasks.removeAll()
        for task in tasks {
            task.cancel()
        }
        for task in tasks {
            await task.value
        }
    }

    func deleteMeetings(_ meetings: [MeetingEntry]) async {
        guard !meetings.isEmpty else { return }
        let meetingIDs = Set(meetings.map(\.id))
        cancelMeetingSummaryTasks(for: Array(meetingIDs))
        await meetingWebhookSender.removeMeetings(ids: meetingIDs)
        let filePaths = meetings.flatMap { [$0.markdownPath, $0.audioPath, $0.activeJSONLPath] }
        await Self.removeMeetingFiles(atRelativePaths: filePaths)
        for meeting in meetings {
            await dataStore.delete(meeting)
            feedManager.remove(id: meeting.id)
        }
    }

    private nonisolated static func removeMeetingFiles(atRelativePaths paths: [String?]) async {
        let urls = paths
            .compactMap { $0 }
            .map { AppSupportPaths.resonantRoot().appendingPathComponent($0) }
        await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            for url in urls where fileManager.fileExists(atPath: url.path) {
                try? fileManager.removeItem(at: url)
            }
        }.value
    }

    func ensureMeetingPromptAuthorization() async {
        guard settingsManager.meetingJoinPromptEnabled else { return }
        _ = await meetingPromptNotifier.requestAuthorizationIfNeeded()
    }

    @discardableResult
    func requestAccessibilityAuthorizationIfNeeded() -> Bool {
        guard !AXIsProcessTrusted() else { return true }

        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        let isTrusted = AXIsProcessTrustedWithOptions(options)
        if !isTrusted {
            openAccessibilitySettings()
        }
        return isTrusted
    }

    func ensureMeetingRecordingSetupAuthorization() async {
        let micGranted = await MeetingMicrophoneCapturePermission.ensureMicrophoneAccess()

        let needsAccessibility = settingsManager.meetingJoinPromptEnabled || settingsManager.meetingAutoStartEnabled
        let accessibilityGranted = needsAccessibility ? requestAccessibilityAuthorizationIfNeeded() : nil

        let promptGranted: Bool? = settingsManager.meetingJoinPromptEnabled
            ? await meetingPromptNotifier.requestAuthorizationIfNeeded()
            : nil

        let calendarGranted: Bool? = settingsManager.meetingUseCalendarHints
            ? await meetingContextDetector.requestCalendarAuthorizationIfNeeded()
            : nil

        captureMeetingSetupAuthorizationEvent(
            source: "recording_setup",
            micGranted: micGranted,
            accessibilityGranted: accessibilityGranted,
            promptGranted: promptGranted,
            calendarGranted: calendarGranted
        )

        await refreshMeetingDetection()
    }

    func ensureMeetingAutomationSetupAuthorization() async {
        let accessibilityGranted = requestAccessibilityAuthorizationIfNeeded()

        let promptGranted: Bool? = settingsManager.meetingJoinPromptEnabled
            ? await meetingPromptNotifier.requestAuthorizationIfNeeded()
            : nil

        let calendarGranted: Bool? = settingsManager.meetingUseCalendarHints
            ? await meetingContextDetector.requestCalendarAuthorizationIfNeeded()
            : nil

        captureMeetingSetupAuthorizationEvent(
            source: "automation_setup",
            micGranted: nil,
            accessibilityGranted: accessibilityGranted,
            promptGranted: promptGranted,
            calendarGranted: calendarGranted
        )

        await refreshMeetingDetection()
    }

    private func captureMeetingSetupAuthorizationEvent(
        source: String,
        micGranted: Bool?,
        accessibilityGranted: Bool?,
        promptGranted: Bool?,
        calendarGranted: Bool?
    ) {
        var properties: [String: Any] = ["source": source]
        if let micGranted { properties["mic_granted"] = micGranted }
        if let accessibilityGranted { properties["accessibility_granted"] = accessibilityGranted }
        if let promptGranted { properties["notification_granted"] = promptGranted }
        if let calendarGranted { properties["calendar_granted"] = calendarGranted }
        let granted = [micGranted, accessibilityGranted, promptGranted, calendarGranted].compactMap { $0 }
        properties["all_granted"] = !granted.isEmpty && granted.allSatisfy { $0 }
        analyticsManager.capture("meeting_setup_authorization_requested", properties: properties)
    }

    func dismissMeetingPrompt(for detectedMeeting: MeetingContextDetector.DetectedMeeting) {
        meetingPromptNotifier.clearPrompt()
        meetingPromptNotifier.clearCalendarPrompt(for: detectedMeeting)
        meetingContextDetector.recordPromptDismissal(for: detectedMeeting)
        if meetingCompanionState.phase == .detecting {
            meetingScratchpadWindowController.close()
        }
        analyticsManager.capture("meeting_prompt_dismissed", properties: [
            "app_name": detectedMeeting.app.name,
            "has_calendar_hint": detectedMeeting.calendarHint != nil
        ])
    }

    @discardableResult
    func ensureMeetingCalendarAuthorization() async -> Bool {
        guard settingsManager.meetingUseCalendarHints else { return false }
        return await meetingContextDetector.requestCalendarAuthorizationIfNeeded()
    }

    func refreshMeetingDetection() async {
        guard shouldRunMeetingContextDetector else { return }
        await meetingContextDetector.reevaluateDetection()
    }

    private func persistManualNotesMeeting(
        title: String?,
        startedAt: Date,
        endedAt: Date?,
        durationSeconds: Double,
        captureContext: MeetingCaptureContext
    ) async -> MeetingEntry {
        let entryID = UUID()
        let normalizedTitle: String? = {
            guard let title else { return nil }
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }()
        let speakerAliases = meetingSpeakerAliases(
            speakers: [.you, .them],
            captureContext: captureContext
        )
        _ = await dataStore.performBackgroundWrite { context in
            let entry = MeetingEntry(
                id: entryID,
                startedAt: startedAt,
                endedAt: endedAt,
                durationSeconds: durationSeconds,
                wordCount: 0
            )
            entry.applyCaptureContext(captureContext)
            entry.customTitle = normalizedTitle
            entry.speakerAliases = speakerAliases
            context.insert(entry)
        }

        let entry = dataStore.meetingEntry(id: entryID) ?? {
            let fallback = MeetingEntry(
                id: entryID,
                startedAt: startedAt,
                endedAt: endedAt,
                durationSeconds: durationSeconds,
                wordCount: 0
            )
            fallback.applyCaptureContext(captureContext)
            fallback.customTitle = normalizedTitle
            fallback.speakerAliases = speakerAliases
            return fallback
        }()
        feedManager.record(entry)
        return entry
    }

    private func syncMeetingAutomationSettings() async {
        if settingsManager.meetingAutoStopEnabled {
            if let activeMeetingLifecycleContext {
                meetingContextDetector.beginLifecycleTracking(for: activeMeetingLifecycleContext)
                await meetingContextDetector.refreshLifecycleTracking()
            }
        } else {
            meetingContextDetector.stopLifecycleTracking()
        }

        if settingsManager.meetingAutoStartEnabled || settingsManager.meetingJoinPromptEnabled {
            await refreshMeetingDetection()
        }
    }

    private var shouldScheduleMeetingCalendarPrompts: Bool {
        AppRuntime.supportsUserNotifications
            && settingsManager.meetingRecordingEnabled
            && settingsManager.meetingJoinPromptEnabled
            && settingsManager.meetingUseCalendarHints
    }

    private func syncMeetingCalendarPromptSchedule() {
        guard shouldScheduleMeetingCalendarPrompts else {
            meetingCalendarPromptRefreshTask?.cancel()
            meetingCalendarPromptRefreshTask = nil
            meetingPromptNotifier.clearCalendarPrompts()
            return
        }

        guard meetingCalendarPromptRefreshTask == nil else {
            Task { @MainActor [weak self] in
                await self?.refreshMeetingCalendarPrompts()
            }
            return
        }

        meetingCalendarPromptRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshMeetingCalendarPrompts()

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15 * 60))
                guard !Task.isCancelled else { return }
                await self.refreshMeetingCalendarPrompts()
            }
        }
    }

    private func handleMeetingCalendarStoreChanged() {
        guard settingsManager.meetingUseCalendarHints else {
            return
        }

        meetingCalendarStoreChangeTask?.cancel()
        meetingCalendarStoreChangeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            self.meetingCalendarDataVersion &+= 1
            self.syncMeetingCalendarPromptSchedule()
            if self.settingsManager.meetingRecordingEnabled {
                await self.refreshMeetingDetection()
            }
        }
    }

    private func refreshMeetingCalendarPrompts() async {
        guard shouldScheduleMeetingCalendarPrompts else { return }
        guard await meetingPromptNotifier.requestAuthorizationIfNeeded() else { return }
        guard await meetingContextDetector.requestCalendarAuthorizationIfNeeded() else {
            meetingPromptNotifier.clearCalendarPrompts()
            return
        }

        let now = Date()
        let ignoredEventIDs = Set(settingsManager.meetingTimelineIgnoredEventIDs)
        let hiddenEventIDs = Set(settingsManager.meetingTimelineHiddenEventIDs)
        let events = await calendarHintSource.calendarEvents(
            from: now,
            to: now.addingTimeInterval(24 * 60 * 60)
        )
        .filter { event in
            guard event.startDate > now else { return false }
            guard event.conferencingURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                return false
            }
            guard !ignoredEventIDs.contains(event.id), !hiddenEventIDs.contains(event.id) else {
                return false
            }
            return true
        }

        await meetingPromptNotifier.scheduleCalendarPrompts(for: events, now: now)
    }

    private var shouldRunMeetingContextDetector: Bool {
        guard meetingRecorderManager != nil, settingsManager.meetingRecordingEnabled else {
            return false
        }
        return settingsManager.meetingJoinPromptEnabled
            || settingsManager.meetingAutoStartEnabled
            || settingsManager.meetingAutoStopEnabled
            || settingsManager.meetingUseCalendarHints
            || !settingsManager.meetingTimelineAutoRecordEventIDs.isEmpty
    }

    private func syncMeetingDetectionState() {
        if shouldRunMeetingContextDetector {
            meetingContextDetector.start()
        } else {
            meetingContextDetector.stop()
            meetingPromptNotifier.clearPrompt()
        }
    }

    private func handleMeetingRecordingEnabledChanged() async {
        syncMeetingDetectionState()
        guard settingsManager.meetingRecordingEnabled else {
            syncMeetingCalendarPromptSchedule()
            return
        }

        if settingsManager.meetingJoinPromptEnabled {
            await ensureMeetingPromptAuthorization()
        }
        if settingsManager.meetingUseCalendarHints {
            await ensureMeetingCalendarAuthorization()
        }
        syncMeetingCalendarPromptSchedule()
        await refreshMeetingDetection()
    }

    private func refreshMeetingDetectionAfterLocalCaptureIfNeeded() {
        guard !isLocalCaptureSuppressingMeetingAutomation else { return }
        guard shouldRunMeetingContextDetector else { return }
        guard settingsManager.meetingJoinPromptEnabled || settingsManager.meetingAutoStartEnabled else { return }
        Task { @MainActor [weak self] in
            await self?.refreshMeetingDetection()
        }
    }

    private func reboundLifecycleMeeting(
        for event: MeetingCalendarEvent,
        activeSession: MeetingSessionInfo?
    ) -> MeetingContextDetector.DetectedMeeting? {
        if let activeMeetingLifecycleContext {
            return MeetingContextDetector.DetectedMeeting(
                app: activeMeetingLifecycleContext.app,
                windowTitle: activeMeetingLifecycleContext.windowTitle,
                browserURL: activeMeetingLifecycleContext.browserURL,
                calendarHint: event.hint,
                autoStartEligible: activeMeetingLifecycleContext.autoStartEligible
            )
        }

        if let currentMeeting = meetingContextDetector.currentMeeting {
            if let detectedApp = activeSession?.detectedApp,
               currentMeeting.app.bundleID.caseInsensitiveCompare(detectedApp.bundleID) != .orderedSame {
                // Ignore unrelated detector state and fall back to the recording session context below.
            } else {
                return MeetingContextDetector.DetectedMeeting(
                    app: currentMeeting.app,
                    windowTitle: currentMeeting.windowTitle,
                    browserURL: currentMeeting.browserURL,
                    calendarHint: event.hint,
                    autoStartEligible: currentMeeting.autoStartEligible
                )
            }
        }

        if let detectedApp = activeSession?.detectedApp {
            return MeetingContextDetector.DetectedMeeting(
                app: detectedApp,
                windowTitle: event.title,
                browserURL: event.conferencingURL,
                calendarHint: event.hint,
                autoStartEligible: false
            )
        }

        return nil
    }

    private func beginMeetingScratchpadProcessing(_ notepad: MeetingNotepad) {
        notepad.beginProcessing(stages: [
            (
                MeetingScratchpadProcessingStageID.determineLanguage.rawValue,
                "Stopping audio capture"
            ),
            (
                MeetingScratchpadProcessingStageID.understandContext.rawValue,
                "Understanding the context"
            ),
            (
                MeetingScratchpadProcessingStageID.identifyParticipants.rawValue,
                "Identifying the participants"
            ),
            (
                MeetingScratchpadProcessingStageID.resolveSpeakerNames.rawValue,
                "Thinking about how to refer to people"
            ),
            (
                MeetingScratchpadProcessingStageID.saveMeeting.rawValue,
                "Saving transcript and notes"
            ),
        ])
    }

    private func updateMeetingScratchpadProcessing(
        _ notepad: MeetingNotepad,
        stage: MeetingScratchpadProcessingStageID,
        status: MeetingNotepad.ProcessingStage.Status,
        detail: String? = nil
    ) {
        notepad.updateProcessingStage(id: stage.rawValue, status: status, detail: detail)
    }

    private func ensureMinimumMeetingScratchpadProcessingDuration(_ notepad: MeetingNotepad) async {
        guard let startedAt = notepad.processingStartedAt else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        let minimumDuration = Self.minimumMeetingScratchpadProcessingDuration
        guard elapsed < minimumDuration else { return }
        try? await Task.sleep(for: .seconds(minimumDuration - elapsed))
    }

    private func purgeExpiredHistoryForCurrentSetting() async {
        let days = settingsManager.historyRetentionDays
        let expiredMeetingIDs = await dataStore.purgeOldEntries(olderThan: days)
        await meetingWebhookSender.removeMeetings(ids: Set(expiredMeetingIDs))
        let memoLoadVerified = await memoManager.load(from: dataStore)
        if memoLoadVerified {
            await memoManager.purgeOldAudio(olderThan: days)
        }
        await activityStreamWriter.purgeOldFiles(olderThan: days)
        await archiveWriter.purgeOldArchive(olderThan: days)
        await feedManager.reload()
    }

    private func cleanupMeetingUtterances(_ utterances: [MeetingUtterance]) async -> [MeetingUtterance] {
        guard !utterances.isEmpty else { return utterances }

        // 1. Echo suppression: remove mic utterances that echo system audio
        var micUtterances = utterances.filter { $0.speaker == .you }
        let systemUtterances = utterances.filter { $0.speaker != .you }
        MeetingEchoSuppressor.suppress(micUtterances: &micUtterances, systemUtterances: systemUtterances)
        let deduped = (micUtterances + systemUtterances).sorted { $0.timestamp < $1.timestamp }

        // 2. Post-processing: filler removal, ITN, dictionary corrections, formatting
        var result = [MeetingUtterance]()
        result.reserveCapacity(deduped.count)
        for u in deduped {
            let cleaned = await postProcessor.process(u.text)
            guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            result.append(MeetingUtterance(text: cleaned, speaker: u.speaker, timestamp: u.timestamp))
        }
        return result
    }

    private func syncAmbientContextState() {
        // Never before onboarding: the AX grant is explained there as typing
        // delivery, so ambient reads must not begin until the user has at
        // least seen the flow that could have told them.
        if settingsManager.onboardingCompleted
            && settingsManager.ambientContextEnabled
            && settingsManager.contextMetadataEnabled
            && !settingsManager.hipaaMode {
            ambientContextCollector.start()
        } else {
            ambientContextCollector.stop()
        }
    }

    private func syncMCPServerState(removeManagedConfigurationWhenDisabled: Bool) {
        if settingsManager.mcpServerEnabled {
            mcpManager.enable()
        } else if removeManagedConfigurationWhenDisabled {
            mcpManager.disable()
        }
    }

    private func syncLocalAPIState(cleanUpWhenDisabled: Bool) {
        if settingsManager.localAPIEnabled {
            localAPIServer.start()
        } else if cleanUpWhenDisabled {
            localAPIServer.stop()
        }
    }

    func shutdown() {
        isShuttingDown = true
        retireInFlightAudioStartsForTerminalLifecycle(reason: "shutdown")
        systemPowerTransitionCoordinator.invalidate()
        cancelAllMeetingSummaryTasks()
        vocabularyBoostDownloadController.cancel()
        audioWarmUpRecoveryCoordinator.cancelPendingActivation()
        audioRecorder.teardownWarmSession()
        setLowLatencyWarmActivity(false)
        settingsManager.persistAll()
        dataStore.saveChanges()
        var properties: [String: Any] = [
            "selected_settings_tab": selectedSettingsTab?.rawValue ?? "unknown",
            "was_recording": isRecording,
            "dictation_count": analyticsManager.currentSessionDictationCount
        ]
        if let sessionDurationMs = analyticsManager.currentSessionDurationMs() {
            properties["session_duration_ms"] = sessionDurationMs
        }
        analyticsManager.capture("app_quit", properties: properties)
        analyticsManager.flush()
        hotkeyManager.teardown()
        let hasRecoveryOwnership = activeCaptureRecoveryID != nil
            || hasUnreadableActiveCaptureRecovery
        if DictationShutdownCleanupPolicy.shouldDeleteRecorderArtifacts(
            isRecording: isRecording,
            isStartingRecording: isStartingRecording,
            isFinishingCapture: isFinishingCapture,
            hasRecoveryOwnership: hasRecoveryOwnership
        ) {
            dictationManager.cleanup(preserveRecoveryArtifact: false)
        }
        Task { await hotMicManager.stop() }
        meetingContextDetector.stop()
        meetingPromptNotifier.clearPrompt()
        meetingCalendarPromptRefreshTask?.cancel()
        meetingCalendarPromptRefreshTask = nil
        meetingCalendarStoreChangeTask?.cancel()
        meetingCalendarStoreChangeTask = nil
        if let manager = meetingRecorderManager,
           let session = manager.activeSession {
            meetingNoteAutosaver.stop(for: manager.notepad)
            // Synchronous on the main context — `applicationWillTerminate` returns
            // and the process exits immediately afterward, so a fire-and-forget
            // Task would lose the user's last edits.
            meetingNoteAutosaver.persistSync(sessionID: session.id, snapshot: manager.notepad.snapshot)
        }
        meetingRecorderManager?.flushActiveSession()
        Task { await meetingRecorderManager?.teardown() }
        workspaceSyncEngine.stop()
        localAPIServer.stop()
        clamshellMicrophoneSwitcher.stop()
        notchWindowManager?.teardown()
        notificationObservers.removeAll()
    }

    /// Registers a default-center observer on the main queue, retained by
    /// `notificationObservers` so `shutdown()` removes it. Use instead of a bare
    /// `NotificationCenter.default.addObserver` whose token would be discarded.
    @discardableResult
    private func observeDefault(
        _ name: Notification.Name,
        using block: @escaping @Sendable (Notification) -> Void
    ) -> NSObjectProtocol {
        notificationObservers.observe(name, using: block)
    }

    // MARK: - Notch setup

    private func setupNotch() {
        guard notchWindowManager == nil else { return }
        let manager = NotchWindowManager(coordinator: notchCoordinator, appState: self)
        manager.setup()
        notchWindowManager = manager
    }

    // MARK: - Hotkey wiring

    private func wireHotkeys() {
        hotkeyManager.onDictationStart = { [weak self] in await self?.startDictation() }
        hotkeyManager.onDictationEnd   = { [weak self] in await self?.endDictation() }
        hotkeyManager.onMemoStart      = { [weak self] in await self?.startMemo() }
        hotkeyManager.onMemoEnd        = { [weak self] in await self?.endMemo() }
        hotkeyManager.onRecordingLock  = { [weak self] in await self?.lockCurrentRecording() }
        hotkeyManager.onCancel         = { [weak self] in await self?.cancelActiveInteraction() }
        hotkeyManager.setup(
            triggers: settingsManager.hotkeyTriggers,
            mode: settingsManager.hotkeyMode,
            holdToTalkLockEnabled: settingsManager.hotkeyHoldLockEnabled
        )
    }

    func refreshRuntimePermissions() {
        runtimeSupportActions.refreshRuntimePermissions()
    }

    /// macOS may bind fn to a system action ("Show Emoji", "Start Dictation", etc.),
    /// which silently consumes the keystroke before our event tap sees it. Surface a
    /// notch warning at launch so the user knows why fn appears dead.
    private func warnIfFnTriggerCapturedByOS() {
        guard settingsManager.hotkeyTriggers.contains(.fn) else { return }
        let diagnostics = HotkeyDiagnostics.current()
        guard let action = diagnostics.fnSystemAction else { return }
        Self.log.warning("fn is bound to system action '\(action, privacy: .public)' — keystrokes will be swallowed by macOS")
        Task { @MainActor [weak self] in
            // Defer until the notch window is visible.
            try? await Task.sleep(for: .milliseconds(800))
            guard let self else { return }
            self.notchCoordinator.showError(
                "macOS uses fn for \(action). Change it in System Settings → Keyboard, or pick another trigger.",
                subtype: .generic
            )
        }
    }

    func refreshAudioInputStatus() {
        let selectedInputDeviceUID = settingsManager.inputDeviceUID
        let selectedInputDeviceName = selectedInputDeviceUID.flatMap {
            audioInputDeviceManager.device(with: $0)?.name
        } ?? activeInputDeviceName

        audioInputDeviceManager.refresh()
        let hasInputDevices = !audioInputDeviceManager.devices.isEmpty

        if selectedInputDeviceUID != nil,
           !audioInputDeviceManager.containsDevice(with: selectedInputDeviceUID) {
            let fallbackDeviceName = audioInputDeviceManager.effectiveDevice(for: nil)?.name
            settingsManager.inputDeviceUID = nil
            inputRoutingUsesFallback = true
            fallbackUnavailableDeviceName = selectedInputDeviceName
            inputRoutingMessage = microphoneFallbackRoutingMessage(
                unavailableDeviceName: selectedInputDeviceName,
                fallbackDeviceName: fallbackDeviceName
            )
            // The system notification is easy to miss (and silently dropped when
            // notification permission is denied) — the notch alert is the one
            // the user reliably sees. Skipped when nothing is left to fall back
            // to: the "No microphone connected" alert below owns that story.
            if hasInputDevices {
                let switchNotice = inputRoutingMessage
                presentAudioInputAlertSoon { appState in
                    appState.notchCoordinator.showNotice(
                        NotchOverlayState.Notice(
                            title: "Microphone switched",
                            detail: switchNotice,
                            icon: "mic.fill"
                        ),
                        timeout: .seconds(7)
                    )
                }
                let notifier = microphoneSwitchNotifier
                Task {
                    await notifier.deliverSelectedMicrophoneUnavailableNotice(
                        unavailableDeviceName: selectedInputDeviceName,
                        fallbackDeviceName: fallbackDeviceName
                    )
                }
            }
        } else if !inputRoutingUsesFallback {
            inputRoutingMessage = nil
            fallbackUnavailableDeviceName = nil
        }

        if !hasInputDevices {
            inputRoutingMessage = "No microphone connected. Connect a microphone to dictate."
            if !lastAudioInputScanFoundNoDevices {
                presentAudioInputAlertSoon { appState in
                    appState.notchCoordinator.showError(
                        "No microphone connected. Connect a microphone to dictate.",
                        subtype: .microphone
                    )
                }
            }
        }
        lastAudioInputScanFoundNoDevices = !hasInputDevices

        activeInputDeviceName = audioInputDeviceManager.effectiveDevice(for: settingsManager.inputDeviceUID)?.name
    }

    /// Device scans can run during launch before the notch window exists, so
    /// alerts about them are delivered on a short delay (same pattern as the
    /// fn-trigger warning).
    private func presentAudioInputAlertSoon(
        _ present: @escaping @MainActor (AppState) -> Void
    ) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard let self else { return }
            present(self)
        }
    }

    func didChangeInputSelection() {
        inputRoutingUsesFallback = false
        inputRoutingMessage = nil
        fallbackUnavailableDeviceName = nil
        refreshAudioInputStatus()
        if settingsManager.lowLatencyMode {
            // Selection restarts are not genuine low-latency disables: keep an
            // active hardware-recovery deadline intact and re-enter through the
            // central activation gate.
            audioRecorder.teardownWarmSession()
            setLowLatencyWarmActivity(false)
            activateLowLatencyMode()
        }
    }

    // MARK: - Vocabulary boost

    /// Runtime truth for the Knowledge UI. The active adapter is read from the
    /// live registry; `settingsManager.selectedModelId` is intentionally absent.
    var vocabularyBoostRuntimeState: VocabularyBoostRuntimeState {
        VocabularyBoostRuntimeState.resolve(
            enabled: settingsManager.vocabularyBoostEnabled,
            liveAdapterSupportsBoosting: modelRegistry.active is FluidAudioAdapter,
            lowLatencyMode: settingsManager.lowLatencyMode,
            selectedLanguage: settingsManager.transcriptionLanguage,
            eligibleTermCount: vocabularyBoostEligibleTermCount,
            helperDownloadState: vocabularyBoostDownloadController.state
        )
    }

    var vocabularyBoostEligibleTermCount: Int {
        ParakeetVocabularyBoostEngine.normalizedTerms(currentVocabularyBoostTerms()).count
    }

    /// Current text-free consumer truth for Personalization Settings. The
    /// memory store invokes this provider once for every snapshot rather than
    /// retaining a launch-time copy of settings, adapter, helper, or access.
    var personalizationConsumerRuntimeContext: PersonalizationConsumerRuntimeContext {
        PersonalizationConsumerRuntimeContext(
            vocabularyBoost: vocabularyBoostRuntimeState,
            cloudCleanup: .resolve(
                cloudProcessingEnabled: settingsManager.cloudProcessingEnabled,
                lowLatencyMode: settingsManager.lowLatencyMode,
                isLoggedIn: authManager.isLoggedIn,
                polishSettings: settingsManager.dictationPolishSettings
            ),
            formatterGates: PersonalizationFormatterRuntimeGates(
                autoPunctuationEnabled: settingsManager.autoPunctuationEnabled,
                bulletPointsEnabled: settingsManager.bulletPointsEnabled
            )
        )
    }

    private func currentVocabularyBoostTerms() -> [VocabularyBoostTerm] {
        // Dictionary terms first: explicit curation wins under the cap. Learned
        // correction memory follows, then the current screen and Contacts.
        // Context-personalization holdout is deliberately not consulted: it
        // governs packet/profile context, not manual or CTC vocabulary.
        dictionaryStore.vocabularyBoostTerms(
            limit: ParakeetVocabularyBoostEngine.maximumTermCount
        ) + personalizationMemoryStore.recognitionBiasTerms().map {
            VocabularyBoostTerm(text: $0, source: .autoLearned)
        } + screenContextBiasSession.terms.map {
            VocabularyBoostTerm(text: $0, source: .screen)
        } + contactNameStore.importedNames.map {
            VocabularyBoostTerm(text: $0, source: .contact)
        }
    }

    /// Installs recognition-level vocabulary biasing on the Parakeet adapter.
    /// The terms provider is consulted per dictation, so toggling the setting
    /// or editing the dictionary needs no re-wiring. Boosting is skipped in
    /// low-latency mode — those users chose speed over the extra CTC pass.
    private func installVocabularyBoostEngine() {
        guard let adapter = modelRegistry.all
            .compactMap({ $0 as? FluidAudioAdapter })
            .first else { return }
        let engine = ParakeetVocabularyBoostEngine(
            termsProvider: { [weak self] in
                self?.currentVocabularyBoostTerms() ?? []
            },
            runtimeConfigurationProvider: { [weak self] in
                VocabularyBoostEngineRuntimeConfiguration(
                    enabled: self?.settingsManager.vocabularyBoostEnabled ?? false,
                    lowLatencyMode: self?.settingsManager.lowLatencyMode ?? false
                )
            },
            attemptRecorder: vocabularyBoostAttemptRecorder
        )
        vocabularyBoostEngine = engine
        adapter.installVocabularyBoostEngine(engine)
        reconcileVocabularyBoostHelperEligibility()
    }

    /// Re-aligns the boost vocabulary with the provider's current terms off
    /// the latency path — call whenever the screen-term set changes, so the
    /// next decode's fingerprint check is a no-op instead of a rebuild.
    private func prewarmVocabularyBoostEngine() {
        reconcileVocabularyBoostHelperEligibility()
        guard let engine = vocabularyBoostEngine else { return }
        let selectedLanguage = settingsManager.transcriptionLanguage
        Task { await engine.prewarm(selectedLanguage: selectedLanguage) }
    }

    /// Refresh installed helper availability as prerequisites change. This is
    /// network-silent; only the visible Download/Retry controls acquire it.
    func reconcileVocabularyBoostHelperEligibility() {
        let applicability = vocabularyBoostRuntimeState.applicability
        Task { @MainActor [weak self] in
            await self?.vocabularyBoostDownloadController.reconcileAutomaticDownload(
                isEligible: applicability.allowsAutomaticHelperDownload,
                cancelInFlightOnLoss: applicability.cancelsInFlightAutomaticDownload
            )
        }
    }

    /// A visible, deliberate prefetch is allowed even when the current runtime
    /// cannot apply vocabulary recognition.
    func downloadVocabularyBoostModelManually() {
        Task { @MainActor [weak self] in
            await self?.vocabularyBoostDownloadController.startManualDownload()
        }
    }

    func retryVocabularyBoostModelDownload() {
        Task { @MainActor [weak self] in
            await self?.vocabularyBoostDownloadController.retry()
        }
    }

    /// Settings and the live adapter are observable. Term-bearing stores use
    /// the callbacks wired in `init`; both paths converge on
    /// `vocabularyBoostInputsDidChange()` so automatic acquisition cannot
    /// silently diverge from the runtime state shown in Settings.
    private func armVocabularyBoostEligibilityObservation() {
        withObservationTracking {
            _ = settingsManager.vocabularyBoostEnabled
            _ = settingsManager.lowLatencyMode
            _ = settingsManager.transcriptionLanguage
            _ = modelRegistry.active?.id
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.armVocabularyBoostEligibilityObservation()
                self.vocabularyBoostInputsDidChange()
            }
        }
    }

    private func vocabularyBoostInputsDidChange() {
        reconcileVocabularyBoostHelperEligibility()
        guard let engine = vocabularyBoostEngine else { return }
        let selectedLanguage = settingsManager.transcriptionLanguage
        Task { await engine.prewarm(selectedLanguage: selectedLanguage) }
    }

    /// Non-Fluid backends never enter the adapter/engine instrumentation, so
    /// AppState closes that branch at each transcription entry point.
    private func recordUnsupportedVocabularyBoostAdapterAttemptIfNeeded() async {
        guard let activeAdapter = modelRegistry.active,
              !(activeAdapter is FluidAudioAdapter) else { return }
        await vocabularyBoostAttemptRecorder.record(
            VocabularyBoostAttemptRouter.unsupportedAdapterOutcome(
                enabled: settingsManager.vocabularyBoostEnabled
            )
        )
    }

    // MARK: - Low-latency mode

    private var shouldSuppressPersistentAudioWarmUp: Bool {
        let manager = meetingRecorderManager
        return PersistentAudioWarmUpPolicy.shouldSuppress(
            hasStartupSuppression: hasMeetingWarmUpStartupSuppression,
            isMeetingStarting: manager?.isStartingSession ?? false,
            isMeetingRecording: manager?.isRecording ?? false,
            isMeetingFinalizing: manager?.isFinalizing ?? false,
            isLocalCaptureActive: isRecording || isStartingRecording || isFinishingCapture,
            isSystemSleeping: isSystemSleeping,
            isShuttingDown: isShuttingDown,
            isClearingWorkspace: isClearingWorkspace
        )
    }

    private var allowsLocalAudioCapture: Bool {
        let manager = meetingRecorderManager
        return LocalAudioCaptureAdmissionPolicy.allowsCapture(
            hasMeetingStartupSuppression: hasMeetingWarmUpStartupSuppression,
            isMeetingStarting: manager?.isStartingSession ?? false,
            isMeetingRecording: manager?.isRecording ?? false,
            isMeetingFinalizing: manager?.isFinalizing ?? false,
            isSystemSleeping: isSystemSleeping,
            isShuttingDown: isShuttingDown,
            isClearingWorkspace: isClearingWorkspace
        )
    }

    private func canContinueAudioStart(ownsStartAttempt: Bool) -> Bool {
        AudioStartContinuationPolicy.shouldContinue(
            ownsStartAttempt: ownsStartAttempt,
            isSystemSleeping: isSystemSleeping,
            isShuttingDown: isShuttingDown,
            isClearingWorkspace: isClearingWorkspace
        )
    }

    private var allowsBackgroundMicrophoneActivation: Bool {
        let manager = meetingRecorderManager
        return BackgroundMicrophoneActivationPolicy.allowsActivation(
            terminalCaptureAllowed: allowsLocalAudioCapture,
            isLocalCaptureRecording: isRecording,
            isLocalCaptureStarting: isStartingRecording,
            isMeetingStarting: manager?.isStartingSession ?? false,
            isMeetingRecording: manager?.isRecording ?? false,
            isMeetingFinalizing: manager?.isFinalizing ?? false
        )
    }

    private var allowsRuntimeServiceRestoration: Bool {
        !isSystemSleeping && !isShuttingDown && !isClearingWorkspace
    }

    func activateLowLatencyMode() {
        guard settingsManager.lowLatencyMode else {
            setLowLatencyWarmActivity(false)
            return
        }

        if shouldSuppressPersistentAudioWarmUp {
            setLowLatencyWarmActivity(false)
            return
        }

        if audioWarmUpRecoveryCoordinator.deferActivationIfNeeded({ [weak self] in
            self?.rewarmIfLowLatency()
        }) {
            setLowLatencyWarmActivity(false)
            return
        }

        setLowLatencyWarmActivity(false)
        audioRecorder.warmUp(selectedInputDeviceUID: settingsManager.inputDeviceUID)
    }

    func deactivateLowLatencyMode() {
        audioWarmUpRecoveryCoordinator.cancelPendingActivation()
        audioRecorder.teardownWarmSession()
        setLowLatencyWarmActivity(false)
    }

    private func rewarmIfLowLatency() {
        if settingsManager.lowLatencyMode {
            activateLowLatencyMode()
        }
    }

    private func rewarmAfterFailedRecordingStartIfNeeded() {
        guard FailedLocalCaptureWarmUpPolicy.shouldRequestPersistentWarmUp(
            isLowLatencyEnabled: settingsManager.lowLatencyMode,
            isRecording: isRecording,
            isStartingRecording: isStartingRecording,
            isFinishingCapture: isFinishingCapture
        ) else { return }
        rewarmIfLowLatency()
    }

    private func setLowLatencyWarmActivity(_ isActive: Bool) {
        isLowLatencyReady = isActive
        let shouldShowMicrophoneActivity = !isSystemSleeping
            && !isShuttingDown
            && !isClearingWorkspace
            && (isActive || isRecording || isStartingRecording)
        onMenuBarRecordingActivityChange?(shouldShowMicrophoneActivity)
    }

    private func handleWarmSessionReadyChange(_ isReady: Bool) {
        guard isReady,
              settingsManager.lowLatencyMode,
              !shouldSuppressPersistentAudioWarmUp else {
            setLowLatencyWarmActivity(false)
            return
        }
        setLowLatencyWarmActivity(true)
    }

    /// Invalidates queued warm work before publishing the stabilization window.
    /// Both operations are synchronous MainActor state changes; callers may
    /// safely invoke this immediately before their first suspension point.
    private func beginAudioHardwareRecovery() {
        audioRecorder.teardownWarmSession()
        audioWarmUpRecoveryCoordinator.enterRecovery()
        setLowLatencyWarmActivity(false)
    }

    /// Synchronously retires ownership before terminal lifecycle cleanup can
    /// suspend. The async cancellation then joins any recorder/meeting source
    /// that was already inside its hardware start.
    private func retireInFlightAudioStartsForTerminalLifecycle(reason: String) {
        meetingStartOwnership.cancel()

        if isStartingRecording {
            disarmStartingRecordingWatchdog()
            Task { @MainActor [weak self] in
                await self?.cancelRecording(
                    reason: reason,
                    shouldTrackCancellation: false
                )
            }
        }

        if let manager = meetingRecorderManager, manager.isStartingSession {
            Task { @MainActor [weak manager] in
                guard let manager,
                      manager.isStartingSession,
                      manager.isRecording else { return }
                await manager.discardSession()
            }
        }
    }

    // MARK: - System sleep/wake

    private func prepareForSystemSleep() {
        isSystemSleeping = true
        retireInFlightAudioStartsForTerminalLifecycle(reason: "system_sleep")
        audioWarmUpRecoveryCoordinator.cancelPendingActivation()
        audioRecorder.teardownWarmSession()
        setLowLatencyWarmActivity(false)
    }

    private func finishSystemSleepPreparation(
        stillOwnsTransition: SystemPowerTransitionCoordinator.OwnershipCheck
    ) async {
        guard stillOwnsTransition(), isSystemSleeping, !isShuttingDown else { return }
        // `pause()` intentionally ignores a startup that has not become active
        // yet. Sleep needs the stronger boundary: publish lifecycle
        // invalidation synchronously and join any suspended start/resume before
        // the transition may finish.
        await hotMicManager.stopAndWait()
        guard stillOwnsTransition(), isSystemSleeping, !isShuttingDown else { return }
        await workspaceSyncEngine.stopAndWait()
        guard stillOwnsTransition(), isSystemSleeping, !isShuttingDown else { return }
        meetingContextDetector.stop()
    }

    private func prepareForSystemWake() {
        isSystemSleeping = false
        beginAudioHardwareRecovery()
    }

    private func finishSystemWakePreparation(
        stillOwnsTransition: SystemPowerTransitionCoordinator.OwnershipCheck
    ) async {
        guard stillOwnsTransition(), allowsRuntimeServiceRestoration else { return }
        await resumeHotMicAfterDictation()
        guard stillOwnsTransition(), allowsRuntimeServiceRestoration else { return }
        if settingsManager.hotMicEnabled,
           !hotMicManager.isActive,
           !hotMicManager.isPaused {
            await startHotMic()
        }
        guard stillOwnsTransition(), allowsRuntimeServiceRestoration else { return }
        rewarmIfLowLatency()
        guard stillOwnsTransition(), allowsRuntimeServiceRestoration else { return }
        await workspaceSyncEngine.start()
        guard stillOwnsTransition(), allowsRuntimeServiceRestoration else { return }
        syncAmbientContextState()
        syncMeetingDetectionState()
    }

    // MARK: - Hot mic

    func startHotMic() async {
        guard allowsBackgroundMicrophoneActivation else { return }
        guard !hotMicManager.isActive, !hotMicManager.isPaused else { return }
        guard modelRegistry.activeIsReady else {
            showModelNotReadyForUser()
            settingsManager.hotMicEnabled = false
            return
        }

        hotMicManager.onPasteTriggered = { [weak self] text in
            await self?.handleHotMicPaste(text: text)
        }
        hotMicManager.onStateUpdate = { [weak self] level, liveText in
            guard let self, self.hotMicManager.isActive else { return }
            self.notchCoordinator.setState(.hotMic(level: level, liveText: liveText))
        }
        hotMicManager.onFatalError = { [weak self] message in
            guard let self else { return }
            self.notchCoordinator.showError(message, subtype: .generic)
            Task { @MainActor [weak self] in
                await self?.hotMicManager.stop()
                self?.settingsManager.hotMicEnabled = false
            }
        }

        do {
            try await hotMicManager.start(inputDeviceUID: settingsManager.inputDeviceUID)
            guard allowsBackgroundMicrophoneActivation else {
                await retireHotMicAfterAdmissionLoss()
                return
            }
            notchCoordinator.setState(.hotMic(level: 0, liveText: ""))
        } catch {
            guard allowsLocalAudioCapture else { return }
            SentryManager.shared.hotMicError(error)
            settingsManager.hotMicEnabled = false
            notchCoordinator.showError("Hot mic failed to start", subtype: .generic)
        }
    }

    private func showModelWarming(detail: String?) {
        notchCoordinator.setState(.notice(NotchOverlayState.Notice(
            title: "Warming up local model…",
            detail: detail,
            icon: "hourglass"
        )))
    }

    private static func warmingDetail(stage: String, progress: Double) -> String {
        let pct = Int((progress * 100).rounded())
        let trimmed = stage.trimmingCharacters(in: CharacterSet(charactersIn: "…. "))
        if pct > 0 && pct < 100 {
            return "\(trimmed) · \(pct)%"
        }
        return trimmed
    }

    /// Surfaces a just-promoted auto-learned dictionary word so learning is
    /// visible instead of silent. Promotions often fire during
    /// `flushBeforeDictation` at the start of the next capture, and the notice
    /// must never replace an active recording/processing strip — so when the
    /// notch is busy the notice queues and shows once it returns to idle.
    private func showOrQueueLearnedWordNotice(written: String?) {
        guard let written = written?.trimmingCharacters(in: .whitespacesAndNewlines),
              !written.isEmpty else { return }
        if case .idle = notchCoordinator.state {
            showLearnedWordNotice(words: [written])
            return
        }
        guard pendingLearnedWordNotices.count < 5,
              !pendingLearnedWordNotices.contains(written) else { return }
        pendingLearnedWordNotices.append(written)
        scheduleLearnedWordNoticeFlush()
    }

    private func scheduleLearnedWordNoticeFlush() {
        guard learnedWordNoticeFlushTask == nil else { return }
        learnedWordNoticeFlushTask = Task { @MainActor [weak self] in
            defer { self?.learnedWordNoticeFlushTask = nil }
            // Poll briefly for an idle notch; a learned-word notice that is a
            // minute stale is noise, so give up quietly after that.
            for _ in 0..<30 {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                guard case .idle = self.notchCoordinator.state else { continue }
                let words = self.pendingLearnedWordNotices
                self.pendingLearnedWordNotices.removeAll()
                if !words.isEmpty {
                    self.showLearnedWordNotice(words: words)
                }
                return
            }
            self?.pendingLearnedWordNotices.removeAll()
        }
    }

    private func showLearnedWordNotice(words: [String]) {
        guard let first = words.first else { return }
        let title = words.count == 1
            ? "Learned “\(first)”"
            : "Learned \(words.count) words"
        let detail = words.count == 1
            ? "Now applied automatically. Manage in Settings → Dictionary."
            : "\(words.map { "“\($0)”" }.joined(separator: ", ")) — now applied automatically."
        notchCoordinator.showNotice(
            NotchOverlayState.Notice(
                title: title,
                detail: detail,
                icon: "character.book.closed.fill"
            ),
            timeout: .seconds(4)
        )
    }

    // MARK: - Learn-word prompt

    /// A correction that looked like a name fix but was too uncertain to learn
    /// silently — ask the user via notification instead of guessing.
    func offerToLearnWord(_ candidate: CorrectionDiffEngine.Candidate) async {
        guard !dictionaryStore.hasEntry(spoken: candidate.spoken) else { return }
        guard wordLearnPromptNotifier.shouldPrompt(spoken: candidate.spoken) else { return }
        let outcome = await wordLearnPromptNotifier.deliverPrompt(
            spoken: candidate.spoken,
            written: candidate.written
        )
        // Only a prompt the user could actually see counts as shown — the event
        // used to fire ahead of delivery and over-counted suppressed prompts.
        guard outcome == .delivered else { return }
        analyticsManager.capture("dictionary_learn_prompt_shown", properties: [
            "written_length": candidate.written.count
        ])
    }

    func handleWordLearnPromptResponse(_ response: UNNotificationResponse) {
        guard let pair = WordLearnPromptNotifier.pair(
            from: response.notification.request.content.userInfo
        ) else { return }

        switch response.actionIdentifier {
        case WordLearnPromptNotifier.learnActionIdentifier:
            dictionaryStore.add(spoken: pair.spoken, written: pair.written)
            analyticsManager.capture("dictionary_learn_prompt_accepted", properties: [
                "written_length": pair.written.count
            ])
            showOrQueueLearnedWordNotice(written: pair.written)
        case WordLearnPromptNotifier.skipActionIdentifier:
            dictionaryStore.declineSuggestion(spoken: pair.spoken, written: pair.written)
            analyticsManager.capture("dictionary_learn_prompt_declined", properties: [:])
        case UNNotificationDefaultActionIdentifier:
            // Tapping the body is not consent to learn — open the dictionary
            // so the user can decide there.
            showPrimaryWindow(selectedTab: .dictionary)
        default:
            break
        }
    }

    private func showModelNotReadyForUser() {
        playAudioCue(.error)
        switch modelRegistry.preparationState {
        case .downloading(let progress):
            let pct = Int((progress * 100).rounded())
            notchCoordinator.showError("Local model warming up… \(pct)%", subtype: .model)
        case .loading:
            notchCoordinator.showError("Local model warming up…", subtype: .model)
        case .failed(let message):
            notchCoordinator.showError("Local model failed: \(message)", subtype: .model)
        case .idle:
            notchCoordinator.showError("Local model not ready — open Settings and choose Download.", subtype: .model)
        case .ready:
            // activeIsReady is false but state says ready — race after select(). Retry prep silently.
            notchCoordinator.showError("Reloading local model…", subtype: .model)
            Task { try? await modelRegistry.prepareActive(source: .hotkeyRecovery) }
        }
    }

    func stopHotMic() async {
        await hotMicManager.stop()
        notchCoordinator.setState(.idle)
        playAudioCue(.stop)
    }

    private func pauseHotMicForDictation() async {
        guard hotMicManager.isActive else { return }
        await hotMicManager.pause()
    }

    private func resumeHotMicAfterDictation() async {
        guard allowsBackgroundMicrophoneActivation else { return }
        guard hotMicManager.isPaused, settingsManager.hotMicEnabled else { return }
        do {
            try await hotMicManager.resume()
            guard allowsBackgroundMicrophoneActivation else {
                await retireHotMicAfterAdmissionLoss()
                return
            }
            notchCoordinator.setState(.hotMic(level: 0, liveText: ""))
        } catch {
            guard allowsLocalAudioCapture else { return }
            SentryManager.shared.hotMicError(error)
            settingsManager.hotMicEnabled = false
            notchCoordinator.showError("Hot mic failed to resume", subtype: .generic)
        }
    }

    private func retireHotMicAfterAdmissionLoss() async {
        if isShuttingDown || isClearingWorkspace {
            await hotMicManager.stop()
        } else {
            await hotMicManager.pause()
        }
    }

    private func pauseMediaForRecordingIfNeeded() {
        dictationMediaController.beginPausePlaybackIfNeeded(
            enabled: settingsManager.pauseMediaWhileRecording
        )
        systemOutputAudioController.beginDuckingIfNeeded(
            enabled: settingsManager.duckSystemAudioWhileRecording
        )
    }

    private func resumeMediaAfterRecording() {
        Task { [dictationMediaController] in
            await dictationMediaController.resumePlaybackIfNeeded()
        }
        systemOutputAudioController.endDuckingIfNeeded()
    }

    private func handleHotMicPaste(text: String) async {
        let targetApplication = activeTargetApplication()
        let shouldPaste = settingsManager.autoPasteEnabled
        let shouldCopy = settingsManager.copyToClipboardEnabled
        let shouldSend = shouldPaste && settingsManager.autoSendEnabled
        let finalText = applySmartLinksIfNeeded(to: text, source: "hot_mic")
        let hotContext = await contextExtractor.extractHot(from: targetApplication)
        let windowTitle = hotContext.windowTitle.nilIfEmpty
        let browserURL = hotContext.browserURL.nilIfEmpty
        let appName = hotContext.appName.nilIfEmpty ?? targetApplication?.localizedName
        let bundleId = hotContext.bundleId.nilIfEmpty ?? targetApplication?.bundleIdentifier
        let focusedFieldContent = hotContext.focusedFieldContent.nilIfEmpty ?? pasteManager.focusedFieldContent(
            for: targetApplication,
            windowTitle: windowTitle,
            browserURL: browserURL
        )
        let focusedFieldContext = pasteManager.focusedFieldContext(for: targetApplication)
        let signatureEmailMode = CloudProcessingSupport.emailDictationMode(
            transcript: finalText,
            focusedFieldContent: focusedFieldContent,
            focusedFieldContext: focusedFieldContext,
            appName: appName,
            bundleId: bundleId,
            windowTitle: windowTitle,
            browserURL: browserURL,
            fallbackSenderName: settingsManager.resolvedEmailSignoffName
        )
        let deliveryText = EmailSignatureSupport.applyingIfNeeded(
            to: finalText,
            enabled: settingsManager.emailSignatureEnabled && AppRuntime.distributionFlavor == .official,
            appName: appName,
            bundleId: bundleId,
            windowTitle: windowTitle,
            browserURL: browserURL,
            emailMode: signatureEmailMode,
            existingFieldContent: focusedFieldContent,
            focusedFieldContext: focusedFieldContext,
            decisionHandler: { decision in
                self.logEmailSignatureDecision(decision, source: "hot_mic")
            }
        )
        let deliveryOutcome = await pasteManager.deliverWithOutcome(
            text: deliveryText,
            copyToClipboard: shouldCopy,
            autoPaste: shouldPaste,
            autoSend: shouldSend,
            captureReceipt: false,
            targetApplication: targetApplication,
            windowTitle: windowTitle,
            browserURL: browserURL,
            deliveryMode: settingsManager.pasteDeliveryMode
        )
        _ = await deliveryPersonalizationRouter.route(DeliveryPersonalizationRequest(
            deliveryOutcome: deliveryOutcome,
            autoPasteRequested: shouldPaste,
            autoSendRequested: shouldSend,
            copiedToClipboard: shouldCopy && deliveryOutcome.delivered,
            selectionTransformUsed: false,
            targetApplication: targetApplication,
            surface: SurfaceClassifier.classify(hot: hotContext),
            windowTitle: windowTitle,
            browserURL: browserURL,
            rawTranscript: nil,
            contextPacket: nil,
            personalizationExposure: nil,
            qualityTrace: nil,
            boostAudit: nil,
            confidence: nil,
            appliedStylePolicy: .none
        ))
        let delivered = shouldSend ? deliveryOutcome.sent : deliveryOutcome.delivered
        let copiedFallback = delivered ? false : fallbackCopyAfterFailedDelivery(text: deliveryText)

        let wordCount = finalText.split(separator: " ").count
        let capturedContext = CapturedContext(
            appName: appName,
            bundleId: bundleId
        )
        let entry = DictationEntry.make(
            id: UUID(),
            text: finalText,
            context: capturedContext,
            wordCount: wordCount,
            duration: 0,
            mode: .dictation,
            date: Date(),
            deliveredText: deliveryText != finalText ? deliveryText : nil
        )
        await dataStore.save(entry)
        feedManager.record(entry)

        analyticsManager.capture("hot_mic_paste", properties: [
            "word_count": wordCount,
            "delivered": delivered,
            "auto_pasted": shouldPaste && deliveryOutcome.delivered,
            "auto_sent": shouldSend && deliveryOutcome.sent,
            "copied_fallback": copiedFallback,
            "paste_delivery_mode": settingsManager.pasteDeliveryMode.rawValue
        ])

        if delivered {
            playAudioCue(.success)
            notchCoordinator.showHotMicDone(shouldSend ? "Sent!" : "Pasted!")
        } else if shouldSend && deliveryOutcome.delivered {
            playAudioCue(.warning)
            notchCoordinator.showError(
                copiedFallback
                    ? "Text was pasted but not sent. A copy is on your clipboard."
                    : "Text was pasted but not sent.",
                subtype: .generic
            )
        } else {
            handlePasteFailurePresentation(copiedFallback: copiedFallback)
        }
    }

    // MARK: - Dispatch (voice command mode)

    func setupDispatch() {
        commandRouter.configure(
            pasteManager: pasteManager,
            dataStore: dataStore,
            convexClient: convexClient,
            learningStore: dispatchLearningStore,
            cloudFallbackEnabled: settingsManager.dispatchCloudFallbackEnabled
        )
        commandRouter.voiceFeedback.enabled = settingsManager.dispatchTTSEnabled

        Task {
            await commandRouter.voiceFeedback.initialize()
        }

        // Wire MCP write tools to the action executor
        WorkspaceTools.onWriteToolCall = { [weak self] tool, args in
            guard let self else {
                return WorkspaceToolCallResult(toolName: tool, payload: .object(["message": .string("App not ready")]), isError: true)
            }
            return await self.handleMCPWriteTool(tool: tool, args: args)
        }

        if AppFeatureVisibility.dispatch && settingsManager.dispatchEnabled {
            registerCommandShortcut()
            patternInferenceEngine.startObserving()
        }

        observeDefault(.dispatchEnabledChanged) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if AppFeatureVisibility.dispatch && self.settingsManager.dispatchEnabled {
                    self.registerCommandShortcut()
                    self.patternInferenceEngine.startObserving()
                } else {
                    self.unregisterCommandShortcut()
                    self.patternInferenceEngine.stopObserving()
                }
            }
        }

        Defaults.observe(.dispatchTTSEnabled) { [weak self] change in
            Task { @MainActor in
                self?.commandRouter.voiceFeedback.enabled = change.newValue
            }
        }.tieToLifetime(of: self)

        Defaults.observe(.dispatchCloudFallbackEnabled) { [weak self] change in
            Task { @MainActor in
                self?.commandRouter.cloudFallbackEnabled = change.newValue
            }
        }.tieToLifetime(of: self)
    }

    private func registerCommandShortcut() {
        // Fn+Shift is detected globally in HotkeyManager's modifier handling.
        // Hold the chord to record a command, release it to process.
        hotkeyManager.onCommandStart = { [weak self] in
            guard let self else { return }
            await self.startCommandMode()
        }
        hotkeyManager.onCommandEnd = { [weak self] in
            guard let self else { return }
            await self.endCommandMode()
        }
    }

    private func unregisterCommandShortcut() {
        hotkeyManager.onCommandToggle = nil
        hotkeyManager.onCommandStart = nil
        hotkeyManager.onCommandEnd = nil
    }

    private var isInCommandMode = false
    private var activeCommandID: UUID?

    func toggleCommandMode() async {
        if isInCommandMode {
            await endCommandMode()
        } else {
            await startCommandMode()
        }
    }

    func startCommandMode() async {
        commandFollowUpTask?.cancel()
        commandFollowUpTask = nil
        guard allowsLocalAudioCapture else { return }
        guard !isInCommandMode else { return }
        guard !isRecording, !isStartingRecording, !isFinishingCapture else {
            Self.log.info("startCommandMode busy isRecording=\(self.isRecording, privacy: .public) isStarting=\(self.isStartingRecording, privacy: .public) isFinishing=\(self.isFinishingCapture, privacy: .public) hotkeySource=\(self.hotkeyManager.lastTriggerSource, privacy: .public)")
            dispatchTrialStore.recordSystemFailure(
                label: .commandBusy,
                message: "Command mode could not start because Resonant was busy.",
                targetApplicationName: activeTargetApplication()?.localizedName
            )
            playAudioCue(.error)
            notchCoordinator.showError("Resonant is busy — try again in a sec.", subtype: .generic)
            return
        }
        guard !rejectNewCaptureForPendingRecovery() else { return }
        guard modelRegistry.activeIsReady else {
            dispatchTrialStore.recordSystemFailure(
                label: .modelNotReady,
                message: "Command mode could not start because the active model was not ready.",
                targetApplicationName: activeTargetApplication()?.localizedName
            )
            showModelNotReadyForUser()
            return
        }

        // Below the entry guards on purpose: a rejected command press (busy,
        // model not ready) must not wipe an in-flight dictation's screen
        // terms. Command decodes share the boost engine with dictation and
        // must never inherit a previous target's terms.
        screenContextBiasSession.begin()
        prewarmVocabularyBoostEngine()
        isInCommandMode = true
        currentMode = .command
        let startAttemptID = beginRecordingStartAttempt()
        let commandID = UUID()
        activeCommandID = commandID
        recordingStartedAt = Date()
        recordingTargetApplication = activeTargetApplication()
        notchCoordinator.setState(.command(stage: .thinking(status: "Opening microphone...")))

        pauseMediaForRecordingIfNeeded()
        await pauseHotMicForDictation()
        guard recordingStartOwnership.owns(startAttemptID) else { return }

        audioRecorder.onLevelUpdate = { [weak self] level in
            guard let self, self.isInCommandMode else { return }
            let elapsed = Date().timeIntervalSince(self.recordingStartedAt ?? Date())
            self.notchCoordinator.setState(.command(stage: .listening(level: level, elapsed: elapsed)))
        }

        do {
            try await startRecordingWithFallback(startAttemptID: startAttemptID)
            guard finishRecordingStartAttempt(startAttemptID), isStartingRecording else { return }
            isStartingRecording = false
            isRecording = true
            recordingStartedAt = Date()
            notchCoordinator.setState(.command(stage: .listening(level: 0, elapsed: 0)))
            if pendingStopAfterStart {
                pendingStopAfterStart = false
                await endCommandMode()
            }
        } catch is CancellationError {
            guard finishRecordingStartAttempt(startAttemptID) else { return }
            if isStartingRecording {
                await cancelRecording(reason: "start_cancelled", shouldTrackCancellation: false)
            }
            return
        } catch {
            guard finishRecordingStartAttempt(startAttemptID) else { return }
            dispatchTrialStore.recordSystemFailure(
                label: .micStartFailed,
                message: "Command mode failed to start: \(error.localizedDescription)",
                targetApplicationName: recordingTargetApplication?.localizedName
            )
            isStartingRecording = false
            isInCommandMode = false
            currentMode = .dictation
            pendingStopAfterStart = false
            activeCommandID = nil
            audioRecorder.onLevelUpdate = nil
            recordingStartedAt = nil
            recordingTargetApplication = nil
            resumeMediaAfterRecording()
            await resumeHotMicAfterDictation()
            playAudioCue(.error)
            notchCoordinator.showError("Command mode failed to start", subtype: .generic)
            rewarmAfterFailedRecordingStartIfNeeded()
        }
    }

    func endCommandMode() async {
        guard isInCommandMode, currentMode == .command else { return }
        if isStartingRecording {
            pendingStopAfterStart = true
            return
        }
        guard isRecording else {
            await cancelActiveInteraction(reason: "command_end_without_recording")
            return
        }

        isRecording = false
        isFinishingCapture = true
        let finalizationRetirement = beginCaptureFinalizationRetirement()
        audioRecorder.onLevelUpdate = nil
        notchCoordinator.setState(.command(stage: .thinking(status: "Transcribing command...")))
        let commandID = activeCommandID

        defer {
            if captureCancellationQuiescenceID == nil {
                isFinishingCapture = false
                rewarmIfLowLatency()
            }
            isInCommandMode = false
            currentMode = .dictation
            recordingStartedAt = nil
            recordingTargetApplication = nil
            activeCommandID = nil
            completeCaptureFinalizationRetirement(finalizationRetirement)
        }

        do {
            await recordUnsupportedVocabularyBoostAdapterAttemptIfNeeded()
            let result = try await dictationManager.stopAndTranscribe(
                targetApplication: recordingTargetApplication,
                preloadedHotContext: nil,
                fallbackSelectedText: nil,
                fallbackSelectedRange: nil,
                latencyLogger: nil,
                onCaptureStopped: { [weak self] in
                    self?.playAudioCue(.stop)
                    self?.resumeMediaAfterRecording()
                },
                recordingRetention: .ephemeral
            )

            let commandText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !commandText.isEmpty else {
                dispatchTrialStore.recordSystemFailure(
                    label: .emptyTranscript,
                    message: "No command transcript was produced.",
                    targetApplicationName: recordingTargetApplication?.localizedName
                )
                notchCoordinator.setState(.command(stage: .result(text: "No command heard.", success: false)))
                playAudioCue(.warning)
                await resumeHotMicAfterDictation()
                scheduleReturnToIdle()
                return
            }

            // If cancelRecording fired while we were transcribing, drop the result.
            guard commandID != nil, activeCommandID == commandID else {
                await resumeHotMicAfterDictation()
                return
            }

            if let trialOutcome = DispatchTrialStore.outcome(fromSpokenCommand: commandText) {
                if let record = dispatchTrialStore.markOutcome(outcome: trialOutcome) {
                    notchCoordinator.setState(.command(stage: .result(
                        text: "Marked trial \(trialOutcome.displayName.lowercased()).",
                        success: trialOutcome == .worked
                    )))
                    analyticsManager.capture("dispatch_trial_outcome", properties: [
                        "outcome": trialOutcome.rawValue,
                        "scenario_id": record.scenarioID ?? "ad_hoc"
                    ])
                } else {
                    notchCoordinator.setState(.command(stage: .result(
                        text: "No Dispatch trial to mark.",
                        success: false
                    )))
                }
                playAudioCue(trialOutcome == .worked ? .agentSuccess : .agentFailure)
                await resumeHotMicAfterDictation()
                scheduleReturnToIdle()
                return
            }

            let trialID = dispatchTrialStore.startCommandTrace(
                transcript: commandText,
                contextPacket: result.contextPacket,
                targetApplicationName: recordingTargetApplication?.localizedName,
                recordingStartedAt: recordingStartedAt
            )
            let commandProcessingStartedAt = Date()

            analyticsManager.capture("dispatch_command", properties: [
                "command_length": commandText.count,
                "target_app": recordingTargetApplication?.localizedName ?? "unknown"
            ])

            var commandPresentation = DispatchCommandPresentationState(heardText: commandText)
            let updateCommandProgress: DispatchCommandProgressHandler = { [weak self] progress in
                guard let self, self.activeCommandID == commandID, self.currentMode == .command else { return }
                self.dispatchTrialStore.recordProgress(progress, trialID: trialID)
                self.notchCoordinator.setState(.command(stage: .thinking(
                    status: commandPresentation.status(after: progress)
                )))
            }

            notchCoordinator.setState(.command(stage: .thinking(status: commandPresentation.initialStatus())))
            playAudioCue(.agentStart)

            let commandResult = await commandRouter.processCommand(
                transcribedText: commandText,
                contextPacket: result.contextPacket,
                onProgress: updateCommandProgress
            )

            // Check again after cloud round-trip — cancel may have fired during processCommand.
            guard activeCommandID == commandID else {
                await resumeHotMicAfterDictation()
                return
            }

            let success = commandResult.actionResult?.success ?? false
            dispatchTrialStore.finishCommandTrace(
                trialID: trialID,
                result: commandResult,
                totalLatencyMs: max(0, Int(Date().timeIntervalSince(commandProcessingStartedAt) * 1000))
            )
            scheduleDispatchTrialVerification(trialID: trialID)
            let handledCorrection = DispatchLearningStore.correctionKind(for: commandText) != nil
            notchCoordinator.setState(.command(stage: .result(
                text: commandPresentation.resultStatus(commandResult.feedback),
                success: success
            )))

            if success {
                playAudioCue(.agentSuccess)
            } else {
                playAudioCue(.agentFailure)
            }

            if !success, commandResult.recovery != nil {
                if settingsManager.dispatchTTSEnabled {
                    commandRouter.speakResult(commandResult) { [weak self] in
                        Task { @MainActor in
                            self?.scheduleCommandFollowUp(
                                parentCommand: commandText,
                                parentContext: result.contextPacket
                            )
                        }
                    }
                } else {
                    scheduleCommandFollowUp(parentCommand: commandText, parentContext: result.contextPacket)
                }
            } else if success, settingsManager.dispatchTTSEnabled {
                commandRouter.speakResult(commandResult) { [weak self] in
                    Task { @MainActor in
                        await self?.resumeHotMicAfterDictation()
                    }
                }
            } else if success {
                await resumeHotMicAfterDictation()
            } else if settingsManager.dispatchTTSEnabled {
                commandRouter.speakResult(commandResult) { [weak self] in
                    Task { @MainActor in
                        await self?.resumeHotMicAfterDictation()
                    }
                }
            } else {
                await resumeHotMicAfterDictation()
            }

            if success || (!success && commandResult.recovery == nil) || handledCorrection {
                scheduleReturnToIdle()
            }

        } catch DictationError.emptyTranscription {
            guard activeCommandID == commandID else {
                resumeMediaAfterRecording()
                await resumeHotMicAfterDictation()
                return
            }
            dispatchTrialStore.recordSystemFailure(
                label: .emptyTranscript,
                message: "No command transcript was produced.",
                targetApplicationName: recordingTargetApplication?.localizedName
            )
            notchCoordinator.setState(.command(stage: .result(text: "No command heard.", success: false)))
            playAudioCue(.warning)
            resumeMediaAfterRecording()
            await resumeHotMicAfterDictation()
            scheduleReturnToIdle()
        } catch {
            guard activeCommandID == commandID else {
                resumeMediaAfterRecording()
                await resumeHotMicAfterDictation()
                return
            }
            dispatchTrialStore.recordSystemFailure(
                label: .transcriptionFailed,
                message: "Command transcription or processing failed: \(error.localizedDescription)",
                targetApplicationName: recordingTargetApplication?.localizedName
            )
            notchCoordinator.setState(.command(stage: .result(text: "Command failed.", success: false)))
            playAudioCue(.agentFailure)
            resumeMediaAfterRecording()
            await resumeHotMicAfterDictation()
            scheduleReturnToIdle()
        }
    }

    private func scheduleReturnToIdle() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if case .command(stage: .result) = notchCoordinator.state {
                notchCoordinator.setState(.idle)
            }
        }
    }

    private func scheduleDispatchTrialVerification(trialID: UUID) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            _ = self?.dispatchTrialStore.recordAutomaticVerification(trialID: trialID)
        }
    }

    private func scheduleCommandFollowUp(parentCommand: String, parentContext: ContextPacket?) {
        commandFollowUpTask?.cancel()
        commandFollowUpTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(160))
            guard let self, !Task.isCancelled else { return }
            await self.startCommandFollowUpWindow(
                parentCommand: parentCommand,
                parentContext: parentContext
            )
        }
    }

    private func startCommandFollowUpWindow(parentCommand: String, parentContext: ContextPacket?) async {
        guard allowsLocalAudioCapture else {
            await resumeHotMicAfterDictation()
            scheduleReturnToIdle()
            return
        }
        guard modelRegistry.activeIsReady else {
            await resumeHotMicAfterDictation()
            scheduleReturnToIdle()
            return
        }
        guard !isRecording, !isStartingRecording, !isFinishingCapture, !isInCommandMode else {
            await resumeHotMicAfterDictation()
            scheduleReturnToIdle()
            return
        }

        screenContextBiasSession.begin()
        isInCommandMode = true
        currentMode = .command
        let startAttemptID = beginRecordingStartAttempt()
        let commandID = UUID()
        activeCommandID = commandID
        recordingStartedAt = Date()
        recordingTargetApplication = activeTargetApplication()

        var followUpWindow = DispatchFollowUpWindowState(
            openedAt: Date(),
            openWindow: dispatchLearningStore.followUpOpenWindow,
            trailingSilence: dispatchLearningStore.recommendedFollowUpTrailingSilence
        )

        notchCoordinator.setState(.command(stage: .awaitingFollowUp(
            level: 0,
            elapsed: 0,
            status: "Opening microphone..."
        )))

        pauseMediaForRecordingIfNeeded()
        await pauseHotMicForDictation()
        guard recordingStartOwnership.owns(startAttemptID) else { return }

        audioRecorder.onLevelUpdate = { [weak self] level in
            guard let self,
                  self.activeCommandID == commandID,
                  self.isInCommandMode,
                  self.currentMode == .command,
                  !followUpWindow.hasRequestedFinish else {
                return
            }

            let update = followUpWindow.observe(level: level, at: Date())
            self.notchCoordinator.setState(.command(stage: .awaitingFollowUp(
                level: update.level,
                elapsed: update.elapsed,
                status: update.status
            )))

            if update.shouldFinish {
                Task { @MainActor [weak self] in
                    await self?.finishCommandFollowUpWindow(
                        commandID: commandID,
                        parentCommand: parentCommand,
                        parentContext: parentContext,
                        observation: update.observation
                    )
                }
            }
        }

        do {
            try await startRecordingWithFallback(startAttemptID: startAttemptID)
            guard finishRecordingStartAttempt(startAttemptID),
                  activeCommandID == commandID,
                  isStartingRecording else { return }
            isStartingRecording = false
            isRecording = true
            recordingStartedAt = Date()
            followUpWindow = DispatchFollowUpWindowState(
                openedAt: Date(),
                openWindow: dispatchLearningStore.followUpOpenWindow,
                trailingSilence: dispatchLearningStore.recommendedFollowUpTrailingSilence
            )
            notchCoordinator.setState(.command(stage: .awaitingFollowUp(
                level: 0,
                elapsed: 0,
                status: followUpWindow.currentStatus
            )))
        } catch is CancellationError {
            guard finishRecordingStartAttempt(startAttemptID) else { return }
            if isStartingRecording {
                await cancelRecording(reason: "start_cancelled", shouldTrackCancellation: false)
            }
            return
        } catch {
            guard finishRecordingStartAttempt(startAttemptID) else { return }
            audioRecorder.onLevelUpdate = nil
            isStartingRecording = false
            isRecording = false
            isInCommandMode = false
            currentMode = .dictation
            activeCommandID = nil
            recordingStartedAt = nil
            recordingTargetApplication = nil
            resumeMediaAfterRecording()
            await resumeHotMicAfterDictation()
            scheduleReturnToIdle()
            rewarmAfterFailedRecordingStartIfNeeded()
        }
    }

    private func finishCommandFollowUpWindow(
        commandID: UUID,
        parentCommand: String,
        parentContext: ContextPacket?,
        observation: DispatchFollowUpWindowState.Observation
    ) async {
        guard activeCommandID == commandID,
              isInCommandMode,
              currentMode == .command,
              !isFinishingCapture else { return }

        disarmStartingRecordingWatchdog()
        isRecording = false
        isStartingRecording = false
        isFinishingCapture = true
        let finalizationRetirement = beginCaptureFinalizationRetirement()
        audioRecorder.onLevelUpdate = nil

        defer {
            if captureCancellationQuiescenceID == nil {
                isFinishingCapture = false
                rewarmIfLowLatency()
            }
            isInCommandMode = false
            currentMode = .dictation
            recordingStartedAt = nil
            recordingTargetApplication = nil
            activeCommandID = nil
            completeCaptureFinalizationRetirement(finalizationRetirement)
        }

        guard observation.heardSpeech else {
            await dictationManager.cancel()
            notchCoordinator.setState(.idle)
            resumeMediaAfterRecording()
            await resumeHotMicAfterDictation()
            return
        }

        notchCoordinator.setState(.command(stage: .thinking(status: "Transcribing follow-up...")))

        do {
            await recordUnsupportedVocabularyBoostAdapterAttemptIfNeeded()
            let result = try await dictationManager.stopAndTranscribe(
                targetApplication: recordingTargetApplication,
                preloadedHotContext: nil,
                fallbackSelectedText: nil,
                fallbackSelectedRange: nil,
                latencyLogger: nil,
                onCaptureStopped: { [weak self] in
                    self?.playAudioCue(.stop)
                    self?.resumeMediaAfterRecording()
                },
                recordingRetention: .ephemeral
            )

            let followUpText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !followUpText.isEmpty else {
                notchCoordinator.setState(.command(stage: .result(text: "No follow-up heard.", success: false)))
                await resumeHotMicAfterDictation()
                scheduleReturnToIdle()
                return
            }

            if let speechTurn = observation.speechTurn(completedAt: Date()) {
                dispatchLearningStore.recordSpeechTurn(
                    utteranceDuration: speechTurn.utteranceDuration,
                    trailingSilence: speechTurn.trailingSilence
                )
            }

            analyticsManager.capture("dispatch_follow_up", properties: [
                "command_length": followUpText.count,
                "parent_command_length": parentCommand.count
            ])

            let routedCommand = DispatchCommandPresentationState.followUpCommandText(
                parentCommand: parentCommand,
                followUpText: followUpText
            )
            await processFollowUpDispatchCommand(
                displayText: followUpText,
                routedCommand: routedCommand,
                contextPacket: result.contextPacket ?? parentContext
            )
        } catch {
            notchCoordinator.setState(.command(stage: .result(text: "Follow-up failed.", success: false)))
            playAudioCue(.agentFailure)
            resumeMediaAfterRecording()
            await resumeHotMicAfterDictation()
            scheduleReturnToIdle()
        }
    }

    private func processFollowUpDispatchCommand(
        displayText: String,
        routedCommand: String,
        contextPacket: ContextPacket?
    ) async {
        let trialID = dispatchTrialStore.startCommandTrace(
            transcript: displayText,
            routedCommand: routedCommand,
            contextPacket: contextPacket,
            targetApplicationName: recordingTargetApplication?.localizedName,
            recordingStartedAt: nil
        )
        let commandProcessingStartedAt = Date()
        var commandPresentation = DispatchCommandPresentationState(heardText: displayText)
        let updateCommandProgress: DispatchCommandProgressHandler = { [weak self] progress in
            guard let self, self.activeCommandID != nil, self.currentMode == .command else { return }
            self.dispatchTrialStore.recordProgress(progress, trialID: trialID)
            self.notchCoordinator.setState(.command(stage: .thinking(
                status: commandPresentation.status(after: progress)
            )))
        }

        notchCoordinator.setState(.command(stage: .thinking(status: commandPresentation.initialStatus())))
        playAudioCue(.agentStart)

        let commandResult = await commandRouter.processCommand(
            transcribedText: routedCommand,
            contextPacket: contextPacket,
            onProgress: updateCommandProgress
        )

        guard activeCommandID != nil, currentMode == .command else {
            await resumeHotMicAfterDictation()
            return
        }

        let success = commandResult.actionResult?.success ?? false
        dispatchTrialStore.finishCommandTrace(
            trialID: trialID,
            result: commandResult,
            totalLatencyMs: max(0, Int(Date().timeIntervalSince(commandProcessingStartedAt) * 1000))
        )
        scheduleDispatchTrialVerification(trialID: trialID)
        let handledCorrection = DispatchLearningStore.correctionKind(for: displayText) != nil
        notchCoordinator.setState(.command(stage: .result(
            text: commandPresentation.resultStatus(commandResult.feedback),
            success: success
        )))

        if success {
            playAudioCue(.agentSuccess)
            if handledCorrection, settingsManager.dispatchTTSEnabled {
                commandRouter.speakResult(commandResult) { [weak self] in
                    Task { @MainActor in
                        await self?.resumeHotMicAfterDictation()
                    }
                }
                scheduleReturnToIdle()
            } else if handledCorrection {
                await resumeHotMicAfterDictation()
                scheduleReturnToIdle()
            } else if settingsManager.dispatchTTSEnabled {
                commandRouter.speakResult(commandResult) { [weak self] in
                    Task { @MainActor in
                        await self?.resumeHotMicAfterDictation()
                    }
                }
                scheduleReturnToIdle()
            } else {
                await resumeHotMicAfterDictation()
                scheduleReturnToIdle()
            }
        } else if commandResult.recovery != nil {
            playAudioCue(.agentFailure)
            if settingsManager.dispatchTTSEnabled {
                commandRouter.speakResult(commandResult) { [weak self] in
                    Task { @MainActor in
                        self?.scheduleCommandFollowUp(
                            parentCommand: routedCommand,
                            parentContext: contextPacket
                        )
                    }
                }
            } else {
                scheduleCommandFollowUp(parentCommand: routedCommand, parentContext: contextPacket)
            }
        } else {
            playAudioCue(.agentFailure)
            if settingsManager.dispatchTTSEnabled {
                commandRouter.speakResult(commandResult) { [weak self] in
                    Task { @MainActor in
                        await self?.resumeHotMicAfterDictation()
                    }
                }
            } else {
                await resumeHotMicAfterDictation()
            }
            scheduleReturnToIdle()
        }
    }

    // MARK: - MCP write tool handler

    private func handleMCPWriteTool(tool: String, args: [String: JSONValue]) async -> WorkspaceToolCallResult {
        let executor = ActionExecutor(
            pasteManager: pasteManager,
            dataStore: dataStore,
            voiceFeedback: commandRouter.voiceFeedback
        )

        let action: CommandAction
        switch tool {
        case "type_text":
            let text = args["text"]?.stringValue ?? ""
            let appHint = args["app_hint"]?.stringValue
            action = .typeText(text: text, appHint: appHint)

        case "open_url":
            let url = args["url"]?.stringValue ?? ""
            action = .openURL(url: url)

        case "open_app":
            let name = args["name"]?.stringValue ?? ""
            action = .openApp(name: name)

        case "notify_user":
            let message = args["message"]?.stringValue ?? ""
            let speak = args["speak"]?.boolValue ?? false
            notchCoordinator.showNotice(.init(title: message))
            if speak && settingsManager.dispatchTTSEnabled {
                commandRouter.voiceFeedback.speak(message)
            }
            return WorkspaceToolCallResult(
                toolName: tool,
                payload: .object(["status": .string("notified"), "message": .string(message)]),
                isError: false
            )

        case "record_notification_hint":
            guard let appName = args["app_name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !appName.isEmpty else {
                return WorkspaceToolCallResult(
                    toolName: tool,
                    payload: .object(["message": .string("Missing required parameter: app_name")]),
                    isError: true
                )
            }
            let title = args["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = args["body"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard title?.isEmpty == false || body?.isEmpty == false else {
                return WorkspaceToolCallResult(
                    toolName: tool,
                    payload: .object(["message": .string("Provide at least one of title or body")]),
                    isError: true
                )
            }
            let receivedAt = args["received_at"]?.stringValue.flatMap(WorkspaceQueryEngine.parseDate) ?? Date()
            ambientContextCollector.recordNotificationHint(
                AmbientContextCollector.NotificationHint(
                    appName: appName,
                    bundleId: args["bundle_id"]?.stringValue,
                    title: title?.isEmpty == false ? title : nil,
                    body: body?.isEmpty == false ? body : nil,
                    url: args["url"]?.stringValue,
                    receivedAt: receivedAt
                )
            )
            return WorkspaceToolCallResult(
                toolName: tool,
                payload: .object([
                    "status": .string("recorded"),
                    "app": .string(appName)
                ]),
                isError: false
            )

        case "run_command":
            let command = args["command"]?.stringValue ?? ""
            let result = await commandRouter.processCommand(transcribedText: command, contextPacket: nil)
            return WorkspaceToolCallResult(
                toolName: tool,
                payload: .object([
                    "status": .string(result.actionResult?.success == true ? "success" : "failed"),
                    "feedback": .string(result.feedback)
                ]),
                isError: !(result.actionResult?.success ?? false)
            )

        case "dispatch_test_run":
            return await DispatchTestRunner.run(
                args: args,
                commandRouter: commandRouter,
                learningStore: dispatchLearningStore,
                defaultCloudFallbackEnabled: settingsManager.dispatchCloudFallbackEnabled
            )

        case "dispatch_trial_next":
            let privacy: DispatchDiagnosticPrivacy = args["include_sensitive"]?.boolValue == true ? .raw : .redacted
            let record: DispatchTrialRecord
            if let scenarioID = args["scenario_id"]?.stringValue,
               let scenarioRecord = dispatchTrialStore.beginScenario(id: scenarioID) {
                record = scenarioRecord
            } else {
                record = dispatchTrialStore.beginNextScenario()
            }
            return WorkspaceToolCallResult(
                toolName: tool,
                payload: .object([
                    "trial": DispatchTrialStore.payloadForTool(record, privacy: privacy),
                    "say": .string(record.prompt),
                    "log_path": .string(privacy.isRedacted ? "[redacted]" : dispatchTrialStore.logURL.path)
                ]),
                isError: false
            )

        case "dispatch_trial_outcome":
            guard let rawOutcome = args["outcome"]?.stringValue,
                  let outcome = DispatchTrialOutcome(rawValue: rawOutcome) else {
                return WorkspaceToolCallResult(
                    toolName: tool,
                    payload: .object(["message": .string("Missing or invalid outcome.")]),
                    isError: true
                )
            }
            let trialID = args["trial_id"]?.stringValue.flatMap(UUID.init(uuidString:))
            guard let record = dispatchTrialStore.markOutcome(
                trialID: trialID,
                outcome: outcome,
                notes: args["notes"]?.stringValue
            ) else {
                return WorkspaceToolCallResult(
                    toolName: tool,
                    payload: .object(["message": .string("No Dispatch trial available to mark.")]),
                    isError: true
                )
            }
            return WorkspaceToolCallResult(
                toolName: tool,
                payload: .object([
                    "status": .string("recorded"),
                    "trial": DispatchTrialStore.payloadForTool(
                        record,
                        privacy: args["include_sensitive"]?.boolValue == true ? .raw : .redacted
                    )
                ]),
                isError: false
            )

        case "dispatch_trials":
            let privacy: DispatchDiagnosticPrivacy = args["include_sensitive"]?.boolValue == true ? .raw : .redacted
            return WorkspaceToolCallResult(
                toolName: tool,
                payload: dispatchTrialStore.payload(
                    limit: args["limit"]?.intValue ?? 20,
                    includeScenarios: args["include_scenarios"]?.boolValue ?? true,
                    privacy: privacy
                ),
                isError: false
            )

        case "dispatch_traces":
            let limit = args["limit"]?.intValue ?? 50
            let privacy: DispatchDiagnosticPrivacy = args["include_sensitive"]?.boolValue == true ? .raw : .redacted
            return WorkspaceToolCallResult(
                toolName: tool,
                payload: DispatchTraceInspector.payload(
                    store: DispatchTraceStore(),
                    limit: limit,
                    privacy: privacy
                ),
                isError: false
            )

        case "dispatch_log":
            let limit = args["limit"]?.intValue ?? 20
            let privacy: DispatchDiagnosticPrivacy = args["include_sensitive"]?.boolValue == true ? .raw : .redacted
            return WorkspaceToolCallResult(
                toolName: tool,
                payload: DispatchLearningInspector.logPayload(
                    store: dispatchLearningStore,
                    limit: limit,
                    privacy: privacy
                ),
                isError: false
            )

        case "dispatch_bindings":
            let limit = args["limit"]?.intValue ?? 20
            let privacy: DispatchDiagnosticPrivacy = args["include_sensitive"]?.boolValue == true ? .raw : .redacted
            return WorkspaceToolCallResult(
                toolName: tool,
                payload: DispatchLearningInspector.bindingsPayload(
                    store: dispatchLearningStore,
                    limit: limit,
                    privacy: privacy
                ),
                isError: false
            )

        case "dispatch_replay_fixtures":
            let limit = args["limit"]?.intValue ?? 20
            let failuresOnly = args["failures_only"]?.boolValue ?? true
            let privacy: DispatchDiagnosticPrivacy = args["include_sensitive"]?.boolValue == true ? .raw : .redacted
            return WorkspaceToolCallResult(
                toolName: tool,
                payload: DispatchRouteReplayFixtureBuilder.payload(
                    from: dispatchLearningStore.recentLogs(limit: min(max(limit, 1), 100)),
                    failuresOnly: failuresOnly,
                    privacy: privacy
                ),
                isError: false
            )

        default:
            return WorkspaceToolCallResult(
                toolName: tool,
                payload: .object(["message": .string("Unknown write tool: \(tool)")]),
                isError: true
            )
        }

        let result = await executor.execute(action)
        return WorkspaceToolCallResult(
            toolName: tool,
            payload: .object([
                "status": .string(result.success ? "success" : "failed"),
                "summary": .string(result.summary),
                "detail": result.detail.map { .string($0) } ?? .null
            ]),
            isError: !result.success
        )
    }

    func requestRuntimePermissions() {
        runtimeSupportActions.requestRuntimePermissions()
    }

    func showPrimaryWindow(selectedTab: SettingsTab = .home) {
        isShowingSettings = selectedTab.isSettingsTab
        selectedSettingsTab = selectedTab
        if settingsManager.onboardingCompleted {
            settingsWindowController.show(appState: self, selectedTab: selectedTab)
        } else {
            onboardingWindowController.show(appState: self)
        }
    }

    func openSettingsAtPreferredTab() {
        isShowingSettings = true
        guard selectedSettingsTab?.isSettingsTab != true else { return }
        selectedSettingsTab = lastSettingsEntryTab.isSettingsSidebarTab ? lastSettingsEntryTab : .dictation
    }

    var canOpenPostHogSettings: Bool {
        runtimeSupportActions.canOpenPostHogSettings
    }

    func openPostHogSettings() {
        guard runtimeSupportActions.openPostHogSettings() else {
            selectedSettingsTab = SettingsTab.support
            return
        }
    }

    func openAccessibilitySettings() {
        runtimeSupportActions.openAccessibilitySettings()
    }

    func openInputMonitoringSettings() {
        runtimeSupportActions.openInputMonitoringSettings()
    }

    func runPasteDiagnosticTest(text: String) async -> PasteDiagnosticReport {
        await runtimeSupportActions.runPasteDiagnosticTest(text: text)
    }

    func recordPasteDiagnosticResult(_ report: PasteDiagnosticReport) {
        runtimeSupportActions.recordPasteDiagnosticResult(report)
    }

    func openSupportURL(kind: String, value: String) {
        runtimeSupportActions.openSupportURL(kind: kind, value: value)
    }

    func setAnalyticsEnabled(_ enabled: Bool) {
        analyticsManager.setAnalyticsEnabled(enabled)
        if enabled {
            syncAnalyticsIdentity()
        }
    }

    func setCrashDiagnosticsEnabled(_ enabled: Bool) {
        settingsManager.crashDiagnosticsEnabled = enabled
    }

    /// Opt the user in/out of the beta program. Persists the preference locally
    /// and syncs the `beta_tester` person property to PostHog so feature flags
    /// targeting the "Beta Testers" cohort evaluate correctly.
    func setBetaTesterEnabled(_ enabled: Bool) {
        analyticsManager.setBetaTesterEnabled(enabled)
    }

    func trackSettingsTabViewed(_ tab: SettingsTab) {
        runtimeSupportActions.trackSettingsTabViewed(tab)
    }

    func initiateLogin(source: String = "settings") {
        guard AppFeatureVisibility.hostedServices else {
            notchCoordinator.showError("Cloud services are not configured in this build.", subtype: .generic)
            return
        }
        analyticsManager.capture("auth_sign_in_started", properties: ["source": source])
        ensureLoginPresentationAnchor()
        pendingLoginSource = source
        authWindowController.show(appState: self)
    }

    func refreshAuthenticationStateFromPersistence() async {
        guard AppFeatureVisibility.hostedServices else { return }
        let previousUserId = authManager.userId
        let previousUserEmail = authManager.userEmail
        let previousAuthToken = authManager.authToken
        let previousCloudAuthToken = authManager.cloudAuthToken

        await authManager.resume()

        let didChange =
            previousUserId != authManager.userId
            || previousUserEmail != authManager.userEmail
            || previousAuthToken != authManager.authToken
            || previousCloudAuthToken != authManager.cloudAuthToken

        if authManager.isLoggedIn {
            authWindowController.dismiss()
        }

        guard didChange || authManager.isLoggedIn else { return }

        syncAnalyticsIdentity()
        syncSentryRuntimeConfiguration()
        reconcileMeetingWebhookDestination()
    }

    func reopenOnboarding(initialStep: OnboardingView.OnboardingStep = .welcome) {
        settingsWindowController.close()
        onboardingWindowController.dismiss()
        onboardingWindowController.show(appState: self, initialStep: initialStep)
    }

    func reconcileMeetingWebhookDestination() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.meetingWebhookSender.reconcileDestination(
                currentURL: self.settingsManager.meetingWebhookURL,
                isEnabled: self.canFireMeetingWebhooks
            )
        }
    }

    /// Authoritative check before any meeting webhook send.
    var canFireMeetingWebhooks: Bool {
        settingsManager.meetingWebhookEnabled
    }

    var canSendMeetingCompletionEmails: Bool {
        AppFeatureVisibility.hostedServices && Self.canSendMeetingCompletionEmails(
            isEnabled: settingsManager.meetingTranscriptEmailEnabled,
            userEmail: authManager.userEmail
        )
    }

    nonisolated static func canSendMeetingCompletionEmails(
        isEnabled: Bool,
        userEmail: String?
    ) -> Bool {
        guard isEnabled else { return false }
        return userEmail?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private func sendMeetingCompletionEmailIfNeeded(
        session: CompletedMeetingSession,
        entry: MeetingEntry
    ) {
        guard canSendMeetingCompletionEmails,
              let payload = MeetingCompletionEmailBuilder.payload(for: session, entry: entry)
        else {
            return
        }

        let startedAt = Date()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await self.convexClient.sendMeetingCompletionEmail(payload: payload)
                self.analyticsManager.capture("meeting_completion_email_sent", properties: [
                    "meeting_id": payload.meetingId,
                    "duration_seconds": payload.durationSeconds,
                    "word_count": session.wordCount,
                    "has_conferencing_url": payload.conferencingURL != nil,
                    "latency_ms": max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
                ])
            } catch {
                Self.log.error("Meeting completion self-email failed: \(error.localizedDescription, privacy: .private)")
                self.notchCoordinator.showError("Transcript email failed", subtype: .generic)
                self.analyticsManager.capture("meeting_completion_email_failed", properties: [
                    "meeting_id": payload.meetingId,
                    "latency_ms": max(0, Int(Date().timeIntervalSince(startedAt) * 1000)),
                    "error": String(describing: error)
                ])
            }
        }
    }

    func generateJournal(for date: Date, userInitiated: Bool = false) async -> JournalManager.GenerationOutcome {
        await journalManager.generate(for: date)
    }

    func finishOnboarding(
        analyticsContext: OnboardingAnalytics.SessionContext,
        totalDurationMs: Int? = nil,
        selectedTab: SettingsTab = .home,
        enableAgentAccess: Bool = false
    ) {
        settingsManager.onboardingCompleted = true

        // Agent access is offered as a checkbox on the done step when AI
        // coding tools are detected. The checkbox is authoritative in both
        // directions: unchecking it on a reopened flow must also revoke
        // access, or the recorded opt-out would be a lie.
        let detectedClients = MCPManager.MCPClient.allCases.filter(\.isInstalled)
        let agentAccessEnabled = enableAgentAccess && !detectedClients.isEmpty
        if !detectedClients.isEmpty {
            settingsManager.mcpServerEnabled = enableAgentAccess
            settingsManager.localAPIEnabled = enableAgentAccess
        }

        var properties: [String: Any] = [
            "trigger_key": settingsManager.hotkeyTrigger.rawValue,
            "mcp_auto_enabled": agentAccessEnabled,
            "mcp_opted_out": !enableAgentAccess && !detectedClients.isEmpty,
            "mcp_detected_clients": detectedClients.map(\.rawValue)
        ]
        if let totalDurationMs {
            properties["total_duration_ms"] = totalDurationMs
        }
        analyticsManager.capture(
            OnboardingAnalytics.Event.completed.rawValue,
            properties: OnboardingAnalytics.properties(
                context: analyticsContext,
                additional: properties
            )
        )
        onboardingWindowController.dismiss()
        settingsWindowController.show(appState: self, selectedTab: selectedTab)
        syncAmbientContextState()
        NotificationCenter.default.post(name: .onboardingCompleted, object: nil)
    }

    func showTestNotch() {
        notchCoordinator.recordingLocked = false
        notchCoordinator.setState(.recording(mode: .dictation, level: 0.72, elapsed: 0))
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            if case .recording = self.notchCoordinator.state {
                self.notchCoordinator.showDone("Notch test")
            }
        }
    }

    var canReuseLastDictation: Bool {
        latestReusableDictation != nil
    }

    // MARK: - Feed actions

    func copyFeedItemText(_ item: FeedItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.text, forType: .string)
    }

    func copyLastDictation() {
        guard let item = latestReusableDictation else { return }
        copyFeedItemText(item)
        playAudioCue(.success)
        if shouldKeepNotchSyncedToHold {
            notchCoordinator.setState(.idle)
        } else {
            notchCoordinator.showDone("Copied last")
        }
    }

    func retryLastDictation() async {
        guard let item = latestReusableDictation else { return }

        let shouldPaste = settingsManager.autoPasteEnabled
        let shouldCopy = settingsManager.copyToClipboardEnabled
        let shouldSend = shouldPaste && settingsManager.autoSendEnabled
        let targetApplication = activeTargetApplication()
        let focusedFieldContent = pasteManager.focusedFieldContent(
            for: targetApplication,
            windowTitle: item.windowTitle,
            browserURL: item.browserURL
        )
        let focusedFieldContext = pasteManager.focusedFieldContext(for: targetApplication)
        let signatureEmailMode = CloudProcessingSupport.emailDictationMode(
            transcript: item.text,
            focusedFieldContent: focusedFieldContent,
            focusedFieldContext: focusedFieldContext,
            appName: targetApplication?.localizedName ?? item.appName,
            bundleId: targetApplication?.bundleIdentifier ?? item.bundleId,
            windowTitle: item.windowTitle,
            browserURL: item.browserURL,
            fallbackSenderName: settingsManager.resolvedEmailSignoffName
        )
        let deliveryText = EmailSignatureSupport.applyingIfNeeded(
            to: item.text,
            enabled: settingsManager.emailSignatureEnabled && AppRuntime.distributionFlavor == .official,
            appName: targetApplication?.localizedName ?? item.appName,
            bundleId: targetApplication?.bundleIdentifier ?? item.bundleId,
            windowTitle: item.windowTitle,
            browserURL: item.browserURL,
            emailMode: signatureEmailMode,
            existingFieldContent: focusedFieldContent,
            focusedFieldContext: focusedFieldContext,
            decisionHandler: { decision in
                self.logEmailSignatureDecision(decision, source: "retry")
            }
        )

        notchCoordinator.setTargetContext(
            bundleId: targetApplication?.bundleIdentifier ?? item.bundleId,
            windowTitle: item.windowTitle ?? item.contextLabel,
            browserURL: item.browserURL
        )

        if !shouldKeepNotchSyncedToHold {
            notchCoordinator.setState(.processing(progress: 0.7, stage: "Retrying…"))
        }

        let deliveryOutcome = await pasteManager.deliverWithOutcome(
            text: deliveryText,
            copyToClipboard: shouldCopy,
            autoPaste: shouldPaste,
            autoSend: shouldSend,
            captureReceipt: false,
            targetApplication: targetApplication,
            windowTitle: item.windowTitle,
            browserURL: item.browserURL,
            deliveryMode: settingsManager.pasteDeliveryMode
        )
        _ = await deliveryPersonalizationRouter.route(DeliveryPersonalizationRequest(
            deliveryOutcome: deliveryOutcome,
            autoPasteRequested: shouldPaste,
            autoSendRequested: shouldSend,
            copiedToClipboard: shouldCopy && deliveryOutcome.delivered,
            selectionTransformUsed: false,
            targetApplication: targetApplication,
            surface: SurfaceClassifier.classify(
                appName: targetApplication?.localizedName ?? item.appName,
                bundleId: targetApplication?.bundleIdentifier ?? item.bundleId,
                windowTitle: item.windowTitle,
                browserURL: item.browserURL,
                focusedFieldContent: focusedFieldContent
            ),
            windowTitle: item.windowTitle,
            browserURL: item.browserURL,
            rawTranscript: nil,
            contextPacket: nil,
            personalizationExposure: nil,
            qualityTrace: nil,
            boostAudit: nil,
            confidence: nil,
            appliedStylePolicy: .none
        ))
        let delivered = shouldSend ? deliveryOutcome.sent : deliveryOutcome.delivered

        if delivered {
            playAudioCue(.success)
            let completionMessage: String
            if shouldPaste {
                completionMessage = shouldSend ? "Sent again" : "Pasted again"
            } else if shouldCopy {
                completionMessage = "Copied again"
            } else {
                completionMessage = "Retried"
            }
            if shouldKeepNotchSyncedToHold {
                notchCoordinator.setState(.idle)
            } else {
                notchCoordinator.showDone(completionMessage)
            }
        } else if shouldSend && deliveryOutcome.delivered {
            let copiedFallback = fallbackCopyAfterFailedDelivery(text: deliveryText)
            playAudioCue(.warning)
            notchCoordinator.showError(
                copiedFallback
                    ? "Text was pasted but not sent. A copy is on your clipboard."
                    : "Text was pasted but not sent.",
                subtype: .generic
            )
        } else {
            let copiedFallback = fallbackCopyAfterFailedDelivery(text: deliveryText)
            handlePasteFailurePresentation(copiedFallback: copiedFallback)
        }
    }

    func saveFeedItemAsMemo(_ item: FeedItem) async {
        guard item.kind == .dictation else { return }
        let saveResult = await memoManager.save(
            text: item.text,
            duration: TimeInterval(item.durationSeconds ?? 0)
        )
        let memo = saveResult.memo
        feedManager.record(memo)
        autoTitleIfEligible(memo: memo)
    }

    func deleteFeedItem(_ item: FeedItem) async {
        switch item.kind {
        case .dictation:
            guard let entry = dataStore.dictationEntry(id: item.id) else {
                feedManager.remove(id: item.id)
                return
            }
            await dataStore.delete(entry)
            feedManager.remove(id: item.id)
            workspaceSyncEngine.markExportNeeded()
            if await journalManager.hasJournal(on: item.date) {
                _ = await journalManager.generate(for: item.date)
            }

        case .memo:
            if let memo = memoManager.memo(id: item.id) {
                memoManager.delete(memo)
            } else if let memo = dataStore.memoEntry(id: item.id) {
                await dataStore.delete(memo)
            }
            feedManager.remove(id: item.id)
            workspaceSyncEngine.markExportNeeded()

        default:
            break
        }
    }

    func retranscribeFeedItem(_ item: FeedItem) async throws {
        guard let transcriber = modelRegistry.active, transcriber.isLoaded else {
            throw TranscriberError.notLoaded
        }
        guard let audioURL = feedManager.resolveAudioURL(item.audioPath) else {
            throw TranscriberError.transcriptionFailed("Audio file not found")
        }

        let lang = settingsManager.transcriptionLanguage
        await recordUnsupportedVocabularyBoostAdapterAttemptIfNeeded()
        let newText = try await Task.detached(priority: .userInitiated) {
            try await transcriber.transcribe(audioURL: audioURL, language: lang)
        }.value

        guard !newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranscriberError.transcriptionFailed("Transcription returned empty text")
        }

        // Update persistence
        switch item.kind {
        case .dictation:
            if let entry = dataStore.dictationEntry(id: item.id) {
                entry.text = newText
                entry.rawTranscript = newText
                entry.wordCount = newText.split(separator: " ").count
                dataStore.saveChanges()
            }
        case .memo:
            let memoID = item.id
            _ = await dataStore.performBackgroundWrite { context in
                var descriptor = FetchDescriptor<MemoEntry>(
                    predicate: #Predicate { $0.id == memoID }
                )
                descriptor.fetchLimit = 1
                guard let memo = try? context.fetch(descriptor).first else { return }
                memo.text = newText
            }
        default:
            break
        }

        // Update feed UI
        feedManager.updateText(id: item.id, newText: newText)
    }

    // MARK: - Dictation flow

    func startDictation() async {
        Self.log.info("startDictation invoked. isRecording=\(self.isRecording, privacy: .public) isStarting=\(self.isStartingRecording, privacy: .public) isFinishing=\(self.isFinishingCapture, privacy: .public) modelReady=\(self.modelRegistry.activeIsReady, privacy: .public) prep=\(String(describing: self.modelRegistry.preparationState), privacy: .public) hotkeySource=\(self.hotkeyManager.lastTriggerSource, privacy: .public)")
        guard allowsLocalAudioCapture else {
            Self.log.info("startDictation rejected — terminal lifecycle state")
            return
        }
        if isRetryingDictation {
            Self.log.info("startDictation rejected — retry in flight")
            playAudioCue(.error)
            notchCoordinator.showError("Resonant is busy — try again in a sec.", subtype: .generic)
            return
        }
        if isRecording || isStartingRecording || isFinishingCapture {
            // A second Fn press while the previous hold capture is still
            // starting/finishing is the same fumble, not real contention —
            // absorb it silently rather than flashing a hard "busy" error that
            // would itself feed the recording<->error overlay oscillation.
            if DictationRestartThrottlePolicy.shouldSilenceSelfCollision(
                mode: settingsManager.hotkeyMode,
                isRecording: isRecording,
                isStartingRecording: isStartingRecording,
                isFinishingCapture: isFinishingCapture
            ) {
                Self.log.info("startDictation absorbed hold-mode self-collision (starting=\(self.isStartingRecording, privacy: .public) finishing=\(self.isFinishingCapture, privacy: .public))")
                return
            }
            Self.log.info("startDictation rejected — already in flight")
            playAudioCue(.error)
            notchCoordinator.showError("Resonant is busy — try again in a sec.", subtype: .generic)
            return
        }
        // Debounce rapid hold-mode re-triggers that follow an unproductive
        // capture (the fumbled-lock case): without this, each quick re-press
        // produces another too-short/silent capture and the notch flips between
        // the no-speech error and the recording strip.
        if DictationRestartThrottlePolicy.shouldSuppressUnproductiveRestart(
            mode: settingsManager.hotkeyMode,
            millisecondsSinceUnproductiveStop: millisecondsSinceUnproductiveCapture()
        ) {
            Self.log.info("startDictation throttled — within hold restart cooldown after unproductive capture")
            return
        }
        guard !rejectNewCaptureForPendingRecovery() else { return }
        if let manager = meetingRecorderManager,
           manager.isRecording || manager.isStartingSession || manager.isFinalizing {
            playAudioCue(.error)
            notchCoordinator.showError("Meeting is recording. Stop it to dictate.", subtype: .generic)
            return
        }
        // Capture is model-independent: while the model is merely loading we
        // record now and let stop-time wait for readiness, instead of bouncing
        // the press with an error the user can't act on.
        let modelDisposition = DictationModelReadinessPolicy.startDisposition(
            hasActiveModel: modelRegistry.active != nil,
            isLoaded: modelRegistry.activeIsReady,
            isDownloaded: modelRegistry.active?.isDownloaded ?? false,
            preparationState: modelRegistry.preparationState
        )
        guard modelDisposition != .reject else {
            analyticsManager.capture("dictation_error", properties: [
                "stage": "start",
                "error_type": "model_not_ready",
                "model": settingsManager.selectedModelId
            ])
            showModelNotReadyForUser()
            return
        }
        if modelDisposition == .proceedAndPrepare {
            Task { try? await modelRegistry.prepareActive(source: .dictationStart) }
        }

        // Speculative warm: build the capture session on the capture queue
        // while the pre-start UI/media work runs, so record-start can promote
        // a ramped session instead of paying device-open latency — the largest
        // share of the capture-start deficit that clips first words. Sessions
        // that don't promote are torn down when the start attempt finishes.
        audioRecorder.warmUp(
            selectedInputDeviceUID: settingsManager.inputDeviceUID,
            intent: .imminentCapture
        )

        // Reaching this point means the new capture was accepted. A rejected or
        // debounced hotkey press must not prematurely finalize the prior text as
        // accepted while its user may still be editing it.
        correctionFlushTask?.cancel()
        correctionFlushTask = Task { await correctionObserver.flushBeforeDictation() }

        currentMode = .dictation
        let startAttemptID = beginRecordingStartAttempt()
        pendingStopAfterStart = false
        currentCaptureUsesPersistentPresentation = false
        let hotkeyAcceptedAt = Date()
        lastCaptureStartGapMs = nil
        recordingStartedAt = hotkeyAcceptedAt
        recordingTargetApplication = activeTargetApplication()
        recordingPreselectedText = nil
        recordingPreselectedRange = nil
        notchTargetContextRefreshTask?.cancel()
        notchTargetContextRefreshTask = nil
        preloadedHotContextTask?.cancel()
        preloadedHotContextTask = nil
        cancelActiveRecipientExtraction()
        notchCoordinator.recordingLocked = false
        resetRecordingAudioFeedback()
        notchCoordinator.setTargetContext(
            bundleId: recordingTargetApplication?.bundleIdentifier,
            windowTitle: nil,
            browserURL: nil
        )
        notchCoordinator.setState(.processing(progress: 0, stage: "Opening microphone…"))

        // Pause media/hot mic after notch is visible — these can be slow
        pauseMediaForRecordingIfNeeded()
        await pauseHotMicForDictation()
        guard recordingStartOwnership.owns(startAttemptID) else {
            if !settingsManager.lowLatencyMode {
                audioRecorder.teardownWarmSession()
            }
            return
        }
        refreshNotchTargetContext(for: recordingTargetApplication)
        activeDictationID = UUID().uuidString.lowercased()

        audioRecorder.onLevelUpdate = { [weak self] level in self?.handleAudioLevel(level) }
        audioRecorder.onDeadCaptureRestart = { [weak self] recovered in
            self?.handleDeadCaptureRestart(recovered: recovered, mode: .dictation)
        }
        do {
            try await startRecordingWithFallback(startAttemptID: startAttemptID)
            // If cancellation retired this attempt while we were awaiting,
            // don't mutate or cancel a newer capture that now owns the manager.
            guard finishRecordingStartAttempt(startAttemptID), isStartingRecording else { return }

            isStartingRecording = false
            isRecording = true
            if DictationLivePreviewController.isEligible(
                settings: settingsManager,
                modelRegistry: modelRegistry
            ) {
                dictationLivePreview.begin(inputDeviceUID: settingsManager.inputDeviceUID)
            }
            recordingStartedAt = Date()
            // Hotkey-press → recorder-running. This is the window that clipped
            // first words; it has to be measurable to prove the warm-up works.
            lastCaptureStartGapMs = Int(Date().timeIntervalSince(hotkeyAcceptedAt) * 1000)
            notchCoordinator.setState(.recording(mode: .dictation, level: 0, elapsed: 0))
            scheduleLowAudioWarning(mode: .dictation)
            analyticsManager.capture("dictation_started", properties: activeDictationAnalyticsProperties([
                "hotkey_mode": settingsManager.hotkeyMode.rawValue,
                "model": settingsManager.selectedModelId,
                "trigger_key": settingsManager.hotkeyTrigger.rawValue,
                "model_ready_at_start": modelRegistry.activeIsReady,
                "capture_start_gap_ms": lastCaptureStartGapMs as Any,
                "warm_session_used": dictationManager.lastDidUseWarmSession
            ]))
            let isLocked = hotkeyManager.isRecordingLocked
            if isLocked && !currentCaptureUsesPersistentPresentation {
                currentCaptureUsesPersistentPresentation = true
                notchCoordinator.recordingLocked = true
            }
            hotkeyManager.syncRecordingState(isActive: true, isLocked: currentCaptureUsesPersistentPresentation)
            onMenuBarRecordingActivityChange?(true)
            if pendingStopAfterStart {
                pendingStopAfterStart = false
                await endDictation()
            }
        } catch is CancellationError {
            guard finishRecordingStartAttempt(startAttemptID) else { return }
            if isStartingRecording {
                await cancelRecording(reason: "start_cancelled", shouldTrackCancellation: false)
            }
            return
        } catch {
            guard finishRecordingStartAttempt(startAttemptID) else { return }
            isStartingRecording = false
            pendingStopAfterStart = false
            audioRecorder.onLevelUpdate = nil
            recordingStartedAt = nil
            recordingTargetApplication = nil
            currentCaptureUsesPersistentPresentation = false
            notchCoordinator.recordingLocked = false
            clearRecordingAudioFeedback()
            hotkeyManager.syncRecordingState(isActive: false, isLocked: false)
            preloadedHotContextTask?.cancel()
            preloadedHotContextTask = nil
            notchTargetContextRefreshTask?.cancel()
            notchTargetContextRefreshTask = nil
            cancelActiveRecipientExtraction()
            screenContextBiasSession.begin()
            prewarmVocabularyBoostEngine()
            analyticsManager.capture("dictation_error", properties: activeDictationAnalyticsProperties([
                "stage": "start",
                "error_type": analyticsErrorType(error),
                "model": settingsManager.selectedModelId
            ]))
            activeDictationID = nil
            playAudioCue(.error)
            notchCoordinator.showError(startFailureMessage(for: error), subtype: startFailureSubtype(for: error))
            resumeMediaAfterRecording()
            await resumeHotMicAfterDictation()
            rewarmAfterFailedRecordingStartIfNeeded()
        }
    }

    private func refreshNotchTargetContext(for targetApplication: NSRunningApplication?) {
        // Reset before the new target's context resolves so a decode never
        // reads the previous dictation's screen terms.
        screenContextBiasSession.begin()
        let screenBiasGeneration = screenContextBiasSession.generation
        guard let targetApplication else { return }

        notchTargetContextRefreshTask?.cancel()
        preloadedHotContextTask?.cancel()
        cancelActiveRecipientExtraction()

        // Preload the hot context once. The stop path awaits this same handle,
        // so the AX work happens during speech instead of after key release.
        let extractor = self.contextExtractor
        let preloadTask: Task<ContextExtractor.HotContext, Never> = Task.detached(priority: .userInitiated) {
            // No AppleScript fallback here: it can throw the "Resonant wants
            // to control Chrome" Automation sheet in the middle of the user's
            // first dictation. The ambient collector makes the same choice.
            await extractor.extractHot(from: targetApplication, allowBrowserAutomationFallback: false)
        }
        preloadedHotContextTask = preloadTask

        let processIdentifier = targetApplication.processIdentifier
        notchTargetContextRefreshTask = Task { [weak self] in
            guard let self else { return }
            let hot = await preloadTask.value
            if Task.isCancelled { return }
            guard recordingTargetApplication?.processIdentifier == processIdentifier else { return }
            guard screenContextBiasSession.bindTarget(
                fingerprint: hot.targetFingerprint,
                ifGeneration: screenBiasGeneration
            ) else {
                return
            }

            let earlySelectedText = hot.selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !earlySelectedText.isEmpty {
                recordingPreselectedText = earlySelectedText
                recordingPreselectedRange = hot.selectedRange
            }

            notchCoordinator.setTargetContext(
                bundleId: hot.bundleId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? targetApplication.bundleIdentifier
                    : hot.bundleId,
                windowTitle: hot.windowTitle,
                browserURL: hot.browserURL
            )

            // Screen names for decode biasing, published for the vocabulary
            // boost terms provider. Runs on the main actor because the
            // extractor is NSSpellChecker-backed; it happens during speech,
            // off the latency path. The stop-time packet re-extracts with
            // cold context for the cloud pass; this exists because the decode
            // cannot wait for that. AX selections are unbounded (select-all),
            // so cap what this extra pass scans — the stop-time build still
            // sees the full text.
            // The privacy toggles govern this harvest too: with context
            // metadata off or HIPAA mode on, no screen-read entity may reach
            // the decode vocabulary or personalization memory.
            guard settingsManager.contextMetadataEnabled, !settingsManager.hipaaMode else { return }

            var hotForBias = hot
            hotForBias.selectedText = String(hot.selectedText.prefix(2_000))
            let entities = ContextEntityExtractor.extract(
                surface: SurfaceClassifier.classify(hot: hot),
                hot: hotForBias
            )
            guard screenContextBiasSession.updateBase(
                entities: entities,
                ifGeneration: screenBiasGeneration
            ) else {
                return
            }
            // Screen terms usually change the engine's term fingerprint, and
            // a vocabulary rebuild reloads the CTC tokenizer from disk — pay
            // that now, during speech, instead of on the stop→paste path.
            prewarmVocabularyBoostEngine()

            // Recipient AX is a separately cancellable sibling of the hot
            // preload. It is useful only for dictation and only when context
            // metadata is enabled; memo and privacy-disabled captures never
            // enter the focused-ancestor walk.
            guard currentMode == .dictation,
                  settingsManager.contextMetadataEnabled,
                  let targetFingerprint = hot.targetFingerprint,
                  let recipientTask = extractor.makeActiveRecipientExtractionTask(
                      from: targetApplication,
                      hot: hot
                  ) else {
                return
            }
            let recipientTaskID = UUID()
            activeRecipientContextTask = (recipientTaskID, recipientTask)
            let recipient = await recipientTask.value
            if activeRecipientContextTask?.id == recipientTaskID {
                activeRecipientContextTask = nil
            }
            guard !Task.isCancelled,
                  recordingTargetApplication?.processIdentifier == processIdentifier,
                  let recipient else {
                return
            }

            _ = screenContextBiasSession.publishRecipient(
                recipient,
                ifGeneration: screenBiasGeneration,
                targetFingerprint: targetFingerprint
            )
        }
    }

    private func cancelActiveRecipientExtraction() {
        activeRecipientContextTask?.task.cancel()
        activeRecipientContextTask = nil
    }

    func endDictation() async {
        guard currentMode == .dictation else { return }
        if isStartingRecording {
            pendingStopAfterStart = true
            return
        }
        guard isRecording else { return }
        let captureRecoveryID = activeCaptureRecoveryID
        // Audio retention is a capture-start contract. A Settings toggle while
        // speaking applies to the next capture, so crash recovery and normal
        // finalization always agree on this generation's intent.
        let shouldPersistAudio = activeCaptureShouldPersistAudio
            ?? settingsManager.saveAudioEnabled
        let keepWorkflowVisible = currentCaptureUsesPersistentPresentation || settingsManager.hotkeyMode == .toggle
        isRecording = false
        dictationLivePreview.end()
        notchCoordinator.recordingLocked = false
        hotkeyManager.syncRecordingState(isActive: false, isLocked: false, isFinishing: true)
        isFinishingCapture = true
        let finalizationRetirement = beginCaptureFinalizationRetirement()
        dictationFinalizationCommitted = false
        onMenuBarRecordingActivityChange?(settingsManager.lowLatencyMode)
        audioRecorder.onLevelUpdate = nil
        clearRecordingAudioFeedback()
        if keepWorkflowVisible {
            notchCoordinator.setState(.processing(progress: 0, stage: "Transcribing…"))
        } else {
            notchCoordinator.setState(.idle)
        }
        defer {
            dictationFinalizationCommitted = false
            currentCaptureUsesPersistentPresentation = false
            recordingStartedAt = nil
            if captureCancellationQuiescenceID == nil {
                isFinishingCapture = false
                hotkeyManager.syncRecordingState(isActive: false, isLocked: false)
                rewarmIfLowLatency()
            }
            completeCaptureFinalizationRetirement(finalizationRetirement)
        }
        // Scopes the post-decode screen-term clear to THIS capture: a next
        // dictation can legally start while this stop is still awaiting, and
        // its freshly captured terms must survive.
        let screenBiasGeneration = screenContextBiasSession.generation
        do {
            let activeRecipientContext = screenContextBiasSession
                .snapshotAndSealRecipient(ifGeneration: screenBiasGeneration)
            let preselected = recordingPreselectedText
            let preselectedRange = recordingPreselectedRange
            recordingPreselectedText = nil
            recordingPreselectedRange = nil
            let latencyLogger = DictationLatencyLogger(
                targetBundleId: recordingTargetApplication?.bundleIdentifier
            )
            activeLatencyLogger = latencyLogger
            let preloadHandle = preloadedHotContextTask
            preloadedHotContextTask = nil
            // A late-resolving refresh must not repopulate screen terms after
            // the post-decode clear below.
            cancelActiveRecipientExtraction()
            notchTargetContextRefreshTask?.cancel()
            notchTargetContextRefreshTask = nil
            let dictationID = activeDictationID
            await recordUnsupportedVocabularyBoostAdapterAttemptIfNeeded()
            let result = try await dictationManager.stopAndTranscribe(
                targetApplication: recordingTargetApplication,
                preloadedHotContext: preloadHandle,
                activeRecipientContext: activeRecipientContext,
                fallbackSelectedText: preselected,
                fallbackSelectedRange: preselectedRange,
                latencyLogger: latencyLogger,
                onCaptureStopped: { [weak self] in
                    self?.playAudioCue(.stop)
                    self?.resumeMediaAfterRecording()
                    self?.refreshMeetingDetectionAfterLocalCaptureIfNeeded()
                },
                onModelWaitBegan: { [weak self] in
                    guard let self, keepWorkflowVisible else { return }
                    self.notchCoordinator.setState(
                        .processing(progress: 0.05, stage: "Preparing model…")
                    )
                }
            )
            // The decode (and its vocabulary rescore) is done: this capture's
            // screen terms must not leak into later decodes — command mode,
            // retries, and feed re-transcription share the same boost engine.
            if screenContextBiasSession.end(ifGeneration: screenBiasGeneration) {
                prewarmVocabularyBoostEngine()
            }
            let resultTaskID = UUID()
            let resultTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.handleResult(
                    result,
                    mode: .dictation,
                    keepWorkflowVisible: keepWorkflowVisible,
                    dictationID: dictationID,
                    captureRecoveryID: captureRecoveryID,
                    shouldPersistAudio: shouldPersistAudio
                )
            }
            activeCaptureResultTask = (resultTaskID, resultTask)
            await resultTask.value
            if activeCaptureResultTask?.id == resultTaskID {
                activeCaptureResultTask = nil
            }
            presentCaptureDropoutNoticeIfNeeded()
        } catch is CancellationError {
            if screenContextBiasSession.end(ifGeneration: screenBiasGeneration) {
                prewarmVocabularyBoostEngine()
            }
            noteUnproductiveCaptureEnded()
            await clearOwnedActiveCapture(id: captureRecoveryID)
            _ = activeLatencyLogger?.finish(outcome: "cancelled")
            activeLatencyLogger = nil
            resumeMediaAfterRecording()
            recordingTargetApplication = nil
            notchCoordinator.setState(.idle)
            activeDictationID = nil
        } catch {
            if screenContextBiasSession.end(ifGeneration: screenBiasGeneration) {
                prewarmVocabularyBoostEngine()
            }
            noteUnproductiveCaptureEnded()
            if dictationManager.lastFailureDiscardedRecording {
                await clearOwnedActiveCapture(id: captureRecoveryID)
            }
            resumeMediaAfterRecording()
            let failedCaptureTargetBundleId = recordingTargetApplication?.bundleIdentifier
            recordingTargetApplication = nil
            let captureDiagnostics = dictationManager.lastCaptureDiagnostics
            let durationMs = currentCaptureDurationMs()
            let disposition = DictationCaptureFailurePolicy.disposition(
                for: error,
                wallClockDurationMs: durationMs,
                captureDiagnostics: captureDiagnostics,
                silenceDiagnostics: dictationManager.lastSilenceDiagnostics
            )
            _ = activeLatencyLogger?.finish(
                outcome: disposition == .silentCancel ? "aborted" : "failure"
            )
            activeLatencyLogger = nil

            // Presentable failures with surviving audio become retryable: the
            // words are on disk, so the error strip offers one-tap Retry
            // instead of asking the user to say everything again.
            if DictationCaptureFailurePolicy.shouldPresentCaptureFailure(disposition),
               let failedStash = dictationManager.lastFailedRecordingStash,
               failedStash.fileStillExists {
                retryableDictationCapture = RetryableDictationCapture(
                    url: failedStash.url,
                    duration: failedStash.duration,
                    captureRecoveryID: captureRecoveryID,
                    shouldPersistAudio: shouldPersistAudio,
                    targetBundleId: failedCaptureTargetBundleId
                )
            } else {
                retryableDictationCapture = nil
            }

            if !DictationCaptureFailurePolicy.shouldPresentCaptureFailure(disposition) {
                // Silent cancel — false start or accidental tap.
                var properties: [String: Any] = [
                    "duration_ms": durationMs as Any,
                    "error_type": analyticsErrorType(error),
                    "model": settingsManager.selectedModelId
                ]
                appendCaptureDiagnostics(
                    captureDiagnostics,
                    wallClockDurationMs: durationMs,
                    to: &properties
                )
                analyticsManager.capture("dictation_silent_cancel", properties: activeDictationAnalyticsProperties(properties))
                notchCoordinator.setState(.idle)
            } else if disposition == .userActionRequired {
                // Hard error — user needs to fix something.
                var properties: [String: Any] = [
                    "stage": "transcribe",
                    "error_type": analyticsErrorType(error),
                    "model": settingsManager.selectedModelId,
                    "duration_ms": durationMs as Any
                ]
                appendCaptureDiagnostics(
                    captureDiagnostics,
                    wallClockDurationMs: durationMs,
                    to: &properties
                )
                analyticsManager.capture("dictation_error", properties: activeDictationAnalyticsProperties(properties))
                SentryManager.shared.captureException(error, context: ["source": "AppState.endDictation"])
                playAudioCue(.error)
                notchCoordinator.showError(
                    transcriptionFailureMessage(for: error, mode: .dictation),
                    subtype: transcriptionFailureSubtype(for: error)
                )
            } else {
                // Soft audio issue — visible guidance, but no error sound.
                let suppressPresentation = Self.isLikelyAccidentalTap(
                    error: error,
                    capturedDurationMs: captureDiagnostics?.durationMilliseconds,
                    peakDb: dictationManager.lastSilenceDiagnostics?.peakDb
                )
                var properties: [String: Any] = [
                    "model": settingsManager.selectedModelId,
                    "error_type": analyticsErrorType(error),
                    "duration_ms": durationMs as Any,
                    "presentation_suppressed": suppressPresentation
                ]
                appendCaptureDiagnostics(
                    captureDiagnostics,
                    wallClockDurationMs: durationMs,
                    to: &properties
                )
                analyticsManager.capture("dictation_audio_unrecognized", properties: activeDictationAnalyticsProperties(properties))
                if suppressPresentation {
                    notchCoordinator.setState(.idle)
                } else {
                    let presentation = softAudioFailurePresentation(for: error)
                    notchCoordinator.showError(presentation.message, subtype: presentation.subtype)
                }
            }
            activeDictationID = nil
        }
        await resumeHotMicAfterDictation()
    }

    // MARK: - Retry failed dictation

    struct RetryableDictationCapture {
        let url: URL
        let duration: TimeInterval
        let captureRecoveryID: UUID?
        let shouldPersistAudio: Bool
        let targetBundleId: String?
    }

    private struct RetryableCaptureSupersession {
        let capture: RetryableDictationCapture
        let markerSnapshot: RecoveryStore.ActiveCaptureMarkerSnapshot?
    }

    private struct RetryableCaptureSupersessionError: LocalizedError {
        var errorDescription: String? {
            "Could not safely replace the previous recording"
        }
    }

    var canRetryLastFailedDictation: Bool {
        guard let capture = retryableDictationCapture else { return false }
        guard !isClearingWorkspace,
              !isRecording,
              !isStartingRecording,
              !isFinishingCapture,
              !isRetryingDictation else {
            return false
        }
        return FileManager.default.fileExists(atPath: capture.url.path)
    }

    /// Re-runs transcription on the last failed dictation's saved audio. The
    /// notch "Retry" action lands here; delivery then follows the normal
    /// result path (paste/copy/persist) against the current frontmost app.
    func retryLastFailedDictation() async {
        guard canRetryLastFailedDictation, let capture = retryableDictationCapture else { return }
        isRetryingDictation = true
        isFinishingCapture = true
        currentMode = .dictation
        dictationFinalizationCommitted = false
        let finalizationRetirement = beginCaptureFinalizationRetirement()
        defer {
            dictationFinalizationCommitted = false
            isRetryingDictation = false
            if captureCancellationQuiescenceID == nil {
                isFinishingCapture = false
            }
            completeCaptureFinalizationRetirement(finalizationRetirement)
        }

        let resultTaskID = UUID()
        let resultTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performRetryLastFailedDictation(capture)
        }
        activeCaptureResultTask = (resultTaskID, resultTask)
        await withTaskCancellationHandler {
            await resultTask.value
        } onCancel: {
            resultTask.cancel()
        }
        if activeCaptureResultTask?.id == resultTaskID {
            activeCaptureResultTask = nil
        }
    }

    private func performRetryLastFailedDictation(_ capture: RetryableDictationCapture) async {
        analyticsManager.capture("dictation_retry_started", properties: [
            "model": settingsManager.selectedModelId,
            "duration_ms": Int(capture.duration * 1000)
        ])
        notchCoordinator.setState(.processing(progress: 0.05, stage: "Retrying…"))
        let latencyLogger = DictationLatencyLogger(targetBundleId: capture.targetBundleId)
        activeLatencyLogger = latencyLogger

        do {
            await recordUnsupportedVocabularyBoostAdapterAttemptIfNeeded()
            let result = try await dictationManager.retryTranscribeRecordedClip(
                at: capture.url,
                duration: capture.duration,
                targetApplication: activeTargetApplication(),
                latencyLogger: latencyLogger,
                onModelWaitBegan: { [weak self] in
                    self?.notchCoordinator.setState(
                        .processing(progress: 0.05, stage: "Preparing model…")
                    )
                }
            )
            retryableDictationCapture = nil
            analyticsManager.capture("dictation_retry_succeeded", properties: [
                "model": settingsManager.selectedModelId
            ])
            await handleResult(
                result,
                mode: .dictation,
                keepWorkflowVisible: true,
                dictationID: nil,
                captureRecoveryID: capture.captureRecoveryID,
                shouldPersistAudio: capture.shouldPersistAudio
            )
        } catch is CancellationError {
            _ = activeLatencyLogger?.finish(outcome: "cancelled")
            activeLatencyLogger = nil
            notchCoordinator.setState(.idle)
        } catch {
            _ = activeLatencyLogger?.finish(outcome: "failure")
            activeLatencyLogger = nil
            analyticsManager.capture("dictation_retry_failed", properties: [
                "model": settingsManager.selectedModelId,
                "error_type": analyticsErrorType(error)
            ])
            // Keep the stash while the clip survives so the user can retry
            // again (e.g. after switching models) — otherwise fall back to
            // the plain failure presentation.
            if let remaining = retryableDictationCapture,
               !FileManager.default.fileExists(atPath: remaining.url.path) {
                retryableDictationCapture = nil
            }
            playAudioCue(.error)
            notchCoordinator.showError(
                transcriptionFailureMessage(for: error, mode: .dictation),
                subtype: transcriptionFailureSubtype(for: error)
            )
        }
    }

    func startMemo() async {
        Self.log.info("startMemo invoked. isRecording=\(self.isRecording, privacy: .public) isStarting=\(self.isStartingRecording, privacy: .public) isFinishing=\(self.isFinishingCapture, privacy: .public) hotkeySource=\(self.hotkeyManager.lastTriggerSource, privacy: .public)")
        guard allowsLocalAudioCapture else {
            Self.log.info("startMemo rejected — terminal lifecycle state")
            return
        }
        if isRecording || isStartingRecording || isFinishingCapture {
            Self.log.info("startMemo rejected — already in flight")
            playAudioCue(.error)
            notchCoordinator.showError("Resonant is busy — try again in a sec.", subtype: .generic)
            return
        }
        guard !rejectNewCaptureForPendingRecovery() else { return }
        // Speculative warm — same first-words rationale as startDictation().
        audioRecorder.warmUp(
            selectedInputDeviceUID: settingsManager.inputDeviceUID,
            intent: .imminentCapture
        )
        recordingPreselectedText = nil
        recordingPreselectedRange = nil
        notchTargetContextRefreshTask?.cancel()
        notchTargetContextRefreshTask = nil
        preloadedHotContextTask?.cancel()
        preloadedHotContextTask = nil
        cancelActiveRecipientExtraction()

        currentMode = .memo
        let startAttemptID = beginRecordingStartAttempt()
        pendingStopAfterStart = false
        currentCaptureUsesPersistentPresentation = false
        recordingStartedAt = Date()
        recordingTargetApplication = activeTargetApplication()
        notchCoordinator.recordingLocked = false
        resetRecordingAudioFeedback()
        notchCoordinator.setTargetContext(
            bundleId: recordingTargetApplication?.bundleIdentifier,
            windowTitle: nil,
            browserURL: nil
        )
        notchCoordinator.setState(.processing(progress: 0, stage: "Opening microphone…"))

        // Pause media/hot mic after notch is visible — these can be slow
        pauseMediaForRecordingIfNeeded()
        await pauseHotMicForDictation()
        guard recordingStartOwnership.owns(startAttemptID) else {
            if !settingsManager.lowLatencyMode {
                audioRecorder.teardownWarmSession()
            }
            return
        }
        refreshNotchTargetContext(for: recordingTargetApplication)

        audioRecorder.onLevelUpdate = { [weak self] level in self?.handleAudioLevel(level) }
        audioRecorder.onDeadCaptureRestart = { [weak self] recovered in
            self?.handleDeadCaptureRestart(recovered: recovered, mode: .memo)
        }
        do {
            try await startRecordingWithFallback(startAttemptID: startAttemptID)
            guard finishRecordingStartAttempt(startAttemptID), isStartingRecording else { return }

            isStartingRecording = false
            isRecording = true
            recordingStartedAt = Date()
            notchCoordinator.setState(.recording(mode: .memo, level: 0, elapsed: 0))
            scheduleLowAudioWarning(mode: .memo)
            let isLocked = hotkeyManager.isRecordingLocked
            if isLocked && !currentCaptureUsesPersistentPresentation {
                currentCaptureUsesPersistentPresentation = true
                notchCoordinator.recordingLocked = true
            }
            hotkeyManager.syncRecordingState(isActive: true, isLocked: currentCaptureUsesPersistentPresentation)
            onMenuBarRecordingActivityChange?(true)
            if pendingStopAfterStart {
                pendingStopAfterStart = false
                await endMemo()
            }
        } catch is CancellationError {
            guard finishRecordingStartAttempt(startAttemptID) else { return }
            if isStartingRecording {
                await cancelRecording(reason: "start_cancelled", shouldTrackCancellation: false)
            }
            return
        } catch {
            guard finishRecordingStartAttempt(startAttemptID) else { return }
            isStartingRecording = false
            pendingStopAfterStart = false
            audioRecorder.onLevelUpdate = nil
            recordingStartedAt = nil
            recordingTargetApplication = nil
            currentCaptureUsesPersistentPresentation = false
            notchCoordinator.recordingLocked = false
            clearRecordingAudioFeedback()
            hotkeyManager.syncRecordingState(isActive: false, isLocked: false)
            preloadedHotContextTask?.cancel()
            preloadedHotContextTask = nil
            notchTargetContextRefreshTask?.cancel()
            notchTargetContextRefreshTask = nil
            cancelActiveRecipientExtraction()
            screenContextBiasSession.begin()
            prewarmVocabularyBoostEngine()
            playAudioCue(.error)
            notchCoordinator.showError(startFailureMessage(for: error), subtype: startFailureSubtype(for: error))
            resumeMediaAfterRecording()
            await resumeHotMicAfterDictation()
            rewarmAfterFailedRecordingStartIfNeeded()
        }
    }

    func endMemo() async {
        guard currentMode == .memo else { return }
        if isStartingRecording {
            pendingStopAfterStart = true
            return
        }
        guard isRecording else { return }
        let captureRecoveryID = activeCaptureRecoveryID
        let shouldPersistAudio = activeCaptureShouldPersistAudio
            ?? settingsManager.saveAudioEnabled
        let keepWorkflowVisible = currentCaptureUsesPersistentPresentation
        isRecording = false
        notchCoordinator.recordingLocked = false
        hotkeyManager.syncRecordingState(isActive: false, isLocked: false, isFinishing: true)
        isFinishingCapture = true
        let finalizationRetirement = beginCaptureFinalizationRetirement()
        memoFinalizationCommitted = false
        onMenuBarRecordingActivityChange?(settingsManager.lowLatencyMode)
        audioRecorder.onLevelUpdate = nil
        clearRecordingAudioFeedback()
        if keepWorkflowVisible {
            notchCoordinator.setState(.processing(progress: 0, stage: "Saving memo…"))
        } else {
            notchCoordinator.setState(.idle)
        }
        defer {
            memoFinalizationCommitted = false
            currentCaptureUsesPersistentPresentation = false
            recordingStartedAt = nil
            if captureCancellationQuiescenceID == nil {
                isFinishingCapture = false
                hotkeyManager.syncRecordingState(isActive: false, isLocked: false)
                rewarmIfLowLatency()
            }
            completeCaptureFinalizationRetirement(finalizationRetirement)
        }
        let screenBiasGeneration = screenContextBiasSession.generation
        do {
            _ = screenContextBiasSession.snapshotAndSealRecipient(
                ifGeneration: screenBiasGeneration
            )
            let preloadHandle = preloadedHotContextTask
            preloadedHotContextTask = nil
            cancelActiveRecipientExtraction()
            notchTargetContextRefreshTask?.cancel()
            notchTargetContextRefreshTask = nil
            await recordUnsupportedVocabularyBoostAdapterAttemptIfNeeded()
            let result = try await dictationManager.stopAndTranscribe(
                targetApplication: recordingTargetApplication,
                preloadedHotContext: preloadHandle,
                extractColdContext: false,
                onCaptureStopped: { [weak self] in
                    self?.playAudioCue(.stop)
                    self?.resumeMediaAfterRecording()
                    self?.refreshMeetingDetectionAfterLocalCaptureIfNeeded()
                }
            )
            if screenContextBiasSession.end(ifGeneration: screenBiasGeneration) {
                prewarmVocabularyBoostEngine()
            }
            let resultTaskID = UUID()
            let resultTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.handleMemoResult(
                    result,
                    captureRecoveryID: captureRecoveryID,
                    shouldPersistAudio: shouldPersistAudio,
                    keepWorkflowVisible: keepWorkflowVisible
                )
            }
            activeCaptureResultTask = (resultTaskID, resultTask)
            await resultTask.value
            if activeCaptureResultTask?.id == resultTaskID {
                activeCaptureResultTask = nil
            }
        } catch is CancellationError {
            if screenContextBiasSession.end(ifGeneration: screenBiasGeneration) {
                prewarmVocabularyBoostEngine()
            }
            await clearOwnedActiveCapture(id: captureRecoveryID)
            resumeMediaAfterRecording()
            recordingTargetApplication = nil
            notchCoordinator.setState(.idle)
        } catch {
            if screenContextBiasSession.end(ifGeneration: screenBiasGeneration) {
                prewarmVocabularyBoostEngine()
            }
            if dictationManager.lastFailureDiscardedRecording {
                await clearOwnedActiveCapture(id: captureRecoveryID)
            }
            resumeMediaAfterRecording()
            recordingTargetApplication = nil
            let captureDiagnostics = dictationManager.lastCaptureDiagnostics
            let durationMs = currentCaptureDurationMs()
            let disposition = DictationCaptureFailurePolicy.disposition(
                for: error,
                wallClockDurationMs: durationMs,
                captureDiagnostics: captureDiagnostics
            )

            if disposition == .silentCancel {
                notchCoordinator.setState(.idle)
            } else if disposition == .userActionRequired {
                SentryManager.shared.captureException(error, context: ["source": "AppState.endMemo"])
                playAudioCue(.error)
                notchCoordinator.showError(
                    transcriptionFailureMessage(for: error, mode: .memo),
                    subtype: transcriptionFailureSubtype(for: error)
                )
            } else {
                let presentation = softAudioFailurePresentation(for: error)
                notchCoordinator.showError(presentation.message, subtype: presentation.subtype)
            }
        }
        await resumeHotMicAfterDictation()
    }

    private func handleMemoResult(
        _ result: TranscriptionResult,
        captureRecoveryID: UUID?,
        shouldPersistAudio: Bool,
        keepWorkflowVisible: Bool
    ) async {
        guard currentMode == .memo, !Task.isCancelled else {
            result.coldContextTask?.cancel()
            cleanupTemporaryRecording(at: result.recordingURL)
            await clearOwnedActiveCapture(id: captureRecoveryID)
            return
        }

        let memoID = UUID()
        let memoDate = Date()
        guard await prepareOwnedActiveCaptureForPersistence(
            id: captureRecoveryID,
            entryID: memoID,
            entryDate: memoDate,
            shouldPersistAudio: shouldPersistAudio
        ) else {
            result.coldContextTask?.cancel()
            return
        }
        let saveResult = await memoManager.save(
            id: memoID,
            date: memoDate,
            text: result.text,
            duration: result.duration,
            recordingURL: result.recordingURL,
            shouldPersistAudio: shouldPersistAudio
        )
        let memo = saveResult.memo
        guard currentMode == .memo, !Task.isCancelled else {
            result.coldContextTask?.cancel()
            let discardPrepared: Bool
            if let captureRecoveryID {
                discardPrepared = await recoveryStore.markActiveCaptureForDiscard(
                    id: captureRecoveryID
                )
            } else {
                discardPrepared = true
            }
            guard discardPrepared, await memoManager.rollback(memo) else {
                Self.log.error("Memo cancellation rollback remains pending")
                return
            }
            await clearOwnedActiveCapture(id: captureRecoveryID)
            cleanupTemporaryRecording(at: result.recordingURL)
            return
        }
        // Persistence has committed and cancellation can no longer be
        // rolled back atomically across the feed/activity/archive sinks.
        // From here to the terminal UI this is one non-cancellable commit.
        memoFinalizationCommitted = true
        _ = await archiveWriter.writeMemo(memo: memo)
        let coreCommitted = saveResult.dataStoreCommitted
            && saveResult.didPersistRequestedAudio
        let activityCommitted: Bool
        if coreCommitted {
            activityCommitted = await activityStreamWriter.writeMemoEvent(memo: memo)
        } else {
            activityCommitted = false
        }
        guard coreCommitted, activityCommitted else {
            Self.log.error(
                "Memo durable handoff incomplete text=\(saveResult.dataStoreCommitted, privacy: .public) audio=\(saveResult.didPersistRequestedAudio, privacy: .public) activity=\(activityCommitted, privacy: .public)"
            )
            notchCoordinator.showNotice(
                NotchOverlayState.Notice(
                    title: "Memo save still pending",
                    detail: "Your recording is safe and will be recovered next launch.",
                    icon: "exclamationmark.arrow.triangle.2.circlepath"
                ),
                timeout: .seconds(7)
            )
            return
        }
        feedManager.record(memo)
        workspaceSyncEngine.markExportNeeded()
        await clearOwnedActiveCapture(id: captureRecoveryID)
        cleanupTemporaryRecording(at: result.recordingURL)
        selectedSettingsTab = .home
        selectedFeedItemID = memo.id
        analyticsManager.capture("memo_saved", properties: [
            "captured_duration_ms": result.captureDiagnostics?.durationMilliseconds as Any,
            "captured_sample_count": result.captureDiagnostics?.sampleCount as Any,
            "duration_ms": Int(result.duration * 1000),
            "duration_seconds": result.duration,
            "save_audio_enabled": shouldPersistAudio,
            "word_count": result.text.split(separator: " ").count
        ])
        playAudioCue(.success)
        if keepWorkflowVisible {
            notchCoordinator.showDone("Memo: \(memo.displayTitle)")
        } else {
            notchCoordinator.setState(.idle)
        }

        autoDistillIfEligible(memo: memo, text: result.text)
        autoTitleIfEligible(memo: memo)
    }

    private func autoTitleIfEligible(memo: MemoEntry) {
        guard authManager.isLoggedIn else { return }
        let memoID = memo.id
        memoTitleDebouncer.schedule(
            key: memoID,
            delay: BackgroundCloudWorkDelay.memoEnrichment
        ) { [weak self] in
            guard let self else { return }
            guard let refreshedMemo = self.memoManager.memo(id: memoID) ?? self.dataStore.memoEntry(id: memoID) else {
                return
            }
            await self.memoManager.generateAITitle(for: refreshedMemo, using: self.convexClient)
        }
    }

    private func autoDistillIfEligible(memo: MemoEntry, text: String) {
        guard authManager.isLoggedIn else { return }

        let title = memo.displayTitle
        let memoID = memo.id
        let requestText = """
        \(kDefaultMemoDistillPrompt)

        Memo title: \(title)

        Memo transcript:
        \(text)
        """
        memoDistillationDebouncer.schedule(
            key: memoID,
            delay: BackgroundCloudWorkDelay.memoEnrichment
        ) { [weak self] in
            guard let self else { return }
            guard let refreshedMemo = self.memoManager.memo(id: memoID) ?? self.dataStore.memoEntry(id: memoID) else {
                return
            }
            if refreshedMemo.distilledText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                return
            }
            if let distilled = await self.convexClient.processMemo(
                text: requestText,
                modelRoute: .meetingSummary
            )?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !distilled.isEmpty {
                await self.memoManager.updateDistilledText(for: refreshedMemo, distilledText: distilled)
            }
        }
    }

    private func scheduleJournalGeneration(for date: Date) {
        let day = Calendar.current.startOfDay(for: date)
        journalGenerationDebouncer.schedule(
            key: day,
            delay: BackgroundCloudWorkDelay.journalGeneration
        ) { [weak self] in
            guard let self else { return }
            guard await self.journalManager.hasJournal(on: day) else { return }
            _ = await self.journalManager.generate(for: day)
        }
    }

    func lockCurrentRecording() async {
        guard (isRecording || isStartingRecording), !currentCaptureUsesPersistentPresentation else { return }
        currentCaptureUsesPersistentPresentation = true
        notchCoordinator.recordingLocked = true
        hotkeyManager.syncRecordingState(isActive: true, isLocked: true)
    }

    func cancelActiveInteraction(reason: String = "escape") async {
        let hadCommandInteraction =
            isInCommandMode
            || currentMode == .command
            || activeCommandID != nil
            || commandRouter.isProcessing
            || isCommandPresentationVisible

        commandRouter.cancelCurrentCommand()
        commandFollowUpTask?.cancel()
        commandFollowUpTask = nil

        activeCommandID = nil

        if isRecording || isStartingRecording || isFinishingCapture {
            await cancelRecording(reason: reason)
            return
        }

        guard hadCommandInteraction else { return }

        disarmStartingRecordingWatchdog()
        isInCommandMode = false
        currentMode = .dictation
        isStartingRecording = false
        isFinishingCapture = true
        defer {
            isFinishingCapture = false
            hotkeyManager.syncRecordingState(isActive: false, isLocked: false)
            rewarmIfLowLatency()
        }
        pendingStopAfterStart = false
        audioRecorder.onLevelUpdate = nil
        recordingStartedAt = nil
        recordingTargetApplication = nil
        notchCoordinator.recordingLocked = false
        hotkeyManager.syncRecordingState(isActive: false, isLocked: false, isFinishing: true)
        notchCoordinator.setState(.idle)
        playAudioCue(.stop)
        resumeMediaAfterRecording()
        await dictationManager.cancel()
        await resumeHotMicAfterDictation()
    }

    private var isCommandPresentationVisible: Bool {
        if case .command = notchCoordinator.state {
            return true
        }
        return false
    }

    func cancelRecording(reason: String = "user_cancel", shouldTrackCancellation: Bool = true) async {
        guard !(currentMode == .memo && memoFinalizationCommitted) else { return }
        guard !(currentMode == .dictation && dictationFinalizationCommitted) else { return }
        guard captureCancellationQuiescenceID == nil else { return }
        if !settingsManager.lowLatencyMode {
            audioRecorder.teardownWarmSession()
        }
        commandRouter.cancelCurrentCommand()
        commandFollowUpTask?.cancel()
        commandFollowUpTask = nil
        guard isRecording || isStartingRecording || isFinishingCapture else { return }
        // Raise the barrier before the first await. An original stop/finalizer
        // coroutine can otherwise resume, lower `isFinishingCapture`, and admit
        // a new generation while this cancellation is still clearing state.
        let cancellationQuiescenceID = UUID()
        captureCancellationQuiescenceID = cancellationQuiescenceID
        let pendingFinalizationRetirement = activeCaptureFinalizationRetirement
        disarmStartingRecordingWatchdog()
        let wasRecording = isRecording
        let cancelledMode = currentMode
        isRecording = false
        dictationLivePreview.end()
        isStartingRecording = false
        isFinishingCapture = true
        var defersCaptureQuiescence = false
        defer {
            if !defersCaptureQuiescence {
                if captureCancellationQuiescenceID == cancellationQuiescenceID {
                    captureCancellationQuiescenceID = nil
                }
                isFinishingCapture = false
                hotkeyManager.syncRecordingState(isActive: false, isLocked: false)
                rewarmIfLowLatency()
            }
        }
        isInCommandMode = false
        currentMode = .dictation
        pendingStopAfterStart = false
        currentCaptureUsesPersistentPresentation = false
        if wasRecording {
            onMenuBarRecordingActivityChange?(settingsManager.lowLatencyMode)
        }
        notchCoordinator.recordingLocked = false
        hotkeyManager.syncRecordingState(isActive: false, isLocked: false, isFinishing: true)
        audioRecorder.onLevelUpdate = nil
        clearRecordingAudioFeedback()
        let resultTaskID = activeCaptureResultTask?.id
        let resultTask = activeCaptureResultTask?.task
        resultTask?.cancel()
        let cancellationLatencyLogger = activeLatencyLogger
        activeLatencyLogger = nil
        notchCoordinator.setState(.idle)
        // Once stopAndTranscribe has produced a result, that result task owns
        // the terminal recording URL and recovery marker. Cancelling the manager
        // here would delete audio that committed keyboard verification may still
        // hand off to history.
        let pendingManagerQuiescence: Task<Void, Never>?
        let resultTaskOwnsTerminalArtifacts = DictationCancellationJoinPolicy
            .resultTaskOwnsTerminalArtifacts(hasActiveResultTask: resultTask != nil)
        let cancellationRecoveryID = activeCaptureRecoveryID
        let discardPrepared: Bool
        if !resultTaskOwnsTerminalArtifacts, let cancellationRecoveryID {
            discardPrepared = await recoveryStore.markActiveCaptureForDiscard(
                id: cancellationRecoveryID
            )
        } else {
            discardPrepared = !resultTaskOwnsTerminalArtifacts
        }
        if !resultTaskOwnsTerminalArtifacts {
            pendingManagerQuiescence = await dictationManager.cancel()
        } else {
            pendingManagerQuiescence = nil
        }
        if pendingFinalizationRetirement == nil, let resultTask {
            await resultTask.value
            if activeCaptureResultTask?.id == resultTaskID {
                activeCaptureResultTask = nil
            }
        }
        notchTargetContextRefreshTask?.cancel()
        notchTargetContextRefreshTask = nil
        preloadedHotContextTask?.cancel()
        preloadedHotContextTask = nil
        cancelActiveRecipientExtraction()
        screenContextBiasSession.begin()
        prewarmVocabularyBoostEngine()
        recordingTargetApplication = nil
        recordingStartedAt = nil
        if cancelledMode == .dictation {
            if shouldTrackCancellation {
                analyticsManager.capture("dictation_cancelled", properties: activeDictationAnalyticsProperties([
                    "reason": reason
                ]))
            }
            activeDictationID = nil
        }
        activeCommandID = nil

        let pendingCaptureQuiescence: Task<Void, Never>?
        if pendingManagerQuiescence != nil || pendingFinalizationRetirement != nil {
            pendingCaptureQuiescence = Task { @MainActor in
                if let pendingManagerQuiescence {
                    await pendingManagerQuiescence.value
                }
                if let pendingFinalizationRetirement {
                    await pendingFinalizationRetirement.wait()
                }
                if discardPrepared {
                    await self.clearOwnedActiveCapture(id: cancellationRecoveryID)
                }
            }
        } else {
            pendingCaptureQuiescence = nil
        }

        if let pendingCaptureQuiescence {
            defersCaptureQuiescence = true
            scheduleCaptureCancellationQuiescence(
                pendingCaptureQuiescence,
                id: cancellationQuiescenceID,
                latencyLogger: cancellationLatencyLogger
            )
            return
        }

        if discardPrepared {
            await clearOwnedActiveCapture(id: cancellationRecoveryID)
        }

        playAudioCue(.stop)
        resumeMediaAfterRecording()
        await resumeHotMicAfterDictation()
        _ = cancellationLatencyLogger?.finish(outcome: "cancelled")
    }

    private func scheduleCaptureCancellationQuiescence(
        _ pendingCaptureQuiescence: Task<Void, Never>,
        id quiescenceID: UUID,
        latencyLogger: DictationLatencyLogger?
    ) {
        captureCancellationQuiescenceTask = Task { @MainActor [weak self] in
            await pendingCaptureQuiescence.value
            guard let self,
                  self.captureCancellationQuiescenceID == quiescenceID else {
                return
            }

            // Only now is it safe to play output audio or re-arm microphone
            // work: the cancelled capture can no longer record either one.
            self.playAudioCue(.stop)
            self.resumeMediaAfterRecording()
            guard self.captureCancellationQuiescenceID == quiescenceID else { return }
            _ = latencyLogger?.finish(outcome: "cancelled")
            self.isFinishingCapture = false
            self.hotkeyManager.syncRecordingState(isActive: false, isLocked: false)
            self.captureCancellationQuiescenceID = nil
            self.captureCancellationQuiescenceTask = nil
            self.rewarmIfLowLatency()
            await self.resumeHotMicAfterDictation()
        }
    }

    private func beginCaptureFinalizationRetirement() -> CaptureFinalizationRetirement {
        let retirement = CaptureFinalizationRetirement()
        activeCaptureFinalizationRetirement = retirement
        return retirement
    }

    private func completeCaptureFinalizationRetirement(
        _ retirement: CaptureFinalizationRetirement
    ) {
        if activeCaptureFinalizationRetirement === retirement {
            activeCaptureFinalizationRetirement = nil
        }
        Task { await retirement.complete() }
    }


    /// Arms a watchdog that auto-cancels recording if `isStartingRecording`
    /// stays true for longer than `timeout`. Protects against audio system hangs
    /// or device contention (e.g. another app holding the mic).
    private func beginRecordingStartAttempt() -> UUID {
        let attemptID = recordingStartOwnership.begin()
        isStartingRecording = true
        // A delayed persistent warm must never fire into an accepted local
        // capture. The hardware deadline itself remains intact for finalization.
        audioWarmUpRecoveryCoordinator.cancelPendingActivation()
        armStartingRecordingWatchdog(for: attemptID)
        return attemptID
    }

    /// Retires the watchdog only when this continuation still owns the active
    /// start. A cancelled older coroutine can resume after a new capture begins.
    @discardableResult
    private func finishRecordingStartAttempt(_ attemptID: UUID) -> Bool {
        guard recordingStartOwnership.finish(attemptID) else { return false }
        startingRecordingWatchdog?.cancel()
        startingRecordingWatchdog = nil
        return true
    }

    private func armStartingRecordingWatchdog(
        for attemptID: UUID,
        timeout: Duration = .seconds(10)
    ) {
        startingRecordingWatchdog?.cancel()
        startingRecordingWatchdog = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled,
                  let self,
                  self.isStartingRecording,
                  self.recordingStartOwnership.owns(attemptID) else {
                return
            }
            self.analyticsManager.capture("dictation_error", properties: self.activeDictationAnalyticsProperties([
                "stage": "start",
                "error_type": "start_timeout"
            ]))
            await self.cancelRecording(reason: "start_timeout", shouldTrackCancellation: false)
        }
    }

    private func disarmStartingRecordingWatchdog() {
        recordingStartOwnership.cancel()
        startingRecordingWatchdog?.cancel()
        startingRecordingWatchdog = nil
    }

    private func ensureLoginPresentationAnchor() {
        let hasVisibleWindow = NSApplication.shared.windows.contains { window in
            window.isVisible && !window.isMiniaturized
        }

        if !hasVisibleWindow {
            showPrimaryWindow(selectedTab: .account)
        }

        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    // MARK: - Result handling

    private struct DeliveredTextResolution {
        var text: String
        var selectionTransformUsed: Bool
        var cleanup: DictationQualityTrace.Cleanup
        var transform: DictationQualityTrace.Transform
    }

    private func handleResult(
        _ result: TranscriptionResult,
        mode: DictationMode,
        keepWorkflowVisible: Bool,
        dictationID: String? = nil,
        captureRecoveryID: UUID?,
        shouldPersistAudio: Bool
    ) async {
        func resultIsStillCurrent() -> Bool {
            !Task.isCancelled && dictationID.map { activeDictationID == $0 } ?? true
        }

        // A capture that produced text is productive — clear the throttle so a
        // deliberate follow-up dictation is never debounced.
        lastUnproductiveCaptureEndedAt = nil
        // If cancelRecording fired between stopAndTranscribe returning and us
        // running, activeDictationID has been cleared (or replaced). Drop the
        // result without delivering — the user already cancelled.
        if !resultIsStillCurrent() {
            cleanupTemporaryRecording(at: result.recordingURL)
            result.coldContextTask?.cancel()
            await clearOwnedActiveCapture(id: captureRecoveryID)
            _ = activeLatencyLogger?.finish(outcome: "cancelled")
            activeLatencyLogger = nil
            return
        }
        defer {
            if dictationID == nil || activeDictationID == dictationID {
                activeDictationID = nil
            }
            _ = activeLatencyLogger?.finish(outcome: "aborted")
            activeLatencyLogger = nil
        }
        let targetApplication = recordingTargetApplication
        recordingTargetApplication = nil

        activeLatencyLogger?.mark("resolveStart")
        let resolvedTextCandidate = await resolveDeliveredText(for: result, keepWorkflowVisible: keepWorkflowVisible)
        activeLatencyLogger?.mark("resolveEnd")
        guard resultIsStillCurrent() else {
            result.coldContextTask?.cancel()
            cleanupTemporaryRecording(at: result.recordingURL)
            await clearOwnedActiveCapture(id: captureRecoveryID)
            _ = activeLatencyLogger?.finish(outcome: "cancelled")
            activeLatencyLogger = nil
            return
        }
        guard let resolvedResolution = resolvedTextCandidate else {
            // Selection transform failed or was blocked. The transcript was
            // already copied to the clipboard by abortSelectionTransform —
            // also keep a history entry so the words stay recoverable.
            let abortedTranscript = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if abortedTranscript.isEmpty {
                await clearOwnedActiveCapture(id: captureRecoveryID)
                result.coldContextTask?.cancel()
                cleanupTemporaryRecording(at: result.recordingURL)
            } else {
                let includeAbortContextMetadata = settingsManager.contextMetadataEnabled
                let abortedEntry = DictationEntry.make(
                    id: UUID(),
                    text: abortedTranscript,
                    context: LocalContextPersistencePolicy.dictationContext(
                        from: result,
                        includeMetadata: settingsManager.contextMetadataEnabled
                    ),
                    wordCount: abortedTranscript.split(separator: " ").count,
                    duration: result.duration,
                    mode: mode,
                    date: Date(),
                    rawTranscript: (result.rawTranscript != abortedTranscript) ? result.rawTranscript : nil,
                    deliveredText: nil,
                    autoPasted: false,
                    copiedToClipboard: true,
                    autoSent: false,
                    vocabularyBoostAuditSummary: result.vocabularyBoostAudit.map {
                        VocabularyBoostAuditSummary(audit: $0)
                    }
                )
                guard await prepareOwnedActiveCaptureForPersistence(
                    id: captureRecoveryID,
                    entryID: abortedEntry.id,
                    entryDate: abortedEntry.date,
                    shouldPersistAudio: shouldPersistAudio
                ) else {
                    result.coldContextTask?.cancel()
                    return
                }
                let persistenceTask = Task { @MainActor in
                    await self.persistCompletedDictation(
                        entry: abortedEntry,
                        result: result,
                        resolvedText: abortedTranscript,
                        deliveredText: nil,
                        autoPasted: false,
                        autoSent: false,
                        copiedToClipboard: true,
                        includeContextMetadata: includeAbortContextMetadata,
                        shouldPersistAudio: shouldPersistAudio
                    )
                }
                if await persistenceTask.value {
                    await clearOwnedActiveCapture(id: captureRecoveryID)
                }
            }
            return
        }
        let resolvedText = resolvedResolution.text

        let shouldPaste = settingsManager.autoPasteEnabled
        let shouldCopy = settingsManager.copyToClipboardEnabled
        let shouldSend = shouldPaste && settingsManager.autoSendEnabled
        let isSelectionTransform = resolvedResolution.selectionTransformUsed
        let linkedText = applySmartLinksIfNeeded(
            to: resolvedText,
            allowSmartLinks: !isSelectionTransform,
            source: "dictation"
        )
        let finalText = EmailSignatureSupport.removingDuplicateClosingIfNeeded(
            from: linkedText,
            appName: result.targetApp,
            bundleId: result.targetBundleId,
            windowTitle: result.windowTitle,
            browserURL: result.browserURL,
            existingFieldContent: result.focusedFieldContent
        )
        guard !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            result.coldContextTask?.cancel()
            cleanupTemporaryRecording(at: result.recordingURL)
            await clearOwnedActiveCapture(id: captureRecoveryID)
            let rawFallback = result.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !rawFallback.isEmpty {
                // Post-processing emptied a non-empty transcript — surface it
                // and keep the raw words recoverable instead of showing "Done".
                let copied = pasteManager.copy(text: rawFallback)
                analyticsManager.capture("dictation_empty_after_processing", properties: [
                    "mode": mode.rawValue,
                    "copied_fallback": copied,
                    "raw_length": rawFallback.count
                ])
                playAudioCue(.warning)
                notchCoordinator.showError(
                    copied
                        ? "Processing returned empty text. Raw transcript copied — ⌘V to paste."
                        : "Processing returned empty text.",
                    subtype: .generic
                )
            } else if keepWorkflowVisible {
                notchCoordinator.showDone("Done")
            } else {
                notchCoordinator.setState(.idle)
            }
            return
        }
        lastTranscriptionPreview = finalText
        lastDictationTargetAppName = result.targetApp ?? targetApplication?.localizedName
        lastDictationTargetBundleId = result.targetBundleId ?? targetApplication?.bundleIdentifier
        let wordCount = finalText.split(separator: " ").count
        let focusedFieldContext = pasteManager.focusedFieldContext(for: targetApplication)
        let signatureEmailMode = CloudProcessingSupport.emailDictationMode(
            transcript: finalText,
            focusedFieldContent: result.focusedFieldContent,
            focusedFieldContext: focusedFieldContext,
            appName: result.targetApp,
            bundleId: result.targetBundleId,
            windowTitle: result.windowTitle,
            browserURL: result.browserURL,
            fallbackSenderName: settingsManager.resolvedEmailSignoffName
        )
        let deliveryText = EmailSignatureSupport.applyingIfNeeded(
            to: finalText,
            enabled: settingsManager.emailSignatureEnabled && AppRuntime.distributionFlavor == .official,
            appName: result.targetApp,
            bundleId: result.targetBundleId,
            windowTitle: result.windowTitle,
            browserURL: result.browserURL,
            allowSignature: !isSelectionTransform,
            emailMode: signatureEmailMode,
            existingFieldContent: result.focusedFieldContent,
            focusedFieldContext: focusedFieldContext,
            decisionHandler: { decision in
                self.logEmailSignatureDecision(decision, source: "dictation")
            }
        )
        let styleDeliveryStageTrace = StyleDeliveryStageTrace(
            cloudOrSelectionReplacedPostProcessing: isSelectionTransform
                || resolvedText != result.text,
            smartLinksChangedText: linkedText != resolvedText,
            duplicateClosingChangedText: finalText != linkedText,
            signatureChangedText: deliveryText != finalText
        )

        // Determine if delivered text differs from the stored final text
        let deliveredText: String? = (deliveryText != finalText) ? deliveryText : nil
        // Raw transcript only stored when it differs from the stored final text
        let rawTranscript: String? = (result.rawTranscript != finalText) ? result.rawTranscript : nil
        let includeContextMetadata = settingsManager.contextMetadataEnabled
        let capturedContext = LocalContextPersistencePolicy.dictationContext(
            from: result,
            includeMetadata: includeContextMetadata
        )

        notchCoordinator.setTargetContext(
            bundleId: result.targetBundleId ?? targetApplication?.bundleIdentifier,
            windowTitle: result.windowTitle,
            browserURL: result.browserURL
        )

        let deliveryStage: String
        if shouldPaste {
            deliveryStage = shouldSend ? "Sending…" : "Pasting…"
        } else if shouldCopy {
            deliveryStage = "Copying…"
        } else {
            deliveryStage = "Finishing…"
        }

        if keepWorkflowVisible {
            notchCoordinator.setState(.processing(progress: 0.8, stage: deliveryStage))
        }
        activeLatencyLogger?.mark("pasteStart")
        let deliveryOutcome = await pasteManager.deliverWithOutcome(
            text: deliveryText,
            copyToClipboard: shouldCopy,
            autoPaste: shouldPaste,
            autoSend: shouldSend,
            captureReceipt: shouldPaste && !shouldSend,
            targetApplication: targetApplication,
            windowTitle: result.windowTitle,
            browserURL: result.browserURL,
            selectedRange: isSelectionTransform ? result.selectedRange : nil,
            deliveryMode: settingsManager.pasteDeliveryMode
        )
        activeLatencyLogger?.mark("pasteEnd")
        let physicalDeliverySucceeded = shouldSend
            ? deliveryOutcome.sent
            : deliveryOutcome.delivered
        let deliveryLatencyEvent = activeLatencyLogger?.finish(
            outcome: physicalDeliverySucceeded ? "success" : "failure"
        )
        let qualityTrace = dictationQualityTrace(
            dictationID: dictationID ?? activeDictationID,
            mode: mode,
            result: result,
            targetApplication: targetApplication,
            shouldPaste: shouldPaste,
            shouldCopy: shouldCopy,
            shouldSend: shouldSend,
            resolution: resolvedResolution,
            latencyEvent: deliveryLatencyEvent
        )
        let appliedStylePolicy = StyleDeliveryProvenanceResolver.appliedPolicyAtDelivery(
            provenance: result.styleApplicationProvenance,
            localPostProcessedText: result.text,
            resolvedText: resolvedText,
            requestedDeliveryText: deliveryText,
            stageTrace: styleDeliveryStageTrace,
            deliveryOutcome: deliveryOutcome
        )
        let contextPersonalizationExposure = result.contextPacket?.personalizationExposure?
            .recordingConsumers(
                localRepair: result.contextEntityRepairProvenance,
                cloudSubmission: resolvedResolution.cleanup.contextPersonalizationCloudSubmission
            )
        _ = await deliveryPersonalizationRouter.route(DeliveryPersonalizationRequest(
            deliveryOutcome: deliveryOutcome,
            autoPasteRequested: shouldPaste,
            autoSendRequested: shouldSend,
            copiedToClipboard: shouldCopy && deliveryOutcome.delivered,
            selectionTransformUsed: isSelectionTransform,
            targetApplication: targetApplication,
            surface: result.contextPacket?.surface ?? SurfaceClassifier.classify(
                appName: result.targetApp ?? targetApplication?.localizedName,
                bundleId: result.targetBundleId ?? targetApplication?.bundleIdentifier,
                windowTitle: result.windowTitle,
                browserURL: result.browserURL,
                focusedFieldContent: result.focusedFieldContent
            ),
            windowTitle: result.windowTitle,
            browserURL: result.browserURL,
            rawTranscript: result.rawTranscript,
            contextPacket: result.contextPacket,
            personalizationExposure: contextPersonalizationExposure,
            qualityTrace: qualityTrace,
            boostAudit: result.vocabularyBoostAudit,
            confidence: qualityTrace.confidence,
            appliedStylePolicy: appliedStylePolicy
        ))
        let textWasDelivered = deliveryOutcome.delivered
        let textWasSent = deliveryOutcome.sent
        let delivered = shouldSend ? textWasSent : textWasDelivered
        let actualAutoPasted = shouldPaste && textWasDelivered
        let actualAutoSent = shouldSend && textWasSent
        let actualCopiedToClipboard = shouldCopy && textWasDelivered
        let entry = DictationEntry.make(
            id: UUID(),
            text: finalText,
            context: capturedContext,
            wordCount: wordCount,
            duration: result.duration,
            mode: mode,
            date: Date(),
            rawTranscript: rawTranscript,
            deliveredText: deliveredText,
            autoPasted: actualAutoPasted,
            copiedToClipboard: actualCopiedToClipboard,
            autoSent: actualAutoSent,
            vocabularyBoostAuditSummary: result.vocabularyBoostAudit.map {
                VocabularyBoostAuditSummary(audit: $0)
            }
        )
        guard resultIsStillCurrent() else {
            if textWasDelivered || deliveryOutcome.partiallyDelivered {
                if deliveryOutcome.partiallyDelivered {
                    let copiedRecovery = fallbackCopyAfterFailedDelivery(text: deliveryText)
                    entry.copiedToClipboard = copiedRecovery
                    analyticsManager.capture("dictation_partial_delivery_committed_after_cancel", properties: [
                        "copied_recovery": copiedRecovery,
                        "mode": mode.rawValue,
                        "word_count": wordCount
                    ])
                } else {
                    analyticsManager.capture("dictation_delivery_committed_after_cancel", properties: [
                        "auto_pasted": actualAutoPasted,
                        "auto_sent": actualAutoSent,
                        "mode": mode.rawValue,
                        "word_count": wordCount
                    ])
                }
                // Delivery is irreversible. Durably hand off history/audio
                // before removing the recovery marker; cancellation owns this
                // outer finalizer until the handoff completes.
                guard await prepareOwnedActiveCaptureForPersistence(
                    id: captureRecoveryID,
                    entryID: entry.id,
                    entryDate: entry.date,
                    shouldPersistAudio: shouldPersistAudio
                ) else {
                    result.coldContextTask?.cancel()
                    return
                }
                let persistenceTask = Task { @MainActor in
                    await self.persistCompletedDictation(
                        entry: entry,
                        result: result,
                        resolvedText: resolvedText,
                        deliveredText: deliveredText,
                        autoPasted: entry.autoPasted == true,
                        autoSent: entry.autoSent == true,
                        copiedToClipboard: entry.copiedToClipboard == true,
                        includeContextMetadata: includeContextMetadata,
                        shouldPersistAudio: shouldPersistAudio
                    )
                }
                if await persistenceTask.value {
                    await clearOwnedActiveCapture(id: captureRecoveryID)
                }
            } else {
                await clearOwnedActiveCapture(id: captureRecoveryID)
                result.coldContextTask?.cancel()
                cleanupTemporaryRecording(at: result.recordingURL)
            }
            _ = activeLatencyLogger?.finish(outcome: "cancelled")
            activeLatencyLogger = nil
            return
        }
        // From here on the resolved delivery outcome owns persistence and
        // recovery cleanup. Escape must not tear down its recorder/file state
        // while terminal analytics and history are being committed.
        dictationFinalizationCommitted = true
        activeLatencyLogger = nil

        let progressEvents = statsTracker.record(wordCount: wordCount)
        streakTracker.recordDictation()
        let totalDictationsLifetime = statsTracker.totalDictations
        let isFirstDictation = totalDictationsLifetime == 1

        analyticsManager.capture("dictation_completed", properties: activeDictationAnalyticsProperties([
            "auto_paste_enabled": shouldPaste,
            "auto_send_enabled": shouldSend,
            "auto_pasted": actualAutoPasted,
            "auto_sent": actualAutoSent,
            "captured_duration_ms": result.captureDiagnostics?.durationMilliseconds as Any,
            "captured_sample_count": result.captureDiagnostics?.sampleCount as Any,
            "cloud_processing_enabled": settingsManager.cloudProcessingEnabled,
            "copy_to_clipboard_enabled": shouldCopy,
            "delivery_verification_downgraded": pasteManager.lastDeliveryVerificationDowngraded,
            "duration_ms": Int(result.duration * 1000),
            "duration_seconds": result.duration,
            "is_first_dictation": isFirstDictation,
            "mode": mode.rawValue,
            "model": settingsManager.selectedModelId,
            "paste_delivery_mode": settingsManager.pasteDeliveryMode.rawValue,
            "selection_transform_used": isSelectionTransform,
            "total_dictations_lifetime": totalDictationsLifetime,
            "word_count": wordCount
        ]))
        analyticsManager.incrementSessionDictationCount()
        if let audit = result.vocabularyBoostAudit {
            // One event per replacement decision, counts and scores only —
            // the terms themselves never leave the device.
            for decision in audit.decisions {
                analyticsManager.capture("vocabulary_boost_decision", properties: [
                    "outcome": decision.outcome.rawValue,
                    "guarded_term": decision.guarded,
                    "term_source": decision.source.rawValue,
                    "original_was_real_word": decision.originalWasRealWord,
                    "original_score": decision.originalScore,
                    "replacement_score": decision.replacementScore as Any,
                    "mode": mode.rawValue
                ])
            }
        }
        if isFirstDictation {
            analyticsManager.capture("first_dictation_completed", properties: activeDictationAnalyticsProperties([
                "captured_duration_ms": result.captureDiagnostics?.durationMilliseconds as Any,
                "captured_sample_count": result.captureDiagnostics?.sampleCount as Any,
                "duration_ms": Int(result.duration * 1000),
                "model": settingsManager.selectedModelId,
                "word_count": wordCount
            ]))
        }

        if delivered {
            let completionMessage: String
            if shouldPaste {
                completionMessage = shouldSend ? "Sent!" : "Pasted!"
            } else if shouldCopy {
                completionMessage = "Copied!"
            } else {
                completionMessage = "Done"
            }
            let cleanupFellBack = resolvedResolution.cleanup.status == .fallbackLocal
                && resolvedResolution.cleanup.attempted
            if keepWorkflowVisible {
                if cleanupFellBack, settingsManager.recoverableDictationIssueNoticesEnabled {
                    notchCoordinator.showNotice(
                        NotchOverlayState.Notice(
                            title: completionMessage,
                            detail: "Cloud cleanup unavailable — used local cleanup.",
                            icon: "icloud.slash"
                        ),
                        timeout: .seconds(5)
                    )
                } else {
                    notchCoordinator.showDone(completionMessage)
                }
            } else {
                notchCoordinator.setState(.idle)
            }
            if let event = progressEvents.first {
                notchCoordinator.triggerExpression(event)
            }
        } else {
            let copiedFallback = fallbackCopyAfterFailedDelivery(text: deliveryText)
            entry.copiedToClipboard = actualCopiedToClipboard || copiedFallback
            var properties: [String: Any] = [
                "auto_paste_enabled": shouldPaste,
                "copy_to_clipboard_enabled": shouldCopy,
                "mode": mode.rawValue,
                "copied_fallback": copiedFallback,
                "delivery_outcome": copiedFallback ? "copied_fallback" : "undelivered",
                "failure_severity": copiedFallback ? "recoverable" : "blocking",
                "paste_delivery_mode": settingsManager.pasteDeliveryMode.rawValue,
                "target_bundle_id": result.targetBundleId as Any
            ]
            if let failureType = pasteFailureAnalyticsValue() {
                properties["failure_type"] = failureType
            }
            analyticsManager.capture(
                shouldSend && textWasDelivered && !textWasSent
                    ? "dictation_send_failed"
                    : (copiedFallback ? "dictation_delivery_recovered" : "dictation_delivery_failed"),
                properties: properties
            )
            if shouldSend && textWasDelivered && !textWasSent {
                playAudioCue(.warning)
                notchCoordinator.showError(
                    copiedFallback
                        ? "Text was pasted but not sent. A copy is on your clipboard."
                        : "Text was pasted but not sent.",
                    subtype: .generic
                )
            } else {
                handlePasteFailurePresentation(copiedFallback: copiedFallback)
            }
        }

        guard await prepareOwnedActiveCaptureForPersistence(
            id: captureRecoveryID,
            entryID: entry.id,
            entryDate: entry.date,
            shouldPersistAudio: shouldPersistAudio
        ) else {
            result.coldContextTask?.cancel()
            return
        }
        let persistenceTask = Task { @MainActor in
            await self.persistCompletedDictation(
                entry: entry,
                result: result,
                resolvedText: resolvedText,
                deliveredText: deliveredText,
                autoPasted: entry.autoPasted == true,
                autoSent: entry.autoSent == true,
                copiedToClipboard: entry.copiedToClipboard == true,
                includeContextMetadata: includeContextMetadata,
                shouldPersistAudio: shouldPersistAudio
            )
        }
        if await persistenceTask.value {
            await clearOwnedActiveCapture(id: captureRecoveryID)
        }
    }

    private func dictationQualityTrace(
        dictationID: String?,
        mode: DictationMode,
        result: TranscriptionResult,
        targetApplication: NSRunningApplication?,
        shouldPaste: Bool,
        shouldCopy: Bool,
        shouldSend: Bool,
        resolution: DeliveredTextResolution,
        latencyEvent: PerformanceExperiments.DictationLatencyEvent?
    ) -> DictationQualityTrace {
        let targetBundleId = result.targetBundleId ?? targetApplication?.bundleIdentifier
        let surfaceKind = result.contextPacket?.surface.kind.rawValue
            ?? SurfaceClassifier.classify(
                appName: result.targetApp ?? targetApplication?.localizedName,
                bundleId: targetBundleId,
                windowTitle: result.windowTitle,
                browserURL: result.browserURL
            ).kind.rawValue
        let confidence = DictationConfidenceEngine.evaluate(DictationConfidenceEngine.Input(
            captureDiagnostics: result.captureDiagnostics,
            recognitionDiagnostics: result.recognitionDiagnostics,
            segmentRecoveryTrace: result.segmentRecoveryTrace,
            rawTranscript: result.rawTranscript,
            postProcessingTrace: result.postProcessingTrace,
            contextPacket: result.contextPacket,
            cleanup: resolution.cleanup,
            transform: resolution.transform,
            selectionTransformUsed: resolution.selectionTransformUsed,
            targetBundleId: targetBundleId,
            windowTitle: result.windowTitle,
            browserURL: result.browserURL,
            pasteDeliveryMode: settingsManager.pasteDeliveryMode,
            shouldPaste: shouldPaste,
            shouldCopy: shouldCopy,
            shouldSend: shouldSend
        ))

        return DictationQualityTrace(
            dictationID: dictationID,
            mode: mode.rawValue,
            model: settingsManager.selectedModelId,
            targetBundleId: targetBundleId,
            surfaceKind: surfaceKind,
            pasteDeliveryMode: settingsManager.pasteDeliveryMode.rawValue,
            autoPaste: shouldPaste,
            autoSend: shouldSend,
            copyToClipboard: shouldCopy,
            cloudProcessingEnabled: settingsManager.cloudProcessingEnabled,
            lowLatencyMode: settingsManager.lowLatencyMode,
            selectionTransformUsed: resolution.selectionTransformUsed,
            cleanup: resolution.cleanup,
            transform: resolution.transform,
            confidence: confidence,
            boostCounts: result.vocabularyBoostAudit?.counts ?? .zero,
            latencies: DictationQualityTrace.Latencies(event: latencyEvent)
        )
    }

    // MARK: - Incoming URLs

    func handleIncomingURL(_ url: URL) async {
        analyticsManager.captureMarketingAttribution(from: url, source: "incoming_url")

        if AppFeatureVisibility.hostedServices, AuthManager.isAuthCompletionHandoffURL(url) {
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        if AppFeatureVisibility.hostedServices, url.host == AuthManager.callbackHost {
            let didAuthenticate = await authManager.handleCallback(url: url)
            if didAuthenticate {
                await completeSignIn(source: "url_scheme")
            }
            return
        }

        if isOnboardingDeepLink(url) {
            NSApp.activate(ignoringOtherApps: true)
            if isVoiceProfileDeepLink(url) {
                // Voice ID moved out of onboarding — it lives in meeting settings.
                showPrimaryWindow(selectedTab: .meetings)
            } else {
                reopenOnboarding()
            }
            analyticsManager.capture(
                OnboardingAnalytics.Event.deepLinkOpened.rawValue,
                properties: OnboardingAnalytics.properties(
                    context: .preSession(),
                    additional: ["entry_point": "deep_link"]
                )
            )
            return
        }

        return
    }

    private func isOnboardingDeepLink(_ url: URL) -> Bool {
        let host = url.host?.lowercased()
        let path = url.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        return host == "onboarding" || path == "onboarding"
    }

    private func isVoiceProfileDeepLink(_ url: URL) -> Bool {
        let pathComponents = url.pathComponents
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased() }
            .filter { !$0.isEmpty }
        let routeParts = ([url.host?.lowercased()].compactMap { $0 } + pathComponents)
        return routeParts.contains("voice-profile")
            || routeParts.contains("voice-id")
            || routeParts.contains("voice")
    }

    func signOut(source: String = "settings") async {
        analyticsManager.capture("auth_signed_out", properties: ["source": source])
        pendingLoginSource = "settings"
        authWindowController.dismiss()
        authManager.logout()
        analyticsManager.resetIdentity()
        syncSentryRuntimeConfiguration()
        reconcileMeetingWebhookDestination()
    }

    func clearWorkspace() async {
        guard !isClearingWorkspace else { return }
        isClearingWorkspace = true
        retireInFlightAudioStartsForTerminalLifecycle(reason: "workspace_clear")
        audioWarmUpRecoveryCoordinator.cancelPendingActivation()
        audioRecorder.teardownWarmSession()
        setLowLatencyWarmActivity(false)
        analyticsManager.capture("workspace_cleared")
        let shouldRestartHotMic = settingsManager.hotMicEnabled

        // Stop every producer before establishing the file/DB clear boundary.
        // Each API below joins work that was admitted before it suspended new
        // writes, so nothing can repopulate a successfully cleared store.
        await ambientContextCollector.stopAndWait(finalizePendingSnapshot: false)
        await quiesceCaptureForWorkspaceClear()
        await hotMicManager.stopAndWait()
        if let meetingRecorderManager {
            await meetingRecorderManager.prepareForWorkspaceClear()
            await meetingNoteAutosaver.stopAndWait(for: meetingRecorderManager.notepad)
        }
        await cancelAllMeetingSummaryTasksAndWait()
        correctionFlushTask?.cancel()
        await correctionFlushTask?.value
        correctionFlushTask = nil
        await personalizationOutcomeSetupCoordinator.quiesceForWorkspaceClear()
        await deliveryPersonalizationRouter.quiesceForWorkspaceClear()
        await journalGenerationDebouncer.cancelAllAndWait()
        await memoDistillationDebouncer.cancelAllAndWait()
        await memoTitleDebouncer.cancelAllAndWait()
        await dictionaryStore.quiesceForWorkspaceClear()
        await personalizationMemoryStore.quiesceForWorkspaceClear()
        await activityStreamWriter.quiesceForWorkspaceClear()
        await meetingWebhookSender.clearPersistedPayloads()

        guard await workspaceSyncEngine.prepareForWorkspaceClear() else {
            await resumeRuntimeAfterWorkspaceClear(
                shouldRestartHotMic: shouldRestartHotMic,
                abortWorkspaceBoundary: true,
                rebuildAmbientMirror: true
            )
            notchCoordinator.showError(
                "Workspace could not be cleared because an import mirror could not be removed.",
                subtype: .generic
            )
            return
        }

        guard let recoverySnapshot = await recoveryStore.snapshotActiveCaptureMarker() else {
            await resumeRuntimeAfterWorkspaceClear(
                shouldRestartHotMic: shouldRestartHotMic,
                abortWorkspaceBoundary: true,
                rebuildAmbientMirror: true
            )
            notchCoordinator.showError(
                "Workspace could not be cleared because recovery metadata could not be secured.",
                subtype: .generic
            )
            return
        }

        guard await prepareCaptureRecoveryForWorkspaceClear() else {
            _ = await recoveryStore.restoreActiveCaptureMarker(recoverySnapshot)
            await refreshActiveCaptureRecoveryReservation()
            await resumeRuntimeAfterWorkspaceClear(
                shouldRestartHotMic: shouldRestartHotMic,
                abortWorkspaceBoundary: true,
                rebuildAmbientMirror: true
            )
            notchCoordinator.showError(
                "Workspace could not be cleared because recovery cleanup could not be prepared.",
                subtype: .generic
            )
            return
        }

        guard await dataStore.clearWorkspaceData() else {
            let markerRestored = await recoveryStore.restoreActiveCaptureMarker(recoverySnapshot)
            await refreshActiveCaptureRecoveryReservation()
            await resumeRuntimeAfterWorkspaceClear(
                shouldRestartHotMic: shouldRestartHotMic,
                abortWorkspaceBoundary: true,
                rebuildAmbientMirror: true
            )
            notchCoordinator.showError(
                markerRestored
                    ? "Workspace could not be cleared. Your existing data was kept."
                    : "Workspace could not be cleared, and recovery metadata needs attention.",
                subtype: .generic
            )
            return
        }
        await deliveryPersonalizationRouter.completeWorkspaceClear()

        let recoveryFilesCleared = await recoveryStore.purgeOrphanedCaptureFiles(
            keepingAudioPath: nil
        )
        var recoveryMarkerCleared = false
        if recoveryFilesCleared {
            recoveryMarkerCleared = await recoveryStore.clearActiveCapture()
        }
        retryableDictationCapture = nil
        await refreshActiveCaptureRecoveryReservation()

        await personalizationMemoryStore.clearPersonalizationMemory()
        dictionaryStore.clearWorkspaceData()
        await memoManager.clearWorkspaceData()
        feedManager.clearWorkspaceData()
        journalManager.clearWorkspaceData()
        await archiveWriter.clearWorkspaceData()
        await activityStreamWriter.clearWorkspaceData()
        statsTracker.clearWorkspaceData()
        streakTracker.clearWorkspaceData()
        try? MeetingVoiceProfileStore().deleteEnrollment()

        selectedMemoID = nil
        selectedFeedItemID = nil
        selectedJournalReviewDate = nil

        await workspaceSyncEngine.finishWorkspaceClear()
        await resumeRuntimeAfterWorkspaceClear(
            shouldRestartHotMic: shouldRestartHotMic,
            abortWorkspaceBoundary: false,
            rebuildAmbientMirror: false
        )

        if recoveryFilesCleared, recoveryMarkerCleared {
            notchCoordinator.showDone("Workspace cleared")
        } else {
            notchCoordinator.showError(
                "Workspace data was cleared, but one recording could not be removed. Resonant will retry on restart.",
                subtype: .generic
            )
        }
    }

    private func resumeRuntimeAfterWorkspaceClear(
        shouldRestartHotMic: Bool,
        abortWorkspaceBoundary: Bool,
        rebuildAmbientMirror: Bool
    ) async {
        activityStreamWriter.resumeAfterWorkspaceClear()
        dictionaryStore.resumeAfterWorkspaceClear()
        personalizationMemoryStore.resumeAfterWorkspaceClear()
        await deliveryPersonalizationRouter.resumeAfterWorkspaceClear()
        personalizationOutcomeSetupCoordinator.resumeAfterWorkspaceClear()

        if abortWorkspaceBoundary {
            await workspaceSyncEngine.abortWorkspaceClear()
        }
        if rebuildAmbientMirror {
            let ambientSnapshots = await dataStore.fetchInBackground(FetchDescriptor<AmbientContextSnapshot>(
                sortBy: [SortDescriptor(\.timestamp)]
            ))
            await activityStreamWriter.bootstrapAmbientFiles(from: ambientSnapshots)
        }
        meetingRecorderManager?.finishWorkspaceClear()
        isClearingWorkspace = false

        // Sleep/wake owns restoration while asleep, and shutdown is terminal.
        // Internal stores still leave their clear boundary above, but no audio
        // or background producer is resurrected here in either state.
        guard allowsRuntimeServiceRestoration else { return }

        await workspaceSyncEngine.start()
        guard allowsRuntimeServiceRestoration else { return }
        rewarmIfLowLatency()
        syncAmbientContextState()
        syncMeetingDetectionState()
        if shouldRestartHotMic, settingsManager.hotMicEnabled {
            await startHotMic()
        }
    }

    private func quiesceCaptureForWorkspaceClear() async {
        if isRecording || isStartingRecording || isFinishingCapture {
            await cancelRecording(reason: "workspace_clear", shouldTrackCancellation: false)
        }

        if let retirement = activeCaptureFinalizationRetirement {
            await retirement.wait()
        }
        if let result = activeCaptureResultTask {
            await result.task.value
            if activeCaptureResultTask?.id == result.id {
                activeCaptureResultTask = nil
            }
        }
        if let quiescenceTask = captureCancellationQuiescenceTask {
            await quiescenceTask.value
        }
    }

    private func prepareCaptureRecoveryForWorkspaceClear() async -> Bool {
        switch await recoveryStore.loadActiveCaptureResult() {
        case .missing:
            return true
        case .loaded(let recovery):
            return await recoveryStore.markActiveCaptureForDiscard(id: recovery.id)
        case .unreadable:
            // An unreadable marker cannot safely be rewritten. Removing only
            // the marker before the DB clear makes any surviving CAF an orphan
            // that launch cleanup deletes; it can never be interpreted as a
            // persist transaction and resurrect cleared history.
            return await recoveryStore.clearActiveCapture()
        }
    }

    private func refreshActiveCaptureRecoveryReservation() async {
        switch await recoveryStore.loadActiveCaptureResult() {
        case .missing:
            activeCaptureRecoveryID = nil
            activeCaptureShouldPersistAudio = nil
            hasUnreadableActiveCaptureRecovery = false
        case .loaded(let recovery):
            activeCaptureRecoveryID = recovery.id
            activeCaptureShouldPersistAudio = recovery.shouldPersistAudio
            hasUnreadableActiveCaptureRecovery = false
        case .unreadable:
            activeCaptureRecoveryID = nil
            activeCaptureShouldPersistAudio = nil
            hasUnreadableActiveCaptureRecovery = true
        }
    }

    func uploadWorkspaceToCloud(enableBackgroundSync: Bool = true) async {
        guard AppFeatureVisibility.cloudSync else {
            settingsManager.workspaceCloudUploadEnabled = false
            workspaceCloudUploadState = .idle(lastSyncedAt: Defaults[.workspaceCloudTextLastSyncedAt])
            return
        }
        guard authManager.isLoggedIn else {
            workspaceCloudUploadState = .failed("Sign in to sync your workspace to the cloud.")
            return
        }
        await workspaceSyncEngine.uploadWorkspaceTextToCloud(enableBackgroundSync: enableBackgroundSync)
    }

    func deleteWorkspaceCloudData() async {
        let wasCloudUploadEnabled = settingsManager.workspaceCloudUploadEnabled
        settingsManager.workspaceCloudUploadEnabled = false
        workspaceCloudUploadState = .deleting
        let result = await convexClient.deleteWorkspaceCloudData()
        switch result {
        case .success(let deleted):
            Defaults[.workspaceCloudTextLastSyncedAt] = nil
            workspaceCloudUploadState = .deleted(
                deletedCount: deleted.dictations + deleted.memos + deleted.meetings,
                deletedAt: Date()
            )
        case .failure(let error):
            settingsManager.workspaceCloudUploadEnabled = wasCloudUploadEnabled
            workspaceCloudUploadState = .failed(error.localizedDescription)
        }
    }

    // MARK: - Audio level

    private func handleAudioLevel(_ level: Float) {
        guard isRecording || isStartingRecording else { return }
        updateRecordingAudioFeedback(level: level)

        if case .recording(let mode, _, _) = notchCoordinator.state {
            notchCoordinator.setState(.recording(mode: mode, level: level, elapsed: recordingElapsed))
        }
    }

    private func handleDeadCaptureRestart(recovered: Bool, mode: DictationMode) {
        analyticsManager.capture("dictation_capture_restarted", properties: activeDictationAnalyticsProperties([
            "recovered": recovered,
            "mode": mode == .memo ? "memo" : "dictation"
        ]))
        guard recovered, isRecording || isStartingRecording else { return }
        notchCoordinator.recordingHint = "Mic gave no audio — restarted. First words may be missing."
    }

    private func resetRecordingAudioFeedback() {
        lowAudioWarningTask?.cancel()
        lowAudioWarningTask = nil
        hasDetectedRecordingAudio = false
        recordingLevelWindow.reset()
        recordingHintIsNoiseBed = false
        notchCoordinator.recordingHint = nil
    }

    private func clearRecordingAudioFeedback() {
        lowAudioWarningTask?.cancel()
        lowAudioWarningTask = nil
        notchCoordinator.recordingHint = nil
    }

    private func scheduleLowAudioWarning(mode: DictationMode) {
        lowAudioWarningTask?.cancel()
        lowAudioWarningTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1800))
            await MainActor.run { [weak self] in
                guard let self,
                      self.isRecording || self.isStartingRecording
                else { return }

                if !self.hasDetectedRecordingAudio {
                    self.notchCoordinator.recordingHint = self.lowAudioHint(for: mode)
                } else if self.recordingLevelWindow.indicatesSteadyLoudBed {
                    // A loud steady bed (machinery/AC) trips the absolute
                    // audio-detected bar immediately, so the low-audio hint
                    // never fires there — but no speech dynamics yet means the
                    // user's voice hasn't risen above the room.
                    self.recordingHintIsNoiseBed = true
                    self.notchCoordinator.recordingHint = self.noiseBedHint()
                }
            }
        }
    }

    private func updateRecordingAudioFeedback(level: Float) {
        recordingLevelWindow.append(level)
        if recordingHintIsNoiseBed {
            // The bed itself keeps the level above any absolute bar; only
            // speech-like dynamics over the bed clear the noise hint.
            if recordingLevelWindow.indicatesSpeechDynamics {
                recordingHintIsNoiseBed = false
                notchCoordinator.recordingHint = nil
            }
        } else if level >= 0.035 {
            hasDetectedRecordingAudio = true
            if notchCoordinator.recordingHint != nil {
                notchCoordinator.recordingHint = nil
            }
        }
    }

    private func noiseBedHint() -> String {
        let micLabel = activeMicrophoneName() ?? "the mic"
        return "Loud background noise. Speak up or move closer to \(micLabel)."
    }

    private func lowAudioHint(for mode: DictationMode) -> String {
        let prefix = mode == .memo ? "No voice in memo yet" : "No voice yet"
        if let microphoneName = activeMicrophoneName() {
            return "\(prefix). Check \(microphoneName)."
        }
        return "\(prefix). Check microphone."
    }

    private enum AudioCue {
        case start
        case stop
        case lock
        case success
        case warning
        case error
        case agentStart
        case agentSuccess
        case agentFailure
    }

    private func playAudioCue(_ cue: AudioCue) {
        audioCuePlayer.enabled = settingsManager.soundsEnabled
        audioCuePlayer.volume = Float(settingsManager.soundsVolume)

        switch cue {
        case .start:
            audioCuePlayer.playStart()
        case .stop:
            audioCuePlayer.playStop()
        case .lock:
            audioCuePlayer.playLock()
        case .success:
            audioCuePlayer.playSuccess()
        case .warning:
            audioCuePlayer.playWarning()
        case .error:
            audioCuePlayer.playError()
        case .agentStart:
            audioCuePlayer.playAgentStart()
        case .agentSuccess:
            audioCuePlayer.playAgentSuccess()
        case .agentFailure:
            audioCuePlayer.playAgentFailure()
        }
    }

    private func activeTargetApplication() -> NSRunningApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        return app
    }

    private func startRecordingWithFallback(startAttemptID: UUID) async throws {
        refreshAudioInputStatus()

        let preferredInputDeviceUID = settingsManager.inputDeviceUID
        let preferredInputDevice = audioInputDeviceManager.device(with: preferredInputDeviceUID)
        let preservedRoutingMessage = inputRoutingUsesFallback ? inputRoutingMessage : nil
        let preservedUsesFallback = inputRoutingUsesFallback
        let preservedUnavailableName = inputRoutingUsesFallback ? fallbackUnavailableDeviceName : nil
        let recordingURL = try audioRecorder.reserveRecoveryCaptureURL()
        let recordingRetention: DictationRecordingRetentionPolicy = currentMode == .command
            ? .ephemeral
            : .recoverable
        let retrySupersession: RetryableCaptureSupersession?
        do {
            retrySupersession = try await beginRetryableCaptureSupersessionIfNeeded()
        } catch {
            cleanupTemporaryRecording(at: recordingURL)
            throw error
        }

        do {
            try await requireActiveCaptureRecoveryMarker(audioURL: recordingURL)
            try await requireCurrentRecordingStartAttempt(
                startAttemptID,
                recordingURL: recordingURL
            )

            do {
                _ = try await dictationManager.startRecording(
                    selectedInputDeviceUID: preferredInputDeviceUID,
                    outputURL: recordingURL,
                    recordingRetention: recordingRetention
                )
                try await requireCurrentRecordingStartAttempt(
                    startAttemptID,
                    recordingURL: recordingURL,
                    cancelStartedCapture: true
                )
                recordActiveInput(
                    deviceName: preferredInputDevice?.name ?? audioInputDeviceManager.effectiveDevice(for: preferredInputDeviceUID)?.name,
                    routingMessage: preservedRoutingMessage,
                    usesFallback: preservedUsesFallback,
                    unavailableDeviceName: preservedUnavailableName
                )
            } catch let error as AudioRecorderError
                where preferredInputDeviceUID != nil && shouldFallbackToSystemDefault(after: error) {
                try await requireCurrentRecordingStartAttempt(
                    startAttemptID,
                    recordingURL: recordingURL
                )
                _ = try await dictationManager.startRecording(
                    selectedInputDeviceUID: nil,
                    outputURL: recordingURL,
                    recordingRetention: recordingRetention
                )
                try await requireCurrentRecordingStartAttempt(
                    startAttemptID,
                    recordingURL: recordingURL,
                    cancelStartedCapture: true
                )
                let fallbackDeviceName = audioInputDeviceManager.effectiveDevice(for: nil)?.name
                let selectedDeviceName = preferredInputDevice?.name ?? "Selected microphone"
                recordActiveInput(
                    deviceName: fallbackDeviceName,
                    routingMessage: microphoneFallbackRoutingMessage(
                        unavailableDeviceName: selectedDeviceName,
                        fallbackDeviceName: fallbackDeviceName
                    ),
                    usesFallback: true,
                    unavailableDeviceName: preferredInputDevice?.name
                )
            }
            commitRetryableCaptureSupersession(retrySupersession)
        } catch {
            let recoveryID = activeCaptureRecoveryID
            await clearOwnedActiveCapture(id: recoveryID)
            cleanupTemporaryRecording(at: recordingURL)
            await rollbackRetryableCaptureSupersession(retrySupersession)
            throw error
        }
    }

    /// Temporarily removes the failed capture's marker without touching its
    /// audio. The new recorder may then claim the single active marker. The
    /// old marker is restored byte-for-byte if microphone startup fails.
    private func beginRetryableCaptureSupersessionIfNeeded() async throws -> RetryableCaptureSupersession? {
        guard let capture = retryableDictationCapture else { return nil }
        guard FileManager.default.fileExists(atPath: capture.url.path) else {
            retryableDictationCapture = nil
            return nil
        }

        guard let recoveryID = capture.captureRecoveryID else {
            return RetryableCaptureSupersession(capture: capture, markerSnapshot: nil)
        }
        guard case .loaded(let marker) = await recoveryStore.loadActiveCaptureResult(),
              marker.id == recoveryID,
              let snapshot = await recoveryStore.snapshotActiveCaptureMarker(),
              await recoveryStore.clearActiveCapture(id: recoveryID) else {
            throw RetryableCaptureSupersessionError()
        }

        if activeCaptureRecoveryID == recoveryID {
            activeCaptureRecoveryID = nil
            activeCaptureShouldPersistAudio = nil
        }
        return RetryableCaptureSupersession(capture: capture, markerSnapshot: snapshot)
    }

    private func commitRetryableCaptureSupersession(_ supersession: RetryableCaptureSupersession?) {
        guard let supersession else { return }
        if !cleanupTemporaryRecording(at: supersession.capture.url) {
            Self.log.error("Superseded retry recording could not be removed; launch cleanup will retry")
        }
        if retryableDictationCapture?.url.standardizedFileURL
            == supersession.capture.url.standardizedFileURL {
            retryableDictationCapture = nil
        }
    }

    private func rollbackRetryableCaptureSupersession(_ supersession: RetryableCaptureSupersession?) async {
        guard let supersession, let snapshot = supersession.markerSnapshot else { return }
        let restored = await recoveryStore.restoreActiveCaptureMarker(snapshot)
        guard restored else {
            Self.log.error("Could not restore superseded retry recovery marker")
            hasUnreadableActiveCaptureRecovery = true
            return
        }
        activeCaptureRecoveryID = supersession.capture.captureRecoveryID
        activeCaptureShouldPersistAudio = supersession.capture.shouldPersistAudio
        hasUnreadableActiveCaptureRecovery = false
    }

    private func requireCurrentRecordingStartAttempt(
        _ startAttemptID: UUID,
        recordingURL: URL,
        cancelStartedCapture: Bool = false
    ) async throws {
        guard isStartingRecording,
              canContinueAudioStart(
                  ownsStartAttempt: recordingStartOwnership.owns(startAttemptID)
              ) else {
            if cancelStartedCapture,
               let pendingRetirement = await dictationManager.cancel() {
                await pendingRetirement.value
            }
            let recoveryID = activeCaptureRecoveryID
            await clearOwnedActiveCapture(id: recoveryID)
            cleanupTemporaryRecording(at: recordingURL)
            throw CancellationError()
        }
    }

    private func shouldFallbackToSystemDefault(after error: AudioRecorderError) -> Bool {
        switch error {
        case .startFailed, .noInputDevice:
            return true
        case .microphonePermissionDenied, .finishFailed:
            return false
        }
    }

    private struct ActiveCaptureRecoveryMarkerError: LocalizedError {
        var errorDescription: String? {
            "Could not secure the recording for recovery"
        }
    }

    private func requireActiveCaptureRecoveryMarker(audioURL: URL) async throws {
        guard await saveActiveCaptureRecoveryMarker(audioURL: audioURL) else {
            if let pendingRetirement = await dictationManager.cancel() {
                await pendingRetirement.value
            }
            throw ActiveCaptureRecoveryMarkerError()
        }
    }

    @discardableResult
    private func saveActiveCaptureRecoveryMarker(audioURL: URL) async -> Bool {
        let shouldPersistAudio = settingsManager.saveAudioEnabled
        activeCaptureShouldPersistAudio = shouldPersistAudio
        // Command mode recordings are short-lived voice commands — skip recovery.
        guard currentMode != .command else { return true }
        let kind: ActiveCaptureRecovery.Kind = currentMode == .memo ? .memo : .dictation
        let id = UUID()
        let recovery = ActiveCaptureRecovery(
            id: id,
            kind: kind,
            startedAt: recordingStartedAt ?? Date(),
            audioPath: audioURL.path,
            targetAppName: recordingTargetApplication?.localizedName,
            targetBundleId: recordingTargetApplication?.bundleIdentifier,
            windowTitle: notchCoordinator.targetWindowTitle,
            browserURL: notchCoordinator.targetBrowserURL,
            shouldPersistAudio: shouldPersistAudio
        )
        // Publish ownership before the actor hop so Escape can see and clear
        // this generation while the atomic write is in flight.
        activeCaptureRecoveryID = id
        let saved = await recoveryStore.saveActiveCapture(recovery)
        guard activeCaptureRecoveryID == id else {
            // Cancellation retired this generation while the write was
            // pending. Reconcile after actor serialization so a late successful
            // write cannot resurrect a stale marker.
            await recoveryStore.clearActiveCapture(id: id)
            return false
        }
        if saved {
            return true
        } else {
            activeCaptureRecoveryID = nil
            Self.log.error("Could not write active-capture recovery marker")
            return false
        }
    }

    /// Clear the recovery marker only if it still belongs to the capture this
    /// AppState wrote; never wipe a marker written by a later capture.
    private func prepareOwnedActiveCaptureForPersistence(
        id: UUID?,
        entryID: UUID,
        entryDate: Date,
        shouldPersistAudio: Bool
    ) async -> Bool {
        guard let id else { return true }
        let prepared = await recoveryStore.prepareActiveCaptureForPersistence(
            id: id,
            entryID: entryID,
            entryDate: entryDate,
            shouldPersistAudio: shouldPersistAudio
        )
        guard !prepared else { return true }

        Self.log.error("Could not prepare active-capture recovery transaction")
        notchCoordinator.showNotice(
            NotchOverlayState.Notice(
                title: "Save still pending",
                detail: "Your recording is safe. Restart Resonant to finish recovering it.",
                icon: "exclamationmark.arrow.triangle.2.circlepath"
            ),
            timeout: .seconds(7)
        )
        return false
    }

    private func clearOwnedActiveCapture(id: UUID?) async {
        guard let id else { return }
        switch await recoveryStore.loadActiveCaptureResult() {
        case .missing:
            break
        case .loaded(let recovery) where recovery.id == id:
            guard cleanupTemporaryRecording(at: recovery.audioURL) else {
                Self.log.error("Recovery source deletion failed; retaining marker")
                return
            }
        case .loaded, .unreadable:
            return
        }
        let cleared = await recoveryStore.clearActiveCapture(id: id)
        if cleared, activeCaptureRecoveryID == id {
            activeCaptureRecoveryID = nil
            activeCaptureShouldPersistAudio = nil
        }
    }

    private func rejectNewCaptureForPendingRecovery() -> Bool {
        if let retryableDictationCapture,
           retryableDictationCapture.captureRecoveryID == activeCaptureRecoveryID,
           FileManager.default.fileExists(atPath: retryableDictationCapture.url.path) {
            return false
        }
        guard activeCaptureRecoveryID != nil || hasUnreadableActiveCaptureRecovery else {
            return false
        }
        playAudioCue(.warning)
        notchCoordinator.showError(
            "A previous recording still needs to be saved. Restart Resonant to recover it.",
            subtype: .generic
        )
        return true
    }

    /// After a delivered dictation, warn when the mic dropped out mid-recording
    /// and part of the speech never reached the file: the paste "succeeded", but
    /// words are missing and nothing else would tell the user.
    private func presentCaptureDropoutNoticeIfNeeded() {
        let capturedSeconds: TimeInterval
        let wallSeconds: TimeInterval
        switch dictationManager.lastCaptureIntegrity {
        case .intact:
            return
        case .truncated(let captured, let wall), .starved(let captured, let wall):
            capturedSeconds = captured
            wallSeconds = wall
        }
        analyticsManager.capture("dictation_capture_truncated", properties: [
            "captured_ms": Int((capturedSeconds * 1000).rounded()),
            "wall_ms": Int((wallSeconds * 1000).rounded()),
            "model": settingsManager.selectedModelId
        ])
        // A failure strip (delivery or capture) is already telling the story —
        // don't replace it with the softer notice.
        if case .error = notchCoordinator.state { return }
        let micLabel = activeMicrophoneName() ?? "the microphone"
        notchCoordinator.showNotice(
            NotchOverlayState.Notice(
                title: "Microphone dropped out mid-recording",
                detail: "Only \(formattedSeconds(capturedSeconds)) of your \(formattedSeconds(wallSeconds)) recording arrived from \(micLabel) — some words may be missing. Check its connection or USB hub.",
                icon: "mic.slash.fill"
            ),
            timeout: .seconds(7)
        )
    }

    private func startFailureMessage(for error: Error) -> String {
        switch error {
        case AudioRecorderError.microphonePermissionDenied:
            return "Enable microphone access"
        case AudioRecorderError.startFailed:
            if let microphoneName = activeMicrophoneName() {
                return "Could not start \(microphoneName)"
            }
            return "Could not start microphone"
        case AudioRecorderError.noInputDevice:
            return "No microphone input found"
        default:
            return error.localizedDescription
        }
    }

    private func startFailureSubtype(for error: Error) -> NotchOverlayState.ErrorSubtype {
        switch error {
        case AudioRecorderError.microphonePermissionDenied,
             AudioRecorderError.startFailed,
             AudioRecorderError.noInputDevice:
            return .microphone
        default:
            return .generic
        }
    }

    private func transcriptionFailureMessage(for error: Error, mode: DictationMode) -> String {
        switch error {
        case DictationError.emptyTranscription:
            return noSpeechDetectedMessage()
        case DictationError.speechDetectedButNoText:
            return speechDetectedButNoTextMessage()
        case DictationError.noModelSelected, TranscriberError.notLoaded, TranscriberError.notDownloaded:
            return "Local model not ready"
        default:
            return mode == .memo ? "Memo failed" : "Transcription failed"
        }
    }

    private func transcriptionFailureSubtype(for error: Error) -> NotchOverlayState.ErrorSubtype {
        switch error {
        case DictationError.noModelSelected, TranscriberError.notLoaded, TranscriberError.notDownloaded:
            return .model
        default:
            return .transcription
        }
    }

    private func noSpeechDetectedMessage() -> String {
        let micName = activeMicrophoneName()
        let fallbackPrefix = inputFallbackPrefix()
        guard let diag = dictationManager.lastSilenceDiagnostics else {
            if let fallbackPrefix {
                return fallbackPrefix
            }
            if let micName {
                return "No speech recognized from \(micName)."
            }
            return "No speech recognized in the recording."
        }
        let peak = roundedFiniteInt(diag.peakDb)
        let micLabel = micName ?? "microphone"
        // A capture whose file covers a fraction of the wall clock is a device
        // dropout: every content heuristic below would run on the surviving
        // fragment (often a hot 2 ms start pop that reads as "clipping"), so
        // hardware guidance must win before any of them fire.
        if let dropout = captureDropoutGuidanceMessage(micLabel: micLabel) {
            return prefixed(fallbackPrefix, dropout)
        }
        if diag.peakDb.isFinite, diag.peakDb < -50 {
            let level = peak.map { " (peak \($0) dB)" } ?? ""
            return prefixed(fallbackPrefix, "\(micLabel) isn't picking up sound\(level). Check it's not muted, still connected, or that the right input is selected.")
        }
        // A loud/clipping capture must take priority over the segment-count branch:
        // continuous shouting collapses the energy gate to zero segments, which would
        // otherwise misroute it into "speak closer" — the exact opposite of the fix.
        if let clipping = clippingGuidanceMessage(diag, micLabel: micLabel, peak: peak) {
            return prefixed(fallbackPrefix, clipping)
        }
        // A genuinely loud, constant background (AC/fan) raises the noise floor and
        // buries normal speech: zero segments not because the user was quiet but
        // because their voice never clears the noise. Point at the environment.
        if let noise = backgroundNoiseGuidanceMessage(diag, micLabel: micLabel) {
            return prefixed(fallbackPrefix, noise)
        }
        if diag.speechSegmentCount == 0 {
            if let peak {
                return prefixed(fallbackPrefix, "Recorded audio at \(peak) dB from \(micLabel), but the recognizer didn't produce any text. Try speaking a bit more clearly, or check that the right input is selected.")
            }
            return prefixed(fallbackPrefix, "Recorded audio from \(micLabel), but the recognizer didn't produce any text. Try speaking a bit more clearly, or check that the right input is selected.")
        }
        if diag.voicedDurationSeconds < 0.45 {
            return prefixed(fallbackPrefix, "Speech too brief (\(String(format: "%.2f", diag.voicedDurationSeconds))s) from \(micLabel).")
        }
        if let fallbackPrefix {
            return fallbackPrefix
        }
        if let micName {
            return "No speech recognized from \(micName)."
        }
        return "No speech recognized in the recording."
    }

    private func speechDetectedButNoTextMessage() -> String {
        let micLabel = activeMicrophoneName() ?? "microphone"
        let fallbackPrefix = inputFallbackPrefix()
        guard let diag = dictationManager.lastSilenceDiagnostics else {
            return prefixed(fallbackPrefix, "Speech was detected from \(micLabel), but no text was produced.")
        }
        if let dropout = captureDropoutGuidanceMessage(micLabel: micLabel) {
            return prefixed(fallbackPrefix, dropout)
        }
        if let clipping = clippingGuidanceMessage(diag, micLabel: micLabel, peak: roundedFiniteInt(diag.peakDb)) {
            return prefixed(fallbackPrefix, clipping)
        }
        if let noise = backgroundNoiseGuidanceMessage(diag, micLabel: micLabel) {
            return prefixed(fallbackPrefix, noise)
        }
        let voiced = String(format: "%.1f", diag.voicedDurationSeconds)
        return prefixed(fallbackPrefix, "Speech was detected from \(micLabel) (\(voiced)s), but no text was produced.")
    }

    /// When the mic stopped delivering audio partway through (flaky USB hub,
    /// dead capture session), name the hardware problem. Returns nil for a
    /// capture that covers the recording, so callers fall through to their
    /// content-based copy.
    private func captureDropoutGuidanceMessage(micLabel: String) -> String? {
        switch dictationManager.lastCaptureIntegrity {
        case .intact:
            return nil
        case .starved(let capturedSeconds, let wallSeconds):
            let capturedMs = Int((capturedSeconds * 1000).rounded())
            return "\(micLabel) delivered almost no audio (\(capturedMs) ms of a \(formattedSeconds(wallSeconds)) recording). The mic or its USB hub may have dropped out — check the connection, or pick another microphone in Settings."
        case .truncated(let capturedSeconds, let wallSeconds):
            return "\(micLabel) delivered only \(formattedSeconds(capturedSeconds)) of a \(formattedSeconds(wallSeconds)) recording — the rest never arrived. Check the mic's connection or USB hub, then try again."
        }
    }

    private func formattedSeconds(_ seconds: TimeInterval) -> String {
        String(format: "%.1fs", seconds)
    }

    /// When the capture is loud enough to be clipping, return guidance to back off
    /// the mic / lower input — never "speak closer". Returns nil for normal levels so
    /// callers fall through to their level-appropriate copy.
    private func clippingGuidanceMessage(
        _ diagnostics: DictationAudioAnalyzer.Diagnostics,
        micLabel: String,
        peak: Int?
    ) -> String? {
        guard diagnostics.indicatesClipping,
              // A few hot milliseconds are a session-start transient, not the
              // user's voice — loudness advice on a stub misleads.
              diagnostics.audioDurationSeconds > DictationCaptureIntegrityPolicy.starvedCapturedSecondsCeiling
        else { return nil }
        let level = peak.map { " (peak \($0) dB)" } ?? ""
        return "\(micLabel) input is very loud and may be clipping\(level). Move the mic farther away or lower your input volume, then try again."
    }

    /// When a loud constant background (AC, fan, traffic) is burying the voice,
    /// return advice to reduce noise / get closer — never "speak up", which the
    /// user is already fighting against. Returns nil when the floor is quiet.
    private func backgroundNoiseGuidanceMessage(
        _ diagnostics: DictationAudioAnalyzer.Diagnostics,
        micLabel: String
    ) -> String? {
        guard diagnostics.warrantsBackgroundNoiseGuidance else { return nil }
        let floor = roundedFiniteInt(diagnostics.noiseFloorDb)
        let level = floor.map { " (noise floor \($0) dB)" } ?? ""
        return "\(micLabel) is picking up loud background noise\(level) that's burying your voice. Move away from the noise source (like an AC or fan), bring the mic closer, or use a headset mic, then try again."
    }

    /// Leads a failure message with the mic-fallback explanation when capture has
    /// dropped to the built-in mic, so the user understands why the error names a
    /// different microphone than the one they selected.
    private func prefixed(_ prefix: String?, _ message: String) -> String {
        guard let prefix else { return message }
        return "\(prefix) \(message)"
    }

    /// A short sentence naming the unavailable selection, shown when capture has
    /// fallen back to the built-in mic. nil when no fallback is active.
    private func inputFallbackPrefix() -> String? {
        guard inputRoutingUsesFallback else { return nil }
        let name = fallbackUnavailableDeviceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name, !name.isEmpty {
            return "Your selected microphone (\"\(name)\") isn't available."
        }
        return "Your selected microphone isn't available."
    }

    /// Names both sides of a microphone fallback for the routing banner shown in
    /// the notch and Settings (e.g. after the chosen input is unplugged).
    private func microphoneFallbackRoutingMessage(
        unavailableDeviceName: String?,
        fallbackDeviceName: String?
    ) -> String {
        let unavailable = unavailableDeviceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = fallbackDeviceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let unavailableLabel = (unavailable?.isEmpty == false) ? "\"\(unavailable!)\"" : "Selected microphone"
        if let fallback, !fallback.isEmpty {
            return "\(unavailableLabel) is unavailable. Using \"\(fallback)\"."
        }
        return "\(unavailableLabel) is unavailable. Using system default."
    }

    /// A sub-second capture of near-silence is an accidental hotkey brush,
    /// not a failed dictation — 63% of audio_unrecognized events fit this
    /// profile (<700ms, ~-50 dB peak). Showing an error for those is noise.
    /// Longer or louder captures keep the error: a long silent capture is a
    /// real signal that the wrong microphone is selected.
    static func isLikelyAccidentalTap(
        error: Error,
        capturedDurationMs: Int?,
        peakDb: Float?
    ) -> Bool {
        if case AudioRecorderError.finishFailed = error { return false }
        if case DictationError.speechDetectedButNoText = error { return false }
        guard let capturedDurationMs, capturedDurationMs < 700 else { return false }
        guard let peakDb, peakDb < -45 else { return false }
        return true
    }

    private func softAudioFailurePresentation(
        for error: Error
    ) -> (message: String, subtype: NotchOverlayState.ErrorSubtype) {
        if case AudioRecorderError.finishFailed = error {
            let micLabel = activeMicrophoneName() ?? "the microphone"
            if let dropout = captureDropoutGuidanceMessage(micLabel: micLabel) {
                return (dropout, .microphone)
            }
            return ("Recording interrupted — no audio arrived from \(micLabel). Check its connection, then try again.", .microphone)
        }

        if case DictationError.speechDetectedButNoText = error {
            return (speechDetectedButNoTextMessage(), .transcription)
        }

        return (noSpeechDetectedMessage(), .transcription)
    }

    private func activeMicrophoneName() -> String? {
        activeInputDeviceName ?? audioInputDeviceManager.effectiveDevice(for: settingsManager.inputDeviceUID)?.name
    }

    private func currentCaptureDurationMs(now: Date = Date()) -> Int? {
        guard let recordingStartedAt else { return nil }
        return max(0, Int(now.timeIntervalSince(recordingStartedAt) * 1000))
    }

    private func millisecondsSinceUnproductiveCapture(now: Date = Date()) -> Int? {
        guard let lastUnproductiveCaptureEndedAt else { return nil }
        return max(0, Int(now.timeIntervalSince(lastUnproductiveCaptureEndedAt) * 1000))
    }

    /// Records that the just-finished dictation capture produced no usable text
    /// (empty / silent / cancelled), arming the hold-mode restart throttle.
    private func noteUnproductiveCaptureEnded() {
        lastUnproductiveCaptureEndedAt = Date()
    }

    private func analyticsErrorType(_ error: Error) -> String {
        let normalized = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return String(describing: error) }
        return String(normalized.prefix(120))
    }

    private func roundedFiniteInt(_ value: Float) -> Int? {
        guard value.isFinite else { return nil }
        let rounded = value.rounded()
        guard rounded >= Float(Int.min), rounded <= Float(Int.max) else { return nil }
        return Int(rounded)
    }

    private func roundedFiniteMilliseconds(_ seconds: TimeInterval) -> Int? {
        let milliseconds = (seconds * 1000).rounded()
        guard milliseconds.isFinite,
              milliseconds >= Double(Int.min),
              milliseconds <= Double(Int.max)
        else {
            return nil
        }
        return max(0, Int(milliseconds))
    }

    private func appendCaptureDiagnostics(
        _ captureDiagnostics: DictationCaptureDiagnostics?,
        wallClockDurationMs: Int?,
        to properties: inout [String: Any]
    ) {
        properties["wall_clock_duration_ms"] = wallClockDurationMs as Any
        properties["captured_duration_ms"] = captureDiagnostics?.durationMilliseconds as Any
        properties["captured_sample_count"] = captureDiagnostics?.sampleCount as Any
        properties["warm_session_used"] = dictationManager.lastDidUseWarmSession
        properties["capture_restart_count"] = audioRecorder.lastCaptureRestartCount
        properties["low_latency_mode"] = settingsManager.lowLatencyMode
        if let captureStartGapMs = lastCaptureStartGapMs {
            properties["capture_start_gap_ms"] = captureStartGapMs
        }
        if let gateStage = dictationManager.lastSilenceDiagnosticsReason {
            properties["gate_stage"] = gateStage
        }
        if let inputDeviceName = audioRecorder.lastCaptureDeviceName {
            properties["input_device_name"] = inputDeviceName
        }
        if let inputDeviceIsDefault = audioRecorder.lastCaptureDeviceIsSystemDefault {
            properties["input_device_is_default"] = inputDeviceIsDefault
        }

        if let diagnostics = dictationManager.lastSilenceDiagnostics {
            if let peakDb = roundedFiniteInt(diagnostics.peakDb) {
                properties["audio_peak_db"] = peakDb
            }
            if let meanDb = roundedFiniteInt(diagnostics.meanDb) {
                properties["audio_mean_db"] = meanDb
            }
            if let noiseFloorDb = roundedFiniteInt(diagnostics.noiseFloorDb) {
                properties["audio_noise_floor_db"] = noiseFloorDb
            }
            if let truePeakDb = roundedFiniteInt(diagnostics.truePeakDb) {
                properties["audio_true_peak_db"] = truePeakDb
            }
            properties["audio_clip_ratio"] = diagnostics.clipRatio
            properties["audio_indicates_clipping"] = diagnostics.indicatesClipping
            if let snrDb = roundedFiniteInt(diagnostics.signalToNoiseDb) {
                properties["audio_snr_db"] = snrDb
            }
            properties["audio_indicates_high_background_noise"] = diagnostics.indicatesHighBackgroundNoise
            if let thresholdDb = roundedFiniteInt(diagnostics.thresholdDb) {
                properties["audio_threshold_db"] = thresholdDb
            }
            properties["speech_segment_count"] = diagnostics.speechSegmentCount
            if let voicedDurationMs = roundedFiniteMilliseconds(diagnostics.voicedDurationSeconds) {
                properties["voiced_duration_ms"] = voicedDurationMs
            }
            properties["segmenter_source"] = diagnostics.segmenterSource.rawValue
        }
    }

    private func activeDictationAnalyticsProperties(_ properties: [String: Any]) -> [String: Any] {
        guard let activeDictationID else { return properties }
        var enriched = properties
        enriched["dictation_id"] = activeDictationID
        return enriched
    }

    private func pasteFailureAnalyticsValue() -> String? {
        pasteManager.lastDeliveryFailure?.analyticsValue
    }

    func completeNativeSignIn() async {
        await completeSignIn(source: pendingLoginSource)
    }

    private func completeSignIn(source: String) async {
        authWindowController.dismiss()
        reconcileMeetingWebhookDestination()
        syncAnalyticsIdentity()
        syncSentryRuntimeConfiguration()
        analyticsManager.capture("auth_signed_in", properties: ["source": source])
        pendingLoginSource = "settings"
    }

    private func syncAnalyticsIdentity() {
        guard let userId = authManager.userId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !userId.isEmpty else {
            if analyticsManager.isIdentifiedUser {
                analyticsManager.resetIdentity()
            }
            return
        }

        let email = authManager.userEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        analyticsManager.identify(userId: userId, email: email?.isEmpty == false ? email : nil)
    }

    private func syncSentryRuntimeConfiguration() {
        SentryManager.shared.syncConfiguration(
            userId: authManager.userId,
            email: authManager.userEmail
        )
    }

    private func resolveDeliveredText(for result: TranscriptionResult, keepWorkflowVisible: Bool) async -> DeliveredTextResolution? {
        let transcript = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedText = result.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let emailMode = CloudProcessingSupport.emailDictationMode(
            transcript: transcript,
            focusedFieldContent: result.focusedFieldContent,
            appName: result.targetApp,
            bundleId: result.targetBundleId,
            windowTitle: result.windowTitle,
            browserURL: result.browserURL,
            fallbackSenderName: settingsManager.resolvedEmailSignoffName
        )

        // Selection transform branch — highlighted text plus an explicit transform command.
        guard AppFeatureVisibility.hostedServices,
              settingsManager.selectionTransformEnabled,
              !selectedText.isEmpty,
              !transcript.isEmpty,
              CloudProcessingSupport.looksLikeSelectionTransformCommand(transcript)
        else {
            return await cloudCleanupOrOriginal(
                transcript: transcript,
                result: result,
                keepWorkflowVisible: keepWorkflowVisible,
                emailMode: emailMode
            )
        }

        guard authManager.isLoggedIn else {
            return abortSelectionTransform(
                message: selectionTransformSignInRequiredMessage,
                analyticsReason: "blocked_sign_in_required",
                transcript: transcript
            )
        }

        let transformRouting = CloudProcessingSupport.selectionTransformRouting(
            command: transcript,
            selectedText: selectedText
        )
        var detailedEditProgressTask: Task<Void, Never>?
        defer {
            detailedEditProgressTask?.cancel()
        }

        if keepWorkflowVisible {
            notchCoordinator.setState(.processing(
                progress: 0.55,
                stage: CloudProcessingSupport.selectionTransformStage(
                    command: transcript,
                    route: transformRouting.route
                )
            ))

            if transformRouting.route == .advanced {
                detailedEditProgressTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(4))
                    guard !Task.isCancelled else { return }
                    self?.notchCoordinator.setState(.processing(
                        progress: 0.72,
                        stage: "Still refining selection..."
                    ))
                }
            }
        }

        let transformStartedAt = Date()
        activeLatencyLogger?.mark("transformStart")
        let transformResult = await convexClient.transformSelection(
            command: transcript,
            selectedText: selectedText,
            windowTitle: result.windowTitle,
            appName: result.targetApp,
            bundleId: result.targetBundleId,
            browserURL: result.browserURL,
            dictionaryTerms: dictionaryStore.cloudDictionaryTerms(),
            recentTexts: recentCloudContextTexts(),
            routing: transformRouting
        )
        activeLatencyLogger?.mark("transformEnd")
        guard !Task.isCancelled else { return nil }

        switch transformResult {
        case .success(let text):
            let transformed = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            guard !transformed.isEmpty else {
                return abortSelectionTransform(
                    message: "Selection transform returned empty text. Try rephrasing your instruction.",
                    analyticsReason: "empty_output",
                    transcript: transcript
                )
            }
            analyticsManager.capture("selection_transform_used", properties: [
                "command_length": transcript.count,
                "duration_ms": max(0, Int(Date().timeIntervalSince(transformStartedAt) * 1000)),
                "selected_length": selectedText.count,
                "route": transformRouting.route.rawValue,
                "route_reason": transformRouting.reason
            ])
            return DeliveredTextResolution(
                text: transformed,
                selectionTransformUsed: true,
                cleanup: .notApplicable,
                transform: DictationQualityTrace.Transform(
                    status: .succeeded,
                    attempted: true,
                    succeeded: true,
                    failureReason: nil,
                    clientDurationMs: max(0, Int(Date().timeIntervalSince(transformStartedAt) * 1000))
                )
            )

        case .failure(let failure):
            analyticsManager.capture("selection_transform_failed", properties: [
                "reason": String(describing: failure),
                "command_length": transcript.count,
                "duration_ms": max(0, Int(Date().timeIntervalSince(transformStartedAt) * 1000)),
                "selected_length": selectedText.count,
                "route": transformRouting.route.rawValue,
                "route_reason": transformRouting.reason
            ])
            return abortSelectionTransform(
                message: selectionTransformFailureMessage(for: failure),
                analyticsReason: "failed_\(String(describing: failure))",
                transcript: transcript
            )
        }
    }

    private func abortSelectionTransform(
        message: String,
        analyticsReason: String,
        transcript: String
    ) -> DeliveredTextResolution? {
        guard !Task.isCancelled else { return nil }
        // Never drop the user's words: keep the dictated command recoverable
        // from the clipboard even though the transform itself failed.
        let copied = !transcript.isEmpty && pasteManager.copy(text: transcript)
        analyticsManager.capture("selection_transform_aborted", properties: [
            "environment": AppRuntime.appEnvironment.rawValue,
            "reason": analyticsReason,
            "transcript_copied": copied
        ])
        playAudioCue(.warning)
        notchCoordinator.showError(
            copied ? message + " Your dictation was copied to the clipboard." : message,
            subtype: .generic
        )
        return nil
    }

    private var selectionTransformSignInRequiredMessage: String {
        if AppRuntime.appEnvironment == .development {
            return "Dev sign-in needed. Sign in again in Settings."
        }
        return "Sign in to transform selected text."
    }

    private func selectionTransformFailureMessage(for failure: TransformFailure) -> String {
        switch failure {
        case .signInRequired:
            if AppRuntime.appEnvironment == .development {
                return "Dev sign-in needed. Sign in again in Settings."
            }
            return failure.userMessage
        case .outputRejected(let reason):
            switch reason {
            case "too-long":
                return "That transform came back unusually long. Try a smaller selection or ask for a shorter rewrite."
            case "command-echo", "assistant-response", "transform-explanation":
                return "Transform returned an invalid replacement. Try rephrasing your instruction."
            default:
                return failure.userMessage
            }
        default:
            return failure.userMessage
        }
    }

    private var latestReusableDictation: FeedItem? {
        feedManager.items.first { item in
            item.kind == .dictation &&
            !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func recordActiveInput(
        deviceName: String?,
        routingMessage: String?,
        usesFallback: Bool,
        unavailableDeviceName: String? = nil
    ) {
        activeInputDeviceName = deviceName
        inputRoutingMessage = routingMessage
        inputRoutingUsesFallback = usesFallback
        fallbackUnavailableDeviceName = usesFallback ? unavailableDeviceName : nil
    }

    private func fallbackCopyAfterFailedDelivery(text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return pasteManager.copy(text: text)
    }

    private func handlePasteFailurePresentation(copiedFallback: Bool) {
        switch DictationDeliveryFailurePolicy.presentation(
            copiedFallback: copiedFallback,
            recoverableIssueNoticesEnabled: settingsManager.recoverableDictationIssueNoticesEnabled
        ) {
        case .copiedFallbackNotice:
            notchCoordinator.showNotice(
                NotchOverlayState.Notice(
                    title: "Copied to clipboard",
                    detail: "Press ⌘V to paste.",
                    icon: "doc.on.clipboard"
                ),
                timeout: .seconds(6)
            )
            cursorPasteHint.show()

        case .copiedFallbackIssue:
            playAudioCue(.warning)
            notchCoordinator.showError(
                copiedFallbackPasteFailureMessage(),
                subtype: .paste
            )
            cursorPasteHint.show()

        case .blockingIssue:
            playAudioCue(.error)
            notchCoordinator.showError(pasteFailureMessage(), subtype: .paste)
        }
    }

    private func copiedFallbackPasteFailureMessage() -> String {
        guard pasteManager.lastDeliveryFailure != nil else {
            return "Copied to clipboard — ⌘V to paste"
        }
        return pasteFailureMessage() + " Copied to clipboard — ⌘V to paste."
    }

    private func pasteFailureMessage() -> String {
        switch pasteManager.lastDeliveryFailure {
        case .accessibilityPermissionStale:
            return "Accessibility permission expired after an update. Remove Resonant from Accessibility settings, then re-add it from your Applications folder."
        case .accessibilityPermissionRequired:
            if AppRuntime.hasValidMainBundle {
                return "Accessibility access is missing. Open Accessibility and enable Resonant."
            }
            return "Launch \(Bundle.main.bundleURL.lastPathComponent), then enable Accessibility for auto-paste."
        case .targetActivationFailed:
            return "Could not focus the target app. Click the field and try again."
        case .noFrontmostTarget:
            return "No target app focused. Click the field and try again."
        case .deliveryUnverified:
            return "Could not confirm insertion in the target field. Click the composer and try again."
        case .secureInputActive:
            return "Secure Keyboard Entry is active. Close password prompts or terminal sessions, then try again."
        case .partialDelivery:
            return "Direct typing stopped partway through. Part of the text may already be in the target field."
        default:
            return "Could not auto-paste. Try again or copy the text manually."
        }
    }

    /// Attempts Groq-backed dictation cleanup via
    /// `DictationCleanupPipeline`, which owns the full clean → lint → repair
    /// sequence. Falls back to local normalization when cloud processing is
    /// unavailable, disabled, or fails, so this is safe to call unconditionally.
    private func cloudCleanupOrOriginal(
        transcript: String,
        result: TranscriptionResult,
        keepWorkflowVisible: Bool,
        emailMode: CloudProcessingSupport.EmailDictationMode
    ) async -> DeliveredTextResolution {
        var pipeline = DictationCleanupPipeline(
            convexClient: convexClient,
            cloudProcessingEnabled: settingsManager.cloudProcessingEnabled,
            lowLatencyMode: settingsManager.lowLatencyMode,
            isLoggedIn: authManager.isLoggedIn,
            fallbackSenderName: settingsManager.resolvedEmailSignoffName,
            recentTexts: recentCloudContextTexts()
        )
        pipeline.polishSettings = settingsManager.dictationPolishSettings
        if keepWorkflowVisible {
            pipeline.onStage = { [weak self] progress, stage in
                self?.notchCoordinator.setState(.processing(progress: progress, stage: stage))
            }
        }
        pipeline.markLatency = { [activeLatencyLogger] label in
            activeLatencyLogger?.mark(label)
        }
        pipeline.captureAnalytics = { [analyticsManager] event, properties in
            analyticsManager.capture(event, properties: properties)
        }

        let outcome = await pipeline.resolve(
            transcript: transcript,
            result: result,
            emailMode: emailMode
        )
        return DeliveredTextResolution(
            text: outcome.text,
            selectionTransformUsed: false,
            cleanup: outcome.cleanup,
            transform: .notApplicable
        )
    }

    private func applySmartLinksIfNeeded(
        to text: String,
        allowSmartLinks: Bool = true,
        source: String
    ) -> String {
        guard allowSmartLinks else { return text }

        let enabledLinks = smartLinkStore.links.filter(\.isEnabled)
        guard !enabledLinks.isEmpty else { return text }

        let (processedText, matchCount) = SmartLinkProcessor().process(text, links: enabledLinks)
        guard processedText != text else { return text }

        analyticsManager.capture("smart_links_applied", properties: [
            "source": source,
            "link_count": enabledLinks.count,
            "match_count": matchCount
        ])
        return processedText
    }

    private func recentCloudContextTexts(limit: Int = 5) -> [String] {
        var seen = Set<String>()
        var recentTexts: [String] = []

        for item in feedManager.items {
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let key = text.lowercased()
            guard seen.insert(key).inserted else { continue }

            recentTexts.append(text)
            if recentTexts.count >= limit {
                break
            }
        }

        return recentTexts
    }

    private var shouldKeepNotchSyncedToHold: Bool {
        settingsManager.hotkeyMode == .hold
    }

    @discardableResult
    private func cleanupTemporaryRecording(at url: URL?) -> Bool {
        guard let url else { return true }
        return DictationRecordingFileDeletion.removeIfPresent(url)
    }

    private func persistedAudioExists(at path: String?) -> Bool {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else { return false }
        let url: URL
        if path.hasPrefix("file://"), let fileURL = URL(string: path), fileURL.isFileURL {
            url = fileURL
        } else if path.hasPrefix("/") {
            url = URL(fileURLWithPath: path)
        } else {
            url = AppSupportPaths.resonantRoot().appendingPathComponent(path)
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func persistCompletedDictation(
        entry: DictationEntry,
        result: TranscriptionResult,
        resolvedText: String,
        deliveredText: String?,
        autoPasted: Bool,
        autoSent: Bool,
        copiedToClipboard: Bool,
        includeContextMetadata: Bool,
        shouldPersistAudio: Bool
    ) async -> Bool {

        // Cold Accessibility metadata is optional and must not hold the outer
        // capture finalizer indefinitely. It normally finishes while ASR and
        // delivery run; give it one short grace period, then commit core text
        // and requested audio without it.
        if includeContextMetadata, let coldContextTask = result.coldContextTask {
            let cold = await DictationAsyncDeadline.valueIfReady(
                coldContextTask,
                timeoutNanoseconds: 15_000_000
            )
            if let cold {
                if let primaryCodeFile = cold.primaryCodeFile {
                    entry.codeFileName = primaryCodeFile
                }
                if let primarySlack = cold.primarySlackRecipient {
                    entry.slackRecipient = primarySlack
                }
                if !cold.visibleTextSnippets.isEmpty {
                    entry.visibleTextSnippetsJSON = encodeJSONStringArray(cold.visibleTextSnippets)
                }
            } else {
                coldContextTask.cancel()
            }
        }

        let archiveResult: ArchiveWriter.DictationWriteResult?
        if shouldPersistAudio {
            // The archive copy establishes the durable audio path that must be
            // included in the SwiftData row before its commit.
            archiveResult = await archiveWriter.writeDictation(
                entry: entry,
                rawTranscript: result.rawTranscript,
                deliveredText: deliveredText,
                recordingURL: result.recordingURL
            )
        } else {
            archiveResult = nil
        }

        let dataStoreCommitted = await dataStore.save(entry)
        let hasSecuredRequestedAudio = !shouldPersistAudio
            || archiveResult?.didCopyRecordingToArchive == true
        let coreCommitted = dataStoreCommitted && hasSecuredRequestedAudio
        let activityCommitted: Bool
        if coreCommitted {
            activityCommitted = await activityStreamWriter.writeDictationEvent(
                result: result,
                resolvedText: resolvedText,
                entry: entry,
                autoPasted: autoPasted,
                autoSent: autoSent,
                copiedToClipboard: copiedToClipboard,
                saveAudioEnabled: shouldPersistAudio,
                includeContextMetadata: includeContextMetadata
            )
        } else {
            activityCommitted = false
        }
        if !shouldPersistAudio, dataStoreCommitted {
            // Keep the secondary mirror owned by the terminal finalizer. Clear
            // Workspace waits that finalizer, so an old write cannot recreate
            // Markdown after the archive has been removed.
            _ = await archiveWriter.writeDictation(
                entry: entry,
                rawTranscript: result.rawTranscript,
                deliveredText: deliveredText,
                recordingURL: nil
            )
        }
        // The marker is cleared only after the app's queryable history row is
        // committed. Markdown is a useful backup, but it cannot replace the
        // row users expect to find in Resonant after relaunch.
        let hasDurableText = dataStoreCommitted
        let committed = coreCommitted && activityCommitted
        if committed {
            feedManager.record(entry)
            scheduleJournalGeneration(for: entry.date)
            workspaceSyncEngine.markExportNeeded()
            cleanupTemporaryRecording(at: result.recordingURL)
        } else {
            Self.log.error(
                "Dictation durable handoff incomplete text=\(hasDurableText, privacy: .public) audio=\(hasSecuredRequestedAudio, privacy: .public) activity=\(activityCommitted, privacy: .public)"
            )
        }
        return committed
    }

    /// Checks if the app bundle still carries the com.apple.quarantine xattr,
    /// which means the user downloaded it and macOS flagged it. If true on
    /// first launch, the user had to click through Gatekeeper to get here.
    private static func appWasQuarantined() -> Bool {
        let path = Bundle.main.bundlePath
        let attr = "com.apple.quarantine"
        return getxattr(path, attr, nil, 0, 0, XATTR_NOFOLLOW) > 0
    }

    // MARK: - Debug: Seed Test Meetings

    #if DEBUG
    func seedTestMeetings() async {
        let calendar = Calendar.current
        let now = Date()

        struct FakeMeeting {
            let title: String
            let app: MeetingApp?
            let minutesAgo: Int
            let durationMinutes: Int
            let transcript: [(MeetingSpeaker, String)]
            let notes: String
            let postNotes: String
        }

        let fakeMeetings: [FakeMeeting] = [
            FakeMeeting(
                title: "Q2 Product Roadmap Review",
                app: MeetingApp(bundleID: "us.zoom.xos", name: "Zoom"),
                minutesAgo: 45,
                durationMinutes: 52,
                transcript: [
                    (.you, "Let's walk through the Q2 priorities. I've updated the roadmap in Notion with the latest estimates."),
                    (.participant(id: "SPEAKER_0"), "Sounds good. Can we start with the mobile push notification feature? The marketing team is asking about the timeline."),
                    (.you, "Sure. We're targeting mid-April for the beta. The backend work is mostly done, just need to wire up the APNs integration."),
                    (.participant(id: "SPEAKER_1"), "I have a concern about the rate limiting on notifications. We saw some issues in staging last week."),
                    (.you, "Good point. I'll add a task to investigate that. Let's cap it at 10 per hour per user for now."),
                    (.participant(id: "SPEAKER_0"), "That works. What about the analytics dashboard redesign?"),
                    (.participant(id: "SPEAKER_1"), "I've been prototyping some ideas. The current charts are too cluttered. I want to move to a card-based layout."),
                    (.you, "Love it. Can you share the Figma link in Slack after this? I'll review it this afternoon."),
                    (.participant(id: "SPEAKER_0"), "One more thing — the investor demo is on April 15th. We need the onboarding flow polished by then."),
                    (.you, "Noted. I'll prioritize that this sprint."),
                ],
                notes: "- Mobile push beta: mid-April\n- Rate limit: 10/hr/user\n- Review Figma for dashboard redesign\n- Investor demo: April 15",
                postNotes: "Action items sent to #product-updates channel"
            ),
            FakeMeeting(
                title: "Sprint Retrospective",
                app: MeetingApp(bundleID: "com.google.Chrome", name: "Google Meet"),
                minutesAgo: 180,
                durationMinutes: 35,
                transcript: [
                    (.participant(id: "SPEAKER_0"), "Alright, let's start with what went well this sprint."),
                    (.you, "The deployment pipeline improvements saved us a lot of time. We went from 20-minute builds down to 8 minutes."),
                    (.participant(id: "SPEAKER_1"), "Agreed. Also, the pair programming sessions on the auth refactor were really productive."),
                    (.participant(id: "SPEAKER_0"), "What could we improve?"),
                    (.you, "We need better test coverage on the meeting transcription engine. We had two regressions that slipped through."),
                    (.participant(id: "SPEAKER_1"), "I think we should also timebox code reviews to 24 hours. Some PRs sat for three days last sprint."),
                    (.participant(id: "SPEAKER_0"), "Fair. Let's add that to our working agreement. Any blockers for next sprint?"),
                    (.you, "I'm waiting on API credentials from the calendar integration vendor. I'll follow up today."),
                ],
                notes: "- Build time: 20min → 8min\n- Need more tests on transcription engine\n- 24hr code review SLA proposed",
                postNotes: ""
            ),
            FakeMeeting(
                title: "Design Review: Settings Overhaul",
                app: MeetingApp(bundleID: "com.figma.Desktop", name: "Figma"),
                minutesAgo: 1500,
                durationMinutes: 28,
                transcript: [
                    (.you, "I've been iterating on the settings layout. The current tab approach doesn't scale well — we have 9 tabs now."),
                    (.them, "Have you considered a sidebar navigation pattern instead? Like System Settings on macOS."),
                    (.you, "That's exactly what I'm proposing. Let me share my screen. See this prototype — grouped sections with search."),
                    (.them, "Oh this is much cleaner. I like the search. What about discoverability of new features?"),
                    (.you, "I was thinking a subtle badge on new items. Nothing aggressive, just a small blue dot."),
                    (.them, "That works. The color palette looks great too. Are you sticking with the blue and amber?"),
                    (.you, "Yes. Green for success states, amber for warnings, blue for primary actions. No purple."),
                    (.them, "Perfect. When can we get this into a build?"),
                    (.you, "I'll have the sidebar shell ready by end of week. We can migrate tabs one at a time."),
                ],
                notes: "- Sidebar nav replaces tabs\n- Search + grouped sections\n- Blue dot badge for new features\n- Shell ready by EOW",
                postNotes: "Shared Figma link: https://figma.com/file/abc123/settings-redesign"
            ),
            FakeMeeting(
                title: "1:1 with Marcus",
                app: MeetingApp(bundleID: "com.microsoft.teams2", name: "Microsoft Teams"),
                minutesAgo: 2880,
                durationMinutes: 25,
                transcript: [
                    (.you, "Hey Marcus, how's the week going?"),
                    (.them, "Pretty good. I finished the webhook reliability improvements yesterday. Retry logic with exponential backoff."),
                    (.you, "Nice. I saw the PR — clean implementation. How are you feeling about the meeting feature work?"),
                    (.them, "Excited but a bit overwhelmed. The audio processing pipeline is more complex than I expected."),
                    (.you, "That's totally fair. Let's break it down into smaller chunks. What's the next concrete milestone?"),
                    (.them, "Getting the speaker diarization working reliably. Right now it sometimes merges two speakers."),
                    (.you, "Do you need any resources? I can pair with you on the audio buffer logic."),
                    (.them, "That would be great actually. Maybe Thursday afternoon?"),
                    (.you, "Done. I'll block 2-4pm. Anything else on your mind?"),
                    (.them, "Just want to make sure I'm on track for the mid-year review. Any feedback so far?"),
                    (.you, "You're doing great. Your code quality has been consistently high and you're ramping fast on the audio work."),
                ],
                notes: "- Webhook retry logic shipped\n- Speaker diarization needs work\n- Pairing session Thursday 2-4pm",
                postNotes: "Follow up: send Marcus the audio processing reference docs"
            ),
            FakeMeeting(
                title: "Customer Feedback Session — Acme Corp",
                app: MeetingApp(bundleID: "us.zoom.xos", name: "Zoom"),
                minutesAgo: 4320,
                durationMinutes: 42,
                transcript: [
                    (.participant(id: "SPEAKER_0"), "Thanks for joining. We've been using Resonant for about three weeks now and have some feedback."),
                    (.you, "Great, we'd love to hear it. What's been working well?"),
                    (.participant(id: "SPEAKER_0"), "The dictation accuracy is impressive. Our legal team especially loves it for drafting contracts."),
                    (.participant(id: "SPEAKER_1"), "I use the meeting transcription daily. Being able to search past meetings has been a game changer."),
                    (.you, "That's wonderful to hear. Any pain points?"),
                    (.participant(id: "SPEAKER_0"), "The meeting recordings sometimes miss the first few seconds of audio."),
                    (.you, "We're aware of that issue and have a fix shipping next week. It's a buffer timing problem."),
                    (.participant(id: "SPEAKER_1"), "Can we get an API to pull transcripts into our internal wiki?"),
                    (.you, "Absolutely. We have a local API that we're expanding. I'll send you the docs."),
                    (.participant(id: "SPEAKER_0"), "One more thing — any plans for team sharing? We'd love to share meeting summaries across our org."),
                    (.you, "It's on our roadmap for Q3. We're designing the sharing model right now."),
                ],
                notes: "- Legal team is a power user segment\n- Audio buffer fix shipping next week\n- API docs to send\n- Team sharing request (Q3 roadmap)",
                postNotes: "Sent API documentation link to sarah@acmecorp.com"
            ),
            FakeMeeting(
                title: "Investor Update Call",
                app: MeetingApp(bundleID: "com.google.Chrome", name: "Google Meet"),
                minutesAgo: 60 * 24 * 4,
                durationMinutes: 30,
                transcript: [
                    (.you, "Good morning everyone. Let me give you a quick update on our progress since last month."),
                    (.participant(id: "SPEAKER_0"), "Looking forward to it. How are the user numbers?"),
                    (.you, "We crossed 2,000 active users last week. Growth is about 15% week over week."),
                    (.participant(id: "SPEAKER_1"), "That's solid. What's driving the growth?"),
                    (.you, "Word of mouth, primarily. Our NPS is 72, which is exceptional for a productivity tool."),
                    (.participant(id: "SPEAKER_0"), "Revenue trajectory?"),
                    (.you, "ARR is at $180K. We expect to hit $300K by end of Q2 with the enterprise tier launch."),
                    (.participant(id: "SPEAKER_1"), "When does the enterprise tier go live?"),
                    (.you, "April 20th. We have three companies in private beta already — all converting to paid."),
                    (.participant(id: "SPEAKER_0"), "Excellent. Keep up the momentum."),
                ],
                notes: "- 2K active users, 15% WoW growth\n- NPS: 72\n- ARR: $180K, targeting $300K EOQ2\n- Enterprise launch April 20",
                postNotes: ""
            ),
            FakeMeeting(
                title: "Bug Triage — Audio Issues",
                app: MeetingApp(bundleID: "com.linear", name: "Linear"),
                minutesAgo: 60 * 5,
                durationMinutes: 18,
                transcript: [
                    (.you, "We have four audio-related bugs from this week. Let's triage them."),
                    (.them, "First one is the recording cutoff on Bluetooth headphones. I can reproduce it consistently."),
                    (.you, "That's P1. It affects a lot of AirPods users. What's the root cause?"),
                    (.them, "The audio session category isn't set correctly when switching from built-in mic to Bluetooth."),
                    (.you, "Okay, let's fix that today. Next one?"),
                    (.them, "Echo detection false positive — it's marking single-speaker meetings as having echo."),
                    (.you, "P2. We can adjust the threshold. The current sensitivity is too aggressive."),
                    (.them, "Last two are edge cases with very long meetings. Memory grows unbounded after about 3 hours."),
                    (.you, "That's the utterance buffer. We need to flush to disk periodically. P1 as well — people do long workshops."),
                ],
                notes: "- P1: Bluetooth audio session fix (today)\n- P2: Echo detection threshold\n- P1: Memory growth in long meetings — flush utterance buffer",
                postNotes: "Created Linear issues: AUD-142, AUD-143, AUD-144"
            ),
        ]

        for fake in fakeMeetings {
            let id = UUID()
            let startDate = calendar.date(byAdding: .minute, value: -fake.minutesAgo, to: now)!
            let endDate = calendar.date(byAdding: .minute, value: fake.durationMinutes, to: startDate)!

            let utterances: [MeetingUtterance] = fake.transcript.enumerated().map { index, pair in
                let offsetSeconds = Double(index) * (Double(fake.durationMinutes * 60) / Double(fake.transcript.count))
                return MeetingUtterance(
                    text: pair.1,
                    speaker: pair.0,
                    timestamp: startDate.addingTimeInterval(offsetSeconds)
                )
            }

            let session = CompletedMeetingSession(
                id: id,
                startedAt: startDate,
                endedAt: endDate,
                detectedApp: fake.app,
                suggestedTitle: fake.title,
                captureContext: .adHoc(title: fake.title, recordingOrigin: .manual),
                speakerAliases: [:],
                utterances: utterances,
                liveNotes: fake.notes,
                postMeetingNotes: fake.postNotes,
                recordingURL: nil,
                shouldDeleteRecordingAfterSave: false
            )

            let entry = MeetingEntry(
                id: id,
                startedAt: startDate,
                endedAt: endDate,
                detectedApp: fake.app?.name,
                customTitle: fake.title,
                durationSeconds: session.durationSeconds,
                wordCount: session.wordCount,
                userNotes: fake.notes.isEmpty ? nil : fake.notes,
                postMeetingNotes: fake.postNotes.isEmpty ? nil : fake.postNotes
            )

            await archiveWriter.writeMeeting(session: session, entry: entry)
            dataStore.context?.insert(entry)
        }

        dataStore.saveChanges()
    }
    #endif
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
