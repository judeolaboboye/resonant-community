import AppKit
import SwiftUI

/// Custom animatable pill shape that matches the hardware notch curvature.
/// Port of NotchShape from boring-notch-upstream.
struct NotchShape: Shape {

    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    init(topCornerRadius: CGFloat = 6, bottomCornerRadius: CGFloat = 14) {
        self.topCornerRadius = topCornerRadius
        self.bottomCornerRadius = bottomCornerRadius
    }

    func path(in rect: CGRect) -> Path {
        let topRadius = max(0, topCornerRadius)
        let bottomRadius = max(0, bottomCornerRadius)

        // Continuous (squircle-style) corners: each corner is a cubic curve
        // with both control points at the corner vertex, which yields zero
        // curvature where the curve meets the straight edges. Arms extend
        // ~1.5× the radius along the edges so curvature ramps in gradually
        // instead of starting abruptly like a circular arc.
        let smoothing: CGFloat = 1.5

        var topArm = topRadius * smoothing
        var bottomArm = bottomRadius * smoothing

        // Keep opposing corners from overlapping on short edges.
        let verticalSpan = topArm + bottomArm
        if verticalSpan > rect.height, verticalSpan > 0 {
            let scale = rect.height / verticalSpan
            topArm *= scale
            bottomArm *= scale
        }
        if (topRadius + bottomArm) * 2 > rect.width {
            bottomArm = max(0, rect.width / 2 - topRadius)
        }

        var path = Path()

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))

        let topLeftVertex = CGPoint(x: rect.minX + topRadius, y: rect.minY)
        path.addCurve(
            to: CGPoint(x: rect.minX + topRadius, y: rect.minY + topArm),
            control1: topLeftVertex,
            control2: topLeftVertex
        )

        path.addLine(to: CGPoint(x: rect.minX + topRadius, y: rect.maxY - bottomArm))

        let bottomLeftVertex = CGPoint(x: rect.minX + topRadius, y: rect.maxY)
        path.addCurve(
            to: CGPoint(x: rect.minX + topRadius + bottomArm, y: rect.maxY),
            control1: bottomLeftVertex,
            control2: bottomLeftVertex
        )

        path.addLine(to: CGPoint(x: rect.maxX - topRadius - bottomArm, y: rect.maxY))

        let bottomRightVertex = CGPoint(x: rect.maxX - topRadius, y: rect.maxY)
        path.addCurve(
            to: CGPoint(x: rect.maxX - topRadius, y: rect.maxY - bottomArm),
            control1: bottomRightVertex,
            control2: bottomRightVertex
        )

        path.addLine(to: CGPoint(x: rect.maxX - topRadius, y: rect.minY + topArm))

        let topRightVertex = CGPoint(x: rect.maxX - topRadius, y: rect.minY)
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control1: topRightVertex,
            control2: topRightVertex
        )

        path.closeSubpath()

        return path
    }
}

// MARK: - Size constants

enum NotchSizes {
    static let fallbackClosedWidth: CGFloat = 185
    static let fallbackClosedHeight: CGFloat = 36
    static let openWidth: CGFloat = 720
    static let openHeight: CGFloat = 192
    static let openExpandedHeight: CGFloat = 217
    static let idleOpenWidth: CGFloat = 480
    static let idleOpenHeight: CGFloat = 140
    static let minimalTextRowHeight: CGFloat = 44
    static let closedTopCornerRadius: CGFloat = 6
    static let closedBottomCornerRadius: CGFloat = 14
    static let openTopCornerRadius: CGFloat = 19
    static let openBottomCornerRadius: CGFloat = 24

    static func minimalStripSideWidth(for closedHeight: CGFloat) -> CGFloat {
        max(0, closedHeight - 10)
    }

    static func minimalStripContentWidth(for closedSize: CGSize) -> CGFloat {
        max(
            0,
            closedSize.width + (minimalStripSideWidth(for: closedSize.height) * 2)
        )
    }

    static func minimalStripWidth(for closedSize: CGSize) -> CGFloat {
        closedSize.width + (minimalStripSideWidth(for: closedSize.height) * 2) + 28
    }

    static func minimalStripHorizontalPadding(for closedSize: CGSize) -> CGFloat {
        max(0, (minimalStripWidth(for: closedSize) - minimalStripContentWidth(for: closedSize)) / 2)
    }
}

enum NotchMotion {
    // Island-style physics: opening bounces with visible overshoot, closing
    // settles critically damped. Width leads and height trails slightly so
    // the morph reads as a stretch, not a uniform scale.
    //
    // The bouncing overlay appears on every dictation, so Reduce Motion swaps
    // every spring for a short fade-style ease with no overshoot.
    private static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    static var openAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.15)
            : .spring(response: 0.38, dampingFraction: 0.72, blendDuration: 0)
    }

    static var openWidthAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.15)
            : .spring(response: 0.36, dampingFraction: 0.72, blendDuration: 0)
    }

    static var openHeightAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.15)
            : .spring(response: 0.42, dampingFraction: 0.78, blendDuration: 0)
    }

    static var closeAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.15)
            : .spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)
    }

    /// Default animation used for content transitions (uses the open spring).
    static var animation: Animation {
        openAnimation
    }

    /// CAMediaTimingFunction approximation for NSAnimationContext panel resizing.
    static var timingFunction: CAMediaTimingFunction {
        reduceMotion
            ? CAMediaTimingFunction(name: .easeOut)
            : CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)  // spring-like overshoot
    }

    /// Duration hint for NSAnimationContext (springs are time-independent but
    /// CoreAnimation needs an explicit duration).
    static var duration: Double { reduceMotion ? 0.15 : 0.42 }
}

// MARK: - Content transitions

private struct NotchBlurModifier: ViewModifier {
    let radius: CGFloat

    func body(content: Content) -> some View {
        content.blur(radius: radius)
    }
}

extension AnyTransition {
    /// Island-style content swap: outgoing content blurs away while the
    /// incoming content scales in — never a hard swap.
    static var notchContentSwap: AnyTransition {
        .asymmetric(
            insertion: .opacity
                .combined(with: .scale(scale: 0.94))
                .combined(with: .modifier(
                    active: NotchBlurModifier(radius: 6),
                    identity: NotchBlurModifier(radius: 0)
                )),
            removal: .opacity
                .combined(with: .modifier(
                    active: NotchBlurModifier(radius: 10),
                    identity: NotchBlurModifier(radius: 0)
                ))
        )
    }
}

@MainActor
func currentClosedNotchSize(screen: NSScreen? = NSScreen.main ?? NSScreen.screens.first) -> CGSize {
    guard let screen else {
        return CGSize(width: NotchSizes.fallbackClosedWidth, height: NotchSizes.fallbackClosedHeight)
    }

    var notchWidth = NotchSizes.fallbackClosedWidth
    var notchHeight = NotchSizes.fallbackClosedHeight

    if let topLeftPadding = screen.auxiliaryTopLeftArea?.width,
       let topRightPadding = screen.auxiliaryTopRightArea?.width {
        notchWidth = max(
            NotchSizes.fallbackClosedWidth,
            screen.frame.width - topLeftPadding - topRightPadding
        )
    }

    if screen.safeAreaInsets.top > 0 {
        notchHeight = screen.safeAreaInsets.top
    } else {
        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        notchHeight = max(NotchSizes.fallbackClosedHeight, menuBarHeight)
    }

    return CGSize(width: notchWidth, height: notchHeight)
}
