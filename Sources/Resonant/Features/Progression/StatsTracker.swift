import Foundation
import Defaults
import Observation

// MARK: - Stats keys

extension Defaults.Keys {
    static let statsTotalWords        = Key<Int>("statsTotalWords",       default: 0, suite: AppDefaults.suite)
    static let statsTotalDictations   = Key<Int>("statsTotalDictations",  default: 0, suite: AppDefaults.suite)
    static let statsStreakDays        = Key<Int>("statsStreakDays",       default: 0, suite: AppDefaults.suite)
    static let statsLastUsedDate      = Key<Date?>("statsLastUsedDate",   default: nil, suite: AppDefaults.suite)
    static let statsLongestDictation  = Key<Int>("statsLongestDictation", default: 0, suite: AppDefaults.suite)
    static let statsLongestStreakDays = Key<Int>("statsLongestStreakDays", default: 0, suite: AppDefaults.suite)
}

/// Tracks cumulative usage stats and detects level-up / achievement events.
@MainActor
@Observable
final class StatsTracker {

    // Observed by UI
    var totalWords:      Int { Defaults[.statsTotalWords] }
    var totalDictations: Int { Defaults[.statsTotalDictations] }
    var streakDays:      Int { Defaults[.statsStreakDays] }
    var longestDictation: Int { Defaults[.statsLongestDictation] }

    // Time saved: assume 2× speaking speed over typing (avg 40 WPM typing)
    var minutesSaved: Double { Double(totalWords) / 40.0 }

    // Pending expression to surface in notch
    var pendingExpression: ExpressionType?

    private let levelSystem = LevelSystem()

    // MARK: - Record dictation

    /// Returns any expression events triggered by this dictation.
    @discardableResult
    func record(wordCount: Int) -> [ExpressionType] {
        let prevTotal = Defaults[.statsTotalWords]
        Defaults[.statsTotalWords]      += wordCount
        Defaults[.statsTotalDictations] += 1
        Defaults[.statsLastUsedDate]    = Date()

        if wordCount > Defaults[.statsLongestDictation] {
            Defaults[.statsLongestDictation] = wordCount
        }

        var events: [ExpressionType] = []

        // Level up?
        if let newLevel = levelSystem.didLevelUp(before: prevTotal, after: Defaults[.statsTotalWords]) {
            let event = ExpressionType.levelUp(levelName: newLevel.name)
            pendingExpression = event
            events.append(event)
        }

        // Word count milestones
        let milestones = [100, 500, 1000, 5000, 10000, 25000, 50000, 100000]
        for m in milestones {
            if prevTotal < m && Defaults[.statsTotalWords] >= m {
                let event = ExpressionType.achievement(
                    title: "\(m.formatted()) words",
                    message: "You've dictated \(m.formatted()) words total!"
                )
                if pendingExpression == nil { pendingExpression = event }
                events.append(event)
            }
        }

        return events
    }

    func clearWorkspaceData() {
        Defaults[.statsTotalWords] = 0
        Defaults[.statsTotalDictations] = 0
        Defaults[.statsStreakDays] = 0
        Defaults[.statsLastUsedDate] = nil
        Defaults[.statsLongestDictation] = 0
        Defaults[.statsLongestStreakDays] = 0
        pendingExpression = nil
    }

    // MARK: - Level info

    var currentLevel: LevelSystem.Level {
        levelSystem.level(for: totalWords)
    }

    var levelProgress: Double {
        levelSystem.progress(for: totalWords)
    }

    var nextLevel: LevelSystem.Level? {
        levelSystem.nextLevel(for: totalWords)
    }

    var wordsToNextLevel: Int? {
        guard let next = nextLevel else { return nil }
        return next.minWords - totalWords
    }
}

// MARK: - Int formatting helper

private extension Int {
    func formatted() -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: self)) ?? "\(self)"
    }
}
