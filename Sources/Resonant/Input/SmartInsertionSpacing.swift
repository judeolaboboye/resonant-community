import Foundation

/// Pure text adjustment policy for consecutive dictation insertions.
///
/// The policy intentionally only trusts surrounding cursor text for spacing and
/// lowercasing when it can be tied to the previous delivery target. This keeps
/// AX readback quirks in rich text editors from changing unrelated text.
struct SmartInsertionSpacing {
    struct Target: Equatable, Hashable {
        private let bundleID: String
        private let windowTitle: String
        private let browserURL: String

        init(bundleID: String?, windowTitle: String?, browserURL: String?) {
            self.bundleID = bundleID ?? ""
            self.windowTitle = windowTitle ?? ""
            self.browserURL = browserURL ?? ""
        }
    }

    struct LastDelivery: Equatable {
        let deliveredText: String
        let target: Target
    }

    struct CursorContext: Equatable {
        let textBeforeCursor: String?
        let continuesFromLastDelivery: Bool

        init(textBeforeCursor: String?, continuesFromLastDelivery: Bool) {
            self.textBeforeCursor = textBeforeCursor
            self.continuesFromLastDelivery = continuesFromLastDelivery
        }
    }

    static func cursorContext(
        textBeforeCursor: String?,
        lastDelivery: LastDelivery?,
        target: Target
    ) -> CursorContext {
        CursorContext(
            textBeforeCursor: textBeforeCursor,
            continuesFromLastDelivery: continuesFromLastDelivery(
                textBeforeCursor: textBeforeCursor,
                lastDelivery: lastDelivery,
                target: target
            )
        )
    }

    static func continuesFromLastDelivery(
        textBeforeCursor: String?,
        lastDelivery: LastDelivery?,
        target: Target
    ) -> Bool {
        guard let textBeforeCursor,
              let lastDelivery,
              lastDelivery.target == target,
              !lastDelivery.deliveredText.isEmpty else {
            return false
        }

        return textBeforeCursor.hasSuffix(lastDelivery.deliveredText)
    }

    static func adjustedText(
        _ text: String,
        context: CursorContext
    ) -> String {
        guard !text.isEmpty else { return text }

        let immediatePrecedingChar = immediateInsertionContextCharacter(in: context.textBeforeCursor)
        let sentenceContextChar = sentenceContextCharacter(in: context.textBeforeCursor)
        let hasAnyContext = immediatePrecedingChar != nil || sentenceContextChar != nil

        var result = text
        // Capitalize-at-field-start is safe even without continuation signal.
        if !hasAnyContext {
            result = adjustingFirstLetter(in: result, transform: { String($0).uppercased() })
            return result
        }

        guard context.continuesFromLastDelivery else {
            return result
        }

        if shouldCapitalizeLeadingLetter(after: sentenceContextChar) {
            result = adjustingFirstLetter(in: result, transform: { String($0).uppercased() })
        } else if shouldLowercaseLeadingLetter(after: sentenceContextChar) {
            result = adjustingFirstLetter(in: result, transform: { String($0).lowercased() })
        }

        if let immediatePrecedingChar,
           !immediatePrecedingChar.isWhitespace,
           !immediatePrecedingChar.isNewline {
            return " " + result
        }

        return result
    }

    private static func immediateInsertionContextCharacter(in textBeforeCursor: String?) -> Character? {
        guard let textBeforeCursor else { return nil }

        for character in textBeforeCursor.reversed() {
            if isInsertionContextIgnorable(character) {
                continue
            }
            return character
        }

        return nil
    }

    private static func sentenceContextCharacter(in textBeforeCursor: String?) -> Character? {
        guard let textBeforeCursor else { return nil }

        for character in textBeforeCursor.reversed() {
            if isInsertionContextIgnorable(character) {
                continue
            }
            if character.isNewline {
                return nil
            }
            if character.isWhitespace {
                continue
            }
            if isTrailingSentenceCloser(character) {
                continue
            }
            return character
        }

        return nil
    }

    private static func isInsertionContextIgnorable(_ character: Character) -> Bool {
        !character.isWhitespace
            && !character.isNewline
            && !character.unicodeScalars.isEmpty
            && character.unicodeScalars.allSatisfy(isInsertionContextIgnorableScalar(_:))
    }

    private static func isInsertionContextIgnorableScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00AD,
             0x061C,
             0x180E,
             0x200B...0x200F,
             0x202A...0x202E,
             0x2060...0x2064,
             0x2066...0x206F,
             0xFEFF:
            return true
        default:
            return false
        }
    }

    private static func shouldCapitalizeLeadingLetter(after sentenceContextChar: Character?) -> Bool {
        guard let sentenceContextChar else { return true }
        return isSentenceBoundary(sentenceContextChar)
    }

    private static func shouldLowercaseLeadingLetter(after sentenceContextChar: Character?) -> Bool {
        guard let sentenceContextChar else { return false }
        return ",;:".contains(sentenceContextChar)
    }

    private static func isSentenceBoundary(_ character: Character) -> Bool {
        ".!?…".contains(character)
    }

    private static func isTrailingSentenceCloser(_ character: Character) -> Bool {
        "\"'”’)]}".contains(character)
    }

    private static func adjustingFirstLetter(
        in text: String,
        transform: (Character) -> String
    ) -> String {
        guard let index = text.firstIndex(where: \.isLetter) else { return text }

        let letter = text[index]
        let replacement = transform(letter)
        guard replacement != String(letter) else { return text }

        var result = text
        result.replaceSubrange(index...index, with: replacement)
        return result
    }
}
