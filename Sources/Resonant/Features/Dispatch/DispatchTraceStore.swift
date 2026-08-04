import Foundation

enum DispatchTraceStage: String, Codable, Sendable, Equatable {
    case commandReceived = "command_received"
    case correctionApplied = "correction_applied"
    case routeSelected = "route_selected"
    case planSelected = "plan_selected"
    case noLocalMatch = "no_local_match"
    case cloudClassificationStarted = "cloud_classification_started"
    case cloudClassificationFailed = "cloud_classification_failed"
    case actionStarted = "action_started"
    case targetGuardBlocked = "target_guard_blocked"
    case actionExecuted = "action_executed"
    case verificationFinished = "verification_finished"
    case repairAttempted = "repair_attempted"
    case learningRecorded = "learning_recorded"
    case commandFinished = "command_finished"
}

struct DispatchTraceEvent: Codable, Sendable, Equatable {
    var id: UUID
    var traceID: UUID
    var timestamp: Date
    var stage: DispatchTraceStage
    var command: String
    var routeID: String?
    var routeSource: String?
    var actionSummary: String?
    var success: Bool?
    var failureStage: String?
    var summary: String?
    var metadata: [String: String]
}

@MainActor
final class DispatchTraceStore {
    private let fileManager: FileManager
    private let tracesDirectory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private static let ioQueue = DispatchQueue(label: "com.resonance.resonant.dispatch-trace-store.io", qos: .utility)

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()

    init(
        rootURL: URL = AppSupportPaths.resonantRoot(),
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.tracesDirectory = rootURL
            .appendingPathComponent("dispatch", isDirectory: true)
            .appendingPathComponent("traces", isDirectory: true)
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
        try? fileManager.createDirectory(at: tracesDirectory, withIntermediateDirectories: true)
    }

    func begin(command: String, contextPacket: ContextPacket?) -> UUID {
        let traceID = UUID()
        append(
            traceID: traceID,
            command: command,
            stage: .commandReceived,
            metadata: contextMetadata(contextPacket)
        )
        return traceID
    }

    func append(
        traceID: UUID,
        command: String,
        stage: DispatchTraceStage,
        route: DispatchRouteResolution? = nil,
        action: CommandAction? = nil,
        success: Bool? = nil,
        failureStage: DispatchFailureStage? = nil,
        summary: String? = nil,
        metadata: [String: String] = [:]
    ) {
        let event = DispatchTraceEvent(
            id: UUID(),
            traceID: traceID,
            timestamp: Date(),
            stage: stage,
            command: command,
            routeID: route?.card.id,
            routeSource: route?.source.rawValue,
            actionSummary: DispatchLearningStore.actionSummary(action ?? route?.action),
            success: success,
            failureStage: failureStage?.rawValue,
            summary: summary,
            metadata: metadata
        )
        guard let data = try? encoder.encode(event) else { return }
        let fileURL = tracesDirectory.appendingPathComponent("\(Self.dayFormatter.string(from: event.timestamp)).jsonl")
        appendLine(data, to: fileURL)
    }

    func recentEvents(limit: Int = 200) -> [DispatchTraceEvent] {
        Self.flushPendingWrites()
        let files = ((try? fileManager.contentsOfDirectory(
            at: tracesDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? [])
            .filter { $0.pathExtension == "jsonl" }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate > rhsDate
            }

        var events: [DispatchTraceEvent] = []
        for file in files {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in content.split(separator: "\n").reversed() {
                guard let event = try? decoder.decode(DispatchTraceEvent.self, from: Data(line.utf8)) else { continue }
                events.append(event)
                if events.count >= limit {
                    return events.sorted { $0.timestamp > $1.timestamp }
                }
            }
        }
        return events.sorted { $0.timestamp > $1.timestamp }
    }

    var tracesDirectoryPath: String {
        tracesDirectory.path
    }

    private func appendLine(_ data: Data, to fileURL: URL) {
        let fileManager = fileManager
        Self.ioQueue.async {
            try? fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fileManager.fileExists(atPath: fileURL.path) {
                fileManager.createFile(atPath: fileURL.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.write(contentsOf: Data("\n".utf8))
        }
    }

    private static func flushPendingWrites() {
        ioQueue.sync {}
    }

    private func contextMetadata(_ contextPacket: ContextPacket?) -> [String: String] {
        guard let surface = contextPacket?.surface else {
            return ["context": "none"]
        }
        var metadata: [String: String] = [
            "surface_kind": surface.kind.rawValue,
            "field_kind": surface.fieldKind.rawValue
        ]
        metadata["app_name"] = surface.appName
        metadata["bundle_id"] = surface.bundleId
        metadata["window_title"] = surface.windowTitle
        metadata["browser_url"] = surface.browserURL
        metadata["site_host"] = surface.siteHost
        if contextPacket?.targetFingerprint != nil {
            metadata["ax_target"] = "available"
        }
        return metadata
    }
}
