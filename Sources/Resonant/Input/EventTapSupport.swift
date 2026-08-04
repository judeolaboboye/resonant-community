import Foundation

/// Dedicated user-interactive thread whose run loop services CGEventTap and
/// IOHIDManager sources, keeping input callbacks off the main thread.
///
/// All waits are bounded: with an active event tap installed, a caller (usually
/// the main thread) stuck waiting on this thread turns into system-wide
/// keyboard latency, so timing out and limping on beats freezing.
final class InputRunLoopThread {
    private static let syncTimeout: TimeInterval = 2

    private let name: String
    private let condition = NSCondition()
    private var thread: Thread?
    private var runLoop: CFRunLoop?

    init(name: String) {
        self.name = name
    }

    /// Runs `block` on the input run loop and waits for it to finish.
    /// Returns false if the run loop could not service the block in time;
    /// the block stays queued and may still execute later.
    @discardableResult
    func performSync(_ block: @escaping (CFRunLoop) -> Void) -> Bool {
        guard let runLoop = startIfNeeded() else { return false }
        let semaphore = DispatchSemaphore(value: 0)

        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
            block(runLoop)
            semaphore.signal()
        }
        CFRunLoopWakeUp(runLoop)
        return semaphore.wait(timeout: .now() + Self.syncTimeout) == .success
    }

    func stop() {
        condition.lock()
        let currentRunLoop = runLoop
        condition.unlock()

        guard let currentRunLoop else { return }

        let semaphore = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(currentRunLoop, CFRunLoopMode.defaultMode.rawValue) {
            CFRunLoopStop(currentRunLoop)
            semaphore.signal()
        }
        CFRunLoopWakeUp(currentRunLoop)
        guard semaphore.wait(timeout: .now() + Self.syncTimeout) == .success else { return }

        condition.lock()
        let deadline = Date().addingTimeInterval(Self.syncTimeout)
        while runLoop != nil {
            if !condition.wait(until: deadline) { break }
        }
        condition.unlock()
    }

    private func startIfNeeded() -> CFRunLoop? {
        condition.lock()
        if thread == nil {
            let newThread = Thread { [weak self] in
                self?.run()
            }
            newThread.name = name
            newThread.qualityOfService = .userInteractive
            thread = newThread
            newThread.start()
        }

        let deadline = Date().addingTimeInterval(Self.syncTimeout)
        while runLoop == nil {
            if !condition.wait(until: deadline) { break }
        }

        let currentRunLoop = runLoop
        condition.unlock()
        return currentRunLoop
    }

    private func run() {
        autoreleasepool {
            let keepAlivePort = Port()
            RunLoop.current.add(keepAlivePort, forMode: .default)

            condition.lock()
            runLoop = CFRunLoopGetCurrent()
            condition.broadcast()
            condition.unlock()

            CFRunLoopRun()

            condition.lock()
            runLoop = nil
            thread = nil
            condition.broadcast()
            condition.unlock()
        }
    }
}

/// Decides how long to wait before re-arming a CGEventTap that macOS disabled
/// for timing out. Re-arming instantly converts one process stall into
/// sustained system-wide keyboard latency (stall → 1s freeze → re-arm → stall
/// again); repeated timeouts back off exponentially so real user input keeps
/// flowing between stalls.
struct EventTapReenableBackoff {
    static let resetInterval: TimeInterval = 10
    static let maxDelay: TimeInterval = 4

    private(set) var consecutiveTimeouts = 0
    private var lastTimeoutAt: Date?

    /// Records a tap timeout and returns how long to wait before re-enabling.
    /// Zero means re-enable immediately (first stall in a while).
    mutating func recordTimeout(at now: Date = Date()) -> TimeInterval {
        if let lastTimeoutAt, now.timeIntervalSince(lastTimeoutAt) > Self.resetInterval {
            consecutiveTimeouts = 0
        }
        lastTimeoutAt = now
        consecutiveTimeouts += 1
        guard consecutiveTimeouts > 1 else { return 0 }
        return min(Self.maxDelay, 0.5 * pow(2, Double(consecutiveTimeouts - 2)))
    }
}
