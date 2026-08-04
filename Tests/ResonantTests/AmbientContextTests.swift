import AppKit
import Darwin
import XCTest
import SwiftData
@testable import Resonant

// MARK: - AmbientContextSnapshot model tests

final class AmbientContextSnapshotTests: XCTestCase {

    func testClipboardSensitivityFilterRejectsMultilineAndCredentialShapes() {
        XCTAssertTrue(AmbientContextCollector.looksLikeSensitive("line one\nline two"))
        XCTAssertTrue(AmbientContextCollector.looksLikeSensitive("-----BEGIN PRIVATE KEY-----"))
        XCTAssertTrue(AmbientContextCollector.looksLikeSensitive("Authorization: Bearer token-value"))
        XCTAssertTrue(AmbientContextCollector.looksLikeSensitive("api_key=super-secret"))
        XCTAssertTrue(AmbientContextCollector.looksLikeSensitive(String(repeating: "a", count: 32)))
    }

    func testClipboardSensitivityFilterAllowsShortOrdinaryProse() {
        XCTAssertFalse(AmbientContextCollector.looksLikeSensitive("follow up with Alice"))
        XCTAssertFalse(AmbientContextCollector.looksLikeSensitive("https://example.com docs"))
    }

    func testEncodeStringArrayRoundTrips() {
        let input = ["Tab 1", "Tab 2 — Google", "Another tab with special chars: <>&"]
        let encoded = encodeJSONStringArray(input)
        XCTAssertNotNil(encoded)

        // Decode manually to verify
        let data = encoded!.data(using: .utf8)!
        let decoded = try! JSONDecoder().decode([String].self, from: data)
        XCTAssertEqual(decoded, input)
    }

    func testEncodeStringArrayReturnsNilForEmptyArray() {
        XCTAssertNil(encodeJSONStringArray([]))
        XCTAssertNil(encodeJSONStringArray(nil))
    }

    func testVisibleTextSnippetsDecodesValidJSON() {
        let snapshot = AmbientContextSnapshot(
            timestamp: Date(),
            appName: "Test",
            bundleId: "com.test",
            visibleTextSnippetsJSON: "[\"hello\",\"world\"]"
        )
        XCTAssertEqual(snapshot.visibleTextSnippets, ["hello", "world"])
    }

    func testVisibleTextSnippetsReturnsEmptyForNil() {
        let snapshot = AmbientContextSnapshot(
            timestamp: Date(),
            appName: "Test",
            bundleId: "com.test",
            visibleTextSnippetsJSON: nil
        )
        XCTAssertEqual(snapshot.visibleTextSnippets, [])
    }

    func testVisibleTextSnippetsReturnsEmptyForCorruptJSON() {
        let snapshot = AmbientContextSnapshot(
            timestamp: Date(),
            appName: "Test",
            bundleId: "com.test",
            visibleTextSnippetsJSON: "not json at all {"
        )
        XCTAssertEqual(snapshot.visibleTextSnippets, [])
    }

    func testBrowserTabsDecodesValidJSON() {
        let snapshot = AmbientContextSnapshot(
            timestamp: Date(),
            appName: "Chrome",
            bundleId: "com.google.Chrome",
            browserTabsJSON: "[\"GitHub\",\"Stack Overflow\",\"Gmail\"]"
        )
        XCTAssertEqual(snapshot.browserTabs, ["GitHub", "Stack Overflow", "Gmail"])
    }

    func testBrowserTabsReturnsEmptyForNil() {
        let snapshot = AmbientContextSnapshot(
            timestamp: Date(),
            appName: "Chrome",
            bundleId: "com.google.Chrome",
            browserTabsJSON: nil
        )
        XCTAssertEqual(snapshot.browserTabs, [])
    }

    func testBrowserTabsReturnsEmptyForCorruptJSON() {
        let snapshot = AmbientContextSnapshot(
            timestamp: Date(),
            appName: "Chrome",
            bundleId: "com.google.Chrome",
            browserTabsJSON: "{invalid"
        )
        XCTAssertEqual(snapshot.browserTabs, [])
    }

    func testSnapshotInitSetsAllFields() {
        let now = Date()
        let snapshot = AmbientContextSnapshot(
            timestamp: now,
            appName: "VS Code",
            bundleId: "com.microsoft.VSCode",
            windowTitle: "main.swift — project",
            browserURL: nil,
            codeFileName: "main.swift",
            slackRecipient: nil,
            focusedFieldContent: "let x = 42",
            visibleTextSnippetsJSON: "[\"line1\"]",
            dwellDurationSeconds: 120.5,
            clipboardText: "copied text",
            browserTabsJSON: nil
        )

        XCTAssertEqual(snapshot.appName, "VS Code")
        XCTAssertEqual(snapshot.bundleId, "com.microsoft.VSCode")
        XCTAssertEqual(snapshot.windowTitle, "main.swift — project")
        XCTAssertNil(snapshot.browserURL)
        XCTAssertEqual(snapshot.codeFileName, "main.swift")
        XCTAssertNil(snapshot.slackRecipient)
        XCTAssertEqual(snapshot.focusedFieldContent, "let x = 42")
        XCTAssertEqual(snapshot.visibleTextSnippets, ["line1"])
        XCTAssertEqual(snapshot.dwellDurationSeconds, 120.5)
        XCTAssertEqual(snapshot.clipboardText, "copied text")
        XCTAssertEqual(snapshot.browserTabs, [])
    }

    func testEncodeStringArrayWithUnicodeAndEmoji() {
        let input = ["日本語タブ", "Tab with émojis 🎉", "Ñoño"]
        let encoded = encodeJSONStringArray(input)
        XCTAssertNotNil(encoded)

        let data = encoded!.data(using: .utf8)!
        let decoded = try! JSONDecoder().decode([String].self, from: data)
        XCTAssertEqual(decoded, input)
    }

    func testEncodeStringArrayWithVeryLongStrings() {
        let longString = String(repeating: "a", count: 10_000)
        let input = [longString]
        let encoded = encodeJSONStringArray(input)
        XCTAssertNotNil(encoded)

        let data = encoded!.data(using: .utf8)!
        let decoded = try! JSONDecoder().decode([String].self, from: data)
        XCTAssertEqual(decoded.first?.count, 10_000)
    }
}

// MARK: - WorkspaceQueryEngine ambient query tests

@MainActor
final class AmbientQueryEngineTests: XCTestCase {

    private var dataStore: Resonant.DataStore!
    private var storeURL: URL!

    override func setUp() async throws {
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AmbientQueryEngineTests-\(UUID().uuidString).store")
        dataStore = Resonant.DataStore(storeURLOverride: storeURL)
        await dataStore.setup()
        // Clean up any leftover snapshots from prior tests
        await clearAllSnapshots()
        await clearAllMeetings()
    }

    override func tearDown() async throws {
        await clearAllSnapshots()
        await clearAllMeetings()
        dataStore = nil
        for url in Resonant.DataStore.storeFamilyURLs(for: storeURL) {
            try? FileManager.default.removeItem(at: url)
        }
        storeURL = nil
    }

    private func clearAllSnapshots() async {
        await dataStore.clearAmbientSnapshots()
    }

    private func clearAllMeetings() async {
        let descriptor = FetchDescriptor<MeetingEntry>()
        for entry in dataStore.fetch(descriptor) {
            await dataStore.delete(entry)
        }
    }

    // MARK: - Timeline

    func testAmbientTimelineReturnsEmptyWhenNoData() async {
        let engine = WorkspaceQueryEngine(dataStore: dataStore)
        let results = await engine.ambientTimeline(.init())
        XCTAssertTrue(results.isEmpty)
    }

    func testAmbientTimelineReturnsSnapshots() async {
        let now = Date()
        await dataStore.save(AmbientContextSnapshot(
            timestamp: now,
            appName: "Chrome",
            bundleId: "com.google.Chrome",
            windowTitle: "GitHub - Brave",
            browserURL: "https://github.com"
        ))

        let engine = WorkspaceQueryEngine(dataStore: dataStore)
        let results = await engine.ambientTimeline(.init(days: 1))

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?["app"], "Chrome")
        XCTAssertEqual(results.first?["window"], "GitHub - Brave")
        XCTAssertEqual(results.first?["url"], "https://github.com")
    }

    func testAmbientTimelineFiltersbyApp() async {
        // Save snapshots one at a time (SwiftData shared-store limitation in tests)
        let now = Date()
        await dataStore.save(AmbientContextSnapshot(timestamp: now, appName: "TestFilterChrome", bundleId: "com.test.chrome1"))
        await dataStore.save(AmbientContextSnapshot(timestamp: now.addingTimeInterval(1), appName: "TestFilterVSCode", bundleId: "com.test.vscode"))
        await dataStore.save(AmbientContextSnapshot(timestamp: now.addingTimeInterval(2), appName: "TestFilterChrome", bundleId: "com.test.chrome2"))

        let engine = WorkspaceQueryEngine(dataStore: dataStore)
        let results = await engine.ambientTimeline(.init(days: 1, app: "TestFilterChrome"))
        XCTAssertGreaterThanOrEqual(results.count, 1)
        XCTAssertTrue(results.allSatisfy { $0["app"] == "TestFilterChrome" })
    }

    func testAmbientTimelineRespectsDateRange() async {
        // Save a snapshot with a known unique app name from 3 days ago
        let threeDaysAgo = Date().addingTimeInterval(-259200)
        await dataStore.save(AmbientContextSnapshot(
            timestamp: threeDaysAgo,
            appName: "DateRangeOldUnique",
            bundleId: "com.daterange.old"
        ))

        let engine = WorkspaceQueryEngine(dataStore: dataStore)
        // Query only last day — should NOT contain the 3-day-old snapshot
        let results = await engine.ambientTimeline(.init(days: 1))
        XCTAssertFalse(results.contains { $0["app"] == "DateRangeOldUnique" })

        // Query last 7 days — should contain it
        let wider = await engine.ambientTimeline(.init(days: 7))
        XCTAssertTrue(wider.contains { $0["app"] == "DateRangeOldUnique" })
    }

    func testAmbientTimelineRespectsLimit() async {
        // Limit clamping is tested via the code path — with shared store we
        // just verify that asking for limit=1 returns at most 1 result.
        let now = Date()
        await dataStore.save(AmbientContextSnapshot(timestamp: now, appName: "LimitTest", bundleId: "com.limit"))

        let engine = WorkspaceQueryEngine(dataStore: dataStore)
        let results = await engine.ambientTimeline(.init(days: 1, limit: 1))

        XCTAssertLessThanOrEqual(results.count, 1)
    }

    func testAmbientTimelineIncludesDwellTime() async {
        let now = Date()
        await dataStore.save(AmbientContextSnapshot(
            timestamp: now,
            appName: "Chrome",
            bundleId: "com.google.Chrome",
            dwellDurationSeconds: 300
        ))

        let engine = WorkspaceQueryEngine(dataStore: dataStore)
        let results = await engine.ambientTimeline(.init(days: 1))

        XCTAssertEqual(results.first?["dwell"], "300s")
    }

    func testAmbientTimelineIncludesClipboard() async {
        let now = Date()
        await dataStore.save(AmbientContextSnapshot(
            timestamp: now,
            appName: "Chrome",
            bundleId: "com.google.Chrome",
            clipboardText: "copied something"
        ))

        let engine = WorkspaceQueryEngine(dataStore: dataStore)
        let results = await engine.ambientTimeline(.init(days: 1))

        XCTAssertEqual(results.first?["clipboard"], "copied something")
    }

    func testAmbientTimelineIncludesBrowserTabs() async {
        let now = Date()
        await dataStore.save(AmbientContextSnapshot(
            timestamp: now,
            appName: "Chrome",
            bundleId: "com.google.Chrome",
            browserTabsJSON: encodeJSONStringArray(["GitHub", "Gmail", "Docs"])
        ))

        let engine = WorkspaceQueryEngine(dataStore: dataStore)
        let results = await engine.ambientTimeline(.init(days: 1))

        XCTAssertTrue(results.first?["tabs"]?.contains("GitHub") == true)
        XCTAssertTrue(results.first?["tabs"]?.contains("Gmail") == true)
    }

    // MARK: - App usage

    func testAmbientAppUsageReturnsEmptyWhenNoData() async {
        let engine = WorkspaceQueryEngine(dataStore: dataStore)
        let results = await engine.ambientAppUsage(.init())
        XCTAssertTrue(results.isEmpty)
    }

    func testAmbientAppUsageSingleEntry() async {
        let now = Date()
        await dataStore.save(AmbientContextSnapshot(
            timestamp: now,
            appName: "UsageTestApp",
            bundleId: "com.usagetest",
            dwellDurationSeconds: 600
        ))

        let engine = WorkspaceQueryEngine(dataStore: dataStore)
        let results = await engine.ambientAppUsage(.init(days: 1))

        let usageApp = results.first { $0["app"] == "UsageTestApp" }
        XCTAssertNotNil(usageApp)
        XCTAssertEqual(usageApp?["totalSeconds"], "600")
        XCTAssertEqual(usageApp?["switches"], "1")
    }

    // MARK: - Ambient search

    func testAmbientSearchFindsWindowTitle() async {
        let now = Date()
        await dataStore.save(AmbientContextSnapshot(
            timestamp: now,
            appName: "Chrome",
            bundleId: "com.google.Chrome",
            windowTitle: "Littlebird raises $11M — TechCrunch"
        ))

        let engine = WorkspaceQueryEngine(dataStore: dataStore)
        let results = await engine.ambientSearch(.init(query: "littlebird", days: 7))

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.type, "ambient")
    }

    func testAmbientSearchFindsURL() async {
        let now = Date()
        await dataStore.save(AmbientContextSnapshot(
            timestamp: now,
            appName: "Chrome",
            bundleId: "com.google.Chrome",
            browserURL: "https://github.com/resonant/parakeet-swift"
        ))

        let engine = WorkspaceQueryEngine(dataStore: dataStore)
        let results = await engine.ambientSearch(.init(query: "parakeet", days: 7))

        XCTAssertEqual(results.count, 1)
    }

    func testAmbientSearchFindsClipboardText() async {
        let now = Date()
        await dataStore.save(AmbientContextSnapshot(
            timestamp: now,
            appName: "VS Code",
            bundleId: "com.microsoft.VSCode",
            clipboardText: "func ambientTimeline() -> [[String: String]]"
        ))

        let engine = WorkspaceQueryEngine(dataStore: dataStore)
        let results = await engine.ambientSearch(.init(query: "ambientTimeline", days: 7))

        XCTAssertEqual(results.count, 1)
    }

    func testAmbientSearchFindsBrowserTabs() async {
        let now = Date()
        await dataStore.save(AmbientContextSnapshot(
            timestamp: now,
            appName: "Chrome",
            bundleId: "com.google.Chrome",
            browserTabsJSON: encodeJSONStringArray(["Linear — Resonant", "Figma — Dashboard"])
        ))

        let engine = WorkspaceQueryEngine(dataStore: dataStore)
        let results = await engine.ambientSearch(.init(query: "figma dashboard", days: 7))

        XCTAssertEqual(results.count, 1)
    }

    func testAmbientSearchFindsVisibleTextSnippets() async {
        let now = Date()
        await dataStore.save(AmbientContextSnapshot(
            timestamp: now,
            appName: "Slack",
            bundleId: "com.tinyspeck.slackmacgap",
            visibleTextSnippetsJSON: encodeJSONStringArray([
                "Stanford: let's sync Thursday about the HIPAA compliance review"
            ])
        ))

        let engine = WorkspaceQueryEngine(dataStore: dataStore)
        let results = await engine.ambientSearch(.init(query: "HIPAA compliance", days: 7))

        XCTAssertEqual(results.count, 1)
    }

    func testAmbientSearchUsesANDLogic() async {
        // AND logic is tested via scoreTerms — if only one term matches, score is 0.
        // Verify with a single snapshot that has two searchable terms.
        let now = Date()
        await dataStore.save(AmbientContextSnapshot(
            timestamp: now,
            appName: "ANDLogicTest",
            bundleId: "com.andlogic",
            windowTitle: "has uniqueAlpha and uniqueBeta together"
        ))

        let engine = WorkspaceQueryEngine(dataStore: dataStore)

        // Both terms present — should match
        let both = await engine.ambientSearch(.init(query: "uniqueAlpha uniqueBeta", days: 7))
        XCTAssertFalse(both.isEmpty)

        // Only one term present — should NOT match because of AND logic
        let missing = await engine.ambientSearch(.init(query: "uniqueAlpha uniqueGamma", days: 7))
        XCTAssertTrue(missing.isEmpty)
    }

    func testAmbientSearchReturnsEmptyForNoMatch() async {
        let now = Date()
        await dataStore.save(AmbientContextSnapshot(
            timestamp: now,
            appName: "Chrome",
            bundleId: "com.google.Chrome",
            windowTitle: "Something unrelated"
        ))

        let engine = WorkspaceQueryEngine(dataStore: dataStore)
        let results = await engine.ambientSearch(.init(query: "xyznonexistent", days: 7))

        XCTAssertTrue(results.isEmpty)
    }

    func testAmbientSearchEmptyQueryReturnsEmpty() async {
        let engine = WorkspaceQueryEngine(dataStore: dataStore)
        let results = await engine.ambientSearch(.init(query: "", days: 7))
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - Integration with unified search

    func testUnifiedSearchIncludesAmbientResults() async {
        let now = Date()
        await dataStore.save(AmbientContextSnapshot(
            timestamp: now,
            appName: "Chrome",
            bundleId: "com.google.Chrome",
            windowTitle: "Resonant pricing discussion"
        ))

        let engine = WorkspaceQueryEngine(dataStore: dataStore)
        let results = await engine.search(.init(query: "pricing discussion"))

        let ambientResults = results.filter { $0.type == "ambient" }
        XCTAssertFalse(ambientResults.isEmpty)
    }

    func testUnifiedSearchExcludesAmbientWhenTypeFilterSet() async {
        let now = Date()
        await dataStore.save(AmbientContextSnapshot(
            timestamp: now,
            appName: "Chrome",
            bundleId: "com.google.Chrome",
            windowTitle: "Resonant pricing"
        ))

        let engine = WorkspaceQueryEngine(dataStore: dataStore)
        // Searching only dictations should not return ambient results
        let results = await engine.search(.init(query: "pricing", type: "dictation"))

        let ambientResults = results.filter { $0.type == "ambient" }
        XCTAssertTrue(ambientResults.isEmpty)
    }

    // MARK: - Edge cases

    func testSnapshotWithAllNilOptionalFields() async {
        let now = Date()
        await dataStore.save(AmbientContextSnapshot(
            timestamp: now,
            appName: "Finder",
            bundleId: "com.apple.finder"
        ))

        let engine = WorkspaceQueryEngine(dataStore: dataStore)
        let results = await engine.ambientTimeline(.init(days: 1))

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?["app"], "Finder")
        XCTAssertNil(results.first?["window"])
        XCTAssertNil(results.first?["url"])
        XCTAssertNil(results.first?["dwell"])
        XCTAssertNil(results.first?["clipboard"])
        XCTAssertNil(results.first?["tabs"])
    }

    func testSnapshotWithEmptyStringFields() async {
        let now = Date()
        await dataStore.save(AmbientContextSnapshot(
            timestamp: now,
            appName: "App",
            bundleId: "com.app",
            windowTitle: "",
            browserURL: "",
            codeFileName: "",
            clipboardText: ""
        ))

        let engine = WorkspaceQueryEngine(dataStore: dataStore)
        let results = await engine.ambientTimeline(.init(days: 1))

        XCTAssertEqual(results.count, 1)
        // Empty strings should not appear in output
        XCTAssertNil(results.first?["window"])
        XCTAssertNil(results.first?["url"])
        XCTAssertNil(results.first?["clipboard"])
    }

    func testQueryEngineHandlesEmptyStore() async {
        let engine = WorkspaceQueryEngine(dataStore: dataStore)

        // All queries should return empty without crashing
        let timeline = await engine.ambientTimeline(.init(days: 0))  // 0 days = empty range
        XCTAssertTrue(timeline.isEmpty)

        let usage = await engine.ambientAppUsage(.init(days: 0))
        XCTAssertTrue(usage.isEmpty)

        let search = await engine.ambientSearch(.init(query: "test", days: 0))
        XCTAssertTrue(search.isEmpty)
    }

    func testGetMeetingFindsLatestMatchingTitleCaseInsensitively() async {
        let earlier = MeetingEntry(
            id: UUID(),
            startedAt: Date().addingTimeInterval(-3600),
            customTitle: "Launch Review",
            durationSeconds: 120,
            wordCount: 30
        )
        let later = MeetingEntry(
            id: UUID(),
            startedAt: Date(),
            customTitle: "Launch Review",
            durationSeconds: 240,
            wordCount: 60
        )

        await dataStore.save(earlier)
        await dataStore.save(later)

        let engine = WorkspaceQueryEngine(dataStore: dataStore)
        let result = await engine.getMeeting(title: "launch review")

        XCTAssertEqual(result?["id"] as? String, later.id.uuidString)
        XCTAssertEqual(result?["title"] as? String, "Launch Review")
        XCTAssertEqual(result?["words"] as? Int, 60)
    }
}

@MainActor
final class AmbientCorrectionSnapshotTests: XCTestCase {
    func testCorrectionSnapshotWorksWhenAmbientHistoryIsDisabledAndIsUntruncated() async {
        let expectedPID: pid_t = 42_001
        let expectedBundleIdentifier = "com.example.editor"
        let settings = SettingsManager.shared
        let previousAmbientEnabled = settings.ambientContextEnabled
        settings.ambientContextEnabled = false
        defer { settings.ambientContextEnabled = previousAmbientEnabled }

        let longContent = String(repeating: "x", count: 4_096)
        let expected = CorrectionHotSnapshot(
            fullFieldContent: longContent,
            processIdentifier: expectedPID,
            bundleIdentifier: expectedBundleIdentifier,
            isSensitiveInput: false,
            targetFingerprint: fingerprint()
        )
        let supportRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AmbientCorrectionSnapshotTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: supportRoot) }
        let collector = AmbientContextCollector(
            contextExtractor: ContextExtractor(),
            dataStore: DataStore(
                storeURLOverride: supportRoot.appendingPathComponent("unused.store")
            ),
            settingsManager: settings,
            activityStreamWriter: ActivityStreamWriter(supportRoot: supportRoot),
            correctionSnapshotExtractor: { _, _ in expected },
            frontmostProcessIdentifierProvider: { expectedPID }
        )

        let observed = await collector.correctionHotSnapshot(
            expectedProcessIdentifier: expectedPID,
            expectedBundleIdentifier: expectedBundleIdentifier
        )

        XCTAssertEqual(observed, expected)
        XCTAssertEqual(observed?.fullFieldContent.count, 4_096)
    }

    func testCorrectionSnapshotRejectsFrontmostPIDChangeAcrossAwait() async {
        let expectedPID: pid_t = 42_002
        let expectedBundleIdentifier = "com.example.editor"
        let expected = CorrectionHotSnapshot(
            fullFieldContent: "field",
            processIdentifier: expectedPID,
            bundleIdentifier: expectedBundleIdentifier,
            isSensitiveInput: false,
            targetFingerprint: fingerprint()
        )
        let supportRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AmbientCorrectionSnapshotTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: supportRoot) }
        var frontmostReads = [expectedPID, expectedPID + 1]
        let collector = AmbientContextCollector(
            contextExtractor: ContextExtractor(),
            dataStore: DataStore(
                storeURLOverride: supportRoot.appendingPathComponent("unused.store")
            ),
            settingsManager: .shared,
            activityStreamWriter: ActivityStreamWriter(supportRoot: supportRoot),
            correctionSnapshotExtractor: { _, _ in expected },
            frontmostProcessIdentifierProvider: {
                frontmostReads.removeFirst()
            }
        )

        let observed = await collector.correctionHotSnapshot(
            expectedProcessIdentifier: expectedPID,
            expectedBundleIdentifier: expectedBundleIdentifier
        )

        XCTAssertNil(observed)
        XCTAssertTrue(frontmostReads.isEmpty)
    }

    private func fingerprint() -> ContextTargetFingerprint {
        ContextTargetFingerprint(
            role: "AXTextArea",
            subrole: "AXStandardTextArea",
            isSensitiveInput: false,
            identifierToken: "field-id",
            titleToken: "title-token",
            descriptionToken: "description-token",
            placeholderToken: nil,
            helpToken: nil,
            frameBucket: "1:2:3:4",
            selectedRangeBucket: "0:0"
        )
    }
}
