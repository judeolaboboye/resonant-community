import Foundation
import XCTest
@testable import Resonant

final class RecoveryStoreTests: XCTestCase {
    func testSaveActiveCaptureReportsMarkerWriteFailure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data([0]).write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let recovery = ActiveCaptureRecovery(
            id: UUID(),
            kind: .dictation,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            audioPath: "/tmp/capture.m4a",
            targetAppName: nil,
            targetBundleId: nil,
            windowTitle: nil,
            browserURL: nil
        )

        let saved = await RecoveryStore(rootURL: root).saveActiveCapture(recovery)

        XCTAssertFalse(saved)
    }

    func testActiveCaptureRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = RecoveryStore(rootURL: root)
        let recovery = ActiveCaptureRecovery(
            id: UUID(),
            kind: .dictation,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            audioPath: root.appendingPathComponent("capture.m4a").path,
            targetAppName: "Notes",
            targetBundleId: "com.apple.Notes",
            windowTitle: "Draft",
            browserURL: nil
        )

        await store.saveActiveCapture(recovery)
        let loaded = await store.loadActiveCapture()

        XCTAssertEqual(loaded, recovery)
    }

    func testClearActiveCaptureHonorsID() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = RecoveryStore(rootURL: root)
        let recovery = ActiveCaptureRecovery(
            id: UUID(),
            kind: .memo,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            audioPath: root.appendingPathComponent("memo.m4a").path,
            targetAppName: nil,
            targetBundleId: nil,
            windowTitle: nil,
            browserURL: nil
        )

        await store.saveActiveCapture(recovery)
        await store.clearActiveCapture(id: UUID())
        let stillLoaded = await store.loadActiveCapture()
        XCTAssertEqual(stillLoaded, recovery)

        await store.clearActiveCapture(id: recovery.id)
        let cleared = await store.loadActiveCapture()
        XCTAssertNil(cleared)
    }

    func testPurgeOrphanedCaptureFilesKeepsOnlyMarkedAudio() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let captureDirectory = root
            .appendingPathComponent("recovery", isDirectory: true)
            .appendingPathComponent("captures", isDirectory: true)
        try FileManager.default.createDirectory(
            at: captureDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let kept = captureDirectory.appendingPathComponent("kept.caf")
        let orphan = captureDirectory.appendingPathComponent("orphan.caf")
        try Data([1]).write(to: kept)
        try Data([2]).write(to: orphan)

        await RecoveryStore(rootURL: root).purgeOrphanedCaptureFiles(
            keepingAudioPath: kept.path
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testPrepareActiveCaptureForPersistenceStoresDeduplicationIdentity() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = RecoveryStore(rootURL: root)
        let recovery = ActiveCaptureRecovery(
            id: UUID(),
            kind: .dictation,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            audioPath: root.appendingPathComponent("capture.m4a").path,
            targetAppName: "Notes",
            targetBundleId: "com.apple.Notes",
            windowTitle: "Draft",
            browserURL: nil
        )
        let entryID = UUID()
        let entryDate = Date(timeIntervalSince1970: 1_700_000_100)

        let saved = await store.saveActiveCapture(recovery)
        let wrongIDPrepared = await store.prepareActiveCaptureForPersistence(
            id: UUID(),
            entryID: entryID,
            entryDate: entryDate,
            shouldPersistAudio: true
        )
        let prepared = await store.prepareActiveCaptureForPersistence(
            id: recovery.id,
            entryID: entryID,
            entryDate: entryDate,
            shouldPersistAudio: true
        )

        XCTAssertTrue(saved)
        XCTAssertFalse(wrongIDPrepared)
        XCTAssertTrue(prepared)

        let loadedValue = await store.loadActiveCapture()
        let loaded = try XCTUnwrap(loadedValue)
        XCTAssertEqual(loaded.pendingEntryID, entryID)
        XCTAssertEqual(loaded.pendingEntryDate, entryDate)
        XCTAssertEqual(loaded.shouldPersistAudio, true)
        XCTAssertEqual(loaded.pendingDisposition, .persist)

        let markedForDiscard = await store.markActiveCaptureForDiscard(id: recovery.id)
        XCTAssertTrue(markedForDiscard)
        let discardedValue = await store.loadActiveCapture()
        XCTAssertEqual(discardedValue?.pendingDisposition, .discard)
    }

    func testLegacyRecoveryMarkerDecodesWithoutPersistenceMetadata() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let recoveryDirectory = root.appendingPathComponent("recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let legacyJSON = """
        {
          "id": "\(id.uuidString)",
          "kind": "dictation",
          "startedAt": "2023-11-14T22:13:20Z",
          "audioPath": "/tmp/legacy.m4a"
        }
        """
        try Data(legacyJSON.utf8).write(
            to: recoveryDirectory.appendingPathComponent("active-capture.json"),
            options: .atomic
        )

        let loaded = await RecoveryStore(rootURL: root).loadActiveCapture()
        XCTAssertEqual(loaded?.id, id)
        XCTAssertNil(loaded?.pendingEntryID)
        XCTAssertNil(loaded?.pendingEntryDate)
        XCTAssertNil(loaded?.shouldPersistAudio)
        XCTAssertNil(loaded?.pendingDisposition)
    }

    func testUnreadableMarkerIsPreservedAndScopedClearFailsClosed() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let recoveryDirectory = root.appendingPathComponent("recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let markerURL = recoveryDirectory.appendingPathComponent("active-capture.json")
        try Data("not-json".utf8).write(to: markerURL)
        let store = RecoveryStore(rootURL: root)

        let loadResult = await store.loadActiveCaptureResult()
        let scopedClear = await store.clearActiveCapture(id: UUID())

        XCTAssertEqual(loadResult, .unreadable)
        XCTAssertFalse(scopedClear)
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))

        let unscopedClear = await store.clearActiveCapture()
        XCTAssertTrue(unscopedClear)
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
    }

    func testMarkerSnapshotRestoresUnreadableBytesExactly() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let recoveryDirectory = root.appendingPathComponent("recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let markerURL = recoveryDirectory.appendingPathComponent("active-capture.json")
        let original = Data("{corrupt-but-important".utf8)
        try original.write(to: markerURL)
        let store = RecoveryStore(rootURL: root)

        let snapshotValue = await store.snapshotActiveCaptureMarker()
        let snapshot = try XCTUnwrap(snapshotValue)
        XCTAssertTrue(snapshot.markerExisted)
        let cleared = await store.clearActiveCapture()
        let restored = await store.restoreActiveCaptureMarker(snapshot)
        XCTAssertTrue(cleared)
        XCTAssertTrue(restored)

        XCTAssertEqual(try Data(contentsOf: markerURL), original)
        let loadResult = await store.loadActiveCaptureResult()
        XCTAssertEqual(loadResult, .unreadable)
    }

    func testMissingMarkerSnapshotRemovesLaterMarkerOnRestore() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(rootURL: root)
        let snapshotValue = await store.snapshotActiveCaptureMarker()
        let snapshot = try XCTUnwrap(snapshotValue)
        XCTAssertFalse(snapshot.markerExisted)

        let recovery = ActiveCaptureRecovery(
            id: UUID(),
            kind: .dictation,
            startedAt: .now,
            audioPath: "/tmp/later.caf",
            targetAppName: nil,
            targetBundleId: nil,
            windowTitle: nil,
            browserURL: nil
        )
        let saved = await store.saveActiveCapture(recovery)
        let restored = await store.restoreActiveCaptureMarker(snapshot)
        let loadResult = await store.loadActiveCaptureResult()
        XCTAssertTrue(saved)
        XCTAssertTrue(restored)
        XCTAssertEqual(loadResult, .missing)
    }
}
