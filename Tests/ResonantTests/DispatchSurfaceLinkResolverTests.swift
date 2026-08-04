import XCTest
@testable import Resonant

final class DispatchSurfaceLinkResolverTests: XCTestCase {
    func testGmailURLBecomesDurableSurfaceLink() {
        let context = contextPacket(
            appName: "Google Chrome",
            browserURL: "https://mail.google.com/mail/u/0/#inbox/FMfcgzGtwExample",
            targetFingerprint: nil
        )

        let links = DispatchSurfaceLinkResolver.links(contextPacket: context)

        XCTAssertEqual(links.first?.kind, .gmail)
        XCTAssertEqual(links.first?.url, "https://mail.google.com/mail/u/0/#inbox/FMfcgzGtwExample")
        XCTAssertGreaterThanOrEqual(links.first?.confidence ?? 0, 0.9)
    }

    func testFocusedFieldFingerprintBecomesAnchorNotURL() {
        let context = contextPacket(
            appName: "Slack",
            browserURL: nil,
            targetFingerprint: ContextTargetFingerprint(
                role: "AXTextArea",
                subrole: nil,
                identifierToken: nil,
                titleToken: nil,
                descriptionToken: nil,
                placeholderToken: "message-field",
                helpToken: nil,
                frameBucket: "10:10:8:2",
                selectedRangeBucket: nil
            )
        )

        let links = DispatchSurfaceLinkResolver.links(contextPacket: context)

        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links[0].kind, .focusedFieldAnchor)
        XCTAssertNil(links[0].url)
        XCTAssertTrue(links[0].label.contains("Slack focused field"))
    }

    func testRecentSnapshotURLIsUsedWhenCurrentContextHasNoURL() {
        let links = DispatchSurfaceLinkResolver.links(
            contextPacket: nil,
            snapshots: [
                DispatchRouteSnapshot(
                    timestamp: Date(),
                    appName: "Safari",
                    bundleId: "com.apple.Safari",
                    windowTitle: "Fix command routing",
                    browserURL: "https://linear.app/resonant/issue/RES-123/fix-command-routing",
                    codeFileName: nil,
                    slackRecipient: nil,
                    focusedFieldContent: nil,
                    visibleTextSnippets: [],
                    browserTabs: []
                )
            ]
        )

        XCTAssertEqual(links.first?.kind, .linear)
        XCTAssertEqual(links.first?.url, "https://linear.app/resonant/issue/RES-123/fix-command-routing")
    }

    private func contextPacket(
        appName: String,
        browserURL: String?,
        targetFingerprint: ContextTargetFingerprint?
    ) -> ContextPacket {
        ContextPacket(
            id: UUID(),
            capturedAt: Date(),
            surface: SurfaceDescriptor(
                kind: .browser,
                appName: appName,
                bundleId: nil,
                windowTitle: "\(appName) window",
                browserURL: browserURL,
                siteHost: nil,
                siteName: nil,
                fieldKind: .reply,
                conversationLabel: nil,
                documentLabel: nil,
                projectLabel: nil
            ),
            intent: DictationIntent(
                kind: .command,
                confidence: 1,
                allowsBiasTerms: true,
                allowsStyleHint: true,
                allowsSelectedTextGrounding: true,
                allowsVisibleContextGrounding: true,
                allowsMemoryGrounding: true,
                evidence: []
            ),
            entities: [],
            styleHint: nil,
            selectedTextPreview: nil,
            focusedFieldPreview: nil,
            targetFingerprint: targetFingerprint,
            visibleGroundingSnippets: [],
            safetyFlags: [],
            latency: .empty
        )
    }
}
