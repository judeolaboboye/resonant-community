import SwiftUI

struct JournalPageRedesignView: View {
    let selectedDate: Date
    let day: JournalDay?
    let dayData: DayData
    let sortedBlocks: [JournalBlock]
    let isToday: Bool
    let isGenerating: Bool
    let isAskingQuestion: Bool
    let questionAnswer: String
    let questionError: String?
    let errorMessage: String?

    @Binding var expandedBlockIDs: Set<UUID>
    @Binding var isEvidenceExpanded: Bool
    @Binding var journalQuestion: String

    var onPrevious: () -> Void
    var onNext: () -> Void
    var onRefresh: () -> Void
    var onHowItWorks: (() -> Void)?
    var onSubmitQuestion: () -> Void
    var onPromptTap: (String) -> Void
    var onUseClassic: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                dateHeader

                if let errorMessage {
                    JournalInlineMessageView(
                        message: errorMessage,
                        systemImage: "exclamationmark.triangle.fill",
                        tint: SettingsPalette.semanticRed
                    )
                }

                if sortedBlocks.isEmpty {
                    emptyCard
                } else {
                    todayCard
                    timeShapeCard
                    highlightsCard
                    if !dayData.commitments.isEmpty {
                        commitmentsCard
                    }
                    if !meetingBlocks.isEmpty {
                        meetingsCard
                    }
                    activityCard
                }

                // askCard — chat hidden for now

                if let onUseClassic {
                    HStack {
                        Spacer()
                        Button(action: onUseClassic) {
                            Text("Use classic layout")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - Header

    private var dateHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if let subtitle = JournalDateFormatters.subtitle(for: selectedDate) {
                    Text(subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                Text(JournalDateFormatters.title(for: selectedDate))
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .tracking(-0.2)
            }

            Spacer(minLength: 12)

            HStack(spacing: 4) {
                if let onHowItWorks {
                    JournalHeaderButton(systemImage: "questionmark.circle", action: onHowItWorks)
                }
                JournalHeaderButton(systemImage: "chevron.left", action: onPrevious)
                JournalHeaderButton(systemImage: "chevron.right", action: onNext).disabled(isToday)
                JournalHeaderButton(systemImage: "arrow.clockwise", action: onRefresh) {
                    if isGenerating { ProgressView().controlSize(.small) }
                }
                .disabled(isGenerating)
            }
        }
    }

    // MARK: - Card: Today

    private var todayCard: some View {
        Card(header: "TODAY") {
            VStack(alignment: .leading, spacing: 12) {
                if let ledeText {
                    Text(ledeText)
                        .font(.system(size: 14))
                        .foregroundStyle(.primary.opacity(0.86))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    if let chip = characterChip {
                        Tag(text: chip, tint: categoryTint)
                    }
                    Text(shortShape)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    private var ledeText: String? {
        guard let brief = dayData.day?.narrativeBrief?.trimmingCharacters(in: .whitespacesAndNewlines),
              !brief.isEmpty else {
            return DayReviewEngine.characterization(for: dayData.shape)
        }
        let sections = BriefSection.parse(brief)
        let lede = sections.first { $0.kind == .lede } ?? sections.first
        let firstParagraph = lede?.blocks.compactMap { block -> String? in
            switch block {
            case .paragraph(let text), .heading(_, let text):
                return cleanInline(text)
            case .bullet:
                return nil
            }
        }.first { !$0.isEmpty }
        return firstParagraph ?? DayReviewEngine.characterization(for: dayData.shape)
    }

    private var characterChip: String? {
        switch DayReviewEngine.dominantCategoryKey(for: dayData.shape) {
        case "meetings": return "Meeting-heavy"
        case "code":     return "Builder"
        case "comms":    return "Comms"
        case "writing":  return "Writing"
        case "other":    return dayData.shape.totalMinutes > 0 ? "Mixed" : nil
        default:         return nil
        }
    }

    private var categoryTint: Color {
        switch DayReviewEngine.dominantCategoryKey(for: dayData.shape) {
        case "code":     return Color(red: 0.22, green: 0.58, blue: 0.52)
        case "comms":    return Color(red: 0.90, green: 0.60, blue: 0.22)
        case "meetings": return Color(red: 0.92, green: 0.45, blue: 0.36)
        case "writing":  return Color(red: 0.66, green: 0.52, blue: 0.32)
        default:         return Color(red: 0.34, green: 0.54, blue: 0.86)
        }
    }

    private var shortShape: String {
        let shape = dayData.shape
        var parts: [String] = []
        if shape.sessionCount > 0 {
            parts.append("\(shape.sessionCount) \(shape.sessionCount == 1 ? "session" : "sessions")")
        }
        if shape.meetingCount > 0 {
            parts.append("\(shape.meetingCount) \(shape.meetingCount == 1 ? "meeting" : "meetings")")
        }
        let h = shape.totalMinutes / 60
        let m = shape.totalMinutes % 60
        if shape.totalMinutes > 0 {
            parts.append(h > 0 ? "\(h)h \(m)m" : "\(m)m")
        }
        return parts.joined(separator: "  \u{00B7}  ")
    }

    private func cleanInline(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\*\*(.*?)\*\*"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\*(.*?)\*"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"_(.*?)_"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " \n\t-#"))
    }

    // MARK: - Card: Time shape

    private var timeShapeCard: some View {
        Card(header: "TIME SHAPE") {
            VStack(alignment: .leading, spacing: 10) {
                JournalDayTimelineView(blocks: sortedBlocks)

                if !appBreakdownText.isEmpty {
                    Text(appBreakdownText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(2)
                }
            }
        }
    }

    private var appBreakdownText: String {
        dayData.shape.slices.prefix(4).map { slice in
            "\(slice.appName) \(slice.minutes)m"
        }.joined(separator: "  \u{00B7}  ")
    }

    // MARK: - Card: Highlights

    private var highlightsCard: some View {
        let highlights = JournalReviewEngine.accomplishmentHighlights(from: sortedBlocks)
        let meetingIDs = Set(meetingBlocks.map(\.id))

        return Group {
            if !highlights.isEmpty {
                Card(header: "WHAT GOT DONE") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(highlights.prefix(4).enumerated()), id: \.element.id) { index, highlight in
                            HighlightRow(highlight: highlight, isMeeting: meetingIDs.contains(highlight.id))
                            if index < min(highlights.count, 4) - 1 {
                                Divider().opacity(0.4)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Card: Commitments

    private var commitmentsCard: some View {
        Card(header: commitmentsHeader) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(dayData.commitments.prefix(6)) { c in
                    CommitmentRow(commitment: c)
                }
            }
        }
    }

    private var commitmentsHeader: String {
        let hasDecision = dayData.commitments.contains { $0.kind == .decision }
        return hasDecision ? "DECISIONS & COMMITMENTS" : "COMMITMENTS"
    }

    // MARK: - Card: Meetings

    private var meetingBlocks: [JournalBlock] {
        sortedBlocks.filter { $0.isMeeting == true }
    }

    private var meetingsCard: some View {
        Card(header: meetingBlocks.count == 1 ? "MEETING" : "MEETINGS") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(meetingBlocks.enumerated()), id: \.element.id) { index, block in
                    MeetingRow(block: block)
                    if index < meetingBlocks.count - 1 {
                        Divider().opacity(0.4)
                    }
                }
            }
        }
    }

    // MARK: - Card: Activity (hour-by-hour, collapsible)

    private var activityCard: some View {
        Card(header: "ACTIVITY") {
            ActivityTimeline(
                blocks: sortedBlocks,
                commitments: dayData.commitments,
                captures: dayData.captures
            )
        }
    }

    // MARK: - Card: Ask

    private var askCard: some View {
        Card(header: "ASK ANYTHING") {
            VStack(alignment: .leading, spacing: 12) {
                if !questionAnswer.isEmpty || questionError != nil || isAskingQuestion {
                    answerView
                }

                HStack(spacing: 10) {
                    TextField("Ask about today\u{2026}", text: $journalQuestion)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .disabled(isAskingQuestion)
                        .onSubmit(onSubmitQuestion)

                    if isAskingQuestion {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(action: onSubmitQuestion) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 17))
                                .foregroundStyle(journalQuestion.trimmingCharacters(in: .whitespaces).isEmpty ? Color.secondary.opacity(0.45) : SettingsPalette.infoText)
                        }
                        .buttonStyle(.plain)
                        .disabled(journalQuestion.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(SettingsPalette.mutedCardBackground)
                )
            }
        }
    }

    @ViewBuilder
    private var answerView: some View {
        if let error = questionError {
            Text(error)
                .font(.system(size: 12.5))
                .foregroundStyle(SettingsPalette.semanticRed)
                .fixedSize(horizontal: false, vertical: true)
        } else if isAskingQuestion && questionAnswer.isEmpty {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Thinking\u{2026}")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        } else if !questionAnswer.isEmpty {
            Text(questionAnswer)
                .font(.system(size: 13))
                .foregroundStyle(.primary.opacity(0.85))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Empty

    private var emptyCard: some View {
        Card(header: isToday ? "TODAY" : "NOTHING CAPTURED") {
            VStack(alignment: .leading, spacing: 6) {
                Text(isToday ? "No journal yet" : "No activity on this day")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Text(isToday
                     ? "Start dictating or join a meeting and your day will fill in here."
                     : "Move to another day or regenerate if you expect captured activity.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Card primitive

private struct Card<Content: View>: View {
    let header: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(header)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.7)

            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .journalCard(cornerRadius: 12)
    }
}

// MARK: - Tag

private struct Tag: View {
    let text: String
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 5, height: 5)
            Text(text)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(tint)
                .tracking(0.3)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(tint.opacity(0.10))
        )
        .overlay(
            Capsule().stroke(tint.opacity(0.20), lineWidth: 1)
        )
    }
}

// MARK: - Highlight row (fresh — not legacy)

private struct HighlightRow: View {
    let highlight: JournalAccomplishment
    let isMeeting: Bool

    private var accent: Color {
        isMeeting ? JournalPalette.meetingColor : JournalPalette.colorForBundleId(highlight.primaryBundleId)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(accent.opacity(0.12))
                    .frame(width: 32, height: 32)
                JournalAppIconBadgeView(
                    bundleId: highlight.primaryBundleId,
                    tint: accent,
                    size: 16,
                    fallbackDotSize: 5
                )
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(highlight.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                if let detail = highlight.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 6) {
                    Text(timeRange)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                    if let dur = duration {
                        Text("\u{00B7}").foregroundStyle(.quaternary)
                        Text(dur)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
                .padding(.top, 1)
            }

            Spacer(minLength: 0)
        }
    }

    private var timeRange: String {
        "\(JournalDateFormatters.time(highlight.startTime))\u{2013}\(JournalDateFormatters.time(highlight.endTime))"
    }

    private var duration: String? {
        guard highlight.duration >= 60 else { return nil }
        return JournalDateFormatters.duration(highlight.duration)
    }
}

// MARK: - Commitment row

private struct CommitmentRow: View {
    let commitment: DayCommitment

    private var accent: Color {
        JournalPalette.colorForBundleId(commitment.bundleId)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 18, height: 18)
                .background(
                    Circle().fill(accent.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(commitment.text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.primary.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(JournalDateFormatters.time(commitment.time))  \u{00B7}  \(commitment.appName)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

            Spacer(minLength: 0)
        }
    }

    private var icon: String {
        switch commitment.kind {
        case .commitment: return "arrow.right"
        case .decision:   return "checkmark"
        case .question:   return "questionmark"
        }
    }
}

// MARK: - Meeting row

private struct MeetingRow: View {
    let block: JournalBlock

    private var accent: Color {
        JournalPalette.meetingColor
    }

    private var title: String {
        block.meetingTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? block.accomplishment?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? "Meeting"
    }

    private var summary: String? {
        block.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private var durationText: String {
        let mins = Int((block.meetingDurationSeconds ?? block.endTime.timeIntervalSince(block.startTime)) / 60)
        return "\(mins)m"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(accent.opacity(0.12))
                    .frame(width: 32, height: 32)
                Image(systemName: "video.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(accent)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                if let summary {
                    Text(summary)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 6) {
                    Text(JournalDateFormatters.time(block.startTime))
                        .monospacedDigit()
                    Text("\u{00B7}").foregroundStyle(.quaternary)
                    Text(durationText)
                        .monospacedDigit()
                    if let app = block.meetingApp, !app.isEmpty {
                        Text("\u{00B7}").foregroundStyle(.quaternary)
                        Text(app)
                    }
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .padding(.top, 1)
            }

            Spacer(minLength: 0)
        }
    }
}

// MARK: - Activity timeline (hour-by-hour, scoped inside its card)

private struct ActivityTimeline: View {
    let blocks: [JournalBlock]
    let commitments: [DayCommitment]
    let captures: [DayCapture]

    private struct HourBucket: Identifiable {
        let id: Int
        let hour: Int
        let blocks: [JournalBlock]
    }

    private var buckets: [HourBucket] {
        let calendar = Calendar.current
        var grouped: [Int: [JournalBlock]] = [:]
        for block in blocks {
            let hour = calendar.component(.hour, from: block.startTime)
            grouped[hour, default: []].append(block)
        }
        return grouped.keys.sorted().map { hour in
            HourBucket(id: hour, hour: hour, blocks: grouped[hour]?.sorted { $0.startTime < $1.startTime } ?? [])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(buckets) { bucket in
                HStack(alignment: .top, spacing: 12) {
                    Text(hourLabel(bucket.hour))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.tertiary)
                        .tracking(0.6)
                        .frame(width: 44, alignment: .trailing)
                        .padding(.top, 4)

                    Rectangle()
                        .fill(SettingsPalette.border.opacity(0.32))
                        .frame(width: 1)

                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(bucket.blocks) { block in
                            ActivityBlockRow(
                                block: block,
                                commitments: commitments.filter { $0.time >= block.startTime && $0.time <= block.endTime }
                            )
                        }
                    }
                }
            }
        }
    }

    private func hourLabel(_ hour: Int) -> String {
        let suffix = hour < 12 ? "AM" : "PM"
        let h = hour % 12
        let display = h == 0 ? 12 : h
        return "\(display) \(suffix)"
    }
}

private struct ActivityBlockRow: View {
    let block: JournalBlock
    let commitments: [DayCommitment]

    private var accent: Color {
        block.isMeeting == true ? JournalPalette.meetingColor : JournalPalette.colorForBundleId(block.bundleId)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                JournalAppIconBadgeView(
                    bundleId: block.bundleId,
                    tint: accent,
                    size: 11,
                    fallbackDotSize: 4
                )
                Text(titleText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(timeRangeLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.quaternary)
                    .monospacedDigit()
            }

            if let summary = block.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !commitments.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(commitments) { c in
                        HStack(spacing: 6) {
                            Image(systemName: c.kind == .decision ? "checkmark" : (c.kind == .question ? "questionmark" : "arrow.right"))
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(accent)
                                .frame(width: 10)
                            Text(c.text)
                                .font(.system(size: 11))
                                .foregroundStyle(.primary.opacity(0.72))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private var titleText: String {
        if block.isMeeting == true, let mt = block.meetingTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !mt.isEmpty {
            return mt
        }
        if let acc = block.accomplishment?.trimmingCharacters(in: .whitespacesAndNewlines), !acc.isEmpty {
            return acc
        }
        if let topic = block.topicLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !topic.isEmpty {
            return topic
        }
        return block.appName
    }

    private var timeRangeLabel: String {
        let mins = Int(block.endTime.timeIntervalSince(block.startTime) / 60)
        let start = JournalDateFormatters.time(block.startTime)
        if mins < 1 { return start }
        return "\(start) \u{00B7} \(mins)m"
    }
}

// MARK: - Small util

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
