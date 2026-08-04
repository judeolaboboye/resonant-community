import Foundation

/// Cloud transcription backend for meetings. The existing meeting pipeline still
/// owns capture, VAD, channel labeling, and post-processing; this backend sends
/// completed 16 kHz mono speech segments through Resonant's Convex proxy.
final class MeetingDeepgramBackend: MeetingTranscriptionBackend, @unchecked Sendable {

    struct ConvexCredentials: Sendable, Equatable {
        let userID: String
        let bearerToken: String
    }

    typealias CredentialsProvider = @Sendable () async -> ConvexCredentials?

    let displayName = "Deepgram Nova-3"

    private static let convexActionPath = "meetingTranscription:transcribeDeepgram"
    private static let sampleRate = 16_000
    private static let channelCount = 1
    private static let bitsPerSample = 16

    private let credentialsProvider: CredentialsProvider
    private let baseURL: URL
    private let session: URLSession
    private var prepared = false

    init(
        credentialsProvider: @escaping CredentialsProvider = {
            await MeetingDeepgramBackend.defaultCredentials()
        },
        baseURL: URL = AppRuntime.appEnvironment.convexCloudURL(),
        session: URLSession = .shared
    ) {
        self.credentialsProvider = credentialsProvider
        self.baseURL = baseURL
        self.session = session
    }

    func prepare(onStatus: @Sendable (String) -> Void) async throws {
        onStatus("Preparing Deepgram cloud transcription...")
        guard await credentialsProvider() != nil else {
            throw MeetingDeepgramBackendError.missingCloudSession
        }
        prepared = true
    }

    func transcribe(_ samples: [Float], locale: Locale) async throws -> String {
        let segments = try await transcribeSegments(samples, locale: locale)
        return segments.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func transcribeSegments(_ samples: [Float], locale: Locale) async throws -> [MeetingTranscriptionSegment] {
        guard prepared else {
            throw MeetingTranscriptionBackendError.notPrepared
        }

        guard let credentials = await credentialsProvider() else {
            throw MeetingDeepgramBackendError.missingCloudSession
        }

        let prepared = try TranscriberAudioSupport.preparedSamples(samples)
        let audioData = Self.wavData(from: prepared)
        let requestBody = try Self.actionRequestBody(
            userID: credentials.userID,
            audioData: audioData,
            languageCode: Self.languageCode(for: locale)
        )

        var request = URLRequest(url: baseURL.appending(path: "api/action"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(credentials.bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = requestBody

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MeetingDeepgramBackendError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = Self.errorMessage(from: data)
            throw MeetingDeepgramBackendError.proxyError(statusCode: httpResponse.statusCode, message: message)
        }

        return try Self.transcriptionSegments(fromConvexData: data)
    }

    nonisolated static func actionRequestBody(
        userID: String,
        audioData: Data,
        languageCode: String?
    ) throws -> Data {
        var args: [String: Any] = [
            "userId": userID,
            "audioBase64": audioData.base64EncodedString(),
            "diarize": true,
            "utterances": true,
        ]
        if let languageCode {
            args["language"] = languageCode
        }

        return try JSONSerialization.data(withJSONObject: [
            "path": convexActionPath,
            "args": args,
        ])
    }

    nonisolated static func languageCode(for locale: Locale) -> String? {
        locale.language.languageCode?.identifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .nilIfEmpty
    }

    nonisolated static func transcript(fromConvexData data: Data) throws -> String {
        let segments = try transcriptionSegments(fromConvexData: data)
        return segments.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func transcriptionSegments(fromConvexData data: Data) throws -> [MeetingTranscriptionSegment] {
        let value = try convexValue(fromConvexData: data)
        return try transcriptionSegments(from: value)
    }

    private nonisolated static func convexValue(fromConvexData data: Data) throws -> Any {
        let json = try JSONSerialization.jsonObject(with: data)
        if let dictionary = json as? [String: Any],
           dictionary["status"] as? String == "error" {
            throw MeetingDeepgramBackendError.proxyError(
                statusCode: 200,
                message: dictionary["errorMessage"] as? String ?? "Unknown Convex error"
            )
        }

        return (json as? [String: Any])?["value"] ?? json
    }

    private nonisolated static func transcriptionSegments(from value: Any) throws -> [MeetingTranscriptionSegment] {
        if let text = normalizedString(value) {
            return [MeetingTranscriptionSegment(text: text)]
        }

        guard let dictionary = value as? [String: Any] else {
            throw MeetingDeepgramBackendError.invalidResponse
        }

        let directUtterances = utteranceSegments(from: dictionary["utterances"])
        if !directUtterances.isEmpty {
            return directUtterances
        }

        if let results = dictionary["results"] as? [String: Any] {
            let resultUtterances = utteranceSegments(from: results["utterances"])
            if !resultUtterances.isEmpty {
                return resultUtterances
            }

            let resultWords = wordSegments(from: results)
            if !resultWords.isEmpty {
                return resultWords
            }

            if let text = firstText(in: results) {
                return [MeetingTranscriptionSegment(text: text)]
            }
        }

        let directWords = wordSegments(from: dictionary)
        if !directWords.isEmpty {
            return directWords
        }

        if let text = firstText(in: dictionary) {
            return [MeetingTranscriptionSegment(text: text)]
        }

        return []
    }

    nonisolated static func wavData(from samples: [Float]) -> Data {
        let pcm = linear16Data(from: samples)
        let dataByteCount = UInt32(pcm.count)
        let byteRate = UInt32(sampleRate * channelCount * bitsPerSample / 8)
        let blockAlign = UInt16(channelCount * bitsPerSample / 8)

        var data = Data(capacity: 44 + pcm.count)
        data.appendASCII("RIFF")
        data.appendLittleEndian(UInt32(36) + dataByteCount)
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(channelCount))
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(UInt16(bitsPerSample))
        data.appendASCII("data")
        data.appendLittleEndian(dataByteCount)
        data.append(pcm)
        return data
    }

    private nonisolated static func defaultCredentials() async -> ConvexCredentials? {
        await MainActor.run {
            let settings = SettingsManager.shared
            guard let userID = settings.userId?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty,
                let token = ConvexClient.convexBearerToken(from: settings.cloudAuthToken)
            else {
                return nil
            }

            return ConvexCredentials(userID: userID, bearerToken: token)
        }
    }

    private nonisolated static func linear16Data(from samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let finite = sample.isFinite ? sample : 0
            let clamped = max(-1, min(1, finite))
            let scaled = clamped < 0 ? clamped * 32768 : clamped * 32767
            var intSample = Int16(scaled.rounded()).littleEndian
            Swift.withUnsafeBytes(of: &intSample) { bytes in
                data.append(contentsOf: bytes)
            }
        }
        return data
    }

    private nonisolated static func errorMessage(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let errorMessage = json["errorMessage"] as? String,
           !errorMessage.isEmpty {
            return errorMessage
        }

        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else {
            return "Deepgram cloud transcription returned an error."
        }
        return text
    }

    private nonisolated static func utteranceSegments(from value: Any?) -> [MeetingTranscriptionSegment] {
        dictionaries(from: value).compactMap { utterance in
            let text = firstText(in: utterance) ?? text(fromWords: utterance["words"])
            guard let text, !text.isEmpty else { return nil }

            return MeetingTranscriptionSegment(
                text: text,
                speaker: speaker(from: utterance["speaker"] ?? utterance["speakerId"] ?? utterance["speaker_id"]),
                startOffset: seconds(from: utterance["start"] ?? utterance["startOffset"] ?? utterance["start_offset"]),
                endOffset: seconds(from: utterance["end"] ?? utterance["endOffset"] ?? utterance["end_offset"])
            )
        }
    }

    private nonisolated static func wordSegments(from value: Any) -> [MeetingTranscriptionSegment] {
        let words = wordEntries(from: value)
        guard words.contains(where: { $0.speaker != nil }) else {
            return []
        }

        var segments: [MeetingTranscriptionSegment] = []
        var currentSpeaker: MeetingSpeaker?
        var currentWords: [String] = []
        var currentStart: TimeInterval?
        var currentEnd: TimeInterval?

        func flush() {
            guard !currentWords.isEmpty else { return }
            segments.append(MeetingTranscriptionSegment(
                text: currentWords.joined(separator: " "),
                speaker: currentSpeaker,
                startOffset: currentStart,
                endOffset: currentEnd
            ))
            currentWords.removeAll(keepingCapacity: true)
            currentStart = nil
            currentEnd = nil
        }

        for word in words {
            if !currentWords.isEmpty, word.speaker != currentSpeaker {
                flush()
            }

            if currentWords.isEmpty {
                currentSpeaker = word.speaker
                currentStart = word.start
            }
            currentWords.append(word.text)
            currentEnd = word.end ?? currentEnd
        }

        flush()
        return segments
    }

    private nonisolated static func wordEntries(from value: Any) -> [DeepgramWord] {
        var words: [DeepgramWord] = []
        if let dictionary = value as? [String: Any] {
            words.append(contentsOf: wordEntries(fromArray: dictionary["words"]))

            for alternative in dictionaries(from: dictionary["alternatives"]) {
                words.append(contentsOf: wordEntries(fromArray: alternative["words"]))
            }

            for channel in dictionaries(from: dictionary["channels"]) {
                words.append(contentsOf: wordEntries(from: channel))
            }
        }
        return words
    }

    private nonisolated static func wordEntries(fromArray value: Any?) -> [DeepgramWord] {
        dictionaries(from: value).compactMap { word in
            guard let text = firstText(in: word, keys: ["punctuated_word", "word"]) else {
                return nil
            }
            return DeepgramWord(
                text: text,
                speaker: speaker(from: word["speaker"] ?? word["speakerId"] ?? word["speaker_id"]),
                start: seconds(from: word["start"] ?? word["startOffset"] ?? word["start_offset"]),
                end: seconds(from: word["end"] ?? word["endOffset"] ?? word["end_offset"])
            )
        }
    }

    private nonisolated static func text(fromWords value: Any?) -> String? {
        let text = wordEntries(fromArray: value)
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.nilIfEmpty
    }

    private nonisolated static func firstText(
        in dictionary: [String: Any],
        keys: [String] = ["text", "transcript"]
    ) -> String? {
        for key in keys {
            if let text = normalizedString(dictionary[key]) {
                return text
            }
        }
        return nil
    }

    private nonisolated static func normalizedString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        return string.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private nonisolated static func seconds(from value: Any?) -> TimeInterval? {
        if isJSONBoolean(value) {
            return nil
        }
        if let number = value as? NSNumber {
            return number.doubleValue.isFinite ? number.doubleValue : nil
        }
        if let string = normalizedString(value),
           let number = Double(string),
           number.isFinite {
            return number
        }
        return nil
    }

    private nonisolated static func speaker(from value: Any?) -> MeetingSpeaker? {
        if isJSONBoolean(value) {
            return nil
        }
        if let number = value as? NSNumber {
            return .participant(id: "SPEAKER_\(number.intValue)")
        }
        guard let raw = normalizedString(value) else {
            return nil
        }

        if let meetingSpeaker = MeetingSpeaker(storageKey: raw) {
            return meetingSpeaker
        }
        if let number = Int(raw) {
            return .participant(id: "SPEAKER_\(number)")
        }

        let normalized = raw
            .replacingOccurrences(of: " ", with: "_")
            .uppercased()
        if normalized.hasPrefix("SPEAKER_"),
           MeetingSpeaker.participantIndex(for: normalized) != nil {
            return .participant(id: normalized)
        }

        return nil
    }

    private nonisolated static func isJSONBoolean(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private nonisolated static func dictionaries(from value: Any?) -> [[String: Any]] {
        guard let array = value as? [Any] else { return [] }
        return array.compactMap { $0 as? [String: Any] }
    }
}

enum MeetingDeepgramBackendError: LocalizedError, Equatable {
    case missingCloudSession
    case invalidResponse
    case proxyError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .missingCloudSession:
            return "Deepgram cloud transcription requires signing in to Resonant."
        case .invalidResponse:
            return "Deepgram cloud transcription returned an invalid response."
        case .proxyError(let statusCode, let message):
            return "Deepgram cloud transcription HTTP \(statusCode): \(message)"
        }
    }
}

private struct DeepgramWord {
    let text: String
    let speaker: MeetingSpeaker?
    let start: TimeInterval?
    let end: TimeInterval?
}

private extension Data {
    mutating func appendASCII(_ string: String) {
        append(contentsOf: string.utf8)
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
