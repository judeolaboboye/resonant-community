import Foundation
import Defaults
import LaunchAtLogin
import os

// MARK: - Keys

extension Defaults.Keys {
    private static let passwordManagerBundleIds = [
        "com.agilebits.onepassword7",
        "com.1password.1password",
        "com.lastpass.LastPass",
        "com.bitwarden.desktop",
    ]

    // Onboarding
    static let onboardingCompleted   = Key<Bool>("onboardingCompleted", default: false, suite: AppDefaults.suite)
    /// Durable marker used to distinguish a genuine first onboarding session
    /// from a welcome-step resume after the window was closed.
    static let onboardingHasStarted  = Key<Bool>("onboardingHasStarted", default: false, suite: AppDefaults.suite)
    /// Last onboarding step the user reached (analytics key), so closing the
    /// window resumes instead of restarting. Cleared on completion.
    static let onboardingResumeStep  = Key<String>("onboardingResumeStep", default: "", suite: AppDefaults.suite)

    // Hotkey
    static let hotkeyTrigger         = Key<String>("hotkeyTrigger", default: HotkeyTrigger.fn.rawValue, suite: AppDefaults.suite)
    static let hotkeyAlternateTriggers = Key<[String]>("hotkeyAlternateTriggers", default: [], suite: AppDefaults.suite)
    static let hotkeyMode            = Key<String>("hotkeyMode",    default: HotkeyMode.hold.rawValue, suite: AppDefaults.suite)
    static let hotkeyHoldLockEnabled = Key<Bool>("hotkeyHoldLockEnabled", default: true, suite: AppDefaults.suite)

    // Model
    static let selectedModelId       = Key<String>("selectedModelId", default: "parakeet-tdt-0.6b-v3", suite: AppDefaults.suite)
    static let transcriptionLanguage = Key<String>("transcriptionLanguage", default: "auto", suite: AppDefaults.suite)

    // Text processing
    static let removeFillersEnabled      = Key<Bool>("removeFillersEnabled",      default: true, suite: AppDefaults.suite)
    static let removeFalseStartsEnabled  = Key<Bool>("removeFalseStartsEnabled",  default: true, suite: AppDefaults.suite)
    static let itnEnabled                = Key<Bool>("itnEnabled",                default: true, suite: AppDefaults.suite)
    static let vocabularyBoostEnabled    = Key<Bool>("vocabularyBoostEnabled",    default: true, suite: AppDefaults.suite)
    static let liveTranscriptPreviewEnabled = Key<Bool>("liveTranscriptPreviewEnabled", default: true, suite: AppDefaults.suite)
    static let autoPunctuationEnabled    = Key<Bool>("autoPunctuationEnabled",    default: true, suite: AppDefaults.suite)
    static let bulletPointsEnabled       = Key<Bool>("bulletPointsEnabled",       default: false, suite: AppDefaults.suite)
    static let cloudProcessingEnabled    = Key<Bool>("cloudProcessingEnabled",    default: false, suite: AppDefaults.suite)
    // One-shot: sign-in enables cloud processing once; after that the user's choice wins.
    static let cloudProcessingAutoEnabled = Key<Bool>("cloudProcessingAutoEnabled", default: false, suite: AppDefaults.suite)
    static let polishLevelChat           = Key<String>("polishLevelChat",         default: DictationPolishLevel.clean.rawValue, suite: AppDefaults.suite)
    static let polishLevelEmail          = Key<String>("polishLevelEmail",        default: DictationPolishLevel.clean.rawValue, suite: AppDefaults.suite)
    static let polishLevelOther          = Key<String>("polishLevelOther",        default: DictationPolishLevel.clean.rawValue, suite: AppDefaults.suite)
    static let selectionTransformEnabled = Key<Bool>("selectionTransformEnabled", default: true, suite: AppDefaults.suite)
    static let journalSummarizationEnabled = Key<Bool>("journalSummarizationEnabled", default: true, suite: AppDefaults.suite)
    static let meetingSummarizationEnabled = Key<Bool>("meetingSummarizationEnabled", default: true, suite: AppDefaults.suite)
    static let meetingSummaryStyle         = Key<String>("meetingSummaryStyle",       default: MeetingSummaryStyle.standard.rawValue, suite: AppDefaults.suite)

    // Output
    static let autoPasteEnabled          = Key<Bool>("autoPasteEnabled",          default: true, suite: AppDefaults.suite)
    static let copyToClipboardEnabled    = Key<Bool>("copyToClipboardEnabled",    default: false, suite: AppDefaults.suite)
    static let autoSendEnabled           = Key<Bool>("autoSendEnabled",           default: false, suite: AppDefaults.suite)
    static let pasteDeliveryMode         = Key<String>("pasteDeliveryMode",       default: PasteDeliveryMode.automatic.rawValue, suite: AppDefaults.suite)
    static let emailSignatureEnabled     = Key<Bool>("emailSignatureEnabled",     default: false, suite: AppDefaults.suite)
    static let emailSignoffName          = Key<String?>("emailSignoffName",       default: nil, suite: AppDefaults.suite)

    // Appearance
    static let soundsEnabled             = Key<Bool>("soundsEnabled",             default: true, suite: AppDefaults.suite)
    static let soundsVolume              = Key<Double>("soundsVolume",            default: 0.6, suite: AppDefaults.suite)
    static let overlayMode               = Key<String>("overlayMode",             default: "notch", suite: AppDefaults.suite)
    static let notchIdleVisible          = Key<Bool>("notchIdleVisible",          default: true, suite: AppDefaults.suite)
    static let notchHidden               = Key<Bool>("notchHidden",               default: false, suite: AppDefaults.suite)
    static let recoverableDictationIssueNoticesEnabled = Key<Bool>("recoverableDictationIssueNoticesEnabled", default: false, suite: AppDefaults.suite)
    static let dictationOrbHue           = Key<Double>("dictationOrbHue",         default: 0.60, suite: AppDefaults.suite)

    // Audio
    static let inputDeviceUID            = Key<String?>("inputDeviceUID",         default: nil, suite: AppDefaults.suite)
    static let hotMicEnabled             = Key<Bool>("hotMicEnabled",             default: false, suite: AppDefaults.suite)
    static let pauseMediaWhileRecording  = Key<Bool>("pauseMediaWhileRecording",  default: false, suite: AppDefaults.suite)
    static let duckSystemAudioWhileRecording = Key<Bool>("duckSystemAudioWhileRecording", default: false, suite: AppDefaults.suite)
    static let hotWord                   = Key<String>("hotWord",                default: SettingsManager.defaultHotWord, suite: AppDefaults.suite)
    // Dispatch (voice command mode)
    static let dispatchEnabled           = Key<Bool>("dispatchEnabled",           default: false, suite: AppDefaults.suite)
    static let dispatchTTSEnabled        = Key<Bool>("dispatchTTSEnabled",        default: false, suite: AppDefaults.suite)
    static let dispatchCloudFallbackEnabled = Key<Bool>("dispatchCloudFallbackEnabled", default: false, suite: AppDefaults.suite)
    static let lowLatencyMode            = Key<Bool>("lowLatencyMode",            default: false, suite: AppDefaults.suite)
    static let clamshellMicSwitchEnabled = Key<Bool>("clamshellMicSwitchEnabled", default: false, suite: AppDefaults.suite)
    static let clamshellMicPreSwitchUID  = Key<String?>("clamshellMicPreSwitchUID", default: nil, suite: AppDefaults.suite)
    static let clamshellMicSwitchedToUID = Key<String?>("clamshellMicSwitchedToUID", default: nil, suite: AppDefaults.suite)

    // Meetings
    static let meetingRecordingEnabled   = Key<Bool>("meetingRecordingEnabled",   default: false, suite: AppDefaults.suite)
    static let meetingJoinPromptEnabled  = Key<Bool>("meetingJoinPromptEnabled",  default: true, suite: AppDefaults.suite)
    static let meetingAutoStartEnabled   = Key<Bool>("meetingAutoStartEnabled",   default: true, suite: AppDefaults.suite)
    static let meetingAutoStopEnabled    = Key<Bool>("meetingAutoStopEnabled",    default: true, suite: AppDefaults.suite)
    static let meetingUseCalendarHints   = Key<Bool>("meetingUseCalendarHints",   default: false, suite: AppDefaults.suite)
    static let meetingSaveAudio          = Key<Bool>("meetingSaveAudio",          default: false, suite: AppDefaults.suite)
    static let meetingUseSelectedMicrophone = Key<Bool>("meetingUseSelectedMicrophone", default: false, suite: AppDefaults.suite)
    static let meetingProcessScopedTapsEnabled = Key<Bool>("meetingProcessScopedTapsEnabled", default: false, suite: AppDefaults.suite)
    static let meetingTranscriptionBackend = Key<String>("meetingTranscriptionBackend", default: MeetingBackendKind.parakeet.rawValue, suite: AppDefaults.suite)
    static let meetingWebhookURL         = Key<String>("meetingWebhookURL",        default: "", suite: AppDefaults.suite)
    static let meetingWebhookEnabled     = Key<Bool>("meetingWebhookEnabled",      default: false, suite: AppDefaults.suite)
    static let meetingTranscriptEmailEnabled = Key<Bool>("meetingTranscriptEmailEnabled", default: false, suite: AppDefaults.suite)
    // Legacy storage only. Runtime reads/writes migrate this value to Keychain.
    static let meetingWebhookSecret      = Key<String>("meetingWebhookSecret",     default: "", suite: AppDefaults.suite)
    static let meetingCalendarHintsAutoEnabled = Key<Bool>("meetingCalendarHintsAutoEnabled", default: false, suite: AppDefaults.suite)
    static let meetingTimelineHiddenEventIDs = Key<[String]>("meetingTimelineHiddenEventIDs", default: [], suite: AppDefaults.suite)
    static let meetingTimelineIgnoredEventIDs = Key<[String]>("meetingTimelineIgnoredEventIDs", default: [], suite: AppDefaults.suite)
    static let meetingTimelineAutoRecordEventIDs = Key<[String]>("meetingTimelineAutoRecordEventIDs", default: [], suite: AppDefaults.suite)
    // MCP
    static let mcpServerEnabled          = Key<Bool>("mcpServerEnabled",          default: false, suite: AppDefaults.suite)

    // Local API
    static let localAPIEnabled           = Key<Bool>("localAPIEnabled",           default: false, suite: AppDefaults.suite)

    // Dormant BYOK prototype. It is intentionally not part of the Community settings surface.
    // static let byokEnabled               = Key<Bool>("byokEnabled",               default: false, suite: AppDefaults.suite)
    // static let byokProvider              = Key<String>("byokProvider",            default: "anthropic", suite: AppDefaults.suite)

    // Ambient context
    static let ambientContextEnabled     = Key<Bool>("ambientContextEnabled",     default: false, suite: AppDefaults.suite)
    static let ambientExcludedBundleIds  = Key<[String]>("ambientExcludedBundleIds", default: passwordManagerBundleIds, suite: AppDefaults.suite)

    // Privacy
    static let saveAudioEnabled          = Key<Bool>("saveAudioEnabled",          default: false, suite: AppDefaults.suite)
    static let workspaceCloudUploadEnabled = Key<Bool>("workspaceCloudUploadEnabled", default: false, suite: AppDefaults.suite)
    static let workspaceCloudTextLastSyncedAt = Key<Date?>("workspaceCloudTextLastSyncedAt", default: nil, suite: AppDefaults.suite)
    static let historyRetentionDays      = Key<Int>("historyRetentionDays",       default: 90, suite: AppDefaults.suite)
    static let contextMetadataEnabled    = Key<Bool>("contextMetadataEnabled",    default: false, suite: AppDefaults.suite)
    /// Device-local marker for the fail-closed migration from historical
    /// default-on privacy settings.
    static let privacyConsentSchemaVersion = Key<Int>("privacyConsentSchemaVersion", default: 0, suite: AppDefaults.suite)
    static let hipaaMode                 = Key<Bool>("hipaaMode",                 default: false, suite: AppDefaults.suite)
    /// Device-local consent. Intentionally omitted from WorkspaceSyncEngine's
    /// roaming settings snapshot and codec.
    static let cloudPersonalizationExamplesEnabled = Key<Bool>(
        "cloudPersonalizationExamplesEnabled",
        default: false,
        suite: AppDefaults.suite
    )

    // Display
    static let pinnedDisplayId           = Key<Int?>("pinnedDisplayId",           default: nil, suite: AppDefaults.suite)

    // Beta — opt-in flag synced to PostHog as the `beta_tester` person property.
    // PostHog cohort "Beta Testers" (ID 95985) auto-includes matching users.
    // Feature flags targeting that cohort gate beta-only functionality.
    static let betaTesterEnabled         = Key<Bool>("betaTesterEnabled",         default: false, suite: AppDefaults.suite)

    // Misc
    static let launchAtLogin             = Key<Bool>("launchAtLogin",             default: false, suite: AppDefaults.suite)
    static let crashDiagnosticsEnabled   = Key<Bool>("crashDiagnosticsEnabled",   default: false, suite: AppDefaults.suite)
    static let analyticsEnabled          = Key<Bool>("analyticsEnabled",          default: false, suite: AppDefaults.suite)
    static let authToken                 = Key<String?>("authToken",              default: nil, suite: AppDefaults.suite)
    static let userId                    = Key<String?>("userId",                 default: nil, suite: AppDefaults.suite)
    static let userEmail                 = Key<String?>("userEmail",              default: nil, suite: AppDefaults.suite)
    static let userDisplayName           = Key<String?>("userDisplayName",        default: nil, suite: AppDefaults.suite)
    static let postHogSettingsURL        = Key<String?>("postHogSettingsURL",     default: nil, suite: AppDefaults.suite)

    // UI State
    static let memoBannerDismissed       = Key<Bool>("memoBannerDismissed",       default: false, suite: AppDefaults.suite)
    static let journalBannerDismissed    = Key<Bool>("journalBannerDismissed",    default: false, suite: AppDefaults.suite)
    static let smartLinksIntroSeen       = Key<Bool>("smartLinksIntroSeen",       default: false, suite: AppDefaults.suite)
    static let memosIntroSeen            = Key<Bool>("memosIntroSeen",            default: false, suite: AppDefaults.suite)
    static let journalIntroSeen          = Key<Bool>("journalIntroSeen",          default: false, suite: AppDefaults.suite)
    static let journalRedesignEnabled    = Key<Bool>("journalRedesignEnabled",    default: false, suite: AppDefaults.suite)
    static let progressionIntroSeen     = Key<Bool>("progressionIntroSeen",     default: false, suite: AppDefaults.suite)
    static let dictionaryIntroSeen      = Key<Bool>("dictionaryIntroSeen",      default: false, suite: AppDefaults.suite)
    static let archiveInfoSeen           = Key<Bool>("archiveInfoSeen",           default: false, suite: AppDefaults.suite)
}

// MARK: - Manager

/// Stored-property @Observable wrapper around Defaults — required for @Bindable compatibility.
@MainActor
@Observable
final class SettingsManager {

    nonisolated private static let log = Logger.resonant("SettingsManager")

    static let shared = SettingsManager()
    nonisolated static let defaultHotWord = "paste it"
    nonisolated static let currentPrivacyConsentSchemaVersion = 1

    /// Historical releases defaulted these behaviors on, so a stored `true`
    /// has no reliable consent provenance. Fail them closed exactly once; the
    /// version marker preserves choices made after this migration.
    @discardableResult
    nonisolated static func applyPrivacyConsentMigration(
        to defaults: UserDefaults,
        targetVersion: Int = currentPrivacyConsentSchemaVersion
    ) -> Bool {
        let markerKey = "privacyConsentSchemaVersion"
        guard defaults.integer(forKey: markerKey) < targetVersion else { return false }

        for key in [
            "emailSignatureEnabled",
            "meetingSaveAudio",
            "saveAudioEnabled",
            "contextMetadataEnabled",
            "ambientContextEnabled",
            "crashDiagnosticsEnabled",
            "analyticsEnabled",
            "mcpServerEnabled",
            "localAPIEnabled",
        ] {
            defaults.set(false, forKey: key)
        }
        defaults.set(targetVersion, forKey: markerKey)
        return true
    }

    nonisolated static func effectiveCloudPersonalizationExamplesConsent(
        explicitConsent: Bool,
        hipaaMode: Bool
    ) -> Bool {
        explicitConsent && !hipaaMode
    }

    /// Used during initialization and exposed for deterministic migration
    /// tests. HIPAA mode revokes stored consent instead of merely making it
    /// dormant, so turning HIPAA mode off never silently restores sharing.
    @discardableResult
    nonisolated static func normalizeStoredCloudPersonalizationExamplesConsent() -> Bool {
        let normalized = effectiveCloudPersonalizationExamplesConsent(
            explicitConsent: Defaults[.cloudPersonalizationExamplesEnabled],
            hipaaMode: Defaults[.hipaaMode]
        )
        if Defaults[.cloudPersonalizationExamplesEnabled] != normalized {
            Defaults[.cloudPersonalizationExamplesEnabled] = normalized
        }
        return normalized
    }

    struct PersistedAuthState: Equatable {
        let authToken: String?
        let cloudAuthToken: String?
        let refreshToken: String?
        let shouldClearLegacyDefaultsAuthToken: Bool
        let shouldPersistUnifiedSessionImmediately: Bool
    }

    nonisolated static let defaultsBackedKeys: Set<String> = [
        "onboardingCompleted",
        "hotkeyTrigger",
        "hotkeyAlternateTriggers",
        "hotkeyMode",
        "hotkeyHoldLockEnabled",
        "selectedModelId",
        "transcriptionLanguage",
        "removeFillersEnabled",
        "removeFalseStartsEnabled",
        "itnEnabled",
        "autoPunctuationEnabled",
        "bulletPointsEnabled",
        "cloudProcessingEnabled",
        "selectionTransformEnabled",
        "journalSummarizationEnabled",
        "meetingSummarizationEnabled",
        "meetingSummaryStyle",
        "autoPasteEnabled",
        "copyToClipboardEnabled",
        "autoSendEnabled",
        "pasteDeliveryMode",
        "emailSignatureEnabled",
        "emailSignoffName",
        "soundsEnabled",
        "soundsVolume",

        "overlayMode",
        "notchIdleVisible",
        "notchHidden",
        "recoverableDictationIssueNoticesEnabled",
        "dictationOrbHue",
        "inputDeviceUID",
        "hotMicEnabled",
        "pauseMediaWhileRecording",
        "duckSystemAudioWhileRecording",
        "hotWord",
        "dispatchEnabled",
        "dispatchTTSEnabled",
        "dispatchCloudFallbackEnabled",
        "lowLatencyMode",
        "clamshellMicSwitchEnabled",
        "saveAudioEnabled",
        "workspaceCloudUploadEnabled",
        "workspaceCloudTextLastSyncedAt",
        "historyRetentionDays",
        "contextMetadataEnabled",
        "hipaaMode",
        "cloudPersonalizationExamplesEnabled",
        "privacyConsentSchemaVersion",
        "pinnedDisplayId",
        "launchAtLogin",
        "crashDiagnosticsEnabled",
        "analyticsEnabled",
        "userId",
        "userEmail",
        "userDisplayName",
        "postHogSettingsURL",
        "memoBannerDismissed",
        "journalBannerDismissed",
        "smartLinksIntroSeen",
        "memosIntroSeen",
        "journalIntroSeen",
        "journalRedesignEnabled",
        "progressionIntroSeen",
        "dictionaryIntroSeen",
        "archiveInfoSeen",
        "meetingRecordingEnabled",
        "meetingJoinPromptEnabled",
        "meetingAutoStartEnabled",
        "meetingAutoStopEnabled",
        "meetingUseCalendarHints",
        "meetingSaveAudio",
        "meetingUseSelectedMicrophone",
        "meetingProcessScopedTapsEnabled",
        "meetingTranscriptionBackend",
        "meetingWebhookURL",
        "meetingWebhookEnabled",
        "meetingTranscriptEmailEnabled",
        "meetingTimelineHiddenEventIDs",
        "meetingTimelineIgnoredEventIDs",
        "meetingTimelineAutoRecordEventIDs",
        "mcpServerEnabled",
        "localAPIEnabled",
        // "byokEnabled",
        // "byokProvider",
        "ambientContextEnabled",
        "ambientExcludedBundleIds",
        "betaTesterEnabled",
    ]

    // Onboarding
    var onboardingCompleted: Bool        { didSet { Defaults[.onboardingCompleted]  = onboardingCompleted } }

    // Hotkey
    var hotkeyTrigger: HotkeyTrigger {
        didSet {
            let normalizedPrimary = Self.normalizedHotkeyPrimary(hotkeyTrigger)
            if normalizedPrimary != hotkeyTrigger {
                hotkeyTrigger = normalizedPrimary
                return
            }
            Defaults[.hotkeyTrigger] = hotkeyTrigger.rawValue
            let normalizedAlternates = Self.normalizedHotkeyAlternates(hotkeyAlternateTriggers, excluding: hotkeyTrigger)
            if normalizedAlternates != hotkeyAlternateTriggers {
                hotkeyAlternateTriggers = normalizedAlternates
            }
        }
    }
    var hotkeyAlternateTriggers: [HotkeyTrigger] {
        didSet {
            let normalizedAlternates = Self.normalizedHotkeyAlternates(hotkeyAlternateTriggers, excluding: hotkeyTrigger)
            if normalizedAlternates != hotkeyAlternateTriggers {
                hotkeyAlternateTriggers = normalizedAlternates
                return
            }
            Defaults[.hotkeyAlternateTriggers] = normalizedAlternates.map(\.rawValue)
        }
    }
    var hotkeyMode: HotkeyMode           { didSet { Defaults[.hotkeyMode]            = hotkeyMode.rawValue } }
    var hotkeyHoldLockEnabled: Bool      { didSet { Defaults[.hotkeyHoldLockEnabled] = hotkeyHoldLockEnabled } }

    // Model
    var selectedModelId: String          { didSet { Defaults[.selectedModelId]       = selectedModelId } }
    var transcriptionLanguage: String    { didSet { Defaults[.transcriptionLanguage] = transcriptionLanguage } }

    // Text processing
    var removeFillersEnabled: Bool       { didSet { Defaults[.removeFillersEnabled]     = removeFillersEnabled } }
    var removeFalseStartsEnabled: Bool   { didSet { Defaults[.removeFalseStartsEnabled] = removeFalseStartsEnabled } }
    var itnEnabled: Bool                 { didSet { Defaults[.itnEnabled]               = itnEnabled } }
    /// Recognition-level biasing toward dictionary/learned words (Parakeet +
    /// CTC helper model). On by default, but automatic acquisition remains
    /// lazy until the live adapter, language, latency, and term gates can use
    /// the optional 98 MB helper. Every attempt still fails open to the
    /// original decode while assets are absent.
    var vocabularyBoostEnabled: Bool     { didSet { Defaults[.vocabularyBoostEnabled]   = vocabularyBoostEnabled } }
    /// Live streaming transcript in the notch while dictating (cosmetic; the
    /// delivered text still comes from the batch decode at stop).
    var liveTranscriptPreviewEnabled: Bool {
        didSet {
            Defaults[.liveTranscriptPreviewEnabled] = liveTranscriptPreviewEnabled
            NotificationCenter.default.post(name: .liveTranscriptPreviewChanged, object: nil)
        }
    }
    var autoPunctuationEnabled: Bool     { didSet { Defaults[.autoPunctuationEnabled]   = autoPunctuationEnabled } }
    var bulletPointsEnabled: Bool        { didSet { Defaults[.bulletPointsEnabled]      = bulletPointsEnabled } }
    var cloudProcessingEnabled: Bool {
        didSet {
            Defaults[.cloudProcessingEnabled] = cloudProcessingEnabled
            NotificationCenter.default.post(name: .cloudProcessingEnabledChanged, object: nil)
        }
    }
    /// Per-surface cleanup latitude (chat / email / everything else).
    var polishLevelChat: DictationPolishLevel  { didSet { Defaults[.polishLevelChat]  = polishLevelChat.rawValue } }
    var polishLevelEmail: DictationPolishLevel { didSet { Defaults[.polishLevelEmail] = polishLevelEmail.rawValue } }
    var polishLevelOther: DictationPolishLevel { didSet { Defaults[.polishLevelOther] = polishLevelOther.rawValue } }
    var dictationPolishSettings: DictationPolishSettings {
        DictationPolishSettings(chat: polishLevelChat, email: polishLevelEmail, other: polishLevelOther)
    }
    var selectionTransformEnabled: Bool  { didSet { Defaults[.selectionTransformEnabled] = selectionTransformEnabled } }
    var journalSummarizationEnabled: Bool { didSet { Defaults[.journalSummarizationEnabled] = journalSummarizationEnabled } }
    var meetingSummarizationEnabled: Bool {
        didSet {
            Defaults[.meetingSummarizationEnabled] = meetingSummarizationEnabled
            NotificationCenter.default.post(name: .workspaceRoamingSettingsChanged, object: nil)
        }
    }
    var meetingSummaryStyle: MeetingSummaryStyle {
        didSet { Defaults[.meetingSummaryStyle] = meetingSummaryStyle.rawValue }
    }
    // Output
    var autoPasteEnabled: Bool           { didSet { Defaults[.autoPasteEnabled]         = autoPasteEnabled } }
    var copyToClipboardEnabled: Bool     { didSet { Defaults[.copyToClipboardEnabled]   = copyToClipboardEnabled } }
    var autoSendEnabled: Bool            { didSet { Defaults[.autoSendEnabled]           = autoSendEnabled } }
    var pasteDeliveryMode: PasteDeliveryMode { didSet { Defaults[.pasteDeliveryMode]     = pasteDeliveryMode.rawValue } }
    var emailSignatureEnabled: Bool      { didSet { Defaults[.emailSignatureEnabled]    = emailSignatureEnabled } }
    var emailSignoffName: String?        { didSet { Defaults[.emailSignoffName]         = emailSignoffName?.trimmedNilIfEmpty } }

    // Appearance
    var overlayMode: OverlayMode         { didSet { Defaults[.overlayMode]              = overlayMode.rawValue } }
    var soundsEnabled: Bool              { didSet { Defaults[.soundsEnabled]            = soundsEnabled } }
    var soundsVolume: Double             { didSet { Defaults[.soundsVolume]             = soundsVolume } }

    var notchIdleVisible: Bool {
        didSet {
            Defaults[.notchIdleVisible] = notchIdleVisible
            NotificationCenter.default.post(name: .notchIdleVisibleChanged, object: nil)
        }
    }

    var notchHidden: Bool {
        didSet {
            Defaults[.notchHidden] = notchHidden
            NotificationCenter.default.post(name: .notchHiddenChanged, object: nil)
        }
    }

    var recoverableDictationIssueNoticesEnabled: Bool {
        didSet { Defaults[.recoverableDictationIssueNoticesEnabled] = recoverableDictationIssueNoticesEnabled }
    }

    var dictationOrbHue: Double          { didSet { Defaults[.dictationOrbHue]        = dictationOrbHue } }

    // Audio
    var inputDeviceUID: String?          { didSet { Defaults[.inputDeviceUID]           = inputDeviceUID } }
    var hotMicEnabled: Bool {
        didSet {
            Defaults[.hotMicEnabled] = hotMicEnabled
            NotificationCenter.default.post(name: .hotMicEnabledChanged, object: nil)
        }
    }
    var pauseMediaWhileRecording: Bool {
        didSet {
            Defaults[.pauseMediaWhileRecording] = pauseMediaWhileRecording
            NotificationCenter.default.post(name: .workspaceRoamingSettingsChanged, object: nil)
        }
    }
    var duckSystemAudioWhileRecording: Bool {
        didSet {
            Defaults[.duckSystemAudioWhileRecording] = duckSystemAudioWhileRecording
            NotificationCenter.default.post(name: .workspaceRoamingSettingsChanged, object: nil)
        }
    }
    var hotWord: String                  { didSet { Defaults[.hotWord]                 = hotWord } }
    var dispatchEnabled: Bool {
        didSet {
            Defaults[.dispatchEnabled] = dispatchEnabled
            NotificationCenter.default.post(name: .dispatchEnabledChanged, object: nil)
        }
    }
    var dispatchTTSEnabled: Bool         { didSet { Defaults[.dispatchTTSEnabled]      = dispatchTTSEnabled } }
    var dispatchCloudFallbackEnabled: Bool { didSet { Defaults[.dispatchCloudFallbackEnabled] = dispatchCloudFallbackEnabled } }
    var lowLatencyMode: Bool {
        didSet {
            Defaults[.lowLatencyMode] = lowLatencyMode
            NotificationCenter.default.post(name: .lowLatencyModeChanged, object: nil)
        }
    }
    var clamshellMicSwitchEnabled: Bool {
        didSet {
            Defaults[.clamshellMicSwitchEnabled] = clamshellMicSwitchEnabled
            NotificationCenter.default.post(name: .clamshellMicSwitchEnabledChanged, object: nil)
        }
    }

    // Privacy
    var saveAudioEnabled: Bool           { didSet { Defaults[.saveAudioEnabled]         = saveAudioEnabled } }
    var workspaceCloudUploadEnabled: Bool {
        get { AppFeatureVisibility.cloudSync && workspaceCloudUploadEnabledStorage }
        set {
            workspaceCloudUploadEnabledStorage = AppFeatureVisibility.cloudSync && newValue
            Defaults[.workspaceCloudUploadEnabled] = workspaceCloudUploadEnabledStorage
        }
    }
    private var workspaceCloudUploadEnabledStorage = false
    var historyRetentionDays: Int {
        didSet {
            Defaults[.historyRetentionDays] = historyRetentionDays
            guard historyRetentionDays != oldValue else { return }
            NotificationCenter.default.post(name: .historyRetentionDaysChanged, object: nil)
        }
    }
    var contextMetadataEnabled: Bool {
        didSet {
            Defaults[.contextMetadataEnabled] = contextMetadataEnabled
            NotificationCenter.default.post(name: .contextMetadataEnabledChanged, object: nil)
        }
    }
    var hipaaMode: Bool {
        didSet {
            Defaults[.hipaaMode] = hipaaMode
            if hipaaMode {
                cloudPersonalizationExamplesEnabled = false
                Defaults[.cloudPersonalizationExamplesEnabled] = false
            }
            NotificationCenter.default.post(name: .sentryDiagnosticsConfigurationChanged, object: nil)
        }
    }
    var cloudPersonalizationExamplesEnabled: Bool {
        didSet {
            if hipaaMode && cloudPersonalizationExamplesEnabled {
                cloudPersonalizationExamplesEnabled = false
                Defaults[.cloudPersonalizationExamplesEnabled] = false
                return
            }
            Defaults[.cloudPersonalizationExamplesEnabled] = cloudPersonalizationExamplesEnabled
        }
    }
    var effectiveCloudPersonalizationExamplesEnabled: Bool {
        Self.effectiveCloudPersonalizationExamplesConsent(
            explicitConsent: cloudPersonalizationExamplesEnabled,
            hipaaMode: hipaaMode
        )
    }

    // Display
    var pinnedDisplayId: Int?            { didSet { Defaults[.pinnedDisplayId]          = pinnedDisplayId } }

    // Beta
    var betaTesterEnabled: Bool {
        didSet {
            Defaults[.betaTesterEnabled] = betaTesterEnabled
            NotificationCenter.default.post(name: .betaTesterEnabledChanged, object: nil)
        }
    }

    // Misc
    var launchAtLogin: Bool {
        didSet {
            Defaults[.launchAtLogin] = launchAtLogin
            if LaunchAtLogin.isEnabled != launchAtLogin {
                LaunchAtLogin.isEnabled = launchAtLogin
            }
        }
    }
    var crashDiagnosticsEnabled: Bool {
        didSet {
            Defaults[.crashDiagnosticsEnabled] = crashDiagnosticsEnabled
            NotificationCenter.default.post(name: .sentryDiagnosticsConfigurationChanged, object: nil)
        }
    }
    var analyticsEnabled: Bool           { didSet { Defaults[.analyticsEnabled]         = analyticsEnabled } }
    var authToken: String?               { didSet { persistAuthSession() } }
    var cloudAuthToken: String?          { didSet { persistAuthSession() } }
    var refreshToken: String?            { didSet { persistAuthSession() } }
    var userId: String?                  { didSet { Defaults[.userId]                   = userId } }
    var userEmail: String?               { didSet { Defaults[.userEmail]               = userEmail } }
    var userDisplayName: String?         { didSet { Defaults[.userDisplayName]         = userDisplayName?.trimmedNilIfEmpty } }
    var postHogSettingsURL: String?      { didSet { Defaults[.postHogSettingsURL]      = postHogSettingsURL } }

    // UI State
    var memoBannerDismissed: Bool        { didSet { Defaults[.memoBannerDismissed]     = memoBannerDismissed } }
    var journalBannerDismissed: Bool     { didSet { Defaults[.journalBannerDismissed]  = journalBannerDismissed } }
    var smartLinksIntroSeen: Bool        { didSet { Defaults[.smartLinksIntroSeen]     = smartLinksIntroSeen } }
    var memosIntroSeen: Bool             { didSet { Defaults[.memosIntroSeen]          = memosIntroSeen } }
    var journalIntroSeen: Bool           { didSet { Defaults[.journalIntroSeen]        = journalIntroSeen } }
    var journalRedesignEnabled: Bool     { didSet { Defaults[.journalRedesignEnabled]  = journalRedesignEnabled } }
    var progressionIntroSeen: Bool      { didSet { Defaults[.progressionIntroSeen]   = progressionIntroSeen } }
    var dictionaryIntroSeen: Bool       { didSet { Defaults[.dictionaryIntroSeen]    = dictionaryIntroSeen } }
    var archiveInfoSeen: Bool            { didSet { Defaults[.archiveInfoSeen]          = archiveInfoSeen } }

    // Meetings
    var meetingRecordingEnabled: Bool {
        didSet {
            Defaults[.meetingRecordingEnabled] = meetingRecordingEnabled
            NotificationCenter.default.post(name: .meetingRecordingEnabledChanged, object: nil)
            NotificationCenter.default.post(name: .workspaceRoamingSettingsChanged, object: nil)
        }
    }
    var meetingJoinPromptEnabled: Bool {
        didSet {
            Defaults[.meetingJoinPromptEnabled] = meetingJoinPromptEnabled
            NotificationCenter.default.post(name: .meetingJoinPromptEnabledChanged, object: nil)
            NotificationCenter.default.post(name: .workspaceRoamingSettingsChanged, object: nil)
        }
    }
    var meetingAutoStartEnabled: Bool {
        didSet {
            Defaults[.meetingAutoStartEnabled] = meetingAutoStartEnabled
            NotificationCenter.default.post(name: .meetingAutoStartEnabledChanged, object: nil)
            NotificationCenter.default.post(name: .workspaceRoamingSettingsChanged, object: nil)
        }
    }
    var meetingAutoStopEnabled: Bool {
        didSet {
            Defaults[.meetingAutoStopEnabled] = meetingAutoStopEnabled
            NotificationCenter.default.post(name: .meetingAutoStopEnabledChanged, object: nil)
            NotificationCenter.default.post(name: .workspaceRoamingSettingsChanged, object: nil)
        }
    }
    var meetingUseCalendarHints: Bool {
        didSet {
            Defaults[.meetingUseCalendarHints] = meetingUseCalendarHints
            NotificationCenter.default.post(name: .meetingCalendarHintsEnabledChanged, object: nil)
            NotificationCenter.default.post(name: .workspaceRoamingSettingsChanged, object: nil)
        }
    }
    var meetingSaveAudio: Bool {
        didSet {
            Defaults[.meetingSaveAudio] = meetingSaveAudio
            NotificationCenter.default.post(name: .workspaceRoamingSettingsChanged, object: nil)
        }
    }
    var meetingUseSelectedMicrophone: Bool {
        didSet {
            Defaults[.meetingUseSelectedMicrophone] = meetingUseSelectedMicrophone
        }
    }
    var meetingProcessScopedTapsEnabled: Bool {
        didSet {
            Defaults[.meetingProcessScopedTapsEnabled] = meetingProcessScopedTapsEnabled
        }
    }
    var meetingTranscriptionBackend: MeetingBackendKind {
        didSet {
            Defaults[.meetingTranscriptionBackend] = meetingTranscriptionBackend.rawValue
        }
    }
    var meetingWebhookURL: String {
        didSet {
            Defaults[.meetingWebhookURL] = meetingWebhookURL
            NotificationCenter.default.post(name: .workspaceRoamingSettingsChanged, object: nil)
        }
    }
    var meetingWebhookEnabled: Bool {
        didSet {
            Defaults[.meetingWebhookEnabled] = meetingWebhookEnabled
            NotificationCenter.default.post(name: .workspaceRoamingSettingsChanged, object: nil)
        }
    }
    var meetingTranscriptEmailEnabled: Bool {
        didSet {
            Defaults[.meetingTranscriptEmailEnabled] = meetingTranscriptEmailEnabled
            NotificationCenter.default.post(name: .workspaceRoamingSettingsChanged, object: nil)
        }
    }
    var meetingWebhookSecret: String {
        didSet {
            guard !isNormalizingMeetingWebhookSecret else { return }
            persistMeetingWebhookSecret()
            NotificationCenter.default.post(name: .workspaceRoamingSettingsChanged, object: nil)
        }
    }
    var meetingTimelineHiddenEventIDs: [String] {
        didSet {
            Defaults[.meetingTimelineHiddenEventIDs] = meetingTimelineHiddenEventIDs
        }
    }
    var meetingTimelineIgnoredEventIDs: [String] {
        didSet {
            Defaults[.meetingTimelineIgnoredEventIDs] = meetingTimelineIgnoredEventIDs
        }
    }
    var meetingTimelineAutoRecordEventIDs: [String] {
        didSet {
            Defaults[.meetingTimelineAutoRecordEventIDs] = meetingTimelineAutoRecordEventIDs
            NotificationCenter.default.post(name: .meetingTimelineAutoRecordEventIDsChanged, object: nil)
        }
    }

    // MCP
    var mcpServerEnabled: Bool {
        didSet {
            Defaults[.mcpServerEnabled] = mcpServerEnabled
            NotificationCenter.default.post(name: .mcpServerEnabledChanged, object: nil)
        }
    }

    // Local API
    var localAPIEnabled: Bool {
        didSet {
            Defaults[.localAPIEnabled] = localAPIEnabled
            NotificationCenter.default.post(name: .localAPIEnabledChanged, object: nil)
        }
    }

    // BYOK
    /*
    var byokEnabled: Bool {
        didSet { Defaults[.byokEnabled] = byokEnabled }
    }
    var byokProvider: BYOKProvider {
        didSet { Defaults[.byokProvider] = byokProvider.rawValue }
    }
    var byokAPIKey: String {
        get { KeychainHelper.read(key: Self.byokAPIKeyKey) ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                KeychainHelper.delete(key: Self.byokAPIKeyKey)
            } else {
                KeychainHelper.save(key: Self.byokAPIKeyKey, value: trimmed)
            }
        }
    }
    private static let byokAPIKeyKey = "byokAPIKey"
    */

    nonisolated static let meetingWebhookSecretKey = "meetingWebhookSecret"
    private var isNormalizingMeetingWebhookSecret = false

    // Ambient context
    var ambientContextEnabled: Bool {
        didSet {
            Defaults[.ambientContextEnabled] = ambientContextEnabled
            NotificationCenter.default.post(name: .ambientContextEnabledChanged, object: nil)
        }
    }
    var ambientExcludedBundleIds: [String] {
        didSet { Defaults[.ambientExcludedBundleIds] = ambientExcludedBundleIds }
    }

    private init() {
        Self.applyPrivacyConsentMigration(to: AppDefaults.suite)
        let initialHIPAAMode = Defaults[.hipaaMode]
        let initialCloudPersonalizationExamplesEnabled =
            Self.normalizeStoredCloudPersonalizationExamplesConsent()
        let initialHotkeyTrigger = Self.normalizedHotkeyPrimary(
            HotkeyTrigger(rawValue: Defaults[.hotkeyTrigger]) ?? .fn
        )
        let initialHotkeyAlternateTriggers = Self.normalizedHotkeyAlternates(
            Defaults[.hotkeyAlternateTriggers].compactMap(HotkeyTrigger.init(rawValue:)),
            excluding: initialHotkeyTrigger
        )
        onboardingCompleted      = Defaults[.onboardingCompleted]
        hotkeyTrigger            = initialHotkeyTrigger
        hotkeyAlternateTriggers  = initialHotkeyAlternateTriggers
        if Defaults[.hotkeyTrigger] != initialHotkeyTrigger.rawValue {
            Defaults[.hotkeyTrigger] = initialHotkeyTrigger.rawValue
        }
        let normalizedAlternateRawValues = initialHotkeyAlternateTriggers.map(\.rawValue)
        if Defaults[.hotkeyAlternateTriggers] != normalizedAlternateRawValues {
            Defaults[.hotkeyAlternateTriggers] = normalizedAlternateRawValues
        }
        hotkeyMode               = (HotkeyMode(rawValue: Defaults[.hotkeyMode]) ?? .hold).normalized
        hotkeyHoldLockEnabled    = Defaults[.hotkeyHoldLockEnabled]
        selectedModelId          = Defaults[.selectedModelId]
        transcriptionLanguage   = Defaults[.transcriptionLanguage]
        removeFillersEnabled     = Defaults[.removeFillersEnabled]
        removeFalseStartsEnabled = Defaults[.removeFalseStartsEnabled]
        itnEnabled               = Defaults[.itnEnabled]
        vocabularyBoostEnabled   = Defaults[.vocabularyBoostEnabled]
        liveTranscriptPreviewEnabled = Defaults[.liveTranscriptPreviewEnabled]
        autoPunctuationEnabled   = Defaults[.autoPunctuationEnabled]
        bulletPointsEnabled      = Defaults[.bulletPointsEnabled]
        cloudProcessingEnabled   = Defaults[.cloudProcessingEnabled]
        polishLevelChat          = DictationPolishLevel(rawValue: Defaults[.polishLevelChat]) ?? .clean
        polishLevelEmail         = DictationPolishLevel(rawValue: Defaults[.polishLevelEmail]) ?? .clean
        polishLevelOther         = DictationPolishLevel(rawValue: Defaults[.polishLevelOther]) ?? .clean
        journalSummarizationEnabled = Defaults[.journalSummarizationEnabled]
        meetingSummarizationEnabled = Defaults[.meetingSummarizationEnabled]
        meetingSummaryStyle = MeetingSummaryStyle(rawValue: Defaults[.meetingSummaryStyle]) ?? .standard
        selectionTransformEnabled = Defaults[.selectionTransformEnabled]
        autoPasteEnabled         = Defaults[.autoPasteEnabled]
        copyToClipboardEnabled   = Defaults[.copyToClipboardEnabled]
        autoSendEnabled          = Defaults[.autoSendEnabled]
        pasteDeliveryMode        = PasteDeliveryMode(rawValue: Defaults[.pasteDeliveryMode]) ?? .automatic
        emailSignatureEnabled    = Defaults[.emailSignatureEnabled]
        emailSignoffName         = Defaults[.emailSignoffName]
        overlayMode              = OverlayMode(rawValue: Defaults[.overlayMode]) ?? .notch
        soundsEnabled            = Defaults[.soundsEnabled]
        soundsVolume             = Defaults[.soundsVolume]

        notchIdleVisible         = Defaults[.notchIdleVisible]
        notchHidden              = Defaults[.notchHidden]
        recoverableDictationIssueNoticesEnabled = Defaults[.recoverableDictationIssueNoticesEnabled]
        dictationOrbHue          = Defaults[.dictationOrbHue]
        inputDeviceUID           = Defaults[.inputDeviceUID]
        hotMicEnabled            = Defaults[.hotMicEnabled]
        pauseMediaWhileRecording = Defaults[.pauseMediaWhileRecording]
        duckSystemAudioWhileRecording = Defaults[.duckSystemAudioWhileRecording]
        hotWord                  = Defaults[.hotWord]
        dispatchEnabled          = Defaults[.dispatchEnabled]
        dispatchTTSEnabled       = Defaults[.dispatchTTSEnabled]
        dispatchCloudFallbackEnabled = Defaults[.dispatchCloudFallbackEnabled]
        lowLatencyMode           = Defaults[.lowLatencyMode]
        clamshellMicSwitchEnabled = Defaults[.clamshellMicSwitchEnabled]
        saveAudioEnabled         = Defaults[.saveAudioEnabled]
        workspaceCloudUploadEnabledStorage = AppFeatureVisibility.cloudSync && Defaults[.workspaceCloudUploadEnabled]
        if !AppFeatureVisibility.cloudSync {
            Defaults[.workspaceCloudUploadEnabled] = false
        }
        historyRetentionDays     = Defaults[.historyRetentionDays]
        contextMetadataEnabled   = Defaults[.contextMetadataEnabled]
        hipaaMode                = initialHIPAAMode
        cloudPersonalizationExamplesEnabled = initialCloudPersonalizationExamplesEnabled
        pinnedDisplayId          = Defaults[.pinnedDisplayId]
        betaTesterEnabled        = Defaults[.betaTesterEnabled]
        launchAtLogin            = Defaults[.launchAtLogin]
        crashDiagnosticsEnabled  = Defaults[.crashDiagnosticsEnabled]
        analyticsEnabled         = Defaults[.analyticsEnabled]
        let persistedAuthState = Self.resolvePersistedAuthState(
            unifiedSession: KeychainHelper.readAuthSession(),
            legacyDefaultsAuthToken: Defaults[.authToken],
            legacyAuthToken: KeychainHelper.read(key: "authToken"),
            legacyCloudAuthToken: KeychainHelper.read(key: "cloudAuthToken"),
            legacyRefreshToken: KeychainHelper.read(key: "refreshToken")
        )
        if persistedAuthState.shouldClearLegacyDefaultsAuthToken {
            Defaults[.authToken] = nil
        }
        authToken                = persistedAuthState.authToken
        cloudAuthToken           = persistedAuthState.cloudAuthToken
        refreshToken             = persistedAuthState.refreshToken
        if persistedAuthState.shouldPersistUnifiedSessionImmediately {
            KeychainHelper.saveAuthSession(
                Self.makeAuthSession(
                    authToken: persistedAuthState.authToken,
                    cloudAuthToken: persistedAuthState.cloudAuthToken,
                    refreshToken: persistedAuthState.refreshToken
                )
            )
        }
        userId                   = Defaults[.userId]
        userEmail                = Defaults[.userEmail]
        userDisplayName          = Defaults[.userDisplayName]
        postHogSettingsURL       = Defaults[.postHogSettingsURL]
        memoBannerDismissed      = Defaults[.memoBannerDismissed]
        journalBannerDismissed   = Defaults[.journalBannerDismissed]
        smartLinksIntroSeen      = Defaults[.smartLinksIntroSeen]
        memosIntroSeen           = Defaults[.memosIntroSeen]
        journalIntroSeen         = Defaults[.journalIntroSeen]
        journalRedesignEnabled   = Defaults[.journalRedesignEnabled]
        progressionIntroSeen    = Defaults[.progressionIntroSeen]
        dictionaryIntroSeen     = Defaults[.dictionaryIntroSeen]
        archiveInfoSeen          = Defaults[.archiveInfoSeen]
        meetingRecordingEnabled  = Defaults[.meetingRecordingEnabled]
        meetingJoinPromptEnabled = Defaults[.meetingJoinPromptEnabled]
        meetingAutoStartEnabled  = Defaults[.meetingAutoStartEnabled]
        meetingAutoStopEnabled   = Defaults[.meetingAutoStopEnabled]
        meetingUseCalendarHints  = Defaults[.meetingUseCalendarHints]
        meetingSaveAudio         = Defaults[.meetingSaveAudio]
        meetingUseSelectedMicrophone = Defaults[.meetingUseSelectedMicrophone]
        meetingProcessScopedTapsEnabled = Defaults[.meetingProcessScopedTapsEnabled]
        let persistedBackend = MeetingBackendKind(rawValue: Defaults[.meetingTranscriptionBackend]) ?? .parakeet
        meetingTranscriptionBackend = persistedBackend.isAvailable ? persistedBackend : .parakeet
        meetingWebhookURL        = Defaults[.meetingWebhookURL]
        meetingWebhookEnabled    = Defaults[.meetingWebhookEnabled]
        meetingTranscriptEmailEnabled = Defaults[.meetingTranscriptEmailEnabled]
        meetingWebhookSecret     = Self.resolvedMeetingWebhookSecret(legacyDefaultsValue: Defaults[.meetingWebhookSecret])
        meetingTimelineHiddenEventIDs = Defaults[.meetingTimelineHiddenEventIDs]
        meetingTimelineIgnoredEventIDs = Defaults[.meetingTimelineIgnoredEventIDs]
        meetingTimelineAutoRecordEventIDs = Defaults[.meetingTimelineAutoRecordEventIDs]
        mcpServerEnabled         = Defaults[.mcpServerEnabled]
        localAPIEnabled          = Defaults[.localAPIEnabled]
        // byokEnabled              = Defaults[.byokEnabled]
        // byokProvider             = BYOKProvider(rawValue: Defaults[.byokProvider]) ?? .anthropic
        ambientContextEnabled    = Defaults[.ambientContextEnabled]
        ambientExcludedBundleIds = Defaults[.ambientExcludedBundleIds]
    }

    func synchronizeLaunchAtLoginState() {
        let isEnabled = LaunchAtLogin.isEnabled
        if launchAtLogin != isEnabled {
            launchAtLogin = isEnabled
        } else {
            Defaults[.launchAtLogin] = isEnabled
        }
    }

    func persistUserDefaultsBackedValues() {
        Defaults[.onboardingCompleted] = onboardingCompleted
        Defaults[.hotkeyTrigger] = hotkeyTrigger.rawValue
        Defaults[.hotkeyAlternateTriggers] = hotkeyAlternateTriggers.map(\.rawValue)
        Defaults[.hotkeyMode] = hotkeyMode.rawValue
        Defaults[.hotkeyHoldLockEnabled] = hotkeyHoldLockEnabled
        Defaults[.selectedModelId] = selectedModelId
        Defaults[.transcriptionLanguage] = transcriptionLanguage
        Defaults[.removeFillersEnabled] = removeFillersEnabled
        Defaults[.removeFalseStartsEnabled] = removeFalseStartsEnabled
        Defaults[.itnEnabled] = itnEnabled
        Defaults[.autoPunctuationEnabled] = autoPunctuationEnabled
        Defaults[.bulletPointsEnabled] = bulletPointsEnabled
        Defaults[.cloudProcessingEnabled] = cloudProcessingEnabled
        Defaults[.selectionTransformEnabled] = selectionTransformEnabled
        Defaults[.journalSummarizationEnabled] = journalSummarizationEnabled
        Defaults[.meetingSummarizationEnabled] = meetingSummarizationEnabled
        Defaults[.meetingSummaryStyle] = meetingSummaryStyle.rawValue
        Defaults[.autoPasteEnabled] = autoPasteEnabled
        Defaults[.copyToClipboardEnabled] = copyToClipboardEnabled
        Defaults[.autoSendEnabled] = autoSendEnabled
        Defaults[.pasteDeliveryMode] = pasteDeliveryMode.rawValue
        Defaults[.emailSignatureEnabled] = emailSignatureEnabled
        Defaults[.emailSignoffName] = emailSignoffName?.trimmedNilIfEmpty
        Defaults[.overlayMode] = overlayMode.rawValue
        Defaults[.soundsEnabled] = soundsEnabled
        Defaults[.soundsVolume] = soundsVolume

        Defaults[.notchIdleVisible] = notchIdleVisible
        Defaults[.notchHidden] = notchHidden
        Defaults[.recoverableDictationIssueNoticesEnabled] = recoverableDictationIssueNoticesEnabled
        Defaults[.dictationOrbHue] = dictationOrbHue
        Defaults[.inputDeviceUID] = inputDeviceUID
        Defaults[.hotMicEnabled] = hotMicEnabled
        Defaults[.pauseMediaWhileRecording] = pauseMediaWhileRecording
        Defaults[.duckSystemAudioWhileRecording] = duckSystemAudioWhileRecording
        Defaults[.hotWord] = hotWord
        Defaults[.dispatchEnabled] = dispatchEnabled
        Defaults[.dispatchTTSEnabled] = dispatchTTSEnabled
        Defaults[.dispatchCloudFallbackEnabled] = dispatchCloudFallbackEnabled
        Defaults[.lowLatencyMode] = lowLatencyMode
        Defaults[.clamshellMicSwitchEnabled] = clamshellMicSwitchEnabled
        Defaults[.saveAudioEnabled] = saveAudioEnabled
        Defaults[.workspaceCloudUploadEnabled] = workspaceCloudUploadEnabled
        Defaults[.historyRetentionDays] = historyRetentionDays
        Defaults[.contextMetadataEnabled] = contextMetadataEnabled
        Defaults[.hipaaMode] = hipaaMode
        Defaults[.cloudPersonalizationExamplesEnabled] = effectiveCloudPersonalizationExamplesEnabled
        Defaults[.pinnedDisplayId] = pinnedDisplayId
        Defaults[.betaTesterEnabled] = betaTesterEnabled
        Defaults[.launchAtLogin] = launchAtLogin
        Defaults[.crashDiagnosticsEnabled] = crashDiagnosticsEnabled
        Defaults[.analyticsEnabled] = analyticsEnabled
        Defaults[.userId] = userId
        Defaults[.userEmail] = userEmail
        Defaults[.userDisplayName] = userDisplayName?.trimmedNilIfEmpty
        Defaults[.postHogSettingsURL] = postHogSettingsURL
        Defaults[.memoBannerDismissed] = memoBannerDismissed
        Defaults[.journalBannerDismissed] = journalBannerDismissed
        Defaults[.smartLinksIntroSeen] = smartLinksIntroSeen
        Defaults[.memosIntroSeen] = memosIntroSeen
        Defaults[.journalIntroSeen] = journalIntroSeen
        Defaults[.journalRedesignEnabled] = journalRedesignEnabled
        Defaults[.progressionIntroSeen] = progressionIntroSeen
        Defaults[.dictionaryIntroSeen] = dictionaryIntroSeen
        Defaults[.archiveInfoSeen] = archiveInfoSeen
        Defaults[.meetingRecordingEnabled] = meetingRecordingEnabled
        Defaults[.meetingJoinPromptEnabled] = meetingJoinPromptEnabled
        Defaults[.meetingAutoStartEnabled] = meetingAutoStartEnabled
        Defaults[.meetingAutoStopEnabled] = meetingAutoStopEnabled
        Defaults[.meetingUseCalendarHints] = meetingUseCalendarHints
        Defaults[.meetingSaveAudio] = meetingSaveAudio
        Defaults[.meetingUseSelectedMicrophone] = meetingUseSelectedMicrophone
        Defaults[.meetingProcessScopedTapsEnabled] = meetingProcessScopedTapsEnabled
        Defaults[.meetingTranscriptionBackend] = meetingTranscriptionBackend.rawValue
        Defaults[.meetingWebhookURL] = meetingWebhookURL
        Defaults[.meetingWebhookEnabled] = meetingWebhookEnabled
        Defaults[.meetingTranscriptEmailEnabled] = meetingTranscriptEmailEnabled
        persistMeetingWebhookSecret()
        Defaults[.meetingTimelineHiddenEventIDs] = meetingTimelineHiddenEventIDs
        Defaults[.meetingTimelineIgnoredEventIDs] = meetingTimelineIgnoredEventIDs
        Defaults[.meetingTimelineAutoRecordEventIDs] = meetingTimelineAutoRecordEventIDs
        Defaults[.mcpServerEnabled] = mcpServerEnabled
        Defaults[.localAPIEnabled] = localAPIEnabled
        // Defaults[.byokEnabled] = byokEnabled
        // Defaults[.byokProvider] = byokProvider.rawValue
        Defaults[.ambientContextEnabled] = ambientContextEnabled
        Defaults[.ambientExcludedBundleIds] = ambientExcludedBundleIds
    }

    func persistAll() {
        persistUserDefaultsBackedValues()

        if LaunchAtLogin.isEnabled != launchAtLogin {
            LaunchAtLogin.isEnabled = launchAtLogin
        }

        persistAuthSession()
    }

    var hotkeyTriggers: [HotkeyTrigger] {
        [hotkeyTrigger] + hotkeyAlternateTriggers
    }

    func setHotkeyBindings(primary: HotkeyTrigger, alternates: [HotkeyTrigger]) {
        hotkeyTrigger = primary
        hotkeyAlternateTriggers = alternates
    }

    func addHotkeyAlternateTrigger(_ trigger: HotkeyTrigger) {
        hotkeyAlternateTriggers.append(trigger)
    }

    func removeHotkeyAlternateTrigger(_ trigger: HotkeyTrigger) {
        hotkeyAlternateTriggers.removeAll { $0 == trigger }
    }

    private func currentAuthSession() -> KeychainAuthSession? {
        Self.makeAuthSession(
            authToken: authToken,
            cloudAuthToken: cloudAuthToken,
            refreshToken: refreshToken
        )
    }

    var resolvedEmailSignoffName: String? {
        emailSignoffName?.trimmedNilIfEmpty ?? userDisplayName?.trimmedNilIfEmpty
    }

    private func persistAuthSession() {
        KeychainHelper.saveAuthSession(currentAuthSession())
    }

    private func persistMeetingWebhookSecret() {
        let trimmed = meetingWebhookSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != meetingWebhookSecret {
            isNormalizingMeetingWebhookSecret = true
            defer { isNormalizingMeetingWebhookSecret = false }
            meetingWebhookSecret = trimmed
        }

        if trimmed.isEmpty {
            if KeychainHelper.delete(key: Self.meetingWebhookSecretKey) {
                Defaults[.meetingWebhookSecret] = ""
            } else {
                Self.log.warning("Failed to delete meeting webhook secret from keychain")
            }
        } else {
            if KeychainHelper.save(key: Self.meetingWebhookSecretKey, value: trimmed) {
                Defaults[.meetingWebhookSecret] = ""
            } else {
                Self.log.warning("Failed to save meeting webhook secret to keychain")
            }
        }
    }

    nonisolated static func resolvedMeetingWebhookSecret(legacyDefaultsValue: String?) -> String {
        if let keychainValue = KeychainHelper.read(key: meetingWebhookSecretKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !keychainValue.isEmpty {
            Defaults[.meetingWebhookSecret] = ""
            return keychainValue
        }

        guard let legacyValue = legacyDefaultsValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !legacyValue.isEmpty else {
            Defaults[.meetingWebhookSecret] = ""
            return ""
        }

        if KeychainHelper.save(key: meetingWebhookSecretKey, value: legacyValue) {
            Defaults[.meetingWebhookSecret] = ""
        } else {
            Self.log.warning("Failed to migrate meeting webhook secret to keychain")
        }
        return legacyValue
    }

    nonisolated static func resolvePersistedAuthState(
        unifiedSession: KeychainAuthSession?,
        legacyDefaultsAuthToken: String?,
        legacyAuthToken: String?,
        legacyCloudAuthToken: String?,
        legacyRefreshToken: String?
    ) -> PersistedAuthState {
        let normalizedLegacyDefaultsAuthToken = normalizedAuthValue(legacyDefaultsAuthToken)
        let normalizedLegacyAuthToken = normalizedAuthValue(legacyAuthToken)
        let normalizedLegacyCloudToken = normalizedCloudToken(legacyCloudAuthToken, authToken: nil)
        let normalizedLegacyRefreshToken = normalizedAuthValue(legacyRefreshToken)

        if let unifiedSession {
            let normalizedUnifiedAuthToken = normalizedAuthValue(unifiedSession.authToken)
                ?? normalizedAuthValue(unifiedSession.cloudAuthToken)
            let normalizedUnifiedCloudToken = normalizedCloudToken(
                unifiedSession.cloudAuthToken,
                authToken: normalizedUnifiedAuthToken
            )
            let normalizedUnifiedRefreshToken = normalizedAuthValue(unifiedSession.refreshToken)

            let normalizedAuthToken = normalizedUnifiedAuthToken
                ?? normalizedLegacyDefaultsAuthToken
                ?? normalizedLegacyAuthToken
                ?? normalizedLegacyCloudToken
            let mergedCloudToken = normalizedUnifiedCloudToken
                ?? normalizedLegacyCloudToken
                ?? normalizedCloudToken(nil, authToken: normalizedAuthToken)
            let mergedRefreshToken = normalizedUnifiedRefreshToken
                ?? normalizedLegacyRefreshToken

            let shouldPersistUnifiedSessionImmediately =
                normalizedAuthToken != normalizedUnifiedAuthToken
                || mergedCloudToken != normalizedUnifiedCloudToken
                || mergedRefreshToken != normalizedUnifiedRefreshToken

            return PersistedAuthState(
                authToken: normalizedAuthToken,
                cloudAuthToken: mergedCloudToken,
                refreshToken: mergedRefreshToken,
                shouldClearLegacyDefaultsAuthToken: normalizedLegacyDefaultsAuthToken != nil,
                shouldPersistUnifiedSessionImmediately: shouldPersistUnifiedSessionImmediately
            )
        }

        let normalizedAuthToken = normalizedLegacyDefaultsAuthToken
            ?? normalizedLegacyAuthToken
            ?? normalizedLegacyCloudToken

        return PersistedAuthState(
            authToken: normalizedAuthToken,
            cloudAuthToken: normalizedCloudToken(legacyCloudAuthToken, authToken: normalizedAuthToken),
            refreshToken: normalizedLegacyRefreshToken,
            shouldClearLegacyDefaultsAuthToken: normalizedLegacyDefaultsAuthToken != nil,
            shouldPersistUnifiedSessionImmediately: normalizedAuthToken != nil
                || normalizedLegacyCloudToken != nil
                || normalizedLegacyRefreshToken != nil
        )
    }

    private nonisolated static func normalizedAuthValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private nonisolated static func normalizedCloudToken(_ cloudAuthToken: String?, authToken: String?) -> String? {
        ConvexClient.convexBearerToken(from: normalizedAuthValue(cloudAuthToken))
            ?? ConvexClient.convexBearerToken(from: normalizedAuthValue(authToken))
    }

    private nonisolated static func makeAuthSession(
        authToken: String?,
        cloudAuthToken: String?,
        refreshToken: String?
    ) -> KeychainAuthSession? {
        let session = KeychainAuthSession(
            authToken: normalizedAuthValue(authToken),
            cloudAuthToken: normalizedCloudToken(cloudAuthToken, authToken: authToken),
            refreshToken: normalizedAuthValue(refreshToken)
        )
        return session.isEmpty ? nil : session
    }

    private nonisolated static func normalizedHotkeyPrimary(_ trigger: HotkeyTrigger) -> HotkeyTrigger {
        trigger.isAllowedAsGlobalTrigger ? trigger : .fn
    }

    private nonisolated static func normalizedHotkeyAlternates(_ triggers: [HotkeyTrigger], excluding primary: HotkeyTrigger) -> [HotkeyTrigger] {
        HotkeyTrigger.deduplicated(triggers.filter { $0 != primary })
    }
}

private extension String {
    var trimmedNilIfEmpty: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let betaTesterEnabledChanged = Notification.Name("betaTesterEnabledChanged")
    static let hotMicEnabledChanged = Notification.Name("hotMicEnabledChanged")
    static let dispatchEnabledChanged = Notification.Name("dispatchEnabledChanged")
    static let lowLatencyModeChanged = Notification.Name("lowLatencyModeChanged")
    static let liveTranscriptPreviewChanged = Notification.Name("liveTranscriptPreviewChanged")
    static let clamshellMicSwitchEnabledChanged = Notification.Name("clamshellMicSwitchEnabledChanged")
    static let sentryDiagnosticsConfigurationChanged = Notification.Name("sentryDiagnosticsConfigurationChanged")
    static let meetingRecordingEnabledChanged = Notification.Name("meetingRecordingEnabledChanged")
    static let meetingJoinPromptEnabledChanged = Notification.Name("meetingJoinPromptEnabledChanged")
    static let meetingAutoStartEnabledChanged = Notification.Name("meetingAutoStartEnabledChanged")
    static let meetingAutoStopEnabledChanged = Notification.Name("meetingAutoStopEnabledChanged")
    static let meetingCalendarHintsEnabledChanged = Notification.Name("meetingCalendarHintsEnabledChanged")
    static let meetingTimelineAutoRecordEventIDsChanged = Notification.Name("meetingTimelineAutoRecordEventIDsChanged")
    static let mcpServerEnabledChanged = Notification.Name("mcpServerEnabledChanged")
    static let localAPIEnabledChanged = Notification.Name("localAPIEnabledChanged")
    static let notchIdleVisibleChanged = Notification.Name("notchIdleVisibleChanged")
    static let notchHiddenChanged = Notification.Name("notchHiddenChanged")
    static let ambientContextEnabledChanged = Notification.Name("ambientContextEnabledChanged")
    static let historyRetentionDaysChanged = Notification.Name("historyRetentionDaysChanged")
    static let contextMetadataEnabledChanged = Notification.Name("contextMetadataEnabledChanged")
    static let cloudProcessingEnabledChanged = Notification.Name("cloudProcessingEnabledChanged")
    static let workspaceRoamingSettingsChanged = Notification.Name("workspaceRoamingSettingsChanged")
    static let onboardingCompleted = Notification.Name("onboardingCompleted")
}
