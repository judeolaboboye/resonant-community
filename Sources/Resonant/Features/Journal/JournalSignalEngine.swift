import Foundation

struct JournalSignal: Identifiable {
    let id = UUID()
    let icon: String      // SF Symbol name
    let title: String
    let detail: String?
    let priority: Int     // higher = more important, used for sorting/limiting

    enum Kind {
        case sprintStreak
        case recoveryDue
        case streamDrift
        case expansionAlert
        case lowDay
        case highDay
        case contextSwitching
        case deepWork
        case meetingLoad
        case communicationHeavy
        case lateSession
        case topicFocus
        case dayCharacter
        case meetingTrend
    }
    let kind: Kind
}

enum JournalSignalEngine {

    /// Analyze recent journal days and return actionable signals.
    /// Pure function — no side effects, no persistence, no cloud calls.
    static func signals(from days: [JournalDay], referenceDate: Date = Date()) -> [JournalSignal] {
        let sorted = days
            .sorted { $0.date < $1.date }
            .suffix(7) // last 7 days only

        guard sorted.count >= 2 else { return [] }

        let window = Array(sorted)
        var results: [JournalSignal] = []

        // Volume & pace
        if let s = sprintStreak(from: window, referenceDate: referenceDate) { results.append(s) }
        if let s = intensitySignal(from: window) { results.append(s) }

        // App & topic patterns
        if let s = streamDrift(from: window) { results.append(s) }
        if let s = expansionAlert(from: window) { results.append(s) }
        if let s = dayCharacterSignal(from: window) { results.append(s) }

        // Focus & fragmentation
        if let s = contextSwitchingSignal(from: window) { results.append(s) }
        if let s = deepWorkSignal(from: window) { results.append(s) }
        if let s = topicFocusSignal(from: window) { results.append(s) }

        // Meeting analysis
        if let s = meetingLoadSignal(from: window) { results.append(s) }
        if let s = meetingTrendSignal(from: window) { results.append(s) }

        // Communication & schedule
        if let s = communicationSignal(from: window) { results.append(s) }
        if let s = lateSessionSignal(from: window) { results.append(s) }

        return results.sorted { $0.priority > $1.priority }
    }

    // MARK: - Sprint streak / recovery

    /// Counts consecutive high-intensity days ending at the most recent day.
    /// A day is "high" if its word count exceeds the 7-day average.
    private static func sprintStreak(from days: [JournalDay], referenceDate: Date) -> JournalSignal? {
        guard days.count >= 3 else { return nil }

        let wordCounts = days.map { totalWords($0) }
        let avg = wordCounts.reduce(0, +) / max(wordCounts.count, 1)
        guard avg > 0 else { return nil }

        // Count consecutive above-average days from the end
        var streak = 0
        for wc in wordCounts.reversed() {
            if wc > avg { streak += 1 } else { break }
        }

        if streak >= 3 {
            return JournalSignal(
                icon: "flame",
                title: "Heavy streak: day \(streak)",
                detail: "Your last \(streak) journal days all ran above your weekly average. Consider a lighter day tomorrow.",
                priority: 90,
                kind: .sprintStreak
            )
        }

        if streak == 2 {
            return JournalSignal(
                icon: "flame",
                title: "Second heavy day in a row",
                detail: "The last two journal days both landed above your weekly average.",
                priority: 50,
                kind: .sprintStreak
            )
        }

        // Check if the most recent day was a recovery (well below average)
        if let last = wordCounts.last, last < avg / 3, last > 0 {
            return JournalSignal(
                icon: "leaf",
                title: "Light day",
                detail: "Today came in well below your recent average, which often means a recovery day.",
                priority: 20,
                kind: .recoveryDue
            )
        }

        return nil
    }

    // MARK: - Stream drift

    /// Detects when today's app distribution differs significantly from the weekly norm.
    private static func streamDrift(from days: [JournalDay]) -> JournalSignal? {
        guard days.count >= 3 else { return nil }

        let today = days.last!
        let previous = Array(days.dropLast())

        let todayDist = appDistribution(today)
        let weekDist = appDistribution(previous)

        // Find the app with the biggest positive drift today vs the week
        var biggestDrift: (app: String, todayPct: Int, weekPct: Int)?
        var maxDelta = 0

        for (app, todayPct) in todayDist {
            let weekPct = weekDist[app] ?? 0
            let delta = todayPct - weekPct
            if delta > maxDelta && delta >= 20 {
                maxDelta = delta
                biggestDrift = (app, todayPct, weekPct)
            }
        }

        guard let drift = biggestDrift else { return nil }

        let appName = shortAppName(drift.app)
        return JournalSignal(
            icon: "arrow.triangle.swap",
            title: "Today leaned into \(appName)",
            detail: "\(drift.todayPct)% of today’s words came from \(appName), versus \(drift.weekPct)% across the rest of the week.",
            priority: 40,
            kind: .streamDrift
        )
    }

    // MARK: - Expansion alert

    /// Counts distinct new topic labels that appeared recently but weren't in earlier days.
    private static func expansionAlert(from days: [JournalDay]) -> JournalSignal? {
        guard days.count >= 4 else { return nil }

        let splitPoint = days.count / 2
        let earlier = Array(days.prefix(splitPoint))
        let recent = Array(days.suffix(from: splitPoint))

        let earlierTopics = Set(earlier.flatMap { topicLabels($0) })
        let recentTopics = Set(recent.flatMap { topicLabels($0) })

        let newTopics = recentTopics.subtracting(earlierTopics)

        if newTopics.count >= 3 {
            let examples = Array(newTopics)
                .sorted()
                .prefix(3)
                .map(Self.displayTopicLabel)
            let exampleText = exampleList(examples)
            return JournalSignal(
                icon: "arrow.up.right.and.arrow.down.left",
                title: newTopics.count >= 8
                    ? "Work expanded into many new topics"
                    : "\(newTopics.count) new topics appeared",
                detail: "These topic labels showed up in the last few days but not earlier in the week\(exampleText)",
                priority: 60,
                kind: .expansionAlert
            )
        }

        return nil
    }

    // MARK: - Intensity (today vs average)

    /// Compares today's output to the rolling average.
    private static func intensitySignal(from days: [JournalDay]) -> JournalSignal? {
        guard days.count >= 3 else { return nil }

        let today = days.last!
        let todayWords = totalWords(today)
        guard todayWords > 0 else { return nil }

        let previous = Array(days.dropLast())
        let prevWords = previous.map { totalWords($0) }
        let avg = prevWords.reduce(0, +) / max(prevWords.count, 1)
        guard avg > 0 else { return nil }

        let ratio = Double(todayWords) / Double(avg)

        if ratio >= 2.5 {
            return JournalSignal(
                icon: "bolt.fill",
                title: "Very full day",
                detail: "You logged \(formatted(todayWords)) words today, about \(String(format: "%.0f", ratio))x your recent average.",
                priority: 70,
                kind: .highDay
            )
        }

        if ratio <= 0.3 && todayWords < 200 {
            return JournalSignal(
                icon: "moon.zzz",
                title: "Quiet day",
                detail: "You logged \(formatted(todayWords)) words today versus a \(formatted(avg))-word recent average.",
                priority: 30,
                kind: .lowDay
            )
        }

        return nil
    }

    // MARK: - Context switching

    /// Counts app/topic transitions across today's blocks. Many switches = fragmented attention.
    private static func contextSwitchingSignal(from days: [JournalDay]) -> JournalSignal? {
        guard let today = days.last else { return nil }
        let blocks = today.blocks
            .filter { $0.isMeeting != true }
            .sorted { $0.startTime < $1.startTime }
        guard blocks.count >= 3 else { return nil }

        var switches = 0
        for i in 1..<blocks.count {
            let prev = blocks[i - 1].topicLabel ?? blocks[i - 1].bundleId
            let curr = blocks[i].topicLabel ?? blocks[i].bundleId
            if prev != curr { switches += 1 }
        }

        if switches >= 10 {
            return JournalSignal(
                icon: "arrow.triangle.2.circlepath",
                title: "Highly fragmented day",
                detail: "\(switches) context switches across your blocks today. Your attention was pulled in many directions.",
                priority: 65,
                kind: .contextSwitching
            )
        }

        if switches >= 6 {
            return JournalSignal(
                icon: "arrow.triangle.2.circlepath",
                title: "\(switches) context switches",
                detail: "More topic-hopping than usual. Consider batching similar work together.",
                priority: 35,
                kind: .contextSwitching
            )
        }

        return nil
    }

    // MARK: - Deep work

    /// Detects notably long unbroken focus blocks (non-meeting).
    private static func deepWorkSignal(from days: [JournalDay]) -> JournalSignal? {
        guard let today = days.last else { return nil }
        let blocks = today.blocks.filter { $0.isMeeting != true }
        guard !blocks.isEmpty else { return nil }

        let longest = blocks.max(by: {
            $0.endTime.timeIntervalSince($0.startTime) < $1.endTime.timeIntervalSince($1.startTime)
        })!

        let minutes = Int(longest.endTime.timeIntervalSince(longest.startTime) / 60)
        guard minutes >= 90 else { return nil }

        let topic = longest.topicLabel ?? shortAppName(longest.appName)
        return JournalSignal(
            icon: "target",
            title: "\(minutes)min deep session",
            detail: "Your longest unbroken focus block today was on \(topic). Sessions this long are rare.",
            priority: 75,
            kind: .deepWork
        )
    }

    // MARK: - Meeting load

    /// Flags when meetings consume a large share of the day.
    private static func meetingLoadSignal(from days: [JournalDay]) -> JournalSignal? {
        guard let today = days.last else { return nil }
        let meetings = today.blocks.filter { $0.isMeeting == true }
        guard !meetings.isEmpty else { return nil }

        let meetingMinutes = meetings.reduce(0.0) {
            $0 + ($1.meetingDurationSeconds ?? $1.endTime.timeIntervalSince($1.startTime))
        } / 60

        if meetingMinutes >= 180 {
            return JournalSignal(
                icon: "person.3",
                title: "Meeting-heavy day",
                detail: "\(Int(meetingMinutes))min across \(meetings.count) meeting\(meetings.count == 1 ? "" : "s"). That's a big chunk of focus time gone.",
                priority: 60,
                kind: .meetingLoad
            )
        }

        if meetings.count >= 4 {
            return JournalSignal(
                icon: "person.3",
                title: "\(meetings.count) meetings today",
                detail: "\(Int(meetingMinutes))min total. Frequent meetings fragment the gaps between them too.",
                priority: 40,
                kind: .meetingLoad
            )
        }

        return nil
    }

    // MARK: - Communication heavy

    private static let communicationBundleIds: Set<String> = [
        "com.tinyspeck.slackmacgap",
        "com.apple.MobileSMS",
        "com.apple.mail",
        "com.microsoft.Outlook",
        "com.hnc.Discord",
        "com.readdle.smartemail",
    ]

    /// Flags when messaging and email apps dominate the day's output.
    private static func communicationSignal(from days: [JournalDay]) -> JournalSignal? {
        guard let today = days.last else { return nil }
        let total = totalWords(today)
        guard total > 50 else { return nil }

        let commWords = today.blocks
            .filter { communicationBundleIds.contains($0.bundleId) }
            .reduce(0) { $0 + $1.wordCount }
        let pct = Int(Double(commWords) / Double(total) * 100)

        guard pct >= 50 else { return nil }
        return JournalSignal(
            icon: "bubble.left.and.bubble.right",
            title: "Communication-heavy day",
            detail: "\(pct)% of today's output was in messaging and email. Less room for heads-down work.",
            priority: 45,
            kind: .communicationHeavy
        )
    }

    // MARK: - Late session

    /// Flags activity extending past 9 PM.
    private static func lateSessionSignal(from days: [JournalDay]) -> JournalSignal? {
        guard let today = days.last else { return nil }
        let blocks = today.blocks.sorted { $0.endTime < $1.endTime }
        guard let lastBlock = blocks.last else { return nil }

        let hour = Calendar.current.component(.hour, from: lastBlock.endTime)
        guard hour >= 21 else { return nil }

        let topic = lastBlock.topicLabel ?? shortAppName(lastBlock.appName)
        return JournalSignal(
            icon: "moon.stars",
            title: "Late session",
            detail: "You were still on \(topic) past 9 PM.",
            priority: 25,
            kind: .lateSession
        )
    }

    // MARK: - Topic focus / scatter

    /// Detects laser-focused days (1–2 topics) or highly scattered days (6+).
    private static func topicFocusSignal(from days: [JournalDay]) -> JournalSignal? {
        guard let today = days.last else { return nil }
        let topics = today.blocks
            .filter { $0.isMeeting != true }
            .compactMap { $0.topicLabel?.lowercased() }
        guard topics.count >= 3 else { return nil }

        let unique = Set(topics)
        let dominant = Dictionary(grouping: topics, by: { $0 })
            .max(by: { $0.value.count < $1.value.count })

        if unique.count <= 2 && topics.count >= 4 {
            let name = dominant.map { displayTopicLabel($0.key) } ?? "one area"
            return JournalSignal(
                icon: "scope",
                title: "Laser-focused day",
                detail: "Almost all your work concentrated on \(name).",
                priority: 55,
                kind: .topicFocus
            )
        }

        if unique.count >= 6 {
            return JournalSignal(
                icon: "square.grid.3x3",
                title: "Scattered across \(unique.count) topics",
                detail: "Attention spread wide today — could be coordination work, or difficulty finding traction.",
                priority: 45,
                kind: .topicFocus
            )
        }

        return nil
    }

    // MARK: - Day character

    private static let codeBundleIds: Set<String> = [
        "com.microsoft.VSCode",
        "com.apple.dt.Xcode",
        "dev.zed.Zed",
        "com.jetbrains.intellij",
        "com.sublimetext.4",
        "com.googlecode.iterm2",
        "com.apple.Terminal",
        "net.kovidgoyal.kitty",
    ]

    private static let browserBundleIds: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.brave.Browser",
        "org.mozilla.firefox",
        "company.thebrowser.Browser",
        "com.nickvision.browser",
    ]

    /// Labels today as a "builder day" (code-heavy) or "research day" (browser-heavy).
    private static func dayCharacterSignal(from days: [JournalDay]) -> JournalSignal? {
        guard let today = days.last else { return nil }
        let total = totalWords(today)
        guard total > 80 else { return nil }

        let codeWords = today.blocks
            .filter { codeBundleIds.contains($0.bundleId) }
            .reduce(0) { $0 + $1.wordCount }
        let browserWords = today.blocks
            .filter { browserBundleIds.contains($0.bundleId) }
            .reduce(0) { $0 + $1.wordCount }

        let codePct = Double(codeWords) / Double(total) * 100
        let browserPct = Double(browserWords) / Double(total) * 100

        if codePct >= 60 {
            return JournalSignal(
                icon: "chevron.left.forwardslash.chevron.right",
                title: "Builder day",
                detail: "\(Int(codePct))% of today was in code editors and terminals.",
                priority: 40,
                kind: .dayCharacter
            )
        }

        if browserPct >= 60 {
            return JournalSignal(
                icon: "globe",
                title: "Research day",
                detail: "\(Int(browserPct))% of today was in the browser — exploring, reviewing, or reading.",
                priority: 40,
                kind: .dayCharacter
            )
        }

        return nil
    }

    // MARK: - Meeting trend

    /// Detects when meeting minutes are climbing across the week.
    private static func meetingTrendSignal(from days: [JournalDay]) -> JournalSignal? {
        guard days.count >= 4 else { return nil }

        let meetingMinutesPerDay = days.map { day -> Double in
            day.blocks
                .filter { $0.isMeeting == true }
                .reduce(0.0) { $0 + ($1.meetingDurationSeconds ?? $1.endTime.timeIntervalSince($1.startTime)) } / 60
        }

        let half = meetingMinutesPerDay.count / 2
        let firstHalf = Array(meetingMinutesPerDay.prefix(half))
        let secondHalf = Array(meetingMinutesPerDay.suffix(half))

        let firstAvg = firstHalf.isEmpty ? 0 : firstHalf.reduce(0, +) / Double(firstHalf.count)
        let secondAvg = secondHalf.isEmpty ? 0 : secondHalf.reduce(0, +) / Double(secondHalf.count)

        guard secondAvg > firstAvg + 30, secondAvg > 60 else { return nil }

        return JournalSignal(
            icon: "chart.line.uptrend.xyaxis",
            title: "Meetings are climbing",
            detail: "Recent days averaged \(Int(secondAvg))min of meetings, up from \(Int(firstAvg))min earlier in the week.",
            priority: 50,
            kind: .meetingTrend
        )
    }

    // MARK: - Helpers

    private static func totalWords(_ day: JournalDay) -> Int {
        day.blocks.reduce(0) { $0 + $1.wordCount }
    }

    private static func topicLabels(_ day: JournalDay) -> [String] {
        day.blocks.compactMap { $0.topicLabel?.lowercased() }
            .filter { !$0.isEmpty && $0.count >= 4 }
    }

    /// Returns app name → percentage of words for a single day.
    private static func appDistribution(_ day: JournalDay) -> [String: Int] {
        let total = totalWords(day)
        guard total > 0 else { return [:] }
        var byApp: [String: Int] = [:]
        for block in day.blocks {
            byApp[block.appName, default: 0] += block.wordCount
        }
        return byApp.mapValues { Int(Double($0) / Double(total) * 100) }
    }

    /// Returns app name → percentage of words across multiple days.
    private static func appDistribution(_ days: [JournalDay]) -> [String: Int] {
        let total = days.reduce(0) { $0 + totalWords($1) }
        guard total > 0 else { return [:] }
        var byApp: [String: Int] = [:]
        for day in days {
            for block in day.blocks {
                byApp[block.appName, default: 0] += block.wordCount
            }
        }
        return byApp.mapValues { Int(Double($0) / Double(total) * 100) }
    }

    private static func shortAppName(_ name: String) -> String {
        let mapping = [
            "Brave Browser": "Browser",
            "Google Chrome": "Chrome",
            "Visual Studio Code": "Code",
        ]
        return mapping[name] ?? name
    }

    private static func formatted(_ n: Int) -> String {
        n.formatted()
    }

    private static func displayTopicLabel(_ label: String) -> String {
        label
            .split(separator: " ")
            .map { word in
                guard let first = word.first else { return String(word) }
                return String(first).uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }

    private static func exampleList<S: Sequence>(_ examples: S) -> String where S.Element == String {
        let items = Array(examples)
        guard !items.isEmpty else { return "." }
        return ": " + items.joined(separator: ", ") + "."
    }
}
