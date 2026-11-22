import SwiftUI

/// Settings tab for the screen-awareness feature: hold Left Option, ask a
/// question about what's on screen, get an answer from the local `claude`
/// CLI. Entirely local/free — no cloud STT/TTS, no paid API key.
struct ScreenAwarenessSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var settings = appState.settingsManager
        let hasCollision = settings.hotkeyTriggers.contains(.custom(keyCode: ScreenAwarenessTrigger.keyCode))
        let claudeCLIAvailable = ClaudeCLIRunner.isAvailable()

        SettingsPage(title: "Screen Awareness") {
            SettingsCardSection(
                "Trigger",
                footer: "Hold \(ScreenAwarenessTrigger.displayName), ask a question about what's on your screen, release."
            ) {
                SettingsToggleRow("Screen Awareness", isOn: $settings.screenAwarenessEnabled)

                SettingsRowDivider()
                SettingsValueRow("Key") {
                    Text(ScreenAwarenessTrigger.displayName)
                        .foregroundStyle(.secondary)
                }

                if hasCollision {
                    SettingsRowDivider()
                    SettingsSectionBody {
                        Text("Left Option is already bound to Dictation — remove it there (Settings → Dictation → Backup key) to use it for Screen Awareness.")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            SettingsCardSection(
                "Voice",
                footer: "Uses the same local, on-device dictation model as everywhere else in Resonant — no cloud speech-to-text."
            ) {
                SettingsToggleRow(
                    "Speak the answer aloud",
                    detail: "Uses macOS's built-in voice, on this Mac only. No network call.",
                    isOn: $settings.screenAwarenessTalkbackEnabled
                )
            }

            SettingsCardSection("Claude Code") {
                SettingsSectionBody {
                    HStack(spacing: 6) {
                        Image(systemName: claudeCLIAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(claudeCLIAvailable ? .green : .orange)
                        Text(claudeCLIAvailable
                            ? "Claude Code CLI found — uses your existing Claude subscription."
                            : "Claude Code CLI not found. Install it and make sure `claude` runs from a terminal.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            SettingsCardSection(
                "Actions",
                footer: "Every request needs Touch ID or your password to confirm before anything happens — that's a one-time approval per request, not per individual action it takes."
            ) {
                SettingsSectionBody {
                    Text("Beyond answering questions, this can open an app or a URL, or look something up on the web. It can't run arbitrary commands, edit files, or do anything beyond that.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onChange(of: settings.screenAwarenessEnabled) { _, _ in
            appState.refreshScreenAwarenessHotkeyAvailability()
        }
    }
}
