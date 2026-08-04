import XCTest
@testable import Resonant

final class ITNProcessorTests: XCTestCase {

    func testNormalizesSentenceCardinals() {
        XCTAssertEqual(
            ITNProcessor().process("I have twenty one apples"),
            "I have 21 apples"
        )
    }

    func testPreservesMicrosoft365ProductName() {
        XCTAssertEqual(
            ITNProcessor().process("Microsoft three sixty five"),
            "Microsoft 365"
        )
    }

    // MARK: - Spoken email addresses

    func testAssemblesSpokenEmailWithoutCollapsingSurroundingClause() {
        // Regression: NeMo's electronic grammar used to fuse the whole clause
        // around the address into "...welcomeemailtoAlex@Example.com".
        // The assembled address itself is lowercased (ASR capitalization of
        // spoken names reads as noise in an email address); the prose around
        // it keeps its casing.
        XCTAssertEqual(
            ITNProcessor().process(
                "Frida, send the same welcome email to Alex at Example dot com who signed up."
            ),
            "Frida, send the same welcome email to alex@example.com who signed up."
        )
    }

    func testAssemblesSpokenEmailPreservingCaseAndTrailingText() {
        XCTAssertEqual(
            ITNProcessor().process("send the update to person at example dot com"),
            "send the update to person@example.com"
        )
        XCTAssertEqual(
            ITNProcessor().process("Frida, send the same email to alex at example dot com."),
            "Frida, send the same email to alex@example.com."
        )
    }

    func testAssemblesSpokenEmailWithDottedLocalPartAndMultiLevelDomain() {
        XCTAssertEqual(
            ITNProcessor().process("john dot smith at gmail dot com"),
            "john.smith@gmail.com"
        )
        XCTAssertEqual(
            ITNProcessor().process("contact at example dot co dot uk"),
            "contact@example.co.uk"
        )
    }

    func testDoesNotAssembleEmailFromPrepositionalAtWithDeterminerDomain() {
        // "look at this dot com" is prose, not an address — the determiner
        // domain guard must keep us from manufacturing "this.com".
        let outputs = [
            ITNProcessor().process("look at this dot com to see more"),
            ITNProcessor().process("let us look at that dot org website together"),
        ]
        for output in outputs {
            XCTAssertFalse(output.contains("this.com"), output)
            XCTAssertFalse(output.contains("that.org"), output)
        }
    }

    func testPrepositionalAtIsNeverTurnedIntoAtSign() {
        // Regression: NeMo's electronic grammar used to fuse prose around a
        // prepositional "at" ("look at this" -> "look@this").
        let look = ITNProcessor().process("look at this dot com to see more")
        XCTAssertFalse(look.contains("@"), look)
        XCTAssertTrue(look.contains("look at this"), look)

        let meeting = ITNProcessor().process("we met at noon to discuss the deal")
        XCTAssertFalse(meeting.contains("@"), meeting)
        XCTAssertTrue(meeting.contains("we met at noon"), meeting)

        // Time and other "at" usages keep the word intact.
        XCTAssertEqual(
            ITNProcessor().process("the meeting is at ten fifteen"),
            "the meeting is at 10:15"
        )
    }

    func testExplicitAtSignStillNormalizes() {
        // "at sign" must keep normalizing to "@" — only bare "at" is shielded.
        XCTAssertTrue(
            ITNProcessor().process("my handle is at sign sourcetms").contains("@")
        )
    }

    func testProseAtBeforeRealEmailIsPreservedAndEmailAssembled() {
        let output = ITNProcessor().process(
            "email me at the address alex at example dot com"
        )
        XCTAssertTrue(output.contains("at the address"), output)
        XCTAssertTrue(output.contains("alex@example.com"), output)
    }

    func testLowercasesAssembledEmail() {
        XCTAssertEqual(
            ITNProcessor().process("John dot Smith at Gmail dot com"),
            "john.smith@gmail.com"
        )
        // Surrounding prose keeps its original casing.
        XCTAssertEqual(
            ITNProcessor().process("Email to Alex at Example dot com please"),
            "Email to alex@example.com please"
        )
    }

    func testSupportsPlusConnectorInEmailLocalPart() {
        XCTAssertEqual(
            ITNProcessor().process("john plus news at gmail dot com"),
            "john+news@gmail.com"
        )
    }

    func testPlusStaysArithmeticWithoutEmailAnchor() {
        // No "at <domain> dot <tld>" anchor, so "plus" is untouched by the
        // email pass (NeMo's arithmetic grammar may still render "+").
        let output = ITNProcessor().process("two plus two is four")
        XCTAssertFalse(output.contains("@"), output)
    }

    func testAbsorbsTrailingDigitWordsOntoLocalHandle() {
        XCTAssertEqual(
            ITNProcessor().process("john seven seven at gmail dot com"),
            "john77@gmail.com"
        )
    }

    func testStandaloneDigitWordLocalKeepsCurrentBehavior() {
        XCTAssertEqual(
            ITNProcessor().process("seven at gmail dot com"),
            "seven@gmail.com"
        )
    }

    func testExistingEmailToAlexStillAssembles() {
        XCTAssertEqual(
            ITNProcessor().process("email to Alex at example dot com"),
            "email to alex@example.com"
        )
    }

    // MARK: - Spoken phone numbers

    func testFormatsSevenDigitPhoneAfterCallCue() {
        XCTAssertEqual(
            ITNProcessor().process("call five five five one two three four"),
            "call 555-1234"
        )
    }

    func testFormatsTenDigitPhoneAfterNumberCue() {
        XCTAssertEqual(
            ITNProcessor().process("my number is five five five one two three four five six seven"),
            "my number is 555-123-4567"
        )
    }

    func testFormatsPlusOneCountryCodePhone() {
        XCTAssertEqual(
            ITNProcessor().process(
                "text me at plus one five five five one two three four five six seven"
            ),
            "text me at +1 555-123-4567"
        )
    }

    func testFormatsPhoneWithExtension() {
        XCTAssertEqual(
            ITNProcessor().process(
                "call one two three one two three five six seven eight extension nine nine"
            ),
            "call 123-123-5678 ext. 99"
        )
    }

    func testExpandsDoubleDigitInSpokenPhone() {
        XCTAssertEqual(
            ITNProcessor().process("call five five five double two three four"),
            "call 555-2234"
        )
    }

    func testExpandsTripleDigitInSpokenPhone() {
        // "triple five" expands to 555; the full run digitizes to 5551212
        // (grouping separators may be inserted downstream).
        let output = ITNProcessor().process("triple five one two one two")
        XCTAssertEqual(output.filter(\.isNumber), "5551212", output)
    }

    func testInvoiceNumberIsNotPhoneReformattedByOurPass() {
        // NeMo may already group the run; our cue-gated pass must be idempotent
        // on an ID/reference context and never re-format it. Proven directly on
        // the recomposer, which is the unit under our control.
        XCTAssertEqual(
            PhoneNumberRecomposer.recompose("the invoice number is 5551234567"),
            "the invoice number is 5551234567"
        )
    }

    func testYearAndPercentUnaffectedByPhonePass() {
        XCTAssertEqual(
            ITNProcessor().process("in nineteen ninety five five percent"),
            "in 1995 5%"
        )
    }

    func testCurrencyAmountUnaffectedByPhonePass() {
        XCTAssertEqual(
            ITNProcessor().process("otherwise we pay 120 5 dollars"),
            "otherwise we pay $125"
        )
    }

    func testNormalizesMoneyAndPunctuation() {
        XCTAssertEqual(
            ITNProcessor().process("it costs five dollars and fifty cents period"),
            "it costs $5.50 ."
        )
    }

    func testNormalizesFragmentedDigitDollarAmount() {
        XCTAssertEqual(
            ITNProcessor().process("otherwise we pay 120 5 dollars"),
            "otherwise we pay $125"
        )
    }

    func testNormalizesFragmentedDigitEuroAmount() {
        XCTAssertEqual(
            ITNProcessor().process("otherwise we pay 120 5 euros"),
            "otherwise we pay €125"
        )
    }

    func testNormalizesFragmentedDigitPercent() {
        XCTAssertEqual(
            ITNProcessor().process("conversion is 20 5 percent"),
            "conversion is 25%"
        )
    }

    func testYearHeadDoesNotMergeWithFollowingCount() {
        // "In 2020 5 percent…" is a year then a count, not the number 2025.
        XCTAssertEqual(
            ITNProcessor().process("In 2020 5 percent of users churned"),
            "In 2020 5% of users churned"
        )
    }

    func testNormalizesDatesAndTimesInsideSentence() {
        XCTAssertEqual(
            ITNProcessor().process("schedule it for january fifth twenty twenty five at quarter past two pm"),
            "schedule it for january 5 2025 at 02:15 p.m."
        )
    }

    func testConcatenatesStandaloneSpokenDigits() {
        XCTAssertEqual(
            ITNProcessor().process("one two three"),
            "123"
        )
    }

    func testConcatenatesSpokenDigitsInsideSentence() {
        XCTAssertEqual(
            ITNProcessor().process("my code is one two three"),
            "my code is 123"
        )
    }

    func testPreservesUpstreamPhoneFormattingForLongerDigitRuns() {
        XCTAssertEqual(
            ITNProcessor().process("call one two three one two three five six seven eight"),
            "call 123-123-5678"
        )
    }

    func testQuestionMarkFormattingIsPreservedForUserFacingText() {
        let normalized = ITNProcessor().process("is that right question mark")
        XCTAssertEqual(
            TextFormatter.finalize(normalized),
            "Is that right?"
        )
    }

    func testAutoPunctuationCanBeDisabled() {
        XCTAssertEqual(
            ITNProcessor().process("is that right question mark", autoPunctuationEnabled: false),
            "is that right question mark"
        )
    }

    func testFinalFormatterCleansUpUserFacingText() {
        XCTAssertEqual(
            TextFormatter.finalize("it costs $5.50 ."),
            "It costs $5.50."
        )
    }

    func testSmartBulletDetectsOrdinalList() {
        XCTAssertEqual(
            TextFormatter.finalize(
                "first buy milk second call john third send the email",
                bulletPointsEnabled: true
            ),
            "1. Buy milk\n2. Call john\n3. Send the email"
        )
    }

    func testSmartBulletDetectsNumberPrefixList() {
        XCTAssertEqual(
            TextFormatter.finalize(
                "number one buy milk number two call john number three send the email",
                bulletPointsEnabled: true
            ),
            "1. Buy milk\n2. Call john\n3. Send the email"
        )
    }

    func testSmartBulletIgnoresRegularProse() {
        XCTAssertEqual(
            TextFormatter.finalize(
                "I went to the store and bought some things.",
                bulletPointsEnabled: true
            ),
            "I went to the store and bought some things."
        )
    }

    func testSmartBulletDetectsCommaNouns() {
        XCTAssertEqual(
            TextFormatter.finalize(
                "red apples, green oranges, yellow bananas, purple grapes",
                bulletPointsEnabled: true
            ),
            "- Red apples\n- Green oranges\n- Yellow bananas\n- Purple grapes"
        )
    }

    // MARK: - Time pattern protection

    func testTimePatternTenFifteen() {
        XCTAssertEqual(
            ITNProcessor().process("ten fifteen"),
            "10:15"
        )
    }

    func testTimePatternInSentence() {
        XCTAssertEqual(
            ITNProcessor().process("the meeting is at ten fifteen"),
            "the meeting is at 10:15"
        )
    }

    func testTimePatternElevenFortyFive() {
        XCTAssertEqual(
            ITNProcessor().process("eleven forty five"),
            "11:45"
        )
    }

    func testTimePatternTwelveThirty() {
        XCTAssertEqual(
            ITNProcessor().process("twelve thirty"),
            "12:30"
        )
    }

    func testTimePatternTwoOhFive() {
        XCTAssertEqual(
            ITNProcessor().process("two oh five"),
            "2:05"
        )
    }

    func testTimePatternWithAmPm() {
        XCTAssertEqual(
            ITNProcessor().process("ten fifteen pm"),
            "10:15 p.m."
        )
    }

    func testTimePatternThreeThirty() {
        XCTAssertEqual(
            ITNProcessor().process("three thirty"),
            "3:30"
        )
    }

    func testDigitizedMetersSquaredUsesAreaSymbol() {
        XCTAssertEqual(
            ITNProcessor().process("16 meters squared"),
            "16 m²"
        )
    }

    func testSpokenMetersSquaredUsesAreaSymbol() {
        XCTAssertEqual(
            ITNProcessor().process("sixteen meters squared"),
            "16 m²"
        )
    }

    // MARK: - Percent normalization

    func testSpokenPercentCollapsesSpace() {
        XCTAssertEqual(
            ITNProcessor().process("ninety nine percent"),
            "99%"
        )
    }

    func testDigitsPercentCollapsesSpace() {
        XCTAssertEqual(
            ITNProcessor().process("99 percent"),
            "99%"
        )
    }

    func testOneHundredPercentCollapsesSpace() {
        XCTAssertEqual(
            ITNProcessor().process("one hundred percent"),
            "100%"
        )
    }

    func testSpokenHyphenatedNumberBeforePercentSymbol() {
        XCTAssertEqual(
            ITNProcessor().process("ninety-nine % off"),
            "99% off"
        )
    }

    // MARK: - Magnitude normalization

    func testDigitThousandPhraseUsesGroupedNumber() {
        XCTAssertEqual(
            ITNProcessor().process("Change the figure to 75 thousand people on the homepage"),
            "Change the figure to 75,000 people on the homepage"
        )
    }

    func testSpokenThousandPhraseUsesGroupedNumber() {
        XCTAssertEqual(
            ITNProcessor().process("change the figure to seventy five thousand people"),
            "change the figure to 75,000 people"
        )
    }

    func testCompactKSpacingIsPreserved() {
        XCTAssertEqual(
            ITNProcessor().process("Change the figure to 75 k people on the homepage"),
            "Change the figure to 75k people on the homepage"
        )
    }

    func testDigitHundredPhraseUsesCompactNumber() {
        XCTAssertEqual(
            ITNProcessor().process("one video is 1200 and three videos is 25 hundred"),
            "1 video is 1200 3 videos is 2500"
        )
    }

    func testDigitHundredsUseCompactNumberAcrossRange() {
        let processor = ITNProcessor()

        for number in 2...99 {
            XCTAssertEqual(
                processor.process("\(number) hundred"),
                "\(number * 100)",
                "\(number) hundred should normalize to \(number * 100)"
            )
        }
    }

    func testDigitHundredWithSpuriousTrailingZeroUsesCompactNumber() {
        XCTAssertEqual(
            ITNProcessor().process("three videos is 250 hundred"),
            "3 videos is 2500"
        )
    }

    func testDigitHundredPlusWordRemainderRecombines() {
        let processor = ITNProcessor()
        let cases: [(String, String)] = [
            ("100 forty", "140"),
            ("200 fifty five", "255"),
            ("160 per month", "160 per month"),  // round hundred-less digit untouched
            ("100 and forty", "140"),
            ("300 nineteen", "319"),
            ("100 forty-five", "145"),
            ("900 ninety nine", "999"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(
                processor.process(input),
                expected,
                "\"\(input)\" should normalize to \"\(expected)\""
            )
        }
    }

    func testDigitHundredPlusWordRemainderLeavesBareOnesAlone() {
        // "100 five" is ambiguous ("100 five-star") so the pass must not turn it
        // into 105; "five" still digitizes downstream but the hundred stays.
        XCTAssertEqual(ITNProcessor().process("100 five star rating"), "100 5 star rating")
    }

    func testDigitThousandPlusAndWordRemainderRecombines() {
        let processor = ITNProcessor()
        let cases: [(String, String)] = [
            ("2000 and fifteen", "2015"),
            ("1200 and fifty", "1250"),
            ("2500 and sixty", "2560"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(
                processor.process(input),
                expected,
                "\"\(input)\" should normalize to \"\(expected)\""
            )
        }
    }

    func testDigitThousandWithoutAndStaysSeparate() {
        // "in 1900 forty percent" is a year followed by a count — only an
        // explicit "and" marks a single spoken cardinal at thousand scale.
        let result = ITNProcessor().process("in 1900 forty percent of people voted")
        XCTAssertFalse(result.contains("1940"), result)
    }

    func testDigitThousandRemainderBeforeHundredRecombines() {
        // A seam inside "two thousand five | hundred" digitizes to
        // "2005 hundred"; the trailing ones digit was the hundreds count.
        XCTAssertEqual(
            ITNProcessor().process("the quote was 2005 hundred"),
            "the quote was 2500"
        )
    }

    // MARK: - Decimal point normalization

    func testSpokenDecimalPointCollapsesToDot() {
        XCTAssertEqual(
            ITNProcessor().process("version two point five"),
            "version 2.5"
        )
    }

    func testDecimalPointWithDigits() {
        XCTAssertEqual(
            ITNProcessor().process("3 point 14"),
            "3.14"
        )
    }

    func testDecimalPointInSentence() {
        XCTAssertEqual(
            ITNProcessor().process("it scored eight point five out of ten"),
            "it scored 8.5 out of 10"
        )
    }

    func testMixedDigitWordDecimal() {
        // Whisper sometimes emits "3 point six" (digit + word) — NeMo produces "3 .6"
        XCTAssertEqual(
            ITNProcessor().process("3 point six"),
            "3.6"
        )
    }

    func testMixedDigitWordDecimalInSentence() {
        XCTAssertEqual(
            ITNProcessor().process("Quinn 3 point six"),
            "Quinn 3.6"
        )
    }

    // MARK: - Version letter-digit collapse

    func testVersionLetterDigitCollapse() {
        XCTAssertEqual(
            ITNProcessor().process("K 2 point 5"),
            "K2.5"
        )
    }

    func testVersionLetterDigitInSentence() {
        XCTAssertEqual(
            ITNProcessor().process("you can run Kimi K 2 point 5"),
            "you can run Kimi K2.5"
        )
    }

    func testVersionCollapseOnlyUppercase() {
        // Lowercase "k" should not collapse — avoids false positives
        let result = ITNProcessor().process("k 2.5")
        XCTAssertEqual(result, "k 2.5")
    }

    // MARK: - Dimension normalization

    func testDimensionByBecomesMultiplySign() {
        XCTAssertEqual(
            ITNProcessor().process("4 m by 2 m"),
            "4 m × 2 m"
        )
    }

    func testDimensionByWithFullUnits() {
        XCTAssertEqual(
            ITNProcessor().process("10 feet by 12 feet"),
            "10 feet × 12 feet"
        )
    }

    func testDimensionBySecondUnitOptional() {
        XCTAssertEqual(
            ITNProcessor().process("4 m by 2"),
            "4 m × 2"
        )
    }

    // MARK: - Number connector protection

    func testNumberConnectorAnd() {
        XCTAssertEqual(
            ITNProcessor().process("ten and fifteen"),
            "10 and 15"
        )
    }

    func testNumberConnectorAndInSentence() {
        XCTAssertEqual(
            ITNProcessor().process("I have ten and fifteen items"),
            "I have 10 and 15 items"
        )
    }

    func testDigitNumberConnectorAndInSentence() {
        XCTAssertEqual(
            ITNProcessor().process("I am saying 50 and 120 people"),
            "I am saying 50 and 120 people"
        )
    }

    func testNumberConnectorBetweenAndY() {
        XCTAssertEqual(
            ITNProcessor().process("between ten and fifteen"),
            "between 10 and 15"
        )
    }

    func testNumberConnectorTo() {
        XCTAssertEqual(
            ITNProcessor().process("ten to fifteen minutes"),
            "10 to 15 minutes"
        )
    }

    func testSpokenRangeDoesNotBecomeTime() {
        XCTAssertEqual(
            ITNProcessor().process("I'm looking at forty to one twenty people"),
            "I'm looking at 40 to 120 people"
        )
    }

    func testMixedDigitRangeDoesNotBecomeTime() {
        XCTAssertEqual(
            ITNProcessor().process("I'm looking at forty to 120 people"),
            "I'm looking at 40 to 120 people"
        )
    }

    // MARK: - Regressions: existing behavior preserved

    func testCardinalTwentyOneStillWorks() {
        XCTAssertEqual(
            ITNProcessor().process("I have twenty one apples"),
            "I have 21 apples"
        )
    }

    func testFiveHundredStillWorks() {
        XCTAssertEqual(
            ITNProcessor().process("five hundred"),
            "500"
        )
    }

    func testYearTwentyTwentyFiveStillWorks() {
        XCTAssertEqual(
            ITNProcessor().process("twenty twenty five"),
            "2025"
        )
    }

    // MARK: - Year pattern protection

    func testYearTwentyTwentySix() {
        XCTAssertEqual(
            ITNProcessor().process("twenty twenty six"),
            "2026"
        )
    }

    func testYearTwentyTwentySixInSentence() {
        XCTAssertEqual(
            ITNProcessor().process("it is twenty twenty six already"),
            "it is 2026 already"
        )
    }

    func testYearNineteenNinetyNine() {
        XCTAssertEqual(
            ITNProcessor().process("nineteen ninety nine"),
            "1999"
        )
    }

    func testYearTwentyTwenty() {
        XCTAssertEqual(
            ITNProcessor().process("back in twenty twenty"),
            "back in 2020"
        )
    }

    func testYearTwentyTwentyThreeHyphenated() {
        XCTAssertEqual(
            ITNProcessor().process("twenty twenty-three"),
            "2023"
        )
    }

    func testYearTwentyTwentyThreeHyphenatedInSentence() {
        XCTAssertEqual(
            ITNProcessor().process("we shipped it in twenty twenty-three"),
            "we shipped it in 2023"
        )
    }

    func testYearTwentyFifteen() {
        XCTAssertEqual(
            ITNProcessor().process("since twenty fifteen"),
            "since 2015"
        )
    }

    func testYearTwentyOhFive() {
        XCTAssertEqual(
            ITNProcessor().process("twenty oh five"),
            "2005"
        )
    }

    func testYearNineteenEightyNine() {
        XCTAssertEqual(
            ITNProcessor().process("nineteen eighty nine"),
            "1989"
        )
    }

    func testYearTwentyThirty() {
        XCTAssertEqual(
            ITNProcessor().process("by twenty thirty"),
            "by 2030"
        )
    }

    // MARK: - Pairwise four-digit numbers

    func testPairwiseFourDigitNumbers() {
        let processor = ITNProcessor()
        let cases: [(String, String)] = [
            ("twenty six seventy seven", "2677"),
            ("the address is forty five sixty seven", "the address is 4567"),
            ("it happened in seventeen seventy six", "it happened in 1776"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(
                processor.process(input),
                expected,
                "\"\(input)\" should normalize to \"\(expected)\""
            )
        }
    }

    func testPairwiseNumberDefersToAmountContext() {
        // A payment verb marks "twenty six fifty" as money, not the number 2650.
        let result = ITNProcessor().process("I paid twenty six fifty for it")
        XCTAssertFalse(result.contains("2650"), result)
    }

    func testYearPatternDoesNotFireBeforeHundred() {
        // "twenty oh six hundred" should NOT become "2006 hundred"
        let result = ITNProcessor().process("twenty oh six hundred")
        XCTAssertFalse(result == "2006 hundred", "Year pattern must not consume 'twenty oh six' when 'hundred' follows")
    }

    func testYearPatternDoesNotFireBeforeThousand() {
        let result = ITNProcessor().process("twenty oh six thousand")
        XCTAssertFalse(result.contains("2006"), "Year pattern must not consume 'twenty oh six' when 'thousand' follows")
    }

    func testTwentyFourSevenAvailabilityPhraseUsesSlash() {
        XCTAssertEqual(
            ITNProcessor().process("twenty four seven ambient audio center"),
            "24/7 ambient audio center"
        )
    }

    func testSpokenDigitSequenceStillWorks() {
        XCTAssertEqual(
            ITNProcessor().process("one two three"),
            "123"
        )
    }

    func testPhoneFormattingStillWorks() {
        XCTAssertEqual(
            ITNProcessor().process("call one two three one two three five six seven eight"),
            "call 123-123-5678"
        )
    }

    func testSmartBulletDoesNotConsumeSpokenPhrases() {
        // "bullet point" in content should be preserved, not consumed as a command
        let result = TextFormatter.finalize(
            "add a bullet point system to the app",
            bulletPointsEnabled: true
        )
        XCTAssertTrue(result.contains("bullet point"))
    }

    func testOrdinalWordsPreservedInProse() {
        let processor = ITNProcessor()
        XCTAssertTrue(
            processor.process("privacy first products").contains("first"),
            "'first' as adjective modifier should not become '1st'"
        )
        XCTAssertTrue(
            processor.process("the first thing I noticed").contains("first"),
            "'first' in prose should stay as 'first'"
        )
    }

    func testOrdinalWordsConvertInDateContext() {
        let processor = ITNProcessor()
        let result = processor.process("schedule it for january fifth 2025")
        XCTAssertFalse(result.contains("fifth"), "Ordinal after month name should be converted to numeric")
    }

    func testOrdinalAdjectiveModifiersAreNotTreatedAsList() {
        // "privacy first" and "voice first" are adjective modifiers, not list ordinals.
        // Must NOT be reformatted as bullet points — that silently drops the preamble.
        let input = "please help me connect with people who are into building with AI, local language models, privacy first products, voice first execution, and self-reflection"
        let result = TextFormatter.finalize(input, bulletPointsEnabled: true)
        XCTAssertTrue(result.contains("privacy first"), "Adjective-modifier ordinals should be preserved as prose")
        XCTAssertFalse(result.hasPrefix("- "), "Should not be formatted as a bullet list")
        XCTAssertTrue(result.contains("please help me connect") || result.contains("Please help me connect"),
                       "Preamble text must not be silently dropped")
    }

    func testRepeatedOrdinalsAreNotTreatedAsList() {
        // Two "first"s is not a sequence — it's adjective usage.
        let result = TextFormatter.finalize(
            "first class service and first rate quality",
            bulletPointsEnabled: true
        )
        XCTAssertFalse(result.hasPrefix("- "), "Repeated ordinals should not trigger bullet formatting")
        XCTAssertFalse(result.hasPrefix("1."), "Repeated ordinals should not trigger numbered formatting")
    }

    func testOrdinalListWithDistinctOrdinalsStillWorks() {
        // Genuine ordinal sequences should still be formatted as numbered lists.
        XCTAssertEqual(
            TextFormatter.finalize(
                "first buy milk second call john",
                bulletPointsEnabled: true
            ),
            "1. Buy milk\n2. Call john"
        )
    }

    func testOrdinalListPreservesPreamble() {
        // Short intro text before ordinals should be preserved, not dropped.
        XCTAssertEqual(
            TextFormatter.finalize(
                "OK so 1st is the handoff 2nd is screenshot 3rd is hardware check",
                bulletPointsEnabled: true
            ),
            "OK so\n1. Is the handoff\n2. Is screenshot\n3. Is hardware check"
        )
    }

    func testNumberPrefixListPreservesPreamble() {
        XCTAssertEqual(
            TextFormatter.finalize(
                "there are number one buy milk number two call john",
                bulletPointsEnabled: true
            ),
            "There are\n1. Buy milk\n2. Call john"
        )
    }
}
