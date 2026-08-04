import Foundation
import os

/// Observes user activity patterns from the ActivityStream and ambient context
/// to suggest proactive actions. Learns routines like:
/// - "Every Monday 9am you check Linear then post standup to Slack"
/// - "After every meeting you draft a summary"
/// - "When you switch to VS Code you usually search recent dictations"
@MainActor
final class PatternInferenceEngine {

    private static let log = Logger.resonant("PatternInference")

    /// A learned pattern the engine can suggest.
    struct Pattern: Codable, Identifiable {
        let id: String
        let description: String
        let triggerCondition: TriggerCondition
        let suggestedAction: SuggestedAction
        var confidence: Double
        var observationCount: Int
        var lastTriggered: Date?
        var lastSuggested: Date?

        var isReady: Bool {
            confidence >= 0.6 && observationCount >= 3
        }
    }

    enum TriggerCondition: Codable {
        case timeOfDay(hour: Int, minute: Int, dayOfWeek: Int?)
        case afterMeeting
        case appSwitch(from: String?, to: String)
        case activitySequence(apps: [String])
    }

    struct SuggestedAction: Codable {
        let description: String
        let commandText: String
    }

    struct Suggestion: Sendable {
        let patternId: String
        let description: String
        let commandText: String
        let confidence: Double
    }

    // MARK: - State

    private var patterns: [Pattern] = []
    private var activityLog: [ActivityEntry] = []
    private let maxActivityLog = 500
    private let storageURL: URL

    private var observationTimer: Timer?
    private var isObserving = false

    struct ActivityEntry: Codable {
        let timestamp: Date
        let app: String?
        let windowTitle: String?
        let action: String?
    }

    // MARK: - Init

    init() {
        let resonantDir = AppSupportPaths.resonantRoot()
        try? FileManager.default.createDirectory(at: resonantDir, withIntermediateDirectories: true)
        storageURL = resonantDir.appendingPathComponent("dispatch_patterns.json")
        loadPatterns()
    }

    // MARK: - Observation

    func startObserving() {
        guard !isObserving else { return }
        isObserving = true

        observationTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.analyzeCurrentContext()
            }
        }

        Self.log.info("Pattern inference started")
    }

    func stopObserving() {
        observationTimer?.invalidate()
        observationTimer = nil
        isObserving = false
    }

    /// Record an activity event for pattern learning.
    func recordActivity(app: String?, windowTitle: String?, action: String?) {
        let entry = ActivityEntry(
            timestamp: Date(),
            app: app,
            windowTitle: windowTitle,
            action: action
        )
        activityLog.append(entry)
        if activityLog.count > maxActivityLog {
            activityLog.removeFirst(activityLog.count - maxActivityLog)
        }
    }

    /// Record that a meeting just ended.
    func recordMeetingEnded(title: String?) {
        recordActivity(app: nil, windowTitle: title, action: "meeting_ended")
        reinforcePattern(trigger: .afterMeeting)
    }

    /// Record an app switch event.
    func recordAppSwitch(from: String?, to: String) {
        recordActivity(app: to, windowTitle: nil, action: "app_switch")
        reinforcePattern(trigger: .appSwitch(from: from, to: to))
    }

    // MARK: - Suggestions

    /// Get suggestions relevant to the current context.
    func suggestions(
        currentApp: String?,
        currentHour: Int? = nil,
        currentDayOfWeek: Int? = nil,
        justEndedMeeting: Bool = false
    ) -> [Suggestion] {
        let now = Date()
        let calendar = Calendar.current
        let hour = currentHour ?? calendar.component(.hour, from: now)
        let dayOfWeek = currentDayOfWeek ?? calendar.component(.weekday, from: now)

        return patterns
            .filter { $0.isReady }
            .filter { pattern in
                // Don't re-suggest within 10 minutes
                if let lastSuggested = pattern.lastSuggested,
                   now.timeIntervalSince(lastSuggested) < 600 {
                    return false
                }
                return matchesTrigger(pattern.triggerCondition, hour: hour, dayOfWeek: dayOfWeek, currentApp: currentApp, justEndedMeeting: justEndedMeeting)
            }
            .sorted { $0.confidence > $1.confidence }
            .prefix(3)
            .map { pattern in
                Suggestion(
                    patternId: pattern.id,
                    description: pattern.description,
                    commandText: pattern.suggestedAction.commandText,
                    confidence: pattern.confidence
                )
            }
    }

    /// Mark a suggestion as accepted (positive reinforcement).
    func acceptSuggestion(patternId: String) {
        guard let idx = patterns.firstIndex(where: { $0.id == patternId }) else { return }
        patterns[idx].confidence = min(1.0, patterns[idx].confidence + 0.1)
        patterns[idx].lastTriggered = Date()
        patterns[idx].lastSuggested = Date()
        savePatterns()
    }

    /// Mark a suggestion as dismissed (negative reinforcement).
    func dismissSuggestion(patternId: String) {
        guard let idx = patterns.firstIndex(where: { $0.id == patternId }) else { return }
        patterns[idx].confidence = max(0.0, patterns[idx].confidence - 0.15)
        patterns[idx].lastSuggested = Date()
        savePatterns()
    }

    // MARK: - Private

    private func matchesTrigger(
        _ trigger: TriggerCondition,
        hour: Int,
        dayOfWeek: Int,
        currentApp: String?,
        justEndedMeeting: Bool
    ) -> Bool {
        switch trigger {
        case .timeOfDay(let h, let m, let dow):
            let hourMatch = hour == h
            let dowMatch = dow == nil || dow == dayOfWeek
            return hourMatch && dowMatch

        case .afterMeeting:
            return justEndedMeeting

        case .appSwitch(_, let to):
            return currentApp?.lowercased() == to.lowercased()

        case .activitySequence(let apps):
            let recentApps = activityLog.suffix(apps.count).compactMap { $0.app?.lowercased() }
            return recentApps == apps.map { $0.lowercased() }
        }
    }

    private func reinforcePattern(trigger: TriggerCondition) {
        // Find existing pattern with matching trigger
        if let idx = patterns.firstIndex(where: { triggerMatches($0.triggerCondition, trigger) }) {
            patterns[idx].observationCount += 1
            patterns[idx].confidence = min(1.0, patterns[idx].confidence + 0.05)
            savePatterns()
        }
    }

    private func triggerMatches(_ a: TriggerCondition, _ b: TriggerCondition) -> Bool {
        switch (a, b) {
        case (.afterMeeting, .afterMeeting):
            return true
        case (.appSwitch(_, let toA), .appSwitch(_, let toB)):
            return toA.lowercased() == toB.lowercased()
        case (.timeOfDay(let hA, _, let dA), .timeOfDay(let hB, _, let dB)):
            return hA == hB && dA == dB
        default:
            return false
        }
    }

    private func analyzeCurrentContext() {
        // Periodic analysis: look for repeating sequences in the activity log.
        // This runs every 60s and updates pattern confidence based on observed
        // sequences. Full ML-based inference is a post-MVP enhancement.
        guard activityLog.count >= 10 else { return }

        let recentApps = activityLog.suffix(20).compactMap { $0.app }
        let calendar = Calendar.current
        let now = Date()
        let hour = calendar.component(.hour, from: now)
        let dayOfWeek = calendar.component(.weekday, from: now)

        // Check for time-based routines: if the same app appears at the same
        // hour on multiple days, create/reinforce a time pattern.
        let sameHourEntries = activityLog.filter {
            calendar.component(.hour, from: $0.timestamp) == hour
        }
        let appCounts = Dictionary(grouping: sameHourEntries, by: { $0.app ?? "unknown" })
        for (app, entries) in appCounts where entries.count >= 3 {
            let patternId = "time_\(hour)_\(app)"
            if !patterns.contains(where: { $0.id == patternId }) {
                let pattern = Pattern(
                    id: patternId,
                    description: "You often open \(app) around \(hour):00",
                    triggerCondition: .timeOfDay(hour: hour, minute: 0, dayOfWeek: nil),
                    suggestedAction: SuggestedAction(
                        description: "Open \(app)",
                        commandText: "open \(app)"
                    ),
                    confidence: 0.4,
                    observationCount: entries.count,
                    lastTriggered: nil,
                    lastSuggested: nil
                )
                patterns.append(pattern)
                Self.log.info("Discovered time pattern: \(patternId)")
            }
        }

        savePatterns()
    }

    // MARK: - Persistence

    private func loadPatterns() {
        guard FileManager.default.fileExists(atPath: storageURL.path),
              let data = try? Data(contentsOf: storageURL),
              let loaded = try? JSONDecoder().decode([Pattern].self, from: data) else {
            return
        }
        patterns = loaded
        Self.log.info("Loaded \(self.patterns.count) patterns")
    }

    private func savePatterns() {
        guard let data = try? JSONEncoder().encode(patterns) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }
}
