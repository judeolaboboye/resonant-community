import XCTest
@testable import Resonant

final class JournalSignalEngineTests: XCTestCase {

    func testExpansionAlertUsesTopicLanguageAndExamples() {
        let start = Date(timeIntervalSince1970: 1_710_000_000)
        let days = [
            makeDay(offset: 0, topics: ["inbox cleanup", "settings polish"], date: start),
            makeDay(offset: 1, topics: ["journal cards", "settings polish"], date: start.addingTimeInterval(86_400)),
            makeDay(offset: 2, topics: ["pricing copy", "ci cleanup"], date: start.addingTimeInterval(172_800)),
            makeDay(offset: 3, topics: ["onboarding review", "pricing copy"], date: start.addingTimeInterval(259_200))
        ]

        let signal = JournalSignalEngine
            .signals(from: days, referenceDate: start.addingTimeInterval(259_200))
            .first { $0.kind == .expansionAlert }

        XCTAssertEqual(signal?.title, "3 new topics appeared")
        XCTAssertEqual(
            signal?.detail,
            "These topic labels showed up in the last few days but not earlier in the week: Ci Cleanup, Onboarding Review, Pricing Copy."
        )
    }

    func testExpansionAlertUsesManyTopicsHeadlineForLargeCounts() {
        let start = Date(timeIntervalSince1970: 1_710_500_000)
        let days = [
            makeDay(offset: 0, topics: ["planning", "design"], date: start),
            makeDay(offset: 1, topics: ["implementation", "review"], date: start.addingTimeInterval(86_400)),
            makeDay(
                offset: 2,
                topics: ["api migration", "ci cleanup", "dashboard polish", "onboarding review"],
                date: start.addingTimeInterval(172_800)
            ),
            makeDay(
                offset: 3,
                topics: ["pricing copy", "release prep", "settings audit", "support follow-up"],
                date: start.addingTimeInterval(259_200)
            )
        ]

        let signal = JournalSignalEngine
            .signals(from: days, referenceDate: start.addingTimeInterval(259_200))
            .first { $0.kind == .expansionAlert }

        XCTAssertEqual(signal?.title, "Work expanded into many new topics")
        XCTAssertEqual(
            signal?.detail,
            "These topic labels showed up in the last few days but not earlier in the week: Api Migration, Ci Cleanup, Dashboard Polish."
        )
    }

    // MARK: - Context switching

    func testContextSwitchingHighFragmentation() {
        let start = Date(timeIntervalSince1970: 1_710_000_000)
        let earlier = makeDay(offset: 0, topics: ["planning"], date: start)
        let today = JournalDay(date: start.addingTimeInterval(86_400))
        // 11 blocks alternating between two different topics/bundles → 10 switches
        today.updateBlocks((0..<11).map { i in
            makeBlock(
                topicLabel: i.isMultiple(of: 2) ? "api work" : "docs update",
                appName: i.isMultiple(of: 2) ? "Xcode" : "Chrome",
                bundleId: i.isMultiple(of: 2) ? "com.apple.dt.Xcode" : "com.google.Chrome",
                start: start.addingTimeInterval(86_400 + Double(i * 600))
            )
        })

        let signal = JournalSignalEngine
            .signals(from: [earlier, today])
            .first { $0.kind == .contextSwitching }

        XCTAssertNotNil(signal)
        XCTAssertEqual(signal?.title, "Highly fragmented day")
    }

    func testNoContextSwitchingForFewBlocks() {
        let start = Date(timeIntervalSince1970: 1_710_000_000)
        let earlier = makeDay(offset: 0, topics: ["planning"], date: start)
        let today = makeDay(offset: 1, topics: ["same", "same"], date: start.addingTimeInterval(86_400))

        let signal = JournalSignalEngine
            .signals(from: [earlier, today])
            .first { $0.kind == .contextSwitching }

        XCTAssertNil(signal)
    }

    // MARK: - Deep work

    func testDeepWorkSignalFor90MinBlock() {
        let start = Date(timeIntervalSince1970: 1_710_000_000)
        let earlier = makeDay(offset: 0, topics: ["warmup"], date: start)
        let today = JournalDay(date: start.addingTimeInterval(86_400))
        today.updateBlocks([
            makeBlock(
                topicLabel: "big feature",
                appName: "Xcode",
                bundleId: "com.apple.dt.Xcode",
                start: start.addingTimeInterval(86_400),
                durationMinutes: 100
            )
        ])

        let signal = JournalSignalEngine
            .signals(from: [earlier, today])
            .first { $0.kind == .deepWork }

        XCTAssertNotNil(signal)
        XCTAssert(signal!.title.contains("100min"))
    }

    func testNoDeepWorkForShortBlocks() {
        let start = Date(timeIntervalSince1970: 1_710_000_000)
        let earlier = makeDay(offset: 0, topics: ["warmup"], date: start)
        let today = makeDay(offset: 1, topics: ["short task"], date: start.addingTimeInterval(86_400))

        let signal = JournalSignalEngine
            .signals(from: [earlier, today])
            .first { $0.kind == .deepWork }

        XCTAssertNil(signal)
    }

    // MARK: - Meeting load

    func testMeetingHeavyDay() {
        let start = Date(timeIntervalSince1970: 1_710_000_000)
        let earlier = makeDay(offset: 0, topics: ["planning"], date: start)
        let today = JournalDay(date: start.addingTimeInterval(86_400))
        today.updateBlocks([
            makeMeetingBlock(title: "Standup", start: start.addingTimeInterval(86_400), durationMinutes: 60),
            makeMeetingBlock(title: "Design review", start: start.addingTimeInterval(86_400 + 3600), durationMinutes: 90),
            makeMeetingBlock(title: "Retro", start: start.addingTimeInterval(86_400 + 7200), durationMinutes: 60),
        ])

        let signal = JournalSignalEngine
            .signals(from: [earlier, today])
            .first { $0.kind == .meetingLoad }

        XCTAssertNotNil(signal)
        XCTAssertEqual(signal?.title, "Meeting-heavy day")
    }

    // MARK: - Communication heavy

    func testCommunicationHeavyDay() {
        let start = Date(timeIntervalSince1970: 1_710_000_000)
        let earlier = makeDay(offset: 0, topics: ["code"], date: start)
        let today = JournalDay(date: start.addingTimeInterval(86_400))
        today.updateBlocks([
            makeBlock(topicLabel: "slack chat", appName: "Slack", bundleId: "com.tinyspeck.slackmacgap",
                      start: start.addingTimeInterval(86_400), wordCount: 200),
            makeBlock(topicLabel: "code", appName: "Xcode", bundleId: "com.apple.dt.Xcode",
                      start: start.addingTimeInterval(86_400 + 3600), wordCount: 50),
        ])

        let signal = JournalSignalEngine
            .signals(from: [earlier, today])
            .first { $0.kind == .communicationHeavy }

        XCTAssertNotNil(signal)
        XCTAssertEqual(signal?.title, "Communication-heavy day")
    }

    // MARK: - Topic focus

    func testLaserFocusedDay() {
        let start = Date(timeIntervalSince1970: 1_710_000_000)
        let earlier = makeDay(offset: 0, topics: ["warmup"], date: start)
        let today = JournalDay(date: start.addingTimeInterval(86_400))
        today.updateBlocks(
            (0..<5).map { i in
                makeBlock(
                    topicLabel: "auth migration",
                    appName: "Xcode",
                    bundleId: "com.apple.dt.Xcode",
                    start: start.addingTimeInterval(86_400 + Double(i * 600))
                )
            }
        )

        let signal = JournalSignalEngine
            .signals(from: [earlier, today])
            .first { $0.kind == .topicFocus }

        XCTAssertNotNil(signal)
        XCTAssertEqual(signal?.title, "Laser-focused day")
    }

    func testScatteredDay() {
        let start = Date(timeIntervalSince1970: 1_710_000_000)
        let earlier = makeDay(offset: 0, topics: ["warmup"], date: start)
        let today = JournalDay(date: start.addingTimeInterval(86_400))
        today.updateBlocks(
            ["auth", "billing", "deploy", "logging", "onboarding", "tests"].enumerated().map { i, topic in
                makeBlock(
                    topicLabel: topic,
                    appName: "Xcode",
                    bundleId: "com.apple.dt.Xcode",
                    start: start.addingTimeInterval(86_400 + Double(i * 600))
                )
            }
        )

        let signal = JournalSignalEngine
            .signals(from: [earlier, today])
            .first { $0.kind == .topicFocus }

        XCTAssertNotNil(signal)
        XCTAssert(signal!.title.contains("6 topics"))
    }

    // MARK: - Day character

    func testBuilderDay() {
        let start = Date(timeIntervalSince1970: 1_710_000_000)
        let earlier = makeDay(offset: 0, topics: ["warmup"], date: start)
        let today = JournalDay(date: start.addingTimeInterval(86_400))
        today.updateBlocks([
            makeBlock(topicLabel: "feature", appName: "Xcode", bundleId: "com.apple.dt.Xcode",
                      start: start.addingTimeInterval(86_400), wordCount: 300),
            makeBlock(topicLabel: "browsing", appName: "Chrome", bundleId: "com.google.Chrome",
                      start: start.addingTimeInterval(86_400 + 3600), wordCount: 50),
        ])

        let signal = JournalSignalEngine
            .signals(from: [earlier, today])
            .first { $0.kind == .dayCharacter }

        XCTAssertNotNil(signal)
        XCTAssertEqual(signal?.title, "Builder day")
    }

    func testResearchDay() {
        let start = Date(timeIntervalSince1970: 1_710_000_000)
        let earlier = makeDay(offset: 0, topics: ["warmup"], date: start)
        let today = JournalDay(date: start.addingTimeInterval(86_400))
        today.updateBlocks([
            makeBlock(topicLabel: "reading docs", appName: "Safari", bundleId: "com.apple.Safari",
                      start: start.addingTimeInterval(86_400), wordCount: 300),
            makeBlock(topicLabel: "code", appName: "Xcode", bundleId: "com.apple.dt.Xcode",
                      start: start.addingTimeInterval(86_400 + 3600), wordCount: 50),
        ])

        let signal = JournalSignalEngine
            .signals(from: [earlier, today])
            .first { $0.kind == .dayCharacter }

        XCTAssertNotNil(signal)
        XCTAssertEqual(signal?.title, "Research day")
    }

    // MARK: - Meeting trend

    func testMeetingTrendClimbing() {
        let start = Date(timeIntervalSince1970: 1_710_000_000)
        var days: [JournalDay] = []

        // First 2 days: no meetings
        for i in 0..<2 {
            days.append(makeDay(offset: i, topics: ["code"], date: start.addingTimeInterval(Double(i) * 86_400)))
        }
        // Last 2 days: 90min meetings each
        for i in 2..<4 {
            let dayDate = start.addingTimeInterval(Double(i) * 86_400)
            let day = JournalDay(date: dayDate)
            day.updateBlocks([
                makeBlock(topicLabel: "code", appName: "Xcode", bundleId: "com.apple.dt.Xcode",
                          start: dayDate, wordCount: 100),
                makeMeetingBlock(title: "Sync", start: dayDate.addingTimeInterval(3600), durationMinutes: 90),
            ])
            days.append(day)
        }

        let signal = JournalSignalEngine
            .signals(from: days)
            .first { $0.kind == .meetingTrend }

        XCTAssertNotNil(signal)
        XCTAssert(signal!.title.contains("climbing"))
    }

    // MARK: - Helpers

    private func makeDay(offset: Int, topics: [String], date: Date) -> JournalDay {
        let day = JournalDay(date: date)
        day.updateBlocks(
            topics.enumerated().map { index, topic in
                makeBlock(
                    topicLabel: topic,
                    appName: "Xcode",
                    bundleId: "com.apple.dt.Xcode",
                    start: date.addingTimeInterval(Double(index * 600))
                )
            }
        )
        return day
    }

    private func makeBlock(
        topicLabel: String,
        appName: String,
        bundleId: String,
        start: Date,
        durationMinutes: Int = 5,
        wordCount: Int = 120
    ) -> JournalBlock {
        JournalBlock(
            appName: appName,
            bundleId: bundleId,
            contextLabel: "Context",
            entries: ["Worked on \(topicLabel)."],
            startTime: start,
            endTime: start.addingTimeInterval(Double(durationMinutes) * 60),
            summary: "Worked on \(topicLabel).",
            wordCount: wordCount,
            appsUsed: [BlockAppInfo(appName: appName, bundleId: bundleId, entryCount: 1, wordCount: wordCount)],
            topicLabel: topicLabel,
            contextClues: ["\(topicLabel).swift"],
            accomplishment: nil
        )
    }

    private func makeMeetingBlock(
        title: String,
        start: Date,
        durationMinutes: Int
    ) -> JournalBlock {
        JournalBlock(
            appName: "Zoom",
            bundleId: "us.zoom.xos",
            contextLabel: title,
            entries: ["Meeting: \(title)"],
            startTime: start,
            endTime: start.addingTimeInterval(Double(durationMinutes) * 60),
            summary: title,
            wordCount: 50,
            isMeeting: true,
            meetingTitle: title,
            meetingApp: "Zoom",
            meetingDurationSeconds: Double(durationMinutes) * 60
        )
    }
}
