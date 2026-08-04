import SwiftUI

/// Celebratory overlay: level up, hot streak, achievement.
struct ExpressionView: View {

    let expression: ExpressionType

    @State private var scale: CGFloat = 0.7
    @State private var opacity: Double = 0

    var body: some View {
        VStack(spacing: 6) {
            Text(emoji)
                .font(.system(size: 28))

            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.82)

            Text(subtitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(2)
                .minimumScaleFactor(0.82)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.black.opacity(0.85))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(accentColor.opacity(0.5), lineWidth: 1)
                )
        )
        .scaleEffect(scale)
        .opacity(opacity)
        .onAppear {
            withAnimation(.spring(duration: 0.4, bounce: 0.5)) {
                scale = 1
                opacity = 1
            }
        }
    }

    private var emoji: String {
        switch expression {
        case .levelUp:        "⚡️"
        case .hotStreak:      "🔥"
        case .achievement:    "🏆"
        }
    }

    private var title: String {
        switch expression {
        case .levelUp(let name):       "Level Up — \(name)"
        case .hotStreak(let count):    "\(count)x Hot Streak"
        case .achievement(let t, _):   t
        }
    }

    private var subtitle: String {
        switch expression {
        case .levelUp:                 "Keep dictating to unlock more"
        case .hotStreak(let count):    "\(count) dictations in a row"
        case .achievement(_, let msg): msg
        }
    }

    private var accentColor: Color {
        switch expression {
        case .levelUp:     .yellow
        case .hotStreak:   .orange
        case .achievement: .blue
        }
    }
}
