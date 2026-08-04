import XCTest
@testable import Resonant

@MainActor
final class DispatchTrialStoreTests: XCTestCase {
    func testGuidedTrialRecordsProgressOutcomeAndReloads() {
        let url = temporaryURL()
        let store = DispatchTrialStore(logURL: url)
        let started = store.beginScenario(id: "open-slack-basic")

        XCTAssertEqual(started?.prompt, "open Slack")
        XCTAssertEqual(store.activeTrial?.scenarioID, "open-slack-basic")

        let trialID = store.startCommandTrace(
            transcript: "Open Slack.",
            contextPacket: contextPacket(),
            targetApplicationName: "Finder",
            recordingStartedAt: Date(timeIntervalSinceReferenceDate: 10)
        )
        let route = slackRoute()
        store.recordProgress(.routeSelected(route), trialID: trialID)
        store.recordProgress(.actionStarted(route.actionLine), trialID: trialID)
        store.finishCommandTrace(
            trialID: trialID,
            result: CommandResult(
                feedback: "Opened Slack",
                actionResult: .ok("Opened Slack"),
                shouldSpeak: false
            ),
            totalLatencyMs: 123
        )
        let marked = store.markOutcome(outcome: .worked)

        XCTAssertEqual(marked?.userOutcome, .worked)
        XCTAssertEqual(marked?.route?.routeID, "app.open.slack")
        XCTAssertEqual(marked?.latencyMs["total"], 123)

        let reloaded = DispatchTrialStore(logURL: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let latest = reloaded.recentTrials.first
        XCTAssertEqual(latest?.id, trialID)
        XCTAssertEqual(latest?.userOutcome, .worked)
        XCTAssertEqual(latest?.transcript, "Open Slack.")
        XCTAssertEqual(latest?.route?.source, "deterministic_local")
    }

    func testAutomaticVerificationPassesOpenAppWhenFrontmostMatches() {
        let store = DispatchTrialStore(logURL: temporaryURL())
        _ = store.beginScenario(id: "open-slack-basic")
        let trialID = store.startCommandTrace(
            transcript: "open Slack",
            contextPacket: contextPacket(),
            targetApplicationName: "Finder",
            recordingStartedAt: nil
        )
        let route = slackRoute()
        store.recordProgress(.routeSelected(route), trialID: trialID)
        store.finishCommandTrace(
            trialID: trialID,
            result: CommandResult(
                feedback: "Opened Slack",
                actionResult: .ok("Opened Slack"),
                shouldSpeak: false
            ),
            totalLatencyMs: 80
        )

        let verified = store.recordAutomaticVerification(
            trialID: trialID,
            probe: DispatchTrialVerificationProbe(
                frontmostAppName: "Slack",
                frontmostBundleID: "com.tinyspeck.slackmacgap",
                clipboardString: nil
            )
        )

        XCTAssertEqual(verified?.automaticVerification?.verdict, .passed)
        XCTAssertEqual(
            verified?.automaticVerification?.evidence["frontmost_app_matches_expected"],
            "true"
        )
        XCTAssertFalse(verified?.failureLabels.contains(.wrongApp) ?? true)
    }

    func testAutomaticVerificationFailsWrongRouteAndWrongFrontmostApp() {
        let store = DispatchTrialStore(logURL: temporaryURL())
        _ = store.beginScenario(id: "open-slack-basic")
        let trialID = store.startCommandTrace(
            transcript: "open Slack",
            contextPacket: contextPacket(),
            targetApplicationName: "Finder",
            recordingStartedAt: nil
        )
        let route = discordRoute()
        store.recordProgress(.routeSelected(route), trialID: trialID)
        store.finishCommandTrace(
            trialID: trialID,
            result: CommandResult(
                feedback: "Opened Discord",
                actionResult: .ok("Opened Discord"),
                shouldSpeak: false
            ),
            totalLatencyMs: 80
        )

        let verified = store.recordAutomaticVerification(
            trialID: trialID,
            probe: DispatchTrialVerificationProbe(
                frontmostAppName: "Discord",
                frontmostBundleID: "com.hnc.Discord",
                clipboardString: nil
            )
        )

        XCTAssertEqual(verified?.automaticVerification?.verdict, .failed)
        XCTAssertTrue(verified?.failureLabels.contains(.wrongRoute) ?? false)
        XCTAssertTrue(verified?.failureLabels.contains(.wrongApp) ?? false)
    }

    func testAutomaticVerificationChecksPreparedTicketClipboard() {
        let store = DispatchTrialStore(logURL: temporaryURL())
        _ = store.beginScenario(id: "linear-ticket-draft")
        let trialID = store.startCommandTrace(
            transcript: "create a Linear ticket to fix dispatch silent failures",
            contextPacket: contextPacket(),
            targetApplicationName: "Finder",
            recordingStartedAt: nil
        )
        let route = linearTicketRoute()
        store.recordProgress(.routeSelected(route), trialID: trialID)
        store.recordProgress(
            .planSelected(
                DispatchPlanner.makePlan(
                    command: "create a Linear ticket to fix dispatch silent failures",
                    route: route,
                    action: route.action!,
                    contextPacket: contextPacket(),
                    snapshots: []
                )
            ),
            trialID: trialID
        )
        store.finishCommandTrace(
            trialID: trialID,
            result: CommandResult(
                feedback: "Linear ticket ready: Fix dispatch silent failures",
                actionResult: .ok("Linear ticket ready: Fix dispatch silent failures"),
                shouldSpeak: false
            ),
            totalLatencyMs: 80
        )

        let verified = store.recordAutomaticVerification(
            trialID: trialID,
            probe: DispatchTrialVerificationProbe(
                frontmostAppName: "Linear",
                frontmostBundleID: "com.linear",
                clipboardString: "Title: Fix dispatch silent failures\nBody: Repro details for Linear"
            )
        )

        XCTAssertEqual(verified?.automaticVerification?.verdict, .passed)
        XCTAssertEqual(verified?.automaticVerification?.evidence["clipboard_contains_title"], "true")
        XCTAssertEqual(verified?.automaticVerification?.evidence["clipboard_contains_body"], "true")
        let planEvent = verified?.events.first { $0.kind == "plan_selected" }
        XCTAssertEqual(planEvent?.payload["capability_status"], "degraded")
        XCTAssertEqual(planEvent?.payload["requires_api"], "true")
        XCTAssertEqual(planEvent?.payload["fallback"], "clipboard ticket draft")
        XCTAssertEqual(planEvent?.payload["capability_summary"], "API needed; using clipboard ticket draft.")
    }

    func testSystemFailureCompletesActiveTrialWithNamedLabel() {
        let store = DispatchTrialStore(logURL: temporaryURL())
        _ = store.beginScenario(id: "open-slack-basic")

        store.recordSystemFailure(
            label: .micStartFailed,
            message: "Microphone unavailable",
            targetApplicationName: "Slack"
        )

        XCTAssertNil(store.activeTrial)
        let latest = store.recentTrials.first
        XCTAssertEqual(latest?.status, .completed)
        XCTAssertEqual(latest?.resultSuccess, false)
        XCTAssertEqual(latest?.failureLabels, [.micStartFailed])
        XCTAssertEqual(latest?.events.last?.kind, "system_failure")
    }

    func testPayloadIncludesScenarioQueueAndLogPath() {
        let url = temporaryURL()
        let store = DispatchTrialStore(logURL: url)
        _ = store.beginNextScenario()

        let payload = store.payload(privacy: .raw)
        let object = payload.objectValue ?? [:]

        XCTAssertEqual(object["log_path"], .string(url.path))
        XCTAssertNotNil(object["active"]?.objectValue)
        XCTAssertFalse(object["scenarios"]?.arrayValue?.isEmpty ?? true)
    }

    func testPayloadRedactsSensitiveTrialFieldsByDefault() {
        let url = temporaryURL()
        let store = DispatchTrialStore(logURL: url)
        _ = store.beginScenario(id: "open-slack-basic")
        let trialID = store.startCommandTrace(
            transcript: "open secret workspace",
            contextPacket: contextPacket(),
            targetApplicationName: "Finder",
            recordingStartedAt: nil
        )
        let route = slackRoute()
        store.recordProgress(.routeSelected(route), trialID: trialID)
        store.recordProgress(.actionStarted("Open Slack with secret details"), trialID: trialID)
        store.finishCommandTrace(
            trialID: trialID,
            result: CommandResult(
                feedback: "Opened secret workspace",
                actionResult: .ok("Opened secret workspace"),
                shouldSpeak: false
            ),
            totalLatencyMs: 80
        )

        let payload = store.payload()
        let object = payload.objectValue ?? [:]
        let recent = object["recent"]?.arrayValue?.first?.objectValue ?? [:]
        let events = recent["events"]?.arrayValue ?? []
        let transcriptEvent = events.compactMap(\.objectValue).first { $0["kind"] == .string("transcript") }

        XCTAssertEqual(object["log_path"], .string("[redacted]"))
        XCTAssertEqual(recent["prompt"], .string("[redacted command]"))
        XCTAssertEqual(recent["transcript"], .string("[redacted command]"))
        XCTAssertEqual(recent["action_line"], .string("[redacted]"))
        XCTAssertEqual(recent["result"], .string("[redacted]"))
        XCTAssertEqual(transcriptEvent?["message"], .string("[redacted]"))
    }

    func testAutomaticVerificationUsesExpectedNonDevinAgent() {
        let store = DispatchTrialStore(logURL: temporaryURL())
        let trialID = store.startCommandTrace(
            transcript: "ask Claude Code to fix dispatch",
            contextPacket: contextPacket(),
            targetApplicationName: "Finder",
            recordingStartedAt: nil
        )
        let route = claudeCodeRoute()
        store.recordProgress(.routeSelected(route), trialID: trialID)
        store.finishCommandTrace(
            trialID: trialID,
            result: CommandResult(
                feedback: "Copied Claude Code prompt",
                actionResult: .ok("Copied Claude Code prompt"),
                shouldSpeak: false
            ),
            totalLatencyMs: 80
        )

        let verified = store.recordAutomaticVerification(
            trialID: trialID,
            probe: DispatchTrialVerificationProbe(
                frontmostAppName: "Finder",
                frontmostBundleID: "com.apple.finder",
                clipboardString: "Agent: claudeCode\nTask prompt: fix dispatch"
            )
        )

        XCTAssertEqual(verified?.automaticVerification?.verdict, .passed)
        XCTAssertEqual(verified?.automaticVerification?.evidence["expected_agent"], "claudeCode")
        XCTAssertEqual(verified?.automaticVerification?.evidence["clipboard_contains_agent"], "true")
    }

    func testSpokenOutcomeParserHandlesNaturalFeedback() {
        XCTAssertEqual(DispatchTrialStore.outcome(fromSpokenCommand: "worked"), .worked)
        XCTAssertEqual(DispatchTrialStore.outcome(fromSpokenCommand: "that was wrong target"), .wrongTarget)
        XCTAssertEqual(DispatchTrialStore.outcome(fromSpokenCommand: "nothing happened."), .nothingHappened)
        XCTAssertEqual(DispatchTrialStore.outcome(fromSpokenCommand: "mark that as bad transcript"), .badTranscript)
        XCTAssertNil(DispatchTrialStore.outcome(fromSpokenCommand: "open Slack"))
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dispatch-trials-\(UUID().uuidString).jsonl")
    }

    private func slackRoute() -> DispatchRouteResolution {
        DispatchRouteResolution(
            card: DispatchRouteCard(
                id: "app.open.slack",
                intent: .openApp,
                title: "App switch",
                surface: "Slack",
                action: "Activate or launch app",
                validator: "macOS open request succeeded",
                disturbance: .appSwitch
            ),
            action: .openApp(name: "Slack"),
            confidence: 0.9,
            evidence: ["deterministic local"],
            source: .deterministicLocal,
            reason: "The command matched a deterministic local dispatch rule."
        )
    }

    private func discordRoute() -> DispatchRouteResolution {
        DispatchRouteResolution(
            card: DispatchRouteCard(
                id: "app.open.discord",
                intent: .openApp,
                title: "App switch",
                surface: "Discord",
                action: "Activate or launch app",
                validator: "macOS open request succeeded",
                disturbance: .appSwitch
            ),
            action: .openApp(name: "Discord"),
            confidence: 0.9,
            evidence: ["deterministic local"],
            source: .deterministicLocal,
            reason: "The command matched a deterministic local dispatch rule."
        )
    }

    private func linearTicketRoute() -> DispatchRouteResolution {
        DispatchRouteResolution(
            card: DispatchRouteCard(
                id: "ticket.linear",
                intent: .ticketDraft,
                title: "Linear ticket draft",
                surface: "Linear",
                action: "Prepare ticket payload",
                validator: "Ticket title/body prepared",
                disturbance: .preparedOnly
            ),
            action: .createTicket(title: "Fix dispatch silent failures", body: "Repro details", service: .linear),
            confidence: 0.72,
            evidence: ["ticket route"],
            source: .deterministicLocal,
            reason: "The command matched a deterministic local dispatch rule."
        )
    }

    private func claudeCodeRoute() -> DispatchRouteResolution {
        DispatchRouteResolution(
            card: DispatchRouteCard(
                id: "agent.claude_code",
                intent: .agentDelegation,
                title: "Claude Code handoff",
                surface: "Claude Code",
                action: "Copy Claude Code task prompt",
                validator: "Task prompt prepared",
                disturbance: .preparedOnly
            ),
            action: .delegateToAgent(agent: .claudeCode, prompt: "fix dispatch", context: nil),
            confidence: 0.72,
            evidence: ["agent route"],
            source: .deterministicLocal,
            reason: "The command mentioned Claude Code."
        )
    }

    private func contextPacket() -> ContextPacket {
        ContextPacket(
            id: UUID(),
            capturedAt: Date(),
            surface: SurfaceDescriptor(
                kind: .finder,
                appName: "Finder",
                bundleId: "com.apple.finder",
                windowTitle: "Desktop",
                browserURL: nil,
                siteHost: nil,
                siteName: nil,
                fieldKind: .unknown,
                conversationLabel: nil,
                documentLabel: nil,
                projectLabel: nil
            ),
            intent: DictationIntent(
                kind: .command,
                confidence: 1,
                allowsBiasTerms: true,
                allowsStyleHint: true,
                allowsSelectedTextGrounding: true,
                allowsVisibleContextGrounding: true,
                allowsMemoryGrounding: true,
                evidence: []
            ),
            entities: [],
            styleHint: nil,
            selectedTextPreview: nil,
            focusedFieldPreview: nil,
            targetFingerprint: nil,
            visibleGroundingSnippets: [],
            safetyFlags: [],
            latency: .empty
        )
    }
}
