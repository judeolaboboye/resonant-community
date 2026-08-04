import CoreAudio
import Foundation

/// Transport type of an audio output device, used to warn the user about known-fragile
/// capture paths (Bluetooth) and to segment telemetry.
enum MeetingAudioTransport: String, Sendable {
    case builtIn
    case bluetooth
    case bluetoothLE
    case usb
    case hdmi
    case displayPort
    case airPlay
    case thunderbolt
    case aggregate
    case virtual
    case pci
    case fireWire
    case avb
    case continuityCapture
    case unknown

    /// Transports known to produce silent / fragile CoreAudio taps.
    /// Bluetooth outputs (especially HFP call mode) routinely return empty buffers.
    var shouldWarnBeforeMeeting: Bool {
        switch self {
        case .bluetooth, .bluetoothLE: return true
        default: return false
        }
    }

    var displayLabel: String {
        switch self {
        case .builtIn:
            return "System audio"
        case .bluetooth, .bluetoothLE:
            return "System audio - Bluetooth"
        case .usb:
            return "System audio - USB"
        case .hdmi:
            return "System audio - HDMI"
        case .displayPort:
            return "System audio - DisplayPort"
        case .airPlay:
            return "System audio - AirPlay"
        case .thunderbolt:
            return "System audio - Thunderbolt"
        case .aggregate:
            return "System audio - aggregate"
        case .virtual:
            return "System audio - virtual"
        case .pci:
            return "System audio - PCI"
        case .fireWire:
            return "System audio - FireWire"
        case .avb:
            return "System audio - AVB"
        case .continuityCapture:
            return "System audio - Continuity"
        case .unknown:
            return "System audio"
        }
    }

    init(rawValue4CC: UInt32) {
        switch rawValue4CC {
        case UInt32(kAudioDeviceTransportTypeBuiltIn):             self = .builtIn
        case UInt32(kAudioDeviceTransportTypeBluetooth):           self = .bluetooth
        case UInt32(kAudioDeviceTransportTypeBluetoothLE):         self = .bluetoothLE
        case UInt32(kAudioDeviceTransportTypeUSB):                 self = .usb
        case UInt32(kAudioDeviceTransportTypeHDMI):                self = .hdmi
        case UInt32(kAudioDeviceTransportTypeDisplayPort):         self = .displayPort
        case UInt32(kAudioDeviceTransportTypeAirPlay):             self = .airPlay
        case UInt32(kAudioDeviceTransportTypeThunderbolt):         self = .thunderbolt
        case UInt32(kAudioDeviceTransportTypeAggregate):           self = .aggregate
        case UInt32(kAudioDeviceTransportTypeVirtual):             self = .virtual
        case UInt32(kAudioDeviceTransportTypePCI):                 self = .pci
        case UInt32(kAudioDeviceTransportTypeFireWire):            self = .fireWire
        case UInt32(kAudioDeviceTransportTypeAVB):                 self = .avb
        case UInt32(kAudioDeviceTransportTypeContinuityCaptureWired): self = .continuityCapture
        case UInt32(kAudioDeviceTransportTypeContinuityCaptureWireless): self = .continuityCapture
        default:                                                   self = .unknown
        }
    }
}

/// Read-only helpers for querying the transport type and name of a CoreAudio output device.
enum MeetingAudioTransportInfo {

    /// Reads `kAudioDevicePropertyTransportType`. Returns `.unknown` on any CoreAudio error.
    static func transport(for deviceID: AudioDeviceID) -> MeetingAudioTransport {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID, &address, 0, nil, &dataSize, &transport
        )
        guard status == noErr else { return .unknown }
        return MeetingAudioTransport(rawValue4CC: transport)
    }

    /// Reads `kAudioObjectPropertyName`. Returns `nil` on any CoreAudio error.
    /// Used for logs only; never sent raw to telemetry.
    static func deviceName(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(
            deviceID, &address, 0, nil, &dataSize, &name
        )
        guard status == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }
}
