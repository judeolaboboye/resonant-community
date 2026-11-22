import SwiftUI

/// Visible, unmistakable "it's listening" cue while holding Left Option —
/// mirrors the intent of the Notch's live waveform without touching Notch
/// code at all.
private struct PulsingMicIcon: View {
    @State private var isPulsing = false

    var body: some View {
        Image(systemName: "mic.fill")
            .foregroundStyle(.red)
            .scaleEffect(isPulsing ? 1.35 : 1.0)
            .opacity(isPulsing ? 1.0 : 0.6)
            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear { isPulsing = true }
    }
}

@Observable
final class ScreenAwarenessOverlayContent {
    enum Phase: Equatable {
        case recording
        case awaitingApproval
        case thinking
        case answer(String)
        case error(String)
    }

    var phase: Phase = .recording
}

struct ScreenAwarenessOverlayView: View {
    let content: ScreenAwarenessOverlayContent
    let onCopy: (String) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            body(for: content.phase)
        }
        .padding(16)
        .frame(maxWidth: 480, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08))
        )
        .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
    }

    private var header: some View {
        HStack(spacing: 8) {
            statusIcon
            Text(statusText)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch content.phase {
        case .recording:
            PulsingMicIcon()
        case .awaitingApproval:
            Image(systemName: "touchid").foregroundStyle(.blue)
        case .thinking:
            ProgressView().controlSize(.small)
        case .answer:
            Image(systemName: "sparkles").foregroundStyle(.blue)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private var statusText: String {
        switch content.phase {
        case .recording: "Listening…"
        case .awaitingApproval: "Confirm with Touch ID / password…"
        case .thinking: "Looking at your screen…"
        case .answer: "Screen Awareness"
        case .error: "Screen Awareness"
        }
    }

    @ViewBuilder
    private func body(for phase: ScreenAwarenessOverlayContent.Phase) -> some View {
        switch phase {
        case .recording, .awaitingApproval, .thinking:
            EmptyView()
        case .answer(let text):
            ScrollView {
                Text(text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
            HStack {
                Spacer()
                Button("Copy") { onCopy(text) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        case .error(let message):
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }
}
