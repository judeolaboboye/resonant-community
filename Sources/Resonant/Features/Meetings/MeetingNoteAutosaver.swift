import Foundation
import SwiftData

/// Persists a meeting's live/post-meeting notes as the user types: debounced,
/// with writes serialized so they can't reorder. Owns its own task lifecycle —
/// `stop(for:)` cancels the pending write and detaches the notepad callback, so
/// a torn-down meeting can't keep a snapshot (and `self`) alive.
@MainActor
final class MeetingNoteAutosaver {
    private let dataStore: DataStore
    private var autosaveTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?

    init(dataStore: DataStore) {
        self.dataStore = dataStore
    }

    /// Starts autosaving `notepad`'s edits to the meeting identified by `sessionID`.
    func configure(sessionID: UUID, notepad: MeetingNotepad) {
        stop(for: notepad)
        notepad.onChange = { [weak self] snapshot in
            self?.schedule(sessionID: sessionID, snapshot: snapshot)
        }
    }

    /// Cancels any pending autosave and detaches the notepad callback.
    func stop(for notepad: MeetingNotepad) {
        autosaveTask?.cancel()
        autosaveTask = nil
        writeTask?.cancel()
        writeTask = nil
        notepad.onChange = nil
    }

    /// Workspace deletion needs evidence that no admitted note write can land
    /// after the database transaction. Cancel both layers and join them before
    /// returning.
    func stopAndWait(for notepad: MeetingNotepad) async {
        let pendingAutosave = autosaveTask
        let pendingWrite = writeTask
        pendingAutosave?.cancel()
        pendingWrite?.cancel()
        autosaveTask = nil
        writeTask = nil
        notepad.onChange = nil
        await pendingAutosave?.value
        await pendingWrite?.value
    }

    /// Synchronous variant for shutdown — uses the main context so the write
    /// lands before `applicationWillTerminate` returns and the process exits.
    func persistSync(sessionID: UUID, snapshot: MeetingNotepad.Snapshot) {
        guard let context = dataStore.context else { return }

        let normalizedUserNotes = Self.normalizedNoteString(snapshot.liveNotes)
        let normalizedPostMeetingNotes = Self.normalizedNoteString(snapshot.postMeetingNotes)

        var descriptor = FetchDescriptor<MeetingEntry>(
            predicate: #Predicate { $0.id == sessionID }
        )
        descriptor.fetchLimit = 1
        guard let entry = try? context.fetch(descriptor).first else { return }
        if entry.userNotes != normalizedUserNotes {
            entry.userNotes = normalizedUserNotes
        }
        if entry.postMeetingNotes != normalizedPostMeetingNotes {
            entry.postMeetingNotes = normalizedPostMeetingNotes
        }
        dataStore.saveChanges()
    }

    private func schedule(sessionID: UUID, snapshot: MeetingNotepad.Snapshot) {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled, let self else { return }

            let previousWriteTask = self.writeTask
            let writeTask = Task { [weak self] in
                await previousWriteTask?.value
                guard !Task.isCancelled, let self else { return }
                await self.persist(sessionID: sessionID, snapshot: snapshot)
            }

            self.writeTask = writeTask
            await writeTask.value
        }
    }

    private func persist(sessionID: UUID, snapshot: MeetingNotepad.Snapshot) async {
        let normalizedUserNotes = Self.normalizedNoteString(snapshot.liveNotes)
        let normalizedPostMeetingNotes = Self.normalizedNoteString(snapshot.postMeetingNotes)

        _ = await dataStore.performBackgroundWrite { context in
            var descriptor = FetchDescriptor<MeetingEntry>(
                predicate: #Predicate { $0.id == sessionID }
            )
            descriptor.fetchLimit = 1
            guard let entry = try? context.fetch(descriptor).first else { return }
            if entry.userNotes != normalizedUserNotes {
                entry.userNotes = normalizedUserNotes
            }
            if entry.postMeetingNotes != normalizedPostMeetingNotes {
                entry.postMeetingNotes = normalizedPostMeetingNotes
            }
        }
    }

    private static func normalizedNoteString(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
