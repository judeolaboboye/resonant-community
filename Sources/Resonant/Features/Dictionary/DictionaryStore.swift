import Foundation
import Observation
import SwiftData
import os

struct DictionaryCorrectionSnapshot: Sendable, Equatable {
    let spoken: String
    let written: String
    let regex: NSRegularExpression
    /// The entry only lowercases the word ("Vibe" → "vibe"). Applied everywhere
    /// except sentence starts, where the capital is grammar, not ASR style.
    let isCaseOnlyDowncase: Bool

    init(spoken: String, written: String, regex: NSRegularExpression, isCaseOnlyDowncase: Bool = false) {
        self.spoken = spoken
        self.written = written
        self.regex = regex
        self.isCaseOnlyDowncase = isCaseOnlyDowncase
    }

    static func == (lhs: DictionaryCorrectionSnapshot, rhs: DictionaryCorrectionSnapshot) -> Bool {
        lhs.spoken == rhs.spoken && lhs.written == rhs.written
    }
}

enum DictionaryCorrectionApplier {
    static func apply(_ corrections: [DictionaryCorrectionSnapshot], to text: String) -> String {
        guard !corrections.isEmpty else { return text }

        var result = text
        for correction in corrections {
            if correction.isCaseOnlyDowncase {
                result = applyDowncase(correction, to: result)
            } else {
                result = correction.regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: correction.written
                )
            }
        }
        return result
    }

    private static func applyDowncase(
        _ correction: DictionaryCorrectionSnapshot,
        to text: String
    ) -> String {
        let matches = correction.regex.matches(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        )
        guard !matches.isEmpty else { return text }

        var result = text
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            guard !isSentenceInitial(position: range.lowerBound, in: result) else { continue }
            result.replaceSubrange(range, with: correction.written)
        }
        return result
    }

    /// Scans backwards over whitespace and opening quotes/brackets; a match is
    /// sentence-initial when that scan hits the text start, terminal
    /// punctuation, or a line break.
    private static func isSentenceInitial(position: String.Index, in text: String) -> Bool {
        let skippable: Set<Character> = ["\"", "'", "\u{201C}", "\u{2018}", "(", "[", "*", "_"]
        var index = position
        while index > text.startIndex {
            index = text.index(before: index)
            let character = text[index]
            if character.isNewline || ".!?…:".contains(character) { return true }
            if character.isWhitespace || skippable.contains(character) { continue }
            return false
        }
        return true
    }
}

/// Stores user-provided word corrections and applies them during post-processing.
/// Supports both manually added entries (always applied) and auto-learned entries
/// (gated by correction count, ratio, and tier).
@MainActor
@Observable
final class DictionaryStore {
    typealias BoostDecisionDecayer = @MainActor (
        String,
        VocabularyBoostAuditSummary.FalseApplyReason
    ) async -> Int
    typealias BoostCorrelationRecorder = @MainActor (
        VocabularyBoostAudit.CorrectionSignals
    ) -> Void
    typealias WordSuppressionObserver = @MainActor (_ spoken: String, _ written: String) -> Void
    typealias VocabularyTermsObserver = @MainActor () -> Void

    struct WorkspaceWord: Codable, Equatable, Sendable {
        let id: UUID
        let spoken: String
        let written: String
        let createdAt: Date
        let correctedCount: Int
        let seenUncorrectedCount: Int
        let isAutoLearned: Bool
        let isSuppressed: Bool
        let spokenIsRealWord: Bool
        let lastSeenAt: Date

        init(word: DictionaryWord) {
            id = word.id
            spoken = word.spoken
            written = word.written
            createdAt = word.createdAt
            correctedCount = word.correctedCount
            seenUncorrectedCount = word.seenUncorrectedCount
            isAutoLearned = word.isAutoLearned
            isSuppressed = word.isSuppressed
            spokenIsRealWord = word.spokenIsRealWord
            lastSeenAt = word.lastSeenAt
        }
    }

    private struct WordSnapshot: Sendable {
        let id: UUID
        let spoken: String
        let written: String
        let createdAt: Date
        let correctedCount: Int
        let seenUncorrectedCount: Int
        let isAutoLearned: Bool
        let isSuppressed: Bool
        let spokenIsRealWord: Bool
        let lastSeenAt: Date

        init(word: DictionaryWord) {
            id = word.id
            spoken = word.spoken
            written = word.written
            createdAt = word.createdAt
            correctedCount = word.correctedCount
            seenUncorrectedCount = word.seenUncorrectedCount
            isAutoLearned = word.isAutoLearned
            isSuppressed = word.isSuppressed
            spokenIsRealWord = word.spokenIsRealWord
            lastSeenAt = word.lastSeenAt
        }
    }

    private let log = Logger.resonant("DictionaryStore")

    private var words: [String: DictionaryWord] = [:]
    private var dataStore: DataStore?
    private var dirtyWordIDs: Set<UUID> = []
    private var persistenceTasks: [UUID: Task<Void, Never>] = [:]
    private var activePersistenceCount = 0
    private var persistenceDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private var isWorkspaceWriteSuspended = false
    /// Serial tail for read-modify-write mutations of persisted audit JSON.
    /// Independent ModelContexts could otherwise both count the same decision
    /// or overwrite each other's feedback flag.
    private var boostFeedbackTail: Task<Void, Never>?

    private let boostDecisionDecayer: BoostDecisionDecayer?
    private let boostCorrelationRecorder: BoostCorrelationRecorder
    @ObservationIgnored var onWordSuppressed: WordSuppressionObserver?
    @ObservationIgnored var onVocabularyTermsChanged: VocabularyTermsObserver?

    private var regexCache: [String: NSRegularExpression] = [:]
    private var sortedKeysCache: [String]?

    // MARK: - Thresholds

    /// Auto-learned proper-noun corrections apply after a single deliberate fix.
    static let tier0Threshold = 1

    /// Auto-learned non-word corrections apply after this many observations.
    static let tier1Threshold = 2

    /// Auto-learned real-word corrections need a higher bar.
    static let tier2Threshold = 5

    /// Case-only downcase preferences ("Vibe" → "vibe") sit between: a style
    /// choice worth repeating evidence, but not the full real-word bar.
    static let caseDowncaseThreshold = 3

    /// Minimum correction ratio for auto-learned entries to be applied silently.
    static let minimumCorrectionRatio = 0.6

    /// Relaxed ratio guard for the proper-noun fast path — still blocks learning a
    /// word the user has repeatedly left uncorrected.
    static let fastPathMinimumCorrectionRatio = 0.5

    /// Notification posted when an auto-learned word first crosses its apply threshold.
    static let didAutoLearnWordNotification = Notification.Name("resonant.dictionaryWordAutoLearned")

    /// Lazily-computed proper-noun-ness of written forms, keyed by written text.
    /// Not persisted on DictionaryWord, so recomputed per process from the written form.
    private static var properNounCache: [String: Bool] = [:]

    init(
        boostDecisionDecayer: BoostDecisionDecayer? = nil,
        boostCorrelationRecorder: @escaping BoostCorrelationRecorder = {
            VocabularyBoostCorrelationRecorder.record($0)
        }
    ) {
        self.boostDecisionDecayer = boostDecisionDecayer
        self.boostCorrelationRecorder = boostCorrelationRecorder
    }

    func setup(store: DataStore) {
        dataStore = store
        let entries = store.fetch(FetchDescriptor<DictionaryWord>())
        words = Dictionary(uniqueKeysWithValues: entries.map {
            let clone = Self.cloneWord($0)
            return (clone.spoken.lowercased(), clone)
        })
        dirtyWordIDs.removeAll()
        invalidateCaches()
    }

    // MARK: - Apply corrections

    func applyCorrections(to text: String) -> String {
        guard !words.isEmpty else { return text }

        return DictionaryCorrectionApplier.apply(correctionSnapshot(), to: text)
    }

    func correctionSnapshot() -> [DictionaryCorrectionSnapshot] {
        sortedKeys().compactMap { spoken in
            guard let entry = words[spoken], shouldApply(entry) else { return nil }
            guard let regex = regex(for: spoken) else { return nil }
            return DictionaryCorrectionSnapshot(
                spoken: spoken,
                written: entry.written,
                regex: regex,
                isCaseOnlyDowncase: Self.isCaseDowncaseEntry(entry)
            )
        }
    }

    /// A pair that only lowercases the word ("Vibe" → "vibe").
    private static func isCaseDowncaseEntry(_ entry: DictionaryWord) -> Bool {
        entry.written == entry.written.lowercased()
            && entry.spoken.lowercased() == entry.written.lowercased()
            && entry.spoken != entry.written
    }

    /// Determines whether an entry should be applied during post-processing.
    private func shouldApply(_ entry: DictionaryWord) -> Bool {
        if entry.isSuppressed { return false }
        if !entry.isAutoLearned { return true }

        let threshold: Int
        let minimumRatio: Double
        if Self.isCaseDowncaseEntry(entry) {
            threshold = Self.caseDowncaseThreshold
            minimumRatio = Self.minimumCorrectionRatio
        } else if Self.isProperNounWritten(entry.written) {
            threshold = Self.tier0Threshold
            minimumRatio = Self.fastPathMinimumCorrectionRatio
        } else {
            threshold = entry.spokenIsRealWord ? Self.tier2Threshold : Self.tier1Threshold
            minimumRatio = Self.minimumCorrectionRatio
        }

        return Self.meetsEvidence(entry, threshold: threshold, minimumRatio: minimumRatio)
    }

    /// The count-and-ratio test every tier shares: enough deliberate fixes, and
    /// not a form the user keeps leaving alone.
    private static func meetsEvidence(
        _ entry: DictionaryWord,
        threshold: Int,
        minimumRatio: Double
    ) -> Bool {
        guard entry.correctedCount >= threshold else { return false }
        let total = entry.correctedCount + entry.seenUncorrectedCount
        guard total > 0 else { return false }
        return Double(entry.correctedCount) / Double(total) >= minimumRatio
    }

    /// Whether an entry may additionally bias the *decode* — a strictly higher
    /// bar than applying it as post-processing text.
    ///
    /// The two consumers carry very different risk. A stored pair rewrites text
    /// only where the decode literally emitted `spoken`, so a bad pair stays
    /// inert until that exact token appears. Handing `written` to the CTC
    /// rescorer instead enters it into acoustic competition with every
    /// similar-sounding word of every future dictation — one bad admission
    /// ("Tees → Thijs") then overwrites unrelated real speech ("things").
    ///
    /// So the proper-noun fast path stays a text-layer affordance: one
    /// deliberate fix is enough to rewrite that exact token, while reaching the
    /// decode costs the standard evidence for the pair's shape — its relaxed
    /// ratio included, or a name the user half-accepts would still slip in.
    /// Case-only preferences never qualify: they carry no acoustic information.
    private func shouldBoostAtDecode(_ entry: DictionaryWord) -> Bool {
        guard shouldApply(entry) else { return false }
        guard entry.isAutoLearned else { return true }
        guard !Self.isCaseDowncaseEntry(entry) else { return false }
        return Self.meetsEvidence(
            entry,
            threshold: entry.spokenIsRealWord ? Self.tier2Threshold : Self.tier1Threshold,
            minimumRatio: Self.minimumCorrectionRatio
        )
    }

    /// Cached proper-noun classification of a written form (fast-path eligibility).
    private static func isProperNounWritten(_ written: String) -> Bool {
        let trimmed = written.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if let cached = properNounCache[trimmed] { return cached }
        let result = CorrectionDiffEngine.isProperNoun(spoken: "", written: trimmed)
        properNounCache[trimmed] = result
        return result
    }

    // MARK: - Auto-learn

    /// Records an auto-learned correction from user editing behavior.
    private static let autoLearnTrimSet: CharacterSet = .whitespacesAndNewlines.union(.punctuationCharacters)

    func recordAutoCorrection(
        spoken: String,
        written: String,
        spokenIsRealWord: Bool,
        writtenIsProperNoun: Bool = false
    ) {
        guard !isWorkspaceWriteSuspended else { return }
        let trimmedSpoken = spoken.trimmingCharacters(in: Self.autoLearnTrimSet)
        let trimmedWritten = written.trimmingCharacters(in: Self.autoLearnTrimSet)
        guard !trimmedSpoken.isEmpty, !trimmedWritten.isEmpty else { return }
        guard trimmedSpoken != trimmedWritten else { return }

        let key = trimmedSpoken.lowercased()
        let writtenKey = trimmedWritten.lowercased()

        // Seed the fast-path cache from the caller's classification so eligibility
        // matches the diff engine's decision even for edge-case spellchecker terms.
        if writtenIsProperNoun {
            Self.properNounCache[trimmedWritten] = true
        }

        // Check if this reverses an existing correction. If we have
        // "libary → library" stored under words["libary"], and the user changes
        // "library" back to "libary", we receive spoken="library" written="libary".
        // The existing entry lives under words["libary"] (the writtenKey side).
        // Case-only pairs share one key and are handled below instead — without
        // this guard, re-recording "iphone → iPhone" would suppress itself.
        if writtenKey != key,
           let reversed = words[writtenKey],
           reversed.isAutoLearned,
           reversed.written.lowercased() == key {
            reversed.isSuppressed = true
            markDirty(reversed)
            notifyWordSuppressed(reversed)
            log.info("Suppressed correction '\(reversed.spoken)' → '\(reversed.written)' (user reversed)")
            return
        }

        if let existing = words[key] {
            // Same correction direction — increment. Case-only pairs must match
            // exactly: for them, a case-insensitive match is the *opposite*
            // direction ("thijs → Thijs" stored, "Thijs → thijs" received).
            let sameDirection = writtenKey == key
                ? existing.written == trimmedWritten
                : existing.written.lowercased() == writtenKey
            if sameDirection {
                let wasEligible = shouldApply(existing)
                existing.correctedCount += 1
                existing.lastSeenAt = Date()
                markDirty(existing)
                log.debug("Auto-correction '\(trimmedSpoken)' → '\(trimmedWritten)' count=\(existing.correctedCount)")
                postAutoLearnedIfNewlyEligible(existing, wasEligible: wasEligible)
                return
            }

            // Case flip of the same word — the user reversed a stored case
            // preference; suppress rather than flip-flop.
            if writtenKey == key,
               existing.isAutoLearned,
               existing.written.lowercased() == writtenKey {
                existing.isSuppressed = true
                markDirty(existing)
                notifyWordSuppressed(existing)
                log.info("Suppressed case preference '\(existing.spoken)' → '\(existing.written)' (user reversed)")
                return
            }

            // Different target — update the replacement.
            existing.written = trimmedWritten
            existing.correctedCount = 1
            existing.seenUncorrectedCount = 0
            existing.isSuppressed = false
            existing.lastSeenAt = Date()
            markDirty(existing)
            invalidateCaches()
            postAutoLearnedIfNewlyEligible(existing, wasEligible: false)
            return
        }

        // New auto-learned entry
        let word = DictionaryWord(
            spoken: trimmedSpoken,
            written: trimmedWritten,
            correctedCount: 1,
            isAutoLearned: true,
            spokenIsRealWord: spokenIsRealWord,
            lastSeenAt: Date()
        )
        words[key] = word
        markDirty(word)
        invalidateCaches()
        log.info("Auto-learned correction '\(trimmedSpoken)' → '\(trimmedWritten)' realWord=\(spokenIsRealWord)")
        postAutoLearnedIfNewlyEligible(word, wasEligible: false)
    }

    /// Posts the auto-learned notification when an entry crosses its apply threshold
    /// on this call (was not eligible before, is now).
    private func postAutoLearnedIfNewlyEligible(_ entry: DictionaryWord, wasEligible: Bool) {
        guard !wasEligible, shouldApply(entry) else { return }
        NotificationCenter.default.post(
            name: Self.didAutoLearnWordNotification,
            object: nil,
            userInfo: ["spoken": entry.spoken, "written": entry.written]
        )
    }

    /// Increment the "seen but not corrected" counter for words the user left alone.
    /// Call `saveChanges()` separately after a batch of updates.
    func recordUncorrected(spoken: String) {
        guard !isWorkspaceWriteSuspended else { return }
        let trimmed = spoken.trimmingCharacters(in: Self.autoLearnTrimSet)
        let key = trimmed.lowercased()
        guard let existing = words[key], existing.isAutoLearned else { return }
        // Seeing the corrected form on screen means the entry did its job —
        // that is confirmation, not counter-evidence. Matters most for
        // case-only entries, whose key equals their own written form.
        guard trimmed != existing.written else { return }
        existing.seenUncorrectedCount += 1
        existing.lastSeenAt = Date()
        markDirty(existing)
    }

    // MARK: - Learn suggestions

    /// Whether any entry (learning, applied, or suppressed) exists for this
    /// spoken form. Used to avoid prompting about pairs already being tracked.
    func hasEntry(spoken: String) -> Bool {
        words[spoken.trimmingCharacters(in: Self.autoLearnTrimSet).lowercased()] != nil
    }

    /// The user declined a learn suggestion: record a suppressed auto-learned
    /// entry so the pair is neither applied nor offered again.
    func declineSuggestion(spoken: String, written: String) {
        guard !isWorkspaceWriteSuspended else { return }
        let trimmedSpoken = spoken.trimmingCharacters(in: Self.autoLearnTrimSet)
        let trimmedWritten = written.trimmingCharacters(in: Self.autoLearnTrimSet)
        guard !trimmedSpoken.isEmpty, !trimmedWritten.isEmpty else { return }

        let key = trimmedSpoken.lowercased()
        var invalidatedWrittenForm: String?
        if let existing = words[key] {
            guard existing.isAutoLearned else { return }
            invalidatedWrittenForm = existing.written
            existing.isSuppressed = true
            markDirty(existing)
        } else {
            let word = DictionaryWord(
                spoken: trimmedSpoken,
                written: trimmedWritten,
                isAutoLearned: true,
                isSuppressed: true,
                lastSeenAt: Date()
            )
            words[key] = word
            markDirty(word)
            invalidateCaches()
        }
        log.info("Declined learn suggestion '\(trimmedSpoken)' → '\(trimmedWritten)'")
        if let suppressed = words[key] {
            notifyWordSuppressed(suppressed)
        }
        schedulePersistence { store in await store.saveChanges() }
        if let invalidatedWrittenForm {
            invalidateBoostTermIfNeeded(
                writtenForm: invalidatedWrittenForm,
                reason: .dictionarySuppressed
            )
        }
    }

    /// Flush in-memory changes (e.g. after a batch of `recordUncorrected` calls).
    func saveChanges() async {
        guard !isWorkspaceWriteSuspended else { return }
        guard let dataStore, !dirtyWordIDs.isEmpty else { return }
        beginPersistence()
        defer { endPersistence() }

        let dirtyIDs = dirtyWordIDs
        let snapshots = words.values
            .filter { dirtyIDs.contains($0.id) }
            .map(WordSnapshot.init(word:))
        dirtyWordIDs.removeAll()
        guard !snapshots.isEmpty else { return }

        let saved = await dataStore.performBackgroundWrite { context in
            for snapshot in snapshots {
                let wordID = snapshot.id
                var descriptor = FetchDescriptor<DictionaryWord>(
                    predicate: #Predicate { $0.id == wordID }
                )
                descriptor.fetchLimit = 1
                if let word = try? context.fetch(descriptor).first {
                    word.spoken = snapshot.spoken
                    word.written = snapshot.written
                    word.createdAt = snapshot.createdAt
                    word.correctedCount = snapshot.correctedCount
                    word.seenUncorrectedCount = snapshot.seenUncorrectedCount
                    word.isAutoLearned = snapshot.isAutoLearned
                    word.isSuppressed = snapshot.isSuppressed
                    word.spokenIsRealWord = snapshot.spokenIsRealWord
                    word.lastSeenAt = snapshot.lastSeenAt
                } else {
                    context.insert(Self.makeWord(from: snapshot))
                }
            }
            return true
        } ?? false

        if !saved {
            dirtyWordIDs.formUnion(snapshots.map(\.id))
        } else {
            NotificationCenter.default.post(name: .workspaceRoamingSettingsChanged, object: nil)
        }
    }

    // MARK: - Manual Add / Remove

    func add(spoken: String, written: String) {
        guard !isWorkspaceWriteSuspended else { return }
        let trimmedSpoken = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedWritten = written.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSpoken.isEmpty, !trimmedWritten.isEmpty else { return }
        guard trimmedSpoken != trimmedWritten else { return }

        let key = trimmedSpoken.lowercased()
        var invalidatedWrittenForm: String?
        if let existing = words[key] {
            invalidatedWrittenForm = existing.written
            existing.spoken = trimmedSpoken
            existing.written = trimmedWritten
            existing.isAutoLearned = false
            existing.isSuppressed = false
            markDirty(existing)
            invalidateCaches()
        } else {
            let word = DictionaryWord(spoken: trimmedSpoken, written: trimmedWritten)
            words[key] = word
            markDirty(word)
            invalidateCaches()
        }
        schedulePersistence { store in await store.saveChanges() }
        if let invalidatedWrittenForm,
           VocabularyBoostAuditSummary.normalizedTermKey(invalidatedWrittenForm)
            != VocabularyBoostAuditSummary.normalizedTermKey(trimmedWritten) {
            invalidateBoostTermIfNeeded(
                writtenForm: invalidatedWrittenForm,
                reason: .dictionaryReplaced
            )
        }
        NotificationCenter.default.post(name: .workspaceRoamingSettingsChanged, object: nil)
    }

    /// Atomically edits a Settings pair in memory so a spoken-key rename is
    /// not misread as deletion before the replacement is visible. Changing the
    /// written form is genuine counter-evidence for the old boost term.
    func update(oldSpoken: String, spoken: String, written: String) {
        guard !isWorkspaceWriteSuspended else { return }
        let oldKey = oldSpoken.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let trimmedSpoken = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedWritten = written.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oldKey.isEmpty,
              !trimmedSpoken.isEmpty,
              !trimmedWritten.isEmpty,
              trimmedSpoken != trimmedWritten
        else { return }
        guard let existing = words[oldKey] else {
            add(spoken: trimmedSpoken, written: trimmedWritten)
            return
        }

        var invalidatedCandidates = [existing.written]
        let newKey = trimmedSpoken.lowercased()
        var removedWordID: UUID?

        if newKey != oldKey,
           let collision = words[newKey],
           collision.id != existing.id {
            invalidatedCandidates.append(collision.written)
            words.removeValue(forKey: oldKey)
            dirtyWordIDs.remove(existing.id)
            removedWordID = existing.id
            collision.spoken = trimmedSpoken
            collision.written = trimmedWritten
            collision.isAutoLearned = false
            collision.isSuppressed = false
            markDirty(collision)
        } else {
            if newKey != oldKey {
                words.removeValue(forKey: oldKey)
                words[newKey] = existing
            }
            existing.spoken = trimmedSpoken
            existing.written = trimmedWritten
            existing.isAutoLearned = false
            existing.isSuppressed = false
            markDirty(existing)
        }

        invalidateCaches()
        schedulePersistence { store in
            await store.saveChanges()
            if let removedWordID, let dataStore = store.dataStore {
                _ = await dataStore.performBackgroundWrite { context in
                    var descriptor = FetchDescriptor<DictionaryWord>(
                        predicate: #Predicate { $0.id == removedWordID }
                    )
                    descriptor.fetchLimit = 1
                    guard let persisted = try? context.fetch(descriptor).first else { return }
                    context.delete(persisted)
                }
            }
        }

        let replacementKey = VocabularyBoostAuditSummary.normalizedTermKey(trimmedWritten)
        let invalidatedByKey = invalidatedCandidates.reduce(
            into: [String: String]()
        ) { result, writtenForm in
            let key = VocabularyBoostAuditSummary.normalizedTermKey(writtenForm)
            guard !key.isEmpty, key != replacementKey else { return }
            result[key] = result[key] ?? writtenForm
        }
        for invalidatedWrittenForm in invalidatedByKey.values {
            invalidateBoostTermIfNeeded(
                writtenForm: invalidatedWrittenForm,
                reason: .dictionaryReplaced
            )
        }
        NotificationCenter.default.post(name: .workspaceRoamingSettingsChanged, object: nil)
    }

    func remove(spoken: String) {
        guard !isWorkspaceWriteSuspended else { return }
        let key = spoken.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let word = words.removeValue(forKey: key) {
            let invalidatedWrittenForm = word.written
            invalidateCaches()
            dirtyWordIDs.remove(word.id)
            if let dataStore {
                let wordID = word.id
                schedulePersistence { _ in
                    _ = await dataStore.performBackgroundWrite { context in
                        var descriptor = FetchDescriptor<DictionaryWord>(
                            predicate: #Predicate { $0.id == wordID }
                        )
                        descriptor.fetchLimit = 1
                        guard let persisted = try? context.fetch(descriptor).first else { return }
                        context.delete(persisted)
                    }
                }
            }
            invalidateBoostTermIfNeeded(
                writtenForm: invalidatedWrittenForm,
                reason: .dictionaryRemoved
            )
        }
        NotificationCenter.default.post(name: .workspaceRoamingSettingsChanged, object: nil)
    }

    /// Suppress an auto-learned entry so it stops being applied.
    func suppress(spoken: String) {
        guard !isWorkspaceWriteSuspended else { return }
        let key = spoken.lowercased()
        guard let entry = words[key] else { return }
        let invalidatedWrittenForm = entry.written
        entry.isSuppressed = true
        markDirty(entry)
        notifyWordSuppressed(entry)
        schedulePersistence { store in await store.saveChanges() }
        invalidateBoostTermIfNeeded(
            writtenForm: invalidatedWrittenForm,
            reason: .dictionarySuppressed
        )
        NotificationCenter.default.post(name: .workspaceRoamingSettingsChanged, object: nil)
    }

    var allWords: [DictionaryWord] {
        Array(words.values).sorted { $0.spoken.localizedCaseInsensitiveCompare($1.spoken) == .orderedAscending }
    }

    /// Whether the dictionary currently vetoes this exact case-only written
    /// form. Personalization consults this when creating a new word-casing
    /// preference, covering the suppress-first / learn-later ordering.
    func hasSuppressedCasingMapping(preferredValue: String) -> Bool {
        let preferred = preferredValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !preferred.isEmpty else { return false }
        let normalized = preferred.lowercased()
        return words.values.contains { word in
            let spoken = word.spoken.trimmingCharacters(in: .whitespacesAndNewlines)
            let written = word.written.trimmingCharacters(in: .whitespacesAndNewlines)
            return word.isSuppressed
                && spoken != written
                && spoken.lowercased() == normalized
                && written == preferred
                && written.lowercased() == normalized
        }
    }

    /// Prompt-level bias for the cloud cleanup pass. A term here only nudges a
    /// model that can already see the whole transcript, so it keeps the same
    /// bar as post-processing replacement.
    func cloudDictionaryTerms(limit: Int = 50) -> [String] {
        dictionaryTerms(limit: limit, admits: shouldApply).map(\.text)
    }

    /// Active recognition-bias terms with enough provenance for the decode
    /// guard to distinguish user-curated entries from learned ones. The scan
    /// continues after `limit` so a later manual duplicate can upgrade an
    /// already-admitted auto-learned written form.
    func vocabularyBoostTerms(limit: Int = 50) -> [VocabularyBoostTerm] {
        dictionaryTerms(limit: limit, admits: shouldBoostAtDecode)
    }

    private func dictionaryTerms(
        limit: Int,
        admits: (DictionaryWord) -> Bool
    ) -> [VocabularyBoostTerm] {
        var indexByKey: [String: Int] = [:]
        var terms: [VocabularyBoostTerm] = []

        for entry in allWords {
            guard admits(entry) else { continue }
            let trimmed = entry.written.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard !trimmed.allSatisfy({ $0.isNumber || $0 == "." || $0 == "," }) else { continue }

            let key = trimmed.lowercased()
            let source: VocabularyBoostTermSource = entry.isAutoLearned ? .autoLearned : .manual
            if let index = indexByKey[key] {
                if source.privilegeRank > terms[index].source.privilegeRank {
                    terms[index] = VocabularyBoostTerm(text: terms[index].text, source: source)
                }
                continue
            }
            guard terms.count < limit else { continue }
            indexByKey[key] = terms.count
            terms.append(VocabularyBoostTerm(text: trimmed, source: source))
        }

        return terms
    }

    func workspaceSnapshot() -> [WorkspaceWord] {
        allWords.map(WorkspaceWord.init(word:))
    }

    func mergeWorkspaceWords(_ workspaceWords: [WorkspaceWord]) {
        guard !isWorkspaceWriteSuspended else { return }
        let remoteWords = workspaceWords.reduce(into: [String: WorkspaceWord]()) { result, word in
            result[word.spoken.lowercased()] = word
        }
        let localWords = allWords.reduce(into: [String: WorkspaceWord]()) { result, word in
            result[word.spoken.lowercased()] = WorkspaceWord(word: word)
        }
        guard remoteWords.count != localWords.count || remoteWords.contains(where: { localWords[$0.key] != $0.value }) else {
            return
        }

        let newlySuppressed = remoteWords.compactMap { key, remote -> WorkspaceWord? in
            guard remote.isSuppressed else { return nil }
            if let local = localWords[key],
               local.isSuppressed,
               local.spoken == remote.spoken,
               local.written == remote.written {
                return nil
            }
            return remote
        }

        words = remoteWords.mapValues(Self.makeWord(from:))
        dirtyWordIDs.removeAll()
        invalidateCaches()
        for word in newlySuppressed {
            onWordSuppressed?(word.spoken, word.written)
        }

        guard let dataStore else { return }
        let snapshots = Array(remoteWords.values)
        schedulePersistence { _ in
            _ = await dataStore.performBackgroundWrite { context in
                let remoteIDs = Set(snapshots.map(\.id))
                let existingWords = (try? context.fetch(FetchDescriptor<DictionaryWord>())) ?? []
                for existing in existingWords where !remoteIDs.contains(existing.id) {
                    context.delete(existing)
                }

                for snapshot in snapshots {
                    let wordID = snapshot.id
                    var descriptor = FetchDescriptor<DictionaryWord>(
                        predicate: #Predicate { $0.id == wordID }
                    )
                    descriptor.fetchLimit = 1
                    if let existing = try? context.fetch(descriptor).first {
                        Self.update(existing, from: snapshot)
                    } else {
                        context.insert(Self.makeWord(from: snapshot))
                    }
                }
            }
        }
    }

    /// Suspends new mutations and joins every persistence task already
    /// admitted. This prevents an old correction from repopulating SwiftData
    /// after a workspace clear commits.
    func quiesceForWorkspaceClear() async {
        isWorkspaceWriteSuspended = true
        let tasks = Array(persistenceTasks.values)
        persistenceTasks.removeAll()
        tasks.forEach { $0.cancel() }
        for task in tasks {
            await task.value
        }
        boostFeedbackTail = nil
        if activePersistenceCount > 0 {
            await withCheckedContinuation { continuation in
                persistenceDrainWaiters.append(continuation)
            }
        }
    }

    func clearWorkspaceData() {
        words.removeAll()
        dirtyWordIDs.removeAll()
        boostFeedbackTail = nil
        invalidateCaches()
    }

    func resumeAfterWorkspaceClear() {
        isWorkspaceWriteSuspended = false
        if !dirtyWordIDs.isEmpty {
            schedulePersistence { store in await store.saveChanges() }
        }
    }

    private func schedulePersistence(
        _ operation: @escaping @MainActor (DictionaryStore) async -> Void
    ) {
        guard !isWorkspaceWriteSuspended else { return }
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.persistenceTasks.removeValue(forKey: id) }
            guard !Task.isCancelled, !self.isWorkspaceWriteSuspended else { return }
            await operation(self)
        }
        persistenceTasks[id] = task
    }

    /// Explicit dictionary removal/suppression is counter-evidence for recent
    /// matching applies even if the pair has since fallen below eligibility.
    /// Another active alias still supplying the written form prevents decay.
    private func invalidateBoostTermIfNeeded(
        writtenForm: String,
        reason: VocabularyBoostAuditSummary.FalseApplyReason
    ) {
        guard !hasActiveWrittenForm(writtenForm) else { return }
        scheduleBoostFeedback(writtenForm: writtenForm, reason: reason)
    }

    private func hasActiveWrittenForm(_ writtenForm: String) -> Bool {
        let key = VocabularyBoostAuditSummary.normalizedTermKey(writtenForm)
        guard !key.isEmpty else { return false }
        return words.values.contains { entry in
            shouldApply(entry)
                && VocabularyBoostAuditSummary.normalizedTermKey(entry.written) == key
        }
    }

    private func notifyWordSuppressed(_ word: DictionaryWord) {
        onWordSuppressed?(word.spoken, word.written)
    }

    private func scheduleBoostFeedback(
        writtenForm: String,
        reason: VocabularyBoostAuditSummary.FalseApplyReason
    ) {
        guard !isWorkspaceWriteSuspended else { return }
        let predecessor = boostFeedbackTail
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            await predecessor?.value
            guard let self else { return }
            defer { self.persistenceTasks.removeValue(forKey: id) }
            guard !Task.isCancelled, !self.isWorkspaceWriteSuspended else { return }

            let count: Int
            if let boostDecisionDecayer = self.boostDecisionDecayer {
                count = await boostDecisionDecayer(writtenForm, reason)
            } else if let dataStore = self.dataStore {
                count = await dataStore.flagRecentVocabularyBoostFalseApplies(
                    writtenForm: writtenForm,
                    reason: reason
                )
            } else {
                return
            }

            guard !Task.isCancelled, count > 0 else { return }
            self.boostCorrelationRecorder(VocabularyBoostAudit.CorrectionSignals(
                removedAppliedTermCount: count,
                insertedVetoedTermCount: 0
            ))
        }
        boostFeedbackTail = task
        persistenceTasks[id] = task
    }

    private func beginPersistence() {
        activePersistenceCount += 1
    }

    private func endPersistence() {
        activePersistenceCount = max(0, activePersistenceCount - 1)
        guard activePersistenceCount == 0 else { return }
        let waiters = persistenceDrainWaiters
        persistenceDrainWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    // MARK: - Cache

    private func invalidateCaches() {
        regexCache.removeAll()
        sortedKeysCache = nil
        onVocabularyTermsChanged?()
    }

    private func sortedKeys() -> [String] {
        if let cached = sortedKeysCache { return cached }
        let sorted = words.keys.sorted { $0.count > $1.count }
        sortedKeysCache = sorted
        return sorted
    }

    private func regex(for spoken: String) -> NSRegularExpression? {
        if let cached = regexCache[spoken] { return cached }
        let pattern = #"(?i)\b"# + NSRegularExpression.escapedPattern(for: spoken) + #"\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        regexCache[spoken] = regex
        return regex
    }

    private func markDirty(_ word: DictionaryWord) {
        dirtyWordIDs.insert(word.id)
        // `DictionaryWord` is a reference type, so eligibility-changing field
        // mutations do not trigger the dictionary's own Observation registrar.
        // Notify the one AppState resolver after every accepted mutation; its
        // controller remains single-flight and cheap when eligibility is stable.
        onVocabularyTermsChanged?()
    }

    private nonisolated static func cloneWord(_ word: DictionaryWord) -> DictionaryWord {
        DictionaryWord(
            id: word.id,
            spoken: word.spoken,
            written: word.written,
            createdAt: word.createdAt,
            correctedCount: word.correctedCount,
            seenUncorrectedCount: word.seenUncorrectedCount,
            isAutoLearned: word.isAutoLearned,
            isSuppressed: word.isSuppressed,
            spokenIsRealWord: word.spokenIsRealWord,
            lastSeenAt: word.lastSeenAt
        )
    }

    private nonisolated static func makeWord(from snapshot: WordSnapshot) -> DictionaryWord {
        DictionaryWord(
            id: snapshot.id,
            spoken: snapshot.spoken,
            written: snapshot.written,
            createdAt: snapshot.createdAt,
            correctedCount: snapshot.correctedCount,
            seenUncorrectedCount: snapshot.seenUncorrectedCount,
            isAutoLearned: snapshot.isAutoLearned,
            isSuppressed: snapshot.isSuppressed,
            spokenIsRealWord: snapshot.spokenIsRealWord,
            lastSeenAt: snapshot.lastSeenAt
        )
    }

    private nonisolated static func makeWord(from snapshot: WorkspaceWord) -> DictionaryWord {
        DictionaryWord(
            id: snapshot.id,
            spoken: snapshot.spoken,
            written: snapshot.written,
            createdAt: snapshot.createdAt,
            correctedCount: snapshot.correctedCount,
            seenUncorrectedCount: snapshot.seenUncorrectedCount,
            isAutoLearned: snapshot.isAutoLearned,
            isSuppressed: snapshot.isSuppressed,
            spokenIsRealWord: snapshot.spokenIsRealWord,
            lastSeenAt: snapshot.lastSeenAt
        )
    }

    private nonisolated static func update(_ word: DictionaryWord, from snapshot: WorkspaceWord) {
        word.spoken = snapshot.spoken
        word.written = snapshot.written
        word.createdAt = snapshot.createdAt
        word.correctedCount = snapshot.correctedCount
        word.seenUncorrectedCount = snapshot.seenUncorrectedCount
        word.isAutoLearned = snapshot.isAutoLearned
        word.isSuppressed = snapshot.isSuppressed
        word.spokenIsRealWord = snapshot.spokenIsRealWord
        word.lastSeenAt = snapshot.lastSeenAt
    }
}
