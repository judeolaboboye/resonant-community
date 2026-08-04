import SwiftData
import SwiftUI

struct ProgressionTabView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.calendar) private var calendar

    @State private var historyMetrics = ProgressionHistoryMetrics()
    @State private var showIntroModal = false

    private var totalWords: Int {
        appState.statsTracker.totalWords
    }

    private var totalDictations: Int {
        max(appState.statsTracker.totalDictations, historyMetrics.entryCount)
    }

    private var currentLevel: LevelSystem.Level {
        appState.statsTracker.currentLevel
    }

    private var currentLevelIndex: Int {
        LevelSystem.levels.firstIndex(where: { $0.name == currentLevel.name }) ?? 0
    }

    private var nextLevel: LevelSystem.Level? {
        appState.statsTracker.nextLevel
    }

    private var levelProgress: Double {
        appState.statsTracker.levelProgress
    }

    private var averageWordsPerMinute: Int {
        guard historyMetrics.totalRecordedSeconds > 0, historyMetrics.totalRecordedWords > 0 else { return 0 }
        return Int(round((Double(historyMetrics.totalRecordedWords) / Double(historyMetrics.totalRecordedSeconds)) * 60))
    }

    private var averageWordsPerSession: Int {
        guard totalDictations > 0 else { return 0 }
        return Int(round(Double(totalWords) / Double(totalDictations)))
    }

    private var longRunRate: Int {
        guard totalDictations > 0 else { return 0 }
        return Int(round((Double(historyMetrics.longDictations) / Double(totalDictations)) * 100))
    }

    private var wordsToNextLevel: Int {
        guard let nextLevel else { return 0 }
        return max(0, nextLevel.minWords - totalWords)
    }

    private var timeSavedLabel: String {
        formatTypingMinutes(Int(round(appState.statsTracker.minutesSaved)))
    }

    private var weeklyTotalWords: Int {
        historyMetrics.weeklyWordCounts.reduce(0, +)
    }

    private var shareworthySummary: String {
        "\(totalWords.formatted()) words overall, \(appState.statsTracker.streakDays)-day streak, \(timeSavedLabel) saved"
    }

    private var levelColor: Color {
        Color(hex: currentLevel.color)
    }

    private static let defaultDictationOrbHue: Double = 0.60

    private var selectedOrbLevelIndex: Int? {
        let savedHue = appState.settingsManager.dictationOrbHue
        let tolerance = 0.005
        return LevelSystem.levels.firstIndex { abs($0.hue - savedHue) < tolerance }
    }

    private var isUsingDefaultOrb: Bool {
        abs(appState.settingsManager.dictationOrbHue - Self.defaultDictationOrbHue) < 0.005
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
                SettingsPageHeader(
                    title: "Progression",
                    subtitle: "See how your voice work compounds over time, and keep a record that feels worth sharing."
                ) {
                    HStack(spacing: 14) {
                        ProgressionHeaderStat(
                            title: "\(totalDictations.formatted())",
                            systemImage: "waveform"
                        )
                        ProgressionHeaderStat(
                            title: timeSavedLabel,
                            systemImage: "clock.arrow.circlepath"
                        )
                        if appState.statsTracker.streakDays > 0 {
                            ProgressionHeaderStat(
                                title: "\(appState.statsTracker.streakDays)d streak",
                                systemImage: "flame.fill"
                            )
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    SettingsSectionLabel(title: "This Week")

                    ProgressionWeeklyCadenceCard(
                        weeklyWordCounts: historyMetrics.weeklyWordCounts,
                        weekdaySymbols: historyMetrics.weekdaySymbols,
                        todayIndex: historyMetrics.todayIndex,
                        averageWeeklyWords: historyMetrics.averageWeeklyWords,
                        todayWords: historyMetrics.todayWords,
                        peakDayLabel: historyMetrics.peakDayLabel,
                        peakDayWords: historyMetrics.peakDayWords,
                        weeklyTotalWords: weeklyTotalWords,
                        sessionsThisWeek: historyMetrics.sessionsThisWeek,
                        levelColor: levelColor
                    )
                }

                VStack(alignment: .leading, spacing: 10) {
                    SettingsSectionLabel(title: "Snapshot")

                    ProgressionSnapshotGrid(
                        averageWordsPerMinute: averageWordsPerMinute,
                        focusTimeSeconds: historyMetrics.totalRecordedSeconds,
                        totalDictations: totalDictations,
                        averageWordsPerSession: averageWordsPerSession,
                        longRunRate: longRunRate,
                        longDictations: historyMetrics.longDictations
                    )
                }

                ProgressionLevelCard(
                    currentLevelName: currentLevel.name,
                    nextLevelName: nextLevel?.name,
                    levelProgress: levelProgress,
                    totalWords: totalWords,
                    wordsToNextLevel: wordsToNextLevel,
                    levelColor: levelColor,
                    currentLevelIndex: currentLevelIndex,
                    selectedOrbHue: appState.settingsManager.dictationOrbHue,
                    selectedOrbLevelIndex: selectedOrbLevelIndex,
                    isUsingDefaultOrb: isUsingDefaultOrb,
                    onSelectLevelHue: { level in
                        appState.settingsManager.dictationOrbHue = level.hue
                    },
                    onResetToDefault: {
                        appState.settingsManager.dictationOrbHue = Self.defaultDictationOrbHue
                    }
                )

                HStack {
                    Text("Quietly shareable: \(shareworthySummary).")
                        .font(SettingsTypography.metadata)
                        .foregroundStyle(.tertiary)

                    Spacer(minLength: 8)

                    Button {
                        showIntroModal = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "questionmark.circle")
                                .font(.system(size: 12, weight: .medium))
                            Text("How it works")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, SettingsLayout.pageHorizontalPadding)
            .padding(.vertical, SettingsLayout.pageVerticalPadding)
            .frame(maxWidth: SettingsLayout.pageWidth)
            .frame(maxWidth: .infinity)
        }
        .background(SettingsPalette.warmBackdrop)
        .task(id: appState.feedManager.items.count) {
            reloadHistoryMetrics()
        }
        .overlay {
            Group {
                if showIntroModal {
                    ProgressionIntroModal(isPresented: $showIntroModal)
                        .transition(.opacity)
                }
            }
        }
        .onAppear {
            if !appState.settingsManager.progressionIntroSeen {
                appState.settingsManager.progressionIntroSeen = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    showIntroModal = true
                }
            }
        }
    }

    private func reloadHistoryMetrics() {
        let descriptor = FetchDescriptor<DictationEntry>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        historyMetrics = ProgressionHistoryMetrics(
            entries: appState.dataStore.fetch(descriptor),
            calendar: calendar
        )
    }
}

// MARK: - Header Stat

private struct ProgressionHeaderStat: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
            Text(title)
                .font(SettingsTypography.metadata)
        }
        .foregroundStyle(.secondary)
    }
}

// MARK: - Orb

private struct ProgressionOrbView: View {
    private struct Theme {
        let background: Color
        let primary: Color
        let secondary: Color
        let tertiary: Color
    }

    let hue: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var theme: Theme {
        Theme(
            background: Color(hue: hue, saturation: 0.08, brightness: 0.99),
            primary: Color(hue: wrappedHue(hue - 0.06), saturation: 0.58, brightness: 0.96),
            secondary: Color(hue: wrappedHue(hue + 0.02), saturation: 0.48, brightness: 0.99),
            tertiary: Color(hue: wrappedHue(hue + 0.10), saturation: 0.54, brightness: 0.94)
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let theme = theme
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { (timeline: TimelineViewDefaultContext) in
                let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                let size = max(1, min(geometry.size.width, geometry.size.height))
                let angle = (time * (360.0 / 40.0)).truncatingRemainder(dividingBy: 360)
                let flare: CGFloat = 0.25

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
                        ProgressionConicLayer(color: theme.tertiary, angle: angle, multiplier: 2, centerX: 0.25, centerY: 0.70, transparentStart: 0.20, transparentEnd: 0.80)
                        ProgressionConicLayer(color: theme.secondary, angle: angle, multiplier: 2, centerX: 0.45, centerY: 0.75, transparentStart: 0.30, transparentEnd: 0.60)
                        ProgressionConicLayer(color: theme.primary, angle: angle, multiplier: -3, centerX: 0.80, centerY: 0.20, transparentStart: 0.40, transparentEnd: 0.60)
                        ProgressionConicLayer(color: theme.secondary, angle: angle, multiplier: 2, centerX: 0.15, centerY: 0.05, transparentStart: 0.10, transparentEnd: 0.90)
                        ProgressionConicLayer(color: theme.primary, angle: angle, multiplier: 1, centerX: 0.20, centerY: 0.80, transparentStart: 0.10, transparentEnd: 0.90)
                        ProgressionConicLayer(color: theme.tertiary, angle: angle, multiplier: -2, centerX: 0.85, centerY: 0.10, transparentStart: 0.20, transparentEnd: 0.80)
                    }
                    .blur(radius: max(size * 0.015, 4))
                    .contrast(1.5 + (flare * 0.3))
                    .saturation(1.1 + (flare * 0.25))

                    ProgressionDotLayer(dotSize: max(size * 0.02, 1.0), color: theme.background)
                        .blendMode(.overlay)
                        .opacity(0.32)
                }
                .clipShape(Circle())
                .shadow(color: theme.secondary.opacity(0.20 + flare * 0.35), radius: max(size * 0.008, 2))
            }
        }
        .compositingGroup()
        .drawingGroup()
    }

    private func wrappedHue(_ h: Double) -> Double {
        let wrapped = h.truncatingRemainder(dividingBy: 1.0)
        return wrapped < 0 ? wrapped + 1.0 : wrapped
    }
}

private struct ProgressionDotLayer: View {
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

private struct ProgressionConicLayer: View {
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

// MARK: - Level Card (Hero + Journey)

private struct ProgressionLevelCard: View {
    let currentLevelName: String
    let nextLevelName: String?
    let levelProgress: Double
    let totalWords: Int
    let wordsToNextLevel: Int
    let levelColor: Color
    let currentLevelIndex: Int
    let selectedOrbHue: Double
    let selectedOrbLevelIndex: Int?
    let isUsingDefaultOrb: Bool
    let onSelectLevelHue: (LevelSystem.Level) -> Void
    let onResetToDefault: () -> Void

    private var dictationOrbAccent: Color {
        originalModeAccentColor(for: "listening")
    }

    private var orbDescriptionText: String {
        if isUsingDefaultOrb {
            return "Tap an unlocked level below to change your notch orb."
        }
        if let index = selectedOrbLevelIndex, let level = LevelSystem.levels[safe: index] {
            return "Showing the \(level.name) orb in your notch. Tap any unlocked level to switch."
        }
        return "Tap an unlocked level below to change your notch orb."
    }

    var body: some View {
        SettingsPrimaryCard {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .center, spacing: 24) {
                    ProgressionOrbView(hue: selectedOrbHue)
                        .frame(width: 88, height: 88)

                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(currentLevelName)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.tertiary)
                                .textCase(.uppercase)
                                .tracking(1.2)

                            Text(totalWords.formatted())
                                .font(.system(size: 36, weight: .semibold))
                                .foregroundStyle(.primary)
                                .monospacedDigit()

                            Text("words dictated")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)

                            Label {
                                Text(orbDescriptionText)
                            } icon: {
                                Image(systemName: "mic.fill")
                                    .foregroundStyle(dictationOrbAccent)
                            }
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 6)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            SettingsLinearProgressBar(value: levelProgress, tint: .primary.opacity(0.85))

                            if let nextLevelName, wordsToNextLevel > 0 {
                                Text("\(wordsToNextLevel.formatted()) to \(nextLevelName)")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.quaternary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Rectangle()
                    .fill(SettingsPalette.border.opacity(0.12))
                    .frame(height: 1)

                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Choose your orb")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                                .tracking(1.0)

                            Text("Each level you unlock adds a new orb color to your notch.")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.tertiary)
                        }

                        Spacer(minLength: 8)

                        if !isUsingDefaultOrb {
                            Button(action: onResetToDefault) {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.counterclockwise")
                                        .font(.system(size: 10, weight: .semibold))
                                    Text("Reset")
                                        .font(.system(size: 11, weight: .semibold))
                                }
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(SettingsPalette.elevatedBackground)
                                )
                                .overlay(
                                    Capsule(style: .continuous)
                                        .stroke(SettingsPalette.border.opacity(0.22), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                            .onHover { hovering in
                                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                            }
                        }
                    }

                    ProgressionJourneyTimeline(
                        currentLevelIndex: currentLevelIndex,
                        selectedOrbLevelIndex: selectedOrbLevelIndex,
                        onSelectLevel: onSelectLevelHue
                    )
                }
            }
        }
    }
}

// MARK: - Snapshot Grid

private struct ProgressionSnapshotGrid: View {
    let averageWordsPerMinute: Int
    let focusTimeSeconds: Int
    let totalDictations: Int
    let averageWordsPerSession: Int
    let longRunRate: Int
    let longDictations: Int

    var body: some View {
        SettingsPrimaryCard(padding: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    snapshotCell(
                        value: averageWordsPerMinute > 0 ? "\(averageWordsPerMinute)" : "—",
                        label: "Avg pace (wpm)"
                    )

                    Rectangle()
                        .fill(SettingsPalette.border.opacity(0.22))
                        .frame(width: 1)

                    snapshotCell(
                        value: formatFocusTime(focusTimeSeconds),
                        label: "Focus time"
                    )
                }
                .frame(height: 80)

                Rectangle()
                    .fill(SettingsPalette.border.opacity(0.22))
                    .frame(height: 1)

                HStack(spacing: 0) {
                    snapshotCell(
                        value: "\(totalDictations.formatted())",
                        label: "Sessions"
                    )

                    Rectangle()
                        .fill(SettingsPalette.border.opacity(0.22))
                        .frame(width: 1)

                    snapshotCell(
                        value: "\(longRunRate)%",
                        label: "Long-run share"
                    )
                }
                .frame(height: 80)
            }
        }
    }

    private func snapshotCell(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(SettingsTypography.metricValue)
                .foregroundStyle(.primary)
                .monospacedDigit()

            Text(label)
                .font(SettingsTypography.metricLabel)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SettingsLayout.cardPadding)
    }
}

// MARK: - Weekly Cadence

private struct ProgressionWeeklyCadenceCard: View {
    let weeklyWordCounts: [Int]
    let weekdaySymbols: [String]
    let todayIndex: Int
    let averageWeeklyWords: Int
    let todayWords: Int
    let peakDayLabel: String?
    let peakDayWords: Int
    let weeklyTotalWords: Int
    let sessionsThisWeek: Int
    let levelColor: Color

    var body: some View {
        SettingsPrimaryCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Weekly momentum")
                            .font(SettingsTypography.cardTitle)
                            .foregroundStyle(.primary)

                        Text("A calm read on how much work your voice moved this week.")
                            .font(SettingsTypography.body)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 12)

                    Text("\(weeklyTotalWords.formatted()) words")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                }

                ProgressionWeeklyBars(
                    weekdaySymbols: weekdaySymbols,
                    wordCounts: weeklyWordCounts,
                    highlightedIndex: todayIndex,
                    levelColor: levelColor
                )

                HStack(spacing: 8) {
                    SettingsMetaPill(title: "\(averageWeeklyWords.formatted()) avg/day", systemImage: "chart.line.uptrend.xyaxis")
                    SettingsMetaPill(title: "Today \(todayWords.formatted())", systemImage: "calendar")
                    SettingsMetaPill(title: "\(sessionsThisWeek) sessions", systemImage: "waveform")

                    if let peakDayLabel, peakDayWords > 0 {
                        SettingsMetaPill(title: "Peak \(peakDayLabel) \(peakDayWords.formatted())", systemImage: "star.fill")
                    }
                }
            }
        }
    }
}

// MARK: - Weekly Bars

private struct ProgressionWeeklyBars: View {
    let weekdaySymbols: [String]
    let wordCounts: [Int]
    let highlightedIndex: Int
    let levelColor: Color

    var body: some View {
        let maxCount = max(wordCounts.max() ?? 0, 10)

        HStack(alignment: .bottom, spacing: 10) {
            ForEach(Array(wordCounts.enumerated()), id: \.offset) { index, count in
                let normalized = max(Double(count) / Double(maxCount), count > 0 ? 0.08 : 0.02)

                ProgressionWeeklyBarColumn(
                    symbol: weekdaySymbols[safe: index] ?? "",
                    count: count,
                    normalized: normalized,
                    isToday: index == highlightedIndex,
                    levelColor: levelColor
                )
            }
        }
    }
}

private struct ProgressionWeeklyBarColumn: View {
    let symbol: String
    let count: Int
    let normalized: Double
    let isToday: Bool
    let levelColor: Color

    private var barFill: Color {
        if isToday {
            return count > 0 ? levelColor : levelColor.opacity(0.15)
        }

        return count > 0
            ? SettingsPalette.border.opacity(0.45)
            : SettingsPalette.border.opacity(0.12)
    }

    var body: some View {
        VStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(barFill)
                .frame(height: max(100 * normalized, count > 0 ? 10 : 4))
                .frame(height: 100, alignment: .bottom)

            Text(symbol)
                .font(.system(size: 10, weight: isToday ? .semibold : .medium))
                .foregroundStyle(isToday ? .primary : .tertiary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(symbol): \(count) words")
    }
}

// MARK: - Journey Timeline

private struct ProgressionJourneyTimeline: View {
    let currentLevelIndex: Int
    let selectedOrbLevelIndex: Int?
    let onSelectLevel: (LevelSystem.Level) -> Void

    private let trackHeight: CGFloat = 2
    private let nodeContainerHeight: CGFloat = 28

    var body: some View {
        let levels = LevelSystem.levels

        VStack(spacing: 10) {
            HStack(spacing: 0) {
                ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                    ProgressionLevelNode(
                        level: level,
                        isUnlocked: index <= currentLevelIndex,
                        isCurrentEarnedLevel: index == currentLevelIndex,
                        isSelectedOrb: index == selectedOrbLevelIndex,
                        onTap: { onSelectLevel(level) }
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: nodeContainerHeight)
                }
            }
            .background(alignment: .center) {
                GeometryReader { geo in
                    let count = levels.count
                    let stepWidth = geo.size.width / CGFloat(count)

                    Capsule()
                        .fill(SettingsPalette.border.opacity(0.18))
                        .frame(
                            width: stepWidth * CGFloat(count - 1),
                            height: trackHeight
                        )
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)

                    if currentLevelIndex > 0 {
                        let startX = stepWidth / 2
                        let endX = stepWidth * CGFloat(currentLevelIndex) + stepWidth / 2

                        Capsule()
                            .fill(.primary.opacity(0.30))
                            .frame(width: endX - startX, height: trackHeight)
                            .position(x: startX + (endX - startX) / 2, y: geo.size.height / 2)
                    }
                }
            }

            HStack(spacing: 0) {
                ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                    let isUnlocked = index <= currentLevelIndex
                    let isSelectedOrb = index == selectedOrbLevelIndex
                    Text(level.name)
                        .font(.system(size: 9, weight: isSelectedOrb ? .semibold : (index == currentLevelIndex ? .semibold : .regular)))
                        .foregroundStyle(isSelectedOrb ? .primary : (isUnlocked ? .secondary : .quaternary))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

private struct ProgressionLevelNode: View {
    let level: LevelSystem.Level
    let isUnlocked: Bool
    let isCurrentEarnedLevel: Bool
    let isSelectedOrb: Bool
    let onTap: () -> Void

    @State private var isHovered = false

    private var nodeSize: CGFloat {
        isSelectedOrb ? 16 : (isCurrentEarnedLevel ? 12 : 10)
    }

    private var fillColor: Color {
        let base = Color(hex: level.color)
        return isUnlocked ? base : base.opacity(0.22)
    }

    var body: some View {
        Button(action: { if isUnlocked { onTap() } }) {
            ZStack {
                if isSelectedOrb {
                    Circle()
                        .stroke(Color(hex: level.color).opacity(0.45), lineWidth: 1.5)
                        .frame(width: nodeSize + 10, height: nodeSize + 10)
                }

                Circle()
                    .fill(fillColor)
                    .frame(width: nodeSize, height: nodeSize)
                    .shadow(
                        color: isUnlocked ? Color(hex: level.color).opacity(isSelectedOrb ? 0.55 : 0.25) : .clear,
                        radius: isSelectedOrb ? 6 : 3
                    )
                    .overlay {
                        if !isUnlocked {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 5, weight: .bold))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                    }
            }
            .scaleEffect(isHovered && isUnlocked ? 1.18 : 1.0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isUnlocked)
        .help(helpText)
        .onHover { hovering in
            isHovered = hovering
            if hovering && isUnlocked {
                NSCursor.pointingHand.push()
            } else if !hovering {
                NSCursor.pop()
            }
        }
    }

    private var helpText: String {
        if !isUnlocked {
            return "\(level.name) — unlocks at \(level.minWords.formatted()) words"
        }
        if isSelectedOrb {
            return "\(level.name) — currently your notch orb"
        }
        return "\(level.name) — click to make this your notch orb"
    }
}

// MARK: - History Metrics

private struct ProgressionHistoryMetrics {
    var entryCount: Int = 0
    var totalRecordedWords: Int = 0
    var totalRecordedSeconds: Int = 0
    var longDictations: Int = 0
    var weeklyWordCounts: [Int] = Array(repeating: 0, count: 7)
    var weekdaySymbols: [String] = []
    var todayIndex: Int = 0
    var peakDayIndex: Int = 0
    var sessionsThisWeek: Int = 0

    init() {}

    init(entries: [DictationEntry], calendar: Calendar) {
        entryCount = entries.count
        totalRecordedWords = entries.reduce(0) { $0 + $1.wordCount }
        totalRecordedSeconds = Int(entries.reduce(0.0) { $0 + $1.duration }.rounded())
        longDictations = entries.reduce(into: 0) { result, entry in
            if entry.duration >= 20 {
                result += 1
            }
        }

        let orderedSymbols = Self.weekdaySymbols(calendar: calendar)
        let weekInterval = calendar.dateInterval(of: .weekOfYear, for: Date())
        let weekStart = weekInterval?.start ?? calendar.startOfDay(for: Date())
        let weekEnd = weekInterval?.end ?? Date()
        var counts = Array(repeating: 0, count: 7)
        var weekSessions = 0

        for entry in entries where entry.date >= weekStart && entry.date < weekEnd {
            let dayStart = calendar.startOfDay(for: entry.date)
            let offset = calendar.dateComponents([.day], from: calendar.startOfDay(for: weekStart), to: dayStart).day ?? -1
            if counts.indices.contains(offset) {
                counts[offset] += entry.wordCount
                weekSessions += 1
            }
        }

        weeklyWordCounts = counts
        weekdaySymbols = orderedSymbols
        sessionsThisWeek = weekSessions

        let todayOffset = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: weekStart),
            to: calendar.startOfDay(for: Date())
        ).day ?? 0
        todayIndex = min(max(todayOffset, 0), 6)
        peakDayIndex = counts.enumerated().max(by: { $0.element < $1.element })?.offset ?? 0
    }

    var averageWeeklyWords: Int {
        Int(round(Double(weeklyWordCounts.reduce(0, +)) / 7.0))
    }

    var todayWords: Int {
        weeklyWordCounts[safe: todayIndex] ?? 0
    }

    var peakDayWords: Int {
        weeklyWordCounts[safe: peakDayIndex] ?? 0
    }

    var peakDayLabel: String? {
        guard peakDayWords > 0 else { return nil }
        return weekdaySymbols[safe: peakDayIndex]
    }

    private static func weekdaySymbols(calendar: Calendar) -> [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        guard !symbols.isEmpty else { return ["S", "M", "T", "W", "T", "F", "S"] }
        let start = max(calendar.firstWeekday - 1, 0)
        return Array(symbols[start...]) + Array(symbols[..<start])
    }
}

// MARK: - Helpers

private func formatFocusTime(_ totalSeconds: Int) -> String {
    let safeSeconds = max(0, totalSeconds)
    let minutes = safeSeconds / 60
    let hours = minutes / 60

    if hours == 0 {
        return "\(minutes)m"
    }

    let remainder = minutes % 60
    return remainder > 0 ? "\(hours)h \(remainder)m" : "\(hours)h"
}

private func formatTypingMinutes(_ minutes: Int) -> String {
    if minutes <= 0 {
        return "<1m"
    }
    if minutes < 60 {
        return "\(minutes)m"
    }

    let hours = minutes / 60
    let remainder = minutes % 60
    return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
}

private extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: .init(charactersIn: "#"))
        guard cleaned.count == 6,
              let value = UInt64(cleaned, radix: 16)
        else {
            self = .gray
            return
        }

        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - Progression Intro Modal

private struct ProgressionIntroModal: View {
    @Binding var isPresented: Bool
    @State private var revealed = false

    private let accentBlue = SettingsPalette.semanticBlue

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(alignment: .leading, spacing: 0) {
                header
                Divider().opacity(0.5)
                content
            }
            .frame(width: 380)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(SettingsPalette.cardBackground)
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(SettingsPalette.border.opacity(0.3), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.18), radius: 30, x: 0, y: 16)
        }
    }

    private var header: some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(accentBlue)
                Text("How Progression Works")
                    .font(.system(size: 14, weight: .semibold))
            }

            Spacer()

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(SettingsPalette.elevatedBackground))
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(SettingsPalette.elevatedBackground.opacity(0.6))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            ProgressionIntroStep(
                number: 1,
                title: "Dictate to level up",
                description: "Every word you speak earns progress toward the next level\u{2014}from Rookie all the way to Transcendent."
            )

            ProgressionIntroStep(
                number: 2,
                title: "Build streaks and momentum",
                description: "Use Resonant daily to build a streak. The weekly view shows your cadence so you can stay consistent."
            )

            ProgressionIntroStep(
                number: 3,
                title: "Save real time",
                description: "Speaking is 3\u{2013}5x faster than typing. Your time saved grows with every session and compounds over weeks."
            )

            levelPreview

            Button { dismiss() } label: {
                Text("Got it")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(accentBlue)
                    )
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
        .padding(20)
    }

    private var levelPreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            let sampleLevels: [(String, Int, Color)] = [
                ("Rookie", 0, Color(hex: "#6B7280")),
                ("Talker", 100, Color(hex: "#3B82F6")),
                ("Wordsmith", 1_000, Color(hex: "#10B981")),
                ("Orator", 10_000, Color(hex: "#EAB308")),
                ("Legend", 100_000, Color(hex: "#EC4899")),
            ]

            HStack(spacing: 0) {
                ForEach(Array(sampleLevels.enumerated()), id: \.offset) { index, level in
                    VStack(spacing: 6) {
                        Circle()
                            .fill(revealed ? level.2 : level.2.opacity(0.3))
                            .frame(width: index == 0 ? 10 : 6, height: index == 0 ? 10 : 6)

                        VStack(spacing: 2) {
                            Text(level.0)
                                .font(.system(size: 11, weight: index == 0 ? .semibold : .regular))
                                .foregroundStyle(index == 0 ? .primary : .secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)

                            Text("\(level.1.formatted())")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(SettingsPalette.elevatedBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(SettingsPalette.border.opacity(0.22), lineWidth: 1)
        )
    }

    private func dismiss() {
        isPresented = false
        revealed = false
    }
}

private struct ProgressionIntroStep: View {
    private static let accent = SettingsPalette.semanticBlue

    let number: Int
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Self.accent))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                if !description.isEmpty {
                    Text(description)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
