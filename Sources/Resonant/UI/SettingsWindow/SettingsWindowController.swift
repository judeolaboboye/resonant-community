import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {

    private var window: NSWindow?

    func show(appState: AppState, selectedTab: SettingsTab = .home) {
        if let existing = window {
            appState.selectedSettingsTab = selectedTab
            appState.isShowingSettings = selectedTab.isSettingsTab
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate()
            refreshAudioDevicesSoon(appState: appState)
            return
        }

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = ""
        win.titlebarAppearsTransparent = true
        win.tabbingMode = .disallowed
        win.center()
        win.minSize = CGSize(width: LayoutTier.windowMinWidth, height: 600)
        win.isReleasedWhenClosed = false

        win.contentView = makeHostingView(appState: appState)

        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate()
        refreshAudioDevicesSoon(appState: appState)
    }

    func close() {
        window?.close()
    }

    func miniaturize() {
        guard let window else { return }
        if !window.isMiniaturized {
            window.miniaturize(nil)
        }
    }

    // MARK: - Hosting View

    private func makeHostingView(appState: AppState) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: AnyView(SettingsView().environment(appState)))
        // Prevent SwiftUI from auto-resizing the window via updateAnimatedWindowSize,
        // which causes a re-entrant layout crash (SIGABRT) when display configuration
        // changes (e.g. clamshell mode, monitor connect/disconnect).
        host.sizingOptions = []
        return host
    }

    private func refreshAudioDevicesSoon(appState: AppState) {
        Task { @MainActor in
            await Task.yield()
            appState.audioInputDeviceManager.refresh()
        }
    }
}
