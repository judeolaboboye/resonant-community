import Foundation
import XCTest
@testable import Resonant

@MainActor
final class MemoManagerTests: XCTestCase {
    func testReferencedAudioIsNeverConsideredAnOrphan() {
        let file = URL(fileURLWithPath: "/tmp/recent-memo.caf")

        XCTAssertFalse(MemoManager.shouldPurgeAudioFile(
            file,
            retainedAudioPaths: [file.standardizedFileURL.path]
        ))
        XCTAssertTrue(MemoManager.shouldPurgeAudioFile(
            file,
            retainedAudioPaths: []
        ))
    }

    func testFailedLoadPreservesExistingMemosAndDisablesOrphanSweep() async {
        let manager = MemoManager()
        let existing = await manager.save(text: "Keep this memo", duration: 1).memo

        let loaded = await manager.load(from: DataStore())

        XCTAssertFalse(loaded)
        XCTAssertFalse(manager.hasVerifiedMemoLoad)
        XCTAssertEqual(manager.memos.map(\.id), [existing.id])
    }

    func testOrphanSweepDeletesRecentUnreferencedFileAndPreservesReferencedFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let audioDirectory = root.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let referenced = audioDirectory.appendingPathComponent("referenced.caf")
        let recentOrphan = audioDirectory.appendingPathComponent("recent-orphan.caf")
        try Data([1]).write(to: referenced)
        try Data([2]).write(to: recentOrphan)

        await MemoManager.purgeUnreferencedAudioFiles(
            in: audioDirectory,
            retainedAudioPaths: [referenced.standardizedFileURL.path]
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: referenced.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recentOrphan.path))
    }

    func testSuccessfulAudioCopyRemovesSourceOnlyAfterCopy() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appendingPathComponent("capture.wav")
        try Data([0, 1, 2, 3]).write(to: sourceURL)
        let supportRoot = root.appendingPathComponent("support", isDirectory: true)

        let savedPath = MemoManager.persistAudioOffMain(
            from: sourceURL,
            memoID: UUID(),
            removeSourceAfterCopy: true,
            supportRoot: supportRoot
        )

        let relativePath = try XCTUnwrap(savedPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: supportRoot.appendingPathComponent(relativePath).path
        ))
    }

    func testFailedAudioCopyPreservesRecoverySource() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appendingPathComponent("capture.wav")
        try Data([0, 1, 2, 3]).write(to: sourceURL)
        let invalidSupportRoot = root.appendingPathComponent("not-a-directory")
        try Data([9]).write(to: invalidSupportRoot)

        let relativePath = MemoManager.persistAudioOffMain(
            from: sourceURL,
            memoID: UUID(),
            removeSourceAfterCopy: true,
            supportRoot: invalidSupportRoot
        )

        XCTAssertNil(relativePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
    }
}
