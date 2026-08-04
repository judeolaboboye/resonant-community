import Foundation

struct HotkeyDiagnostics: Sendable {
    let fnUsageType: Int?
    let macOSMajorVersion: Int

    var fnSystemAction: String? {
        switch fnUsageType {
        case 1:
            return "Change Input Source"
        case 2:
            return "Show Emoji & Symbols"
        case 3:
            return "Start Dictation"
        default:
            return nil
        }
    }

    var fnFallbackReason: String? {
        if let fnSystemAction {
            return "macOS uses FN for \(fnSystemAction)."
        }

        if macOSMajorVersion >= 15 {
            return "FN / Globe is unreliable on macOS \(macOSMajorVersion)."
        }

        return nil
    }

    var fnMayBeCaptured: Bool {
        fnSystemAction == nil
    }

    static func current(
        userDefaults: UserDefaults = .standard,
        processInfo: ProcessInfo = .processInfo
    ) -> HotkeyDiagnostics {
        let rawValue = userDefaults.persistentDomain(forName: "com.apple.HIToolbox")?["AppleFnUsageType"]
        let fnUsageType: Int?

        switch rawValue {
        case let value as Int:
            fnUsageType = value
        case let value as NSNumber:
            fnUsageType = value.intValue
        case let value as String:
            fnUsageType = Int(value)
        default:
            fnUsageType = nil
        }

        return HotkeyDiagnostics(
            fnUsageType: fnUsageType,
            macOSMajorVersion: processInfo.operatingSystemVersion.majorVersion
        )
    }
}
