import Foundation

/// Formatting defaults inferred from the target surface — no learning lag,
/// no spoken commands. A subject line shouldn't end with a period the first
/// time, not after three corrections.
struct SurfaceFormattingDefaults: Sendable, Equatable {
    /// Single-line target: structural breaks become "; " and lists flatten.
    var flattenLineBreaks = false
    /// Subject lines, titles, search queries don't take trailing periods.
    var suppressTrailingPunctuation = false
    /// Chat norm: short messages don't get a period appended.
    var chatShortMessageDefaults = false

    /// Typed adapter used by the learned-policy precedence matrix.
    var trailingPeriodPolicy: TrailingPeriodPolicy {
        suppressTrailingPunctuation ? .omit : .inherit
    }

    static let neutral = SurfaceFormattingDefaults()

    private static let singleLineFieldKinds: Set<FieldKind> = [
        .search, .title, .subject, .address,
    ]

    /// AX roles that render a single line regardless of field kind.
    private static let singleLineRoles: Set<String> = [
        "AXTextField", "AXSearchField", "AXComboBox",
    ]

    static func infer(from packet: ContextPacket?) -> SurfaceFormattingDefaults {
        guard let packet else { return .neutral }
        var defaults = SurfaceFormattingDefaults()

        if singleLineFieldKinds.contains(packet.surface.fieldKind) {
            defaults.flattenLineBreaks = true
            defaults.suppressTrailingPunctuation = true
        }
        if let role = packet.targetFingerprint?.role, singleLineRoles.contains(role) {
            defaults.flattenLineBreaks = true
        }
        if packet.surface.kind == .chat {
            defaults.chatShortMessageDefaults = true
        }

        return defaults
    }
}
