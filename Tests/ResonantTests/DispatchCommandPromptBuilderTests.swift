import XCTest
@testable import Resonant

final class DispatchCommandPromptBuilderTests: XCTestCase {
    func testPromptIncludesActionSchemaAndCommand() {
        let prompt = DispatchCommandPromptBuilder.build(
            command: "open weather in Vienna",
            context: nil
        )

        XCTAssertTrue(prompt.contains("Respond ONLY with a single JSON object"))
        XCTAssertTrue(prompt.contains(#"{"action": "open_url""#))
        XCTAssertTrue(prompt.contains("USER COMMAND: open weather in Vienna"))
        XCTAssertFalse(prompt.contains("CONTEXT:"))
    }

    func testPromptIncludesSurfaceContextWhenAvailable() {
        let context = contextPacket(
            appName: "Safari",
            bundleId: "com.apple.Safari",
            windowTitle: "Weather Search",
            browserURL: "https://google.com/search?q=weather",
            kind: .browser,
            fieldKind: .search
        )

        let prompt = DispatchCommandPromptBuilder.build(
            command: "get me the weather",
            context: context
        )

        XCTAssertTrue(prompt.contains("CONTEXT:"))
        XCTAssertTrue(prompt.contains("Active app: Safari"))
        XCTAssertTrue(prompt.contains("Bundle ID: com.apple.Safari"))
        XCTAssertTrue(prompt.contains("Window: Weather Search"))
        XCTAssertTrue(prompt.contains("URL: https://google.com/search?q=weather"))
        XCTAssertTrue(prompt.contains("Surface: browser"))
        XCTAssertTrue(prompt.contains("Focused field: search"))
        XCTAssertTrue(prompt.contains("EXECUTION PLAYBOOKS:"))
    }

    func testPromptIncludesGroundingForAppSpecificTasks() {
        var context = contextPacket(
            appName: "Linear",
            bundleId: "com.linear",
            windowTitle: "Resonant Project",
            browserURL: nil,
            kind: .task,
            fieldKind: .title
        )
        context.surface.projectLabel = "Resonant"
        context.focusedFieldPreview = "Bug title"
        context.visibleGroundingSnippets = ["Dispatch command failures", "Crash after launch"]

        let prompt = DispatchCommandPromptBuilder.build(
            command: "create a task for this bug",
            context: context
        )

        XCTAssertTrue(prompt.contains("Focused field: title"))
        XCTAssertTrue(prompt.contains("Project: Resonant"))
        XCTAssertTrue(prompt.contains("Focused field preview: Bug title"))
        XCTAssertTrue(prompt.contains("Visible snippets: Dispatch command failures | Crash after launch"))
        XCTAssertTrue(prompt.contains("For Linear/GitHub task commands, use create_ticket"))
    }

    func testPromptIncludesSurfaceLinksAndTargetAnchors() {
        var context = contextPacket(
            appName: "Google Chrome",
            bundleId: "com.google.Chrome",
            windowTitle: "Inbox - Gmail",
            browserURL: "https://mail.google.com/mail/u/0/#inbox/FMfcgzGtwExample",
            kind: .email,
            fieldKind: .reply
        )
        context.targetFingerprint = ContextTargetFingerprint(
            role: "AXTextArea",
            subrole: nil,
            identifierToken: nil,
            titleToken: nil,
            descriptionToken: nil,
            placeholderToken: "reply-field",
            helpToken: nil,
            frameBucket: "10:10:8:2",
            selectedRangeBucket: nil
        )

        let prompt = DispatchCommandPromptBuilder.build(
            command: "reply here that I will handle it",
            context: context
        )

        XCTAssertTrue(prompt.contains("Surface links: Gmail=https://mail.google.com/mail/u/0/#inbox/FMfcgzGtwExample"))
        XCTAssertTrue(prompt.contains("Target anchors: Google Chrome focused field"))
        XCTAssertTrue(prompt.contains("Treat SURFACE LINKS as durable return targets"))
        XCTAssertTrue(prompt.contains("Treat TARGET ANCHOR as an in-session focused-field locator"))
    }

    private func contextPacket(
        appName: String,
        bundleId: String,
        windowTitle: String,
        browserURL: String?,
        kind: SurfaceKind,
        fieldKind: FieldKind
    ) -> ContextPacket {
        ContextPacket(
            id: UUID(),
            capturedAt: Date(),
            surface: SurfaceDescriptor(
                kind: kind,
                appName: appName,
                bundleId: bundleId,
                windowTitle: windowTitle,
                browserURL: browserURL,
                siteHost: nil,
                siteName: nil,
                fieldKind: fieldKind,
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
            targetFingerprint: nil,
            visibleGroundingSnippets: [],
            safetyFlags: [],
            latency: .empty
        )
    }
}
