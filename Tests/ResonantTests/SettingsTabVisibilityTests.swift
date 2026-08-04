import XCTest
@testable import Resonant

final class SettingsTabVisibilityTests: XCTestCase {
    func testSettingsSidebarUsesDailyDriverTabs() {
        let visibleTabs = SettingsTab.settingsSections.flatMap(\.tabs)

        XCTAssertTrue(visibleTabs.contains(.account))
        XCTAssertTrue(visibleTabs.contains(.dictation))
        XCTAssertTrue(visibleTabs.contains(.writing))
        XCTAssertTrue(visibleTabs.contains(.dictionary))
        XCTAssertTrue(visibleTabs.contains(.smartLinks))
        XCTAssertTrue(visibleTabs.contains(.meetingSettings))
        XCTAssertTrue(visibleTabs.contains(.personalization))
        XCTAssertTrue(visibleTabs.contains(.workspace))
        XCTAssertTrue(visibleTabs.contains(.appearance))
        XCTAssertTrue(visibleTabs.contains(.advanced))

        XCTAssertFalse(visibleTabs.contains(.models))
        XCTAssertFalse(visibleTabs.contains(.mcpServer))
        XCTAssertFalse(visibleTabs.contains(.apiCli))
        XCTAssertFalse(visibleTabs.contains(.progression))

        XCTAssertTrue(SettingsTab.dictation.isSettingsSidebarTab)
        XCTAssertTrue(SettingsTab.writing.isSettingsSidebarTab)
        XCTAssertTrue(SettingsTab.dictionary.isSettingsSidebarTab)
        XCTAssertTrue(SettingsTab.smartLinks.isSettingsSidebarTab)
        XCTAssertTrue(SettingsTab.personalization.isSettingsSidebarTab)
        XCTAssertFalse(SettingsTab.models.isSettingsSidebarTab)
    }

    func testSettingsSectionsAreAlphabetized() {
        let sections = Dictionary(uniqueKeysWithValues: SettingsTab.settingsSections.compactMap { section in
            section.label.map { ($0, section.tabs.map(\.displayName)) }
        })

        XCTAssertEqual(sections["General"], ["General", "Appearance"])
        XCTAssertEqual(
            sections["Use"],
            ["Dictation", "Dictionary", "Meetings", "Personalization", "Smart Links", "Writing"]
        )
    }

    func testAdvancedTabsRemainSearchable() {
        let resultTabs = Set(SettingsSearchIndex.entries.map(\.tab))

        XCTAssertTrue(resultTabs.contains(.dictionary))
        XCTAssertTrue(resultTabs.contains(.smartLinks))
        XCTAssertTrue(resultTabs.contains(.models))
        XCTAssertTrue(resultTabs.contains(.mcpServer))
        XCTAssertTrue(resultTabs.contains(.apiCli))
        XCTAssertTrue(resultTabs.contains(.personalization))
    }

    func testDispatchSettingsAreHiddenWhenFeatureIsNotVisible() {
        XCTAssertFalse(AppFeatureVisibility.dispatch)
        XCTAssertFalse(SettingsTab.dispatchDebug.isAvailable)
        XCTAssertFalse(SettingsTab.settingsSections.flatMap(\.tabs).contains(.dispatchDebug))
    }

    func testCloudSyncSettingsAreHiddenWhenFeatureIsNotVisible() {
        XCTAssertFalse(AppFeatureVisibility.cloudSync)
        XCTAssertFalse(SettingsSearchIndex.entries.contains { $0.title == "Cloud Sync" })
    }

}
