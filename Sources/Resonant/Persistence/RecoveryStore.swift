import Foundation

struct ActiveCaptureRecovery: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case dictation
        case memo
    }

    enum PendingDisposition: String, Codable, Sendable {
        case persist
        case discard
    }

    let id: UUID
    let kind: Kind
    let startedAt: Date
    let audioPath: String
    let targetAppName: String?
    let targetBundleId: String?
    let windowTitle: String?
    let browserURL: String?
    var pendingEntryID: UUID? = nil
    var pendingEntryDate: Date? = nil
    var shouldPersistAudio: Bool? = nil
    var pendingDisposition: PendingDisposition? = nil

    var audioURL: URL {
        URL(fileURLWithPath: audioPath)
    }

    var elapsedDuration: TimeInterval {
        max(0, Date().timeIntervalSince(startedAt))
    }
}

/// Decides when an interrupted capture that keeps failing recovery should
/// stop blocking new dictations. Without this, one capture that can never be
/// transcribed (for example a fraction of a second cut off by a crash) is
/// retried on every launch and every new recording is refused.
enum InterruptedCaptureRecoveryPolicy {
    /// Captures shorter than this cannot hold a usable utterance.
    static let minimumRecoverableDuration: TimeInterval = 1.0
    /// Failed recovery attempts (one per launch) before the capture is set aside.
    static let maximumFailedAttempts = 2

    static func shouldSetAside(
        failedAttempts: Int,
        audioDuration: TimeInterval?,
        hasPendingEntry: Bool
    ) -> Bool {
        if failedAttempts >= maximumFailedAttempts { return true }
        // A pending entry proves the first pass produced text, so give the
        // retry budget a chance before giving up on it.
        guard !hasPendingEntry, let audioDuration else { return false }
        return audioDuration < minimumRecoverableDuration
    }
}

actor RecoveryStore {
    struct ActiveCaptureMarkerSnapshot: Sendable, Equatable {
        fileprivate let contents: Data?

        fileprivate init(contents: Data?) {
            self.contents = contents
        }

        var markerExisted: Bool { contents != nil }
    }

    enum ActiveCaptureLoadResult: Sendable, Equatable {
        case missing
        case loaded(ActiveCaptureRecovery)
        case unreadable
    }

    private let rootURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(rootURL: URL = AppSupportPaths.resonantRoot(), fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    @discardableResult
    func saveActiveCapture(_ recovery: ActiveCaptureRecovery) -> Bool {
        do {
            try fileManager.createDirectory(at: recoveryDirectoryURL, withIntermediateDirectories: true)
            let data = try encoder.encode(recovery)
            try data.write(to: activeCaptureURL, options: [.atomic])
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: activeCaptureURL.path)
            return true
        } catch {
            Self.report(error, source: "RecoveryStore.saveActiveCapture")
            print("[RecoveryStore] Failed to save active capture recovery marker: \(error)")
            return false
        }
    }

    @discardableResult
    func prepareActiveCaptureForPersistence(
        id: UUID,
        entryID: UUID,
        entryDate: Date,
        shouldPersistAudio: Bool
    ) -> Bool {
        guard case .loaded(var recovery) = loadActiveCaptureResult(),
              recovery.id == id else { return false }
        recovery.pendingEntryID = entryID
        recovery.pendingEntryDate = entryDate
        recovery.shouldPersistAudio = shouldPersistAudio
        recovery.pendingDisposition = .persist
        return saveActiveCapture(recovery)
    }

    @discardableResult
    func markActiveCaptureForDiscard(id: UUID) -> Bool {
        guard case .loaded(var recovery) = loadActiveCaptureResult(),
              recovery.id == id else { return false }
        recovery.pendingDisposition = .discard
        return saveActiveCapture(recovery)
    }

    func loadActiveCapture() -> ActiveCaptureRecovery? {
        guard case .loaded(let recovery) = loadActiveCaptureResult() else { return nil }
        return recovery
    }

    func loadActiveCaptureResult() -> ActiveCaptureLoadResult {
        guard fileManager.fileExists(atPath: activeCaptureURL.path) else {
            return .missing
        }
        do {
            let data = try Data(contentsOf: activeCaptureURL)
            return .loaded(try decoder.decode(ActiveCaptureRecovery.self, from: data))
        } catch {
            Self.report(error, source: "RecoveryStore.loadActiveCapture")
            return .unreadable
        }
    }

    /// Captures the marker bytes exactly, including an unreadable/corrupt
    /// marker. Destructive workflows use this as their rollback token so a
    /// later failure cannot silently turn an attempted clear/supersession into
    /// lost recovery ownership.
    func snapshotActiveCaptureMarker() -> ActiveCaptureMarkerSnapshot? {
        guard fileManager.fileExists(atPath: activeCaptureURL.path) else {
            return ActiveCaptureMarkerSnapshot(contents: nil)
        }
        do {
            return ActiveCaptureMarkerSnapshot(contents: try Data(contentsOf: activeCaptureURL))
        } catch {
            Self.report(error, source: "RecoveryStore.snapshotActiveCaptureMarker")
            return nil
        }
    }

    /// Restores a marker snapshot byte-for-byte. A missing-marker snapshot is
    /// restored by verifying that the current marker is absent.
    @discardableResult
    func restoreActiveCaptureMarker(_ snapshot: ActiveCaptureMarkerSnapshot) -> Bool {
        guard let contents = snapshot.contents else {
            return clearActiveCapture()
        }
        do {
            try fileManager.createDirectory(at: recoveryDirectoryURL, withIntermediateDirectories: true)
            try contents.write(to: activeCaptureURL, options: [.atomic])
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: activeCaptureURL.path)
            return try Data(contentsOf: activeCaptureURL) == contents
        } catch {
            Self.report(error, source: "RecoveryStore.restoreActiveCaptureMarker")
            return false
        }
    }

    @discardableResult
    func clearActiveCapture(id: UUID? = nil) -> Bool {
        if let id {
            switch loadActiveCaptureResult() {
            case .missing:
                return true
            case .loaded(let existing) where existing.id == id:
                break
            case .loaded, .unreadable:
                return false
            }
        }
        guard fileManager.fileExists(atPath: activeCaptureURL.path) else {
            return true
        }
        do {
            try fileManager.removeItem(at: activeCaptureURL)
            return !fileManager.fileExists(atPath: activeCaptureURL.path)
        } catch {
            Self.report(error, source: "RecoveryStore.clearActiveCapture")
            return false
        }
    }

    /// Moves a capture that recovery could not finish out of the active slot.
    /// The audio and its marker are kept under `recovery/unrecovered/` so
    /// nothing is lost, but the marker no longer blocks new captures.
    @discardableResult
    func setAsideActiveCapture(id: UUID) -> Bool {
        guard case .loaded(let recovery) = loadActiveCaptureResult(),
              recovery.id == id else { return false }
        do {
            try fileManager.createDirectory(at: unrecoveredDirectoryURL, withIntermediateDirectories: true)
            let audioURL = recovery.audioURL
            if fileManager.fileExists(atPath: audioURL.path) {
                let audioDestination = unrecoveredDirectoryURL
                    .appendingPathComponent("\(id.uuidString)-\(audioURL.lastPathComponent)")
                try fileManager.moveItem(at: audioURL, to: audioDestination)
            }
            let markerDestination = unrecoveredDirectoryURL
                .appendingPathComponent("\(id.uuidString).json")
            try? fileManager.removeItem(at: markerDestination)
            try fileManager.moveItem(at: activeCaptureURL, to: markerDestination)
            return !fileManager.fileExists(atPath: activeCaptureURL.path)
        } catch {
            Self.report(error, source: "RecoveryStore.setAsideActiveCapture")
            return false
        }
    }

    /// A fresh process has no live recorder other than the one named by the
    /// marker. Remove command-mode/crash leftovers from app-owned capture
    /// storage so switching away from purgeable `/tmp` does not create a
    /// permanent audio-retention leak.
    @discardableResult
    func purgeOrphanedCaptureFiles(keepingAudioPath: String?) -> Bool {
        let captureDirectory = recoveryDirectoryURL
            .appendingPathComponent("captures", isDirectory: true)
        guard fileManager.fileExists(atPath: captureDirectory.path) else { return true }
        let files: [URL]
        do {
            files = try fileManager.contentsOfDirectory(
                at: captureDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: .skipsHiddenFiles
            )
        } catch {
            Self.report(error, source: "RecoveryStore.purgeOrphanedCaptureFiles")
            return false
        }
        let keptPath = keepingAudioPath.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        }
        var allRemoved = true
        for file in files {
            guard file.standardizedFileURL.path != keptPath else { continue }
            do {
                try fileManager.removeItem(at: file)
                allRemoved = allRemoved && !fileManager.fileExists(atPath: file.path)
            } catch {
                allRemoved = false
                Self.report(error, source: "RecoveryStore.purgeOrphanedCaptureFiles")
            }
        }
        return allRemoved
    }

    private var recoveryDirectoryURL: URL {
        rootURL.appendingPathComponent("recovery", isDirectory: true)
    }

    private var unrecoveredDirectoryURL: URL {
        recoveryDirectoryURL.appendingPathComponent("unrecovered", isDirectory: true)
    }

    private var activeCaptureURL: URL {
        recoveryDirectoryURL.appendingPathComponent("active-capture.json")
    }

    private nonisolated static func report(_ error: Error, source: String) {
        Task { @MainActor in
            SentryManager.shared.captureException(error, context: ["source": source])
        }
    }
}
