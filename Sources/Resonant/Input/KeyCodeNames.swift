import Carbon.HIToolbox

enum KeyCodeNames {

    // MARK: - Display names

    static func name(for keyCode: UInt16) -> String {
        if let known = modifierNames[keyCode] ?? commonNames[keyCode] {
            return known
        }
        if let translated = translateKeyCode(keyCode) {
            return translated.uppercased()
        }
        return "Key \(keyCode)"
    }

    static func shortName(for keyCode: UInt16) -> String {
        if let short = modifierShortNames[keyCode] {
            return short
        }
        return name(for: keyCode)
    }

    // MARK: - Modifier detection

    static func isModifierKey(_ keyCode: UInt16) -> Bool {
        modifierNames[keyCode] != nil
    }

    static func isFunctionKey(_ keyCode: UInt16) -> Bool {
        functionKeyCodes.contains(keyCode)
    }

    // MARK: - Lookups

    private static let modifierNames: [UInt16: String] = [
        54: "Right Command",
        55: "Left Command",
        56: "Left Shift",
        57: "Caps Lock",
        58: "Left Option",
        59: "Left Control",
        60: "Right Shift",
        61: "Right Option",
        62: "Right Control",
        63: "FN / Globe",
    ]

    private static let modifierShortNames: [UInt16: String] = [
        54: "Right Cmd",
        55: "Left Cmd",
        56: "Left Shift",
        57: "Caps Lock",
        58: "Left Opt",
        59: "Left Ctrl",
        60: "Right Shift",
        61: "Right Opt",
        62: "Right Ctrl",
        63: "FN",
    ]

    private static let functionNames: [UInt16: String] = [
        122: "F1",  120: "F2",  99: "F3",   118: "F4",
        96: "F5",   97: "F6",   98: "F7",   100: "F8",
        101: "F9",  109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16",
        64: "F17",  79: "F18",  80: "F19",  90: "F20",
    ]

    private static let functionKeyCodes = Set(functionNames.keys)

    private static let commonNames: [UInt16: String] = functionNames.merging([
        // Special keys
        36: "Return",
        48: "Tab",
        49: "Space",
        51: "Delete",
        53: "Escape",
        76: "Enter",
        115: "Home",
        116: "Page Up",
        117: "Forward Delete",
        119: "End",
        121: "Page Down",
        123: "Left Arrow",
        124: "Right Arrow",
        125: "Down Arrow",
        126: "Up Arrow",

        // Keypad
        65: "Keypad .",
        67: "Keypad *",
        69: "Keypad +",
        71: "Keypad Clear",
        75: "Keypad /",
        78: "Keypad -",
        81: "Keypad =",
        82: "Keypad 0",
        83: "Keypad 1",
        84: "Keypad 2",
        85: "Keypad 3",
        86: "Keypad 4",
        87: "Keypad 5",
        88: "Keypad 6",
        89: "Keypad 7",
        91: "Keypad 8",
        92: "Keypad 9",
    ], uniquingKeysWith: { current, _ in current })

    // MARK: - UCKeyTranslate fallback

    private static func translateKeyCode(_ keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
                ?? TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutDataRef = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }

        let layoutData = unsafeBitCast(layoutDataRef, to: CFData.self)
        guard CFDataGetLength(layoutData) > 0,
              let layoutBytes = CFDataGetBytePtr(layoutData) else {
            return nil
        }

        let layoutPtr = UnsafeRawPointer(layoutBytes).assumingMemoryBound(to: UCKeyboardLayout.self)

        var deadKeyState: UInt32 = 0
        var length: Int = 0
        var chars = [UniChar](repeating: 0, count: 4)

        let status = UCKeyTranslate(
            layoutPtr,
            keyCode,
            UInt16(kUCKeyActionDisplay),
            0,
            UInt32(LMGetKbdType()),
            UInt32(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            chars.count,
            &length,
            &chars
        )

        guard status == noErr, length > 0 else { return nil }
        let result = String(utf16CodeUnits: chars, count: length)
            .trimmingCharacters(in: .controlCharacters)
        return result.isEmpty ? nil : result
    }
}
