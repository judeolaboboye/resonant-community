import SwiftUI

// MARK: - Action Tone (shared palette for icon buttons)

enum DetailActionTone: Equatable {
    case accent
    case neutral
    case info
    case locked
    case destructive

    var background: Color {
        switch self {
        case .accent:      SettingsPalette.accentFill
        case .neutral:     SettingsPalette.cardBackground
        case .info:        SettingsPalette.infoFill
        case .locked:      SettingsPalette.mutedCardBackground
        case .destructive: SettingsPalette.destructiveFill
        }
    }

    var border: Color {
        switch self {
        case .accent:      SettingsPalette.accentBorder
        case .neutral:     SettingsPalette.border.opacity(0.18)
        case .info:        SettingsPalette.infoBorder
        case .locked:      SettingsPalette.border.opacity(0.18)
        case .destructive: SettingsPalette.destructiveBorder
        }
    }

    var foreground: Color {
        switch self {
        case .accent:      SettingsPalette.infoText
        case .neutral:     .secondary
        case .info:        SettingsPalette.infoText
        case .locked:      .secondary
        case .destructive: .red
        }
    }
}

// MARK: - Icon Button

struct DetailIconButton: View {
    let systemImage: String
    var tone: DetailActionTone = .neutral
    var tooltip: String? = nil

    @State private var isHovered = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(tone.foreground)
            .frame(width: SettingsLayout.controlMinHeight, height: SettingsLayout.controlMinHeight)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? tone.background.opacity(1.3) : tone.background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(tone.border, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.14)) {
                    isHovered = hovering
                }
            }
            .scaleEffect(isHovered ? 1.06 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHovered)
            .help(tooltip ?? "")
    }
}

// MARK: - Compact Audio Player

struct CompactAudioPlayerView: View {
    @ObservedObject var playbackController: MemoPlaybackController
    let itemID: UUID
    let audioURL: URL
    var showRateControl: Bool = true

    private var isActive: Bool {
        playbackController.playingMemoID == itemID
    }
    private var isPlaying: Bool {
        isActive && playbackController.isPlaying
    }
    private var current: TimeInterval {
        isActive ? playbackController.currentTime : 0
    }
    private var total: TimeInterval {
        isActive ? playbackController.duration : 0
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                playbackController.togglePlayback(for: itemID, audioURL: audioURL)
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Slider(
                value: Binding(
                    get: { total > 0 ? current / total : 0 },
                    set: { newValue in
                        if total > 0 {
                            playbackController.seek(to: newValue * total)
                        }
                    }
                ),
                in: 0...1
            )
            .controlSize(.mini)

            Text("\(MemoPlaybackController.formattedTime(current)) / \(MemoPlaybackController.formattedTime(total))")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .fixedSize()

            if showRateControl {
                Menu {
                    ForEach(MemoPlaybackController.availableRates, id: \.self) { rate in
                        Button {
                            playbackController.setRate(rate)
                        } label: {
                            let label = MemoPlaybackController.rateLabel(rate)
                            if rate == playbackController.playbackRate {
                                Label(label, systemImage: "checkmark")
                            } else {
                                Text(label)
                            }
                        }
                    }
                } label: {
                    Text(MemoPlaybackController.rateLabel(playbackController.playbackRate))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .frame(minWidth: 44, minHeight: SettingsLayout.controlMinHeight)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }
}

// MARK: - Distill Prompt Sheet

struct DistillPromptSheet: View {
    @Binding var prompt: String
    let isProcessing: Bool
    let error: String?
    let onCancel: () -> Void
    let onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Distill memo")
                .font(.system(size: 18, weight: .semibold))

            Text("Describe what you want back from the memo.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            TextEditor(text: $prompt)
                .font(.system(size: 13))
                .frame(height: 140)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )

            if let error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()

                Button("Cancel", action: onCancel)

                Button(isProcessing ? "Distilling..." : "Distill", action: onSubmit)
                    .buttonStyle(.borderedProminent)
                    .disabled(isProcessing || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
