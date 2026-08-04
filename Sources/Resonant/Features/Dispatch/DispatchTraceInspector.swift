import Foundation

@MainActor
enum DispatchTraceInspector {
    static func payload(
        store: DispatchTraceStore,
        limit: Int,
        privacy: DispatchDiagnosticPrivacy = .redacted
    ) -> JSONValue {
        let formatter = ISO8601DateFormatter()
        let traceEvents = store.recentEvents(limit: min(max(limit, 1), 500))
        let diagnoses = diagnosisPayloads(for: traceEvents, privacy: privacy)
        let events = traceEvents.map { event in
            JSONValue.object([
                "id": .string(event.id.uuidString),
                "trace_id": .string(event.traceID.uuidString),
                "timestamp": .string(formatter.string(from: event.timestamp)),
                "stage": .string(event.stage.rawValue),
                "command": .string(DispatchDiagnosticRedactor.redactCommand(event.command, privacy: privacy)),
                "route_id": event.routeID.map { .string($0) } ?? .null,
                "route_source": event.routeSource.map { .string($0) } ?? .null,
                "action": event.actionSummary.map { .string(DispatchDiagnosticRedactor.redactDiagnosticText($0, privacy: privacy)) } ?? .null,
                "success": event.success.map { .bool($0) } ?? .null,
                "failure_stage": event.failureStage.map { .string($0) } ?? .null,
                "summary": event.summary.map { .string(DispatchDiagnosticRedactor.redactDiagnosticText($0, privacy: privacy)) } ?? .null,
                "metadata": .object(redactedMetadata(event.metadata, privacy: privacy))
            ])
        }
        return .object([
            "events": .array(events),
            "count": .int(events.count),
            "summary": summaryPayload(for: traceEvents),
            "diagnoses": .array(diagnoses),
            "privacy": .string(privacy.isRedacted ? "redacted" : "raw"),
            "log_path": .string(store.tracesDirectoryPath)
        ])
    }

    private static func summaryPayload(for events: [DispatchTraceEvent]) -> JSONValue {
        var capabilityStatusCounts: [String: Int] = [:]
        var failureStageCounts: [String: Int] = [:]
        var stageCounts: [String: Int] = [:]
        var traceIDs = Set<UUID>()
        var failedCommands = 0
        var succeededCommands = 0

        for event in events {
            traceIDs.insert(event.traceID)
            stageCounts[event.stage.rawValue, default: 0] += 1

            if event.stage == .planSelected,
               let status = event.metadata["capability_status"] {
                capabilityStatusCounts[status, default: 0] += 1
            }

            if let failureStage = event.failureStage {
                failureStageCounts[failureStage, default: 0] += 1
            }

            if event.stage == .commandFinished {
                if event.success == true {
                    succeededCommands += 1
                } else if event.success == false {
                    failedCommands += 1
                }
            }
        }

        return .object([
            "traces": .int(traceIDs.count),
            "succeeded_commands": .int(succeededCommands),
            "failed_commands": .int(failedCommands),
            "capability_status": countsPayload(capabilityStatusCounts),
            "failure_stage": countsPayload(failureStageCounts),
            "diagnosis": diagnosisCountsPayload(for: events),
            "stage": countsPayload(stageCounts)
        ])
    }

    private static func diagnosisPayloads(
        for events: [DispatchTraceEvent],
        privacy: DispatchDiagnosticPrivacy
    ) -> [JSONValue] {
        groupedTraces(diagnosticEvents(events, privacy: privacy))
            .compactMap { traceID, events in
                guard events.contains(where: { $0.stage == .commandFinished }) else { return nil }
                let diagnosis = DispatchCapabilityDiagnoser.diagnose(trace: events)
                return .object([
                    "trace_id": .string(traceID.uuidString),
                    "diagnosis": diagnosis.payload
                ])
            }
            .sorted { lhs, rhs in
                lhs.objectValue?["trace_id"]?.stringValue ?? "" > rhs.objectValue?["trace_id"]?.stringValue ?? ""
            }
    }

    private static func diagnosisCountsPayload(for events: [DispatchTraceEvent]) -> JSONValue {
        let counts = groupedTraces(events).values
            .filter { $0.contains(where: { $0.stage == .commandFinished }) }
            .map { DispatchCapabilityDiagnoser.diagnose(trace: $0).kind.rawValue }
            .reduce(into: [String: Int]()) { result, kind in
                result[kind, default: 0] += 1
            }
        return countsPayload(counts)
    }

    private static func diagnosticEvents(
        _ events: [DispatchTraceEvent],
        privacy: DispatchDiagnosticPrivacy
    ) -> [DispatchTraceEvent] {
        guard privacy.isRedacted else { return events }
        return events.map { event in
            var redacted = event
            redacted.command = DispatchDiagnosticRedactor.redactCommand(event.command, privacy: privacy)
            redacted.actionSummary = event.actionSummary.map {
                DispatchDiagnosticRedactor.redactDiagnosticText($0, privacy: privacy)
            }
            redacted.summary = event.summary.map {
                DispatchDiagnosticRedactor.redactDiagnosticText($0, privacy: privacy)
            }
            redacted.metadata = redactedMetadataStrings(event.metadata, privacy: privacy)
            return redacted
        }
    }

    private static func groupedTraces(_ events: [DispatchTraceEvent]) -> [UUID: [DispatchTraceEvent]] {
        Dictionary(grouping: events, by: \.traceID)
    }

    private static func countsPayload(_ counts: [String: Int]) -> JSONValue {
        .object(counts.mapValues { .int($0) })
    }

    private static func redactedMetadata(
        _ metadata: [String: String],
        privacy: DispatchDiagnosticPrivacy
    ) -> [String: JSONValue] {
        redactedMetadataStrings(metadata, privacy: privacy).mapValues { .string($0) }
    }

    private static func redactedMetadataStrings(
        _ metadata: [String: String],
        privacy: DispatchDiagnosticPrivacy
    ) -> [String: String] {
        Dictionary(uniqueKeysWithValues: metadata.map { key, value in
            let redactedValue: String
            if privacy.isRedacted, isSensitiveMetadataKey(key) {
                redactedValue = "[redacted]"
            } else {
                redactedValue = DispatchDiagnosticRedactor.redactDiagnosticText(value, privacy: privacy)
            }
            return (key, redactedValue)
        })
    }

    private static func isSensitiveMetadataKey(_ key: String) -> Bool {
        sensitiveMetadataKeys.contains(key) || key.hasPrefix("planner_evidence_")
    }

    private static let sensitiveMetadataKeys: Set<String> = [
        "app_name",
        "bundle_id",
        "browser_url",
        "clarification_prompt",
        "evidence_1",
        "evidence_2",
        "evidence_3",
        "evidence_4",
        "objective",
        "route_surface",
        "site_host",
        "surface_app",
        "surface_variant",
        "target_guard_summary",
        "target_surface",
        "window_title"
    ]
}
