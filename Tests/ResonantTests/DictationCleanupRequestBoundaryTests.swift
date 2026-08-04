import XCTest
@testable import Resonant

@MainActor
final class DictationCleanupRequestBoundaryTests: XCTestCase {
    private let transcript = "Please send the report tomorrow morning."
    private let rawExample = DictationEditExemplar(
        original: "Please email alice@example.com and send report ABCD123456789 tomorrow morning.",
        edited: "please email updated@example.org and send report ZXCV123456789 tomorrow morning"
    )

    func testRawExamplesAreAbsentByDefaultWhileStructuredStyleHintRemains() async {
        let settings = SettingsManager.shared
        let saved = savePrivacySettings(settings)
        defer { restorePrivacySettings(saved, to: settings) }
        settings.cloudProcessingEnabled = true
        settings.hipaaMode = false
        settings.cloudPersonalizationExamplesEnabled = false

        let client = makeClient()
        var capturedRequest: ConvexClient.DictationCleanupRequest?
        var capturedAttempt: CloudTextAttempt?

        _ = await client.processDictationCleanupDetailed(
            transcript: transcript,
            windowTitle: "General",
            appName: "Slack",
            bundleId: "com.tinyspeck.slackmacgap",
            browserURL: nil,
            dictionaryTerms: [],
            recentTexts: [],
            styleHint: "Prefer concise lowercase messages.",
            cleanupProfileOverride: .message,
            editExemplars: [rawExample],
            attemptRunner: { request, attempt in
                capturedRequest = request
                capturedAttempt = attempt
                return ConvexClient.CloudTextResponse(text: self.transcript, durationMs: 1)
            }
        )

        XCTAssertEqual(capturedRequest?.editExemplars, [rawExample])
        XCTAssertEqual(capturedAttempt?.args["styleHint"] as? String, "Prefer concise lowercase messages.")
        XCTAssertFalse(instruction(in: capturedAttempt).contains("Personal style examples"))
        XCTAssertFalse(instruction(in: capturedAttempt).contains("alice@example.com"))
    }

    func testOptInSendsOnlySanitizedExamples() async {
        let settings = SettingsManager.shared
        let saved = savePrivacySettings(settings)
        defer { restorePrivacySettings(saved, to: settings) }
        settings.cloudProcessingEnabled = true
        settings.hipaaMode = false
        settings.cloudPersonalizationExamplesEnabled = true

        let client = makeClient()
        var capturedAttempt: CloudTextAttempt?

        _ = await client.processDictationCleanupDetailed(
            transcript: transcript,
            windowTitle: "General",
            appName: "Slack",
            bundleId: "com.tinyspeck.slackmacgap",
            browserURL: nil,
            dictionaryTerms: [],
            recentTexts: [],
            cleanupProfileOverride: .message,
            editExemplars: [rawExample],
            attemptRunner: { _, attempt in
                capturedAttempt = attempt
                return ConvexClient.CloudTextResponse(text: self.transcript, durationMs: 1)
            }
        )

        let finalInstruction = instruction(in: capturedAttempt)
        XCTAssertTrue(finalInstruction.contains("Personal style examples"))
        XCTAssertTrue(finalInstruction.contains("[redacted-email]"))
        XCTAssertTrue(finalInstruction.contains("[redacted-identifier]"))
        XCTAssertFalse(finalInstruction.contains("alice@example.com"))
        XCTAssertFalse(finalInstruction.contains("ABCD123456789"))
    }

    func testHIPAAModeAlwaysRemovesExamplesDespiteEarlierOptIn() async {
        let settings = SettingsManager.shared
        let saved = savePrivacySettings(settings)
        defer { restorePrivacySettings(saved, to: settings) }
        settings.cloudProcessingEnabled = true
        settings.hipaaMode = false
        settings.cloudPersonalizationExamplesEnabled = true
        settings.hipaaMode = true

        let client = makeClient()
        var capturedAttempt: CloudTextAttempt?

        _ = await client.processDictationCleanupDetailed(
            transcript: transcript,
            windowTitle: "General",
            appName: "Slack",
            bundleId: "com.tinyspeck.slackmacgap",
            browserURL: nil,
            dictionaryTerms: [],
            recentTexts: [],
            cleanupProfileOverride: .message,
            editExemplars: [rawExample],
            attemptRunner: { _, attempt in
                capturedAttempt = attempt
                return ConvexClient.CloudTextResponse(text: self.transcript, durationMs: 1)
            }
        )

        XCTAssertFalse(settings.cloudPersonalizationExamplesEnabled)
        XCTAssertFalse(instruction(in: capturedAttempt).contains("Personal style examples"))
    }

    func testFallbackRebuildsArgumentsAfterConsentIsRevokedDuringPrimaryFailure() async {
        let settings = SettingsManager.shared
        let saved = savePrivacySettings(settings)
        defer { restorePrivacySettings(saved, to: settings) }
        settings.cloudProcessingEnabled = true
        settings.hipaaMode = false
        settings.cloudPersonalizationExamplesEnabled = true

        let client = makeClient()
        var attempts: [CloudTextAttempt] = []

        _ = await client.processDictationCleanupDetailed(
            transcript: transcript,
            windowTitle: "General",
            appName: "Slack",
            bundleId: "com.tinyspeck.slackmacgap",
            browserURL: nil,
            dictionaryTerms: [],
            recentTexts: [],
            cleanupProfileOverride: .message,
            editExemplars: [rawExample],
            attemptRunner: { _, attempt in
                attempts.append(attempt)
                if attempts.count == 1 {
                    settings.cloudPersonalizationExamplesEnabled = false
                    throw self.missingPrimaryEndpointError()
                }
                return ConvexClient.CloudTextResponse(text: self.transcript, durationMs: 1)
            }
        )

        XCTAssertEqual(attempts.map(\.path), [
            "cloudProcessing:processDictationCleanup",
            "cloudProcessing:processTranscript",
        ])
        XCTAssertTrue(instruction(in: attempts.first).contains("Personal style examples"))
        XCTAssertFalse(instruction(in: attempts.last).contains("Personal style examples"))
        XCTAssertFalse(instruction(in: attempts.last).contains("alice@example.com"))
    }

    func testFallbackRebuildsArgumentsAfterHIPAAIsEnabledDuringPrimaryFailure() async {
        let settings = SettingsManager.shared
        let saved = savePrivacySettings(settings)
        defer { restorePrivacySettings(saved, to: settings) }
        settings.cloudProcessingEnabled = true
        settings.hipaaMode = false
        settings.cloudPersonalizationExamplesEnabled = true

        let client = makeClient()
        var attempts: [CloudTextAttempt] = []

        _ = await client.processDictationCleanupDetailed(
            transcript: transcript,
            windowTitle: "General",
            appName: "Slack",
            bundleId: "com.tinyspeck.slackmacgap",
            browserURL: nil,
            dictionaryTerms: [],
            recentTexts: [],
            cleanupProfileOverride: .message,
            editExemplars: [rawExample],
            attemptRunner: { _, attempt in
                attempts.append(attempt)
                if attempts.count == 1 {
                    settings.hipaaMode = true
                    throw self.missingPrimaryEndpointError()
                }
                return ConvexClient.CloudTextResponse(text: self.transcript, durationMs: 1)
            }
        )

        XCTAssertEqual(attempts.count, 2)
        XCTAssertTrue(instruction(in: attempts.first).contains("Personal style examples"))
        XCTAssertFalse(instruction(in: attempts.last).contains("Personal style examples"))
        XCTAssertFalse(settings.cloudPersonalizationExamplesEnabled)
    }

    func testDisclosurePromisesOnlyLimitedRedactionAndLocalDefault() {
        let copy = [
            PersonalizationDisclosureCopy.localMemory,
            PersonalizationDisclosureCopy.cloudExamples,
            PersonalizationDisclosureCopy.deviceLocalConsent,
            PersonalizationDisclosureCopy.hipaaDisabled,
        ].joined(separator: " ")

        XCTAssertTrue(copy.contains("Corrections stay local by default"))
        XCTAssertTrue(copy.contains("up to three prior correction snippets"))
        XCTAssertTrue(copy.contains("limited automatic redaction"))
        XCTAssertTrue(copy.contains("only to this Mac"))
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("anonymous"))
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("private"))
    }

    private func makeClient() -> ConvexClient {
        let authManager = AuthManager()
        authManager.userId = "cloud-consent-test-user"
        authManager.cloudAuthToken = "header.payload.signature"
        let client = ConvexClient(
            authManager: authManager,
            hostedServicesConfiguration: HostedServicesConfiguration(
                convexCloudURL: URL(string: "https://operator.example.com")!,
                authBaseURL: URL(string: "https://account.example.com")!
            )
        )
        return client
    }

    private func instruction(in attempt: CloudTextAttempt?) -> String {
        attempt?.args["instruction"] as? String ?? ""
    }

    private func missingPrimaryEndpointError() -> Error {
        ConvexError.serverError(
            "Could not find public function cloudProcessing:processDictationCleanup"
        )
    }

    private func savePrivacySettings(_ settings: SettingsManager) -> PrivacySettingsSnapshot {
        PrivacySettingsSnapshot(
            cloudProcessingEnabled: settings.cloudProcessingEnabled,
            hipaaMode: settings.hipaaMode,
            examplesEnabled: settings.cloudPersonalizationExamplesEnabled
        )
    }

    private func restorePrivacySettings(
        _ snapshot: PrivacySettingsSnapshot,
        to settings: SettingsManager
    ) {
        settings.cloudProcessingEnabled = snapshot.cloudProcessingEnabled
        settings.hipaaMode = false
        settings.cloudPersonalizationExamplesEnabled = snapshot.examplesEnabled
        settings.hipaaMode = snapshot.hipaaMode
    }

    private struct PrivacySettingsSnapshot {
        let cloudProcessingEnabled: Bool
        let hipaaMode: Bool
        let examplesEnabled: Bool
    }
}
