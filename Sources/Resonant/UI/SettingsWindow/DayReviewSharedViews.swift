import Foundation
import SwiftUI

struct DayData {
    let day: JournalDay?
    let blocks: [JournalBlock]
    let shape: DayShape
    let commitments: [DayCommitment]
    let captures: [DayCapture]
    let mentions: [AppMention]

    static let empty = DayData(
        day: nil,
        blocks: [],
        shape: DayShape(
            slices: [],
            totalMinutes: 0,
            meetingCount: 0,
            sessionCount: 0,
            dictationCount: 0,
            totalWords: 0
        ),
        commitments: [],
        captures: [],
        mentions: []
    )

    static func build(day: JournalDay?) -> DayData {
        let blocks = day?.blocks ?? []
        guard !blocks.isEmpty else {
            return DayData(
                day: day,
                blocks: [],
                shape: DayShape(
                    slices: [],
                    totalMinutes: 0,
                    meetingCount: 0,
                    sessionCount: 0,
                    dictationCount: 0,
                    totalWords: 0
                ),
                commitments: [],
                captures: [],
                mentions: []
            )
        }

        return DayData(
            day: day,
            blocks: blocks,
            shape: DayReviewEngine.shape(for: blocks),
            commitments: DayReviewEngine.commitments(from: blocks, limit: 50),
            captures: DayReviewEngine.captures(from: blocks, limit: 50),
            mentions: AppMention.build(from: blocks)
        )
    }
}

struct AppMention: Identifiable, Hashable {
    let id: String
    let appName: String
    let bundleId: String
    let minutes: Int
    let blockCount: Int
    let sampleTexts: [String]
    let isMeeting: Bool

    static func build(from blocks: [JournalBlock]) -> [AppMention] {
        struct Bucket {
            var appName: String
            var bundleId: String
            var minutes: Double = 0
            var blockCount: Int = 0
            var samples: [String] = []
            var isMeeting: Bool = false
        }

        var buckets: [String: Bucket] = [:]
        for block in blocks {
            let key = block.appName.lowercased()
            var bucket = buckets[key] ?? Bucket(appName: block.appName, bundleId: block.bundleId)
            bucket.minutes += max(block.endTime.timeIntervalSince(block.startTime) / 60, 1)
            bucket.blockCount += 1
            if block.isMeeting == true {
                bucket.isMeeting = true
            }

            if let summary = block.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
               !summary.isEmpty,
               bucket.samples.count < 3 {
                bucket.samples.append(summary)
            } else if bucket.samples.count < 3,
                      let first = block.entries.first,
                      !first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                bucket.samples.append(String(first.prefix(280)))
            }
            buckets[key] = bucket
        }

        return buckets
            .map { key, bucket in
                AppMention(
                    id: key,
                    appName: bucket.appName,
                    bundleId: bucket.bundleId,
                    minutes: Int(bucket.minutes),
                    blockCount: bucket.blockCount,
                    sampleTexts: bucket.samples,
                    isMeeting: bucket.isMeeting
                )
            }
            .sorted { $0.minutes > $1.minutes }
    }
}

struct BriefView: View {
    let brief: String
    let mentions: [AppMention]

    private var sections: [BriefSection] {
        BriefSection.parse(brief)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                BriefSectionView(section: section)
            }

            if !mentions.isEmpty {
                MentionChipRow(mentions: mentions)
                    .padding(.top, 4)
            }
        }
    }
}

struct BriefSection: Identifiable {
    enum Kind: String {
        case lede
        case whatHappened = "what happened"
        case commitments
        case pattern
        case other
    }

    let id = UUID()
    let kind: Kind
    let heading: String
    let blocks: [MarkdownBlock]

    static func parse(_ brief: String) -> [BriefSection] {
        let lines = brief.components(separatedBy: "\n")
        var sections: [(heading: String, lines: [String])] = []
        var currentHeading: String?
        var buffer: [String] = []

        func flush() {
            if let heading = currentHeading {
                sections.append((heading, buffer))
            } else if !buffer.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                sections.append(("", buffer))
            }
            buffer = []
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") {
                flush()
                currentHeading = String(trimmed.dropFirst(3))
            } else {
                buffer.append(line)
            }
        }
        flush()

        return sections.map { heading, bodyLines in
            let kind: Kind
            switch heading.lowercased() {
            case "lede":
                kind = .lede
            case "what happened":
                kind = .whatHappened
            case "commitments":
                kind = .commitments
            case "pattern":
                kind = .pattern
            default:
                kind = .other
            }

            return BriefSection(
                kind: kind,
                heading: heading,
                blocks: MarkdownBlock.parse(bodyLines.joined(separator: "\n"))
            )
        }
    }
}

private struct BriefSectionView: View {
    let section: BriefSection

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch section.kind {
            case .lede:
                blockList(style: .lede)

            case .whatHappened:
                sectionHeading("What happened")
                blockList(style: .body)

            case .commitments:
                sectionHeading("Commitments")
                blockList(style: .body)

            case .pattern:
                sectionHeading("Pattern")
                blockList(style: .pattern)

            case .other:
                if !section.heading.isEmpty {
                    sectionHeading(section.heading)
                }
                blockList(style: .body)
            }
        }
    }

    private func blockList(style: MarkdownBlockView.Style) -> some View {
        ForEach(Array(section.blocks.enumerated()), id: \.offset) { _, block in
            MarkdownBlockView(block: block, style: style)
        }
    }

    private func sectionHeading(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.secondary)
            .tracking(0.5)
            .textCase(.uppercase)
    }
}

private struct MentionChipRow: View {
    let mentions: [AppMention]

    private var displayed: [AppMention] {
        Array(mentions.prefix(10))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mentioned today")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.tertiary)
                .tracking(0.5)
                .textCase(.uppercase)

            MentionFlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(displayed) { mention in
                    MentionChip(mention: mention)
                }
            }
        }
    }
}

private struct MentionChip: View {
    let mention: AppMention
    @State private var isHovered = false
    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            HStack(spacing: 5) {
                JournalAppIconBadgeView(
                    bundleId: mention.bundleId,
                    tint: JournalPalette.colorForBundleId(mention.bundleId),
                    size: 12,
                    fallbackDotSize: 4
                )
                Text(mention.appName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.85))
                Text(formatMinutes(mention.minutes))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered || showPopover ? SettingsPalette.accentFill : SettingsPalette.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(
                        showPopover ? SettingsPalette.accentBorder : SettingsPalette.border.opacity(0.18),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.14)) {
                isHovered = hovering
            }
        }
        .popover(isPresented: $showPopover, arrowEdge: .top) {
            MentionPopover(mention: mention)
        }
        .help("Click to see what you said in \(mention.appName)")
    }

    private func formatMinutes(_ minutes: Int) -> String {
        if minutes < 60 {
            return "\(minutes)m"
        }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return remainingMinutes > 0 ? "\(hours)h\(remainingMinutes)m" : "\(hours)h"
    }
}

private struct MentionPopover: View {
    let mention: AppMention

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                JournalAppIconBadgeView(
                    bundleId: mention.bundleId,
                    tint: JournalPalette.colorForBundleId(mention.bundleId),
                    size: 16,
                    fallbackDotSize: 6
                )
                Text(mention.appName)
                    .font(.system(size: 13, weight: .semibold))
                if mention.isMeeting {
                    Text("meeting")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .tracking(0.5)
                        .textCase(.uppercase)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Text("\(mention.blockCount) \(mention.blockCount == 1 ? "block" : "blocks")")
                Text("-")
                    .foregroundStyle(.quaternary)
                Text("\(mention.minutes)m")
            }
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .foregroundStyle(.tertiary)

            if !mention.sampleTexts.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(mention.sampleTexts.enumerated()), id: \.offset) { _, sample in
                        Text(sample)
                            .font(.system(size: 12))
                            .foregroundStyle(.primary.opacity(0.85))
                            .lineSpacing(3)
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}

private struct MentionFlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let result = layout(sizes: subviews.map { $0.sizeThatFits(.unspecified) }, containerWidth: width)
        return CGSize(
            width: width == .infinity ? result.width : min(width, result.width),
            height: result.height
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let result = layout(sizes: sizes, containerWidth: bounds.width)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }

    private func layout(
        sizes: [CGSize],
        containerWidth: CGFloat
    ) -> (frames: [CGRect], width: CGFloat, height: CGFloat) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxLineWidth: CGFloat = 0

        for size in sizes {
            if x > 0 && x + size.width > containerWidth {
                maxLineWidth = max(maxLineWidth, x - spacing)
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }

        maxLineWidth = max(maxLineWidth, x - spacing)
        return (frames, maxLineWidth, y + lineHeight)
    }
}

enum MarkdownBlock {
    case paragraph(String)
    case bullet(String)
    case heading(Int, String)

    static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraphBuffer: [String] = []

        func flush() {
            guard !paragraphBuffer.isEmpty else {
                return
            }
            let joined = paragraphBuffer.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                blocks.append(.paragraph(joined))
            }
            paragraphBuffer.removeAll()
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flush()
                continue
            }
            if trimmed.hasPrefix("### ") {
                flush()
                blocks.append(.heading(3, String(trimmed.dropFirst(4))))
            } else if trimmed.hasPrefix("## ") {
                flush()
                blocks.append(.heading(2, String(trimmed.dropFirst(3))))
            } else if trimmed.hasPrefix("# ") {
                flush()
                blocks.append(.heading(1, String(trimmed.dropFirst(2))))
            } else if trimmed.hasPrefix("- ") {
                flush()
                blocks.append(.bullet(String(trimmed.dropFirst(2))))
            } else if trimmed.hasPrefix("* ") && !trimmed.hasPrefix("**") {
                flush()
                blocks.append(.bullet(String(trimmed.dropFirst(2))))
            } else {
                paragraphBuffer.append(trimmed)
            }
        }
        flush()
        return blocks
    }
}

struct MarkdownBlockView: View {
    enum Style {
        case lede
        case body
        case pattern
    }

    let block: MarkdownBlock
    let style: Style

    var body: some View {
        switch block {
        case .paragraph(let text):
            paragraphView(text: text)

        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 4, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 8, alignment: .center)
                    .offset(y: -3)
                bulletText(text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        case .heading(let level, let text):
            Text(renderInline(text))
                .font(.system(size: headingSize(for: level), weight: .bold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func paragraphView(text: String) -> some View {
        switch style {
        case .lede:
            Text(renderInline(text))
                .font(.system(size: 14, weight: .medium, design: .serif))
                .foregroundStyle(.primary)
                .italic()
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .pattern:
            Text(renderInline(text))
                .font(.system(size: 12.5, weight: .regular, design: .serif))
                .foregroundStyle(.secondary)
                .italic()
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .body:
            Text(renderInline(text))
                .font(.system(size: 12.5))
                .foregroundStyle(.primary.opacity(0.9))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func bulletText(_ text: String) -> some View {
        Text(renderInline(text))
            .font(.system(size: 12.5))
            .foregroundStyle(Color.primary.opacity(0.9))
            .lineSpacing(3.5)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private func headingSize(for level: Int) -> CGFloat {
        switch level {
        case 1:
            return 18
        case 2:
            return 14
        default:
            return 12
        }
    }

    private func renderInline(_ text: String) -> AttributedString {
        if let attributed = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            return attributed
        }
        return AttributedString(text)
    }
}
