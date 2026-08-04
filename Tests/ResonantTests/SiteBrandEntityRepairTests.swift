import XCTest
@testable import Resonant

final class SiteBrandEntityRepairTests: XCTestCase {
    private func browserContext(
        windowTitle: String,
        url: String
    ) -> ContextExtractor.Context {
        var context = ContextExtractor.Context()
        context.appName = "Safari"
        context.bundleId = "com.apple.Safari"
        context.windowTitle = windowTitle
        context.browserURL = url
        return context
    }

    // MARK: - spokenForms shaping

    func testBareBrandTokenIsNotASiteDomainSpokenForm() {
        let forms = ContextEntityExtractor.spokenForms(for: "substack.com", type: .siteDomain)
        XCTAssertFalse(forms.contains("substack"), "bare brand label must not be a .siteDomain spoken form")
        XCTAssertTrue(forms.contains("substack.com"))
        XCTAssertTrue(forms.contains("substack com"))
        XCTAssertTrue(forms.contains("substack dot com"))
    }

    func testSiteDomainSpokenFormsStripWwwPrefix() {
        let forms = ContextEntityExtractor.spokenForms(for: "www.substack.com", type: .siteDomain)
        XCTAssertFalse(forms.contains("substack"))
        XCTAssertFalse(forms.contains(where: { $0.contains("www") }))
        XCTAssertTrue(forms.contains("substack.com"))
        XCTAssertTrue(forms.contains("substack dot com"))
    }

    func testMultiLabelHostKeepsDomainShapedForms() {
        let forms = ContextEntityExtractor.spokenForms(for: "example.co.uk", type: .siteDomain)
        XCTAssertFalse(forms.contains("example"))
        XCTAssertTrue(forms.contains("example.co.uk"))
        XCTAssertTrue(forms.contains("example co uk"))
        XCTAssertTrue(forms.contains("example dot co dot uk"))
    }

    // MARK: - repair behavior

    func testBareBrandRepairsToBrandCasingNotDomain() {
        let context = browserContext(
            windowTitle: "The Latest Post | Substack",
            url: "https://substack.com"
        )
        let packet = ContextPacketBuilder.build(
            transcript: "check out substack",
            context: context
        )
        let repaired = ContextualEntityRepair.repair("check out substack", using: packet)

        XCTAssertEqual(repaired.text, "check out Substack")
        XCTAssertFalse(repaired.text.contains(".com"))
        XCTAssertFalse(repaired.text.contains("https://"))
    }

    func testSpokenDomainStillRepairsToDomain() {
        let context = browserContext(
            windowTitle: "The Latest Post | Substack",
            url: "https://substack.com"
        )
        let packet = ContextPacketBuilder.build(
            transcript: "go to substack dot com",
            context: context
        )
        let repaired = ContextualEntityRepair.repair("go to substack dot com", using: packet)

        XCTAssertEqual(repaired.text, "go to substack.com")
        XCTAssertFalse(repaired.text.contains("https://"))
    }

    func testLearnedSuppressionBlocksSpokenDomainExpansion() {
        // Once the user has repeatedly reverted this host's expansion, even the
        // domain-shaped spoken form stays untouched.
        let context = browserContext(
            windowTitle: "The Latest Post | Substack",
            url: "https://substack.com"
        )
        let packet = ContextPacketBuilder.build(
            transcript: "go to substack dot com",
            context: context
        )
        let repaired = ContextualEntityRepair.repair(
            "go to substack dot com",
            using: packet,
            suppressedDomainHosts: ["substack.com"]
        )

        // Brand casing may still apply; the domain expansion must not.
        XCTAssertFalse(repaired.text.lowercased().contains("substack.com"))
        XCTAssertTrue(repaired.text.lowercased().contains("dot com"))
    }

    func testCommonWordBrandDoesNotProduceBrandCasingEntity() {
        let context = browserContext(
            windowTitle: "Some Article – Medium",
            url: "https://medium.com/@author/post"
        )
        let packet = ContextPacketBuilder.build(
            transcript: "a medium coffee please",
            context: context
        )

        XCTAssertFalse(
            packet.entities.contains(where: { $0.type == .customTerm && $0.evidence == "site brand name" }),
            "common English word host must not yield a brand-casing entity"
        )

        let repaired = ContextualEntityRepair.repair("a medium coffee please", using: packet)
        XCTAssertEqual(repaired.text, "a medium coffee please")
    }

    func testWindowTitleCasingWinsOverFallback() {
        // Host label "posthog" is in the known-brand map (PostHog), but a title
        // token proves the source-of-truth casing regardless.
        let candidate = ContextEntityExtractor.brandCasingCandidate(
            host: "posthog.com",
            windowTitle: "Dashboard · PostHog"
        )
        XCTAssertEqual(candidate?.value, "PostHog")
        XCTAssertEqual(candidate?.token, "posthog")
    }

    func testWindowTitleCasingBeatsFirstLetterFallback() {
        // Unknown brand not in the static map: title casing must still win.
        let candidate = ContextEntityExtractor.brandCasingCandidate(
            host: "acmewidgets.com",
            windowTitle: "Home | AcmeWidgets"
        )
        XCTAssertEqual(candidate?.value, "AcmeWidgets")
    }

    func testKnownBrandMapUsedWhenTitleAbsent() {
        let candidate = ContextEntityExtractor.brandCasingCandidate(
            host: "github.com",
            windowTitle: nil
        )
        XCTAssertEqual(candidate?.value, "GitHub")
    }

    func testFallbackCapitalizesFirstLetter() {
        let candidate = ContextEntityExtractor.brandCasingCandidate(
            host: "notarealbrand.com",
            windowTitle: nil
        )
        XCTAssertEqual(candidate?.value, "Notarealbrand")
    }

    func testRepairNeverEmitsHyperlinkScheme() {
        let context = browserContext(
            windowTitle: "Feed | Substack",
            url: "https://substack.com"
        )
        let packet = ContextPacketBuilder.build(
            transcript: "i only mention substack today",
            context: context
        )
        let repaired = ContextualEntityRepair.repair("i only mention substack today", using: packet)

        XCTAssertEqual(repaired.text, "i only mention Substack today")
        XCTAssertFalse(repaired.text.contains("https://"))
        XCTAssertFalse(repaired.text.contains("]("))
    }
}
