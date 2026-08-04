import AppKit
import Observation
import SwiftUI

/// Creates and manages the NSPanel that hosts the notch overlay.
/// Positioned at top-center of the primary display, above all other windows.
@MainActor
final class NotchWindowManager {
    private struct ScreenSnapshot: Sendable {
        let frame: CGRect
        let safeAreaTopInset: CGFloat
        let primaryScreenHeight: CGFloat

        var hasHardwareNotch: Bool {
            safeAreaTopInset > 0
        }
    }

    private enum PollingInterval {
        static let hoverOpen: Duration = .milliseconds(80)
        static let hoverIdle: Duration = .milliseconds(150)
        static let hoverRetracted: Duration = .milliseconds(220)
        static let hoverDisabled: Duration = .seconds(1)
        static let fullscreenBackup: Duration = .seconds(5)
    }

    private let coordinator: NotchCoordinator
    private unowned let appState: AppState
    private var panel: NSPanel?
    private var hoverTask: Task<Void, Never>?
    private var hoverPollingTask: Task<Void, Never>?
    private var panelShrinkTask: Task<Void, Never>?
    private var fullscreenCheckTask: Task<Void, Never>?
    private var retractionRefreshTask: Task<Void, Never>?
    private var isHoveringActivationArea = false
    private var lastTransitionTime: ContinuousClock.Instant = .now
    private var isHiddenForMissionControl = false

    private var usesDevelopmentScreenshotMode: Bool {
        #if DEBUG
        AppEnvironment.current == .development
        #else
        false
        #endif
    }

    /// True when the target screen has a hardware camera notch (safeAreaInsets.top > 0).
    /// On screens without a notch the panel auto-hides when idle.
    private var targetScreenHasNotch = false

    /// True when a non-notch screen has a fullscreen app active.
    /// Disables edge-hover activation (the fullscreen app owns the screen edge).
    private var isFullscreenActive = false

    /// When true the panel is positioned above the visible screen edge (invisible).
    /// It slides down for active states (recording/processing/error) or edge-hover.
    private var isRetracted = false

    /// Last *content* size requested for the panel. The window frame may be
    /// larger (overshoot bleed), so panel.frame.size can't be fed back into
    /// panelFrame without inflating twice.
    private var lastContentSize: CGSize?

    init(coordinator: NotchCoordinator, appState: AppState) {
        self.coordinator = coordinator
        self.appState = appState
    }

    // MARK: - Setup

    func setup() {
        let screen = targetScreen()
        let overlayMode = appState.settingsManager.overlayMode
        lastContentSize = coordinator.preferredSize(for: overlayMode)
        let panel = makePanel(screen: screen, size: coordinator.preferredSize(for: overlayMode))
        installContent(panel: panel)
        self.panel = panel

        // Retract (hide) when idle on screens without a hardware notch, or
        // when the user has opted to hide the idle notch overlay.
        targetScreenHasNotch = screen.safeAreaInsets.top > 0
        if (!targetScreenHasNotch || !appState.settingsManager.notchIdleVisible) && !usesDevelopmentScreenshotMode {
            isRetracted = true
            panel.setFrame(retractedFrame(screen: screen, size: coordinator.preferredSize(for: overlayMode)), display: true, animate: false)
            panel.alphaValue = 0
        }

        if appState.settingsManager.notchHidden {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }

        observeCoordinator()
        if !appState.settingsManager.notchHidden {
            startHoverPolling(panel: panel)
            startFullscreenMonitoring()
            scheduleRetractionRefresh()
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeSpaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(notchIdleVisibleChanged),
            name: .notchIdleVisibleChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(notchHiddenChanged),
            name: .notchHiddenChanged,
            object: nil
        )
    }

    func teardown() {
        hoverTask?.cancel()
        hoverPollingTask?.cancel()
        panelShrinkTask?.cancel()
        fullscreenCheckTask?.cancel()
        retractionRefreshTask?.cancel()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        isHoveringActivationArea = false
        isRetracted = false
        isFullscreenActive = false
        targetScreenHasNotch = false
        isHiddenForMissionControl = false
        panel?.close()
        panel = nil
    }

    // MARK: - Panel factory

    private func makePanel(screen: NSScreen, size: CGSize) -> NSPanel {
        let frame = panelFrame(screen: screen, size: size)

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level             = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        panel.backgroundColor   = .clear
        panel.isOpaque          = false
        panel.hasShadow         = false
        panel.ignoresMouseEvents = false
        panel.tabbingMode       = .disallowed
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.sharingType       = usesDevelopmentScreenshotMode ? .readOnly : .none  // visible to screenshots only in dev debug builds
        return panel
    }

    private func installContent(panel: NSPanel) {
        let content = NotchContentView(coordinator: coordinator)
            .environment(appState)
        let host = NSHostingView(rootView: content)
        host.sizingOptions = []
        host.frame = panel.contentView?.bounds ?? .zero
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
    }

    // MARK: - Frame calculation

    /// Spring-overshoot headroom: expanded states get extra window area so
    /// the SwiftUI morph can bounce past its target without clipping flat at
    /// the window edge. The closed notch hugs the hardware notch exactly so
    /// the window never blocks menu bar clicks.
    private func overshootBleed(for size: CGSize, screen: NSScreen) -> CGSize {
        let closedHeight = currentClosedNotchSize(screen: screen).height
        guard size.height > closedHeight + 1 else { return .zero }
        return CGSize(width: 32, height: 24)
    }

    private func windowSize(for size: CGSize, screen: NSScreen) -> CGSize {
        let bleed = overshootBleed(for: size, screen: screen)
        return CGSize(width: size.width + bleed.width, height: size.height + bleed.height)
    }

    private func panelFrame(screen: NSScreen, size: CGSize) -> NSRect {
        let window = windowSize(for: size, screen: screen)
        let screenFrame = screen.frame
        let x = round(screenFrame.midX - window.width / 2)
        let y = screenFrame.maxY - window.height

        return NSRect(origin: CGPoint(x: x, y: y), size: window)
    }

    /// Frame positioned just above the visible screen edge — panel is invisible.
    private func retractedFrame(screen: NSScreen, size: CGSize) -> NSRect {
        let window = windowSize(for: size, screen: screen)
        let screenFrame = screen.frame
        let x = round(screenFrame.midX - window.width / 2)
        return NSRect(origin: CGPoint(x: x, y: screenFrame.maxY), size: window)
    }

    private func targetScreen() -> NSScreen {
        if let pinnedId = appState.settingsManager.pinnedDisplayId {
            let cgId = CGDirectDisplayID(pinnedId)
            if let pinned = NSScreen.screens.first(where: { $0.displayID == cgId }) {
                return pinned
            }
        }
        return NSScreen.main ?? NSScreen.screens.first ?? NSScreen()

    }

    // MARK: - Hover detection

    private func startHoverPolling(panel: NSPanel) {
        hoverPollingTask?.cancel()
        hoverPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    // NSEvent.mouseLocation (AppKit space) — Quartz events use a
                    // flipped Y and can make the Dock edge trigger the notch zone.
                    // Target-screen gate: an adjacent display sharing an edge with
                    // the target (e.g. a screen physically below a pinned no-notch
                    // display) puts its dock at y ≈ 0 in AppKit coords, matching
                    // the target's maxY-based activation rect.
                    let mouseLocation = NSEvent.mouseLocation
                    let screen = self.targetScreen()
                    let shouldRevealHome = self.targetScreenHoverBounds(screen).contains(mouseLocation)
                        && self.hoverActivationFrame(for: panel, screen: screen).contains(mouseLocation)
                    self.setHomeHoverState(shouldRevealHome)
                }
                let interval = await MainActor.run { [weak self] in
                    self?.hoverPollingInterval() ?? PollingInterval.hoverDisabled
                }
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func targetScreenHoverBounds(_ screen: NSScreen) -> NSRect {
        var bounds = screen.frame
        // The activation rect intentionally extends above the display edge so
        // hovering the top pixel still counts. NSRect.contains excludes maxY,
        // so the target-screen gate needs the same allowance.
        bounds.size.height += 2
        return bounds
    }

    private func hoverActivationFrame(for panel: NSPanel, screen: NSScreen) -> NSRect {
        if appState.settingsManager.notchHidden { return .zero }

        // When retracted and idle, either provide edge-hover or disable entirely.
        if isRetracted && isRetractableCompactPresentation {
            if isFullscreenActive {
                return .zero  // No hover during fullscreen apps
            }
            return edgeActivationRect(screen: screen)
        }

        // While the notch is open or animating open, use a generous frame based on
        // the target (open) size so the mouse doesn't accidentally leave during the
        // panel resize animation, which would cause flickering.
        if coordinator.isOpen(for: appState.settingsManager.overlayMode) {
            let openSize = coordinator.preferredSize(for: appState.settingsManager.overlayMode)
            let openFrame = panelFrame(screen: screen, size: openSize)
            return openFrame.insetBy(dx: -18, dy: -12)
        }

        let closedFrame = panel.frame
        // Inset horizontally so the outer edges of the notch don't trigger on
        // casual mouse passes, and keep the top extension for boundary capture.
        let insetX: CGFloat = 20
        return NSRect(
            x: closedFrame.origin.x + insetX,
            y: closedFrame.origin.y,
            width: closedFrame.width - insetX * 2,
            height: closedFrame.height + 2  // extend past screen top edge — NSRect.contains excludes maxY
        )
    }

    /// Activation zone at the top-center of the screen for edge-hover reveal.
    /// On monitors without a hardware notch the panel retracts completely, so
    /// keep the hidden hover target shaped like the closed notch instead of a
    /// hairline edge strip. That lets the same physical spot reopen it after it
    /// has closed.
    private func edgeActivationRect(screen: NSScreen) -> NSRect {
        let closedSize = currentClosedNotchSize(screen: screen)
        let x = round(screen.frame.midX - closedSize.width / 2)
        let height = max(24, min(closedSize.height, 44))
        // Closed-notch-height zone at the very top; extends 2pt past maxY so
        // NSRect.contains captures the boundary pixel.
        return NSRect(x: x, y: screen.frame.maxY - height, width: closedSize.width, height: height + 2)
    }

    private var isRetractableCompactPresentation: Bool {
        coordinator.presentationStyle(for: appState.settingsManager.overlayMode) == .compact
            && !coordinator.showsHome
    }

    private func setHomeHoverState(_ isHovering: Bool) {
        if coordinator.homeHovered != isHovering {
            coordinator.homeHovered = isHovering
        }
        guard isHovering != isHoveringActivationArea else { return }

        // Hysteresis: ignore rapid state flips during animation.
        let now = ContinuousClock.now
        let elapsed = now - lastTransitionTime
        if elapsed < .milliseconds(300) { return }

        isHoveringActivationArea = isHovering
        lastTransitionTime = now
        hoverTask?.cancel()

        if isHovering {
            guard !coordinator.homeVisible else { return }
            hoverTask = Task { @MainActor [weak self] in
                // Longer dwell when retracted to avoid accidental triggers at screen edge
                let dwell: Duration = self?.isRetracted == true ? .milliseconds(400) : .milliseconds(350)
                try? await Task.sleep(for: dwell)
                guard let self,
                      !Task.isCancelled,
                      self.coordinator.homeVisible == false
                else { return }
                // Don't trigger home expansion when the notch is already open
                // (recording, processing, error). The manual resize to idle-open
                // size conflicts with the coordinator's preferred size, creating
                // a panel/content mismatch that causes layout glitches.
                guard self.coordinator.presentationStyle(for: self.appState.settingsManager.overlayMode) == .compact else { return }
                // Haptic fires only when we actually commit to expanding.
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)

                if self.isRetracted {
                    // Slide panel down from above the screen edge, then show home.
                    let screen = self.targetScreen()
                    let size = CGSize(width: NotchSizes.idleOpenWidth, height: NotchSizes.idleOpenHeight)
                    self.lastContentSize = size
                    if let panel = self.panel {
                        panel.alphaValue = 1
                        panel.setFrame(self.retractedFrame(screen: screen, size: size), display: true, animate: false)
                        let normalFrame = self.panelFrame(screen: screen, size: size)
                        NSAnimationContext.runAnimationGroup({ ctx in
                            ctx.duration = NotchMotion.duration
                            ctx.timingFunction = NotchMotion.timingFunction
                            panel.animator().setFrame(normalFrame, display: true)
                        }, completionHandler: nil)
                    }
                    self.coordinator.homeVisible = true
                } else {
                    // Pre-expand the panel BEFORE setting homeVisible so the frame is
                    // already correct when SwiftUI starts animating on the same frame.
                    self.resize(to: CGSize(width: NotchSizes.idleOpenWidth, height: NotchSizes.idleOpenHeight))
                    self.coordinator.homeVisible = true
                }
            }
        } else {
            guard coordinator.homeVisible else { return }
            hoverTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(200))
                guard let self,
                      !Task.isCancelled,
                      self.coordinator.homeVisible
                else { return }
                self.coordinator.homeVisible = false
                self.coordinator.currentTab = .home
            }
        }
    }

    // MARK: - Screen change

    @objc private func screensChanged() {
        // Defer frame update to the next run-loop tick — this notification fires
        // synchronously inside AppKit's display cycle, and calling setFrame here
        // can trigger a re-entrant layout crash in NSHostingView (SIGABRT).
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel else { return }
            let screen = self.targetScreen()
            let size = self.lastContentSize ?? panel.frame.size

            if self.isRetracted && self.isRetractableCompactPresentation {
                self.setFrameIfNeeded(panel, self.retractedFrame(screen: screen, size: size), animate: false)
                panel.alphaValue = 0
            } else {
                panel.alphaValue = 1
                self.setFrameIfNeeded(panel, self.panelFrame(screen: screen, size: size), animate: false)
            }
            self.scheduleRetractionRefresh()
            self.startFullscreenMonitoring()
        }
    }

    @objc private func activeSpaceChanged() {
        scheduleRetractionRefresh()
    }

    @objc private func notchIdleVisibleChanged() {
        // Force re-evaluation — clear cached retraction state so updateRetraction()
        // applies the new setting immediately.
        isRetracted = false
        scheduleRetractionRefresh()
    }

    @objc private func notchHiddenChanged() {
        guard let panel else { return }
        if appState.settingsManager.notchHidden {
            hoverPollingTask?.cancel()
            fullscreenCheckTask?.cancel()
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
            startHoverPolling(panel: panel)
            startFullscreenMonitoring()
            isRetracted = false
            scheduleRetractionRefresh()
        }
    }

    // MARK: - Mission Control hiding

    /// Dock becomes the frontmost app during Mission Control and Launchpad.
    /// Hide the panel so it doesn't overlap the scaled window previews.
    @objc private func appDidActivate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let isDock = app.bundleIdentifier == "com.apple.dock"
        updateMissionControlVisibility(isDock: isDock)
        scheduleRetractionRefresh()
    }

    private func updateMissionControlVisibility(isDock: Bool) {
        guard isDock != isHiddenForMissionControl else { return }
        isHiddenForMissionControl = isDock
        guard let panel else { return }

        if isDock {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    // MARK: - Retraction (no-notch screens & fullscreen)

    /// Polls retraction state (fullscreen detection on non-notch screens).
    private func startFullscreenMonitoring() {
        fullscreenCheckTask?.cancel()
        guard shouldMonitorFullscreenState() else { return }
        fullscreenCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshRetractionState()
                try? await Task.sleep(for: PollingInterval.fullscreenBackup)
            }
        }
    }

    private func shouldMonitorFullscreenState() -> Bool {
        !makeScreenSnapshot(from: targetScreen()).hasHardwareNotch
    }

    private func scheduleRetractionRefresh() {
        retractionRefreshTask?.cancel()
        retractionRefreshTask = Task { [weak self] in
            await self?.refreshRetractionState()
        }
    }

    private func refreshRetractionState() async {
        guard let panel else { return }
        let screen = targetScreen()
        let screenSnapshot = makeScreenSnapshot(from: screen)

        let isFullscreenActive = if screenSnapshot.hasHardwareNotch {
            false
        } else {
            await Task.detached(priority: .utility) {
                Self.isFullscreenAppActive(on: screenSnapshot)
            }.value
        }

        guard !Task.isCancelled, self.panel != nil else { return }

        targetScreenHasNotch = screenSnapshot.hasHardwareNotch
        self.isFullscreenActive = isFullscreenActive

        // Retract on any screen without a hardware notch, or when the user
        // has chosen to hide the idle notch overlay.
        let shouldRetract = !usesDevelopmentScreenshotMode
            && (!screenSnapshot.hasHardwareNotch || !appState.settingsManager.notchIdleVisible)

        guard shouldRetract != isRetracted else { return }
        isRetracted = shouldRetract

        if shouldRetract {
            // Retract immediately if idle; if active the next resize call will
            // keep the panel visible until the session ends.
            if isRetractableCompactPresentation {
                let size = coordinator.preferredSize(for: appState.settingsManager.overlayMode)
                let frame = retractedFrame(screen: screen, size: size)
                guard Self.framesDiffer(panel.frame, frame) else {
                    panel.alphaValue = 0
                    return
                }
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.25
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    panel.animator().setFrame(frame, display: true)
                }, completionHandler: { [weak panel] in
                    panel?.alphaValue = 0
                })
            }
        } else {
            // Screen now has a hardware notch — restore normal position.
            panel.alphaValue = 1
            let size = coordinator.preferredSize(for: appState.settingsManager.overlayMode)
            setFrameIfNeeded(panel, panelFrame(screen: screen, size: size), animate: false)
        }
    }

    private func setFrameIfNeeded(_ panel: NSPanel, _ frame: CGRect, animate: Bool) {
        guard Self.framesDiffer(panel.frame, frame) else { return }
        panel.setFrame(frame, display: true, animate: animate)
    }

    private static func framesDiffer(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) > 0.5
            || abs(lhs.origin.y - rhs.origin.y) > 0.5
            || abs(lhs.width - rhs.width) > 0.5
            || abs(lhs.height - rhs.height) > 0.5
    }

    /// Returns `true` when a window from another process covers the entire screen,
    /// indicating a fullscreen app is active.
    private nonisolated static func isFullscreenAppActive(on screen: ScreenSnapshot) -> Bool {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return false
        }

        let myPID = ProcessInfo.processInfo.processIdentifier

        // CGWindowListCopyWindowInfo uses top-left origin; convert screen frame.
        let screenRect = CGRect(
            x: screen.frame.origin.x,
            y: screen.primaryScreenHeight - screen.frame.origin.y - screen.frame.height,
            width: screen.frame.width,
            height: screen.frame.height
        )

        for info in windowList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != myPID,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat]
            else { continue }

            let w = bounds["Width"] ?? 0
            let h = bounds["Height"] ?? 0

            if w >= screenRect.width && h >= screenRect.height {
                return true
            }
        }

        return false
    }

    private func makeScreenSnapshot(from screen: NSScreen) -> ScreenSnapshot {
        ScreenSnapshot(
            frame: screen.frame,
            safeAreaTopInset: screen.safeAreaInsets.top,
            primaryScreenHeight: NSScreen.screens.first?.frame.height ?? screen.frame.height
        )
    }

    // MARK: - Resize (called by NotchContentView when state changes)

    func resize(to size: CGSize, animated: Bool = true) {
        guard let panel else { return }
        if appState.settingsManager.notchHidden { return }
        lastContentSize = size
        panelShrinkTask?.cancel()
        panelShrinkTask = nil

        let screen = targetScreen()
        let normalFrame = panelFrame(screen: screen, size: size)

        // --- Retracted path (no-notch / fullscreen) ---
        // Panel hides above the screen edge when idle and slides down
        // when an active session begins or the home panel is revealed.
        if isRetracted {
            if isRetractableCompactPresentation {
                // Retract: let SwiftUI shrink the content, then slide the panel up.
                panelShrinkTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(420))
                    guard let self, !Task.isCancelled, let panel = self.panel else { return }
                    let hidden = self.retractedFrame(screen: screen, size: size)
                    NSAnimationContext.runAnimationGroup({ ctx in
                        ctx.duration = 0.25
                        ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                        panel.animator().setFrame(hidden, display: true)
                    }, completionHandler: { [weak panel] in
                        panel?.alphaValue = 0
                    })
                }
                return
            }

            // Reveal: snap the panel to the correct size above the screen, then
            // animate it sliding down into view.
            let isCurrentlyRetracted = panel.frame.origin.y >= screen.frame.maxY - 1
            if isCurrentlyRetracted {
                panel.alphaValue = 1
                let aboveScreen = retractedFrame(screen: screen, size: size)
                panel.setFrame(aboveScreen, display: true, animate: false)
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = NotchMotion.duration
                    ctx.timingFunction = NotchMotion.timingFunction
                    panel.animator().setFrame(normalFrame, display: true)
                }
            } else {
                // Already visible (mid-session size change) — use normal logic.
                panel.alphaValue = 1
                panel.setFrame(normalFrame, display: true, animate: false)
            }
            return
        }

        // --- Normal (non-retracted) path ---
        let isExpanding = normalFrame.width > panel.frame.width + 1
            || normalFrame.height > panel.frame.height + 1

        let isSmallChange = abs(normalFrame.height - panel.frame.height) < 50
            && abs(normalFrame.width - panel.frame.width) < 50

        if !animated {
            panel.setFrame(normalFrame, display: true, animate: false)
        } else if isSmallChange && isExpanding {
            // Small expansion (e.g. error row appearing): animate the panel frame
            // in sync with SwiftUI. Never animate contractions — even a 1px panel
            // frame shift can produce a visible gap between the screen top and the
            // notch due to CoreAnimation subpixel interpolation.
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = NotchMotion.duration
                ctx.timingFunction = NotchMotion.timingFunction
                panel.animator().setFrame(normalFrame, display: true)
            }
        } else if isExpanding {
            // Large expansion: snap panel to target immediately so SwiftUI has room to animate into.
            panel.setFrame(normalFrame, display: true, animate: false)
        } else {
            // Contracting: keep the panel at its current (larger) size while SwiftUI
            // animates the NotchShape shrinking, then snap the panel down after.
            panelShrinkTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(420))
                guard let self, !Task.isCancelled, let panel = self.panel else { return }
                panel.setFrame(normalFrame, display: true, animate: false)
            }
        }
    }

    private func observeCoordinator() {
        withObservationTracking {
            _ = coordinator.preferredSize(for: appState.settingsManager.overlayMode)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.resize(to: self.coordinator.preferredSize(for: self.appState.settingsManager.overlayMode))
                self.observeCoordinator()
            }
        }
    }

    // MARK: - Display pinning

    /// Move the panel to the pinned display (or back to main if unpinned).
    func repositionToTargetScreen() {
        guard let panel else { return }
        let screen = targetScreen()
        let size = coordinator.preferredSize(for: appState.settingsManager.overlayMode)
        let hasNotch = screen.safeAreaInsets.top > 0

        if !usesDevelopmentScreenshotMode && !hasNotch && isRetractableCompactPresentation {
            panel.setFrame(retractedFrame(screen: screen, size: size), display: true, animate: false)
            panel.alphaValue = 0
        } else {
            panel.alphaValue = 1
            panel.setFrame(panelFrame(screen: screen, size: size), display: true, animate: false)
        }
        scheduleRetractionRefresh()
        startFullscreenMonitoring()
    }

    private func hoverPollingInterval() -> Duration {
        if appState.settingsManager.notchHidden || isHiddenForMissionControl {
            return PollingInterval.hoverDisabled
        }

        if isRetracted {
            if isFullscreenActive && isRetractableCompactPresentation {
                return PollingInterval.hoverDisabled
            }
            return PollingInterval.hoverRetracted
        }

        if coordinator.homeVisible || coordinator.isOpen(for: appState.settingsManager.overlayMode) {
            return PollingInterval.hoverOpen
        }

        return PollingInterval.hoverIdle
    }
}

// MARK: - NSScreen display ID helper

extension NSScreen {
    /// The CoreGraphics display ID for this screen.
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? 0
    }
}
