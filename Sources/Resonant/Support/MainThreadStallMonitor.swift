import Foundation
import os

@MainActor
final class MainThreadStallMonitor {
    static let shared = MainThreadStallMonitor()

    private nonisolated static let log = Logger(
        subsystem: "com.resonance.resonant",
        category: "main-thread"
    )
    private nonisolated static let pollIntervalMilliseconds: Int64 = 500
    private nonisolated static let warningThresholdMilliseconds: Int64 = 1_000
    private nonisolated static let severeThresholdMilliseconds: Int64 = 5_000

    private var task: Task<Void, Never>?

    private init() {}

    func start() {
        guard task == nil else { return }
        task = Task { @MainActor in
            var lastTick = ContinuousClock.now

            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(Self.pollIntervalMilliseconds))
                let now = ContinuousClock.now
                let elapsedMilliseconds = DiagnosticTiming.milliseconds(from: lastTick, to: now)
                let stallMilliseconds = elapsedMilliseconds - Self.pollIntervalMilliseconds
                if stallMilliseconds >= Self.warningThresholdMilliseconds {
                    Self.logStall(milliseconds: stallMilliseconds)
                }
                lastTick = now
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private nonisolated static func logStall(milliseconds: Int64) {
        let line = "mainActorStall=\(milliseconds)ms"
        if milliseconds >= severeThresholdMilliseconds {
            log.fault("main-thread.stall \(line, privacy: .public)")
        } else {
            log.warning("main-thread.stall \(line, privacy: .public)")
        }
        NSLog("[MainThreadStall] %@", line)
    }
}
