import AppKit
import Foundation

enum DispatchTrialStatus: String, Codable, Sendable, CaseIterable {
    case active
    case completed
    case abandoned
}

enum DispatchTrialOutcome: String, Codable, Sendable, CaseIterable {
    case worked
    case wrongApp = "wrong_app"
    case wrongTarget = "wrong_target"
    case nothingHappened = "nothing_happened"
    case tooSlow = "too_slow"
    case badTranscript = "bad_transcript"
    case silentFailure = "silent_failure"
    case micFailed = "mic_failed"
    case other

    var displayName: String {
        switch self {
        case .worked: "Worked"
        case .wrongApp: "Wrong app"
        case .wrongTarget: "Wrong target"
        case .nothingHappened: "Nothing happened"
        case .tooSlow: "Too slow"
        case .badTranscript: "Bad transcript"
        case .silentFailure: "Silent failure"
        case .micFailed: "Mic failed"
        case .other: "Other"
        }
    }
}

enum DispatchTrialFailureLabel: String, Codable, Sendable, CaseIterable, Hashable {
    case commandBusy = "command_busy"
    case modelNotReady = "model_not_ready"
    case micStartFailed = "mic_start_failed"
    case emptyTranscript = "empty_transcript"
    case badTranscript = "bad_transcript"
    case transcriptionFailed = "transcription_failed"
    case wrongRoute = "wrong_route"
    case wrongApp = "wrong_app"
    case wrongTarget = "wrong_target"
    case targetGuard = "target_guard"
    case localResolutionFailed = "local_resolution_failed"
    case cloudFailed = "cloud_failed"
    case executorFailed = "executor_failed"
    case verificationFailed = "verification_failed"
    case tooSlow = "too_slow"
    case silent = "silent"
    case cancelled
    case unknown
}

enum DispatchTrialAutomaticVerdict: String, Codable, Sendable, CaseIterable {
    case passed
    case failed
    case inconclusive

    var displayName: String {
        switch self {
        case .passed: "Auto passed"
        case .failed: "Auto failed"
        case .inconclusive: "Auto inconclusive"
        }
    }
}

struct DispatchTrialAutomaticVerification: Codable, Sendable, Equatable {
    var verdict: DispatchTrialAutomaticVerdict
    var summary: String
    var failureLabels: [DispatchTrialFailureLabel]
    var evidence: [String: String]
    var checkedAt: Date
}

struct DispatchTrialVerificationProbe: Sendable, Equatable {
    var frontmostAppName: String?
    var frontmostBundleID: String?
    var clipboardString: String?
    var checkedAt: Date

    init(
        frontmostAppName: String?,
        frontmostBundleID: String?,
        clipboardString: String?,
        checkedAt: Date = Date()
    ) {
        self.frontmostAppName = frontmostAppName
        self.frontmostBundleID = frontmostBundleID
        self.clipboardString = clipboardString
        self.checkedAt = checkedAt
    }
}

struct DispatchTrialExpected: Codable, Sendable, Equatable {
    var routeID: String?
    var action: String?
    var observable: String
    var failureLabels: [DispatchTrialFailureLabel]
}

struct DispatchTrialScenario: Codable, Identifiable, Sendable, Equatable {
    var id: String
    var category: String
    var say: String
    var preconditions: [String]
    var expected: DispatchTrialExpected
}

struct DispatchTrialEvent: Codable, Identifiable, Sendable, Equatable {
    var id: UUID
    var timestamp: Date
    var kind: String
    var message: String
    var payload: [String: String]

    init(kind: String, message: String, payload: [String: String] = [:], timestamp: Date = Date()) {
        self.id = UUID()
        self.timestamp = timestamp
        self.kind = kind
        self.message = message
        self.payload = payload
    }
}

struct DispatchTrialContextSummary: Codable, Sendable, Equatable {
    var appName: String?
    var bundleID: String?
    var windowTitle: String?
    var browserURL: String?
    var surfaceKind: String?
    var fieldKind: String?
    var hasAXTarget: Bool
    var targetRole: String?
    var targetPlaceholder: String?
}

struct DispatchTrialRouteSummary: Codable, Sendable, Equatable {
    var routeID: String
    var intent: String
    var source: String
    var confidence: Double
    var surface: String
    var reason: String
}

struct DispatchTrialRecord: Codable, Identifiable, Sendable, Equatable {
    var id: UUID
    var scenarioID: String?
    var scenarioCategory: String?
    var prompt: String
    var preconditions: [String]
    var expected: DispatchTrialExpected?
    var status: DispatchTrialStatus
    var startedAt: Date
    var updatedAt: Date
    var completedAt: Date?
    var transcript: String?
    var routedCommand: String?
    var targetApplicationName: String?
    var context: DispatchTrialContextSummary?
    var route: DispatchTrialRouteSummary?
    var actionLine: String?
    var resultSummary: String?
    var resultDetail: String?
    var resultSuccess: Bool?
    var userOutcome: DispatchTrialOutcome?
    var userNotes: String?
    var automaticVerification: DispatchTrialAutomaticVerification?
    var failureLabels: [DispatchTrialFailureLabel]
    var latencyMs: [String: Int]
    var events: [DispatchTrialEvent]
}

@MainActor
final class DispatchTrialStore {
    static let scenarios: [DispatchTrialScenario] = [
        DispatchTrialScenario(
            id: "open-slack-basic",
            category: "open_app",
            say: "open Slack",
            preconditions: ["Any app can be frontmost."],
            expected: DispatchTrialExpected(
                routeID: "app.open.slack",
                action: "open_app",
                observable: "Slack becomes the frontmost app.",
                failureLabels: [.badTranscript, .wrongRoute, .wrongApp, .executorFailed, .silent]
            )
        ),
        DispatchTrialScenario(
            id: "open-discord-basic",
            category: "open_app",
            say: "open Discord",
            preconditions: ["Any app can be frontmost."],
            expected: DispatchTrialExpected(
                routeID: "app.open.discord",
                action: "open_app",
                observable: "Discord becomes the frontmost app.",
                failureLabels: [.badTranscript, .wrongRoute, .wrongApp, .executorFailed, .silent]
            )
        ),
        DispatchTrialScenario(
            id: "open-linear-basic",
            category: "open_app",
            say: "open Linear",
            preconditions: ["Any app can be frontmost."],
            expected: DispatchTrialExpected(
                routeID: "app.open.linear",
                action: "open_app",
                observable: "Linear opens or becomes frontmost.",
                failureLabels: [.badTranscript, .wrongRoute, .wrongApp, .executorFailed, .silent]
            )
        ),
        DispatchTrialScenario(
            id: "linear-ticket-draft",
            category: "ticket",
            say: "create a Linear ticket to fix dispatch silent failures",
            preconditions: ["Any app can be frontmost."],
            expected: DispatchTrialExpected(
                routeID: "ticket.linear",
                action: "create_ticket",
                observable: "Linear opens and the ticket draft is copied to the clipboard.",
                failureLabels: [.badTranscript, .wrongRoute, .executorFailed, .verificationFailed, .silent]
            )
        ),
        DispatchTrialScenario(
            id: "devin-current-workspace",
            category: "agent",
            say: "ask Devin to investigate the current workspace",
            preconditions: ["A Conductor or project workspace should be in recent context."],
            expected: DispatchTrialExpected(
                routeID: nil,
                action: "delegate_agent",
                observable: "Devin opens and the task prompt with local context is copied.",
                failureLabels: [.badTranscript, .wrongRoute, .executorFailed, .verificationFailed, .silent]
            )
        ),
        DispatchTrialScenario(
            id: "devon-asr-agent",
            category: "agent",
            say: "ask Devon to fix the current dispatch bug",
            preconditions: ["Any app can be frontmost. This tests Devin/Devon ASR normalization."],
            expected: DispatchTrialExpected(
                routeID: nil,
                action: "delegate_agent",
                observable: "The command routes to Devin, not an unknown app or no-op.",
                failureLabels: [.badTranscript, .wrongRoute, .executorFailed, .silent]
            )
        ),
        DispatchTrialScenario(
            id: "write-current-field",
            category: "text",
            say: "write testing dispatch here",
            preconditions: ["Place focus in a safe text field first."],
            expected: DispatchTrialExpected(
                routeID: "active.text",
                action: "type_text",
                observable: "The focused text field receives 'testing dispatch'.",
                failureLabels: [.badTranscript, .wrongRoute, .wrongTarget, .targetGuard, .executorFailed, .silent]
            )
        ),
        DispatchTrialScenario(
            id: "reply-recent-notification",
            category: "context",
            say: "reply to that saying I am on it",
            preconditions: ["Trigger or record a recent Slack/Discord/Gmail notification and focus the matching reply field."],
            expected: DispatchTrialExpected(
                routeID: "active.text",
                action: "type_text",
                observable: "The matching reply field receives 'I am on it'.",
                failureLabels: [.badTranscript, .wrongRoute, .wrongTarget, .targetGuard, .executorFailed, .silent]
            )
        )
    ]

    private(set) var activeTrial: DispatchTrialRecord?
    private(set) var recentTrials: [DispatchTrialRecord]
    let logURL: URL

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private static let ioQueue = DispatchQueue(label: "com.resonance.resonant.dispatch-trial-store.io", qos: .utility)

    init(logURL: URL = DispatchTrialStore.defaultLogURL()) {
        self.logURL = logURL
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        Self.flushPendingWrites()
        recentTrials = Self.loadRecentTrials(from: logURL, decoder: decoder)
        activeTrial = recentTrials.first(where: { $0.status == .active && $0.userOutcome == nil })
    }

    func beginNextScenario() -> DispatchTrialRecord {
        let completedScenarioCount = recentTrials.filter { $0.scenarioID != nil && $0.transcript != nil }.count
        let scenario = Self.scenarios[completedScenarioCount % Self.scenarios.count]
        return beginScenario(id: scenario.id) ?? beginAdHoc(prompt: scenario.say)
    }

    func beginScenario(id: String) -> DispatchTrialRecord? {
        guard let scenario = Self.scenarios.first(where: { $0.id == id }) else { return nil }
        let record = DispatchTrialRecord(
            id: UUID(),
            scenarioID: scenario.id,
            scenarioCategory: scenario.category,
            prompt: scenario.say,
            preconditions: scenario.preconditions,
            expected: scenario.expected,
            status: .active,
            startedAt: Date(),
            updatedAt: Date(),
            completedAt: nil,
            transcript: nil,
            routedCommand: nil,
            targetApplicationName: nil,
            context: nil,
            route: nil,
            actionLine: nil,
            resultSummary: nil,
            resultDetail: nil,
            resultSuccess: nil,
            userOutcome: nil,
            userNotes: nil,
            automaticVerification: nil,
            failureLabels: [],
            latencyMs: [:],
            events: [
                DispatchTrialEvent(
                    kind: "trial_prompt",
                    message: "Say: \(scenario.say)",
                    payload: ["scenario_id": scenario.id, "expected_observable": scenario.expected.observable]
                )
            ]
        )
        upsertAndAppend(record)
        activeTrial = record
        return record
    }

    func beginAdHoc(prompt: String) -> DispatchTrialRecord {
        let record = DispatchTrialRecord(
            id: UUID(),
            scenarioID: nil,
            scenarioCategory: "ad_hoc",
            prompt: prompt,
            preconditions: [],
            expected: nil,
            status: .active,
            startedAt: Date(),
            updatedAt: Date(),
            completedAt: nil,
            transcript: nil,
            routedCommand: nil,
            targetApplicationName: nil,
            context: nil,
            route: nil,
            actionLine: nil,
            resultSummary: nil,
            resultDetail: nil,
            resultSuccess: nil,
            userOutcome: nil,
            userNotes: nil,
            automaticVerification: nil,
            failureLabels: [],
            latencyMs: [:],
            events: [DispatchTrialEvent(kind: "trial_prompt", message: "Ad-hoc trial: \(prompt)")]
        )
        upsertAndAppend(record)
        activeTrial = record
        return record
    }

    @discardableResult
    func startCommandTrace(
        transcript: String,
        routedCommand: String? = nil,
        contextPacket: ContextPacket?,
        targetApplicationName: String?,
        recordingStartedAt: Date?
    ) -> UUID {
        var record = activeTrial ?? beginAdHoc(prompt: transcript)
        let now = Date()
        record.status = .active
        record.updatedAt = now
        record.transcript = transcript
        record.routedCommand = routedCommand
        record.context = contextPacket.map(Self.contextSummary)
        record.targetApplicationName = targetApplicationName
        if let recordingStartedAt {
            record.latencyMs["recording_to_transcript"] = max(0, Int(now.timeIntervalSince(recordingStartedAt) * 1000))
        }
        record.events.append(DispatchTrialEvent(
            kind: "transcript",
            message: transcript,
            payload: [
                "target_app": targetApplicationName ?? "",
                "has_context": contextPacket == nil ? "false" : "true"
            ]
        ))
        upsertAndAppend(record)
        activeTrial = record
        return record.id
    }

    func recordProgress(_ progress: DispatchCommandProgress, trialID: UUID) {
        guard var record = record(id: trialID) else { return }
        switch progress {
        case .routeSelected(let route):
            record.route = DispatchTrialRouteSummary(
                routeID: route.card.id,
                intent: route.card.intent.rawValue,
                source: route.source.rawValue,
                confidence: route.confidence,
                surface: route.card.surface,
                reason: route.reason
            )
            record.events.append(DispatchTrialEvent(
                kind: "route_selected",
                message: "\(route.card.id) via \(route.source.rawValue)",
                payload: [
                    "intent": route.card.intent.rawValue,
                    "confidence": String(format: "%.2f", route.confidence),
                    "surface": route.card.surface,
                    "reason": route.reason
                ]
            ))
        case .planSelected(let plan):
            record.events.append(DispatchTrialEvent(
                kind: "plan_selected",
                message: plan.planLine,
                payload: [
                    "target_surface": plan.targetSurface,
                    "execution_strategy": plan.executionStrategy.rawValue,
                    "verification_strategy": plan.verificationStrategy.rawValue,
                    "repair_strategy": plan.repairStrategy.rawValue,
                    "capability_status": plan.capabilityStatus.rawValue,
                    "requires_clarification": plan.requiresClarification ? "true" : "false",
                    "requires_api": plan.requiresAPI ? "true" : "false",
                    "requires_active_target": plan.requiresActiveTarget ? "true" : "false",
                    "surface_app": plan.surfaceKind?.rawValue ?? "",
                    "surface_variant": plan.surfaceVariant?.rawValue ?? "",
                    "fallback": plan.fallback ?? "",
                    "capability_summary": plan.capabilitySummary ?? ""
                ]
            ))
        case .actionStarted(let actionLine):
            record.actionLine = actionLine
            record.events.append(DispatchTrialEvent(kind: "action_started", message: actionLine))
        case .result(let summary, let success):
            record.resultSummary = summary
            record.resultSuccess = success
            if !success {
                record.failureLabels = Self.unique(record.failureLabels + [failureLabel(from: summary)])
            }
            record.events.append(DispatchTrialEvent(
                kind: "result",
                message: summary,
                payload: ["success": success ? "true" : "false"]
            ))
        }
        record.updatedAt = Date()
        upsertAndAppend(record)
        activeTrial = record.status == .active ? record : activeTrial
    }

    func finishCommandTrace(trialID: UUID, result: CommandResult, totalLatencyMs: Int) {
        guard var record = record(id: trialID) else { return }
        record.status = .completed
        record.completedAt = Date()
        record.updatedAt = record.completedAt ?? Date()
        record.resultSummary = result.actionResult?.summary ?? result.feedback
        record.resultDetail = result.actionResult?.detail
        record.resultSuccess = result.actionResult?.success ?? false
        record.latencyMs["total"] = totalLatencyMs
        if record.resultSuccess == false {
            record.failureLabels = Self.unique(record.failureLabels + [failureLabel(from: result.feedback)])
        }
        record.events.append(DispatchTrialEvent(
            kind: "command_finished",
            message: result.feedback,
            payload: [
                "success": (record.resultSuccess == true) ? "true" : "false",
                "should_speak": result.shouldSpeak ? "true" : "false"
            ]
        ))
        upsertAndAppend(record)
        activeTrial = nil
    }

    @discardableResult
    func recordAutomaticVerification(
        trialID: UUID,
        probe: DispatchTrialVerificationProbe? = nil
    ) -> DispatchTrialRecord? {
        guard var record = record(id: trialID) else { return nil }
        let verification = Self.automaticVerification(
            for: record,
            probe: probe ?? Self.currentVerificationProbe()
        )
        record.automaticVerification = verification
        record.updatedAt = verification.checkedAt
        if verification.verdict == .failed {
            record.failureLabels = Self.unique(record.failureLabels + verification.failureLabels)
        }
        record.events.append(DispatchTrialEvent(
            kind: "automatic_verification",
            message: verification.summary,
            payload: [
                "verdict": verification.verdict.rawValue,
                "labels": verification.failureLabels.map(\.rawValue).joined(separator: ",")
            ],
            timestamp: verification.checkedAt
        ))
        upsertAndAppend(record)
        if activeTrial?.id == trialID {
            activeTrial = record.status == .active ? record : nil
        }
        return record
    }

    func recordSystemFailure(
        label: DispatchTrialFailureLabel,
        message: String,
        targetApplicationName: String? = nil
    ) {
        var record = activeTrial ?? beginAdHoc(prompt: "Dispatch system failure")
        record.status = .completed
        record.completedAt = Date()
        record.updatedAt = record.completedAt ?? Date()
        record.targetApplicationName = targetApplicationName
        record.resultSuccess = false
        record.resultSummary = message
        record.failureLabels = Self.unique(record.failureLabels + [label])
        record.events.append(DispatchTrialEvent(
            kind: "system_failure",
            message: message,
            payload: ["label": label.rawValue, "target_app": targetApplicationName ?? ""]
        ))
        upsertAndAppend(record)
        activeTrial = nil
    }

    func markOutcome(
        trialID: UUID? = nil,
        outcome: DispatchTrialOutcome,
        notes: String? = nil
    ) -> DispatchTrialRecord? {
        let targetID = trialID ?? activeTrial?.id ?? recentTrials.first?.id
        guard let targetID, var record = record(id: targetID) else { return nil }
        record.userOutcome = outcome
        record.userNotes = notes
        record.updatedAt = Date()
        if outcome != .worked {
            record.failureLabels = Self.unique(record.failureLabels + failureLabels(for: outcome))
        }
        record.events.append(DispatchTrialEvent(
            kind: "user_outcome",
            message: outcome.displayName,
            payload: ["notes": notes ?? ""]
        ))
        upsertAndAppend(record)
        if activeTrial?.id == targetID {
            activeTrial = nil
        }
        return record
    }

    func payload(
        limit: Int = 20,
        includeScenarios: Bool = true,
        privacy: DispatchDiagnosticPrivacy = .redacted
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "log_path": .string(privacy.isRedacted ? "[redacted]" : logURL.path),
            "active": activeTrial.map { Self.payload(for: $0, privacy: privacy) } ?? .null,
            "recent": .array(recentTrials.prefix(max(0, limit)).map { Self.payload(for: $0, privacy: privacy) })
        ]
        if includeScenarios {
            object["scenarios"] = .array(Self.scenarios.map(Self.payload(for:)))
        }
        return .object(object)
    }

    static func outcome(fromSpokenCommand command: String) -> DispatchTrialOutcome? {
        let normalized = command
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let prefixes = [
            "mark that as ",
            "mark it as ",
            "that was ",
            "it was ",
            "that ",
            "it "
        ]
        let compact = prefixes.reduce(normalized) { current, prefix in
            current.hasPrefix(prefix) ? String(current.dropFirst(prefix.count)) : current
        }

        switch compact {
        case "worked", "works", "correct", "right", "successful", "success":
            return .worked
        case "wrong app", "wrong application", "opened wrong app":
            return .wrongApp
        case "wrong target", "wrong box", "wrong field", "wrong text field":
            return .wrongTarget
        case "nothing happened", "did nothing", "no op", "noop":
            return .nothingHappened
        case "too slow", "slow", "laggy":
            return .tooSlow
        case "bad transcript", "wrong transcript", "transcribed wrong", "bad transcription":
            return .badTranscript
        case "silent", "silent failure", "failed silently":
            return .silentFailure
        case "mic failed", "microphone failed", "microphone problem", "mic problem":
            return .micFailed
        default:
            return nil
        }
    }

    static func automaticVerification(
        for record: DispatchTrialRecord,
        probe: DispatchTrialVerificationProbe
    ) -> DispatchTrialAutomaticVerification {
        let kind = verificationKind(for: record)
        var evidence: [String: String] = [
            "result_success": record.resultSuccess.map { $0 ? "true" : "false" } ?? "unknown",
            "frontmost_app": probe.frontmostAppName ?? "",
            "frontmost_bundle_id": probe.frontmostBundleID ?? "",
            "clipboard_length": "\(probe.clipboardString?.count ?? 0)"
        ]
        var failures: [DispatchTrialFailureLabel] = []
        var positiveChecks: [String] = []
        var notes: [String] = []

        if let expectedRoute = record.expected?.routeID {
            let routeMatches = record.route?.routeID == expectedRoute
            evidence["expected_route_id"] = expectedRoute
            evidence["actual_route_id"] = record.route?.routeID ?? ""
            evidence["route_matches_expected"] = routeMatches ? "true" : "false"
            if routeMatches {
                positiveChecks.append("route matched")
            } else {
                failures.append(.wrongRoute)
                notes.append("route mismatch")
            }
        } else if let actualRoute = record.route?.routeID {
            evidence["actual_route_id"] = actualRoute
        }

        if record.scenarioID != nil, let transcript = record.transcript {
            let transcriptMatches = transcriptMatchesPrompt(transcript, prompt: record.prompt)
            evidence["transcript_matches_prompt"] = transcriptMatches ? "true" : "false"
            if transcriptMatches {
                positiveChecks.append("transcript matched")
            } else {
                failures.append(.badTranscript)
                notes.append("transcript differed from prompt")
            }
        }

        if record.resultSuccess == false {
            failures.append(contentsOf: record.failureLabels.isEmpty ? [.executorFailed] : record.failureLabels)
            notes.append("executor reported failure")
        }

        switch kind {
        case .openApp(let expectedApp):
            let matched = appMatches(
                expectedApp: expectedApp,
                actualName: probe.frontmostAppName,
                actualBundleID: probe.frontmostBundleID
            )
            evidence["expected_app"] = expectedApp
            evidence["frontmost_app_matches_expected"] = matched ? "true" : "false"
            if matched {
                positiveChecks.append("frontmost app matched")
            } else {
                failures.append(.wrongApp)
                notes.append("frontmost app did not match \(expectedApp)")
            }

        case .ticketDraft:
            let clipboard = probe.clipboardString ?? ""
            let hasTitle = containsInsensitive(clipboard, "Title:")
            let hasBody = containsInsensitive(clipboard, "Body:")
            let mentionsService = record.route?.routeID == "ticket.linear"
                ? containsInsensitive(clipboard, "linear")
                : true
            evidence["clipboard_contains_title"] = hasTitle ? "true" : "false"
            evidence["clipboard_contains_body"] = hasBody ? "true" : "false"
            evidence["clipboard_mentions_service"] = mentionsService ? "true" : "false"
            if hasTitle && hasBody && mentionsService {
                positiveChecks.append("ticket draft copied")
            } else {
                failures.append(.verificationFailed)
                notes.append("clipboard did not contain a complete ticket draft")
            }

        case .agentDelegation:
            let clipboard = probe.clipboardString ?? ""
            let expectedAgent = expectedAgent(for: record)
            let hasAgent = expectedAgent.map { containsInsensitive(clipboard, "Agent: \($0.rawValue)") } ?? true
            let hasTask = containsInsensitive(clipboard, "Task prompt:")
            if let expectedAgent {
                evidence["expected_agent"] = expectedAgent.rawValue
                evidence["clipboard_contains_agent"] = hasAgent ? "true" : "false"
            }
            evidence["clipboard_contains_task_prompt"] = hasTask ? "true" : "false"
            if hasAgent && hasTask {
                positiveChecks.append("agent prompt copied")
            } else {
                failures.append(.verificationFailed)
                notes.append("clipboard did not contain the expected agent task prompt")
            }

        case .activeText:
            if record.resultSuccess == true {
                positiveChecks.append("text delivery reported success")
                notes.append("focused field content was not re-read")
            } else {
                failures.append(.executorFailed)
            }

        case .none:
            if record.resultSuccess == true {
                positiveChecks.append("executor reported success")
            }
        }

        failures = unique(failures)
        let verdict: DispatchTrialAutomaticVerdict
        if !failures.isEmpty {
            verdict = .failed
        } else if kind.isDirectlyObservable {
            verdict = .passed
        } else if record.resultSuccess == true {
            verdict = .inconclusive
        } else {
            verdict = .failed
            failures = unique(failures + [.unknown])
        }

        let summary: String
        switch verdict {
        case .passed:
            summary = "Automatic checks passed: \(positiveChecks.joined(separator: ", "))."
        case .failed:
            let reason = notes.isEmpty ? "one or more checks failed" : notes.joined(separator: "; ")
            summary = "Automatic checks failed: \(reason)."
        case .inconclusive:
            let reason = notes.isEmpty ? "no direct observable check is available" : notes.joined(separator: "; ")
            summary = "Automatic checks inconclusive: \(reason)."
        }

        return DispatchTrialAutomaticVerification(
            verdict: verdict,
            summary: summary,
            failureLabels: failures,
            evidence: evidence,
            checkedAt: probe.checkedAt
        )
    }

    static func payloadForTool(
        _ record: DispatchTrialRecord,
        privacy: DispatchDiagnosticPrivacy = .redacted
    ) -> JSONValue {
        payload(for: record, privacy: privacy)
    }

    private func record(id: UUID) -> DispatchTrialRecord? {
        if activeTrial?.id == id {
            return activeTrial
        }
        return recentTrials.first { $0.id == id }
    }

    private func upsertAndAppend(_ record: DispatchTrialRecord) {
        if let index = recentTrials.firstIndex(where: { $0.id == record.id }) {
            recentTrials[index] = record
        } else {
            recentTrials.insert(record, at: 0)
        }
        recentTrials.sort { $0.updatedAt > $1.updatedAt }
        if recentTrials.count > 200 {
            recentTrials.removeLast(recentTrials.count - 200)
        }
        append(record)
    }

    private func append(_ record: DispatchTrialRecord) {
        do {
            let data = try encoder.encode(record)
            guard let line = String(data: data, encoding: .utf8) else { return }
            let logURL = logURL
            Self.ioQueue.async {
                do {
                    try FileManager.default.createDirectory(
                        at: logURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    if FileManager.default.fileExists(atPath: logURL.path) {
                        let handle = try FileHandle(forWritingTo: logURL)
                        try handle.seekToEnd()
                        if let lineData = (line + "\n").data(using: .utf8) {
                            try handle.write(contentsOf: lineData)
                        }
                        try handle.close()
                    } else {
                        try (line + "\n").write(to: logURL, atomically: true, encoding: .utf8)
                    }
                } catch {
                    NSLog("DispatchTrialStore append failed: \(error.localizedDescription)")
                }
            }
        } catch {
            NSLog("DispatchTrialStore append failed: \(error.localizedDescription)")
        }
    }

    private static func flushPendingWrites() {
        ioQueue.sync {}
    }

    private func failureLabel(from summary: String) -> DispatchTrialFailureLabel {
        let normalized = summary
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
        if normalized.contains("target") || normalized.contains("text box") {
            return .targetGuard
        }
        if normalized.contains("no local") || normalized.contains("matched") {
            return .localResolutionFailed
        }
        if normalized.contains("cloud") || normalized.contains("parse") {
            return .cloudFailed
        }
        if normalized.contains("cancel") {
            return .cancelled
        }
        return .executorFailed
    }

    private func failureLabels(for outcome: DispatchTrialOutcome) -> [DispatchTrialFailureLabel] {
        switch outcome {
        case .worked: []
        case .wrongApp: [.wrongApp]
        case .wrongTarget: [.wrongTarget]
        case .nothingHappened: [.silent]
        case .tooSlow: [.tooSlow]
        case .badTranscript: [.badTranscript]
        case .silentFailure: [.silent]
        case .micFailed: [.micStartFailed]
        case .other: [.unknown]
        }
    }

    private enum AutomaticVerificationKind: Equatable {
        case openApp(String)
        case ticketDraft
        case agentDelegation
        case activeText
        case none

        var isDirectlyObservable: Bool {
            switch self {
            case .openApp, .ticketDraft, .agentDelegation:
                return true
            case .activeText, .none:
                return false
            }
        }
    }

    private static func currentVerificationProbe() -> DispatchTrialVerificationProbe {
        let frontmost = NSWorkspace.shared.frontmostApplication
        return DispatchTrialVerificationProbe(
            frontmostAppName: frontmost?.localizedName,
            frontmostBundleID: frontmost?.bundleIdentifier,
            clipboardString: NSPasteboard.general.string(forType: .string)
        )
    }

    private static func verificationKind(for record: DispatchTrialRecord) -> AutomaticVerificationKind {
        if record.expected?.action == "open_app" || record.route?.intent == DispatchRouteIntent.openApp.rawValue {
            return .openApp(expectedAppName(from: record) ?? record.route?.surface ?? record.prompt)
        }
        if record.expected?.action == "create_ticket" || record.route?.intent == DispatchRouteIntent.ticketDraft.rawValue {
            return .ticketDraft
        }
        if record.expected?.action == "delegate_agent" || record.route?.intent == DispatchRouteIntent.agentDelegation.rawValue {
            return .agentDelegation
        }
        if record.expected?.action == "type_text" || record.route?.intent == DispatchRouteIntent.activeText.rawValue {
            return .activeText
        }
        return .none
    }

    private static func expectedAgent(for record: DispatchTrialRecord) -> CommandAction.AgentTarget? {
        let haystack = [
            record.prompt,
            record.transcript,
            record.routedCommand,
            record.actionLine,
            record.route?.surface,
            record.route?.reason
        ]
            .compactMap { $0 }
            .joined(separator: " ")
        let normalized = normalizedCommand(haystack)
        if normalized.contains("claude code") || normalized.contains("claude") {
            return .claudeCode
        }
        if normalized.contains("cursor") {
            return .cursor
        }
        if normalized.contains("devin") || normalized.contains("devon") {
            return .devin
        }
        return nil
    }

    private static func expectedAppName(from record: DispatchTrialRecord) -> String? {
        switch record.scenarioID {
        case "open-slack-basic":
            return "Slack"
        case "open-discord-basic":
            return "Discord"
        case "open-linear-basic":
            return "Linear"
        default:
            return nil
        }
    }

    private static func appMatches(
        expectedApp: String,
        actualName: String?,
        actualBundleID: String?
    ) -> Bool {
        let expected = normalizedToken(expectedApp)
        let actual = normalizedToken([actualName, actualBundleID].compactMap { $0 }.joined(separator: " "))

        if actual.contains(expected) {
            return true
        }

        let knownBundles: [String: Set<String>] = [
            "slack": ["com.tinyspeck.slackmacgap"],
            "discord": ["com.hnc.discord", "com.hnc.discordcanary", "com.hnc.discordptb"],
            "linear": ["com.linear", "app.linear"]
        ]
        if let actualBundleID {
            let normalizedBundle = actualBundleID.lowercased()
            if knownBundles[expected]?.contains(where: { normalizedBundle == $0 || normalizedBundle.contains($0) }) == true {
                return true
            }
        }
        return false
    }

    private static func transcriptMatchesPrompt(_ transcript: String, prompt: String) -> Bool {
        let normalizedTranscript = normalizedCommand(transcript)
        let normalizedPrompt = normalizedCommand(prompt)
        guard !normalizedPrompt.isEmpty else { return true }
        return normalizedTranscript == normalizedPrompt
            || normalizedTranscript.contains(normalizedPrompt)
            || normalizedPrompt.contains(normalizedTranscript)
    }

    private static func containsInsensitive(_ haystack: String, _ needle: String) -> Bool {
        haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private static func normalizedCommand(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedToken(_ value: String) -> String {
        normalizedCommand(value).replacingOccurrences(of: " ", with: "")
    }

    private static func contextSummary(_ contextPacket: ContextPacket) -> DispatchTrialContextSummary {
        let surface = contextPacket.surface
        return DispatchTrialContextSummary(
            appName: surface.appName,
            bundleID: surface.bundleId,
            windowTitle: surface.windowTitle,
            browserURL: surface.browserURL,
            surfaceKind: surface.kind.rawValue,
            fieldKind: surface.fieldKind.rawValue,
            hasAXTarget: contextPacket.targetFingerprint != nil,
            targetRole: contextPacket.targetFingerprint?.role,
            targetPlaceholder: contextPacket.targetFingerprint?.placeholderToken
        )
    }

    private static func loadRecentTrials(from url: URL, decoder: JSONDecoder) -> [DispatchTrialRecord] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var latestByID: [UUID: DispatchTrialRecord] = [:]
        for line in text.split(separator: "\n") {
            guard let data = String(line).data(using: .utf8),
                  let record = try? decoder.decode(DispatchTrialRecord.self, from: data) else {
                continue
            }
            latestByID[record.id] = record
        }
        return latestByID.values
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(200)
            .map { $0 }
    }

    private static func payload(for scenario: DispatchTrialScenario) -> JSONValue {
        .object([
            "id": .string(scenario.id),
            "category": .string(scenario.category),
            "say": .string(scenario.say),
            "preconditions": .array(scenario.preconditions.map { .string($0) }),
            "expected": payload(for: scenario.expected)
        ])
    }

    private static func payload(for expected: DispatchTrialExpected) -> JSONValue {
        .object([
            "route_id": expected.routeID.map { .string($0) } ?? .null,
            "action": expected.action.map { .string($0) } ?? .null,
            "observable": .string(expected.observable),
            "failure_labels": .array(expected.failureLabels.map { .string($0.rawValue) })
        ])
    }

    private static func payload(
        for record: DispatchTrialRecord,
        privacy: DispatchDiagnosticPrivacy
    ) -> JSONValue {
        .object([
            "id": .string(record.id.uuidString),
            "scenario_id": record.scenarioID.map { .string($0) } ?? .null,
            "category": record.scenarioCategory.map { .string($0) } ?? .null,
            "prompt": .string(DispatchDiagnosticRedactor.redactCommand(record.prompt, privacy: privacy)),
            "status": .string(record.status.rawValue),
            "transcript": record.transcript.map { .string(DispatchDiagnosticRedactor.redactCommand($0, privacy: privacy)) } ?? .null,
            "expected": record.expected.map(payload(for:)) ?? .null,
            "route": record.route.map { payload(for: $0, privacy: privacy) } ?? .null,
            "action_line": record.actionLine.map { .string(redactTrialDiagnostic($0, privacy: privacy)) } ?? .null,
            "result": record.resultSummary.map { .string(redactTrialDiagnostic($0, privacy: privacy)) } ?? .null,
            "success": record.resultSuccess.map { .bool($0) } ?? .null,
            "user_outcome": record.userOutcome.map { .string($0.rawValue) } ?? .null,
            "automatic_verification": record.automaticVerification.map { payload(for: $0, privacy: privacy) } ?? .null,
            "failure_labels": .array(record.failureLabels.map { .string($0.rawValue) }),
            "latency_ms": .object(record.latencyMs.mapValues { .int($0) }),
            "events": .array(record.events.suffix(12).map { payload(for: $0, privacy: privacy) })
        ])
    }

    private static func payload(
        for route: DispatchTrialRouteSummary,
        privacy: DispatchDiagnosticPrivacy
    ) -> JSONValue {
        .object([
            "id": .string(route.routeID),
            "intent": .string(route.intent),
            "source": .string(route.source),
            "confidence": .double(route.confidence),
            "surface": .string(redactTrialDiagnostic(route.surface, privacy: privacy)),
            "reason": .string(redactTrialDiagnostic(route.reason, privacy: privacy))
        ])
    }

    private static func payload(
        for verification: DispatchTrialAutomaticVerification,
        privacy: DispatchDiagnosticPrivacy
    ) -> JSONValue {
        .object([
            "verdict": .string(verification.verdict.rawValue),
            "summary": .string(redactTrialDiagnostic(verification.summary, privacy: privacy)),
            "failure_labels": .array(verification.failureLabels.map { .string($0.rawValue) }),
            "evidence": .object(verification.evidence.mapValues {
                .string(DispatchDiagnosticRedactor.redactDiagnosticText($0, privacy: privacy))
            }),
            "checked_at": .string(ISO8601DateFormatter().string(from: verification.checkedAt))
        ])
    }

    private static func payload(
        for event: DispatchTrialEvent,
        privacy: DispatchDiagnosticPrivacy
    ) -> JSONValue {
        .object([
            "timestamp": .string(ISO8601DateFormatter().string(from: event.timestamp)),
            "kind": .string(event.kind),
            "message": .string(redactTrialDiagnostic(event.message, privacy: privacy)),
            "payload": .object(event.payload.mapValues {
                .string(redactTrialDiagnostic($0, privacy: privacy))
            })
        ])
    }

    private static func redactTrialDiagnostic(
        _ value: String,
        privacy: DispatchDiagnosticPrivacy
    ) -> String {
        privacy.isRedacted ? "[redacted]" : value
    }

    private static func unique(_ labels: [DispatchTrialFailureLabel]) -> [DispatchTrialFailureLabel] {
        var seen = Set<DispatchTrialFailureLabel>()
        return labels.filter { seen.insert($0).inserted }
    }

    nonisolated static func defaultLogURL() -> URL {
        if let explicit = ProcessInfo.processInfo.environment["RESONANT_DISPATCH_TRIAL_LOG"],
           !explicit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: explicit)
        }

        let fileManager = FileManager.default
        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        let cwdContext = cwd.appendingPathComponent(".context", isDirectory: true)
        if fileManager.fileExists(atPath: cwdContext.path) {
            return cwdContext.appendingPathComponent("dispatch_trials.jsonl")
        }

        var cursor = Bundle.main.bundleURL
        for _ in 0..<12 {
            let context = cursor.appendingPathComponent(".context", isDirectory: true)
            if fileManager.fileExists(atPath: context.path) {
                return context.appendingPathComponent("dispatch_trials.jsonl")
            }
            cursor.deleteLastPathComponent()
        }

        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return support
            .appendingPathComponent("resonant", isDirectory: true)
            .appendingPathComponent("dispatch_trials.jsonl")
    }
}
