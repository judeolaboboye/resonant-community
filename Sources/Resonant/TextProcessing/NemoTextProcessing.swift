import Foundation
import CNemoTextProcessing

/// Swift bridge for the vendored `text-processing-rs` FFI.
enum NemoTextProcessing {

    static func normalize(_ input: String) -> String {
        guard let cString = input.cString(using: .utf8) else {
            return input
        }

        guard let resultPtr = nemo_normalize(cString) else {
            return input
        }

        defer { nemo_free_string(resultPtr) }
        return String(cString: resultPtr)
    }

    static func normalizeSentence(_ input: String) -> String {
        guard let cString = input.cString(using: .utf8) else {
            return input
        }

        guard let resultPtr = nemo_normalize_sentence(cString) else {
            return input
        }

        defer { nemo_free_string(resultPtr) }
        return String(cString: resultPtr)
    }

    static func normalizeSentence(_ input: String, maxSpanTokens: UInt32) -> String {
        guard let cString = input.cString(using: .utf8) else {
            return input
        }

        guard let resultPtr = nemo_normalize_sentence_with_max_span(cString, maxSpanTokens) else {
            return input
        }

        defer { nemo_free_string(resultPtr) }
        return String(cString: resultPtr)
    }

    static func tnNormalize(_ input: String) -> String {
        guard let cString = input.cString(using: .utf8) else {
            return input
        }

        guard let resultPtr = nemo_tn_normalize(cString) else {
            return input
        }

        defer { nemo_free_string(resultPtr) }
        return String(cString: resultPtr)
    }

    static func tnNormalizeSentence(_ input: String) -> String {
        guard let cString = input.cString(using: .utf8) else {
            return input
        }

        guard let resultPtr = nemo_tn_normalize_sentence(cString) else {
            return input
        }

        defer { nemo_free_string(resultPtr) }
        return String(cString: resultPtr)
    }

    static func tnNormalizeSentence(_ input: String, maxSpanTokens: UInt32) -> String {
        guard let cString = input.cString(using: .utf8) else {
            return input
        }

        guard let resultPtr = nemo_tn_normalize_sentence_with_max_span(cString, maxSpanTokens) else {
            return input
        }

        defer { nemo_free_string(resultPtr) }
        return String(cString: resultPtr)
    }

    static func addRule(spoken: String, written: String) {
        spoken.withCString { spokenPtr in
            written.withCString { writtenPtr in
                nemo_add_rule(spokenPtr, writtenPtr)
            }
        }
    }

    @discardableResult
    static func removeRule(spoken: String) -> Bool {
        spoken.withCString { spokenPtr in
            nemo_remove_rule(spokenPtr) != 0
        }
    }

    static func clearRules() {
        nemo_clear_rules()
    }

    static var ruleCount: Int {
        Int(nemo_rule_count())
    }

    static var version: String {
        guard let versionPtr = nemo_version() else {
            return "unknown"
        }

        return String(cString: versionPtr)
    }
}
