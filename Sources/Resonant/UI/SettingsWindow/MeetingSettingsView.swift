import Defaults
import SwiftUI

/// Settings tab for meeting recording configuration.
/// Recordings can stay manual or follow conservative join/leave automation.
struct MeetingSettingsView: View {

    @Environment(AppState.self) private var appState

    /// Derived "When a meeting starts" mode. Maps to the underlying
    /// join-prompt / auto-start booleans so existing meeting automation
    /// keeps working without a schema migration.
    private enum MeetingStartMode: String, CaseIterable, Identifiable {
        case off
        case prompt
        case auto

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .off:    "Off"
            case .prompt: "Prompt me"
            case .auto:   "Auto-record"
            }
        }

        var detail: String {
            switch self {
            case .off:
                "Recording only starts when you start it manually."
            case .prompt:
                "Resonant asks before starting whenever it detects a call."
            case .auto:
                "Resonant starts recording as soon as it detects a call."
            }
        }
    }

    var body: some View {
        @Bindable var settings = appState.settingsManager

        content(settings: settings)
            .onChange(of: settings.meetingRecordingEnabled) { oldValue, enabled in
                guard enabled != oldValue else { return }
                appState.analyticsManager.capture("meeting_setting_changed", properties: [
                    "setting": "recording_enabled",
                    "enabled": enabled
                ])
                if enabled,
                   !Defaults[.meetingCalendarHintsAutoEnabled] {
                    Defaults[.meetingCalendarHintsAutoEnabled] = true
                    settings.meetingUseCalendarHints = true
                }
                guard enabled else { return }
                Task {
                    await appState.ensureMeetingRecordingSetupAuthorization()
                }
            }
    }

    // MARK: - Page

    @ViewBuilder
    private func content(settings: SettingsManager) -> some View {
        @Bindable var settings = settings

        SettingsPage(title: "Meetings") {
            SettingsCardSection("Recording") {
                recordingSection(settings: settings)
            }
            .id(SettingsAnchor.meetingRecording)

            SettingsCardSection("Audio") {
                recordingDependentContent(
                    isEnabled: settings.meetingRecordingEnabled,
                    disabledMessage: "Enable meeting recording to change the microphone used for calls."
                ) {
                    audioSection(settings: settings)
                }
            }

            SettingsCardSection(
                "Voice ID",
                footer: "A short local voice sample helps in-room meetings tell when you are speaking. Stored on this Mac only."
            ) {
                SettingsSectionBody {
                    VoiceProfileEnrollmentView(analyticsSource: "meeting_settings")
                }
            }

            SettingsCardSection("How it works") {
                SettingsSectionBody {
                    howItWorksSection
                }
            }
            .id(SettingsAnchor.meetingHowItWorks)

            SettingsCardSection("Automation") {
                recordingDependentContent(
                    isEnabled: settings.meetingRecordingEnabled,
                    disabledMessage: "Enable meeting recording before changing join prompts, auto-start, or auto-stop."
                ) {
                    automationSection(settings: settings)
                }
            }
            .id(SettingsAnchor.meetingAutomation)

            if AppFeatureVisibility.hostedServices {
                SettingsCardSection("AI Features") {
                    recordingDependentContent(
                        isEnabled: settings.meetingRecordingEnabled,
                        disabledMessage: "Enable meeting recording before changing post-meeting AI features."
                    ) {
                        aiFeaturesSection(settings: settings)
                    }
                }
                .id(SettingsAnchor.meetingAIFeatures)
            }

            SettingsCardSection("Privacy") {
                recordingDependentContent(
                    isEnabled: settings.meetingRecordingEnabled,
                    disabledMessage: "Enable meeting recording before changing meeting retention options."
                ) {
                    privacySection(settings: settings)
                }
            }
            .id(SettingsAnchor.meetingPrivacy)

            SettingsCardSection(
                "Advanced",
                footer: "Most people can leave these alone. Webhooks send meeting events to your own HTTPS endpoint."
            ) {
                SettingsDrillInRow(
                    title: "Advanced settings",
                    detail: "Transcription engine, model downloads, and post-meeting delivery.",
                    systemImage: "slider.horizontal.3"
                ) {
                    appState.pendingSettingsBackTarget = .meetingSettings
                    appState.selectedSettingsTab = .meetingAdvanced
                }
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

    // MARK: - Sections

    @ViewBuilder
    private func recordingSection(settings: SettingsManager) -> some View {
        @Bindable var settings = settings
        SettingsToggleRow("Meeting recording", isOn: $settings.meetingRecordingEnabled)

        SettingsRowDivider()
        SettingsSectionBody {
            Text(settings.meetingRecordingEnabled
                ? "Start recordings from the notch menu, or opt into the automation options below."
                : "Turn on meeting recording to start calls manually or use join/leave automation.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var howItWorksSection: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 250), spacing: 10, alignment: .topLeading)],
            alignment: .leading,
            spacing: 8
        ) {
            HowItWorksRow(icon: "hand.tap.fill", text: "Start from the notch or settings")
            HowItWorksRow(icon: "mic.fill", text: "Mic and system audio recorded separately")
            HowItWorksRow(icon: "cpu", text: "Transcription runs on-device by default")
            HowItWorksRow(icon: "lock.shield.fill", text: "Audio stays local unless you choose a cloud model")
            HowItWorksRow(icon: "doc.text.fill", text: "Saved as markdown in your workspace")
        }
    }

    @ViewBuilder
    private func audioSection(settings: SettingsManager) -> some View {
        @Bindable var settings = settings
        let systemDefault = appState.audioInputDeviceManager.effectiveDevice(for: nil)?.name ?? "System Default"
        let selectedDevice = appState.audioInputDeviceManager.device(with: settings.inputDeviceUID)?.name

        SettingsPickerRow(
            "Your voice",
            detail: "Microphone that captures your side of the call.",
            selection: $settings.inputDeviceUID
        ) {
            Text("\(systemDefault) (Mac default)").tag(Optional<String>.none)
            ForEach(appState.audioInputDeviceManager.devices) { device in
                Text(device.isSystemDefault ? "\(device.name) (Mac default)" : device.name)
                    .tag(Optional(device.id))
            }
        }
        .onChange(of: settings.inputDeviceUID) { _, newValue in
            settings.meetingUseSelectedMicrophone = newValue != nil
            appState.didChangeInputSelection()
        }

        if settings.inputDeviceUID != nil,
           selectedDevice == nil {
            SettingsRowDivider()
            SettingsSectionBody {
                SettingsCallout(
                    "That microphone is unavailable right now. Resonant will use \(systemDefault) until it comes back.",
                    tone: .warning
                )
            }
        }

        SettingsRowDivider()
        SettingsValueRow(
            "Other person's audio",
            detail: "Captured automatically from system output — whatever your Mac is playing during the call."
        ) {
            SettingsStatusPill(
                title: "Automatic",
                systemImage: "speaker.wave.2.fill",
                tint: .secondary
            )
        }
    }

    @ViewBuilder
    private func automationSection(settings: SettingsManager) -> some View {
        @Bindable var settings = settings

        let startModeBinding = Binding<MeetingStartMode>(
            get: {
                if settings.meetingJoinPromptEnabled { return .prompt }
                if settings.meetingAutoStartEnabled  { return .auto }
                return .off
            },
            set: { newValue in
                let previous: MeetingStartMode
                if settings.meetingJoinPromptEnabled       { previous = .prompt }
                else if settings.meetingAutoStartEnabled   { previous = .auto }
                else                                       { previous = .off }
                guard newValue != previous else { return }

                switch newValue {
                case .off:
                    settings.meetingJoinPromptEnabled = false
                    settings.meetingAutoStartEnabled  = false
                case .prompt:
                    settings.meetingAutoStartEnabled  = false
                    settings.meetingJoinPromptEnabled = true
                case .auto:
                    settings.meetingJoinPromptEnabled = false
                    settings.meetingAutoStartEnabled  = true
                }

                appState.analyticsManager.capture("meeting_setting_changed", properties: [
                    "setting": "start_mode",
                    "value": newValue.rawValue
                ])

                if newValue != .off {
                    Task {
                        await appState.ensureMeetingAutomationSetupAuthorization()
                    }
                }
            }
        )

        let currentMode = startModeBinding.wrappedValue

        SettingsPickerRow(
            "When a meeting starts",
            detail: currentMode.detail,
            selection: startModeBinding,
            presentation: .segmented
        ) {
            ForEach(MeetingStartMode.allCases) { mode in
                Text(mode.displayName).tag(mode)
            }
        }

        SettingsRowDivider()
        SettingsToggleRow(
            "Use calendar to improve detection",
            detail: "Cross-reference Apple Calendar events so scheduled meetings are recognized sooner.",
            isOn: $settings.meetingUseCalendarHints
        )
        .onChange(of: settings.meetingUseCalendarHints) { oldValue, isEnabled in
            guard isEnabled != oldValue else { return }
            appState.analyticsManager.capture("meeting_setting_changed", properties: [
                "setting": "calendar_hints_enabled",
                "enabled": isEnabled
            ])
            Task {
                if isEnabled {
                    await appState.ensureMeetingCalendarAuthorization()
                }
                await appState.refreshMeetingDetection()
            }
        }

        SettingsRowDivider()
        SettingsToggleRow(
            "Stop recording when the meeting ends",
            detail: "Reacts to app quit, end-of-meeting signals, or the scheduled end time.",
            isOn: $settings.meetingAutoStopEnabled
        )
        .onChange(of: settings.meetingAutoStopEnabled) { oldValue, isEnabled in
            guard isEnabled != oldValue else { return }
            appState.analyticsManager.capture("meeting_setting_changed", properties: [
                "setting": "auto_stop_enabled",
                "enabled": isEnabled
            ])
        }
    }

    @ViewBuilder
    private func aiFeaturesSection(settings: SettingsManager) -> some View {
        @Bindable var settings = settings
        let summaryControlsEnabled = settings.cloudProcessingEnabled
        let signedInEmail = appState.authManager.userEmail?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSignedInEmail = signedInEmail?.isEmpty == false
        let transcriptEmailControlsEnabled = hasSignedInEmail
        let transcriptEmailDetail: String = {
            if hasSignedInEmail {
                return "After recording, send the transcript and meeting link only to \(signedInEmail ?? "your account email")."
            } else {
                return "Sign in to email completed meeting transcripts to yourself."
            }
        }()

        SettingsValueRow(
            "Meeting summaries",
            detail: "Generate a summary with key decisions and action items as soon as the call ends."
        ) {
            Toggle("", isOn: $settings.meetingSummarizationEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(!summaryControlsEnabled)
        }

        if settings.meetingSummarizationEnabled {
            SettingsRowDivider()
            SettingsPickerRow(
                "Summary style",
                detail: settings.meetingSummaryStyle.detail,
                selection: $settings.meetingSummaryStyle
            ) {
                ForEach(MeetingSummaryStyle.allCases) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .disabled(!summaryControlsEnabled)
            .onChange(of: settings.meetingSummaryStyle) { oldValue, newValue in
                guard newValue != oldValue else { return }
                appState.analyticsManager.capture("meeting_setting_changed", properties: [
                    "setting": "summary_style",
                    "value": newValue.rawValue
                ])
            }
        }

        SettingsRowDivider()
        SettingsValueRow(
            "Email transcript to me",
            detail: transcriptEmailDetail
        ) {
            Toggle("", isOn: $settings.meetingTranscriptEmailEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(!transcriptEmailControlsEnabled)
        }
        .onChange(of: settings.meetingTranscriptEmailEnabled) { oldValue, isEnabled in
            guard isEnabled != oldValue else { return }
            appState.analyticsManager.capture("meeting_setting_changed", properties: [
                "setting": "transcript_email_enabled",
                "enabled": isEnabled
            ])
        }
    }

    @ViewBuilder
    private func privacySection(settings: SettingsManager) -> some View {
        @Bindable var settings = settings
        SettingsToggleRow(
            "Save meeting audio",
            detail: "When disabled, only the text transcript is kept.",
            isOn: $settings.meetingSaveAudio
        )
    }
}

// MARK: - Local helpers

private struct HowItWorksRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
