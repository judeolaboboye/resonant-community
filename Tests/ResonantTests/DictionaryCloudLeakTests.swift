import XCTest
@testable import Resonant

/// Tests that dictionary corrections stay local and don't leak into or conflict
/// with cloud processing. These cover the exact bug scenario: dictionary terms
/// being injected into cloud output for unrelated dictation.
@MainActor
final class DictionaryCloudLeakTests: XCTestCase {

    private var store: DictionaryStore!

    override func setUp() {
        super.setUp()
        store = DictionaryStore()
        // Simulate a typical dictionary: brand names, people, jargon
        store.add(spoken: "rezzonant", written: "Resonant")
        store.add(spoken: "parakeet tdt", written: "Parakeet TDT")
        store.add(spoken: "convects", written: "Convex")
        store.add(spoken: "john doe", written: "Jon Do")
    }

    // MARK: - Dictionary still works locally

    func testDictionaryCorrectsMisspokenBrandName() {
        let result = store.applyCorrections(to: "I really like rezzonant for dictation")
        XCTAssertEqual(result, "I really like Resonant for dictation")
    }

    func testDictionaryCorrectionIsCaseInsensitive() {
        let result = store.applyCorrections(to: "REZZONANT is great")
        XCTAssertEqual(result, "Resonant is great")
    }

    func testDictionaryDoesNotTouchUnrelatedText() {
        let input = "Please send the report to the client by Friday"
        let result = store.applyCorrections(to: input)
        XCTAssertEqual(result, input, "Dictionary should not modify text that contains no spoken-form matches")
    }

    func testDictionaryDoesNotPartialMatchInsideWords() {
        // "convects" is a spoken form, but "convection" should not be touched
        let input = "The convection oven is broken"
        let result = store.applyCorrections(to: input)
        XCTAssertEqual(result, input, "Dictionary should use word boundaries, not substring matching")
    }

    func testDictionaryAppliesMultipleCorrectionsInOnePass() {
        let result = store.applyCorrections(to: "rezzonant uses parakeet tdt for transcription")
        XCTAssertEqual(result, "Resonant uses Parakeet TDT for transcription")
    }

    // MARK: - cloudDictionaryTerms returns only written forms

    func testCloudDictionaryTermsReturnsWrittenForms() {
        let terms = store.cloudDictionaryTerms()
        XCTAssertTrue(terms.contains("Resonant"))
        XCTAssertTrue(terms.contains("Parakeet TDT"))
        XCTAssertTrue(terms.contains("Convex"))
        XCTAssertFalse(terms.contains("rezzonant"), "Spoken forms should never be sent to cloud")
        XCTAssertFalse(terms.contains("convects"), "Spoken forms should never be sent to cloud")
    }

    // MARK: - sanitizePostProcessingOutput catches injected terms

    /// Demonstrates that the sanitizer alone does NOT catch subtle term injection.
    /// When most original tokens are preserved, a few injected dictionary terms
    /// slip past the novel-token ratio check. This is exactly why we must prevent
    /// the leak at the source (don't send dictionary terms to the cloud prompt)
    /// rather than relying on the sanitizer as a safety net.
    func testSanitizerDoesNotCatchSubtleDictionaryTermInjection() {
        let original = "please send the report to the client by friday"
        // LLM injects "Resonant Parakeet TDT" — only 3 novel tokens among 10 original
        let injected = "Please send the Resonant Parakeet TDT report to the client by Friday."

        let result = CloudProcessingSupport.sanitizePostProcessingOutput(
            original: original,
            result: injected
        )
        // Sanitizer accepts this because novel token ratio is below threshold.
        // This proves the fix MUST happen at the prompt level, not post-hoc.
        XCTAssertTrue(result.accepted,
            "Sanitizer cannot catch subtle injection — confirms we need source-level prevention")
        XCTAssertTrue(result.text.contains("Resonant"),
            "Injected terms pass through sanitizer undetected")
    }

    /// Simulates cloud correctly cleaning a transcript that already has dictionary
    /// corrections applied. The sanitizer should accept this.
    func testSanitizeAcceptsCleanedTextWithDictionaryCorrectedTerms() {
        // Dictionary already turned "rezzonant" -> "Resonant" before cloud saw it
        let original = "I really like Resonant for dictation its the best"
        let cleaned = "I really like Resonant for dictation. It's the best."

        let result = CloudProcessingSupport.sanitizePostProcessingOutput(
            original: original,
            result: cleaned
        )
        XCTAssertTrue(result.accepted, "Cloud correctly cleaned grammar around a dictionary term — should be accepted")
        XCTAssertTrue(result.text.contains("Resonant"))
    }

    /// Cloud should be able to fix real STT errors without dictionary involvement.
    func testSanitizeAcceptsSTTErrorFixWithoutDictionaryTerms() {
        let original = "can you set up a meting with the teem tomorrow"
        let cleaned = "Can you set up a meeting with the team tomorrow?"

        let result = CloudProcessingSupport.sanitizePostProcessingOutput(
            original: original,
            result: cleaned
        )
        XCTAssertTrue(result.accepted)
        // Dictated questions keep the cleaned `?` — the sanitizer preserves
        // question-mark terminators when the original starts with a
        // question word ("can", "what", ...).
        XCTAssertEqual(result.text, "Can you set up a meeting with the team tomorrow?")
    }

    /// Edge case: user dictates something that sounds like a dictionary term's
    /// written form but in a different context. Cloud shouldn't mess with it
    /// since dictionary already handled it (or deliberately didn't).
    func testSanitizeAcceptsTextWhereSpokenFormIsACommonWord() {
        // "convects" is a real English word (heat convects upward)
        // The dictionary replaces it with "Convex", but only at word boundaries
        let original = "the heat convects through the metal quickly"
        let cleaned = "The heat convects through the metal quickly."

        let result = CloudProcessingSupport.sanitizePostProcessingOutput(
            original: original,
            result: cleaned
        )
        XCTAssertTrue(result.accepted)
        // This is actually a problem with the dictionary entry itself (false positive),
        // but the cloud shouldn't make it worse
    }

    // MARK: - Email-specific scenarios (where the leak was noticed)

    /// The sanitizer strips the "Sure, here's..." preamble but the injected term
    /// in the body still passes validation. Another case showing the sanitizer is
    /// not sufficient to catch dictionary leaks — source prevention is required.
    func testSanitizerStripsAssistantPreambleButNotInjectedTerms() {
        let original = "hey priya thanks for the update on the project"
        let llmOutput = "Sure, here's the cleaned email:\n\nHey Priya,\n\nThanks for the update on the Resonant project.\n\nBest regards"

        let result = CloudProcessingSupport.sanitizePostProcessingOutput(
            original: original,
            result: llmOutput
        )
        // The "Sure, here's..." gets stripped, but "Resonant" in the body survives.
        // This confirms the sanitizer alone is not enough — we must not send
        // dictionary terms to the cloud in the first place.
        XCTAssertTrue(result.accepted,
            "Sanitizer strips preamble but accepts the body with injected terms")
    }

    func testSanitizeAcceptsMinimalEmailCleanup() {
        let original = "hey priya thanks for the update lets sync tomorrow"
        let cleaned = "Hey Priya, thanks for the update. Let's sync tomorrow."

        let result = CloudProcessingSupport.sanitizePostProcessingOutput(
            original: original,
            result: cleaned
        )
        XCTAssertTrue(result.accepted)
        XCTAssertFalse(result.text.contains("Resonant"), "No dictionary terms should appear in unrelated email")
        XCTAssertFalse(result.text.contains("Parakeet"), "No dictionary terms should appear in unrelated email")
    }

    // MARK: - Short input edge cases

    func testSanitizeHandlesShortDictationWithDictionaryTerm() {
        // User says "rezzonant" -> dictionary corrects to "Resonant"
        // Cloud should accept minor formatting, not inject extra content
        let original = "Resonant"
        let cleaned = "Resonant"

        let result = CloudProcessingSupport.sanitizePostProcessingOutput(
            original: original,
            result: cleaned
        )
        XCTAssertTrue(result.accepted)
        XCTAssertEqual(result.text, "Resonant")
    }

    func testSanitizeRejectsShortInputExpandedWithDictionaryTerms() {
        let original = "send the report"
        // LLM expands short input and injects dictionary terms
        let expanded = "Send the Resonant Parakeet TDT report to the team by end of day."

        let result = CloudProcessingSupport.sanitizePostProcessingOutput(
            original: original,
            result: expanded
        )
        XCTAssertFalse(
            result.accepted,
            "Short input expanded with injected dictionary terms should be rejected"
        )
    }
}
