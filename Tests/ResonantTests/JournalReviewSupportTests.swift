import XCTest
@testable import Resonant

final class JournalReviewSupportTests: XCTestCase {

    func testBuildBlocksSplitsWhenAppChangesInsideBlockGap() {
        let start = Date(timeIntervalSince1970: 1_710_000_000)
        let entries = [
            makeEntry(
                text: "Reviewed the open pull request and noted two follow-up fixes.",
                appName: "Slack",
                bundleId: "com.tinyspeck.slackmacgap",
                date: start,
                slackRecipient: "design-team"
            ),
            makeEntry(
                text: "Adjusted the journal card spacing in SettingsView.swift.",
                appName: "Xcode",
                bundleId: "com.apple.dt.Xcode",
                date: start.addingTimeInterval(120),
                codeFileName: "SettingsView.swift"
            )
        ]

        let blocks = JournalBlockOrganizer.buildBlocks(from: entries, blockGap: 15 * 60)

        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks.map(\.appName), ["Slack", "Xcode"])
    }

    func testBuildBlocksSplitsSlackThreadsWithinSameApp() {
        let start = Date(timeIntervalSince1970: 1_710_000_000)
        let entries = [
            makeEntry(
                text: "Sent the handoff note to product about the journal issue.",
                appName: "Slack",
                bundleId: "com.tinyspeck.slackmacgap",
                date: start,
                slackRecipient: "product-team"
            ),
            makeEntry(
                text: "Answered support with the root cause and next fix.",
                appName: "Slack",
                bundleId: "com.tinyspeck.slackmacgap",
                date: start.addingTimeInterval(180),
                slackRecipient: "support-escalations"
            )
        ]

        let blocks = JournalBlockOrganizer.buildBlocks(from: entries, blockGap: 15 * 60)

        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks.map(\.contextLabel), ["product-team", "support-escalations"])
    }

    func testBuildBlocksKeepsSameBrowserHostTogether() {
        let start = Date(timeIntervalSince1970: 1_710_000_000)
        let entries = [
            makeEntry(
                text: "Reviewed the implementation notes in the Linear issue.",
                appName: "Arc",
                bundleId: "company.thebrowser.Browser",
                date: start,
                browserURL: "https://linear.app/example-workspace/issue/JRN-42",
                windowTitle: "JRN-42 Journal review polish - Linear"
            ),
            makeEntry(
                text: "Checked the follow-up comments and acceptance criteria.",
                appName: "Arc",
                bundleId: "company.thebrowser.Browser",
                date: start.addingTimeInterval(240),
                browserURL: "https://linear.app/example-workspace/issue/JRN-42?comment=1",
                windowTitle: "Comments - JRN-42 Journal review polish - Linear"
            )
        ]

        let blocks = JournalBlockOrganizer.buildBlocks(from: entries, blockGap: 15 * 60)

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.appName, "Arc")
    }

    func testCleanedSummaryStripsNarrationPrefixes() {
        let block = makeBlock(
            summary: "The speaker discussed tightening the journal grouping logic.",
            topicLabel: "Journal grouping"
        )

        XCTAssertEqual(
            JournalReviewEngine.cleanedSummary(for: block),
            "Tightening the journal grouping logic."
        )
    }

    func testAccomplishmentHighlightsMergeRepeatedNamedTask() {
        let start = Date(timeIntervalSince1970: 1_710_000_000)
        let blocks = [
            makeBlock(
                start: start,
                end: start.addingTimeInterval(600),
                summary: "The work session focused on improving journal grouping.",
                topicLabel: "Journal review overhaul",
                bundleId: "com.apple.dt.Xcode",
                appNames: ["Xcode"]
            ),
            makeBlock(
                start: start.addingTimeInterval(2_400),
                end: start.addingTimeInterval(3_000),
                summary: "The work session focused on refining accomplishment cards.",
                topicLabel: "Journal review overhaul",
                bundleId: "com.apple.dt.Xcode",
                appNames: ["Xcode", "Arc"]
            ),
            makeBlock(
                start: start.addingTimeInterval(4_200),
                end: start.addingTimeInterval(4_800),
                summary: "Reviewed pricing page copy with marketing.",
                topicLabel: "Pricing page copy",
                bundleId: "com.apple.Safari",
                appNames: ["Safari"]
            )
        ]

        let highlights = JournalReviewEngine.accomplishmentHighlights(from: blocks, limit: 4)

        XCTAssertEqual(highlights.count, 2)
        XCTAssertEqual(highlights.first?.title, "Journal review overhaul")
        XCTAssertEqual(highlights.first?.sessionCount, 2)
        XCTAssertEqual(highlights.first?.appNames, ["Xcode", "Arc"])
    }

    private func makeEntry(
        text: String,
        appName: String,
        bundleId: String,
        date: Date,
        browserURL: String? = nil,
        windowTitle: String? = nil,
        codeFileName: String? = nil,
        slackRecipient: String? = nil
    ) -> DictationEntry {
        DictationEntry(
            id: UUID(),
            text: text,
            appName: appName,
            bundleId: bundleId,
            windowTitle: windowTitle,
            browserURL: browserURL,
            codeFileName: codeFileName,
            slackRecipient: slackRecipient,
            wordCount: text.split(whereSeparator: \.isWhitespace).count,
            duration: 30,
            mode: .dictation,
            date: date
        )
    }

    private func makeBlock(
        start: Date = Date(timeIntervalSince1970: 1_710_000_000),
        end: Date = Date(timeIntervalSince1970: 1_710_000_600),
        summary: String,
        topicLabel: String?,
        bundleId: String = "com.apple.dt.Xcode",
        appNames: [String] = ["Xcode"]
    ) -> JournalBlock {
        JournalBlock(
            appName: appNames.first ?? "Resonant",
            bundleId: bundleId,
            contextLabel: "Context",
            entries: ["Worked on the journal presentation."],
            startTime: start,
            endTime: end,
            summary: summary,
            wordCount: 24,
            appsUsed: appNames.map { BlockAppInfo(appName: $0, bundleId: bundleId, entryCount: 1, wordCount: 24) },
            topicLabel: topicLabel,
            contextClues: ["SettingsView.swift"]
        )
    }
}
