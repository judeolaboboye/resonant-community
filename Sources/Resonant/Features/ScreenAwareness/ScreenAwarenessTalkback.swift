import AVFoundation

/// Optional spoken talkback for screen-awareness answers, using macOS's
/// built-in on-device speech synthesizer. No network call, no ElevenLabs —
/// constructed lazily and only when the user turns the setting on (default
/// off).
@MainActor
final class ScreenAwarenessTalkback {
    private let synthesizer = AVSpeechSynthesizer()

    func speak(_ text: String) {
        guard !text.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    var isSpeaking: Bool {
        synthesizer.isSpeaking
    }
}
