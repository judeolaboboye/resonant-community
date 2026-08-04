import XCTest
@testable import Resonant

@MainActor
final class ActivityStreamWriterTests: XCTestCase {

    private var rootURL: URL!
    private var writer: ActivityStreamWriter!

    override func setUp() {
        super.setUp()
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResonantTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        writer = ActivityStreamWriter(fileManager: .default, supportRoot: rootURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: rootURL)
        writer = nil
        rootURL = nil
        super.tearDown()
    }

    func testWriteAmbientSnapshotCreatesDailyJSONL() async throws {
        let timestamp = Date(timeIntervalSince1970: 1_711_793_600) // 2024-03-30T00:00:00Z
        let snapshot = AmbientContextSnapshot(
            timestamp: timestamp,
            appName: "Brave Browser",
            bundleId: "com.brave.Browser",
            windowTitle: "Threads - Brave",
            browserURL: "https://www.threads.com/",
            focusedFieldContent: "reply draft",
            visibleTextSnippetsJSON: encodeJSONStringArray(["Threads", "Home feed"]),
            dwellDurationSeconds: 42,
            clipboardText: "copied text",
            browserTabsJSON: encodeJSONStringArray(["Threads", "GitHub"])
        )

        await writer.writeAmbientSnapshot(snapshot)

        let fileURL = ambientFileURL(for: timestamp)
        let data = try Data(contentsOf: fileURL)
        let lines = data.split(separator: 0x0A)
        XCTAssertEqual(lines.count, 1)

        let event = try JSONDecoder().decode(AmbientStreamEvent.self, from: Data(lines[0]))
        XCTAssertEqual(event.appName, "Brave Browser")
        XCTAssertEqual(event.browserURL, "https://www.threads.com/")
        XCTAssertEqual(event.windowTitle, "Threads - Brave")
        XCTAssertEqual(event.visibleTextSnippets ?? [], ["Threads", "Home feed"])
        XCTAssertEqual(event.browserTabs ?? [], ["Threads", "GitHub"])
        XCTAssertEqual(event.dwellDurationSeconds, 42)
    }

    func testPurgeOldFilesRemovesAmbientJSONL() async {
        let oldTimestamp = Calendar.current.date(byAdding: .day, value: -40, to: Date())!
        let newTimestamp = Date()

        await writer.writeAmbientSnapshot(AmbientContextSnapshot(
            timestamp: oldTimestamp,
            appName: "Old App",
            bundleId: "com.test.old"
        ))
        await writer.writeAmbientSnapshot(AmbientContextSnapshot(
            timestamp: newTimestamp,
            appName: "New App",
            bundleId: "com.test.new"
        ))

        await writer.purgeOldFiles(olderThan: 30)

        XCTAssertFalse(FileManager.default.fileExists(atPath: ambientFileURL(for: oldTimestamp).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ambientFileURL(for: newTimestamp).path))
    }

    func testWriteCurrentAmbientSnapshotCreatesCurrentJSON() async throws {
        let snapshot = AmbientContextSnapshot(
            timestamp: Date(),
            appName: "Brave Browser",
            bundleId: "com.brave.Browser",
            browserURL: "https://www.threads.com/"
        )

        await writer.writeCurrentAmbientSnapshot(snapshot)

        let data = try Data(contentsOf: currentAmbientFileURL())
        let event = try JSONDecoder().decode(AmbientStreamEvent.self, from: data)

        XCTAssertEqual(event.appName, "Brave Browser")
        XCTAssertEqual(event.browserURL, "https://www.threads.com/")
    }

    func testBootstrapAmbientFilesBackfillsHistoryAndCurrent() async throws {
        let earlier = Date(timeIntervalSince1970: 1_711_793_600)
        let later = earlier.addingTimeInterval(5)
        let snapshots = [
            AmbientContextSnapshot(
                timestamp: earlier,
                appName: "Finder",
                bundleId: "com.apple.finder",
                dwellDurationSeconds: 5
            ),
            AmbientContextSnapshot(
                timestamp: later,
                appName: "Code",
                bundleId: "com.microsoft.VSCode",
                windowTitle: "AppState.swift"
            )
        ]

        await writer.bootstrapAmbientFiles(from: snapshots)

        let historyData = try Data(contentsOf: ambientFileURL(for: earlier))
        let historyLines = historyData.split(separator: 0x0A)
        XCTAssertEqual(historyLines.count, 2)

        let currentData = try Data(contentsOf: currentAmbientFileURL())
        let current = try JSONDecoder().decode(AmbientStreamEvent.self, from: currentData)
        XCTAssertEqual(current.appName, "Code")
        XCTAssertEqual(current.windowTitle, "AppState.swift")
    }

    func testClearWorkspaceDataRemovesAmbientStreamFiles() async {
        await writer.writeAmbientSnapshot(AmbientContextSnapshot(
            timestamp: Date(),
            appName: "Finder",
            bundleId: "com.apple.finder"
        ))

        await writer.clearWorkspaceData()

        let ambientDirectory = rootURL
            .appendingPathComponent("stream", isDirectory: true)
            .appendingPathComponent("ambient", isDirectory: true)
        let contents = try? FileManager.default.contentsOfDirectory(
            at: ambientDirectory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: ambientDirectory.path))
        XCTAssertEqual(contents?.count, 0)
    }

    func testWriteMeetingEventCreatesDailyJSONL() async throws {
        let timestamp = Date(timeIntervalSince1970: 1_711_793_600)
        let meeting = MeetingEntry(
            id: UUID(uuidString: "5F7E3D4B-4D18-4C95-AAC1-BE0712E977CC")!,
            startedAt: timestamp,
            endedAt: timestamp.addingTimeInterval(900),
            detectedApp: "Zoom",
            customTitle: "Weekly Staff",
            durationSeconds: 900,
            wordCount: 1200
        )

        await writer.writeMeetingEvent(entry: meeting, transcript: "Speaker 1: Status update")

        let fileURL = eventsFileURL(for: timestamp)
        let data = try Data(contentsOf: fileURL)
        let lines = data.split(separator: 0x0A)
        XCTAssertEqual(lines.count, 1)

        let event = try JSONDecoder().decode(ActivityStreamEvent.self, from: Data(lines[0]))
        XCTAssertEqual(event.type, .meeting)
        XCTAssertEqual(event.meetingTitle, "Weekly Staff")
        XCTAssertEqual(event.appName, "Zoom")
        XCTAssertEqual(event.text, "Speaker 1: Status update")
    }

    func testRepeatedStableEventIDIsAppendedOnlyOnce() async throws {
        let timestamp = Date(timeIntervalSince1970: 1_711_793_600)
        let memo = MemoEntry(
            id: UUID(),
            text: "retry-safe memo",
            title: "Retry safe",
            duration: 2,
            date: timestamp
        )

        await writer.writeMemoEvent(memo: memo)
        await writer.writeMemoEvent(memo: memo)

        let data = try Data(contentsOf: eventsFileURL(for: timestamp))
        XCTAssertEqual(data.split(separator: 0x0A).count, 1)
    }

    func testUnreadableEventTargetFailsClosed() async throws {
        let timestamp = Date(timeIntervalSince1970: 1_711_793_600)
        let fileURL = eventsFileURL(for: timestamp)
        try FileManager.default.createDirectory(
            at: fileURL,
            withIntermediateDirectories: true
        )
        let memo = MemoEntry(
            id: UUID(),
            text: "must not append blindly",
            title: "Fail closed",
            duration: 1,
            date: timestamp
        )

        let committed = await writer.writeMemoEvent(memo: memo)

        XCTAssertFalse(committed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testRetryRepairsPartialJSONLTailBeforeDeduplication() async throws {
        let timestamp = Date(timeIntervalSince1970: 1_711_793_600)
        let first = MemoEntry(
            id: UUID(),
            text: "first",
            title: "First",
            duration: 1,
            date: timestamp
        )
        let retried = MemoEntry(
            id: UUID(),
            text: "retry",
            title: "Retry",
            duration: 1,
            date: timestamp
        )
        let firstCommitted = await writer.writeMemoEvent(memo: first)
        XCTAssertTrue(firstCommitted)

        let fileURL = eventsFileURL(for: timestamp)
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"id\":\"\(retried.id.uuidString)\"".utf8))
        try handle.close()

        let retryCommitted = await writer.writeMemoEvent(memo: retried)
        XCTAssertTrue(retryCommitted)
        let lines = try Data(contentsOf: fileURL).split(separator: 0x0A)
        XCTAssertEqual(lines.count, 2)
        let decoded = try lines.map { try JSONDecoder().decode(ActivityStreamEvent.self, from: Data($0)) }
        XCTAssertEqual(Set(decoded.map(\.id)), Set([first.id.uuidString, retried.id.uuidString]))
    }

    func testWorkspaceQuiescenceRejectsWritesUntilResumed() async {
        let timestamp = Date(timeIntervalSince1970: 1_711_793_600)
        let memo = MemoEntry(
            id: UUID(),
            text: "must respect clear barrier",
            title: "Barrier",
            duration: 1,
            date: timestamp
        )

        await writer.quiesceForWorkspaceClear()
        let blocked = await writer.writeMemoEvent(memo: memo)
        XCTAssertFalse(blocked)
        XCTAssertFalse(FileManager.default.fileExists(atPath: eventsFileURL(for: timestamp).path))

        writer.resumeAfterWorkspaceClear()
        let committed = await writer.writeMemoEvent(memo: memo)
        XCTAssertTrue(committed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: eventsFileURL(for: timestamp).path))
    }

    private func ambientFileURL(for date: Date) -> URL {
        rootURL
            .appendingPathComponent("stream", isDirectory: true)
            .appendingPathComponent("ambient", isDirectory: true)
            .appendingPathComponent("\(dateStem(for: date)).jsonl")
    }

    private func eventsFileURL(for date: Date) -> URL {
        rootURL
            .appendingPathComponent("stream", isDirectory: true)
            .appendingPathComponent("events", isDirectory: true)
            .appendingPathComponent("\(dateStem(for: date)).jsonl")
    }

    private func currentAmbientFileURL() -> URL {
        rootURL
            .appendingPathComponent("stream", isDirectory: true)
            .appendingPathComponent("ambient", isDirectory: true)
            .appendingPathComponent("current.json")
    }

    private func dateStem(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}
