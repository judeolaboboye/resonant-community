import AppKit
import SwiftUI

@MainActor
final class MeetingScratchpadWindowController {

    private enum Layout {
        static let expandedWidth: CGFloat = 384
        static let expandedMinHeight: CGFloat = 528
        static let collapsedPillWidth: CGFloat = 24
        static let collapsedPillHeight: CGFloat = 64
        // Padding around the pill so the drop shadow (radius 16, y 8) is not
        // clipped by the window frame, which made the bottom of the pill look
        // misshapen.
        static let collapsedShadowPad: CGFloat = 24
        static let collapsedWidth: CGFloat = collapsedPillWidth + collapsedShadowPad * 2
        static let collapsedHeight: CGFloat = collapsedPillHeight + collapsedShadowPad * 2
        static let edgeInset: CGFloat = 16
    }

    private var window: NSPanel?
    private var hostingView: NSHostingView<AnyView>?
    private weak var companionState: MeetingCompanionState?

    var isVisible: Bool { window?.isVisible ?? false }

    func show(
        state: MeetingCompanionState,
        manager: MeetingRecorderManager?,
        notepad: MeetingNotepad,
        onStop: @escaping () -> Void,
        onStartDetected: @escaping () -> Void = {},
        onDismissDetected: @escaping () -> Void = {},
        microphoneOptions: [AudioInputDevice] = [],
        selectedMicrophoneUID: String? = nil,
        onSelectMicrophone: @escaping (String?) -> Void = { _ in },
        onOpenAudioSettings: @escaping () -> Void = {},
        onClose: (() -> Void)? = nil
    ) {
        companionState = state

        let resolvedOnClose: () -> Void = onClose ?? { [weak self] in self?.close() }
        let view = MeetingCompanionPanelView(
            state: state,
            manager: manager,
            notepad: notepad,
            onStop: onStop,
            onExpand: { [weak self] in self?.setExpanded(true) },
            onCollapse: { [weak self] in self?.setExpanded(false) },
            onClose: resolvedOnClose,
            onStartDetected: onStartDetected,
            onDismissDetected: onDismissDetected,
            microphoneOptions: microphoneOptions,
            selectedMicrophoneUID: selectedMicrophoneUID,
            onSelectMicrophone: onSelectMicrophone,
            onOpenAudioSettings: onOpenAudioSettings
        )

        if window == nil {
            let panel = MeetingCompanionPanel(
                contentRect: frame(expanded: state.isExpanded),
                styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
                backing: .buffered,
                defer: false
            )
            panel.title = "Meeting Companion"
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isFloatingPanel = true
            panel.becomesKeyOnlyIfNeeded = false
            panel.worksWhenModal = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.minSize = CGSize(width: Layout.collapsedWidth, height: Layout.collapsedHeight)
            panel.maxSize = CGSize(width: Layout.expandedWidth, height: NSScreen.main?.visibleFrame.height ?? 900)
            panel.level = .floating
            panel.animationBehavior = .utilityWindow
            panel.isMovableByWindowBackground = false
            panel.backgroundColor = .clear
            panel.isOpaque = false
            // The SwiftUI sidebar and collapsed pill draw their own shaped shadows.
            // AppKit's panel shadow is rectangular for this transparent borderless
            // window, which shows up as a faint grey line behind the collapsed pill.
            panel.hasShadow = false
            panel.sharingType = .none
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.setFrameAutosaveName("MeetingCompanionPanel")

            let hostingView = NSHostingView(rootView: AnyView(view))
            hostingView.sizingOptions = []
            hostingView.wantsLayer = true
            hostingView.layer?.backgroundColor = NSColor.clear.cgColor
            hostingView.layer?.isOpaque = false
            panel.contentView = hostingView
            self.hostingView = hostingView
            window = panel
        } else {
            hostingView?.rootView = AnyView(view)
        }

        setExpanded(state.isExpanded, animated: false)
        window?.orderFrontRegardless()
    }

    func setExpanded(_ expanded: Bool, animated: Bool = true) {
        companionState?.isExpanded = expanded
        guard let window else { return }
        window.setFrame(frame(expanded: expanded), display: true, animate: animated)
    }

    func close() {
        window?.orderOut(nil)
        hostingView?.rootView = AnyView(EmptyView())
        companionState?.hide()
    }

    private final class MeetingCompanionPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    private func frame(expanded: Bool) -> NSRect {
        let screenFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        if expanded {
            let width = min(Layout.expandedWidth, max(320, screenFrame.width - 2 * Layout.edgeInset))
            let height = max(Layout.expandedMinHeight, screenFrame.height - 2 * Layout.edgeInset)
            return NSRect(
                x: screenFrame.maxX - width - Layout.edgeInset,
                y: screenFrame.minY + Layout.edgeInset,
                width: width,
                height: min(height, screenFrame.height - 2 * Layout.edgeInset)
            )
        }

        // Pill is centered inside the panel; offset the panel so the pill's
        // visible right edge sits Layout.edgeInset from the screen edge.
        let pillRightInset = Layout.edgeInset + Layout.collapsedPillWidth / 2
        return NSRect(
            x: screenFrame.maxX - pillRightInset - Layout.collapsedWidth / 2,
            y: screenFrame.midY - Layout.collapsedHeight / 2,
            width: Layout.collapsedWidth,
            height: Layout.collapsedHeight
        )
    }
}
