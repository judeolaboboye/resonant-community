import CoreGraphics
import XCTest
@testable import Resonant

final class ActiveRecipientContextTests: XCTestCase {
    private let scope = CGRect(x: 500, y: 100, width: 420, height: 620)
    private let composer = CGRect(x: 520, y: 650, width: 380, height: 44)

    func testLinkedInFeedMessageComposerIsEligible() {
        let hot = linkedInHot()

        XCTAssertEqual(SurfaceClassifier.classify(hot: hot).kind, .social)
        XCTAssertEqual(SurfaceClassifier.classify(hot: hot).fieldKind, .comment)
        XCTAssertTrue(ActiveRecipientEligibility.allows(hot: hot))
        XCTAssertTrue(
            ActiveRecipientEligibility.focusedElementLooksLikeConversationComposer(
                attributes: ["AXTextArea", "Write a message…"]
            )
        )
    }

    func testEligibilityRejectsNonBrowserSearchFormAndSensitiveTargets() {
        XCTAssertFalse(ActiveRecipientEligibility.allows(hot: ContextExtractor.HotContext(
            appName: "Notes",
            bundleId: "com.apple.Notes",
            targetFingerprint: ContextTargetFingerprint(role: "AXTextArea")
        )))

        var search = linkedInHot()
        search.browserURL = "https://www.linkedin.com/search/results/people/"
        XCTAssertFalse(ActiveRecipientEligibility.allows(hot: search))

        var secure = linkedInHot()
        secure.targetFingerprint = ContextTargetFingerprint(
            role: "AXTextField",
            isSensitiveInput: true
        )
        XCTAssertFalse(ActiveRecipientEligibility.allows(hot: secure))

        XCTAssertFalse(
            ActiveRecipientEligibility.focusedElementLooksLikeConversationComposer(
                attributes: ["AXSearchField", "Search messages"]
            )
        )
        XCTAssertFalse(
            ActiveRecipientEligibility.focusedElementLooksLikeConversationComposer(
                attributes: ["AXTextArea", "Add a comment"]
            )
        )
        XCTAssertFalse(
            ActiveRecipientEligibility.focusedElementLooksLikeConversationComposer(
                attributes: ["AXTextArea", "Post your reply"]
            )
        )
        XCTAssertFalse(
            ActiveRecipientEligibility.focusedElementLooksLikeConversationComposer(
                attributes: ["AXTextArea", "Write a reply"]
            )
        )
        XCTAssertFalse(
            ActiveRecipientEligibility.focusedElementLooksLikeConversationComposer(
                attributes: ["AXTextField", "First name"]
            )
        )
    }

    func testResolverFindsHeaderRecipientAndIgnoresAdjacentInboxName() throws {
        let recipient = try XCTUnwrap(ActiveRecipientResolver.resolve(
            scopeFrame: scope,
            composerFrame: composer,
            evidence: [
                evidence("Henri Enguerran Badoux", .heading, x: 530, y: 125),
                evidence("Thanks Henri", .button, x: 540, y: 590),
                evidence("Ada Lovelace", .link, x: 120, y: 160),
            ]
        ))

        XCTAssertEqual(recipient.fullName, "Henri Enguerran Badoux")
        XCTAssertEqual(recipient.firstName, "Henri")
        XCTAssertEqual(recipient.confidence, 0.96)
    }

    func testResolverIgnoresAdjacentInboxInsideSharedAncestor() throws {
        let sharedScope = CGRect(x: 100, y: 100, width: 820, height: 620)
        let recipient = try XCTUnwrap(ActiveRecipientResolver.resolve(
            scopeFrame: sharedScope,
            composerFrame: composer,
            evidence: [
                evidence("Henri Enguerran Badoux", .heading, x: 530, y: 125),
                evidence("Ada Lovelace", .link, x: 130, y: 125),
            ]
        ))
        XCTAssertEqual(recipient.fullName, "Henri Enguerran Badoux")

        XCTAssertNil(ActiveRecipientResolver.resolve(
            scopeFrame: sharedScope,
            composerFrame: composer,
            evidence: [
                evidence("Ada Lovelace", .link, x: 130, y: 125),
            ]
        ))
    }

    func testEvidenceFactoryKeepsDescriptionsAsCorroboration() throws {
        let batch = ActiveRecipientEvidenceFactory.make(
            role: "AXLink",
            title: nil,
            value: "Henri Enguerran Badoux",
            description: "View Henri Enguerran Badoux’s profile",
            help: "Open Henri Enguerran Badoux",
            frame: CGRect(x: 530, y: 125, width: 250, height: 30),
            inheritedPrimaryKind: nil
        )

        XCTAssertEqual(batch.evidence.filter(\.kind.isPrimaryHeaderEvidence).count, 1)
        XCTAssertEqual(
            batch.evidence.filter { !$0.kind.isPrimaryHeaderEvidence }.count,
            2
        )
        XCTAssertEqual(batch.descendantPrimaryKind, .link)

        let recipient = try XCTUnwrap(ActiveRecipientResolver.resolve(
            scopeFrame: scope,
            composerFrame: composer,
            evidence: batch.evidence
        ))
        XCTAssertEqual(recipient.fullName, "Henri Enguerran Badoux")
        XCTAssertEqual(recipient.firstName, "Henri")
    }

    func testNestedHeadingLabelRetainsPrimaryRoleAndNavigationWrapperNormalizes() throws {
        let nestedLabel = ActiveRecipientEvidenceFactory.make(
            role: "AXStaticText",
            title: nil,
            value: "View Henri Enguerran Badoux’s profile",
            description: nil,
            help: nil,
            frame: CGRect(x: 530, y: 125, width: 250, height: 30),
            inheritedPrimaryKind: .heading
        )
        XCTAssertEqual(nestedLabel.evidence.first?.kind, .heading)

        let recipient = try XCTUnwrap(ActiveRecipientResolver.resolve(
            scopeFrame: scope,
            composerFrame: composer,
            evidence: nestedLabel.evidence
        ))
        XCTAssertEqual(recipient.fullName, "Henri Enguerran Badoux")
        XCTAssertEqual(recipient.firstName, "Henri")
    }

    func testResolverFailsClosedForAmbiguousHeader() {
        XCTAssertNil(ActiveRecipientResolver.resolve(
            scopeFrame: scope,
            composerFrame: composer,
            evidence: [
                evidence("Henri Enguerran Badoux", .heading, x: 530, y: 125),
                evidence("Ada Lovelace", .link, x: 540, y: 160),
            ]
        ))
    }

    func testResolverRejectsLoneHistoryOrQuotedName() {
        XCTAssertNil(ActiveRecipientResolver.resolve(
            scopeFrame: scope,
            composerFrame: composer,
            evidence: [
                evidence("Ada Lovelace", .staticText, x: 540, y: 300),
                evidence("From Grace Hopper", .staticText, x: 540, y: 360),
            ]
        ))
    }

    func testResolverClipsPartiallyOffScopePrimaryFrames() {
        XCTAssertNil(ActiveRecipientResolver.resolve(
            scopeFrame: scope,
            composerFrame: composer,
            evidence: [
                ActiveRecipientEvidence(
                    text: "Ada Lovelace",
                    kind: .heading,
                    frame: CGRect(x: 530, y: -200, width: 220, height: 700)
                ),
            ]
        ))
    }

    func testResolverRejectsGroupThreadAndMinimizedStaticHeader() {
        XCTAssertNil(ActiveRecipientResolver.resolve(
            scopeFrame: scope,
            composerFrame: composer,
            evidence: [
                evidence("Ada Lovelace", .heading, x: 530, y: 125),
                evidence("Grace Hopper", .link, x: 690, y: 125),
            ]
        ))
        XCTAssertNil(ActiveRecipientResolver.resolve(
            scopeFrame: scope,
            composerFrame: composer,
            evidence: [
                evidence("Henri Enguerran Badoux", .staticText, x: 530, y: 125),
            ]
        ))
    }

    func testResolverRejectsUILabelAndSupportsUnicodeName() throws {
        XCTAssertNil(ActiveRecipientResolver.resolve(
            scopeFrame: scope,
            composerFrame: composer,
            evidence: [
                evidence("New Message", .heading, x: 530, y: 125),
            ]
        ))

        let recipient = try XCTUnwrap(ActiveRecipientResolver.resolve(
            scopeFrame: scope,
            composerFrame: composer,
            evidence: [
                evidence("Élodie van der Meer", .heading, x: 530, y: 125),
            ]
        ))
        XCTAssertEqual(recipient.fullName, "Élodie van der Meer")
        XCTAssertEqual(recipient.firstName, "Élodie")
    }

    private func linkedInHot() -> ContextExtractor.HotContext {
        ContextExtractor.HotContext(
            appName: "Brave Browser",
            bundleId: "com.brave.browser",
            windowTitle: "Feed | LinkedIn",
            browserURL: "https://www.linkedin.com/feed/",
            targetFingerprint: ContextTargetFingerprint(
                role: "AXTextArea",
                isSensitiveInput: false
            )
        )
    }

    private func evidence(
        _ text: String,
        _ kind: ActiveRecipientEvidenceKind,
        x: CGFloat,
        y: CGFloat
    ) -> ActiveRecipientEvidence {
        ActiveRecipientEvidence(
            text: text,
            kind: kind,
            frame: CGRect(x: x, y: y, width: 220, height: 30)
        )
    }
}
