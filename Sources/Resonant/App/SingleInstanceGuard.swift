import AppKit

/// Terminates older running copies of this app when a new one launches. Debug
/// and agent workflows relaunch the app without quitting the prior instance;
/// every stale copy keeps its hotkey event tap and can win the race to service
/// a dictation with a wedged audio stack. Headless `--mcp` server processes
/// never initialize NSApplication, so LaunchServices does not list them and
/// this guard cannot touch them.
@MainActor
enum SingleInstanceGuard {
    static func terminateOlderInstances() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        let current = NSRunningApplication.current
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        let stalePIDs = SingleInstanceTerminationPolicy.instancesToTerminate(
            currentProcessIdentifier: current.processIdentifier,
            currentLaunchDate: current.launchDate,
            others: others.map {
                SingleInstanceTerminationPolicy.Instance(
                    processIdentifier: $0.processIdentifier,
                    launchDate: $0.launchDate
                )
            }
        )
        let stale = others.filter { stalePIDs.contains($0.processIdentifier) }
        guard !stale.isEmpty else { return }

        for app in stale {
            app.terminate()
        }
        Task {
            // A wedged instance (stalled main thread, disabled event tap)
            // never services the polite request; escalate so it can't keep
            // its tap or a dead mic session alive.
            try? await Task.sleep(for: .seconds(3))
            for app in stale where !app.isTerminated {
                app.forceTerminate()
            }
        }
    }
}

/// Which co-running instances a launching instance may kill: strictly older
/// ones, by launch date with process id as the tiebreak. The newest instance
/// survives; an instance that sees a newer sibling leaves it alone and waits
/// to be terminated by it, so simultaneous launches converge on one survivor.
enum SingleInstanceTerminationPolicy {
    struct Instance: Equatable, Sendable {
        let processIdentifier: pid_t
        let launchDate: Date?

        init(processIdentifier: pid_t, launchDate: Date?) {
            self.processIdentifier = processIdentifier
            self.launchDate = launchDate
        }
    }

    static func instancesToTerminate(
        currentProcessIdentifier: pid_t,
        currentLaunchDate: Date?,
        others: [Instance]
    ) -> Set<pid_t> {
        let currentKey = sortKey(
            launchDate: currentLaunchDate,
            processIdentifier: currentProcessIdentifier
        )
        return Set(
            others
                .filter { $0.processIdentifier != currentProcessIdentifier }
                .filter {
                    sortKey(
                        launchDate: $0.launchDate,
                        processIdentifier: $0.processIdentifier
                    ) < currentKey
                }
                .map(\.processIdentifier)
        )
    }

    private static func sortKey(
        launchDate: Date?,
        processIdentifier: pid_t
    ) -> (TimeInterval, pid_t) {
        ((launchDate ?? .distantPast).timeIntervalSinceReferenceDate, processIdentifier)
    }
}
