import AppKit
import AVFoundation
import CoreGraphics
import Defaults
import SwiftUI

// MARK: - Window controller

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?

    func show(appState: AppState, initialStep: OnboardingView.OnboardingStep = .welcome) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 640),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "Welcome to Resonant"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.tabbingMode = .disallowed
        win.isMovableByWindowBackground = true
        win.center()
        win.isReleasedWhenClosed = false

        let startStep = Self.resolveStartStep(appState: appState, requested: initialStep)
        let analyticsContext = OnboardingAnalytics.SessionContext.resolve(
            onboardingCompleted: appState.settingsManager.onboardingCompleted,
            hadStarted: Defaults[.onboardingHasStarted],
            initialStep: startStep.analyticsKey
        )
        Defaults[.onboardingHasStarted] = true
        let host = NSHostingView(
            rootView: OnboardingView(
                initialStep: startStep,
                analyticsContext: analyticsContext
            ).environment(appState)
        )
        // Prevent SwiftUI from auto-resizing the window via updateAnimatedWindowSize,
        // which causes a re-entrant layout crash (SIGABRT) when display configuration
        // changes (e.g. clamshell mode, monitor connect/disconnect).
        host.sizingOptions = []
        win.contentView = host
        win.delegate = self

        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func dismiss() {
        window?.close()
        window = nil
    }

    // Closing with the red button must not strand the app: `show` guards on
    // `window == nil`, so a stale reference here made every later open a no-op
    // until relaunch.
    func windowWillClose(_ notification: Notification) {
        window = nil
    }

    /// First-run flows resume from the last step the user reached, so closing
    /// the window never means starting over. Explicit step requests (deep links)
    /// and post-completion reopens always start where asked.
    private static func resolveStartStep(
        appState: AppState,
        requested: OnboardingView.OnboardingStep
    ) -> OnboardingView.OnboardingStep {
        guard requested == .welcome,
              !appState.settingsManager.onboardingCompleted,
              let resumed = OnboardingView.OnboardingStep(analyticsKey: Defaults[.onboardingResumeStep]),
              resumed != .welcome
        else {
            return requested
        }
        return resumed
    }
}

// MARK: - Onboarding flow

struct OnboardingView: View {

    @Environment(AppState.self) private var appState
    @State private var step: OnboardingStep
    @State private var hasTrackedStart = false
    @State private var didFinishOnboarding = false
    @State private var microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var inputMonitoringGranted = CGPreflightListenEventAccess()
    @State private var onboardingStartedAt = Date()
    @State private var stepViewedAt = Date()
    @State private var practiceOutcome: OnboardingPracticeOutcome?
    @State private var completedStepKeys: Set<String> = []
    @State private var autoAdvanceTask: Task<Void, Never>?
    @State private var userNavigatedBack = false
    @State private var agentAccessEnabled = false
    @State private var detectedAgentClients: [MCPManager.MCPClient] = []
    private let analyticsContext: OnboardingAnalytics.SessionContext
    private let permissionPollTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(
        initialStep: OnboardingStep = .welcome,
        analyticsContext: OnboardingAnalytics.SessionContext
    ) {
        _step = State(initialValue: initialStep)
        self.analyticsContext = analyticsContext
    }

    enum OnboardingStep: Int, CaseIterable {
        case welcome, permissions, practice, done

        var analyticsKey: String {
            switch self {
            case .welcome:     "welcome"
            case .permissions: "permissions"
            case .practice:    "practice"
            case .done:        "done"
            }
        }

        var title: String {
            switch self {
            case .welcome:     "Welcome"
            case .permissions: "Permissions"
            case .practice:    "Try it"
            case .done:        "Done"
            }
        }

        init?(analyticsKey: String) {
            guard let match = Self.allCases.first(where: { $0.analyticsKey == analyticsKey }) else {
                return nil
            }
            self = match
        }
    }

    private var triggerKeyLabel: String {
        appState.settingsManager.hotkeyTrigger.shortName
    }

    private var requiredPermissionsGranted: Bool {
        microphoneGranted && accessibilityGranted
    }

    private var allPermissionsGranted: Bool {
        requiredPermissionsGranted && inputMonitoringGranted
    }

    private var canContinueFromCurrentStep: Bool {
        switch step {
        case .permissions:
            requiredPermissionsGranted
        case .practice:
            practiceOutcome != nil
        default:
            true
        }
    }

    private var blockedContinueMessage: String? {
        switch step {
        case .permissions where !requiredPermissionsGranted:
            "Allow microphone and accessibility access to continue."
        case .practice where practiceOutcome == nil:
            "Try one dictation, or skip and come back later."
        default:
            nil
        }
    }

    private var onboardingDurationMs: Int {
        max(0, Int(Date().timeIntervalSince(onboardingStartedAt) * 1000))
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack(spacing: 5) {
                    ForEach(OnboardingStep.allCases, id: \.rawValue) { s in
                        Capsule(style: .continuous)
                            .fill(s.rawValue <= step.rawValue ? Color.accentColor : Color.primary.opacity(0.12))
                            .frame(width: s == step ? 28 : 16, height: 4)
                    }
                }
                Text("Step \(step.rawValue + 1) of \(OnboardingStep.allCases.count) — \(step.title)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .animation(.spring(duration: 0.35), value: step)
            .padding(.top, 24)

            Spacer()

            stepContent
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
                .animation(.spring(duration: 0.35), value: step)

            Spacer()

            // Navigation
            VStack(alignment: .trailing, spacing: 8) {
                HStack {
                    if step != .welcome {
                        Button("Back") { advance(by: -1) }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if step == .done {
                        doneNavigation
                    } else {
                        HStack(spacing: 8) {
                            Button("Continue") { advance(by: 1) }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                                .keyboardShortcut(.defaultAction)
                                .disabled(!canContinueFromCurrentStep)

                            if canContinueFromCurrentStep {
                                returnKeyHint
                            }
                        }
                    }
                }

                if let blockedContinueMessage {
                    Text(blockedContinueMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 32)
        }
        .frame(width: 640, height: 640)
        .background {
            ZStack {
                VibrancyBackground()
                SettingsPalette.windowBackground.opacity(0.65)
                RadialGradient(
                    colors: [
                        Color.accentColor.opacity(0.08),
                        Color.accentColor.opacity(0)
                    ],
                    center: .top,
                    startRadius: 0,
                    endRadius: 480
                )
            }
            .ignoresSafeArea()
        }
        .onAppear {
            guard !hasTrackedStart else { return }
            let now = Date()
            onboardingStartedAt = now
            stepViewedAt = now
            refreshPermissionState(trackTransitions: false)
            hasTrackedStart = true
            detectedAgentClients = MCPManager.MCPClient.allCases.filter(\.isInstalled)
            // Agent access is always opt-in. A reopened flow reflects the
            // user's current choice without silently changing it.
            if appState.settingsManager.onboardingCompleted {
                agentAccessEnabled = appState.settingsManager.mcpServerEnabled
                    || appState.settingsManager.localAPIEnabled
            }
            capture(.started)
            capture(.permissionState, properties: permissionSnapshot.properties)
            capture(.stepViewed, properties: [
                "step": step.analyticsKey,
                "step_id": step.analyticsKey
            ])
        }
        .onChange(of: step) { _, newValue in
            refreshPermissionState()
            stepViewedAt = Date()
            Defaults[.onboardingResumeStep] = newValue.analyticsKey
            capture(.stepViewed, properties: [
                "step": newValue.analyticsKey,
                "step_id": newValue.analyticsKey
            ])
        }
        .onReceive(permissionPollTimer) { _ in
            refreshPermissionState()
        }
        .onDisappear {
            autoAdvanceTask?.cancel()
            guard hasTrackedStart, !didFinishOnboarding else { return }
            capture(.abandoned, properties: [
                "last_step_id": step.analyticsKey
            ])
        }
    }

    private var returnKeyHint: some View {
        Text("⏎")
            .accessibilityHidden(true)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
            )
    }

    private var doneNavigation: some View {
        HStack(spacing: 8) {
            Button("Start Using Resonant") {
                finish()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)

            returnKeyHint
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome:
            WelcomeStep()
        case .permissions:
            PermissionsStep(
                microphoneGranted: microphoneGranted,
                accessibilityGranted: accessibilityGranted,
                inputMonitoringGranted: inputMonitoringGranted,
                triggerKeyLabel: triggerKeyLabel,
                analyticsContext: analyticsContext
            )
        case .practice:
            PracticeStep(outcome: practiceOutcome, resolve: resolvePracticeOutcome)
        case .done:
            DoneStep(
                practiceOutcome: practiceOutcome,
                triggerKeyLabel: triggerKeyLabel,
                detectedAgentClients: detectedAgentClients,
                agentAccessEnabled: $agentAccessEnabled
            )
        }
    }

    private func advance(by delta: Int) {
        let all = OnboardingStep.allCases
        let next = step.rawValue + delta
        if delta > 0, !completedStepKeys.contains(step.analyticsKey) {
            completedStepKeys.insert(step.analyticsKey)
            capture(.stepCompleted, properties: [
                "duration_ms": max(0, Int(Date().timeIntervalSince(stepViewedAt) * 1000)),
                "step_id": step.analyticsKey
            ])
        }
        userNavigatedBack = delta < 0
        autoAdvanceTask?.cancel()
        autoAdvanceTask = nil
        if next >= 0 && next < all.count { step = all[next] }
    }

    private var permissionSnapshot: OnboardingAnalytics.PermissionSnapshot {
        OnboardingAnalytics.PermissionSnapshot(
            microphone: microphoneGranted,
            accessibility: accessibilityGranted,
            inputMonitoring: inputMonitoringGranted
        )
    }

    private func refreshPermissionState(trackTransitions: Bool = true) {
        let previous = permissionSnapshot
        let current = OnboardingAnalytics.PermissionSnapshot(
            microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            accessibility: AXIsProcessTrusted(),
            inputMonitoring: CGPreflightListenEventAccess()
        )
        microphoneGranted = current.microphone
        accessibilityGranted = current.accessibility
        inputMonitoringGranted = current.inputMonitoring

        if trackTransitions, hasTrackedStart {
            for permission in current.newlyGranted(comparedTo: previous) {
                // Re-arm the hotkey immediately so practice works without a relaunch.
                appState.hotkeyManager.refreshRegistration(promptIfNeeded: false)
                capture(.permissionGranted, properties: [
                    "permission": permission.rawValue,
                    "step_elapsed_ms": max(0, Int(Date().timeIntervalSince(stepViewedAt) * 1000))
                ])
            }
        }

        scheduleAutoAdvanceIfReady()
    }

    /// When every permission row is green there is nothing left to decide —
    /// pause long enough to register the checkmarks, then move on. Never after
    /// an explicit Back, or the user bounces forward again 900 ms later.
    private func scheduleAutoAdvanceIfReady() {
        guard step == .permissions, allPermissionsGranted, autoAdvanceTask == nil,
              !userNavigatedBack else { return }
        autoAdvanceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled, step == .permissions, allPermissionsGranted else { return }
            advance(by: 1)
        }
    }

    private func resolvePracticeOutcome(_ outcome: OnboardingPracticeOutcome) {
        guard practiceOutcome == nil else { return }
        practiceOutcome = outcome
        var properties: [String: Any] = [
            "outcome": outcome.rawValue,
            "total_dictations": appState.statsTracker.totalDictations,
            "has_preview": appState.lastTranscriptionPreview != nil
        ]
        if let bundleId = appState.lastDictationTargetBundleId {
            properties["landed_target_profile"] = PerformanceExperiments.targetProfile(bundleId: bundleId)
            properties["landed_in_external_app"] = bundleId != Bundle.main.bundleIdentifier
        }
        capture(.practiceResolved, properties: properties)
    }

    private func finish(selectedTab: SettingsTab = .home) {
        didFinishOnboarding = true
        Defaults[.onboardingResumeStep] = ""
        appState.finishOnboarding(
            analyticsContext: analyticsContext,
            totalDurationMs: onboardingDurationMs,
            selectedTab: selectedTab,
            enableAgentAccess: agentAccessEnabled
        )
    }

    private func capture(
        _ event: OnboardingAnalytics.Event,
        properties: [String: Any] = [:]
    ) {
        appState.analyticsManager.capture(
            event.rawValue,
            properties: OnboardingAnalytics.properties(
                context: analyticsContext,
                additional: properties
            )
        )
    }
}

enum OnboardingPracticeOutcome: String {
    case transcribed
    case alreadyActivated = "already_activated"
    case skipped
}

private enum OnboardingSystemSettings {
    static func openMicrophonePrivacy() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    static func openAccessibilityPrivacy() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openInputMonitoringPrivacy() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    private static func open(_ urlString: String) {
        guard let settingsURL = URL(string: urlString) else { return }
        NSWorkspace.shared.open(settingsURL)
    }
}

// MARK: - Shared components

private enum OnboardingTypography {
    static let title = Font.system(size: 30, weight: .semibold, design: .rounded)
}

/// Hero symbol in a glass circle with a soft tinted halo — the focal element
/// of each step, echoing the notch orb's glow language.
private struct OnboardingHero: View {
    let systemName: String
    var tint: Color = .accentColor

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [tint.opacity(0.20), tint.opacity(0)],
                        center: .center,
                        startRadius: 10,
                        endRadius: 72
                    )
                )
                .frame(width: 144, height: 144)

            Image(systemName: systemName)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(tint.gradient)
                .frame(width: 76, height: 76)
                .glassPill(elevation: .raised)
        }
        .frame(height: 144)
        .accessibilityHidden(true)
    }
}

/// `.keyboardShortcut` cannot take an optional key, so rows without one pass
/// through unchanged. ⌘1/⌘2/⌘3 keep the permission buttons reachable when
/// Full Keyboard Access is off — the macOS default, where plain Tab never
/// focuses buttons.
private struct OptionalCommandShortcut: ViewModifier {
    let key: Character?

    func body(content: Content) -> some View {
        if let key {
            content.keyboardShortcut(KeyEquivalent(key), modifiers: .command)
        } else {
            content
        }
    }
}

// MARK: - Step 1: Welcome

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 24) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .resonantShadow(.raised)

            Text("Welcome to Resonant").font(OnboardingTypography.title)
            Text("Speak naturally. Your words appear wherever you're typing.")
                .font(.body).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            Text("Setup takes about two minutes.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Step 2: Permissions

/// One checklist instead of sequential permission walls: each row shows why it
/// is needed and flips green in place, which survives the round-trip to System
/// Settings far better than a lone Continue button changing color.
private struct PermissionsStep: View {
    @Environment(AppState.self) private var appState
    let microphoneGranted: Bool
    let accessibilityGranted: Bool
    let inputMonitoringGranted: Bool
    let triggerKeyLabel: String
    let analyticsContext: OnboardingAnalytics.SessionContext

    @State private var accessibilityPromptFired = false
    @State private var inputMonitoringPromptFired = false

    private var microphoneStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    var body: some View {
        VStack(spacing: 24) {
            OnboardingHero(systemName: "checklist")

            Text("Let Resonant Work Everywhere").font(OnboardingTypography.title)
            Text("macOS asks your permission for each of these. Rows turn green as you allow them.")
                .font(.body).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420)

            VStack(spacing: 10) {
                PermissionRow(
                    icon: "mic.fill",
                    title: "Microphone",
                    detail: "Hears your voice so it can be transcribed.",
                    granted: microphoneGranted,
                    actionLabel: microphoneStatus == .notDetermined ? "Allow" : "Open Settings",
                    shortcutKey: "1"
                ) {
                    if microphoneStatus == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in }
                    } else {
                        OnboardingSystemSettings.openMicrophonePrivacy()
                    }
                }

                PermissionRow(
                    icon: "accessibility",
                    title: "Accessibility",
                    detail: "Types your words into the app you're using.",
                    granted: accessibilityGranted,
                    actionLabel: accessibilityPromptFired ? "Open Settings" : "Allow",
                    shortcutKey: "2"
                ) {
                    appState.analyticsManager.capture(
                        OnboardingAnalytics.Event.accessibilitySettingsOpened.rawValue,
                        properties: OnboardingAnalytics.properties(context: analyticsContext)
                    )
                    if accessibilityPromptFired {
                        OnboardingSystemSettings.openAccessibilityPrivacy()
                    } else {
                        accessibilityPromptFired = true
                        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                        _ = AXIsProcessTrustedWithOptions(options)
                    }
                }

                PermissionRow(
                    icon: "keyboard.fill",
                    title: "Input Monitoring",
                    detail: "Makes the \(triggerKeyLabel) trigger key reliable in every app.",
                    granted: inputMonitoringGranted,
                    badge: "Recommended",
                    actionLabel: inputMonitoringPromptFired ? "Open Settings" : "Allow",
                    shortcutKey: "3"
                ) {
                    if inputMonitoringPromptFired {
                        OnboardingSystemSettings.openInputMonitoringPrivacy()
                    } else {
                        inputMonitoringPromptFired = true
                        _ = CGRequestListenEventAccess()
                    }
                }
            }
            .frame(maxWidth: 420)
        }
    }
}

private struct PermissionRow: View {
    let icon: String
    let title: String
    let detail: String
    let granted: Bool
    var badge: String?
    let actionLabel: String
    var shortcutKey: Character?
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(granted ? Color.green : Color.accentColor)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill((granted ? Color.green : Color.accentColor).opacity(0.1))
                )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    if let badge {
                        Text(badge)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(Color.primary.opacity(0.07))
                            )
                    }
                }
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityHidden(true)
            } else {
                Button(actionLabel, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .modifier(OptionalCommandShortcut(key: shortcutKey))
            }
        }
        // One element per row: "Microphone, granted" instead of five fragments,
        // with the ⌘-shortcut reachable when Full Keyboard Access is off.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(badge.map { "\(title), \($0)" } ?? title)
        .accessibilityValue(granted ? "Granted" : "Not granted. \(detail)")
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(SettingsPalette.cardBackground.opacity(0.78))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(SettingsPalette.border, lineWidth: 0.5)
        )
        .resonantShadow(.resting)
        .animation(.spring(duration: 0.3), value: granted)
    }
}

// MARK: - Step 3: Practice

/// The aha moment. Points the user at a real app — the product's actual value —
/// while the onboarding window narrates progress and celebrates the landing.
/// Absorbs the model download and the trigger-key choice so neither needs its
/// own screen.
private struct PracticeStep: View {
    @Environment(AppState.self) private var appState
    let outcome: OnboardingPracticeOutcome?
    let resolve: (OnboardingPracticeOutcome) -> Void

    private var triggerKeyLabel: String {
        appState.settingsManager.hotkeyTrigger.shortName
    }

    private var modelReady: Bool {
        appState.modelRegistry.activeIsReady
    }

    private var diagnostics: HotkeyDiagnostics { HotkeyDiagnostics.current() }

    private var deliveredAppName: String? {
        guard let bundleId = appState.lastDictationTargetBundleId,
              bundleId != Bundle.main.bundleIdentifier
        else {
            return nil
        }
        return appState.lastDictationTargetAppName
    }

    var body: some View {
        VStack(spacing: 20) {
            OnboardingHero(systemName: "waveform")

            Text("Try Your First Dictation").font(OnboardingTypography.title)
            Text("Click into any app — Notes, Messages, your editor — then hold **\(triggerKeyLabel)** and speak. Release to finish.")
                .font(.body).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420)

            triggerKeyMenu

            if appState.settingsManager.hotkeyTrigger == .fn,
               let reason = diagnostics.fnFallbackReason {
                Text("\(reason) Right Option is recommended on this Mac, but FN remains selectable.")
                    .font(.callout).foregroundStyle(.orange)
                    .multilineTextAlignment(.center).frame(maxWidth: 380)
            }

            if !modelReady {
                modelProgressCard
            } else if appState.isRecording {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text("Listening…").foregroundStyle(.red)
                }
                .transition(.opacity)
            } else if appState.isFinishingCapture {
                ProgressView().controlSize(.small)
                Text("Transcribing…").font(.caption).foregroundStyle(.secondary)
            } else if let preview = appState.lastTranscriptionPreview {
                successView(preview: preview)
            } else if outcome == .alreadyActivated {
                Label("You've already dictated on this Mac — try another one, or continue.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.callout.weight(.medium))
            } else if outcome == .skipped {
                Label("Practice skipped. You can reopen onboarding from Account settings.", systemImage: "clock")
                    .foregroundStyle(.secondary).font(.callout)
            }

            if outcome == nil {
                Button("Skip for now") {
                    resolve(.skipped)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
        }
        .animation(.spring(duration: 0.3), value: appState.isRecording)
        .animation(.spring(duration: 0.3), value: appState.lastTranscriptionPreview)
        .animation(.spring(duration: 0.3), value: modelReady)
        .onAppear {
            if appState.statsTracker.totalDictations > 0 {
                resolve(.alreadyActivated)
            } else {
                appState.lastTranscriptionPreview = nil
            }
        }
        .onChange(of: appState.lastTranscriptionPreview) { _, preview in
            if preview != nil {
                resolve(.transcribed)
            }
        }
    }

    private func successView(preview: String) -> some View {
        let wordCount = preview.split(separator: " ").count
        return VStack(spacing: 8) {
            Text("\u{201C}\(preview)\u{201D}")
                .font(.title3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .padding(.horizontal, 20).padding(.vertical, 12)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.green.opacity(0.1))
                }
            Label(successMessage(wordCount: wordCount), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.callout.weight(.medium))
        }
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }

    private func successMessage(wordCount: Int) -> String {
        let words = wordCount == 1 ? "1 word" : "\(wordCount) words"
        if let appName = deliveredAppName {
            return "\(words) delivered to \(appName). Try again or continue."
        }
        return "It works — \(words) without touching the keyboard."
    }

    private var modelProgressCard: some View {
        HStack(spacing: 12) {
            if appState.modelRegistry.downloadError != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.orange)
            } else {
                ProgressView().controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Preparing the speech model")
                        .font(.system(size: 13, weight: .semibold))
                    if appState.modelRegistry.isDownloading, appState.modelRegistry.downloadProgress > 0 {
                        Text("\(Int(appState.modelRegistry.downloadProgress * 100))%")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(appState.modelRegistry.downloadError
                     ?? appState.modelRegistry.preparationStatusText
                     ?? modelDownloadDisclosure)
                    .font(.system(size: 12))
                    .foregroundStyle(appState.modelRegistry.downloadError == nil ? Color.secondary : Color.orange)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            if !appState.modelRegistry.isDownloading {
                Button(appState.modelRegistry.downloadError == nil ? "Download" : "Retry") {
                    Task {
                        try? await appState.modelRegistry.prepareActive(source: .onboardingDownload)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: 420)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(SettingsPalette.cardBackground.opacity(0.78))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(SettingsPalette.border, lineWidth: 0.5)
        )
        .resonantShadow(.resting)
    }

    private var modelDownloadDisclosure: String {
        guard let model = appState.modelRegistry.active else {
            return "Download required — dictation then runs entirely on this Mac."
        }
        let size = ByteCountFormatter.string(fromByteCount: model.downloadSizeBytes, countStyle: .file)
        let host = model.modelURL?.host ?? "the model provider"
        return "Downloads about \(size) from \(host). Model terms are linked in Settings; dictation then runs locally."
    }

    private var triggerKeyMenu: some View {
        Menu {
            ForEach(HotkeyTrigger.presets, id: \.rawValue) { trigger in
                Button {
                    appState.settingsManager.hotkeyTrigger = trigger
                } label: {
                    if trigger == appState.settingsManager.hotkeyTrigger {
                        Label(trigger.displayName, systemImage: "checkmark")
                    } else {
                        Text(trigger.displayName)
                    }
                }
            }
        } label: {
            Label("Trigger key: \(triggerKeyLabel)", systemImage: "keyboard")
                .font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(.secondary)
    }
}

// MARK: - Step 4: Done

private struct DoneStep: View {
    @Environment(AppState.self) private var appState
    let practiceOutcome: OnboardingPracticeOutcome?
    let triggerKeyLabel: String
    let detectedAgentClients: [MCPManager.MCPClient]
    @Binding var agentAccessEnabled: Bool

    private var title: String {
        switch practiceOutcome {
        case .transcribed, .alreadyActivated:
            "You're All Set"
        case .skipped, .none:
            "You're Ready to Dictate"
        }
    }

    var body: some View {
        VStack(spacing: 24) {
            OnboardingHero(systemName: "checkmark.circle.fill", tint: .green)

            Text(title).font(OnboardingTypography.title)
            Text("Hold \(triggerKeyLabel) to dictate in any app — your words land wherever your cursor is.")
                .font(.body).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            if !detectedAgentClients.isEmpty {
                Toggle(isOn: $agentAccessEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Let AI agents search your voice data")
                            .font(.system(size: 12, weight: .medium))
                        Text("Gives \(detectedAgentClients.map(\.rawValue).formatted(.list(type: .and))) access to your dictations via MCP, and enables the local HTTP API. Change anytime in Settings.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.checkbox)
                .frame(maxWidth: 420)
            }
        }
    }
}
