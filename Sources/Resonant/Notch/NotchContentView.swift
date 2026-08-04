import SwiftUI

/// Resonant embedded notch view, ported closer to the original boring-notch layout.
struct NotchContentView: View {
    @Environment(AppState.self) private var appState

    var coordinator: NotchCoordinator

    @State private var clipWidth: CGFloat = NotchSizes.fallbackClosedWidth
    @State private var clipHeight: CGFloat = NotchSizes.fallbackClosedHeight

    var body: some View {
        let overlayMode = appState.settingsManager.overlayMode
        let presentationStyle = coordinator.presentationStyle(for: overlayMode)
        let targetSize = coordinator.preferredSize(for: overlayMode)

        ZStack(alignment: .top) {
            backgroundLayer(for: presentationStyle)

            Group {
                switch presentationStyle {
                case .compact:
                    compactContent
                        .frame(maxHeight: .infinity)
                        .transition(.notchContentSwap)
                case .minimal:
                    minimalContent
                        .transition(.notchContentSwap)
                case .panel:
                    panelContent
                        .transition(.notchContentSwap)
                }
            }
            .padding(.horizontal, horizontalPadding(for: presentationStyle))

            if coordinator.expressionVisible,
               let expression = coordinator.activeExpression,
               coordinator.isOpen(for: overlayMode) {
                ExpressionView(expression: expression)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    .zIndex(1)
            }
        }
        .frame(width: clipWidth, height: clipHeight, alignment: .top)
        .clipShape(
            NotchShape(
                topCornerRadius: NotchSizes.closedTopCornerRadius,
                bottomCornerRadius: bottomCornerRadius(for: presentationStyle)
            )
        )
        .background(alignment: .top) {
            // Pre-fill the target area with black so the desktop never
            // flashes through during expansion (panel resize is async).
            NotchShape(
                topCornerRadius: NotchSizes.closedTopCornerRadius,
                bottomCornerRadius: bottomCornerRadius(for: presentationStyle)
            )
            .fill(Color.black)
            .frame(width: targetSize.width, height: targetSize.height)
        }
        .overlay {
            // Edge light: hairline catching the bottom rim of the glass.
            // Top stays unstroked so the shape remains seamless with the
            // bezel; hidden in compact so the hardware notch reads as pure
            // hardware.
            NotchShape(
                topCornerRadius: NotchSizes.closedTopCornerRadius,
                bottomCornerRadius: bottomCornerRadius(for: presentationStyle)
            )
            .stroke(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .clear, location: 0.5),
                        .init(color: .white.opacity(0.07), location: 0.8),
                        .init(color: .white.opacity(0.22), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 0.5
            )
            .opacity(presentationStyle == .compact ? 0 : 1)
            .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(NotchMotion.animation, value: coordinator.voiceMode)

        .animation(NotchMotion.animation, value: coordinator.showsHome)
        .animation(NotchMotion.animation, value: overlayMode)
        .onChange(of: targetSize.width) { _, newWidth in
            withAnimation(newWidth > clipWidth ? NotchMotion.openWidthAnimation : NotchMotion.closeAnimation) {
                clipWidth = newWidth
            }
        }
        .onChange(of: targetSize.height) { _, newHeight in
            withAnimation(newHeight > clipHeight ? NotchMotion.openHeightAnimation : NotchMotion.closeAnimation) {
                clipHeight = newHeight
            }
        }
        .onAppear {
            let size = coordinator.preferredSize(for: appState.settingsManager.overlayMode)
            clipWidth = size.width
            clipHeight = size.height
        }
    }

    @ViewBuilder
    private func backgroundLayer(for presentationStyle: NotchPresentationStyle) -> some View {
        NotchShape(
            topCornerRadius: NotchSizes.closedTopCornerRadius,
            bottomCornerRadius: bottomCornerRadius(for: presentationStyle)
        )
        .fill(Color.black)
    }

    @ViewBuilder
    private var compactContent: some View {
        switch coordinator.state {
        case .done(let text):
            OriginalCompactSuccessStrip(mode: coordinator.voiceMode, message: text)
                .padding(.horizontal, 10)
        default:
            Color.clear
        }
    }

    @ViewBuilder
    private var meetingMinimalStrip: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let activeSession = appState.meetingRecorderManager?.activeSession
            let title = activeSession?.captureContext?.effectiveTitle ?? coordinator.meetingDetectedApp
            let elapsed = appState.meetingRecorderManager?.recordingElapsed ?? coordinator.meetingElapsed
            let closedNotchSize = currentClosedNotchSize()
            let sideWidth = NotchSizes.minimalStripSideWidth(for: closedNotchSize.height)

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Circle()
                        .fill(.green)
                        .frame(width: 7, height: 7)
                        .shadow(color: .green.opacity(0.6), radius: 3)
                        .frame(width: sideWidth, height: closedNotchSize.height)

                    Spacer(minLength: 0)
                }
                .frame(height: closedNotchSize.height)

                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Recording")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(1)

                        if let title {
                            Text(title)
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(1)
                                .minimumScaleFactor(0.86)
                                .truncationMode(.tail)
                        }
                    }
                    .layoutPriority(1)

                    Spacer(minLength: 8)

                    Text(formatElapsed(elapsed))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)
                        .layoutPriority(2)
                }
                .padding(.top, 4)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, minHeight: NotchSizes.minimalTextRowHeight, alignment: .center)
                .background(Color.white.opacity(0.035))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    @ViewBuilder
    private var minimalContent: some View {
        if coordinator.isMeetingRecording && coordinator.isCompactState {
            meetingMinimalStrip
        } else {
            let isError = coordinator.voiceMode == "error"
            let isProcessingDisplay = coordinator.voiceMode == "processing" || coordinator.isCommandThinking
            let errorMessage: String? = if case .error(let msg, _) = coordinator.state { msg } else { nil }
            let notice: NotchOverlayState.Notice? = if case .notice(let notice) = coordinator.state { notice } else { nil }

            MinimalStrip(
                mode: coordinator.voiceMode,
                reactiveLevel: isProcessingDisplay ? nil : CGFloat(coordinator.audioLevel),
                isProcessing: isProcessingDisplay,
                progress: coordinator.processingProgress,
                statusText: statusText,
                isLocked: coordinator.isRecordingLocked,
                isError: isError,
                errorMessage: errorMessage,
                errorSubtype: coordinator.errorSubtype,
                notice: notice,
                isHotMic: coordinator.isHotMicActive,
                hotMicLiveText: coordinator.hotMicLiveText,
                recordingLiveText: coordinator.recordingLiveText,
                closedNotchSize: currentClosedNotchSize()
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var panelContent: some View {
        if coordinator.expressionVisible {
            Color.clear
        } else if coordinator.showsHome {
            VStack(spacing: 12) {
                OriginalNotchHeader(coordinator: coordinator)
                Group {
                    switch coordinator.currentTab {
                    case .home:
                        OriginalIdleHomeView(coordinator: coordinator)
                    case .screens:
                        ScreenPickerView()
                    }
                }
                .animation(NotchMotion.animation, value: coordinator.currentTab)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .transition(.notchContentSwap)
        } else if coordinator.isHotMicActive {
            HotMicPanelContent(
                reactiveLevel: CGFloat(coordinator.audioLevel),
                liveText: coordinator.hotMicLiveText ?? "",
                hotWord: appState.settingsManager.hotWord
            )
            .transition(.notchContentSwap)
        } else if case .notice(let notice) = coordinator.state {
            NoticePanelContent(notice: notice)
                .transition(.notchContentSwap)
        } else {
            let isCommandProcessing = coordinator.voiceMode == "command" && coordinator.isCommandThinking
            let orbMode = coordinator.voiceMode == "command" && !isCommandProcessing ? "listening" : coordinator.voiceMode
            HStack(spacing: 18) {
                ZStack(alignment: .bottomTrailing) {
                    OriginalOrbView(
                        mode: orbMode,
                        reactiveLevel: CGFloat(coordinator.audioLevel),
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
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if originalModeTheme(for: coordinator.voiceMode) != nil {
                        OriginalModeIconBadge(mode: coordinator.voiceMode, size: 18, iconSize: 10)
                            .offset(x: -6, y: 6)
                    }
                }
                .padding(.all, 6)
                .padding(.leading, 10)

                OriginalTranscriptPanel(
                    title: originalContextLabel(
                        bundleId: coordinator.targetBundleId,
                        windowTitle: coordinator.targetWindowTitle,
                        browserURL: coordinator.targetBrowserURL
                    ),
                    statusText: statusText,
                    reactiveLevel: coordinator.voiceMode == "processing" || coordinator.isCommandThinking ? nil : CGFloat(coordinator.audioLevel),
                    isProcessing: coordinator.voiceMode == "processing" || coordinator.isCommandThinking,
                    progress: coordinator.processingProgress,
                    mode: orbMode,
                    isLocked: coordinator.isRecordingLocked
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .transition(.notchContentSwap)
        }
    }

    private var statusText: String {
        switch coordinator.state {
        case .recording(let mode, _, _):
            if mode != .memo,
               let liveText = coordinator.recordingLiveText?.trimmingCharacters(in: .whitespacesAndNewlines),
               !liveText.isEmpty {
                return liveText
            }
            if coordinator.isRecordingLocked {
                return mode == .memo ? "Memo locked. Keep talking..." : "Locked. Keep talking..."
            }
            if let recordingHint = coordinator.recordingHint {
                return recordingHint
            }
            return mode == .memo ? "Recording memo..." : "Listening..."
        case .processing(_, let stage):
            return stage
        case .done(let text):
            return text
        case .notice(let notice):
            return notice.detail ?? notice.title
        case .error(let message, _):
            return message
        case .idle:
            return "Ready"
        case .hotMic:
            return "Hot mic"
        case .command(let stage):
            switch stage {
            case .listening:
                return "Listening for command..."
            case .awaitingFollowUp(_, _, let status):
                return status
            case .thinking(let status):
                return status
            case .result(let text, _):
                return text
            }
        }
    }

    private func horizontalPadding(for presentationStyle: NotchPresentationStyle) -> CGFloat {
        switch presentationStyle {
        case .compact:
            return 0
        case .minimal:
            return NotchSizes.minimalStripHorizontalPadding(for: currentClosedNotchSize())
        case .panel:
            return 28
        }
    }

    private func formatElapsed(_ timeInterval: TimeInterval) -> String {
        let totalSeconds = max(0, Int(timeInterval.rounded(.down)))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func bottomCornerRadius(for presentationStyle: NotchPresentationStyle) -> CGFloat {
        switch presentationStyle {
        case .compact:
            return NotchSizes.closedBottomCornerRadius
        case .minimal:
            if case .error = coordinator.state {
                return NotchSizes.openBottomCornerRadius
            }
            // Tighter radius so the NotchShape clipShape doesn't eat into
            // the orb/spectrum content at the bottom corners.
            return 8
        case .panel:
            return NotchSizes.openBottomCornerRadius
        }
    }
}

private struct NoticePanelContent: View {
    let notice: NotchOverlayState.Notice

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: notice.icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.blue.opacity(0.9))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(notice.title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                if let detail = notice.detail {
                    Text(detail)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.68))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }

            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}
