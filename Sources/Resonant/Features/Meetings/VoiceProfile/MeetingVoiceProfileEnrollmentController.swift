import Foundation
import Observation

@MainActor
@Observable
final class MeetingVoiceProfileEnrollmentController {
    private let store: MeetingVoiceProfileStore
    private var recorder: AudioRecorder?
    private var startedAt: Date?
    private var elapsedTask: Task<Void, Never>?
    private var isCompletingAutomatically = false

    private(set) var isRecording = false
    private(set) var isSaving = false
    private(set) var level: Float = 0
    private(set) var elapsed: TimeInterval = 0
    private(set) var hasEnrollment: Bool
    private(set) var errorMessage: String?

    init(store: MeetingVoiceProfileStore = MeetingVoiceProfileStore()) {
        self.store = store
        self.hasEnrollment = store.hasEnrollment
    }

    var progress: Double {
        min(1, max(0, elapsed / Self.recommendedDuration))
    }

    var canStopAndSave: Bool {
        elapsed >= Self.minimumDuration
    }

    var isBusy: Bool {
        isRecording || isSaving
    }

    static var minimumDuration: TimeInterval {
        MeetingVoiceProfileStore.minimumEnrollmentDuration
    }

    static var recommendedDuration: TimeInterval {
        MeetingVoiceProfileStore.recommendedEnrollmentDuration
    }

    func refresh() {
        hasEnrollment = store.hasEnrollment
    }

    func start(selectedInputDeviceUID: String?) async {
        guard !isBusy else { return }

        errorMessage = nil
        elapsed = 0
        level = 0
        isCompletingAutomatically = false

        let recorder = AudioRecorder()
        recorder.onLevelUpdate = { [weak self] newLevel in
            await MainActor.run {
                self?.level = newLevel
            }
        }

        do {
            _ = try await recorder.start(selectedInputDeviceUID: selectedInputDeviceUID)
            self.recorder = recorder
            startedAt = Date()
            isRecording = true
            startElapsedPolling()
        } catch {
            self.recorder = nil
            errorMessage = error.localizedDescription
        }
    }

    func stopAndSave() async {
        guard isRecording, let recorder else { return }
        guard canStopAndSave || isCompletingAutomatically else {
            errorMessage = "Keep speaking until the ring reaches the first mark."
            return
        }

        isRecording = false
        isSaving = true
        stopElapsedPolling()

        do {
            guard let url = try await recorder.stop() else {
                throw MeetingVoiceProfileStoreError.emptyAudio
            }
            try store.saveEnrollment(from: url)
            try? FileManager.default.removeItem(at: url)
            hasEnrollment = true
            level = 0
            elapsed = max(elapsed, Self.minimumDuration)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }

        self.recorder = nil
        startedAt = nil
        isCompletingAutomatically = false
        isSaving = false
    }

    func cancelIfRecording() async {
        guard isRecording else { return }
        await cancel()
    }

    func cancel() async {
        stopElapsedPolling()
        if let recorder {
            await recorder.cancel()
        }
        recorder = nil
        startedAt = nil
        isRecording = false
        isSaving = false
        isCompletingAutomatically = false
        level = 0
    }

    private func startElapsedPolling() {
        stopElapsedPolling()
        elapsedTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let startedAt = self.startedAt else { continue }
                self.elapsed = Date().timeIntervalSince(startedAt)

                if self.elapsed >= Self.recommendedDuration, self.isRecording {
                    self.isCompletingAutomatically = true
                    await self.stopAndSave()
                    break
                }
            }
        }
    }

    private func stopElapsedPolling() {
        elapsedTask?.cancel()
        elapsedTask = nil
    }
}
