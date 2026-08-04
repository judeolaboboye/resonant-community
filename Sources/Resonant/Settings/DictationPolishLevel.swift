import Foundation

/// How much latitude the cleanup pass gets on a surface category.
/// - `verbatim`: local deterministic pipeline only — no cloud rewrite at all.
/// - `clean`: today's behavior — fix errors, never rephrase.
/// - `polished`: the model may tighten wording and split run-ons so the text
///   reads as written rather than transcribed; the output sanitizer widens its
///   length/novelty gates to match.
enum DictationPolishLevel: String, Codable, CaseIterable, Sendable {
    case verbatim
    case clean
    case polished

    var displayName: String {
        switch self {
        case .verbatim: "Verbatim"
        case .clean: "Clean"
        case .polished: "Polished"
        }
    }

    var displayDetail: String {
        switch self {
        case .verbatim: "Exactly what you said — no cloud cleanup"
        case .clean: "Fix mistakes, keep your wording"
        case .polished: "Rewrite lightly so it reads as written"
        }
    }
}

/// Per-surface-category polish levels, mirroring the cleanup prompt profiles.
struct DictationPolishSettings: Sendable, Equatable {
    var chat: DictationPolishLevel = .clean
    var email: DictationPolishLevel = .clean
    var other: DictationPolishLevel = .clean

    static let standard = DictationPolishSettings()

    func level(for profile: CloudProcessingSupport.CleanupPromptProfile) -> DictationPolishLevel {
        switch profile {
        case .message: chat
        case .emailFull, .emailFragment: email
        case .default: other
        }
    }

    /// True when no surface category can reach cloud cleanup. Settings can read
    /// this without a transcript; a single verbatim category cannot be resolved
    /// until the dictation picks its profile.
    var isVerbatimEverywhere: Bool {
        chat == .verbatim && email == .verbatim && other == .verbatim
    }
}
