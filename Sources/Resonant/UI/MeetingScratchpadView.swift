import SwiftUI

struct MeetingCompanionPanelView: View {
    private enum Layout {
        static let unit: CGFloat = 8
        static let inset: CGFloat = 16
        static let sectionSpacing: CGFloat = 16
        static let compactSpacing: CGFloat = 8
        static let outerCorner: CGFloat = 24
        static let controlCorner: CGFloat = 8
        static let cardCorner: CGFloat = 8
        static let pillWidth: CGFloat = 24
        static let pillHeight: CGFloat = 64
        static let notesMinHeight: CGFloat = 128
        static let notesEmptyHeight: CGFloat = 176
        static let transcriptMinHeight: CGFloat = 152
    }

    @Bindable var state: MeetingCompanionState
    let manager: MeetingRecorderManager?
    @Bindable var notepad: MeetingNotepad
    let onStop: () -> Void
    let onExpand: () -> Void
    let onCollapse: () -> Void
    let onClose: () -> Void
    let onStartDetected: () -> Void
    let onDismissDetected: () -> Void
    let microphoneOptions: [AudioInputDevice]
    let selectedMicrophoneUID: String?
    let onSelectMicrophone: (String?) -> Void
    let onOpenAudioSettings: () -> Void

    @State private var showStopConfirm = false
    @State private var now = Date()
    @State private var pulseScale: CGFloat = 1.0

    private let tickTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if state.isExpanded {
                sidebar
            } else {
                collapsedPill
            }
        }
        .onReceive(tickTimer) { now = $0 }
    }

    private var collapsedPill: some View {
        Button(action: onExpand) {
            pillIndicator
                .frame(width: Layout.pillWidth, height: Layout.pillHeight)
                .glassPill(elevation: .raised)
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .help(pillHelpText)
        .accessibilityLabel(pillHelpText)
    }

    @ViewBuilder
    private var pillIndicator: some View {
        if state.phase == .recording || state.phase == .starting {
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.22))
                    .frame(width: 16, height: 16)
                    .scaleEffect(pulseScale)
                    .animation(
                        .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                        value: pulseScale
                    )
                Circle()
                    .fill(Color.red)
                    .frame(width: Layout.unit, height: Layout.unit)
            }
            .onAppear { pulseScale = 1.35 }
            .onDisappear { pulseScale = 1.0 }
        } else {
            Circle()
                .fill(phaseTint)
                .frame(width: Layout.unit, height: Layout.unit)
        }
    }

    private var pillHelpText: String {
        switch state.phase {
        case .recording, .starting:
            return "Meeting recording · \(collapsedTimeLabel)"
        case .detecting:
            return "Possible meeting"
        case .processing:
            return "Wrapping up meeting"
        case .saved:
            return "Meeting saved"
        case .error:
            return "Meeting needs attention"
        case .hidden:
            return "Open meeting companion"
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            header

            Divider().opacity(0.55)

            contentArea
            .layoutPriority(1)

            Divider().opacity(0.55)

            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassSurface(cornerRadius: Layout.outerCorner, elevation: .floating)
    }

    @ViewBuilder
    private var contentArea: some View {
        if showsNotesAndTranscript {
            VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                topSections
                notesAndTranscriptStack
            }
            .padding(Layout.inset)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                    topSections

                    if state.phase == .detecting {
                        detectionActions
                    }

                    if state.phase == .processing || notepad.isProcessing {
                        processingSection
                    } else if state.phase == .error {
                        errorSection
                    }
                }
                .padding(Layout.inset)
            }
            .frame(minHeight: 144)
        }
    }

    @ViewBuilder
    private var topSections: some View {
        if state.phase != .recording {
            statusSection
            contextSection
        } else if let audioHealthMessage = state.audioHealthMessage {
            audioStatusSection
            audioHealthBanner(audioHealthMessage)
        } else if manager != nil {
            audioStatusSection
        }
    }

    private var showsNotesAndTranscript: Bool {
        state.phase != .processing
            && !notepad.isProcessing
            && state.phase != .error
            && state.phase != .detecting
    }

    private var notesAndTranscriptStack: some View {
        GeometryReader { proxy in
            let availableHeight = max(0, proxy.size.height - Layout.sectionSpacing)
            let proposedNotesHeight = max(Layout.notesEmptyHeight, floor(availableHeight / 2))
            let maxNotesHeight = max(Layout.notesMinHeight, availableHeight - Layout.transcriptMinHeight)
            let notesHeight = min(proposedNotesHeight, maxNotesHeight)

            VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                liveNotesSection
                    .frame(height: notesHeight)

                transcriptSection
                    .frame(maxWidth: .infinity, minHeight: Layout.transcriptMinHeight, maxHeight: .infinity)
                    .layoutPriority(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .layoutPriority(1)
    }

    private var header: some View {
        HStack(spacing: Layout.compactSpacing) {
            statusDot
                .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle)
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1)
                Text(headerSubtitle)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            chromeButton(systemImage: "sidebar.right", help: "Collapse", action: onCollapse)

            if state.phase == .recording || state.phase == .starting {
                stopButton
            } else {
                chromeButton(systemImage: "xmark", help: "Close", action: onClose)
            }
        }
        .padding(.horizontal, Layout.inset)
        .padding(.top, Layout.inset)
        .padding(.bottom, Layout.unit)
    }

    private func chromeButton(systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: Layout.controlCorner, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
                .contentShape(RoundedRectangle(cornerRadius: Layout.controlCorner, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private var stopButton: some View {
        Button {
            showStopConfirm = true
        } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color(red: 1.00, green: 0.32, blue: 0.30),
                                         Color(red: 0.92, green: 0.20, blue: 0.20)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )
                .overlay(
                    Circle()
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                )
                .shadow(color: Color.red.opacity(0.32), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .help("Stop recording")
        .accessibilityLabel("Stop meeting recording")
        .confirmationDialog("Stop meeting recording?", isPresented: $showStopConfirm) {
            Button("Stop Recording", role: .destructive) { onStop() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The transcript and notes will be saved.")
        }
    }

    private var statusSection: some View {
        sectionCard {
            HStack(alignment: .top, spacing: Layout.compactSpacing) {
                Image(systemName: phaseIcon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(phaseTint)
                    .frame(width: 24)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 4) {
                    Text(phaseTitle)
                        .font(.system(size: 13, weight: .semibold))
                    Text(statusDetail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
        }
    }

    private var detectionActions: some View {
        HStack(spacing: 8) {
            Button(action: onStartDetected) {
                Label("Start", systemImage: "record.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button(action: onDismissDetected) {
                Label("Not now", systemImage: "xmark.circle")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    private var contextSection: some View {
        sectionCard {
            VStack(alignment: .leading, spacing: Layout.compactSpacing) {
                labeledValue("Source", state.origin.displayLabel)

                if let app = state.detectedAppName {
                    labeledValue("App", app)
                }

                if let subtitle = state.subtitle,
                   subtitle != state.origin.displayLabel {
                    labeledValue("Context", subtitle)
                }

                if let audioHealthMessage = state.audioHealthMessage {
                    Divider().opacity(0.5)
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.orange)
                        Text(audioHealthMessage)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var audioStatusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14)
                Text(primaryAudioLabel)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .frame(width: 76, alignment: .leading)
                Menu {
                    Button {
                        onSelectMicrophone(nil)
                    } label: {
                        Label("Use \(systemDefaultMicrophoneName)", systemImage: selectedMicrophoneUID == nil ? "checkmark" : "mic")
                    }
                    if !microphoneOptions.isEmpty {
                        Divider()
                        ForEach(microphoneOptions) { device in
                            Button {
                                onSelectMicrophone(device.id)
                            } label: {
                                Label(
                                    device.isSystemDefault ? "\(device.name) (Default)" : device.name,
                                    systemImage: selectedMicrophoneUID == device.id ? "checkmark" : "mic"
                                )
                            }
                        }
                    }
                    Divider()
                    Button("More Microphone Settings", action: onOpenAudioSettings)
                } label: {
                    HStack(spacing: 4) {
                        Text(microphoneStatusText)
                            .font(.system(size: 11.5, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .frame(minHeight: SettingsLayout.controlMinHeight)
                    .background(
                        RoundedRectangle(cornerRadius: Layout.controlCorner, style: .continuous)
                            .fill(Color.primary.opacity(0.055))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Layout.controlCorner, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: Layout.controlCorner, style: .continuous))
                }
                .menuStyle(.borderlessButton)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(primaryAudioPickerHelp)
                .accessibilityLabel(primaryAudioPickerHelp)
            }

            if !isRoomMode {
                audioStatusRow(
                    icon: "speaker.wave.2.fill",
                    label: "Meeting audio",
                    value: manager?.systemAudioStatus ?? "System audio"
                )
            }

            if let defaultWarningText {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.orange)
                        .padding(.top, 1)
                    Text(defaultWarningText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }

            if shouldWarnMissingMicTranscript {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "mic.slash.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.orange)
                        .padding(.top, 1)
                    Text("Meeting audio is coming through, but we have not heard your voice yet. Choose the microphone you are speaking into.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.top, 2)
            }
        }
        .padding(Layout.compactSpacing)
        .background(
            RoundedRectangle(cornerRadius: Layout.cardCorner, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Layout.cardCorner, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }

    private func audioStatusRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 14)
            Text(label)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .frame(width: 76, alignment: .leading)
            Text(value)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var liveNotesSection: some View {
        VStack(alignment: .leading, spacing: Layout.compactSpacing) {
            sectionHeader("Scratchpad", systemImage: "square.and.pencil")

            ZStack(alignment: .topLeading) {
                if notepad.liveNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Tap to add bullets. Tab to indent, Shift-Tab to outdent.")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, Layout.compactSpacing + 4)
                        .padding(.vertical, Layout.compactSpacing)
                        .allowsHitTesting(false)
                }

                BulletTextView(
                    text: $notepad.liveNotes,
                    minHeight: Layout.notesMinHeight,
                    maintainsBulletList: true
                )
                    .padding(.horizontal, Layout.compactSpacing)
                    .padding(.vertical, 4)
            }
            .frame(maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Layout.cardCorner, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Layout.cardCorner, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.75)
            )
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: Layout.compactSpacing) {
            sectionHeader("Live transcript", systemImage: "text.quote")

            if recentUtterances.isEmpty {
                sectionCard {
                    Text(state.phase == .starting ? "Transcript will appear once audio is ready." : "Listening...")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: Layout.compactSpacing) {
                            ForEach(recentUtterances) { utterance in
                                HStack(alignment: .firstTextBaseline, spacing: Layout.compactSpacing) {
                                    Text(utteranceTimeLabel(utterance))
                                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                        .frame(width: 40, alignment: .leading)
                                    Text(utterance.speaker.displayLabel)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(utterance.speaker.color)
                                        .frame(width: 48, alignment: .leading)
                                    Text(utterance.text)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.primary.opacity(0.88))
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .id(utterance.id)
                            }
                        }
                        .padding(Layout.inset)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(
                        RoundedRectangle(cornerRadius: Layout.cardCorner, style: .continuous)
                            .fill(Color.primary.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Layout.cardCorner, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 0.75)
                    )
                    .frame(maxHeight: .infinity)
                    .onChange(of: recentUtterances.last?.id) { _, newValue in
                        guard let id = newValue else { return }
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var processingSection: some View {
        VStack(alignment: .leading, spacing: Layout.compactSpacing) {
            sectionHeader("Finishing", systemImage: "sparkles")

            sectionCard {
                VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(notepad.processingHeadline ?? "Analyzing the meeting")
                            .font(.system(size: 13, weight: .semibold))
                        if let detail = notepad.processingDetail, !detail.isEmpty {
                            Text(detail)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if notepad.processingStages.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Preparing saved meeting")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: Layout.compactSpacing) {
                            ForEach(notepad.processingStages) { stage in
                                HStack(spacing: Layout.compactSpacing) {
                                    processingStageIcon(stage.status)
                                    Text(stage.title)
                                        .font(.system(size: 12.5, weight: .medium))
                                        .foregroundStyle(stageForegroundStyle(stage.status))
                                    Spacer(minLength: 0)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                }
                .animation(.spring(response: 0.25, dampingFraction: 0.85), value: notepad.processingStages)
            }
        }
    }

    private func audioHealthBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: Layout.compactSpacing) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.orange)
                .padding(.top, 1)
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Layout.compactSpacing)
        .background(
            RoundedRectangle(cornerRadius: Layout.cardCorner, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Layout.cardCorner, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.18), lineWidth: 0.5)
        )
    }

    private var errorSection: some View {
        sectionCard {
            HStack(alignment: .top, spacing: Layout.compactSpacing) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.orange)
                    .padding(.top, 1)
                Text(state.errorMessage ?? "Meeting recording failed.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: Layout.compactSpacing) {
            Image(systemName: "eye.slash")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(footerText)
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Layout.inset)
        .padding(.vertical, Layout.unit)
    }

    private var statusDot: some View {
        ZStack {
            Circle()
                .fill(phaseTint.opacity(0.16))
                .scaleEffect(state.phase == .recording ? 1.8 : 1)
            Circle()
                .fill(phaseTint)
                .frame(width: 8, height: 8)
        }
        .animation(.easeInOut(duration: 0.25), value: state.phase)
    }

    private func sectionCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(Layout.inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Layout.cardCorner, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Layout.cardCorner, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
    }

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        HStack(spacing: Layout.compactSpacing) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
            Spacer(minLength: 0)
        }
    }

    private func labeledValue(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func processingStageIcon(_ status: MeetingNotepad.ProcessingStage.Status) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle")
                .font(.system(size: 11, weight: .light))
                .foregroundStyle(Color.primary.opacity(0.22))
                .frame(width: 16, height: 16)
        case .active:
            ProgressView()
                .controlSize(.mini)
                .tint(Color.primary.opacity(0.65))
                .frame(width: 16, height: 16)
        case .complete:
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .light))
                .foregroundStyle(Color.primary.opacity(0.45))
                .frame(width: 16, height: 16)
        }
    }

    private func stageForegroundStyle(_ status: MeetingNotepad.ProcessingStage.Status) -> Color {
        switch status {
        case .pending:
            return Color.primary.opacity(0.45)
        case .active:
            return Color.primary.opacity(0.78)
        case .complete:
            return Color.primary.opacity(0.92)
        }
    }

    private var displayTitle: String {
        state.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? state.detectedAppName
            ?? "Meeting"
    }

    private var headerSubtitle: String {
        if state.phase == .recording || state.phase == .starting {
            return "\(state.origin.displayLabel) - \(elapsedLabel)"
        }
        return state.statusDetail ?? state.origin.displayLabel
    }

    private var statusDetail: String {
        if state.phase == .recording {
            return "Recording for \(elapsedLabel). Notes and transcript are saved automatically."
        }
        if state.phase == .saved, let count = state.lastSavedWordCount {
            return "Saved with \(count) word\(count == 1 ? "" : "s")."
        }
        return state.statusDetail ?? state.origin.displayLabel
    }

    private var phaseTitle: String {
        switch state.phase {
        case .hidden:
            return "Meeting companion"
        case .detecting:
            return "Possible meeting"
        case .starting:
            return "Starting meeting"
        case .recording:
            return "Recording"
        case .processing:
            return "Wrapping up"
        case .error:
            return "Needs attention"
        case .saved:
            return "Saved"
        }
    }

    private var phaseIcon: String {
        switch state.phase {
        case .hidden:
            return "video"
        case .detecting:
            return "dot.radiowaves.left.and.right"
        case .starting:
            return "hourglass"
        case .recording:
            return "record.circle"
        case .processing:
            return "sparkles"
        case .error:
            return "exclamationmark.triangle"
        case .saved:
            return "checkmark.circle"
        }
    }

    private var phaseTint: Color {
        switch state.phase {
        case .detecting:
            return .blue
        case .starting, .processing:
            return .orange
        case .recording:
            return .red
        case .error:
            return .orange
        case .saved:
            return .green
        case .hidden:
            return .secondary
        }
    }

    private var footerText: String {
        if state.phase == .processing {
            return "Panel closes after the meeting is saved"
        }
        return "Hidden from screen sharing"
    }

    private var collapsedTimeLabel: String {
        switch state.phase {
        case .recording, .starting:
            return elapsedLabel
        case .detecting:
            return "Meet"
        case .processing:
            return "Save"
        case .error:
            return "Fix"
        case .saved:
            return "Done"
        case .hidden:
            return "Meet"
        }
    }

    private var elapsedLabel: String {
        guard let startedAt = state.startedAt else { return "0:00" }
        let seconds = max(0, Int(now.timeIntervalSince(startedAt)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private var recentUtterances: [MeetingUtterance] {
        manager?.liveUtterances ?? []
    }

    private var microphoneStatusText: String {
        guard let manager else { return systemDefaultMicrophoneName }
        let name = manager.activeMicrophoneName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? systemDefaultMicrophoneName
        return manager.activeMicrophoneUsesSystemDefault ? "\(name) (Mac default)" : name
    }

    private var isRoomMode: Bool {
        manager?.captureMode == .room
    }

    private var primaryAudioLabel: String {
        isRoomMode ? "Room audio" : "Your voice"
    }

    private var primaryAudioPickerHelp: String {
        isRoomMode ? "Choose the microphone for the room" : "Choose the microphone for your voice"
    }

    private var systemDefaultMicrophoneName: String {
        microphoneOptions.first(where: \.isSystemDefault)?.name ?? "Mac microphone"
    }

    private var defaultWarningText: String? {
        guard selectedMicrophoneUID == nil,
              let externalMic = microphoneOptions.first(where: { !$0.isBuiltIn && !$0.isSystemDefault })
        else { return nil }

        return "Using \(systemDefaultMicrophoneName). If you are speaking into \(externalMic.name), choose it above."
    }

    private var shouldWarnMissingMicTranscript: Bool {
        guard state.phase == .recording,
              !isRoomMode,
              let startedAt = state.startedAt,
              now.timeIntervalSince(startedAt) > 20
        else { return false }
        let utterances = recentUtterances
        return utterances.contains(where: { $0.speaker != .you })
            && !utterances.contains(where: { $0.speaker == .you })
    }

    private func utteranceTimeLabel(_ utterance: MeetingUtterance) -> String {
        guard let startedAt = state.startedAt else { return "--:--" }
        let seconds = max(0, Int(utterance.timestamp.timeIntervalSince(startedAt)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
