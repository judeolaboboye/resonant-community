import Foundation

/// Decode-bias terms harvested from the dictation target's on-screen context.
///
/// The cloud cleanup prompt already receives screen-derived bias terms via the
/// context packet; this is the equivalent seam for the *decode*: names visible
/// on screen at dictation start feed the vocabulary boost engine, so an
/// on-screen spelling can win at recognition time even on dictations that
/// never reach the cloud pass (short, low-latency, or signed out).
enum ScreenContextBiasTerms {
    /// A wrong boost term rewrites the decode, so only the entity kinds the
    /// persistent recognition-bias path trusts qualify (see
    /// `PersonalizationMemoryStore.recognitionBiasTerms`).
    static let decodeBiasEntityTypes: Set<ContextEntityType> = [.personName, .customTerm]

    /// Small on purpose: a changed term list rebuilds the boost vocabulary
    /// (tokenizer reload + candidate index), and one screen rarely offers more
    /// than a handful of decode-worthy names.
    static let maximumTermCount = 12

    /// The single definition of a decode-safe entity value: the per-dictation
    /// term list and the store's sighting promotion both use it, so the
    /// decode never boosts a kind of term the store wouldn't learn and vice
    /// versa. Returns the trimmed value, or nil when the entity must not
    /// touch the decode.
    static func decodeSafeValue(_ entity: ContextEntity) -> String? {
        guard decodeBiasEntityTypes.contains(entity.type) else { return nil }
        guard !entity.isSensitive else { return nil }
        guard entity.trustTier == .biasTerm || entity.trustTier == .grounding else { return nil }
        let value = entity.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= ParakeetVocabularyBoostEngine.minimumTermLength,
              value.count <= 80 else { return nil }
        return value
    }

    /// Filters ranked context entities down to decode-safe boost terms.
    /// Deterministic (rankingScore, then value) so an unchanged screen yields
    /// an identical list and the engine's vocabulary fingerprint stays stable
    /// across consecutive dictations into the same target.
    static func decodeBiasTerms(from entities: [ContextEntity]) -> [String] {
        var seen = Set<String>()
        var terms: [String] = []
        let ranked = entities.sorted { lhs, rhs in
            if lhs.rankingScore == rhs.rankingScore {
                return lhs.value < rhs.value
            }
            return lhs.rankingScore > rhs.rankingScore
        }
        for entity in ranked {
            guard terms.count < maximumTermCount else { break }
            guard let value = decodeSafeValue(entity) else { continue }
            guard seen.insert(value.lowercased()).inserted else { continue }
            terms.append(value)
        }
        return terms
    }
}

/// Holds the screen-derived boost terms for the in-flight capture. Written
/// when the hot-context preload resolves (during speech), read by the
/// vocabulary boost terms provider at decode time, and cleared the moment the
/// capture's decode completes, fails, or is cancelled — plus at every capture
/// entry that must not inherit them (next dictation's retarget, command
/// mode) — so decodes that never captured a screen (retries, feed
/// re-transcription) run unbiased. Ephemeral by design — durable memory
/// happens in `PersonalizationMemoryStore.recordScreenEntityUsage` once a
/// term survives into delivered text.
@MainActor
final class ScreenContextBiasSession {
    var onTermsChanged: (@MainActor () -> Void)?
    private(set) var terms: [String] = [] {
        didSet {
            guard terms != oldValue else { return }
            onTermsChanged?()
        }
    }
    private(set) var activeRecipient: ActiveRecipientContext?
    private(set) var targetFingerprint: ContextTargetFingerprint?
    private var baseEntities: [ContextEntity] = []
    private var publicationIsOpen = false
    /// Bumped by `begin()`. A capture's stop path clears via
    /// `end(ifGeneration:)` with the value it started under, so it can never
    /// wipe the terms of a next capture that already re-began while the
    /// previous stop was still post-processing.
    private(set) var generation = 0

    /// Takes ownership for a new capture: clears the previous capture's
    /// terms. A decode that races the next update simply sees no screen
    /// terms.
    func begin() {
        generation += 1
        publicationIsOpen = true
        activeRecipient = nil
        targetFingerprint = nil
        baseEntities = []
        terms = []
    }

    /// Compatibility seam for existing direct tests/callers. Capture code uses
    /// the generation-scoped overload below.
    func update(entities: [ContextEntity]) {
        baseEntities = entities
        recomputeTerms()
    }

    @discardableResult
    func bindTarget(
        fingerprint: ContextTargetFingerprint?,
        ifGeneration expectedGeneration: Int
    ) -> Bool {
        guard generation == expectedGeneration, publicationIsOpen else { return false }
        targetFingerprint = fingerprint
        return true
    }

    @discardableResult
    func updateBase(
        entities: [ContextEntity],
        ifGeneration expectedGeneration: Int
    ) -> Bool {
        guard generation == expectedGeneration, publicationIsOpen else { return false }
        baseEntities = entities
        recomputeTerms()
        return true
    }

    /// Publishes opportunistic structured metadata only while this capture
    /// still owns an open epoch and the focused target is the one bound from
    /// hot context. Recipient names deliberately do not mutate decode terms:
    /// doing so could start a vocabulary rebuild immediately before key-up and
    /// add that remaining work to stop-to-paste latency. The recipient still
    /// enters the post-decode context packet and guarded greeting repair.
    @discardableResult
    func publishRecipient(
        _ recipient: ActiveRecipientContext,
        ifGeneration expectedGeneration: Int,
        targetFingerprint expectedTargetFingerprint: ContextTargetFingerprint
    ) -> Bool {
        guard generation == expectedGeneration,
              publicationIsOpen,
              targetFingerprint == expectedTargetFingerprint else {
            return false
        }
        activeRecipient = recipient
        return true
    }

    /// Key-up authority: capture whatever is already ready and permanently
    /// close publication for this generation. Task cancellation is cleanup,
    /// not the correctness mechanism.
    func snapshotAndSealRecipient(
        ifGeneration expectedGeneration: Int
    ) -> ActiveRecipientContext? {
        guard generation == expectedGeneration else { return nil }
        publicationIsOpen = false
        return activeRecipient
    }

    /// Post-decode teardown, scoped to the capture that observed
    /// `generation` at its start. Returns false (and leaves the terms alone)
    /// when a newer capture owns the session, so callers only re-prewarm the
    /// boost vocabulary when they actually changed the term set.
    @discardableResult
    func end(ifGeneration expected: Int) -> Bool {
        guard generation == expected else { return false }
        publicationIsOpen = false
        activeRecipient = nil
        targetFingerprint = nil
        baseEntities = []
        terms = []
        return true
    }

    private func recomputeTerms() {
        terms = ScreenContextBiasTerms.decodeBiasTerms(from: baseEntities)
    }
}
