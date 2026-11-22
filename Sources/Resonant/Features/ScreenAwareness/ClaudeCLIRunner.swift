import Foundation
import os

/// Runs the already-installed `claude` CLI (Claude Code) headlessly and
/// synchronously, so its answer (and any actions it takes) can be captured
/// and shown in the screen-awareness overlay. This rides the user's existing
/// Claude subscription — no separate Anthropic API key involved.
///
/// Limited action set, deliberately scoped down from a general-purpose
/// agent: it can look at the screenshot (Read), open an app or URL
/// (`Bash(open *)` only — not arbitrary shell commands), and look things up
/// (WebSearch/WebFetch). No file writes/edits, no unscoped Bash. This still
/// runs with NO interactive confirmation inside the CLI call itself —
/// headless `-p` mode has no hook for that — so `ScreenAwarenessManager`
/// gates every request up front with a Touch ID / password approval before
/// this runs at all. Never `--dangerously-skip-permissions`.
struct ClaudeCLIRunner {
    private let log = Logger.resonant("ClaudeCLIRunner")
    var timeout: Duration = .seconds(120)

    private static let allowedTools = "Read WebSearch WebFetch Bash(open *)"

    /// Common install locations, checked in order. GUI apps on macOS don't
    /// inherit the user's shell PATH/rc files, so `claude` may not resolve
    /// via `Process`'s default lookup even when it works fine in a terminal.
    private static let candidatePaths = [
        "~/.local/bin/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        "/usr/bin/claude",
    ]

    private static func resolveExecutable() -> URL? {
        for path in candidatePaths {
            let expanded = (path as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: expanded) {
                return URL(fileURLWithPath: expanded)
            }
        }
        return nil
    }

    /// Whether the CLI could be located, for a settings-page status line.
    static func isAvailable() -> Bool {
        resolveExecutable() != nil
    }

    func run(prompt: String) async throws -> String {
        guard let executableURL = Self.resolveExecutable() else {
            throw ScreenAwarenessError.claudeCLINotFound
        }

        let process = Process()
        process.executableURL = executableURL
        // Yields CPU to whatever else is running rather than competing with
        // foreground work — this process only lives for the ~10-15s of a
        // single request, but shouldn't feel like it's slowing anything else
        // down while it runs.
        process.qualityOfService = .utility
        process.arguments = [
            "-p", prompt,
            "--allowedTools", Self.allowedTools,
        ]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let accumulator = PipeAccumulator()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            accumulator.appendStdout(handle.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            accumulator.appendStderr(handle.availableData)
        }

        let timeoutTask = Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            accumulator.markTimedOut()
            if process.isRunning {
                process.terminate()
            }
        }

        do {
            try process.run()
        } catch {
            timeoutTask.cancel()
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            log.error("Failed to launch claude CLI: \(error, privacy: .public)")
            throw ScreenAwarenessError.claudeCLINotFound
        }

        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in continuation.resume() }
        }
        timeoutTask.cancel()
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        if accumulator.didTimeOut() {
            throw ScreenAwarenessError.claudeCLITimedOut
        }

        guard process.terminationStatus == 0 else {
            let stderrTail = accumulator.stderrTailString()
            log.error("claude CLI exited \(process.terminationStatus, privacy: .public): \(stderrTail, privacy: .public)")
            throw ScreenAwarenessError.claudeCLIFailed(
                exitCode: process.terminationStatus,
                stderrTail: stderrTail
            )
        }

        return accumulator.stdoutString().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Thread-safe accumulator for pipe data delivered on FileHandle's internal
/// dispatch queues, which run off the calling actor.
private final class PipeAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    private var timedOut = false

    func markTimedOut() {
        lock.lock(); timedOut = true; lock.unlock()
    }

    func didTimeOut() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return timedOut
    }

    func appendStdout(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock(); stdout.append(data); lock.unlock()
    }

    func appendStderr(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock(); stderr.append(data); lock.unlock()
    }

    func stdoutString() -> String {
        lock.lock(); defer { lock.unlock() }
        return String(data: stdout, encoding: .utf8) ?? ""
    }

    func stderrTailString() -> String {
        lock.lock(); defer { lock.unlock() }
        let tail = stderr.suffix(500)
        return String(data: tail, encoding: .utf8) ?? ""
    }
}
