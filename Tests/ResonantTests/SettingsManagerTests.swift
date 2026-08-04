import XCTest
import Defaults
@testable import Resonant

@MainActor
final class SettingsManagerTests: XCTestCase {

    private let jwtToken = "header.payload.signature"

    func testPrivacyConsentMigrationFailsClosedOnceAndPreservesLaterChoices() throws {
        let suiteName = "SettingsManagerTests.privacy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let sensitiveKeys = [
            "emailSignatureEnabled",
            "meetingSaveAudio",
            "saveAudioEnabled",
            "contextMetadataEnabled",
            "ambientContextEnabled",
            "crashDiagnosticsEnabled",
            "analyticsEnabled",
            "mcpServerEnabled",
            "localAPIEnabled",
        ]
        sensitiveKeys.forEach { defaults.set(true, forKey: $0) }

        XCTAssertTrue(SettingsManager.applyPrivacyConsentMigration(to: defaults))
        XCTAssertEqual(
            defaults.integer(forKey: "privacyConsentSchemaVersion"),
            SettingsManager.currentPrivacyConsentSchemaVersion
        )
        for key in sensitiveKeys {
            XCTAssertFalse(defaults.bool(forKey: key), "Expected \(key) to fail closed")
        }

        defaults.set(true, forKey: "ambientContextEnabled")
        XCTAssertFalse(SettingsManager.applyPrivacyConsentMigration(to: defaults))
        XCTAssertTrue(defaults.bool(forKey: "ambientContextEnabled"))
    }

    func testResolvePersistedAuthStatePrefersUnifiedSession() {
        let resolved = SettingsManager.resolvePersistedAuthState(
            unifiedSession: KeychainAuthSession(
                authToken: " \(jwtToken) ",
                cloudAuthToken: nil,
                refreshToken: " refresh "
            ),
            legacyDefaultsAuthToken: "legacy-default.payload.signature",
            legacyAuthToken: "legacy-auth.payload.signature",
            legacyCloudAuthToken: "legacy-cloud.payload.signature",
            legacyRefreshToken: "legacy-refresh"
        )

        XCTAssertEqual(resolved.authToken, jwtToken)
        XCTAssertEqual(resolved.cloudAuthToken, jwtToken)
        XCTAssertEqual(resolved.refreshToken, "refresh")
        XCTAssertTrue(resolved.shouldClearLegacyDefaultsAuthToken)
        XCTAssertFalse(resolved.shouldPersistUnifiedSessionImmediately)
    }

    func testResolvePersistedAuthStateMergesLegacyCloudTokenIntoIncompleteUnifiedSession() {
        let resolved = SettingsManager.resolvePersistedAuthState(
            unifiedSession: KeychainAuthSession(
                authToken: "website-session-token",
                cloudAuthToken: nil,
                refreshToken: nil
            ),
            legacyDefaultsAuthToken: nil,
            legacyAuthToken: nil,
            legacyCloudAuthToken: jwtToken,
            legacyRefreshToken: "legacy-refresh"
        )

        XCTAssertEqual(resolved.authToken, "website-session-token")
        XCTAssertEqual(resolved.cloudAuthToken, jwtToken)
        XCTAssertEqual(resolved.refreshToken, "legacy-refresh")
        XCTAssertTrue(resolved.shouldPersistUnifiedSessionImmediately)
    }

    func testResolvePersistedAuthStateFallsBackToLegacyTokens() {
        let resolved = SettingsManager.resolvePersistedAuthState(
            unifiedSession: nil,
            legacyDefaultsAuthToken: nil,
            legacyAuthToken: jwtToken,
            legacyCloudAuthToken: nil,
            legacyRefreshToken: "legacy-refresh"
        )

        XCTAssertEqual(resolved.authToken, jwtToken)
        XCTAssertEqual(resolved.cloudAuthToken, jwtToken)
        XCTAssertEqual(resolved.refreshToken, "legacy-refresh")
        XCTAssertFalse(resolved.shouldClearLegacyDefaultsAuthToken)
        XCTAssertTrue(resolved.shouldPersistUnifiedSessionImmediately)
    }

    func testResolvePersistedAuthStateMigratesLegacyDefaultsTokenToUnifiedStorage() {
        let resolved = SettingsManager.resolvePersistedAuthState(
            unifiedSession: nil,
            legacyDefaultsAuthToken: jwtToken,
            legacyAuthToken: nil,
            legacyCloudAuthToken: nil,
            legacyRefreshToken: nil
        )

        XCTAssertEqual(resolved.authToken, jwtToken)
        XCTAssertEqual(resolved.cloudAuthToken, jwtToken)
        XCTAssertNil(resolved.refreshToken)
        XCTAssertTrue(resolved.shouldClearLegacyDefaultsAuthToken)
        XCTAssertTrue(resolved.shouldPersistUnifiedSessionImmediately)
    }

    func testResolvePersistedAuthStateUsesLegacyCloudTokenWhenAuthTokenMissing() {
        let resolved = SettingsManager.resolvePersistedAuthState(
            unifiedSession: nil,
            legacyDefaultsAuthToken: nil,
            legacyAuthToken: nil,
            legacyCloudAuthToken: jwtToken,
            legacyRefreshToken: nil
        )

        XCTAssertEqual(resolved.authToken, jwtToken)
        XCTAssertEqual(resolved.cloudAuthToken, jwtToken)
        XCTAssertNil(resolved.refreshToken)
        XCTAssertTrue(resolved.shouldPersistUnifiedSessionImmediately)
    }

    func testManagedKeysCoverAllDefaultsBackedSettings() {
        let missingKeys = SettingsManager.defaultsBackedKeys.subtracting(AppDefaults.managedKeys)
        XCTAssertTrue(missingKeys.isEmpty, "Missing managed keys: \(missingKeys.sorted())")
    }

    func testWorkspaceCloudUploadSettingStaysDisabledWhenCloudSyncIsHidden() {
        XCTAssertFalse(AppFeatureVisibility.cloudSync)
        let settings = SettingsManager.shared
        let originalDefaultsValue = Defaults[.workspaceCloudUploadEnabled]

        defer {
            settings.workspaceCloudUploadEnabled = false
            Defaults[.workspaceCloudUploadEnabled] = originalDefaultsValue
        }

        settings.workspaceCloudUploadEnabled = true

        XCTAssertFalse(settings.workspaceCloudUploadEnabled)
        XCTAssertFalse(Defaults[.workspaceCloudUploadEnabled])

        settings.workspaceCloudUploadEnabled = false

        XCTAssertFalse(settings.workspaceCloudUploadEnabled)
        XCTAssertFalse(Defaults[.workspaceCloudUploadEnabled])
    }

    func testWebhookSecretMigratesLegacyDefaultsValueToKeychain() {
        let originalKeychainValue = KeychainHelper.read(key: SettingsManager.meetingWebhookSecretKey)
        let originalDefaultsValue = Defaults[.meetingWebhookSecret]
        defer {
            if let originalKeychainValue {
                KeychainHelper.save(key: SettingsManager.meetingWebhookSecretKey, value: originalKeychainValue)
            } else {
                KeychainHelper.delete(key: SettingsManager.meetingWebhookSecretKey)
            }
            Defaults[.meetingWebhookSecret] = originalDefaultsValue
        }

        KeychainHelper.delete(key: SettingsManager.meetingWebhookSecretKey)
        Defaults[.meetingWebhookSecret] = " legacy-secret "

        let resolved = SettingsManager.resolvedMeetingWebhookSecret(legacyDefaultsValue: Defaults[.meetingWebhookSecret])

        XCTAssertEqual(resolved, "legacy-secret")
        XCTAssertEqual(KeychainHelper.read(key: SettingsManager.meetingWebhookSecretKey), "legacy-secret")
        XCTAssertEqual(Defaults[.meetingWebhookSecret], "")
    }

    func testWebhookSecretPrefersKeychainAndClearsLegacyDefaultsValue() {
        let originalKeychainValue = KeychainHelper.read(key: SettingsManager.meetingWebhookSecretKey)
        let originalDefaultsValue = Defaults[.meetingWebhookSecret]
        defer {
            if let originalKeychainValue {
                KeychainHelper.save(key: SettingsManager.meetingWebhookSecretKey, value: originalKeychainValue)
            } else {
                KeychainHelper.delete(key: SettingsManager.meetingWebhookSecretKey)
            }
            Defaults[.meetingWebhookSecret] = originalDefaultsValue
        }

        KeychainHelper.save(key: SettingsManager.meetingWebhookSecretKey, value: "keychain-secret")
        Defaults[.meetingWebhookSecret] = "legacy-secret"

        let resolved = SettingsManager.resolvedMeetingWebhookSecret(legacyDefaultsValue: Defaults[.meetingWebhookSecret])

        XCTAssertEqual(resolved, "keychain-secret")
        XCTAssertEqual(KeychainHelper.read(key: SettingsManager.meetingWebhookSecretKey), "keychain-secret")
        XCTAssertEqual(Defaults[.meetingWebhookSecret], "")
    }

    func testHotkeyAlternatesPersistAndNormalizeAgainstPrimary() {
        let settings = SettingsManager.shared
        let suite = AppDefaults.suite
        let originalPrimary = settings.hotkeyTrigger
        let originalAlternates = settings.hotkeyAlternateTriggers

        defer {
            settings.setHotkeyBindings(primary: originalPrimary, alternates: originalAlternates)
        }

        settings.setHotkeyBindings(
            primary: .fn,
            alternates: [
                .fn,
                .rightOption,
                .custom(keyCode: 122),
                .rightOption,
            ]
        )

        XCTAssertEqual(settings.hotkeyTrigger, .fn)
        XCTAssertEqual(settings.hotkeyAlternateTriggers, [.rightOption, .custom(keyCode: 122)])
        XCTAssertEqual(settings.hotkeyTriggers, [.fn, .rightOption, .custom(keyCode: 122)])
        XCTAssertEqual(
            suite.array(forKey: "hotkeyAlternateTriggers") as? [String],
            [HotkeyTrigger.rightOption.rawValue, HotkeyTrigger.custom(keyCode: 122).rawValue]
        )
    }

    func testHotkeyModePersistsToggleSelection() {
        let settings = SettingsManager.shared
        let suite = AppDefaults.suite
        let originalMode = settings.hotkeyMode

        defer {
            settings.hotkeyMode = originalMode
        }

        settings.hotkeyMode = .toggle

        XCTAssertEqual(settings.hotkeyMode, .toggle)
        XCTAssertEqual(suite.string(forKey: "hotkeyMode"), HotkeyMode.toggle.rawValue)
    }

    func testHotkeyHoldLockPersistsSelection() {
        let settings = SettingsManager.shared
        let suite = AppDefaults.suite
        let originalValue = settings.hotkeyHoldLockEnabled

        defer {
            settings.hotkeyHoldLockEnabled = originalValue
        }

        settings.hotkeyHoldLockEnabled = false

        XCTAssertFalse(settings.hotkeyHoldLockEnabled)
        XCTAssertFalse(suite.bool(forKey: "hotkeyHoldLockEnabled"))
    }

    func testPasteDeliveryModePersistsSelection() {
        let settings = SettingsManager.shared
        let suite = AppDefaults.suite
        let originalMode = settings.pasteDeliveryMode

        defer {
            settings.pasteDeliveryMode = originalMode
        }

        settings.pasteDeliveryMode = .directTyping

        XCTAssertEqual(settings.pasteDeliveryMode, .directTyping)
        XCTAssertEqual(suite.string(forKey: "pasteDeliveryMode"), PasteDeliveryMode.directTyping.rawValue)
    }

    func testMeetingTimelineAutoRecordEventIDsPostChangeNotification() {
        let settings = SettingsManager.shared
        let originalIDs = settings.meetingTimelineAutoRecordEventIDs
        let expectation = expectation(description: "meeting timeline auto-record IDs changed")
        let observer = NotificationCenter.default.addObserver(
            forName: .meetingTimelineAutoRecordEventIDsChanged,
            object: nil,
            queue: .main
        ) { _ in
            expectation.fulfill()
        }

        defer {
            NotificationCenter.default.removeObserver(observer)
            settings.meetingTimelineAutoRecordEventIDs = originalIDs
        }

        settings.meetingTimelineAutoRecordEventIDs = ["calendar-event-for-auto-record"]

        wait(for: [expectation], timeout: 1.0)
    }

    func testPersistUserDefaultsBackedValuesFlushesCurrentSettingsSnapshot() {
        let settings = SettingsManager.shared
        let suite = AppDefaults.suite

        let originalSaveAudioEnabled = settings.saveAudioEnabled
        let originalHistoryRetentionDays = settings.historyRetentionDays
        let originalJournalSummarizationEnabled = settings.journalSummarizationEnabled
        let originalCrashDiagnosticsEnabled = settings.crashDiagnosticsEnabled
        let originalAnalyticsEnabled = settings.analyticsEnabled
        let originalContextMetadataEnabled = settings.contextMetadataEnabled
        let originalHotWord = settings.hotWord
        let originalHotkeyTrigger = settings.hotkeyTrigger
        let originalHotkeyAlternateTriggers = settings.hotkeyAlternateTriggers
        let originalInputDeviceUID = settings.inputDeviceUID
        let originalOverlayMode = settings.overlayMode
        let originalPinnedDisplayId = settings.pinnedDisplayId
        let originalPauseMediaWhileRecording = settings.pauseMediaWhileRecording
        let originalDuckSystemAudioWhileRecording = settings.duckSystemAudioWhileRecording
        let originalMeetingJoinPromptEnabled = settings.meetingJoinPromptEnabled
        let originalMeetingAutoStartEnabled = settings.meetingAutoStartEnabled
        let originalMeetingAutoStopEnabled = settings.meetingAutoStopEnabled
        let originalMeetingUseCalendarHints = settings.meetingUseCalendarHints
        let originalMeetingUseSelectedMicrophone = settings.meetingUseSelectedMicrophone
        let originalEmailSignatureEnabled = settings.emailSignatureEnabled
        let originalEmailSignoffName = settings.emailSignoffName
        let originalUserDisplayName = settings.userDisplayName
        let originalPasteDeliveryMode = settings.pasteDeliveryMode

        defer {
            settings.saveAudioEnabled = originalSaveAudioEnabled
            settings.historyRetentionDays = originalHistoryRetentionDays
            settings.journalSummarizationEnabled = originalJournalSummarizationEnabled
            settings.crashDiagnosticsEnabled = originalCrashDiagnosticsEnabled
            settings.analyticsEnabled = originalAnalyticsEnabled
            settings.contextMetadataEnabled = originalContextMetadataEnabled
            settings.hotWord = originalHotWord
            settings.setHotkeyBindings(primary: originalHotkeyTrigger, alternates: originalHotkeyAlternateTriggers)
            settings.inputDeviceUID = originalInputDeviceUID
            settings.overlayMode = originalOverlayMode
            settings.pinnedDisplayId = originalPinnedDisplayId
            settings.pauseMediaWhileRecording = originalPauseMediaWhileRecording
            settings.duckSystemAudioWhileRecording = originalDuckSystemAudioWhileRecording
            settings.meetingJoinPromptEnabled = originalMeetingJoinPromptEnabled
            settings.meetingAutoStartEnabled = originalMeetingAutoStartEnabled
            settings.meetingAutoStopEnabled = originalMeetingAutoStopEnabled
            settings.meetingUseCalendarHints = originalMeetingUseCalendarHints
            settings.meetingUseSelectedMicrophone = originalMeetingUseSelectedMicrophone
            settings.emailSignatureEnabled = originalEmailSignatureEnabled
            settings.emailSignoffName = originalEmailSignoffName
            settings.userDisplayName = originalUserDisplayName
            settings.pasteDeliveryMode = originalPasteDeliveryMode
        }

        settings.saveAudioEnabled = false
        settings.historyRetentionDays = 36500
        settings.journalSummarizationEnabled = false
        settings.crashDiagnosticsEnabled = false
        settings.analyticsEnabled = false
        settings.contextMetadataEnabled = false
        settings.hotWord = "workspace test phrase"
        settings.setHotkeyBindings(
            primary: .rightOption,
            alternates: [.custom(keyCode: 122)]
        )
        settings.inputDeviceUID = "test-input-device"
        settings.overlayMode = .panel
        settings.pinnedDisplayId = 42
        settings.pauseMediaWhileRecording = true
        settings.duckSystemAudioWhileRecording = true
        settings.meetingJoinPromptEnabled = true
        settings.meetingAutoStartEnabled = true
        settings.meetingAutoStopEnabled = true
        settings.meetingUseCalendarHints = true
        settings.meetingUseSelectedMicrophone = true
        settings.emailSignatureEnabled = true
        settings.emailSignoffName = "Alex"
        settings.userDisplayName = "Alex Example"
        settings.pasteDeliveryMode = .clipboard

        suite.set(true, forKey: "saveAudioEnabled")
        suite.set(30, forKey: "historyRetentionDays")
        suite.set(true, forKey: "journalSummarizationEnabled")
        suite.set(true, forKey: "crashDiagnosticsEnabled")
        suite.set(true, forKey: "analyticsEnabled")
        suite.set(true, forKey: "contextMetadataEnabled")
        suite.set("stale hotword", forKey: "hotWord")
        suite.set(HotkeyTrigger.fn.rawValue, forKey: "hotkeyTrigger")
        suite.set([], forKey: "hotkeyAlternateTriggers")
        suite.set("stale-input-device", forKey: "inputDeviceUID")
        suite.set(OverlayMode.notch.rawValue, forKey: "overlayMode")
        suite.set(7, forKey: "pinnedDisplayId")
        suite.set(false, forKey: "pauseMediaWhileRecording")
        suite.set(false, forKey: "duckSystemAudioWhileRecording")
        suite.set(false, forKey: "meetingJoinPromptEnabled")
        suite.set(false, forKey: "meetingAutoStartEnabled")
        suite.set(false, forKey: "meetingAutoStopEnabled")
        suite.set(false, forKey: "meetingUseCalendarHints")
        suite.set(false, forKey: "meetingUseSelectedMicrophone")
        suite.set(false, forKey: "emailSignatureEnabled")
        suite.set("stale signoff", forKey: "emailSignoffName")
        suite.set("stale user", forKey: "userDisplayName")
        suite.set(PasteDeliveryMode.automatic.rawValue, forKey: "pasteDeliveryMode")

        settings.persistUserDefaultsBackedValues()

        XCTAssertFalse(suite.bool(forKey: "saveAudioEnabled"))
        XCTAssertEqual(suite.integer(forKey: "historyRetentionDays"), 36500)
        XCTAssertFalse(suite.bool(forKey: "journalSummarizationEnabled"))
        XCTAssertFalse(suite.bool(forKey: "crashDiagnosticsEnabled"))
        XCTAssertFalse(suite.bool(forKey: "analyticsEnabled"))
        XCTAssertFalse(suite.bool(forKey: "contextMetadataEnabled"))
        XCTAssertEqual(suite.string(forKey: "hotWord"), "workspace test phrase")
        XCTAssertEqual(suite.string(forKey: "hotkeyTrigger"), HotkeyTrigger.rightOption.rawValue)
        XCTAssertEqual(
            suite.array(forKey: "hotkeyAlternateTriggers") as? [String],
            [HotkeyTrigger.custom(keyCode: 122).rawValue]
        )
        XCTAssertEqual(suite.string(forKey: "inputDeviceUID"), "test-input-device")
        XCTAssertEqual(suite.string(forKey: "overlayMode"), OverlayMode.panel.rawValue)
        XCTAssertEqual(suite.object(forKey: "pinnedDisplayId") as? Int, 42)
        XCTAssertTrue(suite.bool(forKey: "pauseMediaWhileRecording"))
        XCTAssertTrue(suite.bool(forKey: "duckSystemAudioWhileRecording"))
        XCTAssertTrue(suite.bool(forKey: "meetingJoinPromptEnabled"))
        XCTAssertTrue(suite.bool(forKey: "meetingAutoStartEnabled"))
        XCTAssertTrue(suite.bool(forKey: "meetingAutoStopEnabled"))
        XCTAssertTrue(suite.bool(forKey: "meetingUseCalendarHints"))
        XCTAssertTrue(suite.bool(forKey: "meetingUseSelectedMicrophone"))
        XCTAssertTrue(suite.bool(forKey: "emailSignatureEnabled"))
        XCTAssertEqual(suite.string(forKey: "emailSignoffName"), "Alex")
        XCTAssertEqual(suite.string(forKey: "userDisplayName"), "Alex Example")
        XCTAssertEqual(suite.string(forKey: "pasteDeliveryMode"), PasteDeliveryMode.clipboard.rawValue)
    }

    func testCloudPersonalizationExamplesDefaultFalseAndPersistOnlyAfterExplicitOptIn() {
        let settings = SettingsManager.shared
        let suite = AppDefaults.suite
        let originalHIPAAMode = settings.hipaaMode
        let originalConsent = settings.cloudPersonalizationExamplesEnabled

        defer {
            settings.hipaaMode = false
            settings.cloudPersonalizationExamplesEnabled = originalConsent
            settings.hipaaMode = originalHIPAAMode
        }

        settings.hipaaMode = false
        settings.cloudPersonalizationExamplesEnabled = false
        suite.removeObject(forKey: "cloudPersonalizationExamplesEnabled")

        XCTAssertFalse(Defaults[.cloudPersonalizationExamplesEnabled])
        XCTAssertFalse(settings.effectiveCloudPersonalizationExamplesEnabled)

        settings.cloudPersonalizationExamplesEnabled = true

        XCTAssertTrue(Defaults[.cloudPersonalizationExamplesEnabled])
        XCTAssertTrue(settings.effectiveCloudPersonalizationExamplesEnabled)

        suite.set(false, forKey: "cloudPersonalizationExamplesEnabled")
        settings.persistAll()
        XCTAssertTrue(suite.bool(forKey: "cloudPersonalizationExamplesEnabled"))
    }

    func testHIPAAModeImmediatelyRevokesCloudPersonalizationExamples() {
        let settings = SettingsManager.shared
        let originalHIPAAMode = settings.hipaaMode
        let originalConsent = settings.cloudPersonalizationExamplesEnabled

        defer {
            settings.hipaaMode = false
            settings.cloudPersonalizationExamplesEnabled = originalConsent
            settings.hipaaMode = originalHIPAAMode
        }

        settings.hipaaMode = false
        settings.cloudPersonalizationExamplesEnabled = true
        settings.hipaaMode = true

        XCTAssertFalse(settings.cloudPersonalizationExamplesEnabled)
        XCTAssertFalse(settings.effectiveCloudPersonalizationExamplesEnabled)
        XCTAssertFalse(Defaults[.cloudPersonalizationExamplesEnabled])

        settings.cloudPersonalizationExamplesEnabled = true
        XCTAssertFalse(settings.cloudPersonalizationExamplesEnabled)
        XCTAssertFalse(Defaults[.cloudPersonalizationExamplesEnabled])
    }

    func testStoredCloudPersonalizationExamplesNormalizeStaleHIPAAConsent() {
        let settings = SettingsManager.shared
        let originalHIPAAMode = settings.hipaaMode
        let originalConsent = settings.cloudPersonalizationExamplesEnabled

        defer {
            settings.hipaaMode = false
            settings.cloudPersonalizationExamplesEnabled = originalConsent
            settings.hipaaMode = originalHIPAAMode
        }

        Defaults[.hipaaMode] = true
        Defaults[.cloudPersonalizationExamplesEnabled] = true

        let normalized = SettingsManager.normalizeStoredCloudPersonalizationExamplesConsent()

        XCTAssertFalse(normalized)
        XCTAssertFalse(Defaults[.cloudPersonalizationExamplesEnabled])
        XCTAssertTrue(Defaults[.hipaaMode])
    }

    func testDisablingHIPAAModeNeverRestoresCloudPersonalizationConsent() {
        let settings = SettingsManager.shared
        let originalHIPAAMode = settings.hipaaMode
        let originalConsent = settings.cloudPersonalizationExamplesEnabled

        defer {
            settings.hipaaMode = false
            settings.cloudPersonalizationExamplesEnabled = originalConsent
            settings.hipaaMode = originalHIPAAMode
        }

        settings.hipaaMode = false
        settings.cloudPersonalizationExamplesEnabled = true
        settings.hipaaMode = true
        settings.hipaaMode = false

        XCTAssertFalse(settings.cloudPersonalizationExamplesEnabled)
        XCTAssertFalse(settings.effectiveCloudPersonalizationExamplesEnabled)
    }
}
