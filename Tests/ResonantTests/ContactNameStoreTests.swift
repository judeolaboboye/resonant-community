import XCTest
@testable import Resonant

final class ContactNameStoreTests: XCTestCase {

    // MARK: - Per-contact candidates

    func testFullNameFamilyNicknameAndOrganizationAreCandidates() {
        let names = ContactNameStore.candidateNames(
            given: "Sarah",
            family: "Chen",
            nickname: "Saz-machine",
            organization: "Anthropic"
        )

        XCTAssertEqual(names, ["Sarah Chen", "Chen", "Saz-machine", "Anthropic"])
    }

    func testShortGivenNameAloneContributesNothing() {
        // "Mark" with no family name must not become a bare boost term — it
        // collides with the common word and would cause false rescues.
        let names = ContactNameStore.candidateNames(
            given: "Mark",
            family: "",
            nickname: "",
            organization: ""
        )

        XCTAssertTrue(names.isEmpty)
    }

    func testShortFamilyNameIsSkippedButFullNameKept() {
        let names = ContactNameStore.candidateNames(
            given: "Li",
            family: "Wu",
            nickname: "",
            organization: ""
        )

        XCTAssertEqual(names, ["Li Wu"])
    }

    // MARK: - Normalization

    func testNormalizationDedupesCaseInsensitivelyAndDropsNonLetters() {
        let names = ContactNameStore.normalizedNames([
            "Sarah Chen",
            "sarah chen",
            "  Anthropic ",
            "12345",
            "Wu",
        ])

        XCTAssertEqual(names, ["Sarah Chen", "Anthropic"])
    }

    func testNormalizationCapsStoredNames() {
        let raw = (0..<400).map { "Contact Number\($0)" }
        let names = ContactNameStore.normalizedNames(raw)

        XCTAssertEqual(names.count, ContactNameStore.maximumStoredNames)
        XCTAssertEqual(names.first, "Contact Number0")
    }
}
