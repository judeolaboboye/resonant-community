import XCTest
@testable import Resonant

final class MeetingTranscriptionEngineTests: XCTestCase {
    func testExplicitTranscriptionLanguageBuildsMeetingLocale() {
        let locale = MeetingTranscriptionEngine.locale(forTranscriptionLanguage: "sv")

        XCTAssertEqual(locale.identifier, "sv")
        XCTAssertEqual(locale.language.languageCode?.identifier, "sv")
    }

    func testAutomaticTranscriptionLanguageUsesCurrentLocale() {
        let locale = MeetingTranscriptionEngine.locale(forTranscriptionLanguage: "auto")

        XCTAssertEqual(locale.identifier, Locale.current.identifier)
    }

    func testMeetingImportLocaleUsesExplicitTranscriptionLanguageResolver() {
        let locale = MeetingTranscriptionEngine.locale(forTranscriptionLanguage: "de")

        XCTAssertEqual(locale.identifier, "de")
        XCTAssertEqual(locale.language.languageCode?.identifier, "de")
    }

    func testMeetingTranscriberRepairsFragmentedWords() {
        let result = MeetingStreamingTranscriber.normalizeTranscribedText(
            " please fix the t rans format i on bug "
        )

        XCTAssertEqual(result, "please fix the transformation bug")
    }

    func testMeetingTranscriberRepairsCollapsedRuns() {
        let result = MeetingStreamingTranscriber.normalizeTranscribedText(
            " Iproposeditto "
        )

        XCTAssertEqual(result, "I proposed it to")
    }

    func testOnlineCallMicSpeakerIgnoresBackendDiarizationLabels() {
        let resolved = MeetingStreamingTranscriber.resolvedSpeaker(
            configuredSpeaker: .you,
            segmentSpeaker: .participant(id: "SPEAKER_1")
        )

        XCTAssertEqual(resolved, .you)
    }

    func testOnlineCallSystemSpeakerIgnoresBackendDiarizationLabels() {
        let resolved = MeetingStreamingTranscriber.resolvedSpeaker(
            configuredSpeaker: .them,
            segmentSpeaker: .participant(id: "SPEAKER_0")
        )

        XCTAssertEqual(resolved, .them)
    }

    func testRoomModePreservesBackendDiarizationLabels() {
        let resolved = MeetingStreamingTranscriber.resolvedSpeaker(
            configuredSpeaker: .participant(id: "SPEAKER_0"),
            segmentSpeaker: .participant(id: "SPEAKER_2")
        )

        XCTAssertEqual(resolved, .participant(id: "SPEAKER_2"))
    }

    func testDeepgramActionRequestUsesConvexProxyAndBase64Audio() throws {
        let requestBody = try MeetingDeepgramBackend.actionRequestBody(
            userID: "user123",
            audioData: Data([1, 2, 3]),
            languageCode: "de"
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        let args = try XCTUnwrap(json["args"] as? [String: Any])

        XCTAssertEqual(json["path"] as? String, "meetingTranscription:transcribeDeepgram")
        XCTAssertEqual(args["userId"] as? String, "user123")
        XCTAssertEqual(args["audioBase64"] as? String, Data([1, 2, 3]).base64EncodedString())
        XCTAssertEqual(args["language"] as? String, "de")
        XCTAssertEqual(args["diarize"] as? Bool, true)
        XCTAssertEqual(args["utterances"] as? Bool, true)
    }

    func testDeepgramWAVDataUses16kMonoPCMHeader() {
        let data = MeetingDeepgramBackend.wavData(from: [-1, 0, 1])

        XCTAssertEqual(String(data: data[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: data[12..<16], encoding: .ascii), "fmt ")
        XCTAssertEqual(String(data: data[36..<40], encoding: .ascii), "data")
        XCTAssertEqual(data.count, 44 + 6)
        XCTAssertEqual(data.littleEndianUInt16(at: 20), 1)
        XCTAssertEqual(data.littleEndianUInt16(at: 22), 1)
        XCTAssertEqual(data.littleEndianUInt32(at: 24), 16_000)
        XCTAssertEqual(data.littleEndianUInt16(at: 34), 16)
        XCTAssertEqual(data.littleEndianUInt32(at: 40), 6)
        XCTAssertEqual(Int16(bitPattern: data.littleEndianUInt16(at: 44)), Int16.min)
        XCTAssertEqual(Int16(bitPattern: data.littleEndianUInt16(at: 46)), 0)
        XCTAssertEqual(Int16(bitPattern: data.littleEndianUInt16(at: 48)), Int16.max)
    }

    func testDeepgramTranscriptDecodesConvexActionValue() throws {
        let json = """
        {
          "status": "success",
          "value": {
            "text": "  We should ship the Deepgram option.  ",
            "durationMs": 123
          }
        }
        """.data(using: .utf8)!

        let transcript = try MeetingDeepgramBackend.transcript(fromConvexData: json)

        XCTAssertEqual(transcript, "We should ship the Deepgram option.")
    }

    func testDeepgramSegmentsDecodeConvexUtterances() throws {
        let json = """
        {
          "status": "success",
          "value": {
            "text": "Alice opens. Bob replies.",
            "utterances": [
              {
                "text": "  Alice opens.  ",
                "speaker": 0,
                "start": 0.12,
                "end": 1.4
              },
              {
                "transcript": "Bob replies.",
                "speaker": "SPEAKER_1",
                "start": 1.5,
                "end": 2.7
              }
            ]
          }
        }
        """.data(using: .utf8)!

        let segments = try MeetingDeepgramBackend.transcriptionSegments(fromConvexData: json)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].text, "Alice opens.")
        XCTAssertEqual(segments[0].speaker, .participant(id: "SPEAKER_0"))
        XCTAssertEqual(try XCTUnwrap(segments[0].startOffset), 0.12, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(segments[0].endOffset), 1.4, accuracy: 0.001)
        XCTAssertEqual(segments[1].text, "Bob replies.")
        XCTAssertEqual(segments[1].speaker, .participant(id: "SPEAKER_1"))
        XCTAssertEqual(try XCTUnwrap(segments[1].startOffset), 1.5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(segments[1].endOffset), 2.7, accuracy: 0.001)
    }

    func testDeepgramSegmentsGroupSpeakerWordsFromNestedResults() throws {
        let json = """
        {
          "status": "success",
          "value": {
            "results": {
              "channels": [
                {
                  "alternatives": [
                    {
                      "transcript": "Alice starts. Bob answers.",
                      "words": [
                        {
                          "punctuated_word": "Alice",
                          "start": 0.1,
                          "end": 0.4,
                          "speaker": 0
                        },
                        {
                          "punctuated_word": "starts.",
                          "start": 0.4,
                          "end": 0.8,
                          "speaker": 0
                        },
                        {
                          "punctuated_word": "Bob",
                          "start": 0.9,
                          "end": 1.2,
                          "speaker": 1
                        },
                        {
                          "punctuated_word": "answers.",
                          "start": 1.2,
                          "end": 1.8,
                          "speaker": 1
                        }
                      ]
                    }
                  ]
                }
              ]
            }
          }
        }
        """.data(using: .utf8)!

        let segments = try MeetingDeepgramBackend.transcriptionSegments(fromConvexData: json)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].text, "Alice starts.")
        XCTAssertEqual(segments[0].speaker, .participant(id: "SPEAKER_0"))
        XCTAssertEqual(try XCTUnwrap(segments[0].startOffset), 0.1, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(segments[0].endOffset), 0.8, accuracy: 0.001)
        XCTAssertEqual(segments[1].text, "Bob answers.")
        XCTAssertEqual(segments[1].speaker, .participant(id: "SPEAKER_1"))
        XCTAssertEqual(try XCTUnwrap(segments[1].startOffset), 0.9, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(segments[1].endOffset), 1.8, accuracy: 0.001)
    }

    @MainActor
    func testDeepgramMeetingBackendStaysHiddenUntilBackendProxyShips() {
        XCTAssertFalse(MeetingBackendKind.deepgram.isAvailable)
    }
}

private extension Data {
    func littleEndianUInt16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func littleEndianUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }
}
