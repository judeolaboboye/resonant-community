import Foundation

/// Identifiers for the meeting transcription backends users can select.
/// Stored as raw strings in `Defaults` via `SettingsManager.meetingTranscriptionBackend`.
enum MeetingBackendKind: String, CaseIterable, Sendable {
    case parakeet
    case qwen3
    case cohere
    case deepgram

    var displayName: String {
        switch self {
        case .parakeet: return "Parakeet TDT v3"
        case .qwen3: return "Qwen3 ASR"
        case .cohere: return "Cohere Transcribe"
        case .deepgram: return "Deepgram Nova-3"
        }
    }

    /// Why this backend can't be used right now, or nil when it's usable.
    ///
    /// The two cases are surfaced differently in the picker: a
    /// `.requiresNewerOS` backend stays visible but disabled with its reason
    /// so the user understands the gate, while a `.hidden` backend is omitted
    /// from the list entirely.
    enum Unavailability: Equatable {
        /// Listed but unselectable on this OS; the string is shown to the user.
        case requiresNewerOS(String)
        /// Omitted from the picker entirely.
        case hidden
    }

    var unavailability: Unavailability? {
        switch self {
        case .parakeet:
            return nil
        case .deepgram:
            // Keep the enum/coder path for forward compatibility, but do not
            // expose Deepgram until the matching Convex proxy action is deployed.
            return .hidden
        case .qwen3, .cohere:
            // Both ship INT8/ANE weights that require the macOS 15 ANE runtime.
            if #available(macOS 15, *) { return nil }
            return .requiresNewerOS("Requires macOS 15")
        }
    }

    /// Whether this backend can be selected on the running OS.
    var isAvailable: Bool { unavailability == nil }

    /// Whether this backend appears in the settings picker. OS-gated backends
    /// still appear (disabled, with a reason); only `.hidden` ones are omitted.
    var isListedInPicker: Bool { unavailability != .hidden }
}

/// Resolves a `MeetingBackendKind` to a fresh backend instance.
/// Two instances are produced per meeting (mic + system); shared model
/// weights are deduplicated inside `MeetingSharedModelStore`.
enum MeetingBackendFactory {
    static func make(_ kind: MeetingBackendKind) -> any MeetingTranscriptionBackend {
        switch kind {
        case .parakeet:
            return MeetingParakeetBackend()
        case .qwen3:
            if #available(macOS 15, *) {
                return MeetingQwen3Backend()
            }
            return MeetingParakeetBackend()
        case .cohere:
            if #available(macOS 15, *) {
                return MeetingCohereBackend()
            }
            return MeetingParakeetBackend()
        case .deepgram:
            return MeetingDeepgramBackend()
        }
    }
}
