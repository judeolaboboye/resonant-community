import XCTest
import Defaults
@testable import Resonant

@MainActor
final class WorkspaceRoamingStoreTests: XCTestCase {
    override func tearDown() {
        Defaults[.smartLinks] = []
        super.tearDown()
    }

    func testSmartLinkWorkspaceMergeRemovesMissingLinks() {
        let store = SmartLinkStore()
        let kept = store.add(trigger: "docs", url: "https://example.com/docs")
        _ = store.add(trigger: "calendar", url: "https://example.com/calendar")

        store.mergeWorkspaceLinks([kept])

        XCTAssertEqual(store.links, [kept])
        XCTAssertEqual(Defaults[.smartLinks], [kept])
    }

    func testDictionaryWorkspaceMergeRemovesMissingWords() {
        let store = DictionaryStore()
        store.add(spoken: "resonance", written: "Resonant")
        store.add(spoken: "swift data", written: "SwiftData")

        let kept = store.workspaceSnapshot().first { $0.spoken == "resonance" }
        XCTAssertNotNil(kept)

        store.mergeWorkspaceWords(kept.map { [$0] } ?? [])

        XCTAssertEqual(store.allWords.map(\.spoken), ["resonance"])
    }
}
