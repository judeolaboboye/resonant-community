import SwiftUI

private struct ClickableCursorModifier: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isCursorPushed = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                updateCursor(isHovering: hovering && isEnabled)
            }
            .onChange(of: isEnabled) { _, newValue in
                if !newValue {
                    updateCursor(isHovering: false)
                }
            }
            .onDisappear {
                updateCursor(isHovering: false)
            }
    }

    private func updateCursor(isHovering: Bool) {
        if isHovering, !isCursorPushed {
            NSCursor.pointingHand.push()
            isCursorPushed = true
        } else if !isHovering, isCursorPushed {
            NSCursor.pop()
            isCursorPushed = false
        }
    }
}

extension View {
    func clickableCursor() -> some View {
        modifier(ClickableCursorModifier())
    }
}
