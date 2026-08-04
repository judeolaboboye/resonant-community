import Darwin
import XCTest
@testable import Resonant

final class DeliveryAttributionContractsTests: XCTestCase {
    func testTargetMatcherExhaustiveIdentifierAndEvidenceTable() {
        struct Case {
            let name: String
            let delivery: CorrectionTargetIdentity
            let observed: CorrectionTargetIdentity
            let expected: CorrectionTargetMatchResult
        }

        let strong = fingerprint()
        let fallback = fingerprint(identifier: nil)
        let cases: [Case] = [
            Case(
                name: "equal strong identifier",
                delivery: identity(fingerprint: strong),
                observed: identity(fingerprint: strong),
                expected: .match
            ),
            Case(
                name: "PID mismatch",
                delivery: identity(processIdentifier: 100, fingerprint: strong),
                observed: identity(processIdentifier: 101, fingerprint: strong),
                expected: .mismatch
            ),
            Case(
                name: "missing PID",
                delivery: identity(fingerprint: strong),
                observed: identity(processIdentifier: nil, fingerprint: strong),
                expected: .insufficientEvidence
            ),
            Case(
                name: "bundle mismatch",
                delivery: identity(bundleIdentifier: "com.example.one", fingerprint: strong),
                observed: identity(bundleIdentifier: "com.example.two", fingerprint: strong),
                expected: .mismatch
            ),
            Case(
                name: "missing bundle",
                delivery: identity(fingerprint: strong),
                observed: identity(bundleIdentifier: nil, fingerprint: strong),
                expected: .insufficientEvidence
            ),
            Case(
                name: "delivery sensitive",
                delivery: identity(isSensitiveInput: true, fingerprint: strong),
                observed: identity(fingerprint: strong),
                expected: .mismatch
            ),
            Case(
                name: "observed sensitive",
                delivery: identity(fingerprint: strong),
                observed: identity(isSensitiveInput: true, fingerprint: strong),
                expected: .mismatch
            ),
            Case(
                name: "sensitivity unknown",
                delivery: identity(isSensitiveInput: nil, fingerprint: fingerprint(sensitive: nil)),
                observed: identity(fingerprint: strong),
                expected: .insufficientEvidence
            ),
            Case(
                name: "fingerprint sensitivity overrides stale false",
                delivery: identity(
                    isSensitiveInput: false,
                    fingerprint: fingerprint(sensitive: true)
                ),
                observed: identity(fingerprint: strong),
                expected: .mismatch
            ),
            Case(
                name: "missing fingerprint",
                delivery: identity(fingerprint: strong),
                observed: identity(fingerprint: nil),
                expected: .insufficientEvidence
            ),
            Case(
                name: "unequal identifiers",
                delivery: identity(fingerprint: strong),
                observed: identity(fingerprint: fingerprint(identifier: "other-id")),
                expected: .mismatch
            ),
            Case(
                name: "identifier disappears",
                delivery: identity(fingerprint: strong),
                observed: identity(fingerprint: fallback),
                expected: .insufficientEvidence
            ),
            Case(
                name: "identifier appears",
                delivery: identity(fingerprint: fallback),
                observed: identity(fingerprint: strong),
                expected: .insufficientEvidence
            ),
            Case(
                name: "strong role conflict",
                delivery: identity(fingerprint: strong),
                observed: identity(fingerprint: fingerprint(role: "AXTextField")),
                expected: .mismatch
            ),
            Case(
                name: "strong subrole conflict",
                delivery: identity(fingerprint: strong),
                observed: identity(fingerprint: fingerprint(subrole: "AXSearchField")),
                expected: .mismatch
            ),
            Case(
                name: "strong title conflict",
                delivery: identity(fingerprint: strong),
                observed: identity(fingerprint: fingerprint(title: "other-title")),
                expected: .mismatch
            ),
            Case(
                name: "strong description conflict",
                delivery: identity(fingerprint: strong),
                observed: identity(fingerprint: fingerprint(description: "other-description")),
                expected: .mismatch
            ),
            Case(
                name: "strong help conflict",
                delivery: identity(fingerprint: strong),
                observed: identity(fingerprint: fingerprint(help: "other-help")),
                expected: .mismatch
            ),
            Case(
                name: "two present placeholders conflict",
                delivery: identity(fingerprint: strong),
                observed: identity(fingerprint: fingerprint(placeholder: "other-placeholder")),
                expected: .mismatch
            ),
            Case(
                name: "placeholder disappearance and geometry changes ignored",
                delivery: identity(fingerprint: strong),
                observed: identity(fingerprint: fingerprint(
                    placeholder: nil,
                    frame: "moved-frame",
                    selectedRange: "changed-selection"
                )),
                expected: .match
            ),
            Case(
                name: "missing strong stable field is not a conflict",
                delivery: identity(fingerprint: strong),
                observed: identity(fingerprint: fingerprint(title: nil, description: nil)),
                expected: .match
            ),
            Case(
                name: "fallback quorum",
                delivery: identity(fingerprint: fallback),
                observed: identity(fingerprint: fallback),
                expected: .match
            ),
            Case(
                name: "fallback role conflict",
                delivery: identity(fingerprint: fallback),
                observed: identity(fingerprint: fingerprint(identifier: nil, role: "AXTextField")),
                expected: .mismatch
            ),
            Case(
                name: "fallback subrole conflict",
                delivery: identity(fingerprint: fallback),
                observed: identity(fingerprint: fingerprint(identifier: nil, subrole: "AXSearchField")),
                expected: .mismatch
            ),
            Case(
                name: "fallback frame conflict",
                delivery: identity(fingerprint: fallback),
                observed: identity(fingerprint: fingerprint(identifier: nil, frame: "other-frame")),
                expected: .mismatch
            ),
            Case(
                name: "fallback missing role",
                delivery: identity(fingerprint: fallback),
                observed: identity(fingerprint: fingerprint(identifier: nil, role: nil)),
                expected: .insufficientEvidence
            ),
            Case(
                name: "fallback missing subrole",
                delivery: identity(fingerprint: fallback),
                observed: identity(fingerprint: fingerprint(identifier: nil, subrole: nil)),
                expected: .insufficientEvidence
            ),
            Case(
                name: "fallback missing frame",
                delivery: identity(fingerprint: fallback),
                observed: identity(fingerprint: fingerprint(identifier: nil, frame: nil)),
                expected: .insufficientEvidence
            ),
            Case(
                name: "fallback label conflict",
                delivery: identity(fingerprint: fallback),
                observed: identity(fingerprint: fingerprint(identifier: nil, title: "other-title")),
                expected: .mismatch
            ),
            Case(
                name: "fallback one-label quorum",
                delivery: identity(fingerprint: fingerprint(
                    identifier: nil,
                    description: nil,
                    placeholder: nil,
                    help: nil
                )),
                observed: identity(fingerprint: fingerprint(
                    identifier: nil,
                    description: nil,
                    placeholder: nil,
                    help: nil
                )),
                expected: .insufficientEvidence
            ),
            Case(
                name: "fallback two-label quorum tolerates missing labels",
                delivery: identity(fingerprint: fingerprint(identifier: nil, placeholder: nil, help: nil)),
                observed: identity(fingerprint: fingerprint(identifier: nil, placeholder: nil, help: nil)),
                expected: .match
            ),
            Case(
                name: "fallback selection change ignored",
                delivery: identity(fingerprint: fallback),
                observed: identity(fingerprint: fingerprint(identifier: nil, selectedRange: "changed")),
                expected: .match
            ),
        ]

        for testCase in cases {
            XCTAssertEqual(
                CorrectionTargetMatcher.match(
                    delivery: testCase.delivery,
                    observed: testCase.observed
                ),
                testCase.expected,
                testCase.name
            )
        }
    }

    func testLearningCapabilityResolutionTable() {
        struct Case {
            let name: String
            let correctionEligible: Bool
            let rawHabitEligible: Bool
            let autoSent: Bool
            let selectionTransformUsed: Bool
            let expected: LearningCapabilities
        }

        let cases: [Case] = [
            Case(
                name: "no eligible channel",
                correctionEligible: false,
                rawHabitEligible: false,
                autoSent: false,
                selectionTransformUsed: false,
                expected: .none
            ),
            Case(
                name: "ordinary correction",
                correctionEligible: true,
                rawHabitEligible: false,
                autoSent: false,
                selectionTransformUsed: false,
                expected: .correctionDerivedMutations
            ),
            Case(
                name: "ordinary delivery can carry both",
                correctionEligible: true,
                rawHabitEligible: true,
                autoSent: false,
                selectionTransformUsed: false,
                expected: [.correctionDerivedMutations, .rawTranscriptHabits]
            ),
            Case(
                name: "auto-send is raw-habit only",
                correctionEligible: true,
                rawHabitEligible: true,
                autoSent: true,
                selectionTransformUsed: false,
                expected: .rawTranscriptHabits
            ),
            Case(
                name: "low-confidence auto-send learns nothing",
                correctionEligible: true,
                rawHabitEligible: false,
                autoSent: true,
                selectionTransformUsed: false,
                expected: .none
            ),
            Case(
                name: "selection transform vetoes both",
                correctionEligible: true,
                rawHabitEligible: true,
                autoSent: false,
                selectionTransformUsed: true,
                expected: .none
            ),
        ]

        for testCase in cases {
            XCTAssertEqual(
                LearningCapabilities.resolving(
                    correctionDerivedEligible: testCase.correctionEligible,
                    rawTranscriptHabitEligible: testCase.rawHabitEligible,
                    autoSent: testCase.autoSent,
                    selectionTransformUsed: testCase.selectionTransformUsed
                ),
                testCase.expected,
                testCase.name
            )
        }
    }

    private func identity(
        processIdentifier: pid_t? = 100,
        bundleIdentifier: String? = "com.example.editor",
        isSensitiveInput: Bool? = false,
        fingerprint: ContextTargetFingerprint?
    ) -> CorrectionTargetIdentity {
        CorrectionTargetIdentity(
            processIdentifier: processIdentifier,
            bundleIdentifier: bundleIdentifier,
            isSensitiveInput: isSensitiveInput,
            fingerprint: fingerprint
        )
    }

    private func fingerprint(
        identifier: String? = "field-id",
        role: String? = "AXTextArea",
        subrole: String? = "AXStandardTextArea",
        sensitive: Bool? = false,
        title: String? = "title-token",
        description: String? = "description-token",
        placeholder: String? = "placeholder-token",
        help: String? = "help-token",
        frame: String? = "1:2:3:4",
        selectedRange: String? = "0:0"
    ) -> ContextTargetFingerprint {
        ContextTargetFingerprint(
            role: role,
            subrole: subrole,
            isSensitiveInput: sensitive,
            identifierToken: identifier,
            titleToken: title,
            descriptionToken: description,
            placeholderToken: placeholder,
            helpToken: help,
            frameBucket: frame,
            selectedRangeBucket: selectedRange
        )
    }
}
