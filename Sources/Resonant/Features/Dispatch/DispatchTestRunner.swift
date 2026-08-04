import Foundation

@MainActor
enum DispatchTestRunner {
    static func run(
        args: [String: JSONValue],
        commandRouter: CommandRouter,
        learningStore: DispatchLearningStore,
        defaultCloudFallbackEnabled: Bool
    ) async -> WorkspaceToolCallResult {
        guard let command = args["command"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty else {
            return WorkspaceToolCallResult(
                toolName: "dispatch_test_run",
                payload: .object(["message": .string("Missing required parameter: command")]),
                isError: true
            )
        }

        let execute = args["execute"]?.boolValue ?? false
        let cloudFallback = args["cloud_fallback"]?.boolValue ?? defaultCloudFallbackEnabled
        let now = Date()
        let contextPacket = contextPacket(from: args["context"]?.objectValue, now: now)
        let snapshots = (args["snapshots"]?.arrayValue ?? [])
            .compactMap { snapshot(from: $0.objectValue, now: now) }
        let startedAt = Date()

        let routeStartedAt = Date()
        let route = await resolveRoute(
            command: command,
            contextPacket: contextPacket,
            snapshots: snapshots,
            learningStore: learningStore
        )
        let routeMs = elapsedMs(since: routeStartedAt)
        let targetCheck = targetCheckPayload(
            route: route,
            contextPacket: contextPacket,
            snapshots: snapshots,
            learningStore: learningStore
        )

        var payload: [String: JSONValue] = [
            "command": .string(command),
            "mode": .string(execute ? "execute" : "dry_run"),
            "cloud_fallback": .bool(cloudFallback),
            "route": routePayload(route),
            "action": actionPayload(route.action),
            "context": contextSummaryPayload(contextPacket),
            "snapshots": .array(snapshots.map(snapshotPayload)),
            "latency_ms": .object([
                "route": .int(routeMs),
                "total": .int(elapsedMs(since: startedAt))
            ])
        ]

        let plan = route.action.map { action in
            DispatchPlanner.makePlan(
                command: command,
                route: route,
                action: action,
                contextPacket: contextPacket,
                snapshots: snapshots
            )
        }
        if let plan {
            payload["plan"] = planPayload(plan)
        }

        if let targetCheck {
            payload["target_check"] = targetCheck
        }

        if let expectation = args["expect"]?.objectValue {
            let assertions = assertionsPayload(
                expectation: expectation,
                route: route,
                action: route.action,
                plan: plan,
                result: nil
            )
            payload["assertions"] = .array(assertions.items)
            payload["passed"] = .bool(assertions.passed)
        }

        if execute {
            var events: [JSONValue] = []
            let executionStartedAt = Date()
            let result = await commandRouter.processCommand(
                transcribedText: command,
                contextPacket: contextPacket,
                onProgress: { progress in
                    events.append(progressPayload(progress, startedAt: executionStartedAt))
                },
                testSnapshots: snapshots,
                forceCloudFallback: cloudFallback
            )

            let success = result.actionResult?.success ?? false
            payload["execution"] = .object([
                "status": .string(success ? "success" : "failed"),
                "feedback": .string(result.feedback),
                "summary": result.actionResult.map { .string($0.summary) } ?? .null,
                "detail": result.actionResult?.detail.map { .string($0) } ?? .null,
                "should_speak": .bool(result.shouldSpeak),
                "latency_ms": .int(elapsedMs(since: executionStartedAt)),
                "events": .array(events)
            ])
            payload["latency_ms"] = .object([
                "route": .int(routeMs),
                "execution": .int(elapsedMs(since: executionStartedAt)),
                "total": .int(elapsedMs(since: startedAt))
            ])

            if let expectation = args["expect"]?.objectValue {
                let assertions = assertionsPayload(
                    expectation: expectation,
                    route: route,
                    action: route.action,
                    plan: plan,
                    result: result
                )
                payload["assertions"] = .array(assertions.items)
                payload["passed"] = .bool(assertions.passed)
            }
        }

        let passed = payload["passed"]?.boolValue ?? true
        return WorkspaceToolCallResult(
            toolName: "dispatch_test_run",
            payload: .object(payload),
            isError: !passed
        )
    }

    private static func resolveRoute(
        command: String,
        contextPacket: ContextPacket?,
        snapshots: [DispatchRouteSnapshot],
        learningStore: DispatchLearningStore
    ) async -> DispatchRouteResolution {
        let learnedBinding = learningStore.bestBinding(
            command: command,
            contextPacket: contextPacket,
            snapshots: snapshots
        )
        let ambientMemoryProfile = DispatchAmbientMemoryProfile.build(
            contextPacket: contextPacket,
            snapshots: snapshots,
            logs: learningStore.recentLogs(limit: 100)
        )
        return await DispatchRouteResolver.resolve(
            command: command,
            contextPacket: contextPacket,
            snapshots: snapshots,
            learnedBinding: learnedBinding,
            ambientMemoryProfile: ambientMemoryProfile
        )
    }

    private static func contextPacket(from object: [String: JSONValue]?, now: Date) -> ContextPacket? {
        guard let object else { return nil }

        let appName = string(object, "app_name") ?? string(object, "app")
        let browserURL = string(object, "browser_url") ?? string(object, "url")
        let siteHost = string(object, "site_host") ?? browserURL.flatMap(host)
        let surfaceKind = enumValue(
            SurfaceKind.self,
            raw: string(object, "surface_kind") ?? string(object, "kind"),
            fallback: .other
        )
        let fieldKind = enumValue(
            FieldKind.self,
            raw: string(object, "field_kind") ?? string(object, "field"),
            fallback: .unknown
        )
        let intentKind = enumValue(
            DictationIntentKind.self,
            raw: string(object, "intent_kind") ?? string(object, "intent"),
            fallback: .command
        )

        return ContextPacket(
            id: UUID(),
            capturedAt: date(from: object["captured_at"], fallback: now),
            surface: SurfaceDescriptor(
                kind: surfaceKind,
                appName: appName,
                bundleId: string(object, "bundle_id"),
                windowTitle: string(object, "window_title"),
                browserURL: browserURL,
                siteHost: siteHost,
                siteName: string(object, "site_name"),
                fieldKind: fieldKind,
                conversationLabel: string(object, "conversation_label"),
                documentLabel: string(object, "document_label"),
                projectLabel: string(object, "project_label")
            ),
            intent: DictationIntent(
                kind: intentKind,
                confidence: object["intent_confidence"]?.doubleValue ?? 1,
                allowsBiasTerms: true,
                allowsStyleHint: true,
                allowsSelectedTextGrounding: true,
                allowsVisibleContextGrounding: true,
                allowsMemoryGrounding: true,
                evidence: stringArray(object["intent_evidence"])
            ),
            entities: [],
            styleHint: string(object, "style_hint"),
            selectedTextPreview: string(object, "selected_text"),
            focusedFieldPreview: string(object, "focused_text") ?? string(object, "focused_field_preview"),
            targetFingerprint: targetFingerprint(
                from: object["target"]?.objectValue ?? object["target_fingerprint"]?.objectValue
            ),
            visibleGroundingSnippets: stringArray(object["visible_snippets"] ?? object["visible_text_snippets"]),
            safetyFlags: [],
            latency: .empty
        )
    }

    private static func snapshot(from object: [String: JSONValue]?, now: Date) -> DispatchRouteSnapshot? {
        guard let object else { return nil }
        let appName = string(object, "app_name") ?? string(object, "app") ?? "Unknown"
        return DispatchRouteSnapshot(
            timestamp: date(from: object["timestamp"], fallback: now),
            appName: appName,
            bundleId: string(object, "bundle_id") ?? "",
            windowTitle: string(object, "window_title"),
            browserURL: string(object, "browser_url") ?? string(object, "url"),
            codeFileName: string(object, "code_file_name"),
            slackRecipient: string(object, "slack_recipient"),
            focusedFieldContent: string(object, "focused_field_content") ?? string(object, "focused_text"),
            visibleTextSnippets: stringArray(object["visible_text_snippets"] ?? object["visible_snippets"]),
            browserTabs: stringArray(object["browser_tabs"]),
            notificationHint: notificationHint(from: object["notification"]?.objectValue, fallbackAppName: appName, now: now)
        )
    }

    private static func notificationHint(
        from object: [String: JSONValue]?,
        fallbackAppName: String,
        now: Date
    ) -> DispatchNotificationHint? {
        guard let object else { return nil }
        let appName = string(object, "app_name") ?? string(object, "app") ?? fallbackAppName
        guard string(object, "title") != nil || string(object, "body") != nil else {
            return nil
        }
        return DispatchNotificationHint(
            appName: appName,
            bundleId: string(object, "bundle_id"),
            title: string(object, "title"),
            body: string(object, "body"),
            url: string(object, "url"),
            receivedAt: date(from: object["received_at"], fallback: now)
        )
    }

    private static func targetFingerprint(from object: [String: JSONValue]?) -> ContextTargetFingerprint? {
        guard let object else { return nil }
        return ContextTargetFingerprint(
            role: string(object, "role"),
            subrole: string(object, "subrole"),
            identifierToken: string(object, "identifier_token"),
            titleToken: string(object, "title_token"),
            descriptionToken: string(object, "description_token"),
            placeholderToken: string(object, "placeholder_token"),
            helpToken: string(object, "help_token"),
            frameBucket: string(object, "frame_bucket"),
            selectedRangeBucket: string(object, "selected_range_bucket")
        )
    }

    private static func routePayload(_ route: DispatchRouteResolution) -> JSONValue {
        .object([
            "id": .string(route.card.id),
            "intent": .string(route.card.intent.rawValue),
            "title": .string(route.card.title),
            "surface": .string(route.card.surface),
            "action_line": .string(route.card.action),
            "validator": .string(route.card.validator),
            "disturbance": .string(route.card.disturbance.rawValue),
            "confidence": .double(route.confidence),
            "source": .string(route.source.rawValue),
            "reason": .string(route.reason),
            "evidence": .array(route.evidence.map { .string($0) }),
            "learned_binding_id": route.learnedBindingID.map { .string($0.uuidString) } ?? .null
        ])
    }

    private static func actionPayload(_ action: CommandAction?) -> JSONValue {
        guard let action else { return .null }
        switch action {
        case .typeText(let text, let appHint):
            return .object(["type": .string("type_text"), "text": .string(text), "app_hint": appHint.map { .string($0) } ?? .null])
        case .openURL(let url):
            return .object(["type": .string("open_url"), "url": .string(url)])
        case .openApp(let name):
            return .object(["type": .string("open_app"), "name": .string(name)])
        case .searchWorkspace(let query):
            return .object(["type": .string("search_workspace"), "query": .string(query)])
        case .speakAnswer(let text):
            return .object(["type": .string("speak_answer"), "text": .string(text)])
        case .createTicket(let title, let body, let service):
            return .object(["type": .string("create_ticket"), "title": .string(title), "body": .string(body), "service": .string(service.rawValue)])
        case .postSlack(let channel, let message):
            return .object(["type": .string("post_slack"), "channel": .string(channel), "message": .string(message)])
        case .delegateToAgent(let agent, let prompt, let context):
            return .object(["type": .string("delegate_agent"), "agent": .string(agent.rawValue), "prompt": .string(prompt), "context": context.map { .string($0) } ?? .null])
        case .composite(let actions):
            return .object(["type": .string("composite"), "actions": .array(actions.map { actionPayload($0) })])
        }
    }

    private static func contextSummaryPayload(_ contextPacket: ContextPacket?) -> JSONValue {
        guard let contextPacket else { return .null }
        let surface = contextPacket.surface
        return .object([
            "app_name": surface.appName.map { .string($0) } ?? .null,
            "bundle_id": surface.bundleId.map { .string($0) } ?? .null,
            "surface_kind": .string(surface.kind.rawValue),
            "field_kind": .string(surface.fieldKind.rawValue),
            "browser_url": surface.browserURL.map { .string($0) } ?? .null,
            "site_host": surface.siteHost.map { .string($0) } ?? .null,
            "window_title": surface.windowTitle.map { .string($0) } ?? .null,
            "has_target_fingerprint": .bool(contextPacket.targetFingerprint != nil)
        ])
    }

    private static func snapshotPayload(_ snapshot: DispatchRouteSnapshot) -> JSONValue {
        .object([
            "app_name": .string(snapshot.appName),
            "bundle_id": .string(snapshot.bundleId),
            "window_title": snapshot.windowTitle.map { .string($0) } ?? .null,
            "browser_url": snapshot.browserURL.map { .string($0) } ?? .null,
            "slack_recipient": snapshot.slackRecipient.map { .string($0) } ?? .null,
            "notification": snapshot.notificationHint.map { .string($0.summary) } ?? .null
        ])
    }

    private static func targetCheckPayload(
        route: DispatchRouteResolution,
        contextPacket: ContextPacket?,
        snapshots: [DispatchRouteSnapshot],
        learningStore: DispatchLearningStore
    ) -> JSONValue? {
        guard let action = route.action,
              let bindingID = route.learnedBindingID,
              let binding = learningStore.binding(id: bindingID) else {
            return nil
        }
        let currentSurface = DispatchLearningStore.surfaceFingerprint(
            contextPacket: contextPacket,
            snapshots: snapshots
        )
        let evaluation = DispatchTargetGuard.evaluate(
            action: action,
            binding: binding,
            currentSurface: currentSurface
        )
        let check = evaluation.check
        return .object([
            "allowed": .bool(evaluation.allowed),
            "required": .bool(check.required),
            "expected_ax_target": .bool(check.expectedAXTarget),
            "current_ax_target": .bool(check.currentAXTarget),
            "match_score": check.matchScore.map { .double($0) } ?? .null,
            "minimum_score": check.minimumScore.map { .double($0) } ?? .null,
            "summary": check.summary.map { .string($0) } ?? .null
        ])
    }

    private static func progressPayload(_ progress: DispatchCommandProgress, startedAt: Date) -> JSONValue {
        var object: [String: JSONValue] = ["offset_ms": .int(elapsedMs(since: startedAt))]
        switch progress {
        case .routeSelected(let route):
            object["type"] = .string("route_selected")
            object["route_id"] = .string(route.card.id)
            object["source"] = .string(route.source.rawValue)
            object["confidence"] = .double(route.confidence)
        case .planSelected(let plan):
            object["type"] = .string("plan_selected")
            object["objective"] = .string(plan.objective)
            object["target_surface"] = .string(plan.targetSurface)
            object["execution_strategy"] = .string(plan.executionStrategy.rawValue)
            object["verification_strategy"] = .string(plan.verificationStrategy.rawValue)
            object["repair_strategy"] = .string(plan.repairStrategy.rawValue)
            object["capability_status"] = .string(plan.capabilityStatus.rawValue)
            object["requires_clarification"] = .bool(plan.requiresClarification)
            object["requires_api"] = .bool(plan.requiresAPI)
            object["requires_active_target"] = .bool(plan.requiresActiveTarget)
            object["surface_app"] = plan.surfaceKind.map { .string($0.rawValue) } ?? .null
            object["surface_variant"] = plan.surfaceVariant.map { .string($0.rawValue) } ?? .null
            object["fallback"] = plan.fallback.map { .string($0) } ?? .null
            object["capability_summary"] = plan.capabilitySummary.map { .string($0) } ?? .null
        case .actionStarted(let action):
            object["type"] = .string("action_started")
            object["action"] = .string(action)
        case .result(let result, let success):
            object["type"] = .string("result")
            object["result"] = .string(result)
            object["success"] = .bool(success)
        }
        return .object(object)
    }

    private static func planPayload(_ plan: DispatchPlan) -> JSONValue {
        .object([
            "objective": .string(plan.objective),
            "target_surface": .string(plan.targetSurface),
            "surface_app": plan.surfaceKind.map { .string($0.rawValue) } ?? .null,
            "surface_variant": plan.surfaceVariant.map { .string($0.rawValue) } ?? .null,
            "execution_strategy": .string(plan.executionStrategy.rawValue),
            "verification_strategy": .string(plan.verificationStrategy.rawValue),
            "repair_strategy": .string(plan.repairStrategy.rawValue),
            "capability_status": .string(plan.capabilityStatus.rawValue),
            "requires_api": .bool(plan.requiresAPI),
            "requires_active_target": .bool(plan.requiresActiveTarget),
            "fallback": plan.fallback.map { .string($0) } ?? .null,
            "capability_summary": plan.capabilitySummary.map { .string($0) } ?? .null,
            "confidence": .double(plan.confidence),
            "requires_clarification": .bool(plan.requiresClarification),
            "clarification_prompt": plan.clarificationPrompt.map { .string($0) } ?? .null,
            "evidence": .array(plan.evidence.map { .string($0) })
        ])
    }

    private static func assertionsPayload(
        expectation: [String: JSONValue],
        route: DispatchRouteResolution,
        action: CommandAction?,
        plan: DispatchPlan?,
        result: CommandResult?
    ) -> (items: [JSONValue], passed: Bool) {
        var assertions: [JSONValue] = []

        func add(_ name: String, _ passed: Bool, expected: JSONValue, actual: JSONValue) {
            assertions.append(.object([
                "name": .string(name),
                "passed": .bool(passed),
                "expected": expected,
                "actual": actual
            ]))
        }

        if let expected = expectation["route_id"]?.stringValue {
            add("route_id", route.card.id == expected, expected: .string(expected), actual: .string(route.card.id))
        }
        if let expected = expectation["intent"]?.stringValue {
            add("intent", route.card.intent.rawValue == expected, expected: .string(expected), actual: .string(route.card.intent.rawValue))
        }
        if let expected = expectation["source"]?.stringValue {
            add("source", route.source.rawValue == expected, expected: .string(expected), actual: .string(route.source.rawValue))
        }
        if let expected = expectation["action"]?.stringValue ?? expectation["action_type"]?.stringValue {
            let actual = action.map(actionType) ?? "none"
            add("action", actual == expected, expected: .string(expected), actual: .string(actual))
        }
        if let expected = expectation["text"]?.stringValue {
            let actual: String = if case .typeText(let text, _)? = action { text } else { "" }
            add("text", actual == expected, expected: .string(expected), actual: .string(actual))
        }
        if let expected = expectation["app_hint"]?.stringValue {
            let actual: String = if case .typeText(_, let appHint)? = action { appHint ?? "" } else { "" }
            add("app_hint", actual == expected, expected: .string(expected), actual: .string(actual))
        }
        if let expected = expectation["url_contains"]?.stringValue {
            let actual: String = if case .openURL(let url)? = action { url } else { "" }
            add("url_contains", actual.contains(expected), expected: .string(expected), actual: .string(actual))
        }
        if let expected = expectation["capability_status"]?.stringValue {
            let actual = plan?.capabilityStatus.rawValue ?? "none"
            add("capability_status", actual == expected, expected: .string(expected), actual: .string(actual))
        }
        if let expected = expectation["execution_strategy"]?.stringValue {
            let actual = plan?.executionStrategy.rawValue ?? "none"
            add("execution_strategy", actual == expected, expected: .string(expected), actual: .string(actual))
        }
        if let expected = expectation["surface_app"]?.stringValue {
            let actual = plan?.surfaceKind?.rawValue ?? ""
            add("surface_app", actual == expected, expected: .string(expected), actual: .string(actual))
        }
        if let expected = expectation["fallback"]?.stringValue {
            let actual = plan?.fallback ?? ""
            add("fallback", actual == expected, expected: .string(expected), actual: .string(actual))
        }
        if let expected = expectation["requires_api"]?.boolValue {
            let actual = plan?.requiresAPI ?? false
            add("requires_api", actual == expected, expected: .bool(expected), actual: .bool(actual))
        }
        if let expected = expectation["success"]?.boolValue {
            let actual = result?.actionResult?.success ?? false
            add("success", actual == expected, expected: .bool(expected), actual: .bool(actual))
        }

        return (assertions, assertions.allSatisfy { $0.objectValue?["passed"]?.boolValue == true })
    }

    private static func actionType(_ action: CommandAction) -> String {
        switch action {
        case .typeText: "type_text"
        case .openURL: "open_url"
        case .openApp: "open_app"
        case .searchWorkspace: "search_workspace"
        case .speakAnswer: "speak_answer"
        case .createTicket: "create_ticket"
        case .postSlack: "post_slack"
        case .delegateToAgent: "delegate_agent"
        case .composite: "composite"
        }
    }

    private static func string(_ object: [String: JSONValue], _ key: String) -> String? {
        guard let raw = object[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return raw
    }

    private static func stringArray(_ value: JSONValue?) -> [String] {
        value?.arrayValue?.compactMap { item in
            item.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty } ?? []
    }

    private static func date(from value: JSONValue?, fallback: Date) -> Date {
        guard let raw = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return fallback
        }
        if raw == "now" { return fallback }
        if let parsed = WorkspaceQueryEngine.parseDate(raw) {
            return parsed
        }
        return fallback
    }

    private static func host(from urlString: String) -> String? {
        URL(string: urlString)?.host(percentEncoded: false)
    }

    private static func enumValue<T: RawRepresentable>(
        _ type: T.Type,
        raw: String?,
        fallback: T
    ) -> T where T.RawValue == String {
        guard let raw else { return fallback }
        return T(rawValue: raw) ?? fallback
    }

    private static func elapsedMs(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1000)
    }
}
