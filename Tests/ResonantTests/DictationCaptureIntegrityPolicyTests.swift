import XCTest
@testable import Resonant

final class DictationCaptureIntegrityPolicyTests: XCTestCase {

    // Field case: 6.1 s dictation whose file held a 2 ms start pop after a
    // dead-capture watchdog rebuild.
    func testMillisecondStubOfLongRecordingIsStarved() {
        XCTAssertEqual(
            DictationCaptureIntegrityPolicy.assessment(wallSeconds: 6.10, capturedSeconds: 0.002),
            .starved(capturedSeconds: 0.002, wallSeconds: 6.10)
        )
    }

    // Field case: zero-sample file ("recording file contained no audio").
    func testEmptyFileOfLongRecordingIsStarved() {
        XCTAssertEqual(
            DictationCaptureIntegrityPolicy.assessment(wallSeconds: 4.0, capturedSeconds: 0),
            .starved(capturedSeconds: 0, wallSeconds: 4.0)
        )
    }

    // Field case: 3.57 s recording where only the 488 ms tail after the
    // session rebuild survived — transcription "succeeded" on the fragment.
    func testTailFragmentIsTruncated() {
        XCTAssertEqual(
            DictationCaptureIntegrityPolicy.assessment(wallSeconds: 3.57, capturedSeconds: 0.488),
            .truncated(capturedSeconds: 0.488, wallSeconds: 3.57)
        )
    }

    // Field case: healthy capture (3.84 s wall, 3.6 s file — startup shave only).
    func testHealthyCaptureIsIntact() {
        XCTAssertEqual(
            DictationCaptureIntegrityPolicy.assessment(wallSeconds: 3.84, capturedSeconds: 3.599),
            .intact
        )
    }

    // Field case: full-length capture of digital silence must stay intact so
    // the "isn't picking up sound" copy (not dropout copy) explains it.
    func testFullLengthSilenceIsIntact() {
        XCTAssertEqual(
            DictationCaptureIntegrityPolicy.assessment(wallSeconds: 4.08, capturedSeconds: 3.968),
            .intact
        )
    }

    // Quick taps capture little for legitimate reasons; the silent-cancel
    // policy owns them and the device is never blamed.
    func testShortPressIsNotAssessed() {
        XCTAssertEqual(
            DictationCaptureIntegrityPolicy.assessment(wallSeconds: 0.4, capturedSeconds: 0),
            .intact
        )
        XCTAssertEqual(
            DictationCaptureIntegrityPolicy.assessment(wallSeconds: 1.49, capturedSeconds: 0.01),
            .intact
        )
    }

    func testModestShaveBelowMissingFloorIsIntact() {
        XCTAssertEqual(
            DictationCaptureIntegrityPolicy.assessment(wallSeconds: 1.8, capturedSeconds: 0.85),
            .intact
        )
    }

    func testHalfMissingLongRecordingIsTruncated() {
        XCTAssertEqual(
            DictationCaptureIntegrityPolicy.assessment(wallSeconds: 10.0, capturedSeconds: 4.0),
            .truncated(capturedSeconds: 4.0, wallSeconds: 10.0)
        )
    }

    func testNonFiniteInputsAreIntact() {
        XCTAssertEqual(
            DictationCaptureIntegrityPolicy.assessment(wallSeconds: .nan, capturedSeconds: 1),
            .intact
        )
        XCTAssertEqual(
            DictationCaptureIntegrityPolicy.assessment(wallSeconds: 5, capturedSeconds: .infinity),
            .intact
        )
    }
}
