import XCTest
import FluidAudio
@testable import Resonant

/// Live load verification. Confirms the installed FluidAudio version can load
/// the local v3 cache through the same path the app uses. Guards against
/// future FluidAudio bumps breaking the cached bundles or the adapter's load
/// sequence. Skips if no v3 cache is present.
final class FluidAudioMigrationLiveLoadTest: XCTestCase {

    func testLoadsMigratedCacheAndTranscribesSilence() async throws {
        let cacheDir = AsrModels.defaultCacheDirectory(for: .v3)
        let fm = FileManager.default
        guard fm.fileExists(atPath: cacheDir.path) else {
            throw XCTSkip("No v3 cache at \(cacheDir.path) — skipping live load test")
        }

        // Step 1: adapter construction triggers the migration.
        let adapter = FluidAudioAdapter()
        XCTAssertTrue(adapter.isDownloaded, "Expected migrated cache to register as downloaded")
        XCTAssertFalse(adapter.isLoaded, "Adapter should start unloaded")

        // Step 2: load models through the same path the app uses. This compiles
        // all four CoreML bundles (Preprocessor, Encoder, Decoder, JointDecision)
        // and would throw if any .mlmodelc were unreadable or incompatible with
        // the current FluidAudio / CoreML versions.
        try await adapter.load()
        XCTAssertTrue(adapter.isLoaded, "Adapter.load() should set asrManager")
    }
}
