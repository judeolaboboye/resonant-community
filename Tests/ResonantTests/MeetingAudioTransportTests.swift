import CoreAudio
import XCTest
@testable import Resonant

final class MeetingAudioTransportTests: XCTestCase {

    func testBuiltInFourCCMapsToBuiltIn() {
        let t = MeetingAudioTransport(rawValue4CC: UInt32(kAudioDeviceTransportTypeBuiltIn))
        XCTAssertEqual(t, .builtIn)
    }

    func testBluetoothFourCCMapsToBluetooth() {
        let t = MeetingAudioTransport(rawValue4CC: UInt32(kAudioDeviceTransportTypeBluetooth))
        XCTAssertEqual(t, .bluetooth)
    }

    func testBluetoothLEFourCCMapsToBluetoothLE() {
        let t = MeetingAudioTransport(rawValue4CC: UInt32(kAudioDeviceTransportTypeBluetoothLE))
        XCTAssertEqual(t, .bluetoothLE)
    }

    func testUSBFourCCMapsToUSB() {
        let t = MeetingAudioTransport(rawValue4CC: UInt32(kAudioDeviceTransportTypeUSB))
        XCTAssertEqual(t, .usb)
    }

    func testHDMIFourCCMapsToHDMI() {
        let t = MeetingAudioTransport(rawValue4CC: UInt32(kAudioDeviceTransportTypeHDMI))
        XCTAssertEqual(t, .hdmi)
    }

    func testAirPlayFourCCMapsToAirPlay() {
        let t = MeetingAudioTransport(rawValue4CC: UInt32(kAudioDeviceTransportTypeAirPlay))
        XCTAssertEqual(t, .airPlay)
    }

    func testAggregateFourCCMapsToAggregate() {
        let t = MeetingAudioTransport(rawValue4CC: UInt32(kAudioDeviceTransportTypeAggregate))
        XCTAssertEqual(t, .aggregate)
    }

    func testZeroMapsToUnknown() {
        let t = MeetingAudioTransport(rawValue4CC: 0)
        XCTAssertEqual(t, .unknown)
    }

    func testUnrecognizedFourCCMapsToUnknown() {
        let t = MeetingAudioTransport(rawValue4CC: 0xDEADBEEF)
        XCTAssertEqual(t, .unknown)
    }

    func testBluetoothShouldWarnBeforeMeeting() {
        XCTAssertTrue(MeetingAudioTransport.bluetooth.shouldWarnBeforeMeeting)
        XCTAssertTrue(MeetingAudioTransport.bluetoothLE.shouldWarnBeforeMeeting)
    }

    func testBuiltInShouldNotWarn() {
        XCTAssertFalse(MeetingAudioTransport.builtIn.shouldWarnBeforeMeeting)
    }

    func testWiredTransportsShouldNotWarn() {
        let transports: [MeetingAudioTransport] = [
            .usb, .hdmi, .displayPort, .thunderbolt, .pci, .fireWire, .avb
        ]
        for transport in transports {
            XCTAssertFalse(
                transport.shouldWarnBeforeMeeting,
                "\(transport.rawValue) should not trigger the Bluetooth warning"
            )
        }
    }
}
