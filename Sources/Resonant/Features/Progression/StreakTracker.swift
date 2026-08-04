import Foundation
import Defaults
import Observation

extension Defaults.Keys {
    static let streakLastDictationDate = Key<Date?>("streakLastDictationDate", default: nil, suite: AppDefaults.suite)
    static let streakCurrentCount      = Key<Int>("streakCurrentCount",        default: 0, suite: AppDefaults.suite)
    static let streakHighWater         = Key<Int>("streakHighWater",           default: 0, suite: AppDefaults.suite)
}

/// Tracks hot streaks: consecutive dictations within a 5-minute window.
/// Also tracks day streaks.
@MainActor
@Observable
final class StreakTracker {

    // Hot streak: consecutive dictations within 5 min
    private(set) var hotStreakCount: Int = 0
    var pendingStreakExpression: ExpressionType?

    private static let hotStreakWindowSeconds: TimeInterval = 300
    private static let hotStreakMilestones = [6, 10, 15, 20, 30]

    func recordDictation() {
        let now = Date()
        let last = Defaults[.streakLastDictationDate]
        Defaults[.streakLastDictationDate] = now

        // Hot streak detection
        if let last, now.timeIntervalSince(last) < Self.hotStreakWindowSeconds {
            hotStreakCount += 1
        } else {
            hotStreakCount = 1
        }

        if Self.hotStreakMilestones.contains(hotStreakCount) {
            pendingStreakExpression = .hotStreak(count: hotStreakCount)
        }

        // Day streak
        updateDayStreak(now: now, last: last)
    }

    func clearWorkspaceData() {
        hotStreakCount = 0
        pendingStreakExpression = nil
        Defaults[.streakLastDictationDate] = nil
        Defaults[.streakCurrentCount] = 0
        Defaults[.streakHighWater] = 0
    }

    // MARK: - Day streak

    var dayStreak: Int { Defaults[.statsStreakDays] }

    private func updateDayStreak(now: Date, last: Date?) {
        guard let last else {
            Defaults[.statsStreakDays] = 1
            return
        }
        let calendar = Calendar.current
        let lastDay = calendar.startOfDay(for: last)
        let today = calendar.startOfDay(for: now)
        let daysSince = calendar.dateComponents([.day], from: lastDay, to: today).day ?? 0

        if daysSince == 0 {
            // Same day — no change
        } else if daysSince == 1 {
            // Consecutive day
            let newStreak = Defaults[.statsStreakDays] + 1
            Defaults[.statsStreakDays] = newStreak
            if newStreak > Defaults[.statsLongestStreakDays] {
                Defaults[.statsLongestStreakDays] = newStreak
            }
        } else {
            // Streak broken
            Defaults[.statsStreakDays] = 1
        }
    }
}
