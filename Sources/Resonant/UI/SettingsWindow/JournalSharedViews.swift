import AppKit
import SwiftUI

struct JournalDateHeaderView: View {
    let selectedDate: Date
    let isToday: Bool
    let isRefreshing: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onRefresh: () -> Void
    var onHowItWorks: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(JournalDateFormatters.title(for: selectedDate))
                    .font(.system(size: 26, weight: .bold, design: .rounded))

                if let subtitle = JournalDateFormatters.subtitle(for: selectedDate) {
                    Text(subtitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 4) {
                if let onHowItWorks {
                    JournalHeaderButton(systemImage: "questionmark.circle", action: onHowItWorks)
                        .help("How it works")
                }

                JournalHeaderButton(systemImage: "chevron.left", action: onPrevious)

                JournalHeaderButton(systemImage: "chevron.right", action: onNext)
                    .disabled(isToday)

                JournalHeaderButton(systemImage: "arrow.clockwise", action: onRefresh) {
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .disabled(isRefreshing)
                .help("Regenerate journal")
            }
        }
    }
}

struct JournalHeaderButton<Overlay: View>: View {
    let systemImage: String
    let action: () -> Void
    @ViewBuilder var overlay: () -> Overlay

    @State private var isHovered = false

    init(systemImage: String, action: @escaping () -> Void, @ViewBuilder overlay: @escaping () -> Overlay = { EmptyView() }) {
        self.systemImage = systemImage
        self.action = action
        self.overlay = overlay
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? SettingsPalette.accentFill : SettingsPalette.elevatedBackground)

                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isHovered ? SettingsPalette.border.opacity(0.28) : .clear, lineWidth: 1)

                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))

                overlay()
            }
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isHovered ? .primary : .secondary)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.18)) {
                isHovered = hovering
            }
        }
    }
}

struct JournalDayTimelineView: View {
    let blocks: [JournalBlock]

    private static let barHeight: CGFloat = 36

    private static let edgeOverhang: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            let layout = JournalTimelineLayout(blocks: blocks, width: proxy.size.width)
            let lastIndex = layout.segments.count - 1

            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(SettingsPalette.timelineTrack)

                    ForEach(Array(layout.segments.enumerated()), id: \.element.id) { index, segment in
                        let isFirst = index == 0
                        let isLast = index == lastIndex
                        let extraLeading: CGFloat = isFirst ? Self.edgeOverhang : 0
                        let extraTrailing: CGFloat = isLast ? Self.edgeOverhang : 0
                        let width = max(segment.width + extraLeading + extraTrailing, 3)
                        let xOffset = segment.x - extraLeading

                        Rectangle()
                            .fill(segment.color.opacity(0.82))
                            .frame(width: width, height: Self.barHeight - 2)
                            .overlay {
                                if let bundleId = segment.bundleId {
                                    segmentContent(segment: segment, bundleId: bundleId)
                                }
                            }
                            .clipped()
                            .offset(x: xOffset, y: 1)
                    }
                }
                .frame(height: Self.barHeight)

                // Hour marks
                if !layout.hourMarks.isEmpty {
                    ZStack(alignment: .topLeading) {
                        ForEach(layout.hourMarks) { mark in
                            VStack(spacing: 1) {
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.15))
                                    .frame(width: 1, height: 4)

                                Text(mark.label)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.quaternary)
                                    .fixedSize()
                            }
                            .offset(x: mark.x - 0.5)
                        }
                    }
                    .frame(height: 18)
                    .padding(.top, 2)
                }
            }
        }
        .frame(height: hourMarksExist ? 56 : Self.barHeight)
    }

    @ViewBuilder
    private func segmentContent(segment: JournalTimelineLayout.Segment, bundleId: String) -> some View {
        let showDuration = segment.width >= 64 && segment.duration >= 60
        let showIcon = segment.width >= 28

        if showIcon && showDuration {
            HStack(spacing: 4) {
                segmentIcon(segment: segment, bundleId: bundleId)

                Text(JournalDateFormatters.duration(segment.duration))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .monospacedDigit()
                    .lineLimit(1)
            }
        } else if showIcon {
            segmentIcon(segment: segment, bundleId: bundleId)
        }
    }

    @ViewBuilder
    private func segmentIcon(segment: JournalTimelineLayout.Segment, bundleId: String) -> some View {
        if segment.isMeeting {
            Image(systemName: "video.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 16, height: 16)
        } else {
            JournalAppIconBadgeView(
                bundleId: bundleId,
                tint: .white.opacity(0.9),
                size: 16,
                fallbackDotSize: 5
            )
        }
    }

    private var hourMarksExist: Bool {
        guard let first = blocks.first?.startTime, let last = blocks.last?.endTime else { return false }
        return last.timeIntervalSince(first) > 3600
    }
}

struct JournalStatsStripView: View {
    let day: JournalDay?
    let blocks: [JournalBlock]

    private var meetingCount: Int {
        blocks.filter { $0.isMeeting == true }.count
    }

    private var sessionCount: Int {
        blocks.filter { $0.isMeeting != true }.count
    }

    private var totalWords: Int {
        blocks.reduce(0) { $0 + $1.wordCount }
    }

    private var timeSpan: String? {
        guard let first = blocks.first, let last = blocks.last else { return nil }
        return "\(JournalDateFormatters.time(first.startTime))-\(JournalDateFormatters.time(last.endTime))"
    }

    var body: some View {
        HStack(spacing: 10) {
            if sessionCount > 0 {
                Text("\(sessionCount) \(sessionCount == 1 ? "session" : "sessions")")
            }
            if meetingCount > 0 {
                if sessionCount > 0 { journalDivider }
                Text("\(meetingCount) \(meetingCount == 1 ? "meeting" : "meetings")")
            }
            if totalWords > 0 {
                journalDivider
                Text("\(totalWords.formatted()) words")
            }
            if let timeSpan {
                journalDivider
                Text(timeSpan)
            }
            if let generatedAt = day?.generatedAt {
                journalDivider
                Text("Updated \(generatedAt.formatted(date: .omitted, time: .shortened))")
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }

    private var journalDivider: some View {
        Text("·")
            .foregroundStyle(SettingsPalette.border)
    }
}

// MARK: - Accomplishments (bullet summary)

struct JournalHighlightsView: View {
    let blocks: [JournalBlock]

    private var highlights: [JournalAccomplishment] {
        JournalReviewEngine.accomplishmentHighlights(from: blocks)
    }

    private var meetingBlockIDs: Set<UUID> {
        Set(blocks.filter { $0.isMeeting == true }.map(\.id))
    }

    var body: some View {
        if !highlights.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                JournalSectionHeader(title: "HIGHLIGHTS")

                VStack(spacing: 0) {
                    ForEach(Array(highlights.enumerated()), id: \.element.id) { index, highlight in
                        JournalAccomplishmentRow(
                            highlight: highlight,
                            isMeeting: meetingBlockIDs.contains(highlight.id)
                        )

                        if index < highlights.count - 1 {
                            Divider()
                                .padding(.leading, 48)
                        }
                    }
                }
                .padding(4)
                .journalCard(cornerRadius: 12)
            }
        }
    }
}

struct JournalAccomplishmentRow: View {
    let highlight: JournalAccomplishment
    var isMeeting: Bool = false

    private var accentColor: Color {
        isMeeting ? JournalPalette.meetingColor : JournalPalette.colorForBundleId(highlight.primaryBundleId)
    }

    private var durationText: String? {
        guard highlight.duration >= 60 else { return nil }
        return JournalDateFormatters.duration(highlight.duration)
    }

    private var timeRange: String {
        "\(JournalDateFormatters.time(highlight.startTime)) – \(JournalDateFormatters.time(highlight.endTime))"
    }

    /// Structured metadata line: app names, duration, time range
    private var metaLine: String {
        var parts: [String] = []
        let apps = highlight.appNames.joined(separator: ", ")
        parts.append(apps)
        if let dur = durationText { parts.append(dur) }
        parts.append(timeRange)
        return parts.joined(separator: "  ·  ")
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if isMeeting {
                Image(systemName: "video.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(accentColor)
                    .frame(width: 28, height: 28)
            } else {
                JournalAppIconBadgeView(
                    bundleId: highlight.primaryBundleId,
                    tint: accentColor,
                    size: 28,
                    fallbackDotSize: 8
                )
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(highlight.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let detail = highlight.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Text(metaLine)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Task List

struct JournalTaskListView: View {
    let blocks: [JournalBlock]
    @Binding var expandedBlockIDs: Set<UUID>

    private var dayCountLabel: String {
        let meetings = blocks.filter { $0.isMeeting == true }.count
        let tasks = blocks.count - meetings
        var parts: [String] = []
        if tasks > 0 { parts.append("\(tasks) \(tasks == 1 ? "task" : "tasks")") }
        if meetings > 0 { parts.append("\(meetings) \(meetings == 1 ? "meeting" : "meetings")") }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                JournalSectionHeader(title: "YOUR DAY")

                Spacer(minLength: 12)

                Text(dayCountLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

            VStack(spacing: 0) {
                ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                    JournalTaskRow(
                        block: block,
                        summary: JournalReviewEngine.cleanedSummary(for: block),
                        isExpanded: expandedBlockIDs.contains(block.id),
                        onToggle: {
                            if expandedBlockIDs.contains(block.id) {
                                expandedBlockIDs.remove(block.id)
                            } else {
                                expandedBlockIDs.insert(block.id)
                            }
                        }
                    )

                    if index < blocks.count - 1 {
                        Divider()
                            .padding(.leading, 58)
                    }
                }
            }
            .padding(6)
            .journalCard(cornerRadius: 16)
        }
    }
}

struct JournalTaskRow: View {
    let block: JournalBlock
    let summary: String?
    let isExpanded: Bool
    let onToggle: () -> Void

    @State private var isHovered = false

    private var isMeeting: Bool { block.isMeeting == true }

    private var accentColor: Color {
        JournalPalette.color(for: block)
    }

    private var taskTitle: String {
        JournalReviewEngine.taskTitle(for: block)
    }

    private var timeRange: String {
        "\(JournalDateFormatters.time(block.startTime)) – \(JournalDateFormatters.time(block.endTime))"
    }

    private var durationText: String? {
        if isMeeting, let secs = block.meetingDurationSeconds, secs >= 60 {
            return JournalDateFormatters.duration(secs)
        }
        let duration = max(block.endTime.timeIntervalSince(block.startTime), 0)
        guard duration >= 60 else { return nil }
        return JournalDateFormatters.duration(duration)
    }

    private var appPillLabel: String {
        if isMeeting { return block.meetingApp ?? "Meeting" }
        guard let apps = block.appsUsed, apps.count > 1 else { return block.appName }
        return apps.map(\.appName).joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main row
            HStack(alignment: .center, spacing: 10) {
                // Time
                Text(JournalDateFormatters.time(block.startTime))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .fixedSize()
                    .frame(minWidth: 40, alignment: .trailing)

                // Icon: video camera for meetings, app icon for dictations
                if isMeeting {
                    Image(systemName: "video.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(accentColor)
                        .frame(width: 26, height: 26)
                } else {
                    JournalAppIconBadgeView(
                        bundleId: block.bundleId,
                        tint: accentColor,
                        size: 26,
                        fallbackDotSize: 7
                    )
                }

                // Content
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(taskTitle)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if isMeeting, let app = block.meetingApp {
                            Text(app)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 0)

                        if let durationText {
                            Text(durationText)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                        }

                        if !block.entries.isEmpty {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.quaternary)
                                .rotationEffect(.degrees(isExpanded ? 180 : 0))
                                .animation(.spring(response: 0.42, dampingFraction: 0.8), value: isExpanded)
                        }
                    }

                    if let summary, !isExpanded {
                        Text(summary)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isHovered ? SettingsPalette.accentFill.opacity(0.5) : .clear)
            )
            .animation(.easeInOut(duration: 0.18), value: isHovered)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onTapGesture {
                guard !block.entries.isEmpty else { return }
                onToggle()
            }
            .onHover { isHovered = $0 }

            // Expanded entries
            if isExpanded, !block.entries.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(block.entries.enumerated()), id: \.offset) { index, entry in
                        VStack(alignment: .leading, spacing: 4) {
                            if block.entries.count > 1 {
                                Text("Entry \(index + 1)")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                                    .textCase(.uppercase)
                                    .tracking(0.3)
                            }

                            SelectableTextBlock(
                                text: entry,
                                font: .systemFont(ofSize: 12.5),
                                lineSpacing: 4
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 8)

                        if index < block.entries.count - 1 {
                            Divider()
                                .opacity(0.4)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 999, style: .continuous)
                        .fill(accentColor.opacity(0.7))
                        .frame(width: 2.5)
                }
                .padding(.leading, 58)
            }
        }
    }
}

// MARK: - App Breakdown (removed — merged into JournalHighlightsView)

struct JournalAppIconBadgeView: View {
    let bundleId: String
    let tint: Color
    var size: CGFloat = 20
    var fallbackDotSize: CGFloat = 7

    var body: some View {
        if let image = JournalAppIconResolver.icon(for: bundleId) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: max(size * 0.24, 4), style: .continuous))
                .frame(width: size, height: size)
        } else {
            Circle()
                .fill(tint)
                .frame(width: fallbackDotSize, height: fallbackDotSize)
                .frame(width: size, height: size)
        }
    }
}

struct JournalInlineMessageView: View {
    let message: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)

            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(tint.opacity(0.08))
        )
    }
}

struct JournalSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.7)
    }
}

struct JournalCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 22
    var elevation: ResonantElevation = .resting

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        content
            .background(shape.fill(SettingsPalette.cardGradient))
            .overlay(shape.stroke(SettingsPalette.border, lineWidth: 0.5))
            .resonantShadow(elevation)
    }
}

extension View {
    func journalCard(
        cornerRadius: CGFloat = 22,
        elevation: ResonantElevation = .resting
    ) -> some View {
        modifier(JournalCardModifier(
            cornerRadius: cornerRadius,
            elevation: elevation
        ))
    }
}

struct JournalTakeawaysView: View {
    let dayData: DayData
    let blocks: [JournalBlock]

    private struct ModelTakeaways {
        let lede: String?
        let remembered: [String]
        let commitments: [String]
        let pattern: String?

        var hasContent: Bool {
            lede != nil || !remembered.isEmpty || !commitments.isEmpty || pattern != nil
        }
    }

    private var highlights: [JournalAccomplishment] {
        JournalReviewEngine.accomplishmentHighlights(from: blocks, limit: 3)
    }

    private var followUps: [DayCommitment] {
        let priority: [DayCommitment.Kind] = [.commitment, .decision, .question]
        return dayData.commitments
            .sorted { lhs, rhs in
                let lhsRank = priority.firstIndex(of: lhs.kind) ?? priority.count
                let rhsRank = priority.firstIndex(of: rhs.kind) ?? priority.count
                if lhsRank == rhsRank { return lhs.time < rhs.time }
                return lhsRank < rhsRank
            }
            .prefix(3)
            .map { $0 }
    }

    private var modelTakeaways: ModelTakeaways {
        guard let brief = dayData.day?.narrativeBrief?.trimmingCharacters(in: .whitespacesAndNewlines),
              !brief.isEmpty else {
            return ModelTakeaways(lede: nil, remembered: [], commitments: [], pattern: nil)
        }

        let sections = BriefSection.parse(brief)

        func texts(in kind: BriefSection.Kind) -> [String] {
            sections
                .filter { $0.kind == kind }
                .flatMap(\.blocks)
                .compactMap { block -> String? in
                    switch block {
                    case .paragraph(let text), .bullet(let text), .heading(_, let text):
                        return cleanMarkdown(text)
                    }
                }
                .filter { text in
                    !text.isEmpty && text != "— Nothing committed today."
                }
        }

        return ModelTakeaways(
            lede: texts(in: .lede).first,
            remembered: Array(texts(in: .whatHappened).prefix(4)),
            commitments: Array(texts(in: .commitments).prefix(3)),
            pattern: texts(in: .pattern).first
        )
    }

    private var usesModelTakeaways: Bool {
        modelTakeaways.hasContent
    }

    private var dayLabel: String {
        if let lede = modelTakeaways.lede {
            return lede
        }
        return DayReviewEngine.characterization(for: dayData.shape)
    }

    private var primaryTakeaway: String {
        if let first = modelTakeaways.remembered.first {
            return first
        }

        if let first = highlights.first {
            if let detail = first.detail, !detail.isEmpty {
                return detail
            }
            return "The main thread was \(first.title)."
        }

        let shape = dayData.shape
        if let topApp = shape.slices.first {
            return "\(topApp.appName) carried most of the captured work, with \(formatMinutes(topApp.minutes)) in focus."
        }

        return "There is not enough captured activity yet to form a useful takeaway."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    JournalSectionHeader(title: "TAKEAWAY")
                    Text(usesModelTakeaways ? "Model-generated" : "Estimated")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                }

                Text(dayLabel)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(primaryTakeaway)
                    .font(.system(size: 14.5, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)

                JournalTakeawayMetrics(shape: dayData.shape)
                    .padding(.top, 2)
            }

            Divider().opacity(0.45)

            VStack(alignment: .leading, spacing: 12) {
                Text("What To Remember")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)

                if !modelTakeaways.remembered.isEmpty {
                    ForEach(Array(modelTakeaways.remembered.enumerated()), id: \.offset) { _, text in
                        JournalModelTakeawayRow(text: text, systemImage: "sparkle")
                    }
                } else if highlights.isEmpty {
                    JournalEmptyTakeawayLine(text: "Capture more dictation or meetings and the journal will surface the useful threads here.")
                } else {
                    ForEach(highlights) { highlight in
                        JournalTakeawayHighlightRow(highlight: highlight)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("What To Do Next")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)

                if !modelTakeaways.commitments.isEmpty {
                    ForEach(Array(modelTakeaways.commitments.enumerated()), id: \.offset) { _, text in
                        JournalModelTakeawayRow(text: text, systemImage: "checkmark.circle")
                    }
                } else if followUps.isEmpty {
                    JournalEmptyTakeawayLine(text: "No clear commitment or decision was detected for this day.")
                } else {
                    ForEach(followUps) { item in
                        JournalFollowUpRow(item: item)
                    }
                }
            }

            if let pattern = modelTakeaways.pattern {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pattern")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)

                    JournalModelTakeawayRow(text: pattern, systemImage: "waveform.path.ecg")
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .journalCard(cornerRadius: 16)
    }

    private func cleanMarkdown(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"[*_`]+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \n\t-"))
    }

    private func formatMinutes(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder > 0 ? "\(hours)h \(remainder)m" : "\(hours)h"
    }
}

private struct JournalModelTakeawayRow: View {
    let text: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SettingsPalette.infoText)
                .frame(width: 22, height: 22)
                .padding(.top, 1)

            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(.primary.opacity(0.9))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            Spacer(minLength: 0)
        }
    }
}

struct JournalBriefSynthesisView: View {
    let dayData: DayData
    let onRegenerate: () -> Void

    private var brief: String? {
        guard let trimmed = dayData.day?.narrativeBrief?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                JournalSectionHeader(title: "DAILY MEMO")
                Spacer(minLength: 12)
                Button(action: onRegenerate) {
                    Label(brief == nil ? "Generate" : "Refresh", systemImage: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if let brief {
                BriefView(brief: brief, mentions: dayData.mentions)
            } else {
                Text("Generating a concise memo from the day’s captured work.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .journalCard(cornerRadius: 16)
    }
}

struct JournalEvidenceView: View {
    let day: JournalDay?
    let blocks: [JournalBlock]
    @Binding var isExpanded: Bool
    @Binding var expandedBlockIDs: Set<UUID>

    private var highlights: [JournalAccomplishment] {
        JournalReviewEngine.accomplishmentHighlights(from: blocks, limit: 3)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                JournalSectionHeader(title: "EVIDENCE")
                Spacer(minLength: 12)
                Text("\(blocks.count) \(blocks.count == 1 ? "source" : "sources")")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

            VStack(alignment: .leading, spacing: 6) {
                JournalDayTimelineView(blocks: blocks)
                JournalStatsStripView(day: day, blocks: blocks)
            }

            if !highlights.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Source moments")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)

                    ForEach(highlights) { highlight in
                        JournalTakeawayHighlightRow(highlight: highlight)
                    }
                }
            }

            DisclosureGroup(isExpanded: $isExpanded) {
                JournalTaskListView(
                    blocks: blocks,
                    expandedBlockIDs: $expandedBlockIDs
                )
                .padding(.top, 10)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)

                    Text("Show full activity")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .journalCard(cornerRadius: 16)
    }
}

private struct JournalTakeawayMetrics: View {
    let shape: DayShape

    var body: some View {
        HStack(spacing: 8) {
            metric("\(shape.sessionCount)", shape.sessionCount == 1 ? "session" : "sessions")
            if shape.meetingCount > 0 {
                metric("\(shape.meetingCount)", shape.meetingCount == 1 ? "meeting" : "meetings")
            }
            if shape.totalWords > 0 {
                metric(shape.totalWords.formatted(), "words")
            }
            if shape.totalMinutes > 0 {
                metric(formatMinutes(shape.totalMinutes), "captured")
            }
        }
    }

    private func metric(_ value: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(SettingsPalette.mutedCardBackground)
        )
    }

    private func formatMinutes(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder > 0 ? "\(hours)h \(remainder)m" : "\(hours)h"
    }
}

private struct JournalTakeawayHighlightRow: View {
    let highlight: JournalAccomplishment

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            JournalAppIconBadgeView(
                bundleId: highlight.primaryBundleId,
                tint: JournalPalette.colorForBundleId(highlight.primaryBundleId),
                size: 22,
                fallbackDotSize: 7
            )
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(highlight.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let detail = highlight.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("\(JournalDateFormatters.time(highlight.startTime)) – \(JournalDateFormatters.time(highlight.endTime))")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

            Spacer(minLength: 0)
        }
    }
}

private struct JournalFollowUpRow: View {
    let item: DayCommitment

    private var symbol: String {
        switch item.kind {
        case .commitment: return "checkmark.circle"
        case .decision:   return "arrow.triangle.branch"
        case .question:   return "questionmark.circle"
        }
    }

    private var tint: Color {
        switch item.kind {
        case .commitment: return SettingsPalette.semanticBlue
        case .decision:   return SettingsPalette.semanticGreen
        case .question:   return SettingsPalette.semanticAmber
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.primary.opacity(0.9))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)

                Text("\(item.appName) · \(JournalDateFormatters.time(item.time))")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

            Spacer(minLength: 0)
        }
    }
}

private struct JournalEmptyTakeawayLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct JournalAskPanel: View {
    @Binding var question: String
    let isAsking: Bool
    let answer: String
    let error: String?
    let onSubmit: () -> Void
    let onPrompt: (String) -> Void

    private let prompts = [
        "What mattered most today?",
        "What should I follow up on?",
        "Draft a short journal entry"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SettingsPalette.infoText)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(SettingsPalette.infoFill))

                VStack(alignment: .leading, spacing: 7) {
                    Text("Ask About This Day")
                        .font(.system(size: 13, weight: .semibold))

                    Text("Use the journal as a personal retrieval surface: summarize, reflect, or pull out next steps.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                TextField("Ask about your day…", text: $question)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(SettingsPalette.elevatedBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(SettingsPalette.border.opacity(0.22), lineWidth: 1)
                    )
                    .onSubmit(onSubmit)

                Button(action: onSubmit) {
                    if isAsking {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 11, weight: .bold))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(SettingsPalette.infoText))
                .disabled(isAsking || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Ask")
            }

            HStack(spacing: 6) {
                ForEach(prompts, id: \.self) { prompt in
                    Button {
                        onPrompt(prompt)
                    } label: {
                        Text(prompt)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(SettingsPalette.cardBackground)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(isAsking)
                }
            }

            if !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                SelectableTextBlock(
                    text: answer,
                    font: .systemFont(ofSize: 12.5),
                    lineSpacing: 4
                )
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(SettingsPalette.elevatedBackground)
                )
            } else if isAsking {
                Text("Thinking…")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.tertiary)
            }

            if let error, !error.isEmpty {
                JournalInlineMessageView(
                    message: error,
                    systemImage: "exclamationmark.triangle.fill",
                    tint: SettingsPalette.semanticRed
                )
            }
        }
        .padding(14)
        .journalCard(cornerRadius: 14)
    }
}

struct JournalTimelineLayout {
    struct Segment: Identifiable {
        let id: UUID
        let x: CGFloat
        let width: CGFloat
        let color: Color
        let bundleId: String?
        let duration: TimeInterval
        let isMeeting: Bool
    }

    struct HourMark: Identifiable {
        let id: Int
        let x: CGFloat
        let label: String
    }

    let segments: [Segment]
    let hourMarks: [HourMark]

    /// Merges blocks into consolidated app-level bands so the timeline stays clean
    /// even with 50+ raw sessions.
    init(blocks: [JournalBlock], width: CGFloat) {
        guard
            let first = blocks.first?.startTime,
            let last = blocks.last?.endTime,
            width > 0
        else {
            segments = []
            hourMarks = []
            return
        }

        let totalDuration = max(last.timeIntervalSince(first), 60)
        let usable = width - 2 // 1px padding each side

        // Merge adjacent blocks that share the same primary bundleId
        struct MergedBand {
            var bundleId: String
            var startTime: Date
            var endTime: Date
            var color: Color
            var isMeeting: Bool
        }

        var bands: [MergedBand] = []
        for block in blocks {
            let isMeeting = block.isMeeting == true
            let key = block.bundleId.journalTrimmed ?? block.appName
            // Never merge meetings with non-meetings; only merge same-type same-app
            if let last = bands.last, last.bundleId == key,
               last.isMeeting == isMeeting,
               block.startTime.timeIntervalSince(last.endTime) < 10 * 60 {
                bands[bands.count - 1].endTime = block.endTime
            } else {
                bands.append(MergedBand(
                    bundleId: key,
                    startTime: block.startTime,
                    endTime: block.endTime,
                    color: JournalPalette.color(for: block),
                    isMeeting: isMeeting
                ))
            }
        }

        segments = bands.map { band in
            let startOffset = max(band.startTime.timeIntervalSince(first), 0)
            let duration = max(band.endTime.timeIntervalSince(band.startTime), 30)
            let x = (startOffset / totalDuration) * usable + 1
            let w = min((duration / totalDuration) * usable, usable - x + 1)

            return Segment(
                id: UUID(),
                x: x,
                width: max(w, 3),
                color: band.color,
                bundleId: band.bundleId,
                duration: duration,
                isMeeting: band.isMeeting
            )
        }

        // Compute hour marks
        let cal = Calendar.current
        let startComps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: first)
        let endComps = cal.dateComponents([.year, .month, .day, .hour], from: last)

        var firstMarkHour = startComps.hour ?? 0
        if (startComps.minute ?? 0) > 0 { firstMarkHour += 1 }
        let lastMarkHour = endComps.hour ?? 23

        guard firstMarkHour <= lastMarkHour else {
            hourMarks = []
            return
        }

        var marks: [HourMark] = []

        for hour in firstMarkHour ... lastMarkHour {
            var comps = startComps
            comps.hour = hour
            comps.minute = 0
            comps.second = 0

            guard let hourDate = cal.date(from: comps) else { continue }

            let offset = hourDate.timeIntervalSince(first)
            guard offset >= 0, offset <= totalDuration else { continue }

            let x = (offset / totalDuration) * width
            guard x >= 12, x <= width - 12 else { continue }

            let isAM = hour < 12
            let displayHour = hour % 12 == 0 ? 12 : hour % 12
            let periodChanged = marks.last.map { ($0.id < 12) != isAM } ?? true
            let label = periodChanged ? "\(displayHour)\(isAM ? "a" : "p")" : "\(displayHour)"

            marks.append(HourMark(id: hour, x: x, label: label))
        }

        hourMarks = marks
    }
}

// MARK: - Activity Path Sidebar

struct JournalActivitySidebar: View {
    let days: [JournalDay]
    @Binding var selectedDate: Date

    private typealias MonthGroup = (key: String, days: [JournalDay])

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM yyyy"
        return f
    }()

    @State private var cachedMaxWordCount: Int = 1
    @State private var cachedMonthGroups: [MonthGroup] = []

    private var selectedDay: JournalDay? {
        // days is already sorted descending; linear scan over <=30 items
        days.first { Calendar.current.isDate($0.date, inSameDayAs: selectedDate) }
    }

    var body: some View {
        SettingsPrimaryCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Activity")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)

                    if let day = selectedDay {
                        let totalWords = day.blocks.reduce(0) { $0 + $1.wordCount }
                        let uniqueApps = Set(day.blocks.flatMap { block in
                            block.appsUsed?.map(\.bundleId) ?? [block.bundleId]
                        }).count
                        HStack(spacing: 8) {
                            Label("\(day.blocks.count)", systemImage: "text.bubble")
                            Label("\(totalWords.formatted())", systemImage: "character.cursor.ibeam")
                            Label("\(uniqueApps)", systemImage: "app.badge")
                        }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    } else {
                        Text("Select a day")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 10)

                Divider()
                    .padding(.horizontal, 12)

                JournalSignalsStrip(days: days)

                if days.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "chart.dots.scatter")
                            .font(.system(size: 20, weight: .light))
                            .foregroundStyle(.quaternary)

                        Text("No activity yet")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.vertical, 40)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(cachedMonthGroups, id: \.key) { group in
                                Text(group.key)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.quaternary)
                                    .tracking(0.5)
                                    .padding(.horizontal, 14)
                                    .padding(.top, group.key == cachedMonthGroups.first?.key ? 10 : 18)
                                    .padding(.bottom, 4)

                                ForEach(group.days, id: \.id) { day in
                                    let dayStart = Calendar.current.startOfDay(for: day.date)
                                    JournalActivityDayRow(
                                        day: day,
                                        isSelected: Calendar.current.isDate(dayStart, inSameDayAs: selectedDate),
                                        maxWordCount: cachedMaxWordCount
                                    )
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        selectedDate = dayStart
                                    }
                                }
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
        .onAppear { rebuildCache() }
        .onChange(of: days.count) { _, _ in rebuildCache() }
    }

    private func rebuildCache() {
        // days is already sorted descending by JournalManager
        cachedMaxWordCount = days.map { $0.blocks.reduce(0) { $0 + $1.wordCount } }.max() ?? 1
        let grouped = Dictionary(grouping: days) { Self.monthFormatter.string(from: $0.date).uppercased() }
        cachedMonthGroups = grouped
            .sorted { ($0.value.first?.date ?? .distantPast) > ($1.value.first?.date ?? .distantPast) }
            .map { MonthGroup(key: $0.key, days: $0.value) }
    }
}

struct JournalActivityDayRow: View {
    let day: JournalDay
    let isSelected: Bool
    var maxWordCount: Int = 1

    @State private var isHovered = false

    private static let calendar = Calendar.current

    private var dateLabel: String {
        if Self.calendar.isDateInToday(day.date) {
            return "Today"
        }
        if Self.calendar.isDateInYesterday(day.date) {
            return "Yest."
        }
        return day.date.formatted(.dateTime.weekday(.abbreviated).day())
    }

    private var sortedBlocks: [JournalBlock] {
        day.blocks.sorted { $0.startTime < $1.startTime }
    }

    private var totalWords: Int {
        day.blocks.reduce(0) { $0 + $1.wordCount }
    }

    private var barFraction: CGFloat {
        guard maxWordCount > 0 else { return 0 }
        return CGFloat(totalWords) / CGFloat(maxWordCount)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(dateLabel)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(width: 40, alignment: .trailing)
                .lineLimit(1)

            // Mini activity bar showing relative volume
            GeometryReader { geo in
                let barWidth = geo.size.width * barFraction
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(SettingsPalette.timelineTrack)

                    // Segmented bar by app — positioned to avoid overflow
                    let offsets = sidebarBarOffsets(blocks: sortedBlocks, totalWords: totalWords, barWidth: barWidth)
                    ForEach(Array(zip(sortedBlocks, offsets)), id: \.0.id) { block, seg in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(JournalPalette.color(for: block))
                            .frame(width: max(seg.width, 1))
                            .offset(x: seg.x)
                    }
                }
            }
            .frame(height: 6)

            Text("\(totalWords.formatted())")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 34, alignment: .trailing)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? SettingsPalette.accentFill : (isHovered ? SettingsPalette.elevatedBackground : .clear))
        )
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(SettingsPalette.accentBorder, lineWidth: 1)
            }
        }
        .padding(.horizontal, 6)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.14)) {
                isHovered = hovering
            }
        }
    }

    private func sidebarBarOffsets(blocks: [JournalBlock], totalWords: Int, barWidth: CGFloat) -> [(x: CGFloat, width: CGFloat)] {
        guard totalWords > 0, barWidth > 0 else {
            return blocks.map { _ in (x: CGFloat(0), width: CGFloat(0)) }
        }
        var x: CGFloat = 0
        return blocks.map { block in
            let fraction = CGFloat(block.wordCount) / CGFloat(totalWords)
            let w = fraction * barWidth
            let result = (x: x, width: w)
            x += w
            return result
        }
    }
}


// MARK: - Signals strip (sidebar ambient insights)

struct JournalSignalsStrip: View {
    let days: [JournalDay]

    private var signals: [JournalSignal] {
        JournalSignalEngine.signals(from: days)
    }

    var body: some View {
        let items = Array(signals.prefix(5))
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(items) { signal in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: signal.icon)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 14, alignment: .center)
                            .padding(.top, 2)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(signal.title)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)

                            if let detail = signal.detail, !detail.isEmpty {
                                Text(detail)
                                    .font(.system(size: 10, weight: .regular))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                }
            }
            .padding(.vertical, 6)

            Divider()
                .padding(.horizontal, 12)
        }
    }
}

enum JournalPalette {
    private static let colors: [Color] = [
        SettingsPalette.semanticBlue,
        SettingsPalette.semanticGreen,
        SettingsPalette.semanticAmber,
        Color(red: 0.78, green: 0.64, blue: 0.22),
        Color(red: 0.15, green: 0.65, blue: 0.69),
        Color(red: 0.83, green: 0.35, blue: 0.39)
    ]

    static let meetingColor = Color(red: 0.18, green: 0.58, blue: 0.72)

    static func colorForBundleId(_ bundleId: String) -> Color {
        let hash = bundleId.unicodeScalars.reduce(0) { partialResult, scalar in
            (partialResult &* 31) &+ Int(scalar.value)
        }
        let index = abs(hash) % colors.count
        return colors[index]
    }

    static func color(for block: JournalBlock) -> Color {
        if block.isMeeting == true { return meetingColor }
        let key = block.bundleId.journalTrimmed ?? block.appName
        return colorForBundleId(key)
    }
}

enum JournalAppIconResolver {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(for bundleId: String) -> NSImage? {
        guard let bundleId = bundleId.journalTrimmed else { return nil }

        if let cached = cache.object(forKey: bundleId as NSString) {
            return cached
        }

        let icon: NSImage
        if bundleId == Bundle.main.bundleIdentifier, let appIcon = NSApp.applicationIconImage {
            icon = appIcon
        } else if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            icon = NSWorkspace.shared.icon(forFile: appURL.path)
        } else {
            return nil
        }

        cache.setObject(icon, forKey: bundleId as NSString)
        return icon
    }
}

enum JournalDateFormatters {
    private static let calendar = Calendar.current

    static func title(for date: Date) -> String {
        if calendar.isDateInToday(date) {
            return "Today"
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday"
        }
        return date.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }

    static func subtitle(for date: Date) -> String? {
        guard calendar.isDateInToday(date) || calendar.isDateInYesterday(date) else { return nil }
        return date.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func duration(_ duration: TimeInterval) -> String {
        let minutes = max(Int(duration / 60), 1)
        if minutes < 60 {
            return "\(minutes)m"
        }

        let hours = minutes / 60
        let remainder = minutes % 60
        if remainder == 0 {
            return "\(hours)h"
        }
        return "\(hours)h \(remainder)m"
    }
}

extension Optional where Wrapped == String {
    var journalTrimmed: String? {
        self?.journalTrimmed
    }
}

extension String {
    var journalTrimmed: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
