import FluidAudio
import Foundation

/// Holds at most one loaded copy of each multi-channel-shareable ASR model.
/// Mic + system meeting channels acquire from the same store so the ANE
/// doesn't end up with two copies of the 1.7–2 GB weights resident.
///
/// Both wrapped types (`Qwen3AsrManager`, `CoherePipeline`) are themselves
/// actors, so concurrent `transcribe(...)` calls from the two channels
/// serialize automatically. This store only manages lifecycle.
@available(macOS 15, *)
actor MeetingSharedModelStore {

    static let shared = MeetingSharedModelStore()

    private struct CohereHandle: Sendable {
        let pipeline: CoherePipeline
        let models: CoherePipeline.LoadedModels
    }

    private var qwen3: Qwen3AsrManager?
    private var qwen3Refs = 0
    private var qwen3LoadTask: Task<Qwen3AsrManager, Error>?

    private var cohere: CohereHandle?
    private var cohereRefs = 0
    private var cohereLoadTask: Task<CohereHandle, Error>?

    private init() {}

    // MARK: Qwen3

    func acquireQwen3() async throws -> Qwen3AsrManager {
        if let qwen3 {
            qwen3Refs += 1
            return qwen3
        }
        if let inflight = qwen3LoadTask {
            let manager = try await inflight.value
            qwen3Refs += 1
            return manager
        }
        let task = Task<Qwen3AsrManager, Error> {
            let manager = Qwen3AsrManager()
            try await manager.loadModels(from: Qwen3AsrModels.defaultCacheDirectory())
            return manager
        }
        qwen3LoadTask = task
        do {
            let manager = try await task.value
            qwen3 = manager
            qwen3Refs += 1
            qwen3LoadTask = nil
            return manager
        } catch {
            qwen3LoadTask = nil
            throw error
        }
    }

    func releaseQwen3() {
        qwen3Refs = max(0, qwen3Refs - 1)
        if qwen3Refs == 0 {
            qwen3 = nil
        }
    }

    // MARK: Cohere

    func acquireCohere() async throws -> (CoherePipeline, CoherePipeline.LoadedModels) {
        if let cohere {
            cohereRefs += 1
            return (cohere.pipeline, cohere.models)
        }
        if let inflight = cohereLoadTask {
            let handle = try await inflight.value
            cohereRefs += 1
            return (handle.pipeline, handle.models)
        }
        let task = Task<CohereHandle, Error> {
            let dir = MLModelConfigurationUtils.defaultModelsDirectory(for: .cohereTranscribeCoreml)
            let models = try await CoherePipeline.loadModels(
                encoderDir: dir, decoderDir: dir, vocabDir: dir
            )
            return CohereHandle(pipeline: CoherePipeline(), models: models)
        }
        cohereLoadTask = task
        do {
            let handle = try await task.value
            cohere = handle
            cohereRefs += 1
            cohereLoadTask = nil
            return (handle.pipeline, handle.models)
        } catch {
            cohereLoadTask = nil
            throw error
        }
    }

    func releaseCohere() {
        cohereRefs = max(0, cohereRefs - 1)
        if cohereRefs == 0 {
            cohere = nil
        }
    }
}
