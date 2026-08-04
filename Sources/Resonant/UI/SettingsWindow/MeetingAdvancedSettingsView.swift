import Defaults
import SwiftUI

/// Sub-page for Meetings advanced settings: transcription model, room speaker
/// model, and post-meeting webhooks. Reached via a drill-in row on the main
/// Meetings settings page.
struct MeetingAdvancedSettingsView: View {

    @Environment(AppState.self) private var appState
    @State private var speakerModelDownloaded = MeetingSpeakerDiarizer.isDownloaded()
    @State private var speakerModelDownloading = false
    @State private var speakerModelProgress = 0.0
    @State private var speakerModelError: String?
    @State private var voiceProfileEnrolled = MeetingVoiceProfileStore().hasEnrollment

    private let voiceProfileRefreshTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        @Bindable var settings = appState.settingsManager

        SettingsPage(
            title: "Meeting advanced",
            subtitle: "Transcription engine, model downloads, and post-meeting delivery."
        ) {
            SettingsBackLink(target: .meetingSettings) {
                appState.selectedSettingsTab = .meetingSettings
            }

            SettingsCardSection("Transcription model") {
                recordingDependentContent(
                    isEnabled: settings.meetingRecordingEnabled,
                    disabledMessage: "Enable meeting recording to choose or download meeting transcription models."
                ) {
                    transcriptionModelSection(settings: settings)
                }
            }
            .id(SettingsAnchor.meetingTranscriptionModel)

            SettingsCardSection("Room speaker model") {
                recordingDependentContent(
                    isEnabled: settings.meetingRecordingEnabled,
                    disabledMessage: "Enable meeting recording to download the Room Mode speaker model."
                ) {
                    speakerModelSection()
                }
            }
            .id(SettingsAnchor.meetingSpeakerModel)

            SettingsCardSection(
                "Webhooks",
                footer: "Send meeting events to your own HTTPS endpoint after a recording finishes."
            ) {
                recordingDependentContent(
                    isEnabled: settings.meetingRecordingEnabled,
                    disabledMessage: "Enable meeting recording before configuring post-meeting webhooks."
                ) {
                    webhookSection(settings: settings)
                }
            }
            .id(SettingsAnchor.meetingWebhooks)
        }
        .onAppear {
            speakerModelDownloaded = MeetingSpeakerDiarizer.isDownloaded()
            voiceProfileEnrolled = MeetingVoiceProfileStore().hasEnrollment
        }
        .onReceive(voiceProfileRefreshTimer) { _ in
            let current = MeetingVoiceProfileStore().hasEnrollment
            if current != voiceProfileEnrolled {
                voiceProfileEnrolled = current
            }
        }
    }

    @ViewBuilder
    private func recordingDependentContent<Content: View>(
        isEnabled: Bool,
        disabledMessage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
                .disabled(!isEnabled)
                .opacity(isEnabled ? 1 : 0.55)

            if !isEnabled {
                SettingsRowDivider()
                SettingsSectionBody {
                    Text(disabledMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func transcriptionModelSection(settings: SettingsManager) -> some View {
        @Bindable var settings = settings
        let listedKinds = MeetingBackendKind.allCases.filter {
            $0.isListedInPicker
                && (AppRuntime.hasHostedServices || $0 != .deepgram)
                && (AppRuntime.distributionFlavor == .official || $0 != .cohere)
        }
        let downloader = appState.meetingBackendDownloader
        let kind = settings.meetingTranscriptionBackend
        let isRecording = appState.meetingRecorderManager?.isRecording == true
        let isDownloaded = MeetingBackendDownloader.isDownloaded(kind)
        let isDownloading = downloader.activeKind == kind
        let backendBinding = Binding<MeetingBackendKind>(
            get: { settings.meetingTranscriptionBackend },
            set: { newValue in
                // OS-gated backends are listed but disabled; ignore taps on them.
                if newValue.unavailability != nil { return }
                settings.meetingTranscriptionBackend = newValue
            }
        )

        Group {
            SettingsPickerRow(
                "Transcription model",
                detail: Self.backendDescription(kind),
                selection: backendBinding
            ) {
                ForEach(listedKinds, id: \.self) { kind in
                    Text(backendPickerLabel(kind))
                        .tag(kind)
                        .help(Self.backendHelp(kind))
                }
            }
            .disabled(isRecording || downloader.activeKind != nil)

            SettingsRowDivider()
            SettingsValueRow("Model status", detail: Self.backendHelp(kind)) {
                downloadStatusRow(
                    kind: kind,
                    isDownloaded: isDownloaded,
                    isDownloading: isDownloading,
                    progress: isDownloading ? downloader.progress : 0
                )
            }

            if let error = downloader.lastError, downloader.activeKind == nil {
                SettingsRowDivider()
                SettingsSectionBody {
                    SettingsCallout(error, tone: .warning)
                }
            }

            if kind == .cohere {
                SettingsRowDivider()
                SettingsSectionBody {
                    SettingsCallout(
                        "Cohere has no auto language detection. Meetings transcribe using your current system locale and fall back to English when unsupported.",
                        systemImage: "globe"
                    )
                }
            }

            if kind == .deepgram {
                SettingsRowDivider()
                SettingsSectionBody {
                    SettingsCallout(
                        "Deepgram sends speech segments through Resonant's Convex backend for cloud transcription. No provider API key is stored on this Mac.",
                        systemImage: "cloud"
                    )
                }
            }

            if isRecording {
                SettingsRowDivider()
                SettingsSectionBody {
                    Text("Stop the current recording to switch transcription models.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onChange(of: settings.meetingTranscriptionBackend) { _, _ in
            appState.meetingBackendDownloader.clearError()
        }
    }

    @ViewBuilder
    private func speakerModelSection() -> some View {
        let saveAudioEnabled = appState.settingsManager.saveAudioEnabled

        SettingsValueRow(
            "Room speaker model",
            detail: "Optional speaker separation for Room Mode and imported audio."
        ) {
            HStack(spacing: 8) {
                if speakerModelDownloading {
                    ProgressView(value: speakerModelProgress)
                        .progressViewStyle(.linear)
                        .frame(width: 120)
                    Text("\(Int(speakerModelProgress * 100))%")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else if speakerModelDownloaded {
                    SettingsStatusPill(
                        title: "Ready",
                        detail: "Room Mode",
                        systemImage: "checkmark.circle.fill",
                        tint: .green
                    )
                } else {
                    Button("Download") {
                        Task { await downloadSpeakerModel() }
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                }
            }
        }

        if let speakerModelError {
            SettingsRowDivider()
            SettingsSectionBody {
                SettingsCallout(speakerModelError, tone: .warning)
            }
        }

        SettingsRowDivider()
        SettingsValueRow(
            "Your voice",
            detail: voiceProfileDetail(saveAudioEnabled: saveAudioEnabled)
        ) {
            SettingsStatusPill(
                title: voiceProfileStatusTitle(saveAudioEnabled: saveAudioEnabled),
                detail: voiceProfileStatusDetail,
                systemImage: voiceProfileStatusIcon(saveAudioEnabled: saveAudioEnabled),
                tint: voiceProfileStatusTint(saveAudioEnabled: saveAudioEnabled)
            )
        }
    }

    private func voiceProfileDetail(saveAudioEnabled: Bool) -> String {
        if voiceProfileEnrolled, speakerModelDownloaded {
            return "Captured from your dictations. Room Mode can label your audio as \"You\"."
        }
        if voiceProfileEnrolled {
            return "Voice sample saved locally. Download the Room speaker model before meetings can label your audio as \"You\"."
        }
        if saveAudioEnabled {
            return "Picked up automatically the next time you dictate for 12 seconds or more."
        }
        return "Automatic enrollment is paused while saved audio recordings are off."
    }

    private func voiceProfileStatusTitle(saveAudioEnabled: Bool) -> String {
        if voiceProfileEnrolled {
            return "Enrolled"
        }
        return saveAudioEnabled ? "Pending" : "Paused"
    }

    private var voiceProfileStatusDetail: String? {
        guard voiceProfileEnrolled else { return nil }
        return speakerModelDownloaded ? "Ready" : "Needs model"
    }

    private func voiceProfileStatusIcon(saveAudioEnabled: Bool) -> String {
        if voiceProfileEnrolled {
            return speakerModelDownloaded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        }
        return saveAudioEnabled ? "ellipsis.circle" : "pause.circle"
    }

    private func voiceProfileStatusTint(saveAudioEnabled: Bool) -> Color {
        if voiceProfileEnrolled {
            return speakerModelDownloaded ? .green : .orange
        }
        return .secondary
    }

    @MainActor
    private func downloadSpeakerModel() async {
        guard !speakerModelDownloaded, !speakerModelDownloading else { return }
        speakerModelDownloading = true
        speakerModelProgress = 0
        speakerModelError = nil
        defer { speakerModelDownloading = false }

        do {
            try await MeetingSpeakerDiarizer.downloadModels(onProgress: { progress in
                Task { @MainActor in
                    speakerModelProgress = progress
                }
            })
            speakerModelProgress = 1
            speakerModelDownloaded = MeetingSpeakerDiarizer.isDownloaded()
        } catch {
            speakerModelError = error.localizedDescription
        }
    }

    private func backendPickerLabel(_ kind: MeetingBackendKind) -> String {
        let base = kind == .parakeet ? "\(kind.displayName) (Default)" : kind.displayName
        // An unselectable backend should explain why it can't be picked at all.
        if case .requiresNewerOS(let reason) = kind.unavailability {
            return "\(base) \u{2022} \(reason)"
        }
        return base
    }

    @ViewBuilder
    private func downloadStatusRow(
        kind: MeetingBackendKind,
        isDownloaded: Bool,
        isDownloading: Bool,
        progress: Double
    ) -> some View {
        HStack(spacing: 8) {
            if isDownloading {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 120)
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else if isDownloaded {
                SettingsStatusPill(
                    title: "Ready",
                    detail: MeetingBackendDownloader.downloadSizeText(kind),
                    systemImage: "checkmark.circle.fill",
                    tint: .green
                )
            } else {
                Button("Download \(MeetingBackendDownloader.downloadSizeText(kind))") {
                    Task { await appState.meetingBackendDownloader.download(kind) }
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private static func backendDescription(_ kind: MeetingBackendKind) -> String {
        switch kind {
        case .parakeet:
            return "Best latency. ~5 s captions. English-leaning multilingual."
        case .qwen3:
            return "30 languages. Captions trail by ~7 s on dual-channel meetings."
        case .cohere:
            return "14 languages. Highest accuracy on supported codes; captions trail by ~8 s."
        case .deepgram:
            return "Cloud transcription through Deepgram Nova-3. No local model download."
        }
    }

    private static func backendHelp(_ kind: MeetingBackendKind) -> String {
        switch kind {
        case .parakeet: return "Parakeet TDT v3 — streaming, ~700 MB"
        case .qwen3: return "Qwen3 ASR — batch, ~1.7 GB (requires macOS 15)"
        case .cohere: return "Cohere Transcribe — batch, ~2 GB (requires macOS 15)"
        case .deepgram: return "Deepgram Nova-3 — cloud API"
        }
    }

    @ViewBuilder
    private func webhookSection(settings: SettingsManager) -> some View {
        @Bindable var settings = settings

        SettingsValueRow(
            "Post-meeting webhook",
            detail: "Send meeting transcript and metadata after a recording finishes."
        ) {
            Toggle("", isOn: $settings.meetingWebhookEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .onChange(of: settings.meetingWebhookEnabled) { oldValue, isEnabled in
            guard isEnabled != oldValue else { return }
            appState.analyticsManager.capture("meeting_setting_changed", properties: [
                "setting": "webhook_enabled",
                "enabled": isEnabled
            ])
            reconcileWebhookDestination(settings: settings)
        }

        if settings.meetingWebhookEnabled {
            SettingsRowDivider()
            SettingsTextFieldRow(
                "Webhook URL",
                detail: "HTTPS endpoint called when the meeting is ready.",
                placeholder: "https://your-webhook-url.com/endpoint",
                text: $settings.meetingWebhookURL,
                isMonospaced: true
            )
            .onChange(of: settings.meetingWebhookURL) { oldValue, newValue in
                guard oldValue != newValue else { return }
                reconcileWebhookDestination(settings: settings)
            }

            SettingsRowDivider()
            SettingsSecureFieldRow(
                "Signing secret",
                detail: "Optional shared secret used to verify requests.",
                placeholder: "Optional",
                text: $settings.meetingWebhookSecret,
                isMonospaced: true
            )

            SettingsRowDivider()
            MeetingWebhookDeliveryLogView()
        }
    }

    private func reconcileWebhookDestination(settings: SettingsManager) {
        Task { @MainActor in
            await appState.meetingWebhookSender.reconcileDestination(
                currentURL: settings.meetingWebhookURL,
                isEnabled: appState.canFireMeetingWebhooks
            )
        }
    }
}
