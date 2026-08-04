import AppKit
import SwiftUI

struct OriginalModeTheme {
    let hue: Double
    let rotationPeriod: Double
    let reactiveMultiplier: Double
    let iconName: String
}

func originalModeTheme(for mode: String) -> OriginalModeTheme? {
    switch mode {
    case "listening":
        return OriginalModeTheme(hue: 0.60, rotationPeriod: 20, reactiveMultiplier: 1.0, iconName: "mic.fill")
    case "processing":
        return OriginalModeTheme(hue: 0.60, rotationPeriod: 10, reactiveMultiplier: 0.2, iconName: "waveform")
    case "memo":
        return OriginalModeTheme(hue: 0.083, rotationPeriod: 30, reactiveMultiplier: 0.8, iconName: "note.text")
    case "command":
        return OriginalModeTheme(hue: 0.57, rotationPeriod: 20, reactiveMultiplier: 1.0, iconName: "point.3.connected.trianglepath.dotted")
    case "error":
        return OriginalModeTheme(hue: 0.0, rotationPeriod: 40, reactiveMultiplier: 0.0, iconName: "xmark.circle.fill")
    case "success":
        return OriginalModeTheme(hue: 0.33, rotationPeriod: 28, reactiveMultiplier: 0.0, iconName: "checkmark.circle.fill")
    case "hotMic":
        return OriginalModeTheme(hue: 0.0, rotationPeriod: 25, reactiveMultiplier: 1.0, iconName: "mic.badge.plus")
    default:
        return nil
    }
}

func originalModeAccentColor(for mode: String) -> Color {
    guard let theme = originalModeTheme(for: mode) else {
        return .white.opacity(0.85)
    }
    return Color(hue: theme.hue, saturation: 0.65, brightness: 0.95)
}

struct OriginalModeIconBadge: View {
    let mode: String
    var size: CGFloat = 10
    var iconSize: CGFloat = 6

    @ViewBuilder
    var body: some View {
        if let theme = originalModeTheme(for: mode) {
            Image(systemName: theme.iconName)
                .font(.system(size: iconSize, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(
                    Circle()
                        .fill(Color.black.opacity(0.65))
                )
        }
    }
}

struct OriginalOrbView: View {
    let mode: String
    let reactiveLevel: CGFloat
    let expression: ExpressionType?
    var customHue: Double? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { timeline in
                let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                let size = max(1, min(geometry.size.width, geometry.size.height))
                let theme = orbTheme
                let rotationPeriod = originalModeTheme(for: mode)?.rotationPeriod ?? 20
                let angle = (time * (360.0 / rotationPeriod)).truncatingRemainder(dividingBy: 360)
                let flare = min(1, pow(max(0, min(1, reactiveLevel)), 0.55) * 1.15 * (originalModeTheme(for: mode)?.reactiveMultiplier ?? 1))

                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                stops: [
                                    .init(color: theme.secondary.opacity(0.46), location: 0),
                                    .init(color: theme.primary.opacity(0.32), location: 0.45),
                                    .init(color: .clear, location: 0.95),
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: size * 0.6
                            )
                        )
                        .opacity(Double(flare))

                    ZStack {
                        OriginalConicLayer(color: theme.tertiary, angle: angle, multiplier: 2, centerX: 0.25, centerY: 0.70, transparentStart: 0.20, transparentEnd: 0.80)
                        OriginalConicLayer(color: theme.primary, angle: angle, multiplier: -3, centerX: 0.80, centerY: 0.20, transparentStart: 0.40, transparentEnd: 0.60)
                        OriginalConicLayer(color: theme.secondary, angle: angle, multiplier: 2, centerX: 0.15, centerY: 0.05, transparentStart: 0.10, transparentEnd: 0.90)
                        OriginalConicLayer(color: theme.tertiary, angle: angle, multiplier: -2, centerX: 0.85, centerY: 0.10, transparentStart: 0.20, transparentEnd: 0.80)
                    }
                    .blur(radius: max(size * 0.015, 4))
                    .contrast(1.5 + (flare * 0.3))
                    .saturation(1.1 + (flare * 0.25))

                    OriginalDotLayer(dotSize: max(size * 0.02, 1.0), color: theme.background)
                        .blendMode(.overlay)
                        .opacity(0.32)
                }
                .clipShape(Circle())
                .compositingGroup()
                .drawingGroup()
                .background {
                    // Inner light: content glows from within the black panel,
                    // keyed to the live audio level. Sits outside drawingGroup
                    // so it can bleed past the orb bounds without clipping.
                    Circle()
                        .fill(
                            RadialGradient(
                                stops: [
                                    .init(color: theme.secondary.opacity(0.50), location: 0),
                                    .init(color: theme.primary.opacity(0.16), location: 0.5),
                                    .init(color: .clear, location: 1),
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: size * 0.5
                            )
                        )
                        .scaleEffect(2.1)
                        .opacity(Double(flare) * 0.45)
                        .allowsHitTesting(false)
                }
                .shadow(color: theme.secondary.opacity(0.20 + flare * 0.35), radius: max(size * 0.008, 2))
            }
        }
    }

    private var orbTheme: (background: Color, primary: Color, secondary: Color, tertiary: Color) {
        let expressionHue: Double? = {
            switch expression {
            case .levelUp, .hotStreak, .achievement:
                return 0.083
            case nil:
                return nil
            }
        }()

        // customHue only applies to dictation modes; error/hotMic keep their semantic colors.
        let isCustomizableMode = (mode == "listening" || mode == "processing")
        let resolvedCustomHue = isCustomizableMode ? customHue : nil

        let baseHue = expressionHue ?? resolvedCustomHue ?? originalModeTheme(for: mode)?.hue ?? 0.57

        return (
            background: Color(hue: baseHue, saturation: 0.08, brightness: 0.99),
            primary: Color(hue: wrappedHue(baseHue - 0.06), saturation: 0.58, brightness: 0.96),
            secondary: Color(hue: wrappedHue(baseHue + 0.02), saturation: 0.48, brightness: 0.99),
            tertiary: Color(hue: wrappedHue(baseHue + 0.10), saturation: 0.54, brightness: 0.94)
        )
    }

    private func wrappedHue(_ hue: Double) -> Double {
        let wrapped = hue.truncatingRemainder(dividingBy: 1.0)
        return wrapped < 0 ? wrapped + 1.0 : wrapped
    }
}

private struct OriginalConicLayer: View {
    let color: Color
    let angle: Double
    let multiplier: Double
    let centerX: CGFloat
    let centerY: CGFloat
    let transparentStart: Double
    let transparentEnd: Double

    var body: some View {
        Circle()
            .fill(
                AngularGradient(
                    gradient: Gradient(stops: [
                        .init(color: color, location: 0),
                        .init(color: .clear, location: transparentStart),
                        .init(color: .clear, location: transparentEnd),
                        .init(color: color, location: 1),
                    ]),
                    center: UnitPoint(x: centerX, y: centerY),
                    startAngle: .degrees(angle * multiplier),
                    endAngle: .degrees((angle * multiplier) + 360)
                )
            )
    }
}

private struct OriginalDotLayer: View {
    let dotSize: CGFloat
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, canvasSize in
                let step = dotSize * 3
                var y: CGFloat = 0
                while y <= canvasSize.height {
                    var x: CGFloat = 0
                    while x <= canvasSize.width {
                        context.fill(
                            Path(ellipseIn: CGRect(x: x, y: y, width: dotSize, height: dotSize)),
                            with: .color(color)
                        )
                        x += step
                    }
                    y += step
                }
            }
            .blur(radius: dotSize * 0.6)
            .mask {
                RadialGradient(
                    stops: [
                        .init(color: .white, location: 0.08),
                        .init(color: .clear, location: 0.75),
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: min(geometry.size.width, geometry.size.height) * 0.5
                )
            }
        }
    }
}

struct OriginalTranscriptPanel: View {
    let title: String
    let statusText: String
    let reactiveLevel: CGFloat?
    let isProcessing: Bool
    let progress: Double
    let mode: String
    let isLocked: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 4) {
                Text(title)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.white.opacity(0.38))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isLocked {
                    OriginalRecordingLockPill()
                }
            }

            Spacer(minLength: 10)

            if isProcessing {
                OriginalProcessingBand(progress: progress)
                    .frame(height: 44)
            } else {
                OriginalWaveformView(
                    reactiveLevel: reactiveLevel,
                    accentColor: NSColor(originalModeAccentColor(for: mode))
                )
                .frame(height: 44)
            }

            Spacer(minLength: 10)

            Text(statusText)
                .lineLimit(2)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

private struct OriginalProcessingBand: View {
    let progress: Double

    @State private var beatOffset: CGFloat = -120

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Capsule()
                .fill(Color.white.opacity(0.09))
                .overlay(alignment: .leading) {
                    if progress > 0 {
                        Capsule()
                            .fill(Color.white.opacity(0.88))
                            .frame(maxWidth: max(24, CGFloat(progress) * 340))
                    } else {
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [.clear, .white.opacity(0.85), .clear],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: 120)
                            .offset(x: beatOffset)
                            .onAppear {
                                withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                                    beatOffset = 340
                                }
                            }
                    }
                }
                .frame(height: 6)

            OriginalWaveformView(reactiveLevel: 0.08, accentColor: .white)
                .frame(height: 22)
                .opacity(0.65)
        }
    }
}

struct OriginalWaveformView: View {
    let reactiveLevel: CGFloat?
    let accentColor: NSColor

    private let barCount = 32

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
                let width = geometry.size.width
                let height = geometry.size.height
                let spacing = width / CGFloat(barCount * 2)
                let barWidth = spacing
                let baseline = max(height * 0.18, 6)
                let level = reactiveLevel ?? 0
                let time = timeline.date.timeIntervalSinceReferenceDate

                HStack(alignment: .center, spacing: spacing) {
                    ForEach(0..<barCount, id: \.self) { index in
                        let phase = sin(time * 5.4 + Double(index) * 0.41)
                        let organic = CGFloat((phase + 1) * 0.5)
                        let amplitude = max(level, 0.12) * (0.55 + organic * 0.9)
                        let barHeight = min(height, baseline + amplitude * height * 0.72)

                        RoundedRectangle(cornerRadius: barWidth * 0.5, style: .continuous)
                            .fill(Color(nsColor: accentColor))
                            .frame(width: barWidth, height: barHeight)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
            }
        }
    }
}

struct NotchIssuePresentation {
    var icon: String
    var title: String
    var detail: String?
    var actionLabel: String?
    var tint: Color
    /// When true the action re-runs the failed dictation's saved audio
    /// instead of deep-linking to settings.
    var performsRetry: Bool = false
}

func notchIssuePresentation(
    message: String,
    subtype: NotchOverlayState.ErrorSubtype?,
    offersRetry: Bool = false
) -> NotchIssuePresentation {
    var presentation = baseNotchIssuePresentation(message: message, subtype: subtype)
    // A surviving failed clip makes "try the words again" the primary action
    // for recognition/model failures — more direct than a settings deep link.
    if offersRetry, subtype == .transcription || subtype == .model {
        presentation.actionLabel = "Retry"
        presentation.performsRetry = true
    }
    return presentation
}

private func baseNotchIssuePresentation(
    message: String,
    subtype: NotchOverlayState.ErrorSubtype?
) -> NotchIssuePresentation {
    let lowered = message.lowercased()

    if subtype == .model || lowered.contains("model") {
        let isLoading = lowered.contains("loading") || lowered.contains("preparing")
        return NotchIssuePresentation(
            icon: "cpu",
            title: isLoading ? "Loading local model" : "Model not ready",
            detail: isLoading ? "Dictation will work as soon as it is ready." : "Open Dictation settings or retry in a moment.",
            actionLabel: isLoading ? nil : "Settings",
            tint: .blue.opacity(0.9)
        )
    }

    if subtype == .paste {
        let isStale = lowered.contains("expired") || lowered.contains("re-add")
        let needsAccessibility = lowered.contains("accessibility")
        let copiedFallback = lowered.contains("copied to clipboard")
        if isStale {
            return NotchIssuePresentation(
                icon: "lock.shield.fill",
                title: copiedFallback ? "Copied — ⌘V to paste" : "Can't auto-paste",
                detail: "Remove Resonant from Accessibility, then re-add it from Applications.",
                actionLabel: "Open Settings",
                tint: copiedFallback ? .orange.opacity(0.95) : .red.opacity(0.88)
            )
        }
        if needsAccessibility {
            return NotchIssuePresentation(
                icon: "lock.shield.fill",
                title: copiedFallback ? "Copied — ⌘V to paste" : "Can't auto-paste",
                detail: "Enable Resonant in Accessibility settings to auto-paste.",
                actionLabel: "Open Settings",
                tint: copiedFallback ? .orange.opacity(0.95) : .red.opacity(0.88)
            )
        }
        return NotchIssuePresentation(
            icon: "doc.on.clipboard",
            title: copiedFallback ? "Copied — ⌘V to paste" : "Can't auto-paste",
            detail: message,
            actionLabel: nil,
            tint: copiedFallback ? .orange.opacity(0.95) : .red.opacity(0.88)
        )
    }

    if subtype == .transcription && (lowered.contains("no speech") || lowered.contains("too brief")) {
        let detail: String
        if let range = message.range(of: " from ", options: .caseInsensitive) {
            let micName = String(message[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            detail = "Check \(micName), then try again."
        } else {
            detail = "Check the selected microphone and try again."
        }

        return NotchIssuePresentation(
            icon: "waveform.badge.magnifyingglass",
            title: "No speech detected",
            detail: detail,
            actionLabel: "Check Mic",
            tint: .orange.opacity(0.95)
        )
    }

    if subtype == .transcription && lowered.contains("speech was detected") && lowered.contains("no text") {
        return NotchIssuePresentation(
            icon: "waveform.badge.magnifyingglass",
            title: "Transcription missed speech",
            detail: "Try again, or check the selected model and language if this repeats.",
            actionLabel: "Settings",
            tint: .orange.opacity(0.95)
        )
    }

    if subtype == .microphone || lowered.contains("permission") || lowered.contains("privacy") {
        if lowered.contains("enable") || lowered.contains("permission") || lowered.contains("privacy") {
            return NotchIssuePresentation(
                icon: "lock.shield.fill",
                title: "Microphone access needed",
                detail: "Allow Resonant in System Settings, then try again.",
                actionLabel: "Open Settings",
                tint: .red.opacity(0.88)
            )
        }

        return NotchIssuePresentation(
            icon: "mic.slash.fill",
            title: "Microphone unavailable",
            detail: "Check the selected input device and try again.",
            actionLabel: "Check Mic",
            tint: .orange.opacity(0.95)
        )
    }

    if subtype == .meetingSystemAudio {
        return NotchIssuePresentation(
            icon: "speaker.slash.fill",
            title: message,
            detail: "Check system audio capture permissions.",
            actionLabel: "Settings",
            tint: .red.opacity(0.88)
        )
    }

    return NotchIssuePresentation(
        icon: "exclamationmark.triangle.fill",
        title: message,
        detail: "Retry, or open Dictation settings if this keeps happening.",
        actionLabel: "Settings",
        tint: .red.opacity(0.88)
    )
}

/// Unified minimal strip for all expanded-notch states (listening, processing,
/// error, hot mic).  One component, different animation states.
struct MinimalStrip: View {
    @Environment(AppState.self) private var appState

    let mode: String
    let reactiveLevel: CGFloat?
    let isProcessing: Bool
    let progress: Double
    let statusText: String
    let isLocked: Bool
    let isError: Bool
    let errorMessage: String?
    let errorSubtype: NotchOverlayState.ErrorSubtype?
    let notice: NotchOverlayState.Notice?
    let isHotMic: Bool
    let hotMicLiveText: String?
    let recordingLiveText: String?
    let closedNotchSize: CGSize

    var body: some View {
        let sideWidth = NotchSizes.minimalStripSideWidth(for: closedNotchSize.height)
        let orbSize = max(18, sideWidth - 4)
        let isNotice = notice != nil
        let textRow = belowNotchStatusText
        let visualMode = mode == "command" && !isProcessing ? "listening" : (isHotMic ? "hotMic" : mode)

        VStack(spacing: 0) {
            // Top row: non-text controls flanking the hardware notch.
            if !isError && !isNotice {
                HStack(spacing: 0) {
                    ZStack(alignment: .bottomTrailing) {
                        OriginalOrbView(
                            mode: visualMode,
                            reactiveLevel: reactiveLevel ?? 0.12,
                            expression: nil,
                            customHue: appState.settingsManager.dictationOrbHue
                        )
                        .frame(width: orbSize, height: orbSize)

                        Group {
                            if isHotMic {
                                HotMicRecordingDot()
                            } else if isLocked {
                                OriginalRecordingLockBadge()
                            } else if originalModeTheme(for: mode) != nil {
                                OriginalModeIconBadge(mode: mode)
                            }
                        }
                        .offset(x: 1, y: 1)
                    }
                    .frame(width: sideWidth, height: orbSize, alignment: .center)

                    Spacer(minLength: 0)

                    if mode == "success" {
                        Spacer(minLength: 0)
                            .frame(width: sideWidth, height: orbSize, alignment: .center)
                    } else {
                        OriginalCompactSpectrumView(
                            mode: visualMode,
                            reactiveLevel: reactiveLevel,
                            isProcessing: isProcessing,
                            progress: progress,
                            customHue: appState.settingsManager.dictationOrbHue
                        )
                        .frame(width: sideWidth, height: orbSize, alignment: .center)
                    }
                }
                .frame(height: closedNotchSize.height)
                .transition(.opacity)
                .animation(.easeOut(duration: 0.2), value: isError)
            }

            if let notice {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: notice.icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.blue.opacity(0.9))
                        .frame(width: 18)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(notice.title)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.88)

                        if let detail = notice.detail {
                            Text(detail)
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.68))
                                .lineLimit(1)
                                .minimumScaleFactor(0.86)
                        }
                    }

                    Spacer(minLength: 8)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, closedNotchSize.height + 4)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
                .transition(.opacity)
                .animation(.easeOut(duration: 0.25).delay(0.15), value: isNotice)
            }

            if let textRow {
                Text(textRow)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(2)
                    .minimumScaleFactor(0.86)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: mode == "success" ? .center : .leading)
                    .padding(.top, 4)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .frame(minHeight: NotchSizes.minimalTextRowHeight, alignment: .center)
                    .background(Color.white.opacity(0.035))
                    .transition(.opacity)
                    .animation(.easeOut(duration: 0.25).delay(0.15), value: textRow)
            }

            // Error row — title and guidance below the hardware notch.
            if let issue = errorIssue {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: issue.icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(issue.tint)
                        .frame(width: 18)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(issue.title)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.88)

                        if let detail = issue.detail {
                            Text(detail)
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.68))
                                .lineLimit(1)
                                .minimumScaleFactor(0.86)
                        }
                    }

                    Spacer(minLength: 8)

                    if let actionLabel = issue.actionLabel {
                        Button {
                            performIssueAction(issue)
                        } label: {
                            Text(actionLabel)
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.92))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .contentShape(Capsule(style: .continuous))
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(Color.white.opacity(0.12))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, closedNotchSize.height + 4)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
                .transition(.opacity)
                .animation(.easeOut(duration: 0.25).delay(0.15), value: isError)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(NotchMotion.animation, value: isError)
        .animation(NotchMotion.animation, value: isNotice)
        .animation(NotchMotion.animation, value: textRow)
        .animation(NotchMotion.animation, value: isHotMic)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(noticeAccessibilityLabel ?? (isError ? (errorMessage ?? statusText) : statusText))
        // `children: .ignore` collapses the strip into one element, which would
        // otherwise hide the error card's button from VoiceOver entirely.
        .modifier(NotchIssueActionAccessibility(issue: errorIssue) { issue in
            performIssueAction(issue)
        })
    }

    private var errorIssue: NotchIssuePresentation? {
        guard isError, let errorMessage else { return nil }
        return notchIssuePresentation(
            message: errorMessage,
            subtype: errorSubtype,
            offersRetry: appState.canRetryLastFailedDictation
        )
    }

    private func performIssueAction(_ issue: NotchIssuePresentation) {
        if issue.performsRetry {
            let appState = appState
            Task { @MainActor in
                await appState.retryLastFailedDictation()
            }
        } else {
            errorFixAction()
        }
    }

    private var belowNotchStatusText: String? {
        guard !isError, notice == nil else { return nil }

        if mode == "command" {
            return "Agent command - \(statusText)"
        }

        if isHotMic,
           let hotMicLiveText,
           !hotMicLiveText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return hotMicLiveText
        }

        // Live dictation preview — the words appear as the user speaks.
        if mode == "listening",
           let recordingLiveText = recordingLiveText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !recordingLiveText.isEmpty {
            return recordingLiveText
        }

        if mode == "success" {
            return statusText
        }

        return nil
    }

    private var noticeAccessibilityLabel: String? {
        guard let notice else { return nil }
        return [notice.title, notice.detail]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ". ")
    }

    private func errorFixAction() {
        let msg = (errorMessage ?? "").lowercased()

        // System Settings deep links
        if msg.contains("input monitoring") {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
        } else if msg.contains("accessibility") {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        } else if msg.contains("permission") || msg.contains("privacy") || msg.contains("enable microphone") {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        } else if errorSubtype == .microphone || msg.contains("microphone") {
            appState.showPrimaryWindow(selectedTab: .dictation)
        } else if errorSubtype == .transcription && msg.contains("no speech") {
            // "No speech detected from X" → open Resonant mic settings
            appState.showPrimaryWindow(selectedTab: .dictation)
        } else if errorSubtype == .model {
            appState.showPrimaryWindow(selectedTab: .dictation)
        } else if msg.contains("model") || msg.contains("transform") || msg.contains("empty text")
                    || msg.contains("focus") || msg.contains("click") || errorSubtype == .paste {
            // Non-actionable errors: dismiss (coordinator auto-clears on timeout)
        } else {
            appState.showPrimaryWindow(selectedTab: .dictation)
        }
    }
}

/// Exposes the notch error card's fix/retry button as a VoiceOver custom action
/// on the collapsed strip element.
private struct NotchIssueActionAccessibility: ViewModifier {
    let issue: NotchIssuePresentation?
    let perform: (NotchIssuePresentation) -> Void

    func body(content: Content) -> some View {
        if let issue, let actionLabel = issue.actionLabel {
            content.accessibilityAction(named: Text(actionLabel)) {
                perform(issue)
            }
        } else {
            content
        }
    }
}

private struct OriginalRecordingLockPill: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "lock.fill")
                .font(.system(size: 8, weight: .bold))
            Text("Locked")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.1))
        )
    }
}

private struct OriginalRecordingLockBadge: View {
    var body: some View {
        Image(systemName: "lock.fill")
            .font(.system(size: 6, weight: .bold))
            .foregroundStyle(.black.opacity(0.85))
            .frame(width: 11, height: 11)
            .background(
                Circle()
                    .fill(Color.white.opacity(0.95))
            )
    }
}

// MARK: - Spectrum style selector
// Change this to preview different styles: .dotGrid, .pixelMatrix, .blob
private let activeSpectrumStyle: SpectrumStyle = .dotGrid

private enum SpectrumStyle {
    case dotGrid
    case pixelMatrix
    case blob
}

private struct OriginalCompactSpectrumView: View {
    let mode: String
    let reactiveLevel: CGFloat?
    let isProcessing: Bool
    let progress: Double
    var customHue: Double? = nil

    var body: some View {
        Group {
            switch activeSpectrumStyle {
            case .dotGrid:
                DotGridSpectrumView(reactiveLevel: reactiveLevel, isProcessing: isProcessing, progress: progress)
            case .pixelMatrix:
                PixelMatrixSpectrumView(reactiveLevel: reactiveLevel, isProcessing: isProcessing, progress: progress)
            case .blob:
                BlobSpectrumView(reactiveLevel: reactiveLevel, isProcessing: isProcessing, progress: progress)
            }
        }
        .background {
            // Inner light, matching the orb's bloom: soft radial tint keyed
            // to the live audio level, bleeding past the spectrum bounds.
            GeometryReader { geometry in
                let size = min(geometry.size.width, geometry.size.height)
                Circle()
                    .fill(
                        RadialGradient(
                            stops: [
                                .init(color: glowTint.opacity(0.45), location: 0),
                                .init(color: glowTint.opacity(0.14), location: 0.5),
                                .init(color: .clear, location: 1),
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: size * 0.5
                        )
                    )
                    .frame(width: size, height: size)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    .scaleEffect(2.0)
            }
            .opacity(Double(flare) * 0.45)
            .allowsHitTesting(false)
        }
    }

    private var flare: CGFloat {
        let level = max(0, min(1, reactiveLevel ?? 0))
        let multiplier = originalModeTheme(for: mode)?.reactiveMultiplier ?? 1
        return min(1, pow(level, 0.55) * 1.15 * multiplier)
    }

    private var glowTint: Color {
        let isCustomizableMode = (mode == "listening" || mode == "processing")
        let hue = (isCustomizableMode ? customHue : nil) ?? originalModeTheme(for: mode)?.hue ?? 0.57
        return Color(hue: hue, saturation: 0.5, brightness: 0.95)
    }
}

// MARK: - 1. Dot Grid (3×3, center-out bloom)

private struct DotGridSpectrumView: View {
    let reactiveLevel: CGFloat?
    let isProcessing: Bool
    let progress: Double

    private let gridSize = 3

    /// Unique phase offset per dot — seeded so the pattern is deterministic
    /// but feels organic. Each dot gets its own animation personality.
    private static let dotPhases: [Double] = {
        // Golden-ratio–spaced phases give a non-repeating but structured feel
        let phi = 1.6180339887
        return (0..<9).map { i in Double(i) * phi }
    }()

    /// Activation order: center first, then cardinal edges, then corners.
    /// Maps grid index → ring (0 = first to light, 2 = last).
    private static let activationRing: [Int] = [
        2, 1, 2,   // top row:    corner, edge, corner
        1, 0, 1,   // mid row:    edge, CENTER, edge
        2, 1, 2,   // bottom row: corner, edge, corner
    ]

    var body: some View {
        GeometryReader { geometry in
            let diameter = min(geometry.size.width, geometry.size.height)

            TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let rawLevel = CGFloat(max(reactiveLevel ?? 0, isProcessing ? 0.06 : 0.02))
                let progressBoost = isProcessing ? CGFloat(max(0, min(1, progress))) * 0.08 : 0
                let level = min(1.0, pow(rawLevel, 0.4) + progressBoost)

                let spacing = diameter / CGFloat(gridSize + 1)
                let maxDotSize = spacing * 0.72

                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.07))

                    ForEach(0..<gridSize * gridSize, id: \.self) { index in
                        let row = index / gridSize
                        let col = index % gridSize
                        let style = Self.dotStyle(
                            index: index,
                            row: row,
                            col: col,
                            time: time,
                            level: level,
                            isProcessing: isProcessing
                        )
                        let dotSize = max(1.5, min(maxDotSize, maxDotSize * style.scale))
                        let x = spacing * (CGFloat(col) + 1)
                        let y = spacing * (CGFloat(row) + 1)

                        Circle()
                            .fill(Color.white.opacity(style.opacity))
                            .shadow(color: .white.opacity(style.intensity * 0.35), radius: dotSize * 0.4)
                            .frame(width: dotSize, height: dotSize)
                            .position(x: x, y: y)
                    }
                }
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private struct DotStyle {
        let intensity: Double
        let opacity: Double
        let scale: CGFloat
    }

    private static func dotStyle(
        index: Int,
        row: Int,
        col: Int,
        time: Double,
        level: CGFloat,
        isProcessing: Bool
    ) -> DotStyle {
        let phase = dotPhases[index]
        let ring = activationRing[index]
        let sizeWobble = sin(time * 1.4 + phase * 2.0) * 0.04

        if isProcessing {
            // Rotating chase: outer 8 dots light up sequentially around the
            // perimeter; center pulses steadily so the user sees motion while
            // transcription/post-processing is running.
            if ring == 0 {
                let pulse = 0.55 + sin(time * 3.2) * 0.2
                return DotStyle(
                    intensity: pulse,
                    opacity: 0.35 + pulse * 0.55,
                    scale: 0.5 + CGFloat(pulse) * 0.3 + CGFloat(sizeWobble)
                )
            }
            let dx = Double(col) - 1
            let dy = Double(row) - 1
            let dotAngle = atan2(dy, dx)
            let revPerSec = 0.7
            let sweep = time * revPerSec * 2.0 * .pi
            var delta = (sweep - dotAngle).truncatingRemainder(dividingBy: 2.0 * .pi)
            if delta < 0 { delta += 2.0 * .pi }
            let tail = exp(-delta * 1.6)
            return DotStyle(
                intensity: tail,
                opacity: 0.16 + tail * 0.78,
                scale: 0.42 + CGFloat(tail) * 0.5 + CGFloat(sizeWobble)
            )
        }

        // Each ring activates at a staggered volume threshold:
        // ring 0 (center): 0.0 — always responds
        // ring 1 (edges):  0.1
        // ring 2 (corners): 0.2
        let ringThreshold = CGFloat(ring) * 0.1
        let dotEnergy = max(0, (level - ringThreshold) / max(0.01, 1.0 - ringThreshold))
        let freq = 1.8 + Double(ring) * 0.6
        let wave = sin(time * freq + phase)
        let wobble = wave * 0.12 * Double(dotEnergy)
        let intensity = max(0, min(1, Double(dotEnergy) + wobble))

        let idlePulse: Double
        if ring == 0 {
            idlePulse = 0.20 + sin(time * 1.2) * 0.06
        } else if ring == 1 {
            idlePulse = 0.14 + sin(time * 0.9 + phase) * 0.04
        } else {
            idlePulse = 0.08 + sin(time * 0.7 + phase) * 0.03
        }

        let opacity = intensity > 0.05 ? 0.3 + intensity * 0.6 : idlePulse
        let scale: CGFloat = intensity > 0.05
            ? 0.4 + CGFloat(intensity) * 0.6 + CGFloat(sizeWobble)
            : 0.32 + CGFloat(sizeWobble)

        return DotStyle(intensity: intensity, opacity: opacity, scale: scale)
    }
}

// MARK: - 4. Pixel Matrix (4×4 level meter, bottom-up fill)

private struct PixelMatrixSpectrumView: View {
    let reactiveLevel: CGFloat?
    let isProcessing: Bool
    let progress: Double

    private let cols = 4
    private let rows = 4

    var body: some View {
        GeometryReader { geometry in
            let diameter = min(geometry.size.width, geometry.size.height)

            TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let rawLevel = CGFloat(max(reactiveLevel ?? 0, isProcessing ? 0.06 : 0.02))
                let progressBoost = isProcessing ? CGFloat(max(0, min(1, progress))) * 0.08 : 0
                let level = min(1.0, pow(rawLevel, 0.4) + progressBoost)

                let inset: CGFloat = diameter * 0.18
                let available = diameter - inset * 2
                let cellSize = available / CGFloat(max(cols, rows))
                let gap: CGFloat = 1.0
                let pixelSize = cellSize - gap

                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.07))

                    ForEach(0..<rows * cols, id: \.self) { index in
                        let row = index / cols      // 0 = top
                        let col = index % cols
                        let invertedRow = rows - 1 - row  // 0 = bottom

                        let rowThreshold = CGFloat(invertedRow) / CGFloat(rows)

                        // Per-column ripple for variation
                        let colPhase = Double(col) * 1.3
                        let ripple = sin(time * 2.5 + colPhase) * 0.06 * Double(level)
                        let adjustedLevel = level + CGFloat(ripple)
                        let litAdjusted = adjustedLevel > rowThreshold

                        // Subtle idle glow on bottom row
                        let idleGlow = invertedRow == 0 ? 0.15 + sin(time * 1.2 + Double(col) * 0.8) * 0.05 : 0.0

                        let opacity = litAdjusted ? (0.4 + Double(1.0 - rowThreshold) * 0.5) : idleGlow

                        let x = inset + cellSize * CGFloat(col) + cellSize / 2
                        let y = inset + cellSize * CGFloat(row) + cellSize / 2

                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(Color.white.opacity(opacity))
                            .frame(width: pixelSize, height: pixelSize)
                            .position(x: x, y: y)
                    }
                }
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

// MARK: - 5. Morphing Blob

private struct BlobSpectrumView: View {
    let reactiveLevel: CGFloat?
    let isProcessing: Bool
    let progress: Double

    var body: some View {
        GeometryReader { geometry in
            let diameter = min(geometry.size.width, geometry.size.height)

            TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let rawLevel = CGFloat(max(reactiveLevel ?? 0, isProcessing ? 0.06 : 0.02))
                let progressBoost = isProcessing ? CGFloat(max(0, min(1, progress))) * 0.08 : 0
                let level = min(1.0, pow(rawLevel, 0.45) + progressBoost)

                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.07))

                    BlobShape(time: time, level: Double(level))
                        .fill(Color.white.opacity(0.75))
                        .frame(
                            width: diameter * (0.35 + level * 0.5),
                            height: diameter * (0.35 + level * 0.5)
                        )
                }
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

private struct BlobShape: Shape {
    var time: Double
    var level: Double

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(time, level) }
        set { time = newValue.first; level = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let baseRadius = min(rect.width, rect.height) / 2
        let pointCount = 64

        var path = Path()

        for i in 0..<pointCount {
            let angle = (Double(i) / Double(pointCount)) * .pi * 2

            // Multiple sine waves create organic deformation
            let deform1 = sin(angle * 3 + time * 1.8) * 0.12 * level
            let deform2 = sin(angle * 5 - time * 2.3) * 0.08 * level
            let deform3 = sin(angle * 2 + time * 1.1) * 0.06
            let breath = sin(time * 1.4) * 0.03

            let r = baseRadius * (1.0 + deform1 + deform2 + deform3 + breath)

            let point = CGPoint(
                x: center.x + CGFloat(cos(angle) * r),
                y: center.y + CGFloat(sin(angle) * r)
            )

            if i == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }

        path.closeSubpath()
        return path
    }
}

struct OriginalCompactSuccessStrip: View {
    let mode: String
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: originalModeTheme(for: mode)?.iconName ?? "doc.on.doc.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(originalModeAccentColor(for: mode))

            Text(message)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .lineLimit(1)
                .foregroundStyle(.white.opacity(0.86))
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

struct OriginalContextIconBadge: View {
    let bundleId: String?
    let browserURL: String?

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.75))
                .frame(width: 26, height: 26)

            if let faviconURL = BrowserWebsiteDisplay.faviconURL(from: browserURL) {
                AsyncImage(url: faviconURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 20, height: 20)
                            .clipShape(RoundedRectangle(cornerRadius: 4.5, style: .continuous))
                    default:
                        fallbackIcon
                    }
                }
            } else {
                fallbackIcon
            }
        }
    }

    @ViewBuilder
    private var fallbackIcon: some View {
        if let image = nsImage {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 20, height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 4.5, style: .continuous))
        }
    }

    private var nsImage: NSImage? {
        guard let bundleId else { return nil }
        if bundleId == Bundle.main.bundleIdentifier {
            return NSApp.applicationIconImage
        }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: appURL.path)
    }
}

func originalContextLabel(bundleId: String?, windowTitle: String?, browserURL: String?) -> String {
    if let website = BrowserWebsiteDisplay.from(
        windowTitle: windowTitle,
        browserURL: browserURL,
        bundleId: bundleId
    ) {
        return website.title
    }

    if let title = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
       !title.isEmpty {
        return title
    }

    guard let bundleId,
          let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
    else {
        return "Resonant"
    }

    let bundle = Bundle(url: appURL)
    return bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
        ?? appURL.deletingPathExtension().lastPathComponent
}

struct OriginalNotchHeader: View {
    @Environment(AppState.self) private var appState

    let coordinator: NotchCoordinator

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                OriginalHeaderTabButton(
                    icon: "house.fill",
                    isSelected: coordinator.currentTab == .home
                ) {
                    coordinator.currentTab = .home
                }

                OriginalHeaderTabButton(
                    icon: "pin.fill",
                    isSelected: coordinator.currentTab == .screens
                ) {
                    coordinator.currentTab = .screens
                }
            }
            .padding(3)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )

            Spacer(minLength: 0)

            OriginalHomeHeaderButton(icon: "gearshape.fill") {
                appState.showPrimaryWindow(selectedTab: .appearance)
            }
        }
    }
}

struct OriginalIdleHomeView: View {
    @Environment(AppState.self) private var appState
    let coordinator: NotchCoordinator

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                OriginalOrbView(
                    mode: coordinator.voiceMode,
                    reactiveLevel: 0.12,
                    expression: nil,
                    customHue: appState.settingsManager.dictationOrbHue
                )
                .frame(width: 58, height: 58)

                if coordinator.targetBundleId != nil || coordinator.targetBrowserURL != nil {
                    OriginalContextIconBadge(
                        bundleId: coordinator.targetBundleId,
                        browserURL: coordinator.targetBrowserURL
                    )
                        .offset(x: 8, y: 8)
                } else {
                    Image(systemName: "waveform")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.black.opacity(0.72)))
                        .offset(x: 8, y: 8)
                }
            }
            .padding(.all, 5)
            .padding(.leading, 8)

            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Text(statusSubtitle)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.gray)
                        .lineLimit(1)

                    Text(detailLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.38))
                        .lineLimit(1)
                        .padding(.top, 3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    OriginalGhostActionButton(
                        systemImage: appState.settingsManager.soundsEnabled ? "speaker.wave.2" : "speaker.slash",
                        tooltip: appState.settingsManager.soundsEnabled ? "Sounds on" : "Sounds off"
                    ) {
                        appState.settingsManager.soundsEnabled.toggle()
                    }

                    OriginalGhostActionButton(
                        systemImage: "doc.on.doc",
                        isEnabled: appState.canReuseLastDictation,
                        tooltip: "Copy last dictation"
                    ) {
                        appState.copyLastDictation()
                    }

                    OriginalGhostActionButton(
                        systemImage: "arrow.counterclockwise",
                        isEnabled: appState.canReuseLastDictation,
                        tooltip: "Retry last dictation"
                    ) {
                        Task { await appState.retryLastDictation() }
                    }

                    if let manager = appState.meetingRecorderManager {
                        OriginalGhostActionButton(
                            systemImage: manager.isRecording ? "stop.circle.fill" : "video.fill",
                            isEnabled: true,
                            tooltip: manager.isRecording ? "Stop meeting" : "Record meeting"
                        ) {
                            Task {
                                if manager.isRecording {
                                    await appState.stopMeetingRecording()
                                } else {
                                    await appState.startMeetingRecording(startOrigin: .notch)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var statusTitle: String {
        if coordinator.isMeetingRecording {
            return "Recording Meeting"
        }
        if case .done(let text) = coordinator.state {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Copied" : compactLabel(trimmed, maxLength: 22)
        }
        return "Ready"
    }

    private var statusSubtitle: String {
        if coordinator.isMeetingRecording {
            if let app = coordinator.meetingDetectedApp {
                return app
            }
            return "Tap stop to end"
        }
        if case .done = coordinator.state {
            return "Copied"
        }
        if let routingMessage = appState.inputRoutingMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
           !routingMessage.isEmpty {
            return compactLabel(routingMessage, maxLength: 34)
        }
        return "Hold \(shortHotkeyLabel) to dictate"
    }

    private var detailLabel: String {
        if let routingMessage = appState.inputRoutingMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
           !routingMessage.isEmpty {
            return compactLabel(routingMessage, maxLength: 24)
        }
        return "\(shortHotkeyLabel) + Space • \(shortMicrophoneLabel)"
    }

    private var shortHotkeyLabel: String {
        appState.settingsManager.hotkeyTrigger.shortName
    }

    private var shortMicrophoneLabel: String {
        compactLabel(appState.activeInputDeviceName ?? "System Default", maxLength: 12)
    }

    private func compactLabel(_ text: String, maxLength: Int = 18) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLength else { return trimmed }
        return String(trimmed.prefix(maxLength - 1)) + "…"
    }
}

private struct OriginalHomeHeaderButton: View {
    let icon: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Capsule(style: .continuous)
                .fill(Color.white.opacity(isHovered ? 0.14 : 0.08))
                .frame(width: 30, height: 28)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(isHovered ? 1.0 : 0.88))
                }
                .contentShape(Capsule(style: .continuous))
                .scaleEffect(isHovered ? 1.06 : 1.0)
        }
        .buttonStyle(.plain)
        .clickableCursor()
        .onHover { hovering in
            withAnimation(.spring(response: 0.22, dampingFraction: 0.84)) {
                isHovered = hovering
            }
        }
    }
}

private struct OriginalHeaderTabButton: View {
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isSelected ? .white.opacity(0.92) : isHovered ? .white.opacity(0.7) : .gray)
                .frame(width: 36, height: 28)
                .background(
                    Capsule(style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.12) : isHovered ? Color.white.opacity(0.06) : .clear)
                )
                .scaleEffect(isHovered && !isSelected ? 1.06 : 1.0)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .clickableCursor()
        .onHover { hovering in
            withAnimation(.spring(response: 0.22, dampingFraction: 0.84)) {
                isHovered = hovering
            }
        }
    }
}

private struct OriginalGhostActionButton: View {
    let systemImage: String
    var isEnabled = true
    let tooltip: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isHovered ? Color.white : Color.white.opacity(0.35))
                .frame(width: 28, height: 28)
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(isHovered ? 0.08 : 0))
                )
                .scaleEffect(isHovered ? 1.08 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.15)
        .clickableCursor()
        .help(tooltip)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Hot Mic Views



struct HotMicPanelContent: View {
    let reactiveLevel: CGFloat
    let liveText: String
    let hotWord: String

    var body: some View {
        HStack(spacing: 18) {
            ZStack(alignment: .bottomTrailing) {
                OriginalOrbView(mode: "hotMic", reactiveLevel: reactiveLevel, expression: nil)
                    .frame(width: 58, height: 58)

                HotMicRecordingDot(size: 14)
                    .offset(x: 4, y: 4)
            }
            .padding(.all, 6)
            .padding(.leading, 10)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 4) {
                    Text("Hot Mic")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.white.opacity(0.38))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    HotMicWordPill(word: hotWord)
                }

                Spacer(minLength: 10)

                if liveText.isEmpty {
                    OriginalWaveformView(
                        reactiveLevel: reactiveLevel,
                        accentColor: NSColor(originalModeAccentColor(for: "hotMic"))
                    )
                    .frame(height: 44)
                } else {
                    Text(liveText)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 44)
                }

                Spacer(minLength: 10)

                Text("Listening...")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }
}

private struct HotMicRecordingDot: View {
    var size: CGFloat = 11

    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: size, height: size)
            .shadow(color: .red.opacity(0.6), radius: isPulsing ? 4 : 2)
            .scaleEffect(isPulsing ? 1.15 : 1.0)
            .onAppear {
                withAnimation(.spring(duration: 1.0, bounce: 0.3).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            }
    }
}

private struct HotMicWordPill: View {
    let word: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "waveform")
                .font(.system(size: 8, weight: .bold))
            Text("\"\(word)\"")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(Color.red.opacity(0.25))
        )
    }
}
