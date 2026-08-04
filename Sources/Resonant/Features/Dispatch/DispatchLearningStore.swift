import Foundation
import os

struct DispatchSurfaceFingerprint: Codable, Hashable, Sendable {
    var surfaceKind: String?
    var fieldKind: String?
    var appName: String?
    var bundleId: String?
    var siteHost: String?
    var urlPathToken: String?
    var windowTitleToken: String?
    var fieldContentToken: String?
    var nearbyTextToken: String?
    var conversationLabel: String?
    var documentLabelToken: String?
    var projectLabel: String?
    var codeFileName: String?
    var slackRecipient: String?
    var axRole: String?
    var axSubrole: String?
    var axIdentifierToken: String?
    var axTitleToken: String?
    var axDescriptionToken: String?
    var axPlaceholderToken: String?
    var axHelpToken: String?
    var axFrameBucket: String?
    var axSelectedRangeBucket: String?
    var axIsSensitiveInput: Bool? = nil

    var hasAXTarget: Bool {
        [
            axRole,
            axSubrole,
            axIdentifierToken,
            axTitleToken,
            axDescriptionToken,
            axPlaceholderToken,
            axHelpToken,
            axFrameBucket,
            axSelectedRangeBucket
        ].contains { $0 != nil }
    }

    func matchScore(against other: DispatchSurfaceFingerprint) -> Double {
        var matched = 0.0
        var possible = 0.0

        func add<T: Equatable>(_ lhs: T?, _ rhs: T?, weight: Double) {
            guard lhs != nil || rhs != nil else { return }
            possible += weight
            if lhs != nil, lhs == rhs {
                matched += weight
            }
        }

        func addWhenBoth<T: Equatable>(_ lhs: T?, _ rhs: T?, weight: Double) {
            guard let lhs, let rhs else { return }
            possible += weight
            if lhs == rhs {
                matched += weight
            }
        }

        add(bundleId, other.bundleId, weight: 0.26)
        add(siteHost, other.siteHost, weight: 0.2)
        add(projectLabel, other.projectLabel, weight: 0.14)
        add(conversationLabel, other.conversationLabel, weight: 0.12)
        add(slackRecipient, other.slackRecipient, weight: 0.12)
        add(windowTitleToken, other.windowTitleToken, weight: 0.08)
        add(fieldKind, other.fieldKind, weight: 0.05)
        add(surfaceKind, other.surfaceKind, weight: 0.03)
        addWhenBoth(axIdentifierToken, other.axIdentifierToken, weight: 0.18)
        addWhenBoth(axPlaceholderToken, other.axPlaceholderToken, weight: 0.12)
        addWhenBoth(axTitleToken, other.axTitleToken, weight: 0.1)
        addWhenBoth(axDescriptionToken, other.axDescriptionToken, weight: 0.08)
        addWhenBoth(axHelpToken, other.axHelpToken, weight: 0.06)
        addWhenBoth(axFrameBucket, other.axFrameBucket, weight: 0.05)
        addWhenBoth(axSubrole, other.axSubrole, weight: 0.04)
        addWhenBoth(axRole, other.axRole, weight: 0.03)

        guard possible > 0 else { return 0 }
        return matched / possible
    }

    func axTargetMatchScore(against other: DispatchSurfaceFingerprint) -> Double {
        var matched = 0.0
        var possible = 0.0

        func add<T: Equatable>(_ lhs: T?, _ rhs: T?, weight: Double) {
            guard let lhs, let rhs else { return }
            possible += weight
            if lhs == rhs {
                matched += weight
            }
        }

        add(axIdentifierToken, other.axIdentifierToken, weight: 0.24)
        add(axPlaceholderToken, other.axPlaceholderToken, weight: 0.18)
        add(axTitleToken, other.axTitleToken, weight: 0.16)
        add(axDescriptionToken, other.axDescriptionToken, weight: 0.13)
        add(axHelpToken, other.axHelpToken, weight: 0.09)
        add(axFrameBucket, other.axFrameBucket, weight: 0.08)
        add(axSubrole, other.axSubrole, weight: 0.06)
        add(axRole, other.axRole, weight: 0.04)
        add(axSelectedRangeBucket, other.axSelectedRangeBucket, weight: 0.02)

        guard possible > 0 else { return hasAXTarget == other.hasAXTarget ? 1 : 0 }
        return matched / possible
    }
}

struct DispatchLearningBinding: Codable, Identifiable, Sendable {
    var id: UUID
    var commandPattern: String
    var commandTokens: [String]
    var surface: DispatchSurfaceFingerprint
    var routeCard: DispatchRouteCard
    var action: CommandAction?
    var confidence: Double
    var successCount: Int
    var failureCount: Int
    var createdAt: Date
    var lastUpdatedAt: Date

    var isUsable: Bool {
        action != nil && confidence >= 0.62 && successCount > failureCount
    }
}

struct DispatchLearningOutcome: Codable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case success
        case failure
    }

    var id: UUID
    var timestamp: Date
    var commandPattern: String
    var routeCardID: String
    var routeIntent: String
    var surface: DispatchSurfaceFingerprint
    var kind: Kind
    var resultSummary: String
}

enum DispatchCorrectionKind: String, Codable, Sendable {
    case positive
    case negative
    case preferCurrentSurface
    case forgetLast
}

enum DispatchRouteSource: String, Codable, Sendable, Equatable {
    case learnedBinding = "learned_binding"
    case deterministicLocal = "deterministic_local"
    case cloudClassifier = "cloud_classifier"
    case cloudAction = "cloud_action"
    case localFallback = "local_fallback"
    case explicitAction = "explicit_action"
    case correction = "correction"
}

enum DispatchFailureStage: String, Codable, Sendable, Equatable {
    case localResolution = "local_resolution"
    case cloudClassification = "cloud_classification"
    case responseParsing = "response_parsing"
    case targetGuard = "target_guard"
    case actionExecution = "action_execution"
    case verification = "verification"
    case correction = "correction"
}

struct DispatchTargetCheck: Codable, Sendable, Equatable {
    var required: Bool
    var expectedAXTarget: Bool
    var currentAXTarget: Bool
    var matchScore: Double?
    var minimumScore: Double?
    var summary: String?
}

struct DispatchCorrectionResult: Sendable {
    var kind: DispatchCorrectionKind
    var feedback: String
    var success: Bool
}

struct DispatchLogEntry: Codable, Identifiable, Sendable {
    var id: UUID
    var timestamp: Date
    var command: String
    var commandPattern: String
    var routeCard: DispatchRouteCard
    var action: CommandAction?
    var actionSummary: String?
    var confidence: Double
    var evidence: [String]
    var surface: DispatchSurfaceFingerprint
    var resultSuccess: Bool
    var resultSummary: String
    var learnedBindingID: UUID?
    var correctionKind: DispatchCorrectionKind?
    var routeSource: DispatchRouteSource? = nil
    var routeReason: String? = nil
    var failureStage: DispatchFailureStage? = nil
    var targetCheck: DispatchTargetCheck? = nil
    var correctedLogID: UUID? = nil
}

struct DispatchSpeechProfile: Codable, Sendable {
    var observedTurns: Int
    var averageUtteranceSeconds: Double
    var averageTrailingSilenceSeconds: Double

    static let empty = DispatchSpeechProfile(
        observedTurns: 0,
        averageUtteranceSeconds: 4.0,
        averageTrailingSilenceSeconds: 1.1
    )
}

@MainActor
final class DispatchLearningStore {
    private static let log = Logger.resonant("DispatchLearning")

    private struct State: Codable {
        var bindings: [DispatchLearningBinding]
        var outcomes: [DispatchLearningOutcome]
        var logs: [DispatchLogEntry]
        var speechProfile: DispatchSpeechProfile

        init(
            bindings: [DispatchLearningBinding],
            outcomes: [DispatchLearningOutcome],
            logs: [DispatchLogEntry],
            speechProfile: DispatchSpeechProfile
        ) {
            self.bindings = bindings
            self.outcomes = outcomes
            self.logs = logs
            self.speechProfile = speechProfile
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            bindings = try container.decodeIfPresent([DispatchLearningBinding].self, forKey: .bindings) ?? []
            outcomes = try container.decodeIfPresent([DispatchLearningOutcome].self, forKey: .outcomes) ?? []
            logs = try container.decodeIfPresent([DispatchLogEntry].self, forKey: .logs) ?? []
            speechProfile = try container.decodeIfPresent(DispatchSpeechProfile.self, forKey: .speechProfile) ?? .empty
        }

        static let empty = State(
            bindings: [],
            outcomes: [],
            logs: [],
            speechProfile: .empty
        )
    }

    private var state: State
    private let storageURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(storageURL: URL = DispatchLearningStore.defaultStorageURL()) {
        self.storageURL = storageURL
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        state = Self.load(from: storageURL, decoder: decoder)
    }

    var bindingsForTesting: [DispatchLearningBinding] {
        state.bindings
    }

    var speechProfileForTesting: DispatchSpeechProfile {
        state.speechProfile
    }

    var logsForTesting: [DispatchLogEntry] {
        state.logs
    }

    var recommendedFollowUpTrailingSilence: TimeInterval {
        let learned = state.speechProfile.averageTrailingSilenceSeconds * 1.35
        return min(2.4, max(1.05, learned))
    }

    var followUpOpenWindow: TimeInterval {
        let learned = state.speechProfile.averageUtteranceSeconds * 1.6
        return min(9.0, max(5.5, learned))
    }

    func bestBinding(
        command: String,
        contextPacket: ContextPacket?,
        snapshots: [DispatchRouteSnapshot]
    ) -> DispatchLearningBinding? {
        if DispatchLocalActionResolver.deterministicAction(for: command) != nil {
            return nil
        }

        let commandTokens = Self.commandTokens(for: command)
        guard !commandTokens.isEmpty else { return nil }

        let surface = Self.surfaceFingerprint(contextPacket: contextPacket, snapshots: snapshots)
        guard surface.axIsSensitiveInput != true else { return nil }
        let now = Date()

        return state.bindings
            .filter(\.isUsable)
            .compactMap { binding -> (DispatchLearningBinding, Double)? in
                guard binding.surface.axIsSensitiveInput != true else { return nil }
                let commandScore = Self.jaccard(commandTokens, binding.commandTokens)
                let surfaceScore = binding.surface.matchScore(against: surface)
                if binding.surface.hasAXTarget, surface.hasAXTarget {
                    let targetScore = binding.surface.axTargetMatchScore(against: surface)
                    guard targetScore >= 0.52 else { return nil }
                }
                let ageSeconds = max(0, now.timeIntervalSince(binding.lastUpdatedAt))
                let recencyBonus = max(0, 1 - (ageSeconds / (14 * 24 * 60 * 60))) * 0.05
                let score = commandScore * 0.48 + surfaceScore * 0.37 + binding.confidence * 0.15 + recencyBonus

                guard score >= 0.64,
                      commandScore >= 0.42 || surfaceScore >= 0.72 else {
                    return nil
                }
                return (binding, score)
            }
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 {
                    return lhs.0.lastUpdatedAt > rhs.0.lastUpdatedAt
                }
                return lhs.1 > rhs.1
            }
            .first?
            .0
    }

    func recordOutcome(
        command: String,
        contextPacket: ContextPacket?,
        snapshots: [DispatchRouteSnapshot],
        route: DispatchRouteResolution,
        result: CommandActionResult,
        failureStage: DispatchFailureStage? = nil,
        targetCheck: DispatchTargetCheck? = nil,
        allowBindingUpdate: Bool = true
    ) {
        let surface = Self.surfaceFingerprint(contextPacket: contextPacket, snapshots: snapshots)
        let commandTokens = Self.commandTokens(for: command)
        guard !commandTokens.isEmpty else { return }
        var shouldUpdateBinding = allowBindingUpdate && surface.axIsSensitiveInput != true

        let now = Date()
        let kind: DispatchLearningOutcome.Kind = result.success ? .success : .failure
        let pattern = commandTokens.joined(separator: " ")
        let outcome = DispatchLearningOutcome(
            id: UUID(),
            timestamp: now,
            commandPattern: pattern,
            routeCardID: route.card.id,
            routeIntent: route.card.intent.rawValue,
            surface: surface,
            kind: kind,
            resultSummary: result.summary
        )
        state.outcomes.append(outcome)
        if state.outcomes.count > 300 {
            state.outcomes.removeFirst(state.outcomes.count - 300)
        }

        state.logs.append(DispatchLogEntry(
            id: UUID(),
            timestamp: now,
            command: command,
            commandPattern: pattern,
            routeCard: route.card,
            action: route.action,
            actionSummary: Self.actionSummary(route.action),
            confidence: route.confidence,
            evidence: Array(route.evidence.prefix(8)),
            surface: surface,
            resultSuccess: result.success,
            resultSummary: result.summary,
            learnedBindingID: route.learnedBindingID,
            correctionKind: nil,
            routeSource: route.source,
            routeReason: route.reason,
            failureStage: result.success ? nil : failureStage ?? .actionExecution,
            targetCheck: targetCheck,
            correctedLogID: nil
        ))
        trimLogs()

        guard let action = route.action else {
            save()
            return
        }
        guard shouldUpdateBinding else {
            save()
            return
        }
        let reward = result.success ? 0.14 : -0.22
        if let index = state.bindings.firstIndex(where: { binding in
            binding.routeCard.id == route.card.id
                && binding.commandPattern == pattern
                && binding.surface.matchScore(against: surface) >= 0.72
        }) {
            state.bindings[index].confidence = Self.clamp(
                state.bindings[index].confidence + reward + (route.confidence * 0.03),
                min: 0.05,
                max: 0.98
            )
            if result.success {
                state.bindings[index].successCount += 1
            } else {
                state.bindings[index].failureCount += 1
            }
            state.bindings[index].action = action
            state.bindings[index].routeCard = route.card
            state.bindings[index].lastUpdatedAt = now
        } else {
            let initialConfidence = Self.clamp(
                (route.confidence * 0.68) + (result.success ? 0.18 : -0.12),
                min: 0.12,
                max: 0.86
            )
            state.bindings.append(DispatchLearningBinding(
                id: UUID(),
                commandPattern: pattern,
                commandTokens: commandTokens,
                surface: surface,
                routeCard: route.card,
                action: action,
                confidence: initialConfidence,
                successCount: result.success ? 1 : 0,
                failureCount: result.success ? 0 : 1,
                createdAt: now,
                lastUpdatedAt: now
            ))
        }

        state.bindings = state.bindings
            .sorted {
                if $0.confidence == $1.confidence {
                    return $0.lastUpdatedAt > $1.lastUpdatedAt
                }
                return $0.confidence > $1.confidence
            }
        if state.bindings.count > 120 {
            state.bindings.removeLast(state.bindings.count - 120)
        }

        save()
    }

    func recordGuardFailure(
        command: String,
        contextPacket: ContextPacket?,
        snapshots: [DispatchRouteSnapshot],
        route: DispatchRouteResolution,
        binding: DispatchLearningBinding,
        summary: String,
        targetCheck: DispatchTargetCheck? = nil
    ) {
        let surface = Self.surfaceFingerprint(contextPacket: contextPacket, snapshots: snapshots)
        let commandTokens = Self.commandTokens(for: command)
        let pattern = commandTokens.joined(separator: " ")

        state.logs.append(DispatchLogEntry(
            id: UUID(),
            timestamp: Date(),
            command: command,
            commandPattern: pattern,
            routeCard: route.card,
            action: route.action,
            actionSummary: Self.actionSummary(route.action),
            confidence: route.confidence,
            evidence: Array((["Target guard blocked active-surface execution."] + route.evidence).prefix(8)),
            surface: surface,
            resultSuccess: false,
            resultSummary: summary,
            learnedBindingID: route.learnedBindingID ?? binding.id,
            correctionKind: nil,
            routeSource: route.source,
            routeReason: route.reason,
            failureStage: .targetGuard,
            targetCheck: targetCheck ?? DispatchTargetCheck(
                required: true,
                expectedAXTarget: binding.surface.hasAXTarget,
                currentAXTarget: surface.hasAXTarget,
                matchScore: binding.surface.hasAXTarget && surface.hasAXTarget
                    ? binding.surface.axTargetMatchScore(against: surface)
                    : nil,
                minimumScore: DispatchTargetGuard.minimumAXTargetScore,
                summary: summary
            ),
            correctedLogID: nil
        ))
        trimLogs()
        save()
    }

    func applyCorrection(
        command: String,
        contextPacket: ContextPacket?,
        snapshots: [DispatchRouteSnapshot]
    ) -> DispatchCorrectionResult? {
        guard let kind = Self.correctionKind(for: command) else { return nil }
        let now = Date()
        let currentSurface = Self.surfaceFingerprint(contextPacket: contextPacket, snapshots: snapshots)

        guard let latest = state.logs.last(where: { $0.action != nil && $0.correctionKind == nil }) else {
            let feedback = "I don't have a recent Dispatch action to correct."
            appendCorrectionLog(
                command: command,
                kind: kind,
                feedback: feedback,
                success: false,
                timestamp: now,
                surface: currentSurface,
                latest: nil
            )
            save()
            return DispatchCorrectionResult(kind: kind, feedback: feedback, success: false)
        }

        let feedback: String
        let success: Bool

        switch kind {
        case .positive:
            adjustBinding(for: latest, confidenceDelta: 0.18, successDelta: 1, failureDelta: 0)
            feedback = "Got it. I marked that Dispatch route as right."
            success = true

        case .negative:
            adjustBinding(for: latest, confidenceDelta: -0.3, successDelta: 0, failureDelta: 1)
            feedback = "Got it. I marked that Dispatch route as wrong."
            success = true

        case .preferCurrentSurface:
            guard let action = latest.action else {
                feedback = "I couldn't bind that route to the current surface."
                success = false
                break
            }
            upsertBinding(
                commandPattern: latest.commandPattern,
                commandTokens: Self.commandTokens(for: latest.command),
                surface: currentSurface,
                routeCard: latest.routeCard,
                action: action,
                confidence: max(0.78, latest.confidence),
                successDelta: 1,
                failureDelta: 0,
                timestamp: now
            )
            feedback = "Got it. I'll prefer this current surface for that kind of command."
            success = true

        case .forgetLast:
            removeBinding(for: latest)
            feedback = "Forgot the last Dispatch route."
            success = true
        }

        appendCorrectionLog(
            command: command,
            kind: kind,
            feedback: feedback,
            success: success,
            timestamp: now,
            surface: currentSurface,
            latest: latest
        )
        save()
        return DispatchCorrectionResult(kind: kind, feedback: feedback, success: success)
    }

    func recentLogs(limit: Int = 20) -> [DispatchLogEntry] {
        Array(state.logs.suffix(max(0, limit)).reversed())
    }

    func recentBindings(limit: Int = 20) -> [DispatchLearningBinding] {
        Array(state.bindings.prefix(max(0, limit)))
    }

    func binding(id: UUID) -> DispatchLearningBinding? {
        state.bindings.first { $0.id == id }
    }

    func recordSpeechTurn(utteranceDuration: TimeInterval, trailingSilence: TimeInterval) {
        let duration = min(45, max(0.4, utteranceDuration))
        let silence = min(3.0, max(0.5, trailingSilence))
        let alpha = state.speechProfile.observedTurns == 0 ? 1.0 : 0.18

        state.speechProfile.averageUtteranceSeconds =
            (state.speechProfile.averageUtteranceSeconds * (1 - alpha)) + (duration * alpha)
        state.speechProfile.averageTrailingSilenceSeconds =
            (state.speechProfile.averageTrailingSilenceSeconds * (1 - alpha)) + (silence * alpha)
        state.speechProfile.observedTurns += 1
        save()
    }

    static func surfaceFingerprint(
        contextPacket: ContextPacket?,
        snapshots: [DispatchRouteSnapshot]
    ) -> DispatchSurfaceFingerprint {
        let surface = contextPacket?.surface
        let target = contextPacket?.targetFingerprint
        let snapshot = snapshots.first
        let url = surface?.browserURL ?? snapshot?.browserURL
        let parsedURL = url.flatMap(URL.init(string:))
        let visibleText = contextPacket?.visibleGroundingSnippets.first
            ?? snapshot?.visibleTextSnippets.first
            ?? snapshot?.browserTabs.first

        return DispatchSurfaceFingerprint(
            surfaceKind: surface?.kind.rawValue,
            fieldKind: surface?.fieldKind.rawValue,
            appName: Self.normalizedPlain(surface?.appName ?? snapshot?.appName),
            bundleId: Self.normalizedPlain(surface?.bundleId ?? snapshot?.bundleId),
            siteHost: Self.normalizedHost(surface?.siteHost ?? parsedURL?.host(percentEncoded: false)),
            urlPathToken: Self.stableToken(parsedURL?.path),
            windowTitleToken: Self.stableToken(surface?.windowTitle ?? snapshot?.windowTitle),
            fieldContentToken: Self.stableToken(contextPacket?.focusedFieldPreview ?? snapshot?.focusedFieldContent),
            nearbyTextToken: Self.stableToken(visibleText),
            conversationLabel: Self.normalizedPlain(surface?.conversationLabel ?? snapshot?.slackRecipient),
            documentLabelToken: Self.stableToken(surface?.documentLabel),
            projectLabel: Self.normalizedPlain(surface?.projectLabel),
            codeFileName: Self.normalizedPlain(snapshot?.codeFileName),
            slackRecipient: Self.normalizedPlain(snapshot?.slackRecipient),
            axRole: target?.role,
            axSubrole: target?.subrole,
            axIdentifierToken: target?.identifierToken,
            axTitleToken: target?.titleToken,
            axDescriptionToken: target?.descriptionToken,
            axPlaceholderToken: target?.placeholderToken,
            axHelpToken: target?.helpToken,
            axFrameBucket: target?.frameBucket,
            axSelectedRangeBucket: target?.selectedRangeBucket,
            axIsSensitiveInput: target?.isSensitiveInput
        )
    }

    static func commandTokens(for command: String) -> [String] {
        let normalized = command
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
        let rawTokens = normalized
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        let stopwords: Set<String> = [
            "a", "an", "and", "are", "can", "could", "do", "for", "from", "get",
            "give", "go", "i", "in", "it", "me", "my", "of", "on", "or", "please",
            "that", "the", "this", "to", "use", "with", "you"
        ]
        return Array(rawTokens
            .filter { $0.count > 1 && !stopwords.contains($0) }
            .prefix(16))
    }

    static func correctionKind(for command: String) -> DispatchCorrectionKind? {
        let normalized = command
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()

        if containsAny(normalized, [
            "forget that",
            "don't remember that",
            "dont remember that",
            "do not remember that",
            "clear that route"
        ]) {
            return .forgetLast
        }

        if containsAny(normalized, [
            "use this text box",
            "use this textbox",
            "use this box",
            "use this field",
            "use this target",
            "use current text box",
            "use current textbox",
            "use current field",
            "use current target",
            "use this page",
            "use this window",
            "use here",
            "yes here",
            "yeah here",
            "right here",
            "this one",
            "always use this",
            "bind this"
        ]) {
            return .preferCurrentSurface
        }

        if containsAny(normalized, [
            "that was right",
            "that is right",
            "that's right",
            "thats right",
            "that was good",
            "that worked",
            "worked correctly",
            "correct route",
            "yes correct",
            "yes that's correct"
        ]) {
            return .positive
        }

        if containsAny(normalized, [
            "not there",
            "wrong place",
            "wrong route",
            "that was wrong",
            "that's wrong",
            "thats wrong",
            "incorrect",
            "not what i wanted",
            "not the right",
            "no not",
            "don't do that",
            "dont do that"
        ]) {
            return .negative
        }

        return nil
    }

    private func save() {
        guard let data = try? encoder.encode(state) else { return }
        do {
            try FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: storageURL, options: .atomic)
        } catch {
            Self.log.error("Failed to save dispatch learning: \(error.localizedDescription, privacy: .public)")
        }
    }

    private nonisolated static func load(from url: URL, decoder: JSONDecoder) -> State {
        guard let data = try? Data(contentsOf: url),
              let state = try? decoder.decode(State.self, from: data) else {
            return .empty
        }
        return state
    }

    private nonisolated static func defaultStorageURL() -> URL {
        AppSupportPaths.resonantRoot()
            .appendingPathComponent("dispatch_learning.json")
    }

    private static func normalizedPlain(_ value: String?) -> String? {
        let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
        guard let normalized, !normalized.isEmpty else { return nil }
        return String(normalized.prefix(80))
    }

    private static func normalizedHost(_ value: String?) -> String? {
        normalizedPlain(value)?.replacingOccurrences(of: #"^www\."#, with: "", options: .regularExpression)
    }

    private static func stableToken(_ value: String?) -> String? {
        guard let normalized = normalizedPlain(value) else { return nil }
        return String(Self.fnv1a64(normalized), radix: 16)
    }

    private static func fnv1a64(_ value: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    private static func jaccard(_ lhs: [String], _ rhs: [String]) -> Double {
        let left = Set(lhs)
        let right = Set(rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let intersection = left.intersection(right).count
        let union = left.union(right).count
        return Double(intersection) / Double(union)
    }

    private static func clamp(_ value: Double, min lower: Double, max upper: Double) -> Double {
        Swift.min(upper, Swift.max(lower, value))
    }

    private func adjustBinding(
        for log: DispatchLogEntry,
        confidenceDelta: Double,
        successDelta: Int,
        failureDelta: Int
    ) {
        guard let index = bindingIndex(for: log) else { return }
        state.bindings[index].confidence = Self.clamp(
            state.bindings[index].confidence + confidenceDelta,
            min: 0.05,
            max: 0.98
        )
        state.bindings[index].successCount += successDelta
        state.bindings[index].failureCount += failureDelta
        state.bindings[index].lastUpdatedAt = Date()
    }

    private func upsertBinding(
        commandPattern: String,
        commandTokens: [String],
        surface: DispatchSurfaceFingerprint,
        routeCard: DispatchRouteCard,
        action: CommandAction,
        confidence: Double,
        successDelta: Int,
        failureDelta: Int,
        timestamp: Date
    ) {
        if let index = state.bindings.firstIndex(where: { binding in
            binding.commandPattern == commandPattern
                && binding.routeCard.id == routeCard.id
                && binding.surface.matchScore(against: surface) >= 0.72
        }) {
            state.bindings[index].surface = surface
            state.bindings[index].action = action
            state.bindings[index].routeCard = routeCard
            state.bindings[index].confidence = Self.clamp(
                max(state.bindings[index].confidence, confidence) + 0.08,
                min: 0.05,
                max: 0.98
            )
            state.bindings[index].successCount += successDelta
            state.bindings[index].failureCount += failureDelta
            state.bindings[index].lastUpdatedAt = timestamp
            return
        }

        state.bindings.append(DispatchLearningBinding(
            id: UUID(),
            commandPattern: commandPattern,
            commandTokens: commandTokens,
            surface: surface,
            routeCard: routeCard,
            action: action,
            confidence: Self.clamp(confidence, min: 0.05, max: 0.98),
            successCount: successDelta,
            failureCount: failureDelta,
            createdAt: timestamp,
            lastUpdatedAt: timestamp
        ))
    }

    private func removeBinding(for log: DispatchLogEntry) {
        state.bindings.removeAll { binding in
            binding.commandPattern == log.commandPattern
                && binding.routeCard.id == log.routeCard.id
                && binding.surface.matchScore(against: log.surface) >= 0.72
        }
    }

    private func bindingIndex(for log: DispatchLogEntry) -> Int? {
        state.bindings.firstIndex { binding in
            binding.commandPattern == log.commandPattern
                && binding.routeCard.id == log.routeCard.id
                && binding.surface.matchScore(against: log.surface) >= 0.72
        }
    }

    private func appendCorrectionLog(
        command: String,
        kind: DispatchCorrectionKind,
        feedback: String,
        success: Bool,
        timestamp: Date,
        surface: DispatchSurfaceFingerprint,
        latest: DispatchLogEntry?
    ) {
        let tokens = Self.commandTokens(for: command)
        state.logs.append(DispatchLogEntry(
            id: UUID(),
            timestamp: timestamp,
            command: command,
            commandPattern: tokens.joined(separator: " "),
            routeCard: latest?.routeCard ?? DispatchRouteCard(
                id: "dispatch.correction",
                intent: .cloudClassification,
                title: "Dispatch correction",
                surface: "Last Dispatch route",
                action: "Apply correction",
                validator: "Learning store updated",
                disturbance: .background
            ),
            action: latest?.action,
            actionSummary: latest?.actionSummary,
            confidence: latest?.confidence ?? 0,
            evidence: latest?.evidence ?? [],
            surface: surface,
            resultSuccess: success,
            resultSummary: feedback,
            learnedBindingID: latest?.learnedBindingID,
            correctionKind: kind,
            routeSource: .correction,
            routeReason: latest == nil
                ? "User correction had no recent Dispatch action to update."
                : "User correction applied to the latest Dispatch action.",
            failureStage: success ? nil : .correction,
            targetCheck: nil,
            correctedLogID: latest?.id
        ))
        trimLogs()
    }

    private func trimLogs() {
        if state.logs.count > 200 {
            state.logs.removeFirst(state.logs.count - 200)
        }
    }

    static func actionSummary(_ action: CommandAction?) -> String? {
        guard let action else { return nil }
        switch action {
        case .typeText(_, let appHint):
            return "type_text\(appHint.map { ":\($0)" } ?? "")"
        case .openURL(let url):
            return "open_url:\(URL(string: url)?.host(percentEncoded: false) ?? "url")"
        case .openApp(let name):
            return "open_app:\(name)"
        case .searchWorkspace:
            return "search_workspace"
        case .speakAnswer:
            return "speak_answer"
        case .createTicket(_, _, let service):
            return "create_ticket:\(service.rawValue)"
        case .postSlack(let channel, _):
            return "post_slack:\(channel)"
        case .delegateToAgent(let agent, _, _):
            return "delegate_agent:\(agent.rawValue)"
        case .composite(let actions):
            return "composite:\(actions.count)"
        }
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }
}
