import XCTest
@testable import Resonant

@MainActor
final class PersonalizationSettingsPresentationStateTests: XCTestCase {
    private let firstCapture = Date(timeIntervalSince1970: 2_000_000_000)
    private let secondCapture = Date(timeIntervalSince1970: 2_000_000_100)

    func testInitialRefreshKeepsDisclosureStructurallyIndependentFromStatus() throws {
        var state = PersonalizationSettingsPresentationState()

        XCTAssertEqual(state.disclosureText, PersonalizationDisclosureCopy.localMemory)
        let request = try XCTUnwrap(state.beginSnapshotRequest(.initial))
        let completion = try XCTUnwrap(
            state.completeSnapshotRequest(request, capturedAt: firstCapture)
        )

        XCTAssertEqual(state.disclosureText, PersonalizationDisclosureCopy.localMemory)
        XCTAssertEqual(state.operationStatus, .refreshCompleted(firstCapture))
        XCTAssertNil(completion.announcement)
    }

    func testManualRefreshStatusCoexistsWithDisclosureAndRequestsAnnouncement() throws {
        var state = PersonalizationSettingsPresentationState()
        let request = try XCTUnwrap(state.beginSnapshotRequest(.manual))
        let completion = try XCTUnwrap(
            state.completeSnapshotRequest(request, capturedAt: firstCapture)
        )

        XCTAssertEqual(state.disclosureText, PersonalizationDisclosureCopy.localMemory)
        XCTAssertEqual(state.operationStatus, .refreshCompleted(firstCapture))
        XCTAssertEqual(completion.announcement, .refreshCompleted)
    }

    func testResetCompletionFollowsPostResetSnapshotAndIsNotRewrittenAsUpdated() throws {
        var state = PersonalizationSettingsPresentationState()
        let staleInitial = try XCTUnwrap(state.beginSnapshotRequest(.initial))

        state.armReset()
        XCTAssertTrue(state.isResetArmed)
        XCTAssertEqual(state.operationStatus, .resetConfirmation)

        let reset = try XCTUnwrap(state.beginReset())
        XCTAssertFalse(state.isResetArmed)
        XCTAssertTrue(state.isResetInProgress)
        XCTAssertEqual(state.operationStatus, .resetConfirmation)
        XCTAssertNil(state.beginSnapshotRequest(.runtime))

        // The view fetches and installs the post-reset snapshot before this transition.
        XCTAssertTrue(state.canCompleteReset(reset))
        XCTAssertEqual(state.completeReset(reset), .resetCompleted)
        XCTAssertEqual(state.operationStatus, .resetCompleted)
        XCTAssertEqual(state.disclosureText, PersonalizationDisclosureCopy.localMemory)

        XCTAssertNil(
            state.completeSnapshotRequest(staleInitial, capturedAt: secondCapture)
        )
        XCTAssertEqual(state.operationStatus, .resetCompleted)
    }

    func testRuntimeRefreshCannotClobberResetConfirmationOrCompletion() throws {
        var state = PersonalizationSettingsPresentationState()
        state.armReset()

        let confirmationRefresh = try XCTUnwrap(state.beginSnapshotRequest(.runtime))
        XCTAssertNotNil(
            state.completeSnapshotRequest(
                confirmationRefresh,
                capturedAt: firstCapture
            )
        )
        XCTAssertTrue(state.isResetArmed)
        XCTAssertEqual(state.operationStatus, .resetConfirmation)

        let reset = try XCTUnwrap(state.beginReset())
        XCTAssertEqual(state.completeReset(reset), .resetCompleted)

        let completionRefresh = try XCTUnwrap(state.beginSnapshotRequest(.runtime))
        XCTAssertNotNil(
            state.completeSnapshotRequest(
                completionRefresh,
                capturedAt: secondCapture
            )
        )
        XCTAssertEqual(state.operationStatus, .resetCompleted)
        XCTAssertEqual(state.disclosureText, PersonalizationDisclosureCopy.localMemory)
    }

    func testLaterExplicitManualRefreshMayReplaceResetCompletion() throws {
        var state = PersonalizationSettingsPresentationState()
        state.armReset()
        let reset = try XCTUnwrap(state.beginReset())
        XCTAssertEqual(state.completeReset(reset), .resetCompleted)

        let refresh = try XCTUnwrap(state.beginSnapshotRequest(.manual))
        let completion = try XCTUnwrap(
            state.completeSnapshotRequest(refresh, capturedAt: secondCapture)
        )

        XCTAssertEqual(state.operationStatus, .refreshCompleted(secondCapture))
        XCTAssertEqual(completion.announcement, .refreshCompleted)
        XCTAssertEqual(state.disclosureText, PersonalizationDisclosureCopy.localMemory)
    }

    func testAnnouncerPostsBoundedRefreshAndResetCompletionText() {
        var values: [String] = []
        let announcer = PersonalizationSettingsAccessibilityAnnouncer {
            values.append($0)
        }

        announcer.post(.refreshCompleted)
        announcer.post(.resetCompleted)

        XCTAssertEqual(
            values,
            [
                "Personalization updated.",
                "Personalization memory reset.",
            ]
        )
    }

    func testOutcomeRecoveryBlocksCompetingSnapshotsAndPreservesMemoryStatus() throws {
        var state = PersonalizationSettingsPresentationState()
        state.armReset()
        let reset = try XCTUnwrap(state.beginReset())
        XCTAssertEqual(state.completeReset(reset), .resetCompleted)

        let recovery = try XCTUnwrap(state.beginOutcomeRecovery())
        XCTAssertTrue(state.isOutcomeRecoveryInProgress)
        XCTAssertTrue(state.isRefreshing)
        XCTAssertNil(state.beginSnapshotRequest(.runtime))

        state.armReset()
        XCTAssertEqual(state.operationStatus, .resetCompleted)
        XCTAssertFalse(state.isResetArmed)

        XCTAssertTrue(state.completeOutcomeRecovery(recovery))
        XCTAssertFalse(state.isOutcomeRecoveryInProgress)
        XCTAssertEqual(state.operationStatus, .resetCompleted)
        XCTAssertEqual(state.disclosureText, PersonalizationDisclosureCopy.localMemory)
    }

    func testOutcomeSetupCopyUsesOnlyBoundedCategoriesAndHasNoInertRefreshInstruction() {
        XCTAssertEqual(
            PersonalizationSettingsCopy.outcomesUnavailable(
                for: .unavailable(.localStorageNotReady)
            ),
            PersonalizationSettingsCopy.outcomesLocalStorageNotReady
        )
        XCTAssertEqual(
            PersonalizationSettingsCopy.outcomesUnavailable(
                for: .unavailable(.outcomeBootstrapUnavailable)
            ),
            PersonalizationSettingsCopy.outcomesBootstrapUnavailable
        )

        let copy = [
            PersonalizationSettingsCopy.outcomesNotStarted,
            PersonalizationSettingsCopy.outcomesSettingUp,
            PersonalizationSettingsCopy.outcomesRetrying,
            PersonalizationSettingsCopy.outcomesLocalStorageNotReady,
            PersonalizationSettingsCopy.outcomesBootstrapUnavailable,
            PersonalizationSettingsCopy.outcomesLoadingSummary,
        ].joined(separator: " ").lowercased()
        XCTAssertFalse(copy.contains("refresh after app setup"))
        XCTAssertFalse(copy.contains("error:"))
        XCTAssertFalse(copy.contains("/users/"))
    }

    func testExternalOutcomeAvailabilityRefreshIsStatusSilent() throws {
        var state = PersonalizationSettingsPresentationState()
        state.armReset()
        let reset = try XCTUnwrap(state.beginReset())
        XCTAssertEqual(state.completeReset(reset), .resetCompleted)

        let refresh = try XCTUnwrap(state.beginSnapshotRequest(.outcomeSetup))
        let completion = try XCTUnwrap(
            state.completeSnapshotRequest(refresh, capturedAt: secondCapture)
        )

        XCTAssertNil(completion.announcement)
        XCTAssertEqual(state.operationStatus, .resetCompleted)
        XCTAssertEqual(state.disclosureText, PersonalizationDisclosureCopy.localMemory)
    }

    func testOrdinaryRefreshNeverCallsOutcomeSetup() async {
        var snapshot = PersonalizationControlsSnapshot.empty
        snapshot.capturedAt = firstCapture
        var snapshotCount = 0
        var setupCount = 0
        let actions = PersonalizationSettingsDataActions(
            loadControlsSnapshot: {
                snapshotCount += 1
                return snapshot
            },
            retryOutcomeSetup: {
                setupCount += 1
                return .available
            }
        )

        let refreshed = await actions.refreshSnapshot()

        XCTAssertEqual(refreshed.capturedAt, firstCapture)
        XCTAssertEqual(snapshotCount, 1)
        XCTAssertEqual(setupCount, 0)
    }

    func testOutcomeRetryFetchesSilentlyOnlyAfterSetupSucceeds() async throws {
        var snapshot = PersonalizationControlsSnapshot.empty
        snapshot.capturedAt = secondCapture
        var snapshotCount = 0
        var setupResults: [PersonalizationOutcomeSetupState] = [
            .unavailable(.outcomeBootstrapUnavailable),
            .available,
        ]
        let actions = PersonalizationSettingsDataActions(
            loadControlsSnapshot: {
                snapshotCount += 1
                return snapshot
            },
            retryOutcomeSetup: {
                setupResults.removeFirst()
            }
        )

        let failed = await actions.recoverOutcomes()
        XCTAssertEqual(
            failed,
            .unavailable(.unavailable(.outcomeBootstrapUnavailable))
        )
        XCTAssertEqual(snapshotCount, 0)

        var presentation = PersonalizationSettingsPresentationState()
        presentation.armReset()
        let reset = try XCTUnwrap(presentation.beginReset())
        XCTAssertEqual(presentation.completeReset(reset), .resetCompleted)
        let recovery = try XCTUnwrap(presentation.beginOutcomeRecovery())

        let recovered = await actions.recoverOutcomes()
        let refreshed: PersonalizationControlsSnapshot
        switch recovered {
        case let .available(value):
            refreshed = value
        case let .unavailable(state):
            XCTFail("Expected available recovery, got \(state)")
            return
        }

        XCTAssertEqual(refreshed.capturedAt, secondCapture)
        XCTAssertEqual(snapshotCount, 1)
        XCTAssertTrue(presentation.completeOutcomeRecovery(recovery))
        XCTAssertEqual(
            presentation.operationStatus,
            .resetCompleted,
            "outcome recovery is status-silent and must not replace Memory status"
        )
        XCTAssertEqual(
            presentation.disclosureText,
            PersonalizationDisclosureCopy.localMemory
        )
    }
}
