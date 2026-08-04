import Foundation

/// Text-based echo suppression for meeting transcription.
///
/// When system audio (remote participants) leaks through speakers into the mic,
/// both channels transcribe the same speech. This suppressor detects and removes
/// mic utterances that are echoes of system audio by comparing word-set similarity
/// within a time window.
///
/// Ported from OpenOats AcousticEchoFilter — adapted for Resonant.
/// OpenOats explicitly avoids hardware AEC (VoiceProcessingIO) because it conflicts
/// with SystemAudioCapture's CoreAudio aggregate device, causing mic stream stalls.
enum MeetingEchoSuppressor {

    /// Remove mic utterances that are echoes of system audio.
    ///
    /// - Parameters:
    ///   - micUtterances: Mic-channel ("You") utterances — modified in place.
    ///   - systemUtterances: System-channel ("Them") utterances to compare against.
    ///   - window: Maximum time offset (seconds) between matching utterances.
    ///   - similarityThreshold: Jaccard similarity threshold for echo detection (0–1).
    ///   - minimumWordCount: Skip utterances shorter than this to avoid false positives.
    static func suppress(
        micUtterances: inout [MeetingUtterance],
        systemUtterances: [MeetingUtterance],
        window: TimeInterval = 1.75,
        similarityThreshold: Double = 0.78,
        minimumWordCount: Int = 4
    ) {
        guard !systemUtterances.isEmpty else { return }

        micUtterances.removeAll { mic in
            let words = mic.text.split(separator: " ")
            guard words.count >= minimumWordCount else { return false }

            let micWords = normalizedWords(mic.text)

            // Search system utterances in reverse (most recent first) for efficiency
            for sys in systemUtterances.reversed() {
                let timeDelta = abs(mic.timestamp.timeIntervalSince(sys.timestamp))
                guard timeDelta <= window else {
                    // If we've gone past the window going backwards, stop early
                    if sys.timestamp < mic.timestamp.addingTimeInterval(-window) {
                        break
                    }
                    continue
                }

                let sysWords = normalizedWords(sys.text)

                // Check Jaccard similarity
                if jaccard(micWords, sysWords) >= similarityThreshold {
                    return true
                }

                // Also check substring containment (one is a subset of the other)
                if micWords.isSubset(of: sysWords) || sysWords.isSubset(of: micWords) {
                    return true
                }
            }

            return false
        }
    }

    // MARK: - Private

    private static func normalizedWords(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .components(separatedBy: .alphanumerics.inverted)
                .filter { !$0.isEmpty }
        )
    }

    private static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty || !b.isEmpty else { return 0 }
        let intersection = a.intersection(b).count
        let union = a.union(b).count
        return Double(intersection) / Double(union)
    }
}
