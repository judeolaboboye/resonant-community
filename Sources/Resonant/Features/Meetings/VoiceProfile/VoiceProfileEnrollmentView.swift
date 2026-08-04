import SwiftUI

/// Voice ID enrollment UI: dial, read-aloud script, and record/save controls.
/// Lives in meeting settings (Voice ID was removed from onboarding so first-run
/// stays focused on dictation).
struct VoiceProfileEnrollmentView: View {
    @Environment(AppState.self) private var appState
    @State private var controller = MeetingVoiceProfileEnrollmentController()

    /// Analytics `source` property for enrollment events.
    let analyticsSource: String

    private var selectedInputDeviceUID: String? {
        appState.settingsManager.meetingUseSelectedMicrophone
            ? appState.settingsManager.inputDeviceUID
            : nil
    }

    private var minimumRemainingSeconds: Int {
        max(0, Int(ceil(MeetingVoiceProfileEnrollmentController.minimumDuration - controller.elapsed)))
    }

    var body: some View {
        VStack(spacing: 14) {
            VoiceEnrollmentDial(
                progress: controller.progress,
                level: controller.level,
                isRecording: controller.isRecording,
                isComplete: controller.hasEnrollment
            )
            .frame(width: 150, height: 150)

            VStack(spacing: 6) {
                Text("Read aloud")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text("Today I'm setting up Resonant to recognize my voice during an in-person meeting.")
                    .font(.system(size: 14, weight: .medium))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            statusView

            HStack(spacing: 10) {
                if controller.isRecording {
                    Button("Cancel") {
                        Task { await controller.cancel() }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                    Button(controller.canStopAndSave ? "Save Voice ID" : "\(minimumRemainingSeconds)s") {
                        Task {
                            await controller.stopAndSave()
                            appState.analyticsManager.capture("voice_profile_saved", properties: [
                                "source": analyticsSource
                            ])
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!controller.canStopAndSave)
                } else {
                    Button(controller.hasEnrollment ? "Record Again" : "Start Voice ID") {
                        appState.analyticsManager.capture("voice_profile_recording_started", properties: [
                            "source": analyticsSource
                        ])
                        Task {
                            await controller.start(selectedInputDeviceUID: selectedInputDeviceUID)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.isSaving)
                }
            }

            if let error = controller.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            controller.refresh()
        }
        .onDisappear {
            Task { await controller.cancelIfRecording() }
        }
        .animation(.spring(duration: 0.3), value: controller.isRecording)
        .animation(.spring(duration: 0.3), value: controller.hasEnrollment)
    }

    @ViewBuilder
    private var statusView: some View {
        if controller.isSaving {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Saving Voice ID...")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        } else if controller.isRecording {
            Label("Keep speaking. Voice ID saves automatically.", systemImage: "waveform")
                .font(.callout.weight(.medium))
                .foregroundStyle(.blue)
        } else if controller.hasEnrollment {
            Label("Voice ID saved locally", systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.green)
        } else {
            Label("Optional — helps Room Mode tell when you are speaking", systemImage: "person.wave.2.fill")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
