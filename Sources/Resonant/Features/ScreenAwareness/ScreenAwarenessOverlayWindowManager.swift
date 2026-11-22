import AppKit
import SwiftUI

/// Floating overlay for screen-awareness answers. Separate from
/// `NotchWindowManager`/the dictation Notch entirely — same NSPanel recipe
/// (borderless, non-activating, floats above everything, joins all Spaces)
/// but its own class, so this feature can't regress dictation's overlay.
@MainActor
final class ScreenAwarenessOverlayWindowManager {
    private var panel: NSPanel?
    private let content = ScreenAwarenessOverlayContent()
    private var autoDismissTask: Task<Void, Never>?
    private var outsideClickMonitor: Any?

    private static let autoDismissDelay: Duration = .seconds(20)

    func showRecording() {
        content.phase = .recording
        present()
    }

    func showAwaitingApproval() {
        content.phase = .awaitingApproval
        present()
    }

    func showThinking() {
        content.phase = .thinking
        present()
    }

    func showAnswer(_ text: String) {
        content.phase = .answer(text)
        present()
        scheduleAutoDismiss()
    }

    func showError(_ message: String) {
        content.phase = .error(message)
        present()
        scheduleAutoDismiss()
    }

    func dismiss() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        removeOutsideClickMonitor()
        panel?.orderOut(nil)
    }

    func teardown() {
        dismiss()
        panel?.close()
        panel = nil
    }

    // MARK: - Panel

    private func present() {
        let panel = panel ?? makePanel()
        self.panel = panel
        positionPanel(panel)
        panel.orderFrontRegardless()
        installOutsideClickMonitor()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 160),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.tabbingMode = .disallowed
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let view = ScreenAwarenessOverlayView(
            content: content,
            onCopy: { text in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            },
            onDismiss: { [weak self] in self?.dismiss() }
        )
        let host = NSHostingView(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        panel.contentView = host
        return panel
    }

    private func positionPanel(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        panel.layoutIfNeeded()
        let size = panel.contentView?.fittingSize ?? NSSize(width: 480, height: 160)
        let screenFrame = screen.visibleFrame
        let originX = screenFrame.midX - size.width / 2
        let originY = screenFrame.maxY - screenFrame.height / 3 - size.height
        panel.setFrame(NSRect(x: originX, y: originY, width: size.width, height: size.height), display: true)
    }

    private func scheduleAutoDismiss() {
        autoDismissTask?.cancel()
        autoDismissTask = Task { [weak self] in
            try? await Task.sleep(for: Self.autoDismissDelay)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
        outsideClickMonitor = nil
    }
}

private extension NSView {
    func layoutIfNeeded() {
        layoutSubtreeIfNeeded()
    }
}
