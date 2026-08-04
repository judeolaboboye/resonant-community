import XCTest
@testable import Resonant

@MainActor
final class DispatchTraceStoreTests: XCTestCase {
    func testTraceStoreWritesAndReadsCommandTimelineEvents() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DispatchTraceStoreTests-\(UUID().uuidString)", isDirectory: true)
        let store = DispatchTraceStore(rootURL: root)
        let route = DispatchRouteResolution(
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
            evidence: ["App route uses macOS activation/open APIs."],
            source: .deterministicLocal
        )

        let traceID = store.begin(command: "open slack", contextPacket: nil)
        store.append(
            traceID: traceID,
            command: "open slack",
            stage: .routeSelected,
            route: route,
            action: .openApp(name: "Slack"),
            summary: "Deterministic route selected.",
            metadata: ["confidence": "0.900"]
        )
        store.append(
            traceID: traceID,
            command: "open slack",
            stage: .commandFinished,
            route: route,
            action: .openApp(name: "Slack"),
            success: true,
            summary: "Verified Slack is frontmost."
        )

        let events = store.recentEvents(limit: 10).filter { $0.traceID == traceID }
        XCTAssertEqual(events.count, 3)
        XCTAssertTrue(events.contains { $0.stage == .commandReceived })
        XCTAssertTrue(events.contains { $0.stage == .routeSelected && $0.routeID == "app.open.slack" })
        XCTAssertTrue(events.contains { $0.stage == .commandFinished && $0.success == true })
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.tracesDirectoryPath))
    }

    func testTraceInspectorRedactsSensitiveFieldsByDefault() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DispatchTraceInspectorTests-\(UUID().uuidString)", isDirectory: true)
        let store = DispatchTraceStore(rootURL: root)
        let traceID = store.begin(command: "reply to alex with secret", contextPacket: nil)
        store.append(
            traceID: traceID,
            command: "reply to alex with secret",
            stage: .routeSelected,
            summary: "URL: https://linear.app/resonant/issue/RES-1",
            metadata: [
                "app_name": "Linear",
                "bundle_id": "com.linear",
                "browser_url": "https://linear.app/resonant/issue/RES-1",
                "clarification_prompt": "Which private issue?",
                "planner_evidence_1": "Saw private issue RES-1",
                "route_surface": "#private",
                "site_host": "linear.app",
                "surface_app": "linear",
                "surface_variant": "browser",
                "target_guard_summary": "Window: Secret roadmap",
                "window_title": "Secret roadmap"
            ]
        )

        guard case .object(let payload) = DispatchTraceInspector.payload(store: store, limit: 10),
              case .array(let events)? = payload["events"],
              case .object(let event)? = events.first(where: { value in
                  guard case .object(let object) = value else { return false }
                  return object["stage"] == .string("route_selected")
              }),
              case .object(let metadata)? = event["metadata"] else {
            return XCTFail("Expected trace inspector payload")
        }

        XCTAssertEqual(event["command"], .string("[redacted command]"))
        XCTAssertEqual(event["summary"], .string("URL: [url]"))
        XCTAssertEqual(metadata["app_name"], .string("[redacted]"))
        XCTAssertEqual(metadata["bundle_id"], .string("[redacted]"))
        XCTAssertEqual(metadata["browser_url"], .string("[redacted]"))
        XCTAssertEqual(metadata["clarification_prompt"], .string("[redacted]"))
        XCTAssertEqual(metadata["planner_evidence_1"], .string("[redacted]"))
        XCTAssertEqual(metadata["route_surface"], .string("[redacted]"))
        XCTAssertEqual(metadata["site_host"], .string("[redacted]"))
        XCTAssertEqual(metadata["surface_app"], .string("[redacted]"))
        XCTAssertEqual(metadata["surface_variant"], .string("[redacted]"))
        XCTAssertEqual(metadata["target_guard_summary"], .string("[redacted]"))
        XCTAssertEqual(metadata["window_title"], .string("[redacted]"))
    }

    func testTraceInspectorSummarizesCapabilityAndFailureCounts() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DispatchTraceSummaryTests-\(UUID().uuidString)", isDirectory: true)
        let store = DispatchTraceStore(rootURL: root)
        let route = DispatchRouteResolution(
            card: DispatchRouteCard(
                id: "ticket.linear",
                intent: .ticketDraft,
                title: "Linear ticket draft",
                surface: "Linear",
                action: "Prepare ticket payload",
                validator: "Ticket title/body prepared",
                disturbance: .preparedOnly
            ),
            action: .createTicket(title: "Fix dispatch", body: "Silent failure", service: .linear),
            confidence: 0.8,
            evidence: ["Ticket route"],
            source: .deterministicLocal
        )
        let traceID = store.begin(command: "create a linear ticket", contextPacket: nil)
        store.append(
            traceID: traceID,
            command: "create a linear ticket",
            stage: .planSelected,
            route: route,
            action: route.action,
            success: true,
            summary: "Prepare a linear ticket via clipboard_draft",
            metadata: [
                "capability_status": "degraded",
                "capability_requires_api": "true"
            ]
        )
        store.append(
            traceID: traceID,
            command: "create a linear ticket",
            stage: .commandFinished,
            route: route,
            action: route.action,
            success: false,
            failureStage: .verification,
            summary: "Clipboard did not contain ticket draft."
        )

        guard case .object(let payload) = DispatchTraceInspector.payload(store: store, limit: 10),
              case .object(let summary)? = payload["summary"],
              case .object(let capability)? = summary["capability_status"],
              case .object(let failureStage)? = summary["failure_stage"],
              case .object(let diagnosis)? = summary["diagnosis"],
              case .object(let stage)? = summary["stage"] else {
            return XCTFail("Expected trace summary payload")
        }

        XCTAssertEqual(summary["traces"], .int(1))
        XCTAssertEqual(summary["failed_commands"], .int(1))
        XCTAssertEqual(capability["degraded"], .int(1))
        XCTAssertEqual(failureStage["verification"], .int(1))
        XCTAssertEqual(diagnosis["missing_integration"], .int(1))
        XCTAssertEqual(stage["plan_selected"], .int(1))
    }

    func testTraceInspectorDiagnosesMissingActiveTarget() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DispatchTraceDiagnosisTests-\(UUID().uuidString)", isDirectory: true)
        let store = DispatchTraceStore(rootURL: root)
        let route = DispatchRouteResolution(
            card: DispatchRouteCard(
                id: "reply.active.discord",
                intent: .activeText,
                title: "Discord reply",
                surface: "Discord",
                action: "Type into active reply field",
                validator: "Focused field contains inserted text",
                disturbance: .activeSurface
            ),
            action: .typeText(text: "sounds good", appHint: "Discord"),
            confidence: 0.7,
            evidence: ["Needs active target"],
            source: .deterministicLocal
        )
        let traceID = store.begin(command: "reply sounds good", contextPacket: nil)
        store.append(
            traceID: traceID,
            command: "reply sounds good",
            stage: .planSelected,
            route: route,
            action: route.action,
            success: true,
            summary: "Insert dictated text via local_ui_automation",
            metadata: [
                "capability_status": "available",
                "capability_requires_active_target": "true",
                "surface_app": "discord",
                "surface_variant": "native",
                "execution_strategy": "local_ui_automation"
            ]
        )
        store.append(
            traceID: traceID,
            command: "reply sounds good",
            stage: .commandFinished,
            route: route,
            action: route.action,
            success: false,
            failureStage: .verification,
            summary: "Focused field did not contain inserted text."
        )

        guard case .object(let payload) = DispatchTraceInspector.payload(store: store, limit: 10),
              case .array(let diagnoses)? = payload["diagnoses"],
              case .object(let traceDiagnosis)? = diagnoses.first,
              case .object(let diagnosis)? = traceDiagnosis["diagnosis"],
              case .object(let summary)? = payload["summary"],
              case .object(let diagnosisCounts)? = summary["diagnosis"] else {
            return XCTFail("Expected diagnosis payload")
        }

        XCTAssertEqual(traceDiagnosis["trace_id"], .string(traceID.uuidString))
        XCTAssertEqual(diagnosis["kind"], .string("missing_active_target"))
        XCTAssertEqual(diagnosisCounts["missing_active_target"], .int(1))
    }

    func testTraceInspectorRedactsDiagnosisEvidenceByDefault() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DispatchTraceDiagnosisRedactionTests-\(UUID().uuidString)", isDirectory: true)
        let store = DispatchTraceStore(rootURL: root)
        let traceID = store.begin(command: "reply with secret", contextPacket: nil)
        store.append(
            traceID: traceID,
            command: "reply with secret",
            stage: .targetGuardBlocked,
            success: false,
            summary: "Target changed. Focus #private and say use this text box.",
            metadata: [
                "target_guard_summary": "Target changed from #private to #other with customer secret.",
                "match_score": "0.100",
                "minimum_score": "0.650"
            ]
        )
        store.append(
            traceID: traceID,
            command: "reply with secret",
            stage: .commandFinished,
            success: false,
            failureStage: .targetGuard,
            summary: "Target changed. Focus #private and say use this text box."
        )

        guard case .object(let payload) = DispatchTraceInspector.payload(store: store, limit: 10),
              case .array(let diagnoses)? = payload["diagnoses"],
              case .object(let traceDiagnosis)? = diagnoses.first,
              case .object(let diagnosis)? = traceDiagnosis["diagnosis"],
              case .array(let evidence)? = diagnosis["evidence"] else {
            return XCTFail("Expected diagnosis payload")
        }

        XCTAssertFalse(evidence.contains(.string("Target changed from #private to #other with customer secret.")))
        XCTAssertTrue(evidence.contains(.string("[redacted]")))
    }
}
