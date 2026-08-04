import Foundation

/// Infers high-confidence English questions from sentence shape.
///
/// Rendering and style learning share this classifier, but remain separate
/// actions: ambiguous text is left untouched and is not treated as evidence
/// for a trailing-period preference.
enum QuestionInference {
    private struct Token {
        let value: String
        let beginsWithUppercase: Bool
    }

    private static let whOpeners: Set<String> = [
        "what", "where", "when", "why", "who", "whom", "whose", "which", "how",
    ]
    private static let whSubjectOpeners: Set<String> = ["what", "who", "which"]
    private static let whSubjectPredicates: Set<String> = [
        "arrived", "broke", "called", "changed", "failed", "happened",
        "joined", "left", "lost", "started", "stopped", "won",
    ]
    private static let whNounHeadOpeners: Set<String> = ["what", "which", "whose"]
    private static let whNounHeads: Set<String> = [
        "build", "color", "date", "day", "file", "kind", "name", "option",
        "result", "team", "time", "turn", "type", "version",
    ]
    private static let howModifiers: Set<String> = [
        "far", "long", "many", "much", "often", "old", "soon",
    ]

    private static let subjectPronouns: Set<String> = [
        "i", "you", "we", "they", "he", "she", "it",
    ]
    private static let subjectStarters: Set<String> = subjectPronouns.union([
        "the", "this", "that", "these", "those",
        "anyone", "anybody", "everyone", "everybody",
        "someone", "somebody", "nobody", "nothing", "something",
        "there", "each", "either", "neither", "all", "both", "some", "any",
        "my", "your", "his", "her", "its", "our", "their",
    ])

    private static let copulaAuxiliaries: Set<String> = ["is", "are", "was", "were", "am"]
    private static let directAuxiliaries: Set<String> = copulaAuxiliaries.union([
        "can", "could", "will", "would", "shall", "should", "might", "must",
    ])
    private static let doAuxiliaries: Set<String> = ["do", "does", "did"]
    private static let haveAuxiliaries: Set<String> = ["have", "has", "had"]
    private static let negativeDoAuxiliaries: Set<String> = [
        "don't", "doesn't", "didn't",
    ]
    private static let otherNegativeAuxiliaries: Set<String> = [
        "isn't", "aren't", "wasn't", "weren't",
        "can't", "couldn't", "won't", "wouldn't", "shouldn't",
        "haven't", "hasn't",
    ]
    private static let whAuxiliaries = directAuxiliaries
        .union(doAuxiliaries)
        .union(haveAuxiliaries)
        .union(negativeDoAuxiliaries)
        .union(otherNegativeAuxiliaries)
        .union(["may"])

    /// A later finite predicate is evidence that the wh-clause is the subject
    /// of a statement: "what matters is..." / "who gets access depends...".
    private static let embeddedMainPredicates: Set<String> = [
        "is", "are", "was", "were",
        "depend", "depends", "determine", "determines",
        "deserve", "deserves", "get", "gets", "help", "helps",
        "matter", "matters", "mean", "means",
        "qualify", "qualifies",
        "change", "changes", "receive", "receives",
        "remain", "remains", "vary", "varies",
        "win", "wins",
    ]

    private static let tagEndings: Set<String> = ["right", "correct", "okay", "ok", "yeah"]

    /// Continuations after "May I"/"May we" that are never a bare infinitive,
    /// so the sentence cannot be a permission question. These arise when a
    /// contact name ("Mei, I need…") is transcribed as the auxiliary "May".
    private static let mayPermissionImpossibleContinuations: Set<String> = [
        "need", "needed", "want", "wanted",
        "am", "was", "were", "will", "would",
        "can", "could", "should", "might", "must",
        "just", "also", "already", "actually", "never",
        "don't", "didn't", "won't", "can't", "couldn't", "wouldn't",
        "said", "told", "thought", "knew", "figured", "guessed",
    ]

    /// Periods after these tokens are nonterminal when more text follows.
    /// Foundation's `.bySentences` also splits "Dr. Smith", so the local
    /// scanner keeps this deliberately small and explicit.
    private static let titleAbbreviations: Set<String> = [
        "dr", "jr", "mr", "mrs", "ms", "prof", "sr", "st",
    ]
    private static let continuationAbbreviations: Set<String> = [
        "co", "dept", "e.g", "etc", "fig", "i.e", "inc", "ltd", "vs",
    ]

    /// Rewrites only a single ordinary sentence-final period. When the caller
    /// intentionally left punctuation unterminated, it may append `?` to a
    /// high-confidence final question.
    static func apply(to text: String, appendWhenUnterminated: Bool = false) -> String {
        var result = text

        for range in semanticSentenceRanges(in: text).reversed() {
            let sentence = String(result[range])
            let periodIndex = result.index(before: range.upperBound)
            guard sentence.hasSuffix("."),
                  !sentence.hasSuffix(".."),
                  isQuestion(sentence)
            else { continue }

            if isProtectedAbbreviationPeriod(at: periodIndex, in: result) {
                // The period belongs to the abbreviation, not the sentence.
                // Preserve it and add the inferred terminal mark separately:
                // "Are you in the U.S.?"
                result.insert("?", at: range.upperBound)
            } else {
                result.replaceSubrange(periodIndex..<range.upperBound, with: "?")
            }
        }

        if appendWhenUnterminated,
           let last = result.last,
           last.isLetter || last.isNumber,
           let finalSentence = finalSemanticSentence(in: result),
           isQuestion(finalSentence) {
            result += "?"
        }

        return result
    }

    /// The final semantic sentence/clause owns a trailing-period opportunity.
    /// Semicolons are included because line flattening uses `"; "` to retain a
    /// hard line boundary after question inference has already run.
    static func finalSemanticSentence(in text: String) -> String? {
        semanticSentenceRanges(in: text).last.map { String(text[$0]) }
    }

    static func isQuestion(_ sentence: String) -> Bool {
        let body = sentenceBody(sentence)
        let tokens = questionTokens(in: body)
        guard let first = tokens.first?.value else { return false }

        if isTagQuestion(body, tokens: tokens) {
            return true
        }
        if whOpeners.contains(first) {
            return isWhQuestion(tokens)
        }
        return isAuxiliaryQuestion(tokens)
    }

    private static func isAuxiliaryQuestion(_ tokens: [Token]) -> Bool {
        guard tokens.count >= 2 else { return false }
        let first = tokens[0].value
        let second = tokens[1]

        if first == "may" {
            guard second.value == "i" || second.value == "we" else { return false }
            // "Mei, I need to follow up" transcribes as "May I need to follow
            // up" — a finite or stative continuation cannot be the bare
            // infinitive a permission question requires, so treat it as
            // homophone fallout, not a question. Verbs that are valid both
            // ways ("think", "have") stay question-eligible; fail open.
            if tokens.count >= 3, mayPermissionImpossibleContinuations.contains(tokens[2].value) {
                return false
            }
            return true
        }
        if negativeDoAuxiliaries.contains(first) {
            // "Don't you forget..." is commonly an emphatic imperative.
            // Past- and third-person forms with a subject plus predicate are
            // substantially clearer inversions.
            guard first != "don't", tokens.count >= 3 else { return false }
            return hasSubjectEvidence(
                second,
                tokenCount: tokens.count,
                auxiliary: first
            )
        }
        if doAuxiliaries.contains(first) {
            // "Do it now" is imperative; unlike the other personal pronouns,
            // `it` is not positive subject evidence after bare `do`.
            guard second.value != "it" else { return false }
            return hasSubjectEvidence(second, tokenCount: tokens.count, auxiliary: first)
        }
        if haveAuxiliaries.contains(first) {
            if first == "has" {
                guard tokens.count >= 3 else { return false }
                return hasSubjectEvidence(
                    second,
                    tokenCount: tokens.count,
                    auxiliary: first
                )
            }
            // Keeps "Have you tried..." while rejecting possessive/narrative
            // fragments such as "Had the meeting earlier."
            return subjectPronouns.subtracting(["it"]).contains(second.value)
        }
        if otherNegativeAuxiliaries.contains(first) {
            return hasSubjectEvidence(second, tokenCount: tokens.count, auxiliary: first)
        }
        if directAuxiliaries.contains(first) {
            return hasSubjectEvidence(second, tokenCount: tokens.count, auxiliary: first)
        }
        return false
    }

    private static func isWhQuestion(_ tokens: [Token]) -> Bool {
        guard tokens.count >= 2 else { return false }
        let first = tokens[0].value
        let second = tokens[1].value

        // Direct wh-object/adverb inversion: "How are you", "Where did it go".
        if whAuxiliaries.contains(second) {
            guard tokens.count >= 3 else { return false }
            if ["how", "when", "where", "why"].contains(first) {
                let auxiliary = second
                let minimumCount = copulaAuxiliaries.contains(auxiliary) ? 3 : 4
                guard tokens.count >= minimumCount,
                      hasSubjectEvidence(
                        tokens[2],
                        tokenCount: tokens.count,
                        auxiliary: auxiliary
                      )
                else { return false }
            } else if whSubjectOpeners.contains(first),
                      !hasSubjectEvidence(
                        tokens[2],
                        tokenCount: tokens.count,
                        auxiliary: second
                      ),
                      hasPlausibleEmbeddedMatrixPredicate(
                        in: tokens,
                        startingAt: 3
                      ) {
                // "Who can attend gets priority" has the same prefix as a
                // direct wh-subject question. A later finite-looking predicate
                // makes it an embedded subject clause, so fail closed.
                return false
            }
            return !hasEmbeddedMainPredicate(in: tokens, startingAt: 3)
        }

        // Noun-headed wh inversion: "What time is it", "Which build did fail".
        if whNounHeadOpeners.contains(first),
           tokens.count >= 4,
           whNounHeads.contains(second),
           whAuxiliaries.contains(tokens[2].value) {
            return !hasEmbeddedMainPredicate(in: tokens, startingAt: 4)
        }

        // Quantified how-questions: "How long will it take" /
        // "How many users are affected".
        if first == "how", howModifiers.contains(second) {
            if tokens.count >= 4,
               whAuxiliaries.contains(tokens[2].value),
               hasSubjectEvidence(
                    tokens[3],
                    tokenCount: tokens.count,
                    auxiliary: tokens[2].value
               ) {
                return !hasEmbeddedMainPredicate(in: tokens, startingAt: 4)
            }
            if tokens.count >= 5, whAuxiliaries.contains(tokens[3].value) {
                return !hasEmbeddedMainPredicate(in: tokens, startingAt: 5)
            }
        }

        // Wh-subject questions do not invert: "Who broke the build", "What
        // happened", "Which failed". A later matrix predicate or an explicit
        // clause subject makes the shape an embedded declarative clause.
        if whSubjectOpeners.contains(first) {
            guard !subjectStarters.contains(second),
                  whSubjectPredicates.contains(second),
                  !hasEmbeddedMainPredicate(in: tokens, startingAt: 2)
            else { return false }
            return true
        }

        return false
    }

    private static func hasEmbeddedMainPredicate(
        in tokens: [Token],
        startingAt index: Int
    ) -> Bool {
        guard index < tokens.count else { return false }
        return tokens[index...].contains {
            embeddedMainPredicates.contains($0.value) || whAuxiliaries.contains($0.value)
        }
    }

    private static func hasPlausibleEmbeddedMatrixPredicate(
        in tokens: [Token],
        startingAt index: Int
    ) -> Bool {
        guard index < tokens.count else { return false }

        for candidateIndex in index..<tokens.count {
            let value = tokens[candidateIndex].value
            if embeddedMainPredicates.contains(value)
                || whAuxiliaries.contains(value) {
                return true
            }

            // Without a parser, an inflected verb followed by predicate
            // material is enough ambiguity to suppress inference.
            // This intentionally favors preserving a possible statement.
            guard candidateIndex + 1 < tokens.count else { continue }
            if value.count >= 3,
               value.hasSuffix("s") || value.hasSuffix("ed") {
                return true
            }
        }
        return false
    }

    private static func hasSubjectEvidence(
        _ token: Token,
        tokenCount: Int,
        auxiliary: String
    ) -> Bool {
        if subjectStarters.contains(token.value) {
            return true
        }
        guard tokenCount >= 3, token.beginsWithUppercase else { return false }

        // "Will Smith..." is lexically ambiguous between inversion and a
        // person's name, so preserve it rather than manufacturing a question.
        return auxiliary != "will" && auxiliary != "would"
    }

    private static func isTagQuestion(_ body: String, tokens: [Token]) -> Bool {
        guard let last = tokens.last?.value,
              tagEndings.contains(last),
              tokens.count >= 2 else {
            return false
        }
        return body.range(
            of: #",\s*\#(last)\s*$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func sentenceBody(_ sentence: String) -> String {
        var body = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = body.last, ".!?".contains(last) {
            body.removeLast()
            body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return body
    }

    private static func questionTokens(in sentence: String) -> [Token] {
        sentence.split(whereSeparator: \.isWhitespace).compactMap { rawWord in
            let trimmed = rawWord.trimmingCharacters(
                in: CharacterSet.alphanumerics
                    .union(CharacterSet(charactersIn: "'’"))
                    .inverted
            )
            guard !trimmed.isEmpty else { return nil }
            let canonical = trimmed.replacingOccurrences(of: "’", with: "'")
            return Token(
                value: canonical.lowercased(),
                beginsWithUppercase: canonical.first?.isUppercase == true
            )
        }
    }

    private static func semanticSentenceRanges(in text: String) -> [Range<String.Index>] {
        guard !text.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var segmentStart: String.Index?
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)

            if segmentStart == nil, !character.isWhitespace, character != ";" {
                segmentStart = index
            }

            if character == "\n"
                || character == ";"
                || (character == ":" && isTerminalBoundary(after: next, in: text)) {
                appendTrimmedRange(
                    from: segmentStart,
                    to: index,
                    in: text,
                    ranges: &ranges
                )
                segmentStart = nil
            } else if character == "…",
                      isTerminalBoundary(after: next, in: text) {
                appendTrimmedRange(
                    from: segmentStart,
                    to: next,
                    in: text,
                    ranges: &ranges
                )
                segmentStart = nil
            } else if ".!?".contains(character),
                      isTerminalBoundary(after: next, in: text),
                      !(character == "." && isNonterminalPeriod(at: index, in: text)) {
                appendTrimmedRange(
                    from: segmentStart,
                    to: next,
                    in: text,
                    ranges: &ranges
                )
                segmentStart = nil
            }

            index = next
        }

        appendTrimmedRange(
            from: segmentStart,
            to: text.endIndex,
            in: text,
            ranges: &ranges
        )
        return ranges
    }

    private static func appendTrimmedRange(
        from start: String.Index?,
        to end: String.Index,
        in text: String,
        ranges: inout [Range<String.Index>]
    ) {
        guard var lower = start, lower < end else { return }
        var upper = end
        while lower < upper, text[lower].isWhitespace {
            lower = text.index(after: lower)
        }
        while lower < upper {
            let previous = text.index(before: upper)
            guard text[previous].isWhitespace else { break }
            upper = previous
        }
        guard lower < upper else { return }
        ranges.append(lower..<upper)
    }

    private static func isTerminalBoundary(
        after index: String.Index,
        in text: String
    ) -> Bool {
        index == text.endIndex || text[index].isWhitespace || text[index] == ";"
    }

    private static func isNonterminalPeriod(
        at index: String.Index,
        in text: String
    ) -> Bool {
        let next = text.index(after: index)
        guard next < text.endIndex else { return false }

        if index > text.startIndex {
            let previous = text.index(before: index)
            if text[previous].isNumber, text[next].isNumber {
                return true
            }
        }

        guard let following = text[next...].firstIndex(where: { !$0.isWhitespace }) else {
            return false
        }
        let token = tokenBeforePeriod(at: index, in: text)
        let normalized = token.lowercased()
        let followingTextBeginsQuestion = isQuestion(String(text[following...]))

        if titleAbbreviations.contains(normalized) {
            return !followingTextBeginsQuestion
        }
        if normalized == "no" {
            return text[following].isNumber
        }
        if continuationAbbreviations.contains(normalized) {
            return !followingTextBeginsQuestion && !text[following].isUppercase
        }
        if token.count == 1,
           token.first?.isLetter == true,
           text[following].isUppercase {
            return !followingTextBeginsQuestion
        }

        let initialismParts = token.split(separator: ".", omittingEmptySubsequences: true)
        guard initialismParts.count >= 2,
              initialismParts.allSatisfy({
                $0.count == 1 && $0.first?.isLetter == true
              }) else {
            return false
        }
        return !followingTextBeginsQuestion
    }

    private static func isProtectedAbbreviationPeriod(
        at index: String.Index,
        in text: String
    ) -> Bool {
        let token = tokenBeforePeriod(at: index, in: text)
        let normalized = token.lowercased()
        if titleAbbreviations.contains(normalized)
            || continuationAbbreviations.contains(normalized) {
            return true
        }
        let initialismParts = token.split(separator: ".", omittingEmptySubsequences: true)
        return initialismParts.count >= 2
            && initialismParts.allSatisfy { $0.count == 1 && $0.first?.isLetter == true }
    }

    private static func tokenBeforePeriod(
        at index: String.Index,
        in text: String
    ) -> String {
        var start = index
        while start > text.startIndex {
            let previous = text.index(before: start)
            let character = text[previous]
            guard character.isLetter || character == "." else { break }
            start = previous
        }
        return String(text[start..<index])
    }
}
