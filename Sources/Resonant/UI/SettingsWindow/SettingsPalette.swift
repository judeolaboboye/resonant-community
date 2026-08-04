import AppKit
import SwiftUI

enum SettingsPalette {
    static let windowBackground = adaptiveColor(
        light: NSColor(calibratedRed: 0.985, green: 0.988, blue: 0.992, alpha: 1),
        dark: NSColor.windowBackgroundColor
    )
    static let sidebarBackground = adaptiveColor(
        light: NSColor(calibratedWhite: 0.955, alpha: 1),
        dark: NSColor.underPageBackgroundColor
    )
    static let modalSidebarBackground = adaptiveColor(
        light: NSColor(calibratedRed: 0.975, green: 0.969, blue: 0.955, alpha: 1),
        dark: NSColor.windowBackgroundColor
    )
    static let cardBackground = adaptiveColor(
        light: NSColor(calibratedWhite: 1.0, alpha: 1),
        dark: NSColor.controlBackgroundColor
    )
    static let border = adaptiveColor(
        light: NSColor(calibratedWhite: 0.0, alpha: 0.10),
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.14)
    )
    static let accent = Color(nsColor: .controlAccentColor)

    static let modalBorder = adaptiveColor(
        light: NSColor(calibratedWhite: 0.0, alpha: 0.12),
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.18)
    )

    static let elevatedBackground = adaptiveColor(
        light: NSColor(calibratedWhite: 0.97, alpha: 1),
        dark: NSColor.controlBackgroundColor
    )

    static let mutedCardBackground = adaptiveColor(
        light: NSColor(calibratedWhite: 0.0, alpha: 0.035),
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.06)
    )

    static let accentFill = adaptiveColor(
        light: NSColor.controlAccentColor.withAlphaComponent(0.10),
        dark: NSColor.controlAccentColor.withAlphaComponent(0.20)
    )

    static let accentBorder = adaptiveColor(
        light: NSColor.controlAccentColor.withAlphaComponent(0.14),
        dark: NSColor.controlAccentColor.withAlphaComponent(0.28)
    )

    static let infoFill = adaptiveColor(
        light: NSColor.systemBlue.withAlphaComponent(0.10),
        dark: NSColor.systemBlue.withAlphaComponent(0.18)
    )

    static let infoBorder = adaptiveColor(
        light: NSColor.systemBlue.withAlphaComponent(0.16),
        dark: NSColor.systemBlue.withAlphaComponent(0.28)
    )

    static let infoText = adaptiveColor(
        light: NSColor(calibratedRed: 0.19, green: 0.38, blue: 0.66, alpha: 1),
        dark: NSColor(calibratedRed: 0.58, green: 0.75, blue: 0.98, alpha: 1)
    )

    static let destructiveFill = adaptiveColor(
        light: NSColor.systemRed.withAlphaComponent(0.10),
        dark: NSColor.systemRed.withAlphaComponent(0.18)
    )

    static let destructiveBorder = adaptiveColor(
        light: NSColor.systemRed.withAlphaComponent(0.14),
        dark: NSColor.systemRed.withAlphaComponent(0.24)
    )

    static let timelineTrack = adaptiveColor(
        light: NSColor(white: 0.0, alpha: 0.06),
        dark: NSColor(white: 1.0, alpha: 0.08)
    )

    static let warmBackdrop = adaptiveColor(
        light: NSColor(calibratedWhite: 1.0, alpha: 1),
        dark: NSColor.windowBackgroundColor
    )

    static let shadow = Color.black.opacity(0.05)
    static let subtleShadow = Color.black.opacity(0.025)

    // Semantic accents, shared across feed, journal, and progression surfaces.
    // Prefer these over per-view Color(red:green:blue:) literals.
    static let semanticBlue = Color(red: 0.22, green: 0.52, blue: 0.93)
    static let semanticGreen = Color(red: 0.27, green: 0.67, blue: 0.44)
    static let semanticAmber = Color(red: 0.89, green: 0.59, blue: 0.16)
    static let semanticRed = Color(red: 0.74, green: 0.28, blue: 0.24)

    static var pageGradient: LinearGradient {
        LinearGradient(
            colors: [windowBackground],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var cardGradient: LinearGradient {
        LinearGradient(
            colors: [cardBackground],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static func adaptiveColor(light: NSColor, dark: NSColor) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let match = appearance.bestMatch(from: [.darkAqua, .vibrantDark])
                return (match == .darkAqua || match == .vibrantDark) ? dark : light
            }
        )
    }
}
