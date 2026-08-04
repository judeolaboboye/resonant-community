import AppKit
import SwiftUI

/// Floats a tiny "⌘V" pill next to the mouse cursor after dictated text
/// falls back to the clipboard, so the user knows the text is waiting to be
/// pasted even if they never look at the notch.
///
/// The panel follows the cursor and dismisses when the user pastes (Cmd+V),
/// copies something else (the hint would be stale), or the timeout elapses.
@MainActor
final class CursorPasteHintController {

    /// Gap between the pointer hotspot and the pill, mirroring the offset of
    /// a drag badge so the hint reads as attached to the cursor.
    static let cursorOffset = CGPoint(x: 18, y: -22)

    private var panel: NSPanel?
    private var mouseMonitors: [Any] = []
    private var keyMonitors: [Any] = []
    private var dismissTask: Task<Void, Never>?
    private var staleClipboardTimer: Timer?
    private var expectedPasteboardChangeCount: Int = -1
    private var hintSize: CGSize = .zero

    // MARK: - Show / hide

    func show(timeout: Duration = .seconds(6)) {
        hide(animated: false)

        expectedPasteboardChangeCount = NSPasteboard.general.changeCount

        let panel = makePanel()
        self.panel = panel
        positionPanel(at: NSEvent.mouseLocation)
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }

        installMouseMonitors()
        installKeyMonitors()
        startStaleClipboardTimer()

        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.hide(animated: true)
        }
    }

    func hide(animated: Bool) {
        dismissTask?.cancel()
        dismissTask = nil
        staleClipboardTimer?.invalidate()
        staleClipboardTimer = nil
        for monitor in mouseMonitors + keyMonitors {
            NSEvent.removeMonitor(monitor)
        }
        mouseMonitors = []
        keyMonitors = []

        guard let panel else { return }
        self.panel = nil

        if animated {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.15
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.orderOut(nil)
            })
        } else {
            panel.orderOut(nil)
        }
    }

    // MARK: - Panel

    private func makePanel() -> NSPanel {
        let host = NSHostingView(rootView: CursorPasteHintView())
        host.sizingOptions = []
        let size = host.fittingSize
        hintSize = size
        host.frame = NSRect(origin: .zero, size: size)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level              = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        panel.backgroundColor    = .clear
        panel.isOpaque           = false
        panel.hasShadow          = false
        panel.ignoresMouseEvents = true
        panel.tabbingMode        = .disallowed
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
        panel.sharingType        = .none
        panel.contentView        = host
        return panel
    }

    private func positionPanel(at mouseLocation: CGPoint) {
        guard let panel else { return }
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        guard let screen else { return }

        let origin = Self.hintOrigin(
            mouseLocation: mouseLocation,
            hintSize: hintSize,
            screenFrame: screen.visibleFrame
        )
        panel.setFrameOrigin(origin)
    }

    /// Places the hint below-right of the pointer, flipping to the opposite
    /// side when it would run off the screen edge.
    static func hintOrigin(
        mouseLocation: CGPoint,
        hintSize: CGSize,
        screenFrame: CGRect
    ) -> CGPoint {
        var x = mouseLocation.x + cursorOffset.x
        var y = mouseLocation.y + cursorOffset.y - hintSize.height

        if x + hintSize.width > screenFrame.maxX {
            x = mouseLocation.x - cursorOffset.x - hintSize.width
        }
        if y < screenFrame.minY {
            y = mouseLocation.y - cursorOffset.y
        }

        x = min(max(x, screenFrame.minX), max(screenFrame.minX, screenFrame.maxX - hintSize.width))
        y = min(max(y, screenFrame.minY), max(screenFrame.minY, screenFrame.maxY - hintSize.height))
        return CGPoint(x: x, y: y)
    }

    // MARK: - Dismissal triggers

    private func installMouseMonitors() {
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.positionPanel(at: NSEvent.mouseLocation)
            }
        }) {
            mouseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            Task { @MainActor [weak self] in
                self?.positionPanel(at: NSEvent.mouseLocation)
            }
            return event
        }) {
            mouseMonitors.append(local)
        }
    }

    /// Dismisses the hint the moment the user pastes. Global keyDown monitors
    /// only deliver events when the app is trusted for Accessibility; when
    /// they stay silent (e.g. the fallback was caused by a missing permission)
    /// the timeout still tears the hint down.
    private func installKeyMonitors() {
        let isPaste: (NSEvent) -> Bool = { event in
            event.modifierFlags.contains(.command)
                && event.charactersIgnoringModifiers?.lowercased() == "v"
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard isPaste(event) else { return }
            Task { @MainActor [weak self] in
                self?.hide(animated: true)
            }
        }) {
            keyMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if isPaste(event) {
                Task { @MainActor [weak self] in
                    self?.hide(animated: true)
                }
            }
            return event
        }) {
            keyMonitors.append(local)
        }
    }

    /// If the user copies something else, the clipboard no longer holds the
    /// dictated text and the hint would be misleading.
    private func startStaleClipboardTimer() {
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if NSPasteboard.general.changeCount != self.expectedPasteboardChangeCount {
                    self.hide(animated: true)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        staleClipboardTimer = timer
    }
}

/// The pill itself: clipboard glyph + "⌘V", sized to stay unobtrusive.
private struct CursorPasteHintView: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 9, weight: .semibold))
            Text("⌘V")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .glassPill(elevation: .raised)
        .padding(6)  // headroom so the pill's shadow isn't clipped by the panel
    }
}
