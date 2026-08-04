import Foundation
import os

/// Wall-clock + signpost instrumentation for the dictation critical path.
///
/// One instance per dictation. `endDictation` creates it, marks `stop`, and
/// passes the same instance through `stopAndTranscribe` and `handleResult`.
/// On `finish`, durations between marks are emitted both as signposts (for
/// Instruments) and a single compact NSLog line readable from Console.app.
@MainActor
final class DictationLatencyLogger {

    private static let signposter = OSSignposter(
        subsystem: "com.resonance.resonant",
        category: "dictation.latency"
    )

    private static let log = OSLog(
        subsystem: "com.resonance.resonant",
        category: "dictation.latency"
    )

    private let signpostID: OSSignpostID
    private let stopAt: ContinuousClock.Instant
    private let now: () -> ContinuousClock.Instant
    private var marks: [(name: String, at: ContinuousClock.Instant)] = []
    private var terminalAt: ContinuousClock.Instant?
    private var outcome: String?
    private var finished = false
    private var finalTelemetryEvent: PerformanceExperiments.DictationLatencyEvent?
    private(set) var targetBundleId: String?

    init(
        targetBundleId: String?,
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.signpostID = Self.signposter.makeSignpostID()
        self.now = now
        self.stopAt = now()
        self.targetBundleId = targetBundleId
        marks.reserveCapacity(16)
        Self.signposter.emitEvent("dictation.stop", id: signpostID)
    }

    /// Update the bundle id once we've resolved hot context.
    func setTargetBundleId(_ bundleId: String?) {
        guard let bundleId, !bundleId.isEmpty else { return }
        targetBundleId = bundleId
    }

    func mark(_ name: StaticString) {
        let timestamp = now()
        marks.append((name: String(describing: name), at: timestamp))
        Self.signposter.emitEvent(name, id: signpostID)
    }

    /// Emit the compact summary line. Safe to call multiple times — second call no-ops.
    @discardableResult
    func finish(outcome: String = "success") -> PerformanceExperiments.DictationLatencyEvent {
        if finished, let finalTelemetryEvent {
            return finalTelemetryEvent
        }
        finished = true
        terminalAt = now()
        self.outcome = PerformanceExperiments.sanitizedOutcome(outcome)

        let telemetryEvent = makeTelemetryEvent()
        finalTelemetryEvent = telemetryEvent
        Task { @MainActor in
            PerformanceExperiments.shared.recordDictationLatency(telemetryEvent)
        }

        guard Self.shouldLog else { return telemetryEvent }

        let line = formatSummary()
        os_log("%{public}@", log: Self.log, type: .info, line)
        NSLog("[DictationLatency] %@", line)
        return telemetryEvent
    }

    private func formatSummary() -> String {
        let metrics = makeMetrics()
        let target = targetBundleId ?? "unknown"
        return "stop→txStart=\(format(metrics.stopToTranscriptionStartMs)) captureStop=\(format(metrics.captureStopMs)) captureDiagnostics=\(format(metrics.captureDiagnosticsMs)) preTx=\(format(metrics.preTranscriptionMs)) tx=\(format(metrics.transcriptionMs)) recovery=\(format(metrics.segmentRecoveryMs)) ctxAwait=\(format(metrics.contextAwaitMs)) postProc=\(format(metrics.postProcessMs)) resolve=\(format(metrics.resolveDeliveryMs)) cloudCleanup=\(format(metrics.cloudCleanupMs)) transform=\(format(metrics.transformMs)) pasteSetup=\(format(metrics.pasteSetupMs)) paste=\(format(metrics.pasteMs)) total=\(format(metrics.totalMs)) outcome=\(outcome ?? "unknown") target=\(target)"
    }

    private func makeTelemetryEvent() -> PerformanceExperiments.DictationLatencyEvent {
        var event = makeMetrics()
        event.outcome = outcome
        event.targetBundleId = targetBundleId
        return event
    }

    private func makeMetrics() -> PerformanceExperiments.DictationLatencyEvent {
        var byName: [String: ContinuousClock.Instant] = [:]
        for mark in marks { byName[mark.name] = mark.at }

        func ms(_ from: ContinuousClock.Instant?, _ to: ContinuousClock.Instant?) -> Int? {
            guard let from, let to else { return nil }
            let nanos = (from.duration(to: to)).components.attoseconds / 1_000_000_000
            let seconds = (from.duration(to: to)).components.seconds
            return Int(seconds * 1_000 + nanos / 1_000_000)
        }

        let txStart = byName["txStart"]
        let txEnd = byName["txEnd"]
        let modelWaitStart = byName["modelWaitStart"]
        let modelWaitEnd = byName["modelWaitEnd"]
        let emptyRetryStart = byName["emptyRetryStart"]
        let emptyRetryEnd = byName["emptyRetryEnd"]
        let captureStopStart = byName["captureStopStart"]
        let captureStopEnd = byName["captureStopEnd"]
        let captureDiagnosticsEnd = byName["captureDiagnosticsEnd"]
        let recoveryStart = byName["recoveryStart"]
        let recoveryEnd = byName["recoveryEnd"]
        let ctxAwaitStart = byName["ctxAwaitStart"]
        let ctxAwaitEnd = byName["ctxAwaitEnd"]
        let postProcEnd = byName["postProcEnd"]
        let resolveStart = byName["resolveStart"]
        let resolveEnd = byName["resolveEnd"]
        let cloudCleanupStart = byName["cloudCleanupStart"]
        let cloudCleanupEnd = byName["cloudCleanupEnd"]
        let transformStart = byName["transformStart"]
        let transformEnd = byName["transformEnd"]
        let pasteStart = byName["pasteStart"]
        let pasteEnd = byName["pasteEnd"]

        return PerformanceExperiments.DictationLatencyEvent(
            outcome: nil,
            targetBundleId: nil,
            stopToTranscriptionStartMs: ms(stopAt, txStart),
            captureStopMs: ms(captureStopStart, captureStopEnd),
            captureDiagnosticsMs: ms(captureStopEnd, captureDiagnosticsEnd),
            preTranscriptionMs: ms(captureDiagnosticsEnd, txStart),
            modelWaitMs: ms(modelWaitStart, modelWaitEnd),
            transcriptionMs: ms(txStart, txEnd),
            emptyRetryMs: ms(emptyRetryStart, emptyRetryEnd),
            segmentRecoveryMs: ms(recoveryStart, recoveryEnd),
            contextAwaitMs: ms(ctxAwaitStart, ctxAwaitEnd),
            postProcessMs: ms(ctxAwaitEnd ?? txEnd, postProcEnd),
            resolveDeliveryMs: ms(resolveStart, resolveEnd),
            cloudCleanupMs: ms(cloudCleanupStart, cloudCleanupEnd),
            transformMs: ms(transformStart, transformEnd),
            pasteSetupMs: ms(resolveEnd ?? postProcEnd, pasteStart),
            pasteMs: ms(pasteStart, pasteEnd),
            totalMs: ms(stopAt, terminalAt ?? pasteEnd ?? resolveEnd ?? postProcEnd ?? txEnd ?? txStart)
        )
    }

    private func format(_ milliseconds: Int?) -> String {
        guard let milliseconds else { return "—" }
        return "\(milliseconds)ms"
    }

    /// Whether to actually emit log lines. Always on in DEBUG; release builds gate
    /// behind `defaults write com.resonance.resonant dictationLatencyLogging -bool YES`.
    private static var shouldLog: Bool {
        #if DEBUG
        return true
        #else
        return UserDefaults.standard.bool(forKey: "dictationLatencyLogging")
        #endif
    }
}
