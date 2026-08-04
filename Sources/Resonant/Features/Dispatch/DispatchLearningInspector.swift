import Foundation

@MainActor
enum DispatchLearningInspector {
    static func logPayload(
        store: DispatchLearningStore,
        limit: Int,
        privacy: DispatchDiagnosticPrivacy = .raw
    ) -> JSONValue {
        logPayload(entries: store.recentLogs(limit: clampedLimit(limit)), privacy: privacy)
    }

    static func bindingsPayload(store: DispatchLearningStore, limit: Int) -> JSONValue {
        bindingsPayload(bindings: store.recentBindings(limit: clampedLimit(limit)))
    }

    static func bindingsPayload(
        store: DispatchLearningStore,
        limit: Int,
        privacy: DispatchDiagnosticPrivacy
    ) -> JSONValue {
        bindingsPayload(bindings: store.recentBindings(limit: clampedLimit(limit)), privacy: privacy)
    }

    static func logPayload(
        entries: [DispatchLogEntry],
        privacy: DispatchDiagnosticPrivacy = .raw
    ) -> JSONValue {
        let formatter = ISO8601DateFormatter()
        let logs = entries.map { entry in
            JSONValue.object([
                "id": .string(entry.id.uuidString),
                "timestamp": .string(formatter.string(from: entry.timestamp)),
                "command": .string(DispatchDiagnosticRedactor.redactCommand(entry.command, privacy: privacy)),
                "command_pattern": .string(DispatchDiagnosticRedactor.redactPattern(entry.commandPattern, privacy: privacy)),
                "route_id": .string(entry.routeCard.id),
                "route_title": .string(entry.routeCard.title),
                "route_intent": .string(entry.routeCard.intent.rawValue),
                "route_surface": .string(redactedSurface(entry.routeCard.surface, privacy: privacy)),
                "route_source": .string((entry.routeSource ?? .explicitAction).rawValue),
                "route_reason": entry.routeReason
                    .map { .string(DispatchDiagnosticRedactor.redactDiagnosticText($0, privacy: privacy)) }
                    ?? .null,
                "action": .string(actionSummary(entry.action, fallback: entry.actionSummary, privacy: privacy)),
                "confidence": .double(entry.confidence),
                "success": .bool(entry.resultSuccess),
                "result": .string(DispatchDiagnosticRedactor.redactDiagnosticText(entry.resultSummary, privacy: privacy)),
                "failure_stage": entry.failureStage.map { .string($0.rawValue) } ?? .null,
                "used_learned_binding": .bool(entry.learnedBindingID != nil),
                "learned_binding_id": entry.learnedBindingID.map { .string($0.uuidString) } ?? .null,
                "correction": entry.correctionKind.map { .string($0.rawValue) } ?? .null,
                "corrected_log_id": entry.correctedLogID.map { .string($0.uuidString) } ?? .null,
                "evidence": .array(entry.evidence.map {
                    .string(DispatchDiagnosticRedactor.redactDiagnosticText($0, privacy: privacy))
                }),
                "target_check": targetCheckPayload(entry.targetCheck),
                "surface": surfacePayload(entry.surface, privacy: privacy)
            ])
        }
        return .object([
            "logs": .array(logs),
            "count": .int(logs.count),
            "privacy": .string(privacy.isRedacted ? "redacted" : "raw")
        ])
    }

    static func bindingsPayload(
        bindings: [DispatchLearningBinding],
        privacy: DispatchDiagnosticPrivacy = .raw
    ) -> JSONValue {
        let formatter = ISO8601DateFormatter()
        let bindings = bindings.map { binding in
            JSONValue.object([
                "id": .string(binding.id.uuidString),
                "command_pattern": .string(DispatchDiagnosticRedactor.redactPattern(binding.commandPattern, privacy: privacy)),
                "route_id": .string(binding.routeCard.id),
                "route_title": .string(binding.routeCard.title),
                "route_intent": .string(binding.routeCard.intent.rawValue),
                "route_surface": .string(redactedSurface(binding.routeCard.surface, privacy: privacy)),
                "route_action": .string(binding.routeCard.action),
                "action": .string(actionSummary(binding.action, privacy: privacy)),
                "confidence": .double(binding.confidence),
                "success_count": .int(binding.successCount),
                "failure_count": .int(binding.failureCount),
                "usable": .bool(binding.isUsable),
                "created_at": .string(formatter.string(from: binding.createdAt)),
                "last_updated_at": .string(formatter.string(from: binding.lastUpdatedAt)),
                "surface": surfacePayload(binding.surface, privacy: privacy)
            ])
        }
        return .object([
            "bindings": .array(bindings),
            "count": .int(bindings.count),
            "privacy": .string(privacy.isRedacted ? "redacted" : "raw")
        ])
    }

    static func surfacePayload(
        _ surface: DispatchSurfaceFingerprint,
        privacy: DispatchDiagnosticPrivacy = .raw
    ) -> JSONValue {
        var values: [String: JSONValue] = [:]
        values["surface_kind"] = surface.surfaceKind.map { .string($0) } ?? .null
        values["field_kind"] = surface.fieldKind.map { .string($0) } ?? .null
        values["app_name"] = surface.appName.map { .string($0) } ?? .null
        values["bundle_id"] = surface.bundleId.map { .string($0) } ?? .null
        values["site_host"] = redactedOptional(surface.siteHost, privacy: privacy, placeholder: "[redacted host]")
        values["url_path_token"] = surface.urlPathToken.map { .string($0) } ?? .null
        values["window_title_token"] = surface.windowTitleToken.map { .string($0) } ?? .null
        values["field_content_token"] = surface.fieldContentToken.map { .string($0) } ?? .null
        values["nearby_text_token"] = surface.nearbyTextToken.map { .string($0) } ?? .null
        values["conversation_label"] = redactedOptional(surface.conversationLabel, privacy: privacy, placeholder: "[redacted conversation]")
        values["document_label_token"] = surface.documentLabelToken.map { .string($0) } ?? .null
        values["project_label"] = redactedOptional(surface.projectLabel, privacy: privacy, placeholder: "[redacted project]")
        values["code_file_name"] = redactedOptional(surface.codeFileName, privacy: privacy, placeholder: "[redacted file]")
        values["slack_recipient"] = redactedOptional(surface.slackRecipient, privacy: privacy, placeholder: "[redacted recipient]")
        values["ax_role"] = surface.axRole.map { .string($0) } ?? .null
        values["ax_subrole"] = surface.axSubrole.map { .string($0) } ?? .null
        values["ax_identifier_token"] = surface.axIdentifierToken.map { .string($0) } ?? .null
        values["ax_title_token"] = surface.axTitleToken.map { .string($0) } ?? .null
        values["ax_description_token"] = surface.axDescriptionToken.map { .string($0) } ?? .null
        values["ax_placeholder_token"] = surface.axPlaceholderToken.map { .string($0) } ?? .null
        values["ax_help_token"] = surface.axHelpToken.map { .string($0) } ?? .null
        values["ax_frame_bucket"] = surface.axFrameBucket.map { .string($0) } ?? .null
        values["ax_selected_range_bucket"] = surface.axSelectedRangeBucket.map { .string($0) } ?? .null
        return .object(values)
    }

    static func targetCheckPayload(_ check: DispatchTargetCheck?) -> JSONValue {
        guard let check else { return .null }
        return .object([
            "required": .bool(check.required),
            "expected_ax_target": .bool(check.expectedAXTarget),
            "current_ax_target": .bool(check.currentAXTarget),
            "match_score": check.matchScore.map { .double($0) } ?? .null,
            "minimum_score": check.minimumScore.map { .double($0) } ?? .null,
            "summary": check.summary.map { .string($0) } ?? .null
        ])
    }

    static func actionSummary(_ action: CommandAction?) -> String {
        actionSummary(action, privacy: .raw)
    }

    static func actionSummary(
        _ action: CommandAction?,
        fallback: String? = nil,
        privacy: DispatchDiagnosticPrivacy
    ) -> String {
        guard let action else {
            guard let fallback else { return "" }
            return privacy.isRedacted ? "[redacted action]" : fallback
        }
        switch action {
        case .typeText(_, let appHint):
            if privacy.isRedacted { return "type_text" }
            return "type_text\(appHint.map { ":\($0)" } ?? "")"
        case .openURL(let url):
            if privacy.isRedacted { return "open_url:[url]" }
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
            if privacy.isRedacted { return "post_slack:[channel]" }
            return "post_slack:\(channel)"
        case .delegateToAgent(let agent, _, _):
            return "delegate_agent:\(agent.rawValue)"
        case .composite(let actions):
            return "composite:\(actions.count)"
        }
    }

    private static func clampedLimit(_ limit: Int) -> Int {
        min(max(limit, 1), 100)
    }

    private static func redactedSurface(_ surface: String, privacy: DispatchDiagnosticPrivacy) -> String {
        privacy.isRedacted ? "[redacted surface]" : surface
    }

    private static func redactedOptional(
        _ value: String?,
        privacy: DispatchDiagnosticPrivacy,
        placeholder: String
    ) -> JSONValue {
        guard let value else { return .null }
        return .string(privacy.isRedacted ? placeholder : value)
    }
}
