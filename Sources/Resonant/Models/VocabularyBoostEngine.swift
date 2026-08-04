import Foundation
import FluidAudio
import os

struct VocabularyBoostTerm: Sendable, Equatable {
    let text: String
    let source: VocabularyBoostTermSource
}

/// Biases Parakeet recognition toward the user's own vocabulary (custom
/// dictionary + auto-learned words) using FluidAudio's CTC keyword spotting +
/// rescoring. This is the seam that lets learned words influence the *decode*
/// instead of only post-hoc text repair: a separate ~98 MB CTC encoder scores
/// the audio against the vocabulary, and `VocabularyRescorer` swaps in a term
/// only when the acoustic evidence clears its similarity/confidence gates.
///
/// Fail-open by design: any unavailability (model not downloaded, no terms,
/// Auto language not confidently identified as English, load failure) returns
/// the original result untouched and must never break a dictation.
actor ParakeetVocabularyBoostEngine {

    /// Supplies the current boost terms and their provenance. Runs on the main
    /// actor so it can read DictionaryStore and the personalization sources.
    /// Feature/latency gating is kept separate so every skip remains typed.
    typealias TermsProvider = @MainActor @Sendable () -> [VocabularyBoostTerm]
    typealias RuntimeConfigurationProvider = @MainActor @Sendable () -> VocabularyBoostEngineRuntimeConfiguration
    typealias ModelDownloadedProvider = @Sendable () -> Bool
    typealias AssetPreparation = @Sendable ([String]) async -> Bool

    private static let log = Logger.resonant("VocabularyBoost")

    /// Vocabulary sizes beyond this are truncated: rescoring quality drops and
    /// similarity thresholds tighten as vocab grows (FluidAudio guidance tops
    /// out around ~100–230 terms).
    static let maximumTermCount = 100

    /// Terms shorter than this are skipped — very short words produce spurious
    /// CTC matches (also the FluidAudio-documented recommendation).
    static let minimumTermLength = 4

    private let termsProvider: TermsProvider
    private let runtimeConfigurationProvider: RuntimeConfigurationProvider
    private let modelDownloadedProvider: ModelDownloadedProvider
    private let languageDetector: VocabularyBoostLanguageDetector
    /// Injectable preparation boundary used by deterministic tests. Production
    /// leaves this nil and uses the real FluidAudio CTC assets below.
    private let assetPreparationOverride: AssetPreparation?
    private let attemptRecorder: VocabularyBoostAttemptRecorder?

    private var ctcModels: CtcModels?
    private var tokenizer: CtcTokenizer?
    private var spotter: CtcKeywordSpotter?
    private var rescorer: VocabularyRescorer?
    private var vocabulary: CustomVocabularyContext?
    private var vocabularyFingerprint: [String] = []
    /// After a hard asset failure, stay disabled for the rest of the process
    /// instead of re-attempting a broken load on every dictation.
    private var assetLoadFailedPermanently = false
    /// Serializes asset builds across actor-reentrancy suspension points —
    /// see `prepareAssets(for:)`.
    private var prepareChain: Task<Bool, Never>?

    init(
        termsProvider: @escaping TermsProvider,
        runtimeConfigurationProvider: @escaping RuntimeConfigurationProvider = {
            VocabularyBoostEngineRuntimeConfiguration(enabled: true, lowLatencyMode: false)
        },
        modelDownloadedProvider: @escaping ModelDownloadedProvider = {
            ParakeetVocabularyBoostEngine.isModelDownloaded
        },
        languageDetector: VocabularyBoostLanguageDetector = .localNaturalLanguage,
        assetPreparationOverride: AssetPreparation? = nil,
        attemptRecorder: VocabularyBoostAttemptRecorder? = nil
    ) {
        self.termsProvider = termsProvider
        self.runtimeConfigurationProvider = runtimeConfigurationProvider
        self.modelDownloadedProvider = modelDownloadedProvider
        self.languageDetector = languageDetector
        self.assetPreparationOverride = assetPreparationOverride
        self.attemptRecorder = attemptRecorder
    }

    // MARK: - Model availability

    static var isModelDownloaded: Bool {
        CtcModels.modelsExist(at: CtcModels.defaultCacheDirectory(for: .ctc110m))
    }

    /// Downloads the CTC helper model when missing. Safe to call repeatedly.
    /// Takes the shared cache lock: the helper lives in the same
    /// `FluidAudio/Models` tree as the speech models, and a concurrent dev/prod
    /// or speech-model download interleaving with it can corrupt either cache.
    static func downloadModelIfNeeded() async throws {
        guard !isModelDownloaded else { return }
        log.info("Downloading CTC vocabulary model (~98 MB)")
        try await ModelDownloadLock.withLock(reportingWaitTo: { _ in }) {
            guard !isModelDownloaded else { return }
            _ = try await CtcModels.download(variant: .ctc110m)
        }
        log.info("CTC vocabulary model download complete")
    }

    // MARK: - Rescoring

    /// Returns `result` with vocabulary-rescored text when the acoustic
    /// evidence supports a replacement, or the original result untouched —
    /// plus an audit of every replacement decision (nil when the rescore
    /// never reached the decision stage).
    /// `audioSamples` must be the same 16 kHz mono array the TDT decode saw so
    /// CTC frames align with `result.tokenTimings` in absolute seconds.
    func rescoredResult(
        _ result: ASRResult,
        audioSamples: [Float],
        language: Language?
    ) async -> (result: ASRResult, audit: VocabularyBoostAudit?) {
        await rescoredResult(
            result,
            audioSamples: audioSamples,
            languageHint: language,
            selectedLanguage: language?.rawValue ?? "auto"
        )
    }

    func rescoredResult(
        _ result: ASRResult,
        audioSamples: [Float],
        languageHint: Language?,
        selectedLanguage: String?
    ) async -> (result: ASRResult, audit: VocabularyBoostAudit?) {
        let configuration = await runtimeConfigurationProvider()
        let tokenTimings = result.tokenTimings
        let transcriptIsEmpty = result.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty

        let terms = Self.normalizedTerms(await termsProvider())
        let preflight = VocabularyBoostAttemptRouter.enginePreflight(
            configuration: configuration,
            selectedLanguage: selectedLanguage,
            hasTokenTimings: tokenTimings?.isEmpty == false,
            transcriptIsEmpty: transcriptIsEmpty,
            eligibleTermCount: terms.count,
            automaticLanguageDetection: {
                languageDetector.detect(result.text)
            },
            helperModelDownloaded: modelDownloadedProvider
        )
        let attemptLanguage: VocabularyBoostAttemptLanguageMode
        switch preflight {
        case .skip(let reason):
            await record(.skipped(reason))
            return (result, nil)
        case .proceed(let language):
            attemptLanguage = language
        }
        guard let tokenTimings else {
            // The pure preflight above makes this unreachable; retain the
            // fail-open guard at the FluidAudio boundary.
            await record(.skipped(.missingTokenTimings))
            return (result, nil)
        }

        guard await prepareAssetsForAttempt(terms.map(\.text)),
              let spotter, let rescorer, let vocabulary else {
            await record(.attempted(result: .processingFailure, language: attemptLanguage))
            return (result, nil)
        }

        do {
            let spot = try await spotter.spotKeywordsWithLogProbs(
                audioSamples: audioSamples,
                customVocabulary: vocabulary
            )
            guard !spot.logProbs.isEmpty else {
                await record(.attempted(result: .noChange, language: attemptLanguage))
                return (result, nil)
            }

            let sizeConfig = ContextBiasingConstants.rescorerConfig(
                forVocabSize: vocabulary.terms.count
            )
            let output = rescorer.ctcTokenRescore(
                transcript: result.text,
                tokenTimings: tokenTimings,
                logProbs: spot.logProbs,
                frameDuration: spot.frameDuration,
                cbw: sizeConfig.cbw,
                marginSeconds: ContextBiasingConstants.defaultMarginSeconds,
                minSimilarity: sizeConfig.minSimilarity
            )
            guard output.wasModified else {
                await record(.attempted(result: .noChange, language: attemptLanguage))
                return (result, nil)
            }

            // Keep the original language hint for the independent spell-check
            // veto. Under Auto, nil lets that local check infer a locale; the
            // separate confidence-bearing language gate above has already
            // decided whether the English-only CTC path may run.
            let isRealWord: (String) -> Bool = {
                FragmentedWordRepair.isRealWord($0, language: languageHint?.rawValue)
            }
            var decisions: [VocabularyBoostAudit.Decision] = []
            var vetoCount = 0
            let sourceByTerm = Dictionary(
                uniqueKeysWithValues: terms.map {
                    (Self.normalizedTermKey($0.text), $0.source)
                }
            )
            for replacement in output.replacements where replacement.shouldReplace {
                guard let term = replacement.replacementWord else { continue }
                // FluidAudio returns one of the supplied vocabulary terms. A
                // defensive manual default keeps an unexpected spelling from
                // acquiring inferred-source restrictions.
                let source = sourceByTerm[Self.normalizedTermKey(term)] ?? .manual
                let originalWasRealWord = Self.spanIsRealWords(
                    replacement.originalWord, isRealWord: isRealWord
                )
                let similarity = Self.orthographicSimilarity(
                    replacement.originalWord, term
                )
                let vetoed = Self.replacementVetoed(
                    original: replacement.originalWord,
                    replacement: term,
                    isRealWord: isRealWord
                )
                if vetoed { vetoCount += 1 }
                decisions.append(VocabularyBoostAudit.Decision(
                    outcome: vetoed ? .vetoed : .applied,
                    term: term,
                    originalText: replacement.originalWord,
                    guarded: source.isGuarded,
                    source: source,
                    originalWasRealWord: originalWasRealWord,
                    originalScore: replacement.originalScore,
                    replacementScore: replacement.replacementScore,
                    similarity: Float(similarity)
                ))
            }

            if vetoCount > 0 {
                // The rescorer hands back fully rebuilt text without span
                // positions, so the surviving replacements can't be
                // re-applied selectively. Fail open to the raw decode: a
                // veto means the rescore overwrote real speech. Survivors
                // are audited as dropped-with-veto, not applied.
                Self.log.info(
                    "Vocabulary boost vetoed realWordReplacements=\(vetoCount, privacy: .public); keeping original decode"
                )
                let audit = VocabularyBoostAudit(decisions: decisions.map { decision in
                    guard decision.outcome == .applied else { return decision }
                    return VocabularyBoostAudit.Decision(
                        outcome: .droppedWithVeto,
                        term: decision.term,
                        originalText: decision.originalText,
                        guarded: decision.guarded,
                        source: decision.source,
                        originalWasRealWord: decision.originalWasRealWord,
                        originalScore: decision.originalScore,
                        replacementScore: decision.replacementScore,
                        similarity: decision.similarity
                    )
                })
                await record(.attempted(result: .vetoed, language: attemptLanguage))
                return (result, audit)
            }

            let detected = output.replacements.compactMap(\.replacementWord)
            let applied = output.replacements
                .filter(\.shouldReplace)
                .compactMap(\.replacementWord)
            Self.log.info(
                "Vocabulary boost applied terms=\(applied.count, privacy: .public) detected=\(detected.count, privacy: .public)"
            )
            await record(.attempted(
                result: applied.isEmpty ? .noChange : .applied,
                language: attemptLanguage
            ))
            return (
                result.withRescoring(
                    text: output.text,
                    detected: detected.isEmpty ? nil : detected,
                    applied: applied.isEmpty ? nil : applied
                ),
                decisions.isEmpty ? nil : VocabularyBoostAudit(decisions: decisions)
            )
        } catch is CancellationError {
            await record(.skipped(.cancelled))
            return (result, nil)
        } catch {
            Self.log.error("Vocabulary boost failed: \(error.localizedDescription, privacy: .public)")
            await record(.attempted(result: .processingFailure, language: attemptLanguage))
            return (result, nil)
        }
    }

    /// Records the long-form constant-memory bypass through the same preflight
    /// policy as in-memory attempts. It never loads the audio or retains text.
    func recordDiskBackedBypass(selectedLanguage: String?) async {
        let configuration = await runtimeConfigurationProvider()
        let terms = Self.normalizedTerms(await termsProvider())
        let outcome = VocabularyBoostAttemptRouter.diskBackedOutcome(
            configuration: configuration,
            selectedLanguage: selectedLanguage,
            eligibleTermCount: terms.count,
            helperModelDownloaded: modelDownloadedProvider()
        )
        await record(outcome)
    }

    private func record(_ outcome: VocabularyBoostAttemptOutcome) async {
        await attemptRecorder?.record(outcome)
    }

    /// Builds CTC assets ahead of a decode only when English is selected
    /// explicitly. Auto cannot prewarm: its required language decision does
    /// not exist until the first-pass transcript is available.
    func prewarm(selectedLanguage: String?) async {
        let configuration = await runtimeConfigurationProvider()
        guard configuration.enabled,
              !configuration.lowLatencyMode,
              VocabularyBoostAttemptRouter.languageMode(for: selectedLanguage)
                == .explicitEnglish,
              modelDownloadedProvider() else { return }
        let terms = Self.normalizedTerms(await termsProvider())
        guard !terms.isEmpty else { return }
        _ = await prepareAssetsForAttempt(terms.map(\.text))
    }

    // MARK: - Assets

    private func prepareAssetsForAttempt(_ terms: [String]) async -> Bool {
        if let assetPreparationOverride {
            return await assetPreparationOverride(terms)
        }
        return await prepareAssets(for: terms)
    }

    /// Loads CTC assets (once) and rebuilds the vocabulary context/rescorer
    /// when the term set changed. Returns false when boosting is unavailable.
    ///
    /// Serialized: the model/tokenizer loads suspend, and actor reentrancy at
    /// those awaits would let a prewarm racing a decode's rescore start a
    /// second concurrent ~98 MB model load. Later callers chain behind the
    /// in-flight build; the fingerprint check makes redundant follow-ups
    /// cheap.
    private func prepareAssets(for terms: [String]) async -> Bool {
        let previous = prepareChain
        let task = Task { () -> Bool in
            _ = await previous?.value
            return await self.buildAssets(for: terms)
        }
        prepareChain = task
        return await task.value
    }

    private func buildAssets(for terms: [String]) async -> Bool {
        guard !assetLoadFailedPermanently else { return false }

        if ctcModels == nil {
            // Never trigger a ~98 MB download from the dictation hot path; the
            // settings toggle / launch check own the download.
            guard Self.isModelDownloaded else { return false }
            do {
                let directory = CtcModels.defaultCacheDirectory(for: .ctc110m)
                ctcModels = try await CtcModels.load(from: directory, variant: .ctc110m)
                tokenizer = try await CtcTokenizer.load(from: directory)
            } catch {
                Self.log.error("CTC asset load failed: \(error.localizedDescription, privacy: .public)")
                assetLoadFailedPermanently = true
                ctcModels = nil
                tokenizer = nil
                return false
            }
        }
        guard let ctcModels, let tokenizer else { return false }

        if spotter == nil {
            spotter = CtcKeywordSpotter(
                models: ctcModels,
                blankId: ctcModels.vocabulary.count
            )
        }

        if rescorer == nil || vocabulary == nil || terms != vocabularyFingerprint {
            let vocabularyTerms = terms.compactMap { term -> CustomVocabularyTerm? in
                let ids = tokenizer.encode(term)
                guard !ids.isEmpty else { return nil }
                return CustomVocabularyTerm(text: term, ctcTokenIds: ids)
            }
            guard !vocabularyTerms.isEmpty, let spotter else { return false }
            let context = CustomVocabularyContext(terms: vocabularyTerms)
            do {
                rescorer = try await VocabularyRescorer.create(
                    spotter: spotter,
                    vocabulary: context,
                    config: .default,
                    ctcModelDirectory: CtcModels.defaultCacheDirectory(for: .ctc110m)
                )
                vocabulary = context
                vocabularyFingerprint = terms
            } catch {
                Self.log.error("Vocabulary rescorer build failed: \(error.localizedDescription, privacy: .public)")
                rescorer = nil
                vocabulary = nil
                vocabularyFingerprint = []
                return false
            }
        }

        return vocabulary != nil && rescorer != nil
    }

    /// Whether a rescorer replacement must be discarded because it would
    /// overwrite real speech. When the replaced span consists entirely of
    /// words that spell-check in the dictation locale, the decode heard actual
    /// words, so overwriting demands a much stronger prior than the rescorer's
    /// own acoustic gate ("model" cleared the 0.55 similarity gate against
    /// "Codex" and shipped in a real dictation).
    ///
    /// Provenance deliberately does not enter into it. Earlier revisions
    /// exempted whichever sources felt trustworthy — first every curated one,
    /// then manual single words, then contacts — and each exemption turned back
    /// into the same field failure, because trusting the *term* says nothing
    /// about whether this particular span was real speech. A term earns
    /// decode-level power over real words only by being an orthographic
    /// near-neighbor of what was actually heard; the exact spoken → written
    /// pairs a curated term is built from still rewrite text in the dictionary
    /// layer, which is where a distant replacement belongs.
    nonisolated static func replacementVetoed(
        original: String,
        replacement: String?,
        isRealWord: (String) -> Bool
    ) -> Bool {
        guard let replacement else { return false }
        guard spanIsRealWords(original, isRealWord: isRealWord) else { return false }
        return orthographicSimilarity(original, replacement) < realWordOverwriteMinSimilarity
    }

    /// Minimum letters-only Levenshtein similarity a curated term needs
    /// before it may overwrite a span of real words. Aligned with
    /// FluidAudio's own "protect real speech" tier (shortWordSimilarity
    /// 0.80 / stopwordSpanSimilarity 0.85) rather than its permissive
    /// 0.50–0.60 replacement gate, which lets pairs like "model"/"Codex"
    /// (similarity 0.60) through.
    nonisolated static let realWordOverwriteMinSimilarity = 0.8

    /// Levenshtein similarity over lowercased letters/digits only, so
    /// punctuation and casing differences ("design," vs "Devin",
    /// "e-mail" vs "email") don't distort the distance.
    nonisolated static func orthographicSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let normalize: (String) -> String = { value in
            String(value.lowercased().unicodeScalars.filter {
                CharacterSet.alphanumerics.contains($0)
            })
        }
        return 1 - PersonalizationEvaluationEngine.normalizedEditDistance(
            from: normalize(lhs), to: normalize(rhs)
        )
    }

    /// Whether every word of a replaced span spell-checks as a real word —
    /// the "this was real speech" half of the veto, also recorded per
    /// decision in the audit.
    nonisolated static func spanIsRealWords(
        _ span: String,
        isRealWord: (String) -> Bool
    ) -> Bool {
        let words = spanWords(span)
        guard !words.isEmpty else { return false }
        return words.allSatisfy(isRealWord)
    }

    nonisolated private static func spanWords(_ span: String) -> [String] {
        span
            .split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: CharacterSet.letters.inverted) }
            .filter { !$0.isEmpty }
    }

    /// Dedupes, drops too-short/numeric-only terms, and caps the vocabulary at
    /// the size where rescoring quality is still well characterized. Order is
    /// preserved so the provider controls priority under truncation. The full
    /// input is still scanned after the cap so a later manual/contact duplicate
    /// can upgrade the source privilege of an already-admitted term.
    nonisolated static func normalizedTerms(
        _ rawTerms: [VocabularyBoostTerm]
    ) -> [VocabularyBoostTerm] {
        var indexByKey: [String: Int] = [:]
        var terms: [VocabularyBoostTerm] = []
        for raw in rawTerms {
            let trimmed = raw.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= minimumTermLength else { continue }
            guard trimmed.contains(where: { $0.isLetter }) else { continue }
            let key = normalizedTermKey(trimmed)
            if let index = indexByKey[key] {
                if raw.source.privilegeRank > terms[index].source.privilegeRank {
                    terms[index] = VocabularyBoostTerm(text: terms[index].text, source: raw.source)
                }
                continue
            }
            guard terms.count < maximumTermCount else { continue }
            indexByKey[key] = terms.count
            terms.append(VocabularyBoostTerm(text: trimmed, source: raw.source))
        }
        return terms
    }

    nonisolated static func normalizedTerms(_ rawTerms: [String]) -> [String] {
        normalizedTerms(rawTerms.map { VocabularyBoostTerm(text: $0, source: .manual) })
            .map(\.text)
    }

    nonisolated private static func normalizedTermKey(_ term: String) -> String {
        term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
