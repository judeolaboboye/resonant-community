import AppKit
import SwiftUI

/// Behind-window vibrancy so the desktop glows through translucent chrome
/// (sidebars, onboarding canvas). Pair with a low-opacity wash from
/// `SettingsPalette` when the surface should read as white.
struct VibrancyBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

/// Elevation tiers for the shared depth system. Use these instead of ad-hoc
/// `.shadow(...)` stacks so every surface sits on the same lighting model.
enum ResonantElevation {
    /// Cards resting on the window canvas.
    case resting
    /// Hover lift, popovers, drag states.
    case raised
    /// Detached panels, HUDs, and floating companions.
    case floating
}

extension View {
    @ViewBuilder
    func resonantShadow(_ elevation: ResonantElevation) -> some View {
        switch elevation {
        case .resting:
            self.shadow(color: .black.opacity(0.04), radius: 8, y: 2)
        case .raised:
            self.shadow(color: .black.opacity(0.08), radius: 16, y: 6)
        case .floating:
            self
                .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
                .shadow(color: .black.opacity(0.16), radius: 24, y: 12)
        }
    }
}

/// Shared glass treatment for floating surfaces (companion pill, HUD panels,
/// modals). Renders Liquid Glass on macOS 26+, and a material fill with a
/// top-lit edge highlight on earlier systems.
private struct GlassSurfaceModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let elevation: ResonantElevation

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .clipShape(shape)
                .glassEffect(.regular, in: shape)
                .resonantShadow(elevation)
        } else {
            content
                .background(shape.fill(.regularMaterial))
                .clipShape(shape)
                .overlay(
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.22),
                                Color.white.opacity(0.04)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.75
                    )
                )
                .resonantShadow(elevation)
        }
    }
}

extension View {
    /// Rounded-rectangle glass surface.
    func glassSurface(
        cornerRadius: CGFloat = 24,
        elevation: ResonantElevation = .floating
    ) -> some View {
        modifier(GlassSurfaceModifier(
            shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
            elevation: elevation
        ))
    }

    /// Capsule glass surface, for pills and compact indicators.
    func glassPill(elevation: ResonantElevation = .floating) -> some View {
        modifier(GlassSurfaceModifier(
            shape: Capsule(style: .continuous),
            elevation: elevation
        ))
    }
}
