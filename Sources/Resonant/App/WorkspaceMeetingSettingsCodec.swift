import Foundation

/// Encodes and decodes the meeting preferences persisted in workspace JSON.
///
/// WorkspaceSyncEngine still owns sync orchestration; this codec owns the
/// stable JSON keys and the optional snapshot used during import.
enum WorkspaceMeetingSettingsCodec {
    struct Snapshot: Equatable, Sendable {
        let summarizationEnabled: Bool?
        let recordingEnabled: Bool?
        let joinPromptEnabled: Bool?
        let autoStartEnabled: Bool?
        let autoStopEnabled: Bool?
        let calendarHintsEnabled: Bool?
        let saveAudioEnabled: Bool?
    }

    nonisolated static func decode(from json: [String: Any]) -> Snapshot {
        Snapshot(
            summarizationEnabled: boolValue(json["meetingSummarizationEnabled"]),
            recordingEnabled: boolValue(json["meetingRecordingEnabled"]),
            joinPromptEnabled: boolValue(json["meetingJoinPromptEnabled"]),
            autoStartEnabled: boolValue(json["meetingAutoStartEnabled"]),
            autoStopEnabled: boolValue(json["meetingAutoStopEnabled"]),
            calendarHintsEnabled: boolValue(json["meetingUseCalendarHints"]),
            saveAudioEnabled: boolValue(json["meetingSaveAudio"])
        )
    }

    @MainActor
    static func snapshot(from settingsManager: SettingsManager) -> Snapshot {
        Snapshot(
            summarizationEnabled: settingsManager.meetingSummarizationEnabled,
            recordingEnabled: settingsManager.meetingRecordingEnabled,
            joinPromptEnabled: settingsManager.meetingJoinPromptEnabled,
            autoStartEnabled: settingsManager.meetingAutoStartEnabled,
            autoStopEnabled: settingsManager.meetingAutoStopEnabled,
            calendarHintsEnabled: settingsManager.meetingUseCalendarHints,
            saveAudioEnabled: settingsManager.meetingSaveAudio
        )
    }

    @MainActor
    static func write(from settingsManager: SettingsManager, into json: inout [String: Any]) {
        encode(snapshot(from: settingsManager), into: &json)
    }

    nonisolated static func encode(_ snapshot: Snapshot, into json: inout [String: Any]) {
        set(snapshot.summarizationEnabled, forKey: "meetingSummarizationEnabled", in: &json)
        set(snapshot.recordingEnabled, forKey: "meetingRecordingEnabled", in: &json)
        set(snapshot.joinPromptEnabled, forKey: "meetingJoinPromptEnabled", in: &json)
        set(snapshot.autoStartEnabled, forKey: "meetingAutoStartEnabled", in: &json)
        set(snapshot.autoStopEnabled, forKey: "meetingAutoStopEnabled", in: &json)
        set(snapshot.calendarHintsEnabled, forKey: "meetingUseCalendarHints", in: &json)
        set(snapshot.saveAudioEnabled, forKey: "meetingSaveAudio", in: &json)
    }

    private nonisolated static func set(_ value: Bool?, forKey key: String, in json: inout [String: Any]) {
        if let value {
            json[key] = value
        } else {
            json.removeValue(forKey: key)
        }
    }

    private nonisolated static func boolValue(_ value: Any?) -> Bool? {
        switch value {
        case let bool as Bool:
            return bool
        case let number as NSNumber:
            return number.boolValue
        default:
            return nil
        }
    }
}
