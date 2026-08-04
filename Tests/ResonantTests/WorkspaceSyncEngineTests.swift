import XCTest
@testable import Resonant

final class WorkspaceSyncEngineTests: XCTestCase {

    @MainActor
    func testMeetingSettingsHelpersRoundTripMeetingPreferences() {
        let settings = SettingsManager.shared
        let originalPauseMediaWhileRecording = settings.pauseMediaWhileRecording
        let originalDuckSystemAudioWhileRecording = settings.duckSystemAudioWhileRecording
        let originalMeetingSummarizationEnabled = settings.meetingSummarizationEnabled
        let originalMeetingRecordingEnabled = settings.meetingRecordingEnabled
        let originalMeetingJoinPromptEnabled = settings.meetingJoinPromptEnabled
        let originalMeetingAutoStartEnabled = settings.meetingAutoStartEnabled
        let originalMeetingAutoStopEnabled = settings.meetingAutoStopEnabled
        let originalMeetingUseCalendarHints = settings.meetingUseCalendarHints
        let originalMeetingSaveAudio = settings.meetingSaveAudio

        defer {
            settings.pauseMediaWhileRecording = originalPauseMediaWhileRecording
            settings.duckSystemAudioWhileRecording = originalDuckSystemAudioWhileRecording
            settings.meetingSummarizationEnabled = originalMeetingSummarizationEnabled
            settings.meetingRecordingEnabled = originalMeetingRecordingEnabled
            settings.meetingJoinPromptEnabled = originalMeetingJoinPromptEnabled
            settings.meetingAutoStartEnabled = originalMeetingAutoStartEnabled
            settings.meetingAutoStopEnabled = originalMeetingAutoStopEnabled
            settings.meetingUseCalendarHints = originalMeetingUseCalendarHints
            settings.meetingSaveAudio = originalMeetingSaveAudio
        }

        settings.pauseMediaWhileRecording = true
        settings.duckSystemAudioWhileRecording = true
        settings.meetingSummarizationEnabled = false
        settings.meetingRecordingEnabled = true
        settings.meetingJoinPromptEnabled = true
        settings.meetingAutoStartEnabled = true
        settings.meetingAutoStopEnabled = true
        settings.meetingUseCalendarHints = true
        settings.meetingSaveAudio = false

        var json: [String: Any] = [:]
        WorkspaceSyncEngine.writeMeetingSettings(from: settings, into: &json)

        XCTAssertEqual(
            WorkspaceMeetingSettingsCodec.decode(from: json),
            WorkspaceMeetingSettingsCodec.Snapshot(
                summarizationEnabled: false,
                recordingEnabled: nil,
                joinPromptEnabled: nil,
                autoStartEnabled: nil,
                autoStopEnabled: nil,
                calendarHintsEnabled: nil,
                saveAudioEnabled: nil
            )
        )
        XCTAssertEqual(WorkspaceSyncEngine.meetingSettingsSnapshot(from: json), WorkspaceMeetingSettingsCodec.decode(from: json))
    }

    func testMeetingSettingsCodecDecodesNSNumberBoolsAndMissingKeys() {
        let snapshot = WorkspaceMeetingSettingsCodec.decode(from: [
            "meetingSummarizationEnabled": NSNumber(value: false),
            "meetingRecordingEnabled": NSNumber(value: true),
            "meetingJoinPromptEnabled": true,
            "meetingAutoStartEnabled": false,
            "meetingUseCalendarHints": NSNumber(value: true),
        ])

        XCTAssertEqual(
            snapshot,
            WorkspaceMeetingSettingsCodec.Snapshot(
                summarizationEnabled: false,
                recordingEnabled: true,
                joinPromptEnabled: true,
                autoStartEnabled: false,
                autoStopEnabled: nil,
                calendarHintsEnabled: true,
                saveAudioEnabled: nil
            )
        )
    }

    func testMeetingSettingsCodecEncodesStableWorkspaceKeys() {
        var json: [String: Any] = ["meetingSaveAudio": true]
        WorkspaceMeetingSettingsCodec.encode(
            WorkspaceMeetingSettingsCodec.Snapshot(
                summarizationEnabled: true,
                recordingEnabled: false,
                joinPromptEnabled: true,
                autoStartEnabled: false,
                autoStopEnabled: true,
                calendarHintsEnabled: false,
                saveAudioEnabled: nil
            ),
            into: &json
        )

        XCTAssertEqual(json["meetingSummarizationEnabled"] as? Bool, true)
        XCTAssertEqual(json["meetingRecordingEnabled"] as? Bool, false)
        XCTAssertEqual(json["meetingJoinPromptEnabled"] as? Bool, true)
        XCTAssertEqual(json["meetingAutoStartEnabled"] as? Bool, false)
        XCTAssertEqual(json["meetingAutoStopEnabled"] as? Bool, true)
        XCTAssertEqual(json["meetingUseCalendarHints"] as? Bool, false)
        XCTAssertNil(json["meetingSaveAudio"])
    }

    @MainActor
    func testContinuousRoamingSettingsLeaveCaptureConsentDeviceLocal() {
        let settings = SettingsManager.shared
        let originalPauseMediaWhileRecording = settings.pauseMediaWhileRecording
        let originalDuckSystemAudioWhileRecording = settings.duckSystemAudioWhileRecording
        let originalMeetingSummarizationEnabled = settings.meetingSummarizationEnabled
        let originalMeetingRecordingEnabled = settings.meetingRecordingEnabled
        let originalMeetingJoinPromptEnabled = settings.meetingJoinPromptEnabled
        let originalMeetingAutoStartEnabled = settings.meetingAutoStartEnabled
        let originalMeetingAutoStopEnabled = settings.meetingAutoStopEnabled
        let originalMeetingUseCalendarHints = settings.meetingUseCalendarHints
        let originalMeetingSaveAudio = settings.meetingSaveAudio

        defer {
            settings.pauseMediaWhileRecording = originalPauseMediaWhileRecording
            settings.duckSystemAudioWhileRecording = originalDuckSystemAudioWhileRecording
            settings.meetingSummarizationEnabled = originalMeetingSummarizationEnabled
            settings.meetingRecordingEnabled = originalMeetingRecordingEnabled
            settings.meetingJoinPromptEnabled = originalMeetingJoinPromptEnabled
            settings.meetingAutoStartEnabled = originalMeetingAutoStartEnabled
            settings.meetingAutoStopEnabled = originalMeetingAutoStopEnabled
            settings.meetingUseCalendarHints = originalMeetingUseCalendarHints
            settings.meetingSaveAudio = originalMeetingSaveAudio
        }

        settings.pauseMediaWhileRecording = false
        settings.duckSystemAudioWhileRecording = false
        settings.meetingSummarizationEnabled = true
        settings.meetingRecordingEnabled = false
        settings.meetingJoinPromptEnabled = false
        settings.meetingAutoStartEnabled = false
        settings.meetingAutoStopEnabled = false
        settings.meetingUseCalendarHints = false
        settings.meetingSaveAudio = true

        let snapshot = WorkspaceSnapshot(
            onboardingCompleted: nil,
            triggerKey: nil,
            triggerKeys: nil,
            hotkeyMode: nil,
            sttModel: nil,
            removeFillerWords: nil,
            removeFalseStarts: nil,
            itnEnabled: nil,
            punctuationEnabled: nil,
            formatBulletPoints: nil,
            cloudProcessingEnabled: nil,
            selectionTransformEnabled: nil,
            journalSummarizationEnabled: nil,
            meetingSummarizationEnabled: false,
            autoPaste: nil,
            copyToClipboard: nil,
            autoSend: nil,
            emailSignatureEnabled: nil,
            emailSignoffName: nil,
            triggerKeySoundEnabled: nil,
            triggerKeySoundVolume: nil,
            expressionSoundsEnabled: nil,
            expressionSoundsVolume: nil,
            overlayMode: nil,
            inputDeviceUID: nil,
            hotMicEnabled: nil,
            pauseMediaWhileRecording: true,
            duckSystemAudioWhileRecording: true,
            hotWord: nil,
            lowLatencyMode: nil,
            meetingRecordingEnabled: true,
            meetingJoinPromptEnabled: true,
            meetingAutoStartEnabled: true,
            meetingAutoStopEnabled: true,
            meetingUseCalendarHints: true,
            meetingSaveAudio: false,
            saveAudio: nil,
            saveContextMetadata: nil,
            historyRetentionDays: nil,
            hipaaMode: nil,
            launchAtLogin: nil,
            crashDiagnosticsEnabled: nil,
            analyticsEnabled: nil,
            authToken: nil,
            userId: nil,
            userEmail: nil,
            userDisplayName: nil,
            pinnedDisplayId: nil,
            smartLinks: [],
            hasSmartLinks: false,
            dictionaryWords: [],
            hasDictionaryWords: false,
            dictationHistory: [],
            voiceNotes: [],
            meetingHistory: [],
            stats: nil,
            dailyWordCounts: [:]
        )

        WorkspaceSyncEngine.applyContinuouslyRoamingSettings(from: snapshot, to: settings)

        XCTAssertTrue(settings.pauseMediaWhileRecording)
        XCTAssertTrue(settings.duckSystemAudioWhileRecording)
        XCTAssertFalse(settings.meetingSummarizationEnabled)
        XCTAssertFalse(settings.meetingRecordingEnabled)
        XCTAssertFalse(settings.meetingJoinPromptEnabled)
        XCTAssertFalse(settings.meetingAutoStartEnabled)
        XCTAssertFalse(settings.meetingAutoStopEnabled)
        XCTAssertFalse(settings.meetingUseCalendarHints)
        XCTAssertTrue(settings.meetingSaveAudio)
    }

    func testHotWordFallbackReadsLegacyWakePhraseKey() {
        XCTAssertEqual(
            WorkspaceSyncEngine.hotWordValue(from: ["hotMicWakePhrase": "resonant"]),
            "resonant"
        )
    }

    func testAuthTokenFallbackReadsLegacyClawTokenKey() {
        XCTAssertEqual(
            WorkspaceSyncEngine.authTokenValue(from: ["clawAuthToken": "secret-token"]),
            "secret-token"
        )
    }

    func testGeneratedLocalExternalIDsUseStableModelIDs() {
        let dictationID = UUID(uuidString: "D9E92EC2-4D13-4F49-A43E-9CB7367A291B")!
        let memoID = UUID(uuidString: "B7A474DA-3DD1-4672-9996-5C9D3741B113")!

        XCTAssertEqual(
            WorkspaceSyncEngine.localDictationExternalID(for: dictationID),
            "workspace-dictation:d9e92ec2-4d13-4f49-a43e-9cb7367a291b"
        )
        XCTAssertEqual(
            WorkspaceSyncEngine.localMemoExternalID(for: memoID),
            "workspace-memo:b7a474da-3dd1-4672-9996-5c9d3741b113"
        )
    }

    func testWorkspaceRecordIDStripsSyncedDataPrefixes() {
        XCTAssertEqual(
            WorkspaceSyncEngine.workspaceRecordID(from: "workspace-dictation:abc-123"),
            "abc-123"
        )
        XCTAssertEqual(
            WorkspaceSyncEngine.workspaceRecordID(from: "workspace-memo:def-456"),
            "def-456"
        )
    }

    @MainActor
    func testCloudTextSyncIsDisabledEvenWhenForced() {
        XCTAssertFalse(WorkspaceSyncEngine.shouldSyncCloudText(
            permissionGranted: false,
            override: true,
            exportDirty: true,
            lastSyncedAt: nil
        ))

        XCTAssertFalse(WorkspaceSyncEngine.shouldSyncCloudText(
            permissionGranted: false,
            override: false,
            exportDirty: true,
            lastSyncedAt: Date()
        ))

        XCTAssertFalse(WorkspaceSyncEngine.shouldSyncCloudText(
            permissionGranted: true,
            override: true,
            exportDirty: false,
            lastSyncedAt: Date()
        ))
    }

    func testExportMeetingHistoryIncludesCalendarMetadata() {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let endedAt = startedAt.addingTimeInterval(1_800)
        let entry = MeetingEntry(
            id: UUID(uuidString: "B7A474DA-3DD1-4672-9996-5C9D3741B113")!,
            startedAt: startedAt,
            endedAt: endedAt,
            detectedApp: "Zoom",
            customTitle: "Customer sync",
            durationSeconds: 1_800,
            wordCount: 420,
            userNotes: "Action items",
            postMeetingNotes: "Follow up next week",
            summary: "Summary"
        )
        entry.calendarEventID = "evt_123"
        entry.scheduledStartAt = startedAt
        entry.scheduledEndAt = endedAt
        entry.organizerName = "Ada"
        entry.attendeeNamesJSON = encodeJSONStringArray(["Ada", "Grace"])
        entry.attendeeEmailsJSON = encodeJSONStringArray(["ada@example.com"])
        entry.speakerAliasesJSON = encodeJSONStringDictionary(["you": "Taylor", "participant:SPEAKER_0": "Grace"])
        entry.conferencingURL = "https://meet.proton.me/room"
        entry.calendarName = "Work"
        entry.recordingOrigin = .automatic

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let exported = WorkspaceSyncEngine.exportMeetingHistory([entry], formatter: formatter)

        XCTAssertEqual(exported.count, 1)
        XCTAssertEqual(exported[0]["calendarEventID"] as? String, "evt_123")
        XCTAssertEqual(exported[0]["scheduledStartAt"] as? String, formatter.string(from: startedAt))
        XCTAssertEqual(exported[0]["scheduledEndAt"] as? String, formatter.string(from: endedAt))
        XCTAssertEqual(exported[0]["organizerName"] as? String, "Ada")
        XCTAssertEqual(exported[0]["attendeeNames"] as? [String], ["Ada", "Grace"])
        XCTAssertEqual(exported[0]["attendeeEmails"] as? [String], ["ada@example.com"])
        XCTAssertEqual(
            exported[0]["speakerAliases"] as? [String: String],
            ["you": "Taylor", "participant:SPEAKER_0": "Grace"]
        )
        XCTAssertEqual(exported[0]["conferencingURL"] as? String, "https://meet.proton.me/room")
        XCTAssertEqual(exported[0]["calendarName"] as? String, "Work")
        XCTAssertEqual(exported[0]["recordingOrigin"] as? String, "automatic")
    }

    @MainActor
    func testParseMeetingRecordReadsCalendarMetadata() {
        let engine = makeWorkspaceSyncEngine()
        let record: [String: Any] = [
            "id": "b7a474da-3dd1-4672-9996-5c9d3741b113",
            "title": "Customer sync",
            "timestamp": "2024-01-01T10:00:00Z",
            "endedAt": "2024-01-01T10:30:00Z",
            "calendarEventID": "evt_123",
            "scheduledStartAt": "2024-01-01T10:00:00Z",
            "scheduledEndAt": "2024-01-01T10:30:00Z",
            "organizerName": "Ada",
            "attendeeNames": ["Ada", "Grace"],
            "attendeeEmails": ["ada@example.com"],
            "speakerAliases": ["you": "Taylor", "participant:SPEAKER_0": "Grace"],
            "conferencingURL": "https://meet.proton.me/room",
            "calendarName": "Work",
            "recordingOrigin": "rebound",
        ]

        let parsed = engine.parseMeetingRecord(record)

        XCTAssertEqual(parsed?.calendarEventID, "evt_123")
        XCTAssertEqual(parsed?.scheduledStartAt, "2024-01-01T10:00:00Z")
        XCTAssertEqual(parsed?.scheduledEndAt, "2024-01-01T10:30:00Z")
        XCTAssertEqual(parsed?.organizerName, "Ada")
        XCTAssertEqual(parsed?.attendeeNames, ["Ada", "Grace"])
        XCTAssertEqual(parsed?.attendeeEmails, ["ada@example.com"])
        XCTAssertEqual(
            parsed?.speakerAliases,
            ["you": "Taylor", "participant:SPEAKER_0": "Grace"]
        )
        XCTAssertEqual(parsed?.conferencingURL, "https://meet.proton.me/room")
        XCTAssertEqual(parsed?.calendarName, "Work")
        XCTAssertEqual(parsed?.recordingOrigin, "rebound")
        XCTAssertEqual(parsed?.hasCaptureMetadata, true)
    }

    func testNormalizedMeetingURLRecognizesProtonMeet() {
        XCTAssertEqual(
            EventKitMeetingCalendarHintSource.normalizedMeetingURL("meet.proton.me/team-sync"),
            "https://meet.proton.me/team-sync"
        )
    }

    func testWorkspaceClearMirrorRemovalDeletesEveryImportSource() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceClearTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ambient = root
            .appendingPathComponent("stream", isDirectory: true)
            .appendingPathComponent("ambient", isDirectory: true)
        try FileManager.default.createDirectory(at: ambient, withIntermediateDirectories: true)

        let settings = root.appendingPathComponent("settings.json")
        let syncState = root.appendingPathComponent("workspace-sync-state.json")
        let ambientHistory = ambient.appendingPathComponent("2026-07-12.jsonl")
        let current = ambient.appendingPathComponent("current.json")
        try Data("{}".utf8).write(to: settings)
        try Data("{}".utf8).write(to: syncState)
        try Data("{}\n".utf8).write(to: ambientHistory)
        try Data("{}".utf8).write(to: current)

        XCTAssertTrue(WorkspaceSyncEngine.removeWorkspaceImportMirrorsOffMain(directories: [root]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: settings.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: syncState.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ambientHistory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: current.path))
    }

    @MainActor
    private func makeWorkspaceSyncEngine() -> WorkspaceSyncEngine {
        WorkspaceSyncEngine(
            dataStore: DataStore(),
            settingsManager: SettingsManager.shared,
            smartLinkStore: SmartLinkStore(),
            dictionaryStore: DictionaryStore(),
            memoManager: MemoManager(),
            feedManager: FeedManager(),
            journalManager: JournalManager(),
            archiveWriter: ArchiveWriter(),
            convexClient: ConvexClient(authManager: AuthManager())
        )
    }
}
