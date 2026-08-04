import AVFoundation
import Combine

@MainActor
final class MemoPlaybackController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playingMemoID: UUID?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var playbackRate: Float = 1.0

    private var player: AVAudioPlayer?
    private var progressTimer: Timer?

    func togglePlayback(for memoID: UUID, audioURL: URL) {
        do {
            if playingMemoID != memoID {
                try loadPlayer(for: memoID, audioURL: audioURL)
            }

            if isPlaying {
                pause()
            } else {
                player?.rate = playbackRate
                player?.play()
                isPlaying = true
                startProgressTimer()
            }
        } catch {
            stop()
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopProgressTimer()
    }

    func stop() {
        stopProgressTimer()
        player?.stop()
        player = nil
        playingMemoID = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        let clamped = min(max(time, 0), player.duration)
        player.currentTime = clamped
        currentTime = clamped
    }

    func setRate(_ rate: Float) {
        playbackRate = rate
        player?.rate = rate
    }

    static let availableRates: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    static func rateLabel(_ rate: Float) -> String {
        if rate == 1.0 { return "1x" }
        if rate.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0fx", rate)
        }
        return String(format: "%.2gx", rate)
    }

    static func formattedTime(_ t: TimeInterval) -> String {
        let total = Int(max(t, 0))
        let minutes = total / 60
        let seconds = total % 60
        return "\(minutes):\(String(format: "%02d", seconds))"
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.stopProgressTimer()
            self.isPlaying = false
            self.currentTime = self.duration
        }
    }

    private func loadPlayer(for memoID: UUID, audioURL: URL) throws {
        stop()
        let player = try AVAudioPlayer(contentsOf: audioURL)
        player.delegate = self
        player.enableRate = true
        player.rate = playbackRate
        player.prepareToPlay()
        self.player = player
        playingMemoID = memoID
        duration = player.duration
        currentTime = 0
    }

    private func startProgressTimer() {
        stopProgressTimer()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let player = self.player, self.isPlaying else { return }
                self.currentTime = player.currentTime
            }
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }
}
