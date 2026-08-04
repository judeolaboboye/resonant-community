import FluidAudio
import Foundation

enum TranscriptionSpacingDebug {

    static func logSuspiciousSampleIfNeeded(_ result: ASRResult, source: String) {
        // Raw transcript/token content can contain secrets. Never write it from
        // release builds, and require an explicit local opt-in even in DEBUG.
        guard isContentLoggingEnabled else { return }
        guard FragmentedWordRepair.shouldLogDebugSample(for: result.text) else { return }

        let tokenTimings = result.tokenTimings ?? []
        let preview = tokenTimings.prefix(64).enumerated().map { index, timing in
            String(
                format: "#%d id=%d token=\"%@\" start=%.2f end=%.2f conf=%.2f",
                index,
                timing.tokenId,
                escapedToken(timing.token),
                timing.startTime,
                timing.endTime,
                timing.confidence
            )
        }.joined(separator: " | ")

        let suffix = tokenTimings.count > 64
            ? String(format: " | ... (%d more tokens)", tokenTimings.count - 64)
            : ""

        NSLog(
            "[ASRSpacingDebug] source=%@ rawTranscript=\"%@\" tokenTimings=%@%@",
            source,
            result.text,
            preview.isEmpty ? "<none>" : preview,
            suffix
        )
    }

    static var isContentLoggingEnabled: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["RESONANT_ASR_SPACING_DEBUG"] == "1"
        #else
        false
        #endif
    }

    private static func escapedToken(_ token: String) -> String {
        token
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
}
