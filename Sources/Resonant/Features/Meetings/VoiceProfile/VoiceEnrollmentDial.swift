import SwiftUI

/// Radial tick dial with a trimmed progress ring and a level-reactive pulsing
/// core. Shared by Voice ID enrollment surfaces (meeting settings, deep links).
struct VoiceEnrollmentDial: View {
    let progress: Double
    let level: Float
    let isRecording: Bool
    let isComplete: Bool

    private let segmentCount = 48

    private var clampedProgress: Double {
        min(1, max(0, progress))
    }

    private var accentColor: Color {
        isComplete ? .green : .blue
    }

    var body: some View {
        GeometryReader { geometry in
            let diameter = min(geometry.size.width, geometry.size.height)
            let radius = diameter / 2
            let tickHeight = diameter * 0.08
            let tickWidth = max(2, diameter * 0.014)
            let pulse = CGFloat(level) * diameter * 0.08

            ZStack {
                ForEach(0..<segmentCount, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(color(for: index))
                        .frame(width: tickWidth, height: tickHeight)
                        .offset(y: -(radius - tickHeight / 2))
                        .rotationEffect(.degrees(Double(index) / Double(segmentCount) * 360))
                }

                Circle()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 14)
                    .frame(width: diameter * 0.68, height: diameter * 0.68)

                Circle()
                    .trim(from: 0, to: clampedProgress)
                    .stroke(
                        accentColor,
                        style: StrokeStyle(lineWidth: 14, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: diameter * 0.68, height: diameter * 0.68)

                Circle()
                    .fill(accentColor.opacity(isRecording ? 0.12 : 0.08))
                    .frame(width: diameter * 0.42 + pulse, height: diameter * 0.42 + pulse)

                Image(systemName: isComplete ? "checkmark" : "waveform")
                    .font(.system(size: diameter * 0.18, weight: .semibold))
                    .foregroundStyle(accentColor)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .accessibilityLabel(isComplete ? "Voice ID complete" : "Voice ID progress")
        .accessibilityValue("\(Int(clampedProgress * 100)) percent")
    }

    private func color(for index: Int) -> Color {
        let filled = Double(index + 1) / Double(segmentCount) <= clampedProgress
        if filled {
            return accentColor
        }
        return Color.primary.opacity(isRecording ? 0.16 : 0.1)
    }
}
